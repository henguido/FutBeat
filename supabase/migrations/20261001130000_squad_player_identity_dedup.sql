-- One real person = one row in a team's squad.
--
-- Root cause (production, read-only diagnosis 2026-10-01): GOAL's
-- /teams/:id/players answer can list the SAME person twice under two catalog
-- ids from two GOAL catalog batches: a complete record ("Pablo Arboine",
-- photo, birth date, stats) and a sparse twin with the name tokens in another
-- order ("Arboine Pablo", no photo/birth date/age), same shirt number.
-- Squad ingestion canonicalizes players strictly by provider id, so each id
-- became its own canonical player and both joined team_squad_members.
--
-- Fix: READ-SIDE ONLY, conservative, no automatic data merge.
--   A member is hidden from the squad as the sparse twin of another member
--   only when ALL hold (squad_twin_key / team_squad_twin_aliases):
--     * same team, written by the SAME squad answer (equal updated_at), so a
--       stale retained member never pairs with a current one;
--     * same KNOWN shirt number (1..999; 0/blank is unknown, never matched);
--     * identical name token MULTISETS (order-free); names are folded with an
--       explicit accent list and a name with any other character (Đ, ł, ø,
--       non-Latin scripts...) is not comparable; at least 2 tokens;
--     * exactly two members share that (fetch, number, name multiset) and one
--       is sparse (no verified photo, no birth date, no age) while the other
--       is rich (verified photo or birth date). Groups of 3+, two sparse or
--       two rich rows are never collapsed.
--   Subset names ("Juan Perez" vs "Juan Carlos Perez Lopez") are never
--   collapsed: they are indistinguishable from two different people.
--   Twins are found when a squad answer is stored (grouping, no pairwise
--   scan) and kept in team_squad_twins; reads only consult that table and
--   hide a twin only while the evidence still holds (rich partner still a
--   member of the team, hidden row still sparse).
--
-- Ingestion keeps storing every provider row; it only stores ONE row when two
-- rows resolve to the same canonical player (already the same identity), and
-- such a row never renames that identity.
--
-- Data merges are an operator tool only: futbeat_merge_player_identity (with a
-- per-merge audit row holding everything needed to undo it) and the guarded
-- manual script supabase/manual/2026-10-01_squad_player_identity_merge.sql,
-- whose candidates are exactly the pairs this read rule hides.

-- ---------------------------------------------------------------------------
-- Player redirects (used only by the operator merge tool).
-- ---------------------------------------------------------------------------

do $$
declare c record; remaining integer;
begin
  for c in
    select con.conname
    from pg_catalog.pg_constraint con
    where con.conrelid='futbeat_private.entity_redirects'::regclass
      and con.contype='c'
      and pg_catalog.pg_get_constraintdef(con.oid) ~ '\mkind\M'
  loop
    execute format('alter table futbeat_private.entity_redirects drop constraint %I',c.conname);
  end loop;
  alter table futbeat_private.entity_redirects
    add constraint entity_redirects_kind_check
    check(kind in ('competition','team','player'));
  select count(*) into remaining
  from pg_catalog.pg_constraint con
  where con.conrelid='futbeat_private.entity_redirects'::regclass
    and con.contype='c'
    and pg_catalog.pg_get_constraintdef(con.oid) ~ '\mkind\M';
  if remaining<>1 then
    raise exception 'entity_redirects must have exactly one kind check, found %',remaining;
  end if;
end $$;

-- Audit of every operator merge: everything needed to undo it.
create table futbeat_private.player_identity_merges (
  id bigint generated always as identity primary key,
  alias_id text not null,
  canonical_id text not null,
  reason text not null,
  merged_at timestamptz not null default now(),
  alias_payload jsonb not null,
  canonical_payload_before jsonb not null,
  moved_provider_ids text[] not null default '{}',
  moved_media_cache text[] not null default '{}',
  moved_memberships jsonb not null default '[]',
  moved_follows jsonb not null default '[]',
  moved_interests jsonb not null default '[]',
  redirected_aliases text[] not null default '{}'
);
alter table futbeat_private.player_identity_merges enable row level security;
revoke all on futbeat_private.player_identity_merges from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- The conservative twin rule.
-- ---------------------------------------------------------------------------

-- Order-free name key, or null when the name is not safely comparable.
create function futbeat_private.squad_name_key(p_name text)
returns text language sql immutable set search_path='' as $$
  with folded as (
    select btrim(regexp_replace(translate(lower(coalesce(p_name,'')),
      'áàäâãåéèëêíìïîóòöôõúùüûñçý',
      'aaaaaaeeeeiiiiooooouuuuncy'),
      '[[:space:].''’`´-]+',' ','g')) s
  ), tokens as (
    select array(select t from unnest(string_to_array(s,' ')) t where t<>'' order by t) toks
    from folded where s ~ '^[a-z0-9 ]+$'
  )
  select case when cardinality(toks)>=2 then array_to_string(toks,' ') end from tokens
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

-- sparse: nothing that identifies the person beyond the name.
create function futbeat_private.squad_player_sparse(p jsonb)
returns boolean language sql immutable set search_path='' as $$
  select not futbeat_private.valid_player_media(p->'media')
    and coalesce(btrim(p->>'dateOfBirth'),'')=''
    and coalesce(btrim(p->>'age'),'')=''
$$;

create function futbeat_private.squad_player_rich(p jsonb)
returns boolean language sql immutable set search_path='' as $$
  select futbeat_private.valid_player_media(p->'media')
    or coalesce(btrim(p->>'dateOfBirth'),'')<>''
$$;

-- Sparse twins hidden from a team's squad, with the member they duplicate.
create function futbeat_private.team_squad_twin_aliases(p_team_id text)
returns table(alias_id text,canonical_id text)
language sql stable set search_path='' as $$
  with members as (
    select sm.updated_at,e.id,
      futbeat_private.squad_shirt_number(e.payload->'shirtNumber') shirt,
      futbeat_private.squad_name_key(e.payload->>'name') name_key,
      futbeat_private.squad_player_sparse(e.payload) sparse,
      futbeat_private.squad_player_rich(e.payload) rich
    from futbeat_private.team_squad_members sm
    join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
    where sm.team_id=p_team_id
      and not exists(select 1 from futbeat_private.entity_redirects r
        where r.alias_id=sm.player_id and r.kind='player')
  ), groups as (
    select
      min(id) filter (where sparse) alias_id,
      min(id) filter (where rich and not sparse) canonical_id
    from members
    where shirt is not null and name_key is not null
    group by updated_at,shirt,name_key
    having count(*)=2
      and count(*) filter (where sparse)=1
      and count(*) filter (where rich and not sparse)=1
  )
  select alias_id,canonical_id from groups
$$;

-- Twins found when a squad answer is stored (the evidence is that answer).
-- Reads only consult this small table: no per-read pairing work.
create table futbeat_private.team_squad_twins (
  team_id text not null,
  alias_id text not null,
  canonical_id text not null,
  computed_at timestamptz not null default now(),
  primary key(team_id,alias_id)
);
alter table futbeat_private.team_squad_twins enable row level security;
revoke all on futbeat_private.team_squad_twins from public,anon,authenticated;

create function futbeat_private.refresh_team_squad_twins(p_team_id text)
returns integer language plpgsql security definer set search_path='' as $$
declare n integer;
begin
  -- Two concurrent stores of one team never interleave their refreshes.
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('squad-twins:'||p_team_id,0));
  delete from futbeat_private.team_squad_twins where team_id=p_team_id;
  insert into futbeat_private.team_squad_twins(team_id,alias_id,canonical_id)
  select p_team_id,alias_id,canonical_id
  from futbeat_private.team_squad_twin_aliases(p_team_id)
  on conflict(team_id,alias_id) do nothing;
  get diagnostics n=row_count;
  return n;
end $$;

-- Every stored squad today (no provider call; same rule as ingestion).
do $$
declare t record;
begin
  for t in select distinct team_id from futbeat_private.team_squad_members loop
    perform futbeat_private.refresh_team_squad_twins(t.team_id);
  end loop;
end $$;

-- Twins hidden right now: the stored evidence, still true live. A twin is
-- hidden only while its rich partner is still a member of this team and the
-- hidden row is still sparse. Rows stored under a team alias (team
-- redirects move memberships, not twins) count for the canonical team.
-- Single source of truth for the read and the manual merge script.
create function futbeat_private.team_squad_hidden_twins(p_team_id text)
returns table(alias_id text,canonical_id text)
language sql stable set search_path='' as $$
  select t.alias_id,t.canonical_id
  from futbeat_private.team_squad_twins t
  join futbeat_private.team_squad_members alias_sm
    on alias_sm.team_id=p_team_id and alias_sm.player_id=t.alias_id
  join futbeat_private.team_squad_members partner_sm
    on partner_sm.team_id=p_team_id and partner_sm.player_id=t.canonical_id
  join futbeat_private.entities e on e.id=t.alias_id and e.kind='player'
  where t.team_id=any(futbeat_private.team_identity_ids(p_team_id))
    and futbeat_private.squad_player_sparse(e.payload)
    and not exists(select 1 from futbeat_private.entity_redirects r
      where r.kind='player' and r.alias_id in (t.alias_id,t.canonical_id))
$$;

-- The squad as users see it: canonical players, sparse twins hidden.
create function futbeat_private.team_squad_player_ids(p_team_id text)
returns setof text language sql stable set search_path='' as $$
  with hidden as materialized (
    select alias_id from futbeat_private.team_squad_hidden_twins(p_team_id)
  ), members as materialized (
    select distinct futbeat_private.futbeat_resolve_entity_id('player',sm.player_id) id
    from futbeat_private.team_squad_members sm
    where sm.team_id=p_team_id
      and not exists(select 1 from hidden h where h.alias_id=sm.player_id)
  )
  select e.id
  from members m
  join futbeat_private.entities e on e.id=m.id and e.kind='player'
$$;

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
-- Ingestion: two rows of ONE canonical player are stored once; never merges.
-- ---------------------------------------------------------------------------

-- How much a row really knows (higher = richer).
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

alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  rename to store_team_squad_before_identity_dedup;
create function futbeat_private.futbeat_store_team_squad(
  p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  kept jsonb; result jsonb;
begin
  if jsonb_typeof(p_players) is distinct from 'array' then
    return futbeat_private.store_team_squad_before_identity_dedup(p_team_id,p_provider,p_received_at,p_players);
  end if;
  with items as (
    select x.ord,x.item,nullif(btrim(x.item#>>'{provenance,externalId}'),'') ext
    from jsonb_array_elements(p_players) with ordinality x(item,ord)
  ), resolved as (
    select i.*,coalesce(e.id,'#'||i.ord) pid,e.payload old
    from items i
    left join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='player' and pe.external_id=i.ext
    left join futbeat_private.entities e
      on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) and e.kind='player'
  ), scored as (
    select rs.*,
      futbeat_private.player_identity_richness(
        coalesce(rs.old,'{}'::jsonb)||jsonb_strip_nulls(rs.item)) score,
      coalesce(rs.old#>>'{provenance,externalId}'=rs.ext,false) est
    from resolved rs
  ), per_player as (
    select distinct on (s.pid) s.*
    from scored s
    order by s.pid,s.est desc,s.score desc,s.ext,s.ord
  )
  select coalesce(jsonb_agg(
      -- A second provider row of an identity never renames it while the
      -- established provider id still maps to it.
      case when not p.est and coalesce(btrim(p.old->>'name'),'')<>''
        and exists(select 1 from futbeat_private.provider_entities pe
          where pe.provider='goal_api' and pe.kind='player'
            and pe.external_id=p.old#>>'{provenance,externalId}'
            and futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)=p.pid)
      then p.item||jsonb_build_object('name',p.old->'name',
        'shortName',coalesce(p.old->'shortName',p.item->'shortName','""'::jsonb))
      else p.item end
      order by p.ord),'[]'::jsonb)
  into kept
  from per_player p;

  result:=futbeat_private.store_team_squad_before_identity_dedup(p_team_id,p_provider,p_received_at,kept);
  if result->>'status' in ('ignored_older','ignored_older_players') then
    return result;
  end if;

  perform futbeat_private.refresh_team_squad_twins(tid);
  -- Counts describe the squad users see.
  update futbeat_private.team_detail_coverage c set
    player_count=(select count(*) from futbeat_private.team_squad_player_ids(tid)),
    media_count=(select count(*) from futbeat_private.team_squad_player_ids(tid) s(id)
      join futbeat_private.entities e on e.id=s.id
      where futbeat_private.valid_player_media(e.payload->'media'))
  where c.team_id=tid;

  return result||jsonb_build_object(
    'duplicateRows',jsonb_array_length(p_players)-jsonb_array_length(kept));
end $$;

-- ---------------------------------------------------------------------------
-- Operator merge tool (never called by ingestion or reads).
-- ---------------------------------------------------------------------------

-- Redirects p_alias_id to p_canonical_id. Never deletes an entity. Refuses
-- conflicting birth dates. Every change is recorded in player_identity_merges.
create function futbeat_private.futbeat_merge_player_identity(
  p_alias_id text,p_canonical_id text,p_reason text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_target text; v_alias jsonb; v_canonical jsonb; v_next jsonb; v_key text;
  v_aliases jsonb; v_name text; v_team text; v_interests integer:=0;
  v_provider text[]; v_media text[]; v_members jsonb; v_follows jsonb;
  v_temp jsonb; v_redirected text[];
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
  -- Wrong direction: the kept identity must not be a known sparse twin.
  if exists(select 1 from futbeat_private.team_squad_twins where alias_id=v_target) then
    raise exception 'Player merge refused: target % is a hidden sparse twin; merge it into its rich partner instead',v_target;
  end if;
  if coalesce(btrim(v_alias->>'dateOfBirth'),'')<>''
     and coalesce(btrim(v_canonical->>'dateOfBirth'),'')<>''
     and btrim(v_alias->>'dateOfBirth')<>btrim(v_canonical->>'dateOfBirth') then
    raise exception 'Player merge refused: conflicting birth dates';
  end if;

  -- Capture what moves (audit / undo).
  select coalesce(array_agg(external_id order by external_id),'{}') into v_provider
  from futbeat_private.provider_entities where kind='player' and canonical_id=p_alias_id;
  select coalesce(array_agg(provider||':'||external_id order by provider,external_id),'{}') into v_media
  from futbeat_private.provider_media_cache where kind='player' and canonical_id=p_alias_id;
  -- keptHad*: the kept player already had that row (undo must keep it).
  select coalesce(jsonb_agg(to_jsonb(sm)||jsonb_build_object('keptHadMembership',exists(
      select 1 from futbeat_private.team_squad_members k
      where k.team_id=sm.team_id and k.player_id=v_target))),'[]') into v_members
  from futbeat_private.team_squad_members sm where sm.player_id=p_alias_id;
  select coalesce(jsonb_agg(to_jsonb(f)||jsonb_build_object('keptHadFollow',exists(
      select 1 from futbeat_private.push_follows k
      where k.user_id=f.user_id and k.entity_type='player' and k.entity_id=v_target))),'[]') into v_follows
  from futbeat_private.push_follows f where f.entity_type='player' and f.entity_id=p_alias_id;
  select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('keptHadInterest',exists(
      select 1 from futbeat_private.temporary_interests k
      where k.user_id=t.user_id and k.entity_type='player' and k.entity_id=v_target))),'[]') into v_temp
  from futbeat_private.temporary_interests t where t.entity_type='player' and t.entity_id=p_alias_id;
  select coalesce(array_agg(alias_id order by alias_id),'{}') into v_redirected
  from futbeat_private.entity_redirects where kind='player' and canonical_id=p_alias_id;

  insert into futbeat_private.player_identity_merges(
    alias_id,canonical_id,reason,alias_payload,canonical_payload_before,
    moved_provider_ids,moved_media_cache,moved_memberships,moved_follows,moved_interests,
    redirected_aliases)
  values(p_alias_id,v_target,left(btrim(p_reason),500),v_alias,v_canonical,
    v_provider,v_media,v_members,v_follows,v_temp,v_redirected);

  insert into futbeat_private.entity_redirects(alias_id,canonical_id,kind,reason,created_at)
  values(p_alias_id,v_target,'player',left(btrim(p_reason),500),now());
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

  -- Membership: only the kept player's current team gains it.
  v_team:=futbeat_private.futbeat_resolve_entity_id('team',nullif(v_next->>'teamId',''));
  insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
  select team_id,v_target,provider,updated_at
  from futbeat_private.team_squad_members
  where player_id=p_alias_id and team_id=v_team
  on conflict(team_id,player_id) do update
    set updated_at=greatest(futbeat_private.team_squad_members.updated_at,excluded.updated_at);
  delete from futbeat_private.team_squad_members where player_id=p_alias_id;
  delete from futbeat_private.team_squad_twins
  where alias_id=p_alias_id or canonical_id=p_alias_id;

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
  futbeat_private.squad_name_key(text),
  futbeat_private.squad_shirt_number(jsonb),
  futbeat_private.squad_player_sparse(jsonb),
  futbeat_private.squad_player_rich(jsonb),
  futbeat_private.team_squad_twin_aliases(text),
  futbeat_private.refresh_team_squad_twins(text),
  futbeat_private.team_squad_hidden_twins(text),
  futbeat_private.team_squad_player_ids(text),
  futbeat_private.player_identity_richness(jsonb),
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
