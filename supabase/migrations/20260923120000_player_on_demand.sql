-- Player discovery and profile hydration on demand (GOAL, server-side only).
--
-- Search: the local catalog ALWAYS answers first. Only when no PLAYER matches
-- the query well (whole word or multi-word typo match) a normalized search
-- demand is recorded (>= 3 useful characters). Matching teams/competitions
-- are still returned but never suppress player discovery. One row per
-- normalized query: 1000 users searching the same name cost at most one
-- provider call; results are cached (playerSearchDays), empty results are
-- negatively cached (playerSearchNegativeDays), failures back off.
-- Found players are canonicalized strictly by provider id (never by name),
-- become searchable through the existing index trigger, and only fields the
-- provider actually returned are stored.
--
-- Profile: opening a player records a deduplicated hydration demand when the
-- profile is poor/never hydrated or stale (playerProfileDays), and season
-- statistics when stale (playerStatsHours, shorter). Partial responses never
-- erase valid data; squads keep ownership of club facts.
--
-- Worker: reserve_player_call -> GET /players/search | /players/:id |
-- /players/:id/statistics -> store_* (which also completes the ledger row).
-- Quota: class 'user' through the central manager, per-kind safety caps.

create table if not exists futbeat_private.player_search_demands(
  query_key text primary key check(length(query_key) between 3 and 80),
  query_text text not null,
  status text not null default 'QUEUED' check(status in ('QUEUED','AVAILABLE','NO_DATA','FETCH_FAILED')),
  requested_at timestamptz not null default now(),
  request_count bigint not null default 1,
  lease_until timestamptz,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  next_retry_at timestamptz,
  failure_count integer not null default 0,
  result_count integer,
  result_player_ids text[] not null default '{}',
  last_error text,
  -- When this key was (re)admitted into the queue: admission control window.
  admitted_at timestamptz not null default now()
);
create index if not exists player_search_demands_admitted_idx
  on futbeat_private.player_search_demands(admitted_at desc);
create index if not exists player_search_demands_due_idx
  on futbeat_private.player_search_demands(status,requested_at desc);
alter table futbeat_private.player_search_demands enable row level security;
revoke all on futbeat_private.player_search_demands from public,anon,authenticated;

create table if not exists futbeat_private.player_profile_coverage(
  player_id text primary key references futbeat_private.entities(id) on delete cascade,
  external_id text not null,
  requested_at timestamptz,
  request_count bigint not null default 0,
  profile_status text not null default 'NEVER' check(profile_status in ('NEVER','AVAILABLE','NO_DATA','FETCH_FAILED')),
  profile_fetched_at timestamptz,
  profile_next_retry_at timestamptz,
  stats_status text not null default 'NEVER' check(stats_status in ('NEVER','AVAILABLE','NO_DATA','FETCH_FAILED')),
  stats_fetched_at timestamptz,
  stats_next_retry_at timestamptz,
  failure_count integer not null default 0,
  lease_until timestamptz,
  last_error text
);
create index if not exists player_profile_coverage_requested_idx
  on futbeat_private.player_profile_coverage(requested_at desc);
alter table futbeat_private.player_profile_coverage enable row level security;
revoke all on futbeat_private.player_profile_coverage from public,anon,authenticated;

-- Normalized query key: folded, punctuation-free, >= 3 letters/digits.
create or replace function futbeat_private.player_search_key(p_query text)
returns text language sql immutable set search_path='' as $$
  select case when length(regexp_replace(k,'[^a-z0-9]','','g'))>=3 then left(k,80) end
  from (select btrim(regexp_replace(regexp_replace(coalesce(futbeat_private.search_fold(p_query),''),
    '[^a-z0-9 ]+',' ','g'),'\s+',' ','g')) k) q
$$;

-- Global admission control for new search demands: at most
-- searchAdmissionsPerWindow per searchAdmissionWindowMinutes and at most
-- searchQueueMax queued. Serialized by one advisory lock held only on the
-- new-key path (cached/duplicate searches never take it).
create or replace function futbeat_private.admit_player_search_demand()
returns jsonb language plpgsql security definer set search_path='' as $$
declare window_size interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','searchAdmissionWindowMinutes',5)::integer);
  per_window integer:=futbeat_private.quota_setting('goal_api','searchAdmissionsPerWindow',60)::integer;
  queue_max integer:=futbeat_private.quota_setting('goal_api','searchQueueMax',200)::integer;
  admitted integer; queued integer;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-player-search-admission'));
  select count(*)::integer into admitted from futbeat_private.player_search_demands
  where admitted_at>now()-window_size;
  if admitted>=per_window then
    return jsonb_build_object('admitted',false,'reason','demand_rate_limited');
  end if;
  select count(*)::integer into queued from futbeat_private.player_search_demands where status='QUEUED';
  if queued>=queue_max then
    return jsonb_build_object('admitted',false,'reason','demand_queue_full');
  end if;
  return jsonb_build_object('admitted',true);
end $$;

create or replace function futbeat_private.note_player_search_demand(p_query text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare key text:=futbeat_private.player_search_key(p_query); v_status text; v_next timestamptz;
  v_lease timestamptz; inserted boolean; admission jsonb;
begin
  if key is null then return jsonb_build_object('pending',false,'reason','too_short'); end if;
  -- Flood protection (anonymous API): a NEW key, or re-queueing an expired
  -- one, needs an admission slot. Known keys (queued = dedupe, cached = hit)
  -- never consume slots. Local results are returned either way.
  select status,next_retry_at into v_status,v_next from futbeat_private.player_search_demands where query_key=key;
  if not found or (v_status<>'QUEUED' and coalesce(v_next,'-infinity')<=now()) then
    admission:=futbeat_private.admit_player_search_demand();
    if not (admission->>'admitted')::boolean then
      perform futbeat_private.bump_metric('player_search_demand_limited');
      return jsonb_build_object('pending',false,'reason',admission->>'reason','key',key);
    end if;
  end if;
  insert into futbeat_private.player_search_demands(query_key,query_text)
  values(key,left(btrim(p_query),80))
  on conflict(query_key) do update set request_count=futbeat_private.player_search_demands.request_count+1,
    requested_at=now()
  returning status,next_retry_at,lease_until,(xmax::text='0') into v_status,v_next,v_lease,inserted;
  if inserted then
    -- Typing "haa", "haal", "haala"... must not queue one paid search per
    -- prefix: a newer, longer query supersedes its never-attempted prefixes.
    delete from futbeat_private.player_search_demands d
    where d.status='QUEUED' and d.last_attempt_at is null and d.query_key<>key
      and d.request_count<=2 and key like d.query_key||'%'
      and d.requested_at>now()-interval '2 minutes';
    perform futbeat_private.bump_metric('player_search_demands');
    perform futbeat_private.wake_provider_worker('demand');
    return jsonb_build_object('pending',true,'status','QUEUED','key',key);
  end if;
  if v_status='QUEUED' then
    perform futbeat_private.bump_metric('deduped_requests');
    if v_lease is null or v_lease<=now() then
      perform futbeat_private.wake_provider_worker('demand');
    end if;
    return jsonb_build_object('pending',true,'status','QUEUED','key',key);
  end if;
  if coalesce(v_next,'-infinity')>now() then
    -- Positive or negative cache (or failure backoff): no provider call.
    perform futbeat_private.bump_metric('player_search_cache_hits');
    return jsonb_build_object('pending',false,'status',v_status,'key',key);
  end if;
  update futbeat_private.player_search_demands set status='QUEUED',admitted_at=now() where query_key=key;
  perform futbeat_private.bump_metric('player_search_demands');
  perform futbeat_private.wake_provider_worker('demand');
  return jsonb_build_object('pending',true,'status','QUEUED','key',key);
end $$;

-- Merge one provider player (already normalized by the worker) into the
-- canonical catalog. Identity strictly by provider id. Only received values;
-- 'profile' refreshes personal facts, 'search' only fills missing ones.
-- Club facts (team/position/shirt) are only filled when missing and the
-- player is not owned by a stored squad.
create or replace function futbeat_private.upsert_goal_player(p_item jsonb,p_source text,p_received timestamptz)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ext text:=nullif(btrim(p_item->>'externalId'),''); name text:=nullif(btrim(p_item->>'name'),'');
  existed boolean; pid text; old jsonb; next jsonb; key text; value jsonb; team_id text; squad boolean; url text;
begin
  if ext is null or p_source not in ('search','profile') then return null; end if;
  existed:=exists(select 1 from futbeat_private.provider_entities where provider='goal_api' and kind='player' and external_id=ext);
  if not existed and name is null then return null; end if;
  pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,coalesce(name,''),
    coalesce(p_item->>'country',''),coalesce(p_item->>'shortName',''));
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

-- Profile/stats state for one canonical player.
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
        where t.team_id=e.payload->>'teamId' and t.last_success_at>now()-interval '7 days')))
  from futbeat_private.entities e
  left join futbeat_private.player_profile_coverage c on c.player_id=e.id
  where e.id=p_player_id and e.kind='player'
$$;

create or replace function public.futbeat_request_player_profile(p_player_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare ext text; due jsonb; previous timestamptz; lease timestamptz; pending boolean;
begin
  select external_id into ext from futbeat_private.provider_entities
  where provider='goal_api' and kind='player' and canonical_id=p_player_id
  order by external_id limit 1;
  if ext is null then return jsonb_build_object('enrichmentPending',false,'reason','unmapped'); end if;
  due:=futbeat_private.player_hydration_due(p_player_id);
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
  insert into futbeat_private.player_profile_coverage(player_id,external_id,requested_at,request_count)
  values(p_player_id,ext,now(),1)
  on conflict(player_id) do update set requested_at=now(),external_id=excluded.external_id,
    request_count=futbeat_private.player_profile_coverage.request_count+1;
  if lease>now() or previous>now()-interval '1 minute' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('player_profile_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return jsonb_build_object('enrichmentPending',true)||due;
end $$;

-- One provider call per reservation: search first (a user is waiting on the
-- search screen), then profile, then season statistics.
create or replace function public.futbeat_reserve_player_call(p_trigger_source text default 'supabase-cron')
returns jsonb language plpgsql security definer set search_path='' as $$
declare window_start timestamptz:=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','demandWindowMinutes',30)::integer);
  lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  decision jsonb; last_decision jsonb; demand futbeat_private.player_search_demands; player record; id bigint;
begin
  if nullif(btrim(p_trigger_source),'') is null then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  -- Housekeeping (bounded): demand nobody is waiting for anymore, and old
  -- finished rows whose cache/backoff ended long ago.
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
    -- Freshest demand first; popularity only breaks ties up to a small cap,
    -- so repeating junk queries cannot monopolize the budget.
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
    select c.player_id,c.external_id,(d->>'profileDue')::boolean profile_due,(d->>'statsDue')::boolean stats_due
    from futbeat_private.player_profile_coverage c
    cross join lateral futbeat_private.player_hydration_due(c.player_id) d
    where c.requested_at>window_start and coalesce(c.lease_until,'-infinity')<=now()
      and ((d->>'profileDue')::boolean or (d->>'statsDue')::boolean)
    order by c.requested_at desc,c.player_id
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

create or replace function futbeat_private.complete_player_ledger(p_reservation_id bigint,p_kind text,
  p_status text,p_remaining integer,p_http integer,p_error text,p_metadata jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb;
begin
  update futbeat_private.provider_call_ledger
  set status=p_status,completed_at=now(),provider_remaining=p_remaining,http_status=p_http,error_code=p_error,
    metadata=metadata||coalesce(p_metadata,'{}')
  where id=p_reservation_id and provider='goal_api' and call_kind=p_kind and status='RESERVED'
  returning metadata into meta;
  if meta is null then raise exception 'Unknown or completed player reservation'; end if;
  return meta;
end $$;

create or replace function public.futbeat_store_player_search_result(p_reservation_id bigint,
  p_players jsonb,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; item jsonb; result jsonb; ids text[]:='{}'; created integer:=0; gained integer:=0;
  days numeric;
begin
  if jsonb_typeof(p_players) is distinct from 'array' then raise exception 'Invalid player search result'; end if;
  meta:=futbeat_private.complete_player_ledger(p_reservation_id,'player-search','SUCCEEDED',p_provider_remaining,
    200,null,jsonb_build_object('players',least(jsonb_array_length(p_players),50)));
  -- Stable lock order (same as squad stores): concurrent stores never deadlock.
  for item in select value from (select value from jsonb_array_elements(p_players) with ordinality x(value,n)
      where n<=50) first50 order by value->>'externalId' loop
    result:=futbeat_private.upsert_goal_player(item,'search',now());
    if result is null then continue; end if;
    ids:=array_append(ids,result->>'id');
    created:=created+case when (result->>'created')::boolean then 1 else 0 end;
    gained:=gained+(result->>'gained')::integer;
  end loop;
  days:=case when cardinality(ids)>0 then futbeat_private.quota_setting('goal_api','playerSearchDays',7)
    else futbeat_private.quota_setting('goal_api','playerSearchNegativeDays',3) end;
  update futbeat_private.player_search_demands set
    status=case when cardinality(ids)>0 then 'AVAILABLE' else 'NO_DATA' end,
    last_success_at=now(),next_retry_at=now()+make_interval(days=>days::integer),lease_until=null,
    failure_count=0,last_error=null,result_count=cardinality(ids),result_player_ids=ids
  where query_key=meta->>'queryKey';
  perform futbeat_private.bump_metric('player_search_provider_calls');
  perform futbeat_private.bump_metric('players_discovered',created);
  perform futbeat_private.bump_metric('coverage_gained',gained);
  return jsonb_build_object('players',cardinality(ids),'created',created,'fieldsGained',gained);
end $$;

create or replace function public.futbeat_store_player_profile(p_reservation_id bigint,
  p_profile jsonb,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; result jsonb; has_data boolean;
begin
  meta:=futbeat_private.complete_player_ledger(p_reservation_id,'player-profile','SUCCEEDED',p_provider_remaining,200,null,'{}');
  has_data:=jsonb_typeof(p_profile)='object' and exists(select 1 from jsonb_each(p_profile) f
    where f.key<>'externalId' and f.value not in ('null'::jsonb,'""'::jsonb));
  if has_data then
    -- Identity comes from the reservation, never from the payload.
    result:=futbeat_private.upsert_goal_player(p_profile||jsonb_build_object('externalId',meta->>'externalPlayerId'),
      'profile',now());
  end if;
  update futbeat_private.player_profile_coverage set
    profile_status=case when has_data then 'AVAILABLE' else 'NO_DATA' end,
    profile_fetched_at=now(),
    profile_next_retry_at=now()+make_interval(days=>futbeat_private.quota_setting('goal_api',
      case when has_data then 'playerProfileDays' else 'playerNoDataDays' end,30)::integer),
    failure_count=0,lease_until=null,last_error=null
  where player_id=meta->>'playerId';
  if has_data then
    perform futbeat_private.bump_metric('player_profiles_hydrated');
    perform futbeat_private.bump_metric('coverage_gained',coalesce((result->>'gained')::integer,0));
  end if;
  return jsonb_build_object('playerId',meta->>'playerId','hydrated',has_data,
    'fieldsGained',coalesce((result->>'gained')::integer,0));
end $$;

create or replace function public.futbeat_store_player_stats(p_reservation_id bigint,
  p_stats jsonb,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; stats jsonb; has_data boolean;
begin
  meta:=futbeat_private.complete_player_ledger(p_reservation_id,'player-stats','SUCCEEDED',p_provider_remaining,200,null,'{}');
  stats:=case when jsonb_typeof(p_stats)='object' then jsonb_strip_nulls(p_stats) else '{}'::jsonb end;
  has_data:=exists(select 1 from jsonb_each(stats) f where jsonb_typeof(f.value)='number');
  if has_data then
    update futbeat_private.entities set payload=payload||jsonb_build_object('seasonStats',
      stats||jsonb_build_object('source','GOAL API','receivedAt',now()))
    where id=meta->>'playerId' and kind='player';
    perform futbeat_private.bump_metric('coverage_gained');
  end if;
  update futbeat_private.player_profile_coverage set
    stats_status=case when has_data then 'AVAILABLE' else 'NO_DATA' end,
    stats_fetched_at=now(),
    stats_next_retry_at=now()+case when has_data
      then make_interval(hours=>futbeat_private.quota_setting('goal_api','playerStatsHours',12)::integer)
      else make_interval(days=>futbeat_private.quota_setting('goal_api','playerStatsNoDataDays',3)::integer) end,
    failure_count=0,lease_until=null,last_error=null
  where player_id=meta->>'playerId';
  return jsonb_build_object('playerId',meta->>'playerId','seasonStats',has_data);
end $$;

-- Failure: ledger FAILED and per-demand backoff (404 = negative cache).
create or replace function public.futbeat_fail_player_call(p_reservation_id bigint,p_kind text,
  p_http_status integer default null,p_error_code text default null,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; retry interval; failures integer; v_status text;
begin
  if p_kind not in ('player-search','player-profile','player-stats') then raise exception 'Invalid player call kind'; end if;
  meta:=futbeat_private.complete_player_ledger(p_reservation_id,p_kind,'FAILED',p_provider_remaining,
    case when p_http_status between 100 and 599 then p_http_status end,left(coalesce(p_error_code,'GOAL_PLAYER_FETCH_FAILED'),80),'{}');
  v_status:=case when p_http_status=404 then 'NO_DATA' else 'FETCH_FAILED' end;
  if p_kind='player-search' then
    update futbeat_private.player_search_demands set failure_count=failure_count+1,lease_until=null,
      status=v_status,last_error=left(coalesce(p_error_code,'failed'),120)
    where query_key=meta->>'queryKey' returning failure_count into failures;
  else
    update futbeat_private.player_profile_coverage set failure_count=failure_count+1,lease_until=null,
      last_error=left(coalesce(p_error_code,'failed'),120)
    where player_id=meta->>'playerId' returning failure_count into failures;
  end if;
  retry:=case when p_http_status=404 then make_interval(days=>futbeat_private.quota_setting('goal_api',
      case p_kind when 'player-search' then 'playerSearchNegativeDays' when 'player-profile' then 'playerNoDataDays'
        else 'playerStatsNoDataDays' end,3)::integer)
    when p_http_status=429 then interval '1 hour'
    else least(interval '1 day',interval '15 minutes'*power(2,least(greatest(coalesce(failures,1)-1,0),7))) end;
  if p_kind='player-search' then
    update futbeat_private.player_search_demands set next_retry_at=now()+retry where query_key=meta->>'queryKey';
  elsif p_kind='player-profile' then
    update futbeat_private.player_profile_coverage set profile_status=v_status,profile_next_retry_at=now()+retry
    where player_id=meta->>'playerId';
  else
    update futbeat_private.player_profile_coverage set stats_status=v_status,stats_next_retry_at=now()+retry
    where player_id=meta->>'playerId';
  end if;
  return jsonb_build_object('status',v_status,'retryAt',now()+retry);
end $$;

create or replace function public.futbeat_demand_metrics(p_days integer default 1)
returns jsonb language sql stable security definer set search_path='' as $$
  with m as (
    select metric,sum(value)::bigint n from futbeat_private.demand_metrics
    where day>(now() at time zone 'UTC')::date-greatest(1,least(coalesce(p_days,1),90))
    group by metric
  ), calls as (
    select count(*) filter(where call_kind in ('player-search','player-profile','player-stats','match-detail')
      and status='SUCCEEDED') demand_calls
    from futbeat_private.provider_call_ledger
    where provider='goal_api'
      and reserved_at>now()-make_interval(days=>greatest(1,least(coalesce(p_days,1),90)))
  )
  select jsonb_build_object(
    'days',greatest(1,least(coalesce(p_days,1),90)),
    'counters',(select coalesce(jsonb_object_agg(metric,n),'{}') from m),
    'providerRemaining',futbeat_private.provider_remaining('goal_api'),
    'callsByKind',(select coalesce(jsonb_object_agg(call_kind,n),'{}') from (
      select call_kind,count(*) n from futbeat_private.provider_call_ledger
      where provider='goal_api'
        and reserved_at>now()-make_interval(days=>greatest(1,least(coalesce(p_days,1),90)))
      group by call_kind) k),
    'coverageGainedPerProviderCall',(select round(coalesce((select n from m where metric='coverage_gained'),0)::numeric
      /nullif(demand_calls,0),2) from calls))
$$;

create or replace function public.futbeat_search_catalog(
 p_query text default '',p_country text default null,p_limit integer default 50)
returns jsonb language plpgsql volatile security definer
set search_path='' set pg_trgm.strict_word_similarity_threshold='0.5' as $$
-- qr/pr: previous raw query (teams, competitions). qf/pf: folded (players).
declare qr text:=lower(btrim(coalesce(p_query,''))); pr text; qf text; pf text; v_result jsonb;
 v_player_ok boolean; v_demand jsonb;
begin
 if length(qr)>80 then raise exception 'Invalid search query'; end if;
 if qr='' then return public.futbeat_read_explore(); end if;
 if length(qr)<2 then return futbeat_private.catalog_snapshot('[]','[]'); end if;
 pr:=replace(replace(replace(qr,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_');
 qf:=futbeat_private.search_fold(qr);
 if length(qf)<2 then qf:=null; end if;
 pf:=replace(replace(replace(qf,E'\\',E'\\\\'),'%',E'\\%'),'_',E'\\_');
 with hits as materialized (
   select s.kind,s.entity_id,s.term from futbeat_private.entity_search_index s
   where (s.kind<>'player' and ((length(qr)=2 and s.term like pr||'%')
       or (length(qr)>=3 and (s.term like '%'||pr||'%' or s.term operator(extensions.%) qr))))
      or (s.kind='player' and qf is not null and ((length(qf)=2 and s.term like pf||'%')
       or (length(qf)>=3 and (s.term like '%'||pf||'%' or qf operator(extensions.<<%) s.term))))
 ), matches as materialized (
   select h.kind,futbeat_private.futbeat_resolve_entity_id(h.kind,h.entity_id) id,
     max(case when h.kind<>'player' then
       case when h.term=qr then 3 when h.term like pr||'%' then 2
         when h.term like '%'||pr||'%' then 1 else 0 end
     else case
       when h.term=qf and n.is_name then 6
       when n.is_name and h.term like pf||'%' then 5
       when n.is_name and h.term like '% '||pf||'%' then 4
       when h.term=qf then 3
       when h.term like pf||'%' or h.term like '% '||pf||'%' then 2
       when h.term like '%'||pf||'%' then 1 else 0 end end) quality,
     max(case when h.kind<>'player' then extensions.similarity(h.term,qr)
       else extensions.strict_word_similarity(qf,h.term) end) similarity,
     -- Multi-word fuzzy is judged per term, so similarity and the word guard
     -- always come from the same name/alias.
     bool_or(h.kind='player' and position(' ' in qf)>0
       and extensions.strict_word_similarity(qf,h.term)>=0.5
       and futbeat_private.search_word_guard(qf,h.term)>=0.35) multiword_fuzzy,
     -- The query names this player as whole word(s): the local answer is good
     -- enough, no provider discovery needed.
     bool_or(h.kind='player' and (h.term=qf or h.term like pf||' %' or h.term like '% '||pf
       or h.term like '% '||pf||' %')) whole_word
   from hits h join futbeat_private.entities src on src.id=h.entity_id
   cross join lateral (select h.kind='player' and h.term in (lower(btrim(coalesce(src.payload->>'name',''))),
     coalesce(futbeat_private.search_fold(src.payload->>'name'),''),
     coalesce(futbeat_private.search_compact_fold(src.payload->>'name'),'')) is_name) n
   group by h.kind,2
 ), scored as (
   select e.id,e.kind,e.payload,h.quality,h.similarity,h.whole_word,h.multiword_fuzzy,
     coalesce(meta.relevance_score,100) relevance
   from matches h join futbeat_private.entities e on e.id=h.id and e.kind=h.kind
   left join futbeat_private.entities team on e.kind='player' and team.id=e.payload->>'teamId'
   left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=
     case when e.kind='competition' then e.id else futbeat_private.futbeat_resolve_entity_id(
       'competition',coalesce(e.payload->>'competitionId',team.payload->>'competitionId')) end
   -- Players need a reasonable match: exact/prefix/word/alias, an infix of
   -- at least 4 characters, or a whole-word fuzzy match. Otherwise: none.
   -- Multi-word fuzzy also needs every query word to resemble a term word:
   -- one shared word ("lionel messi" vs "lionel scaloni") is not a typo.
   where e.kind<>'player' or h.quality>=2 or (h.quality=1 and length(qf)>=4)
     or (position(' ' in qf)=0 and h.similarity>=0.5)
     or h.multiword_fuzzy
 ), ranked as (
   select *,row_number() over(partition by kind order by quality desc,similarity desc,relevance desc,
     lower(payload->>'name'),id) rn from scored
 ), bounded as (
   select * from ranked where rn<=greatest(1,least(coalesce(p_limit,50),75))
 )
 select futbeat_private.catalog_snapshot(
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='competition'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='team'),'[]'),
   coalesce(jsonb_agg(futbeat_private.catalog_entity(payload,relevance) order by rn) filter(where kind='player'),'[]')
 ),
 coalesce(bool_or(kind='player' and (whole_word or multiword_fuzzy)),false)
 into v_result,v_player_ok from bounded;
 -- Local first, always. Discovery depends ONLY on player quality: a matching
 -- team/competition is still returned but never suppresses player discovery.
 if qf is not null and not v_player_ok then
   v_demand:=futbeat_private.note_player_search_demand(qr);
   if (v_demand->>'pending')::boolean then
     v_result:=jsonb_set(v_result,'{coverage,pendingRemote}','true'::jsonb,true);
   end if;
 end if;
 return v_result;
end $$;


revoke all on function
  futbeat_private.admit_player_search_demand(),
  futbeat_private.player_search_key(text),
  futbeat_private.note_player_search_demand(text),
  futbeat_private.upsert_goal_player(jsonb,text,timestamptz),
  futbeat_private.player_hydration_due(text),
  futbeat_private.complete_player_ledger(bigint,text,text,integer,integer,text,jsonb)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_request_player_profile(text),
  public.futbeat_reserve_player_call(text),
  public.futbeat_store_player_search_result(bigint,jsonb,integer),
  public.futbeat_store_player_profile(bigint,jsonb,integer),
  public.futbeat_store_player_stats(bigint,jsonb,integer),
  public.futbeat_fail_player_call(bigint,text,integer,text,integer),
  public.futbeat_demand_metrics(integer)
from public,anon,authenticated;
grant execute on function
  public.futbeat_request_player_profile(text),
  public.futbeat_reserve_player_call(text),
  public.futbeat_store_player_search_result(bigint,jsonb,integer),
  public.futbeat_store_player_profile(bigint,jsonb,integer),
  public.futbeat_store_player_stats(bigint,jsonb,integer),
  public.futbeat_fail_player_call(bigint,text,integer,text,integer),
  public.futbeat_demand_metrics(integer)
to service_role;

notify pgrst,'reload schema';
