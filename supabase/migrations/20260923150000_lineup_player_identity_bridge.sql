-- Lineup player identity bridge.
--
-- GOAL uses TWO disjoint player id namespaces: match-detail/lineup rows
-- carry a purely numeric provider id (e.g. "1343925596"), while player
-- search/profile/statistics and squad ingestion use a catalog-style string
-- id (e.g. "cmr7..."). Calling GOAL_PLAYER_ENDPOINTS.profile with the
-- numeric lineup id 404s -- confirmed in production. futbeat_resolve_global
-- _entity deliberately never matches players by name (player_on_demand.sql:
-- "Found players are canonicalized strictly by provider id (never by
-- name)"), so a lineup-discovered canonical player and a later
-- search-discovered one for the SAME real person previously became two
-- separate canonical entities whenever their external ids differed, and
-- lineup hydration kept sending the numeric id to /players/:id forever.
--
-- Bridge: when a NEW catalog-style search result arrives for a player whose
-- normalized name AND current team (verified via provider_entities, never
-- supplied by the caller) match EXACTLY ONE existing lineup-only canonical
-- player (one with no profile-compatible id yet), that search id is aliased
-- onto the SAME canonical player instead of minting a new one. Ambiguous or
-- team-unverified matches are never merged: futbeat_resolve_global_entity's
-- own player rule stands, a search id with no unambiguous bridge target
-- gets its own new canonical player exactly as before. Until a bridge (or a
-- direct search) resolves the profile-compatible id, hydration registers a
-- name-based discovery demand through the EXISTING search pipeline instead
-- of calling /players/:id with an id that would 404.

-- GOAL's live/lineup player ids are purely numeric; search/profile/squad ids
-- are not (e.g. "cmr7..."). This is the only distinguishing evidence
-- available locally, and it is exactly the evidence production surfaced
-- (the numeric id 404s on /players/:id, the catalog id does not).
create or replace function futbeat_private.player_external_id_is_numeric(p_external_id text)
returns boolean language sql immutable set search_path='' as $$
  select p_external_id ~ '^[0-9]+$'
$$;

-- Exactly one existing lineup-only canonical player matching name + a
-- verified current team, or null (no match, or ambiguous -- never guessed).
create or replace function futbeat_private.bridge_lineup_player_identity(
  p_name text, p_team_external_id text
) returns text language sql stable set search_path='' as $$
  select case when count(*)=1 then min(candidate) end
  from (
    select distinct e.id candidate
    from futbeat_private.entities e
    join futbeat_private.provider_entities pe
      on pe.canonical_id=e.id and pe.provider='goal_api' and pe.kind='player'
    where e.kind='player'
      and nullif(p_name,'') is not null
      and nullif(p_team_external_id,'') is not null
      and futbeat_private.normalize_live_name(e.payload->>'name')
        = futbeat_private.normalize_live_name(p_name)
      -- Only a still-numeric-only identity is a bridge candidate; an
      -- already-bridged player is found by its own real id, never re-matched.
      and not exists(
        select 1 from futbeat_private.provider_entities pe2
        where pe2.canonical_id=e.id and pe2.provider='goal_api' and pe2.kind='player'
          and not futbeat_private.player_external_id_is_numeric(pe2.external_id)
      )
      and exists(
        select 1 from futbeat_private.provider_entities team_pe
        where team_pe.provider='goal_api' and team_pe.kind='team'
          and team_pe.external_id=p_team_external_id
          and team_pe.canonical_id=futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId')
      )
  ) candidates
$$;

-- Same signature/behavior as before; one new branch: a brand-new
-- catalog-style search id that bridges to an existing lineup-only canonical
-- player reuses that player's id instead of minting a new one.
create or replace function futbeat_private.upsert_goal_player(p_item jsonb,p_source text,p_received timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ext text:=nullif(btrim(p_item->>'externalId'),''); name text:=nullif(btrim(p_item->>'name'),'');
  existed boolean; pid text; old jsonb; next jsonb; key text; value jsonb; team_id text; squad boolean; url text;
  bridge_pid text;
begin
  if ext is null or p_source not in ('search','profile') then return null; end if;
  existed:=exists(select 1 from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=ext);
  if not existed and name is null then return null; end if;
  if not existed and p_source='search' and not futbeat_private.player_external_id_is_numeric(ext) then
    bridge_pid:=futbeat_private.bridge_lineup_player_identity(name,p_item->>'teamExternalId');
  end if;
  if bridge_pid is not null then
    perform pg_catalog.pg_advisory_xact_lock(hashtextextended('player:goal_api:'||ext,0));
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values('goal_api','player',ext,bridge_pid) on conflict do nothing;
    pid:=bridge_pid;
    perform futbeat_private.bump_metric('lineup_identity_bridged');
  else
    pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,coalesce(name,''),
      coalesce(p_item->>'country',''),coalesce(p_item->>'shortName',''));
  end if;
  select payload into old from futbeat_private.entities where id=pid and kind='player' for update;
  if old is null then return null; end if;
  next:=old;
  squad:=exists(select 1 from futbeat_private.team_squad_members where player_id=pid);
  foreach key in array array['name','shortName','country','dateOfBirth','age','height','preferredFoot'] loop
    value:=p_item->key;
    if value is null or value='null'::jsonb or value='""'::jsonb then continue; end if;
    -- A stored squad also writes these facts: only fill what it lacks, so the
    -- two sources never flip-flop.
    if p_source='profile' and not squad and key not in ('name','shortName')
       or coalesce(btrim(next->>key),'')='' then
      next:=next||jsonb_build_object(key,value);
    end if;
  end loop;
  if not squad then
    if coalesce(next->>'teamId','')='' and nullif(p_item->>'teamExternalId','') is not null then
      select canonical_id into team_id from futbeat_private.provider_entities
      where provider='goal_api' and kind='team' and external_id=p_item->>'teamExternalId';
      if team_id is not null then
        next:=next||jsonb_build_object('teamId',futbeat_private.futbeat_resolve_entity_id('team',team_id));
      end if;
    end if;
    if coalesce(btrim(next->>'position'),'')='' and coalesce(btrim(p_item->>'position'),'')<>'' then
      next:=next||jsonb_build_object('position',p_item->'position');
    end if;
    if jsonb_typeof(next->'shirtNumber') is distinct from 'number' and jsonb_typeof(p_item->'shirtNumber')='number' then
      next:=next||jsonb_build_object('shirtNumber',p_item->'shirtNumber');
    end if;
  end if;
  url:=p_item->>'photo';
  if futbeat_private.futbeat_valid_goal_player_media_url(url,'GOAL API')
     and not futbeat_private.valid_player_media(old->'media') then
    next:=jsonb_set(next,'{media}',jsonb_build_object('url',url,'kind','PLAYER_PHOTO','source','GOAL API',
      'externalId',ext,'receivedAt',p_received,'verificationStatus','VERIFIED','rightsStatus','REVIEW_REQUIRED',
      'usageScope','DEVELOPMENT_ONLY','discoveredVia','player_'||p_source),true);
  end if;
  if next->'provenance' is null then
    next:=next||jsonb_build_object('provenance',jsonb_build_object('source','GOAL API','externalId',ext,
      'receivedAt',p_received,'verificationStatus','PROVISIONAL'));
  end if;
  if next is distinct from old then
    update futbeat_private.entities set payload=next where id=pid and kind='player';
  end if;
  return jsonb_build_object('id',pid,'created',not existed,
    'gained',(select count(*) from jsonb_each(next) n where not (old ? n.key) or old->n.key is distinct from n.value));
end $$;

-- Same output keys as before, plus profileIdReady: whether a
-- profile-compatible (non-numeric) external id is known yet. profileDue can
-- be true while profileIdReady is false (a numeric-only lineup identity that
-- is missing profile facts) -- callers must not call /players/:id in that
-- case; they register discovery demand instead (see below).
create or replace function futbeat_private.player_hydration_due(p_player_id text)
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object(
    'profileDue',coalesce(c.profile_next_retry_at,'-infinity')<=now()
      and (c.profile_fetched_at is not null
        or coalesce(e.payload->>'dateOfBirth','')='' or coalesce(e.payload->>'country','')=''
        or coalesce(e.payload->>'position','')='' or coalesce(e.payload->>'height','')=''
        or not futbeat_private.valid_player_media(e.payload->'media')),
    'statsDue',coalesce(c.stats_next_retry_at,'-infinity')<=now()
      -- A fresh squad already carries this season's numbers.
      and not (e.payload ? 'matchesPlayed' and e.payload->'seasonStats' is null and exists(
        select 1 from futbeat_private.team_detail_coverage t
        where t.team_id=e.payload->>'teamId' and t.last_success_at>now()-interval '7 days')),
    'profileIdReady',exists(
      select 1 from futbeat_private.provider_entities pe
      where pe.canonical_id=p_player_id and pe.provider='goal_api' and pe.kind='player'
        and not futbeat_private.player_external_id_is_numeric(pe.external_id)))
  from futbeat_private.entities e
  left join futbeat_private.player_profile_coverage c on c.player_id=e.id
  where e.id=p_player_id and e.kind='player'
$$;

create or replace function public.futbeat_request_lineup_hydration(
  p_starter_ids text[] default null,
  p_bench_ids text[] default null
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  pid text; v_priority smallint; ext text; due jsonb; player_name text;
  previous timestamptz; lease_at timestamptz;
  any_pending boolean:=false; should_wake boolean:=false;
begin
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
    if not coalesce((due->>'profileDue')::boolean,false) then continue; end if;

    if not coalesce((due->>'profileIdReady')::boolean,false) then
      -- Only a numeric (lineup/live-only) id is known: /players/:id would
      -- 404 on it. Discover the profile-compatible id via the existing
      -- search pipeline (name-only query; bridge_lineup_player_identity
      -- links a matching result back to THIS canonical player, never by
      -- name alone -- team context is verified when the result arrives).
      select payload->>'name' into player_name from futbeat_private.entities where id=pid and kind='player';
      if nullif(btrim(coalesce(player_name,'')),'') is not null then
        any_pending:=true;
        perform futbeat_private.note_player_search_demand(player_name);
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

-- A user actively viewing a player's own screen always outranks lineup
-- hydration for the same player (priority 0 < lineup's 1/2 < default 100).
create or replace function public.futbeat_request_player_profile(p_player_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ext text; due jsonb; previous timestamptz; lease timestamptz; pending boolean; player_name text;
begin
  select external_id into ext from futbeat_private.provider_entities
  where provider='goal_api' and kind='player' and canonical_id=p_player_id
  order by futbeat_private.player_external_id_is_numeric(external_id),external_id
  limit 1;
  if ext is null then return jsonb_build_object('enrichmentPending',false,'reason','unmapped'); end if;
  due:=futbeat_private.player_hydration_due(p_player_id);
  if not coalesce((due->>'profileIdReady')::boolean,false) then
    -- Same numeric-id-only situation as lineup hydration: discover the
    -- profile-compatible id before ever attempting /players/:id.
    select payload->>'name' into player_name from futbeat_private.entities where id=p_player_id and kind='player';
    if nullif(btrim(coalesce(player_name,'')),'') is not null then
      perform futbeat_private.note_player_search_demand(player_name);
    end if;
    return jsonb_build_object('enrichmentPending',true,'reason','identity_discovery')||due;
  end if;
  -- Only promise enrichment that the quota manager would allow today.
  pending:=((due->>'profileDue')::boolean
      and (futbeat_private.quota_decision('goal_api','player-profile','user')->>'allowed')::boolean)
    or ((due->>'statsDue')::boolean
      and (futbeat_private.quota_decision('goal_api','player-stats','user')->>'allowed')::boolean);
  if not pending then
    perform futbeat_private.bump_metric('player_profile_cache_hits');
    return jsonb_build_object('enrichmentPending',false)||due;
  end if;
  select requested_at,lease_until into previous,lease from futbeat_private.player_profile_coverage
  where player_id=p_player_id;
  insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count,priority)
  values(p_player_id,ext,now(),1,0)
  on conflict(player_id) do update set requested_at=now(),external_id=excluded.external_id,
    request_count=futbeat_private.player_profile_coverage.request_count+1,priority=0;
  if lease>now() or previous>now()-interval '1 minute' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('player_profile_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return jsonb_build_object('enrichmentPending',true)||due;
end $$;

-- Same priority order as before (direct visit 0, starters 1, bench 2,
-- freshest at 100); one new guard: a player whose only known id is the
-- numeric lineup/live one is never reserved (it would 404 on /players/:id),
-- and the external id sent to GOAL is always re-resolved fresh, preferring
-- a profile-compatible id over the stale one player_profile_coverage may
-- still carry from before a bridge landed.
create or replace function public.futbeat_reserve_player_call(p_trigger_source text default 'supabase-cron')
returns jsonb language plpgsql security definer set search_path='' as $$
declare window_start timestamptz:=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','demandWindowMinutes',30)::integer);
  lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  decision jsonb; last_decision jsonb; demand futbeat_private.player_search_demands; player record; id bigint;
begin
  if nullif(btrim(p_trigger_source),'') is null then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  delete from futbeat_private.player_search_demands where query_key in (
    select query_key from futbeat_private.player_search_demands
    where (status='QUEUED' and last_attempt_at is null and requested_at<=window_start)
       or (status<>'QUEUED' and coalesce(next_retry_at,last_attempt_at,requested_at)<now()-interval '30 days')
    limit 500);

  decision:=futbeat_private.quota_decision('goal_api','player-search','user');
  last_decision:=decision;
  if (decision->>'allowed')::boolean then
    select * into demand from futbeat_private.player_search_demands
    where status='QUEUED' and requested_at>window_start and coalesce(lease_until,'-infinity')<=now()
      and coalesce(next_retry_at,'-infinity')<=now()
    order by requested_at>now()-interval '1 minute' desc,least(request_count,5) desc,requested_at desc,query_key
    limit 1 for update skip locked;
    if demand.query_key is not null then
      update futbeat_private.player_search_demands set lease_until=now()+lease,last_attempt_at=now()
      where query_key=demand.query_key;
      insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
      values('goal_api','player-search',left(p_trigger_source,40),now(),
        jsonb_build_object('queryKey',demand.query_key,'query',demand.query_text))
      returning provider_call_ledger.id into id;
      return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind','player-search',
        'query',demand.query_text,'queryKey',demand.query_key);
    end if;
  end if;

  for player in
    select c.player_id,
      coalesce(
        (select pe.external_id from futbeat_private.provider_entities pe
         where pe.canonical_id=c.player_id and pe.provider='goal_api' and pe.kind='player'
           and not futbeat_private.player_external_id_is_numeric(pe.external_id)
         order by pe.external_id limit 1),
        c.external_id
      ) external_id,
      (d->>'profileDue')::boolean profile_due,(d->>'statsDue')::boolean stats_due
    from futbeat_private.player_profile_coverage c
    cross join lateral futbeat_private.player_hydration_due(c.player_id) d
    where c.requested_at>window_start and coalesce(c.lease_until,'-infinity')<=now()
      and ((d->>'profileDue')::boolean or (d->>'statsDue')::boolean)
      and coalesce((d->>'profileIdReady')::boolean,false)
    order by c.priority,c.requested_at desc,c.player_id
    limit 20
  loop
    decision:=futbeat_private.quota_decision('goal_api',
      case when player.profile_due then 'player-profile' else 'player-stats' end,'user');
    last_decision:=decision;
    if not (decision->>'allowed')::boolean then continue; end if;
    update futbeat_private.player_profile_coverage set lease_until=now()+lease where player_id=player.player_id;
    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
    values('goal_api',decision->>'kind',left(p_trigger_source,40),now(),
      jsonb_build_object('playerId',player.player_id,'externalPlayerId',player.external_id))
    returning provider_call_ledger.id into id;
    return decision||jsonb_build_object('allowed',true,'reservationId',id,'kind',decision->>'kind',
      'playerId',player.player_id,'externalPlayerId',player.external_id);
  end loop;

  return jsonb_build_object('allowed',false,'reason',
    case when last_decision->>'reason' is not null and not (last_decision->>'allowed')::boolean
      then last_decision->>'reason' else 'no_player_demand' end,
    'providerRemaining',last_decision->'providerRemaining');
end $$;

revoke all on function
  futbeat_private.player_external_id_is_numeric(text),
  futbeat_private.bridge_lineup_player_identity(text,text)
from public,anon,authenticated,service_role;

notify pgrst,'reload schema';
