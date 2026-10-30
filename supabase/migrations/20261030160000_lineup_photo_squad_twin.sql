-- DATA 219: lineup photos through a verified squad twin (read-side only).
--
-- Evidence (DATA 218, production read-only 2026-10-30): GOAL lists one person
-- under two ids, the numeric lineup playerKey and the catalog id ("cmr7...")
-- of /teams/:id/players and search. harvest_lineup_players only bridges an id
-- it has never seen, so a lineup stub minted before the squad (or a squad row
-- stored after the stub) is never linked: 0/40 photos in the reference
-- League Cup match while 22 of those players have a VERIFIED photo on their
-- squad twin; 0/242 photos and 66 twins over six finished matches.
-- Photo hydration cannot fix it either: the search result is the catalog id,
-- which already belongs to the twin, so the photo lands there again.
--
-- D1 (no merge, no identity or history change). A lineup player without its
-- own valid photo shows the photo of exactly one squad twin:
--   * the lineup player has only numeric GOAL ids (a lineup/live stub);
--   * the twin is a member of the lineup player's team (payload.teamId,
--     aliases resolved) in that team's CURRENT squad answer (latest
--     updated_at), is not an alias, has no numeric GOAL id (else it is a
--     separate lineup identity) and carries a VERIFIED photo;
--   * names are equal under squad_name_key (accent folding, token order
--     free, >= 2 tokens); a one-token name also needs the same known shirt
--     number on both rows; known different shirt numbers never pair (the
--     twin's number counts only in its own team: payload.shirtNumber is the
--     club number, unknown in a national-team squad);
--   * unambiguous: exactly one "rich" member (photo or birth date) of that
--     squad answer has the key (sparse duplicate rows are tolerated, as in
--     team_squad_twin_aliases), and no other requested player of the same
--     team resolves to the same twin.
-- The result keeps canonicalId (links stay on the lineup identity) and adds
-- imageSource ('PLAYER' | 'SQUAD_TWIN') and twinCanonicalId. One set-based
-- statement per lineup: squads are read by team (team_squad_members_pkey),
-- never a scan of all players.
--
-- D2. futbeat_request_lineup_hydration skips the name-search discovery for a
-- numeric-only player whose photo D1 resolves: the search can only land on
-- the twin's id. Profile/stats hydration of players with a profile id is
-- unchanged. (futbeat-api already sends only players without an image, so
-- D1 alone removes them from the request; this keeps the RPC consistent.)

create or replace function futbeat_private.lineup_squad_photo_twins(p_player_ids text[])
returns table(player_id text, twin_id text, url text)
language sql stable security definer set search_path='' as $$
  with req as (
    select distinct e.id,e.payload,
      futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId') team_id
    from unnest(coalesce(p_player_ids,array[]::text[])) ids(id)
    join futbeat_private.entities e on e.id=ids.id and e.kind='player'
    where cardinality(p_player_ids)<=100
      and not futbeat_private.valid_player_media(e.payload->'media')
      and nullif(e.payload->>'teamId','') is not null
      and exists(select 1 from futbeat_private.provider_entities pe
        where pe.canonical_id=e.id and pe.provider='goal_api' and pe.kind='player')
      and not exists(select 1 from futbeat_private.provider_entities pe
        where pe.canonical_id=e.id and pe.provider='goal_api' and pe.kind='player'
          and not futbeat_private.player_external_id_is_numeric(pe.external_id))
  ), keyed as (
    select r.id,r.team_id,
      futbeat_private.squad_name_key(r.payload->>'name') name_key,
      btrim(regexp_replace(translate(lower(coalesce(r.payload->>'name','')),
        'áàäâãåéèëêíìïîóòöôõúùüûñçý','aaaaaaeeeeiiiiooooouuuuncy'),'[[:space:].''’`´-]+',' ','g')) mono,
      futbeat_private.squad_shirt_number(r.payload->'shirtNumber') shirt
    from req r
  ), current_squad as (
    select sm.team_id,sm.player_id,e.payload
    from (select distinct team_id from keyed where team_id is not null) t
    join lateral (
      select m.team_id,m.player_id,m.updated_at,max(m.updated_at) over () latest
      from futbeat_private.team_squad_members m where m.team_id=t.team_id
    ) sm on sm.updated_at=sm.latest
    join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
    where not exists(select 1 from futbeat_private.entity_redirects x
      where x.alias_id=sm.player_id and x.kind='player')
  ), members as (
    select c.team_id,c.player_id,c.payload,
      futbeat_private.squad_name_key(c.payload->>'name') name_key,
      btrim(regexp_replace(translate(lower(coalesce(c.payload->>'name','')),
        'áàäâãåéèëêíìïîóòöôõúùüûñçý','aaaaaaeeeeiiiiooooouuuuncy'),'[[:space:].''’`´-]+',' ','g')) mono,
      -- payload.shirtNumber is the club number: it only speaks for the
      -- player's own team (a national-team squad leaves it unknown).
      case when futbeat_private.futbeat_resolve_entity_id('team',c.payload->>'teamId')=c.team_id
        then futbeat_private.squad_shirt_number(c.payload->'shirtNumber') end shirt,
      futbeat_private.squad_player_rich(c.payload) rich,
      futbeat_private.valid_player_media(c.payload->'media') photo
    from current_squad c
  ), pairs as (
    select k.id,k.team_id,m.player_id twin_id,m.payload,m.rich,m.photo
    from keyed k
    join members m on m.team_id=k.team_id and m.player_id<>k.id
      and (k.name_key is not null and m.name_key=k.name_key
        or k.name_key is null and m.name_key is null and k.mono ~ '^[a-z0-9]{4,}$' and m.mono=k.mono
          and k.shirt is not null and m.shirt=k.shirt)
      and not (k.shirt is not null and m.shirt is not null and k.shirt<>m.shirt)
  ), unique_twin as (
    select p.id,p.team_id,min(p.twin_id) filter (where p.rich) twin_id
    from pairs p
    group by p.id,p.team_id
    having count(*) filter (where p.rich)=1
  ), safe as (
    select u.id,u.twin_id,m.payload#>>'{media,url}' url
    from unique_twin u
    join pairs m on m.id=u.id and m.twin_id=u.twin_id and m.photo
    where not exists(select 1 from futbeat_private.provider_entities pe
        where pe.canonical_id=u.twin_id and pe.provider='goal_api' and pe.kind='player'
          and futbeat_private.player_external_id_is_numeric(pe.external_id))
  )
  select s.id,s.twin_id,s.url from safe s
  where (select count(*) from safe o where o.twin_id=s.twin_id)=1
$$;

create or replace function futbeat_private.futbeat_read_lineup_player_media(p_provider text,p_external_ids text[])
returns jsonb language sql stable security definer set search_path='' as $$
 with ids as (
   select ids.ext,e.id,e.payload
   from (select distinct unnest(p_external_ids) ext) ids
   left join futbeat_private.provider_entities pe on pe.provider=p_provider and pe.kind='player' and pe.external_id=ids.ext
   left join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) and e.kind='player'
   where p_provider='goal_api' and cardinality(p_external_ids)<=100 and nullif(ids.ext,'') is not null
 ), twins as (
   select t.player_id,t.twin_id,t.url
   from futbeat_private.lineup_squad_photo_twins((select array_agg(distinct id) from ids where id is not null)) t
 )
 select coalesce(jsonb_object_agg(r.ext,jsonb_build_object('providerId',r.ext,'canonicalId',r.id,'image',r.image)
   || jsonb_strip_nulls(jsonb_build_object('imageSource',r.source,'twinCanonicalId',r.twin_id))),'{}')
 from (
   select ids.ext,ids.id,
     case when own then ids.payload#>>'{media,url}' else t.url end image,
     case when own then 'PLAYER' when t.url is not null then 'SQUAD_TWIN' end source,
     case when not own then t.twin_id end twin_id
   from (select ids.*,futbeat_private.valid_player_media(ids.payload->'media') own from ids) ids
   left join twins t on t.player_id=ids.id
 ) r
$$;

create or replace function public.futbeat_request_lineup_hydration(p_starter_ids text[] default null::text[], p_bench_ids text[] default null::text[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  pid text; v_priority smallint; ext text; due jsonb; player_name text; discovery jsonb;
  previous timestamptz; lease_at timestamptz;
  any_pending boolean:=false; should_wake boolean:=false; discovery_demands integer:=0;
  twin_resolved text[];
begin
  -- D2 (DATA 219): players whose photo a verified squad twin already provides.
  select coalesce(array_agg(t.player_id),array[]::text[]) into twin_resolved
  from futbeat_private.lineup_squad_photo_twins(
    (select array_agg(x) from (
      select unnest(coalesce(p_starter_ids,array[]::text[])) x
      union select unnest(coalesce(p_bench_ids,array[]::text[]))) z
     where x is not null and x<>'' limit 100)) t;
  for pid,v_priority in
    select s.player_id,s.priority from (
      select unnest(coalesce(p_starter_ids,array[]::text[])) player_id,1::smallint priority
      union all
      select unnest(coalesce(p_bench_ids,array[]::text[])),2::smallint
    ) s
    where s.player_id is not null and s.player_id<>''
    limit 60
  loop
    select external_id into ext from futbeat_private.provider_entities
    where provider='goal_api' and kind='player' and canonical_id=pid
    order by futbeat_private.player_external_id_is_numeric(external_id),external_id
    limit 1;
    if ext is null then continue; end if;

    due:=futbeat_private.player_hydration_due(pid);
    -- This lane is photo hydration (profile data), not stats -- unchanged
    -- from before this migration: only profileDue gates it, never statsDue.
    if not coalesce((due->>'profileDue')::boolean,false) then continue; end if;

    if not coalesce((due->>'profileIdReady')::boolean,false) then
      -- D2: the search would only return the twin's catalog id; the photo is
      -- already shown through that twin. No discovery demand, no GOAL call.
      if pid=any(twin_resolved) then
        perform futbeat_private.bump_metric('lineup_twin_photo_discovery_skipped');
        continue;
      end if;
      -- Only a numeric (lineup/live-only) id is known: /players/:id would
      -- 404 on it. Discover the profile-compatible id via the existing
      -- search pipeline (name-only query; bridge_player_identity links a
      -- matching result back to THIS canonical player, never by name alone
      -- -- team context is verified when the result arrives). Bounded per
      -- call: a busy lineup must not burst the shared search admission
      -- budget (60 admissions / 5 minutes, shared with user-typed search).
      if discovery_demands<5 then
        select payload->>'name' into player_name from futbeat_private.entities where id=pid and kind='player';
        if nullif(btrim(coalesce(player_name,'')),'') is not null then
          discovery:=futbeat_private.note_player_search_demand(player_name);
          discovery_demands:=discovery_demands+1;
          if coalesce((discovery->>'pending')::boolean,false) then any_pending:=true; end if;
        end if;
      end if;
      continue;
    end if;

    if not coalesce((futbeat_private.quota_decision('goal_api','player-profile','user')->>'allowed')::boolean,false) then
      continue;
    end if;

    -- Still due and quota-allowed: pending regardless of whether THIS call
    -- deduped against an earlier request for the same player (matching
    -- futbeat_request_player_profile's own pending semantics) — otherwise
    -- the client's bounded refresh sees enrichmentPending:false and stops
    -- retrying while the player is still genuinely queued.
    any_pending:=true;

    select requested_at,lease_until into previous,lease_at
    from futbeat_private.player_profile_coverage where player_id=pid;
    insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count,priority)
    values(pid,ext,now(),1,v_priority)
    on conflict(player_id) do update set
      requested_at=now(),
      external_id=excluded.external_id,
      request_count=futbeat_private.player_profile_coverage.request_count+1,
      priority=least(futbeat_private.player_profile_coverage.priority,excluded.priority);

    if lease_at>now() or previous>now()-interval '1 minute' then
      perform futbeat_private.bump_metric('deduped_requests');
    else
      perform futbeat_private.bump_metric('lineup_player_hydration_demands');
      should_wake:=true;
    end if;
  end loop;

  if should_wake then perform futbeat_private.wake_provider_worker('demand'); end if;
  return jsonb_build_object('enrichmentPending',any_pending);
end
$$;

revoke all on function futbeat_private.lineup_squad_photo_twins(text[]) from public,anon,authenticated,service_role;
