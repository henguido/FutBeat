-- One real person = one player identity in a squad.
--
-- Root cause (production, read-only diagnosis 2026-10-01): GOAL's
-- /teams/:id/players answer lists the SAME person twice, under two catalog ids
-- from two GOAL catalog batches: a complete record ("Pablo Arboine", photo,
-- birth date, stats) and a sparse one with the name in "Last First" order or
-- shortened ("Arboine Pablo", no photo/age), both with the same shirt number.
-- Squad ingestion canonicalizes players strictly by provider id, so each id
-- became its own canonical player and both joined team_squad_members (693 of
-- 695 same-number duplicate pairs were stored by the same squad fetch; with
-- the rule below ~718 duplicate identities in ~270 of 752 stored squads).
--
-- Fix (generic: no names or ids):
--   * One rule decides "same person in this squad" (same_squad_player):
--     same team AND names compatible (tokens compared order-free) AND
--       - both shirt numbers known and equal, one name's tokens contained in
--         the other's (>= 2 tokens each), or
--       - a shirt number unknown and identical full names (>= 2 tokens, no
--         initials).
--     Two known, different shirt numbers are never the same person. A
--     candidate whose matches are not all mutually compatible (e.g. one
--     "A. B" without number next to two different "A. B" numbers) is
--     ambiguous and never collapsed.
--   * The richest identity is kept (verified photo, birth date, age, stats,
--     position, country; then the established provider identity; then the
--     fuller name).
--   * Read: the team profile squad and its coverage count list each person
--     once (immediate for every team, no data change).
--   * Ingestion: a squad answer that lists one person twice stores only the
--     kept row; the other provider identity is MERGED onto the kept player
--     through entity_redirects (kind 'player', new): its provider ids,
--     memberships, follows and interests move to the kept player, the alias
--     entity row is kept for old links. Lineups, search and profiles then
--     resolve every id of that person to one identity and one photo.
--   * Snapshot reads only ship player redirects relevant to their players.
-- Existing duplicates merge on each team's next squad refresh; an optional
-- bounded manual script (supabase/manual/2026-10-01_squad_player_identity_merge.sql)
-- merges them immediately.

-- ---------------------------------------------------------------------------
-- Player redirects.
-- ---------------------------------------------------------------------------

alter table futbeat_private.entity_redirects
  drop constraint if exists entity_redirects_kind_check;
alter table futbeat_private.entity_redirects
  add constraint entity_redirects_kind_check
  check(kind in ('competition','team','player'));

-- ---------------------------------------------------------------------------
-- The "same person in one squad" rule.
-- ---------------------------------------------------------------------------

-- Order-free name tokens: accents folded, punctuation dropped.
create function futbeat_private.player_name_tokens(p_name text)
returns text[] language sql immutable set search_path='' as $$
  select coalesce(array(
    select t from unnest(string_to_array(futbeat_private.normalize_live_name(p_name),' ')) t
    where t<>'' order by t),'{}'::text[])
$$;

-- A real dorsal (0, blanks, decimals and absurd values are unknown).
create function futbeat_private.squad_shirt_number(p_value jsonb)
returns integer language sql immutable set search_path='' as $$
  select case
    when jsonb_typeof(p_value)='number'
      and (p_value::text)::numeric between 1 and 999
      and (p_value::text)::numeric=trunc((p_value::text)::numeric)
    then (p_value::text)::numeric::integer end
$$;

create function futbeat_private.same_squad_player(
  a_tokens text[],a_shirt integer,b_tokens text[],b_shirt integer
) returns boolean language sql immutable set search_path='' as $$
  select coalesce(cardinality(a_tokens)>=2 and cardinality(b_tokens)>=2
    and case
      when a_shirt is not null and b_shirt is not null then
        a_shirt=b_shirt and (a_tokens<@b_tokens or b_tokens<@a_tokens)
      else a_tokens=b_tokens
        and not exists(select 1 from unnest(a_tokens) t where length(t)<2)
    end,false)
$$;

-- How much a player identity really knows (higher = richer).
create function futbeat_private.player_identity_richness(p jsonb)
returns integer language sql immutable set search_path='' as $$
  select case when futbeat_private.valid_player_media(p->'media') then 32 else 0 end
    + case when coalesce(btrim(p->>'dateOfBirth'),'')<>'' then 16 else 0 end
    + case when jsonb_typeof(p->'age')='number' then 8 else 0 end
    + case when jsonb_typeof(p->'matchesPlayed')='number' then 4 else 0 end
    + case when coalesce(btrim(p->>'position'),'')<>'' then 2 else 0 end
    + case when coalesce(btrim(p->>'country'),'')<>'' then 1 else 0 end
    + case when jsonb_typeof(p->'height')='number' then 1 else 0 end
$$;

-- Candidates: [{key,name,shirtNumber,score,established}] of ONE squad.
-- Returns each duplicate key with the key of the identity that is kept.
create function futbeat_private.squad_identity_duplicates(p_candidates jsonb)
returns table(alias_key text,keeper_key text)
language sql stable set search_path='' as $$
  with c as (
    select distinct on (x->>'key')
      x->>'key' k,
      futbeat_private.player_name_tokens(x->>'name') toks,
      futbeat_private.squad_shirt_number(x->'shirtNumber') shirt,
      coalesce((x->>'score')::integer,0) score,
      coalesce((x->>'established')::boolean,false) est
    from jsonb_array_elements(case when jsonb_typeof(p_candidates)='array'
      then p_candidates else '[]'::jsonb end) x
    where nullif(x->>'key','') is not null
    order by x->>'key'
  ), p as materialized (
    select a.k a,b.k b
    from c a join c b on a.k<>b.k
    where futbeat_private.same_squad_player(a.toks,a.shirt,b.toks,b.shirt)
  ), clean as (
    -- Every match of this candidate also matches every other one.
    select c.* from c
    where exists(select 1 from p where p.a=c.k)
      and not exists(
        select 1 from p n1 join p n2 on n2.a=n1.a and n1.b<n2.b
        where n1.a=c.k
          and not exists(select 1 from p x where x.a=n1.b and x.b=n2.b))
  ), ranked as (
    select k,row_number() over(
      order by score desc,est desc,cardinality(toks) desc,k) r
    from clean
  )
  select a.k,(
    select b.k from p join ranked b on b.k=p.b
    where p.a=a.k order by b.r limit 1)
  from ranked a
  where exists(
    select 1 from p join ranked b on b.k=p.b
    where p.a=a.k and b.r<a.r)
$$;

-- Duplicate identities currently in a team's stored squad (canonical ids).
create function futbeat_private.team_squad_duplicate_pairs(p_team_id text)
returns table(alias_id text,canonical_id text)
language sql stable set search_path='' as $$
  with members as (
    select distinct futbeat_private.futbeat_resolve_entity_id('player',sm.player_id) id
    from futbeat_private.team_squad_members sm
    where sm.team_id=p_team_id
  ), players as (
    select e.id,e.payload
    from members m join futbeat_private.entities e on e.id=m.id and e.kind='player'
  )
  select d.alias_key,d.keeper_key
  from futbeat_private.squad_identity_duplicates((
    select coalesce(jsonb_agg(jsonb_build_object(
      'key',id,'name',payload->>'name','shirtNumber',payload->'shirtNumber',
      'score',futbeat_private.player_identity_richness(payload))),'[]'::jsonb)
    from players)) d
$$;

-- The squad as users see it: canonical players, each person once.
create function futbeat_private.team_squad_player_ids(p_team_id text)
returns setof text language sql stable set search_path='' as $$
  with dup as materialized (
    select alias_id from futbeat_private.team_squad_duplicate_pairs(p_team_id)
  )
  select distinct e.id
  from futbeat_private.team_squad_members sm
  join futbeat_private.entities e
    on e.id=futbeat_private.futbeat_resolve_entity_id('player',sm.player_id)
   and e.kind='player'
  where sm.team_id=p_team_id
    and not exists(select 1 from dup where dup.alias_id=e.id)
$$;

-- ---------------------------------------------------------------------------
-- Player identity merge (redirect; the alias entity row is never deleted).
-- ---------------------------------------------------------------------------

create function futbeat_private.futbeat_merge_player_identity(
  p_alias_id text,p_canonical_id text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_target text; v_alias jsonb; v_canonical jsonb; v_next jsonb; v_key text;
  v_aliases jsonb; v_name text; v_interests integer:=0;
begin
  if nullif(p_alias_id,'') is null or nullif(p_canonical_id,'') is null
     or nullif(btrim(p_reason),'') is null then
    raise exception 'Invalid player merge';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-player-merge'));
  v_target:=futbeat_private.futbeat_resolve_entity_id('player',p_canonical_id);
  if v_target=p_alias_id then raise exception 'Player merge cycle'; end if;
  if futbeat_private.futbeat_resolve_entity_id('player',p_alias_id)=v_target then
    return jsonb_build_object('status','already_merged','aliasId',p_alias_id,'canonicalId',v_target);
  end if;
  if exists(select 1 from futbeat_private.entity_redirects where alias_id=p_alias_id) then
    raise exception 'Player alias is already redirected';
  end if;
  select payload into v_alias from futbeat_private.entities
  where id=p_alias_id and kind='player' for update;
  select payload into v_canonical from futbeat_private.entities
  where id=v_target and kind='player' for update;
  if v_alias is null or v_canonical is null then
    raise exception 'Player merge entities must exist';
  end if;

  insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason,created_at)
  values(p_alias_id,v_target,'player',left(btrim(p_reason),500),now());
  -- Older aliases of the alias now point straight to the kept player.
  update futbeat_private.entity_redirects set canonical_id=v_target
  where kind='player' and canonical_id=p_alias_id;

  -- The kept identity only gains facts it lacks; its name stays.
  v_next:=v_canonical;
  foreach v_key in array array['shortName','country','dateOfBirth','age','height','preferredFoot','position'] loop
    if coalesce(btrim(v_next->>v_key),'')='' and coalesce(btrim(v_alias->>v_key),'')<>'' then
      v_next:=v_next||jsonb_build_object(v_key,v_alias->v_key);
    end if;
  end loop;
  if futbeat_private.squad_shirt_number(v_next->'shirtNumber') is null
     and futbeat_private.squad_shirt_number(v_alias->'shirtNumber') is not null then
    v_next:=v_next||jsonb_build_object('shirtNumber',v_alias->'shirtNumber');
  end if;
  if not futbeat_private.valid_player_media(v_next->'media')
     and futbeat_private.valid_player_media(v_alias->'media') then
    v_next:=jsonb_set(v_next,'{media}',v_alias->'media',true);
  end if;
  v_aliases:=case when jsonb_typeof(v_next->'aliases')='array' then v_next->'aliases' else '[]'::jsonb end;
  v_name:=nullif(btrim(v_alias->>'name'),'');
  if v_name is not null and lower(v_name)<>lower(coalesce(v_next->>'name',''))
     and not exists(select 1 from jsonb_array_elements_text(v_aliases) a where lower(a)=lower(v_name)) then
    v_next:=v_next||jsonb_build_object('aliases',v_aliases||jsonb_build_array(v_name));
  end if;
  if v_next is distinct from v_canonical then
    update futbeat_private.entities set payload=v_next where id=v_target and kind='player';
  end if;

  update futbeat_private.provider_entities set canonical_id=v_target
  where kind='player' and canonical_id=p_alias_id;
  update futbeat_private.provider_media_cache set canonical_id=v_target
  where kind='player' and canonical_id=p_alias_id;

  insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
  select team_id,v_target,provider,updated_at
  from futbeat_private.team_squad_members where player_id=p_alias_id
  on conflict(team_id,player_id) do update
    set updated_at=greatest(futbeat_private.team_squad_members.updated_at,excluded.updated_at);
  delete from futbeat_private.team_squad_members where player_id=p_alias_id;

  insert into futbeat_private.push_follows(user_id,entity_type,entity_id,created_at)
  select user_id,'player',v_target,created_at from futbeat_private.push_follows
  where entity_type='player' and entity_id=p_alias_id
  on conflict(user_id,entity_type,entity_id) do nothing;
  delete from futbeat_private.push_follows where entity_type='player' and entity_id=p_alias_id;
  get diagnostics v_interests=row_count;

  insert into futbeat_private.temporary_interests(user_id,entity_type,entity_id,touched_at,expires_at)
  select user_id,'player',v_target,touched_at,expires_at from futbeat_private.temporary_interests
  where entity_type='player' and entity_id=p_alias_id
  on conflict(user_id,entity_type,entity_id) do update
    set touched_at=greatest(futbeat_private.temporary_interests.touched_at,excluded.touched_at),
        expires_at=greatest(futbeat_private.temporary_interests.expires_at,excluded.expires_at);
  delete from futbeat_private.temporary_interests where entity_type='player' and entity_id=p_alias_id;
  if found then v_interests:=v_interests+1; end if;
  if v_interests>0 then perform futbeat_private.refresh_interest_aggregates(); end if;

  perform futbeat_private.bump_metric('player_identity_merged');
  return jsonb_build_object('status','merged','aliasId',p_alias_id,'canonicalId',v_target);
end $$;

-- ---------------------------------------------------------------------------
-- Ingestion: one row per person; the duplicate identity merges onto it.
-- ---------------------------------------------------------------------------

alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  rename to store_team_squad_before_identity_dedup;
create function futbeat_private.futbeat_store_team_squad(
  p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  kept jsonb; pairs jsonb; result jsonb; r record; merged integer:=0;
begin
  if jsonb_typeof(p_players) is distinct from 'array' then
    return futbeat_private.store_team_squad_before_identity_dedup(p_team_id,p_provider,p_received_at,p_players);
  end if;
  with items as (
    select x.ord,x.item,nullif(btrim(x.item#>>'{provenance,externalId}'),'') ext
    from jsonb_array_elements(p_players) with ordinality x(item,ord)
  ), resolved as (
    select i.*,
      coalesce(e.id,nullif(i.item->>'id',''),'#'||i.ord) pid,
      e.payload old
    from items i
    left join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='player' and pe.external_id=i.ext
    left join futbeat_private.entities e
      on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) and e.kind='player'
  ), scored as (
    select rs.*,
      futbeat_private.player_identity_richness(
        coalesce(rs.old,'{}'::jsonb)||jsonb_strip_nulls(rs.item)) score,
      coalesce(rs.old#>>'{provenance,externalId}'=rs.ext,false) est,
      cardinality(futbeat_private.player_name_tokens(rs.item->>'name')) ntok
    from resolved rs
  ), per_player as (
    -- Two provider rows of one canonical player: keep one.
    select distinct on (s.pid) s.*
    from scored s
    order by s.pid,s.score desc,s.est desc,s.ntok desc,s.ext,s.ord
  ), dups as (
    select d.alias_key,d.keeper_key
    from futbeat_private.squad_identity_duplicates((
      select coalesce(jsonb_agg(jsonb_build_object(
        'key',pid,'name',item->>'name','shirtNumber',item->'shirtNumber',
        'score',score,'established',est)),'[]'::jsonb)
      from per_player)) d
  )
  select
    coalesce((select jsonb_agg(
        -- A merged duplicate's row never renames the kept identity: while the
        -- established provider id still maps here, its name stays.
        case when not p.est and coalesce(btrim(p.old->>'name'),'')<>''
          and exists(select 1 from futbeat_private.provider_entities pe
            where pe.provider='goal_api' and pe.kind='player'
              and pe.external_id=p.old#>>'{provenance,externalId}'
              and futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)=p.pid)
        then p.item||jsonb_build_object('name',p.old->'name',
          'shortName',coalesce(p.old->'shortName',p.item->'shortName','""'::jsonb))
        else p.item end
        order by p.ord) from per_player p
      where not exists(select 1 from dups d where d.alias_key=p.pid)),'[]'::jsonb),
    coalesce((select jsonb_agg(jsonb_build_object('alias',alias_key,'keeper',keeper_key))
      from dups where alias_key not like '#%' and keeper_key not like '#%'),'[]'::jsonb)
  into kept,pairs;

  result:=futbeat_private.store_team_squad_before_identity_dedup(p_team_id,p_provider,p_received_at,kept);
  if result->>'status' in ('ignored_older','ignored_older_players') then
    return result;
  end if;

  for r in select x->>'alias' alias_id,x->>'keeper' keeper_id from jsonb_array_elements(pairs) x loop
    if exists(select 1 from futbeat_private.entities where id=r.alias_id and kind='player')
       and exists(select 1 from futbeat_private.entities where id=r.keeper_id and kind='player')
       and not exists(select 1 from futbeat_private.entity_redirects where alias_id=r.alias_id)
       and futbeat_private.futbeat_resolve_entity_id('player',r.keeper_id)<>r.alias_id then
      perform futbeat_private.futbeat_merge_player_identity(r.alias_id,r.keeper_id,
        'GOAL squad lists one person twice (same team; same shirt number or full name)');
      merged:=merged+1;
    end if;
  end loop;

  -- Counts describe the squad users see.
  update futbeat_private.team_detail_coverage c set
    player_count=(select count(*) from futbeat_private.team_squad_player_ids(tid)),
    media_count=(select count(*) from futbeat_private.team_squad_player_ids(tid) s(id)
      join futbeat_private.entities e on e.id=s.id
      where futbeat_private.valid_player_media(e.payload->'media'))
  where c.team_id=tid;

  return result||jsonb_build_object(
    'duplicateRows',jsonb_array_length(p_players)-jsonb_array_length(kept),
    'identitiesMerged',merged);
end $$;

-- ---------------------------------------------------------------------------
-- Read: the team profile squad and its state count each person once.
-- ---------------------------------------------------------------------------

alter function futbeat_private.futbeat_read_entity_detail(text,text)
  rename to read_entity_detail_before_squad_dedup;
create function futbeat_private.futbeat_read_entity_detail(p_type text,p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare snap jsonb;
begin
  snap:=futbeat_private.read_entity_detail_before_squad_dedup(p_type,p_id);
  if snap is null or p_type<>'team' then return snap; end if;
  return snap||jsonb_build_object('players',(
    select coalesce(jsonb_agg(e.payload order by e.payload->>'position',e.payload->>'name',e.id),'[]'::jsonb)
    from futbeat_private.team_squad_player_ids(p_id) s(id)
    join futbeat_private.entities e on e.id=s.id and e.kind='player'));
end $$;

-- Copied from 20260929100000; only the player count changes.
create or replace function futbeat_private.team_squad_state(p_team_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare
  players integer;
  cov futbeat_private.team_detail_coverage;
  fresh_until timestamptz;
  state text;
  reason text;
begin
  select count(*)::integer into players
  from futbeat_private.team_squad_player_ids(p_team_id);
  select * into cov from futbeat_private.team_detail_coverage where team_id=p_team_id;
  fresh_until:=coalesce(cov.last_success_at,cov.fetched_at)+interval '7 days';
  if players>0 then
    state:=case when fresh_until>now() then 'AVAILABLE' else 'STALE' end;
  elsif cov.status='NO_DATA'
    and coalesce(cov.next_retry_at,cov.fetched_at+interval '30 days','-infinity')>now() then
    state:='CONFIRMED_EMPTY'; reason:='provider_no_data';
  elsif not futbeat_private.team_squad_mapped(p_team_id) then
    state:='UNAVAILABLE'; reason:='no_provider_source';
  else
    state:='PENDING';
    reason:=case
      when cov.team_id is null then 'never_fetched'
      when cov.lease_until>now() then 'in_flight'
      when cov.status='FETCH_FAILED' then 'retrying'
      when cov.status='NO_DATA' then 'revalidating'
      else 'queued' end;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'state',state,
    'reason',reason,
    'playerCount',players,
    'updatedAt',coalesce(cov.last_success_at,cov.fetched_at)));
end $$;

-- ---------------------------------------------------------------------------
-- Snapshots carry only the player redirects their players need.
-- ---------------------------------------------------------------------------

alter function futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb)
  rename to apply_entity_redirects_before_player_scope;
create function futbeat_private.futbeat_apply_entity_redirects_snapshot(p_snapshot jsonb)
returns jsonb language sql stable security definer set search_path='' as $$
  with base as (
    select futbeat_private.apply_entity_redirects_before_player_scope(p_snapshot) s
  ), ids as (
    select x->>'id' id
    from base,jsonb_array_elements(case when jsonb_typeof(base.s->'players')='array'
      then base.s->'players' else '[]'::jsonb end) x
  )
  select case when base.s is null then null else
    (base.s-'entityRedirects')||jsonb_build_object('entityRedirects',coalesce((
      select jsonb_object_agg(r.alias_id,r.canonical_id order by r.alias_id)
      from futbeat_private.entity_redirects r
      where r.kind<>'player'
        or r.alias_id in (select id from ids)
        or r.canonical_id in (select id from ids)),'{}'::jsonb))
  end
  from base
$$;

-- ---------------------------------------------------------------------------
-- Lineup/search bridge: a merged alias is never a second candidate.
-- ---------------------------------------------------------------------------

-- Copied from 20260923150000; only the redirected-alias exclusion is new.
create or replace function futbeat_private.bridge_player_identity(
  p_ext text, p_name text, p_team_external_id text
) returns text language sql stable set search_path='' as $$
  select case when count(*)=1 then min(candidate) end
  from (
    select distinct e.id candidate
    from futbeat_private.entities e
    join futbeat_private.provider_entities team_pe
      on team_pe.provider='goal_api' and team_pe.kind='team'
      and team_pe.external_id=p_team_external_id
      and team_pe.canonical_id=futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId')
    where e.kind='player'
      and nullif(p_team_external_id,'') is not null
      and nullif(futbeat_private.normalize_live_name(p_name),'') is not null
      and length(replace(futbeat_private.normalize_live_name(p_name),' ','')) >= 3
      and futbeat_private.normalize_live_name(e.payload->>'name')
        = futbeat_private.normalize_live_name(p_name)
      and not exists(
        select 1 from futbeat_private.entity_redirects r
        where r.alias_id=e.id and r.kind='player')
      and not exists(
        select 1 from futbeat_private.provider_entities pe2
        where pe2.canonical_id=e.id and pe2.provider='goal_api' and pe2.kind='player'
          and futbeat_private.player_external_id_is_numeric(pe2.external_id)
            = futbeat_private.player_external_id_is_numeric(p_ext)
      )
  ) candidates
$$;

-- ---------------------------------------------------------------------------
-- Grants: everything here is internal; public wrappers keep their grants.
-- ---------------------------------------------------------------------------

revoke all on function
  futbeat_private.player_name_tokens(text),
  futbeat_private.squad_shirt_number(jsonb),
  futbeat_private.same_squad_player(text[],integer,text[],integer),
  futbeat_private.player_identity_richness(jsonb),
  futbeat_private.squad_identity_duplicates(jsonb),
  futbeat_private.team_squad_duplicate_pairs(text),
  futbeat_private.team_squad_player_ids(text),
  futbeat_private.futbeat_merge_player_identity(text,text,text),
  futbeat_private.store_team_squad_before_identity_dedup(text,text,timestamptz,jsonb),
  futbeat_private.read_entity_detail_before_squad_dedup(text,text),
  futbeat_private.apply_entity_redirects_before_player_scope(jsonb),
  futbeat_private.bridge_player_identity(text,text,text)
from public,anon,authenticated,service_role;

revoke all on function
  futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text),
  futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb),
  futbeat_private.team_squad_state(text)
from public,anon,authenticated;
grant execute on function
  futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text),
  futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb)
to service_role;

notify pgrst,'reload schema';
