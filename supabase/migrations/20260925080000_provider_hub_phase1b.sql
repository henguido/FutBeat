-- Issue #102 Provider Hub Phase 1B: selective secondary worker path,
-- activation-ready but DISABLED (API-Football's account is suspended; no
-- provider is enabled here and no cron/workflow is added).
--
-- Why a separate observation table: the canonical read model
-- (match_read_model_core) takes the newest status/score evidence from
-- provider_observations of ANY provider. Writing API-Football observations
-- there directly would let a secondary override fresher/stronger GOAL
-- evidence. Secondary observations are stored in
-- provider_secondary_observations (never read by the read model); only a
-- reconciled final result is promoted to provider_observations, where the
-- existing read-model rules (never final by clock, complete score only)
-- apply unchanged.
--
-- Reconciliation precedence (futbeat_record_secondary_observation):
--   1. The observation must belong to the strictly mapped canonical match.
--   2. Only a TERMINAL secondary status with a COMPLETE score can ever be
--      applied; LIVE/scheduled/partial secondary evidence is stored only
--      (no global or selective LIVE reconciliation in 1B).
--   3. GOAL terminal evidence with a complete score is authoritative: equal
--      -> CONFIRMED, different -> CONFLICT (nothing written).
--   4. GOAL evidence newer than the secondary observation -> SUPERSEDED.
--   5. Otherwise (GOAL lacks a terminal result) -> APPLIED_FINAL: one
--      provider_observations row carries the terminal evidence.
-- Secondary events are deduplicated against GOAL events by the worker
-- (dedupeCanonicalEvents) and stored as evidence; they are NOT written to
-- canonical_events in 1B (that table feeds push notifications).

create table if not exists futbeat_private.provider_secondary_observations(
  id bigint generated always as identity primary key,
  provider text not null,
  external_match_id text not null,
  canonical_match_id text not null references futbeat_private.entities(id) on delete cascade,
  received_at timestamptz not null,
  status text,
  minute integer check(minute is null or minute>=0),
  home_score integer check(home_score is null or home_score>=0),
  away_score integer check(away_score is null or away_score>=0),
  events jsonb not null default '[]'::jsonb check(jsonb_typeof(events)='array'),
  observation jsonb not null check(jsonb_typeof(observation)='object'),
  payload_hash text not null,
  reconciliation jsonb not null default '{}'::jsonb check(jsonb_typeof(reconciliation)='object'),
  recorded_at timestamptz not null default now(),
  unique(provider,external_match_id,payload_hash)
);
create index if not exists provider_secondary_observations_match_idx
  on futbeat_private.provider_secondary_observations(canonical_match_id,received_at desc);
alter table futbeat_private.provider_secondary_observations enable row level security;
revoke all on futbeat_private.provider_secondary_observations from public,anon,authenticated;

-- Read-only worker preview: config, hub decision, canonical match summary
-- and the strict mapping state. No writes (dry runs use only this and the
-- status RPC).
create or replace function public.futbeat_provider_hub_preview(p_provider text,p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare cfg futbeat_private.provider_hub_config; m jsonb; ext text; mapping_state text;
begin
  select * into cfg from futbeat_private.provider_hub_config where provider=p_provider;
  select e.payload into m from futbeat_private.entities e
  where e.id=futbeat_private.futbeat_resolve_entity_id('match',p_match_id) and e.kind='match';
  if m is null then return jsonb_build_object('provider',p_provider,'matchFound',false); end if;
  select pe.external_id into ext from futbeat_private.provider_entities pe
  where pe.provider=p_provider and pe.kind='match'
    and futbeat_private.futbeat_resolve_entity_id('match',pe.canonical_id)=m->>'id'
  order by pe.external_id limit 1;
  mapping_state:=case
    when ext is not null then 'MAPPED'
    when exists(select 1 from futbeat_private.provider_fixture_diagnostics d
      where d.provider=p_provider and d.status='AMBIGUOUS' and d.detail->'candidates' ? (m->>'id')) then 'AMBIGUOUS'
    else 'UNMAPPED' end;
  return jsonb_build_object(
    'provider',p_provider,
    'matchFound',true,
    'config',case when cfg.provider is null then null else jsonb_build_object('enabled',cfg.enabled,'role',cfg.role,
      'developmentOnly',cfg.development_only,'priority',cfg.priority,'dailyBudget',cfg.daily_budget,
      'minuteBudget',cfg.minute_budget) end,
    'decision',futbeat_private.provider_hub_decision(p_provider,1),
    'mapping',jsonb_build_object('state',mapping_state,'externalMatchId',ext),
    'match',jsonb_build_object('id',m->>'id','competitionId',m->>'competitionId',
      'homeTeamId',m->>'homeTeamId','awayTeamId',m->>'awayTeamId','startTime',m->>'startTime',
      'status',m->>'status','score',m->'score',
      'events',coalesce((select jsonb_agg(jsonb_build_object('id',x->>'id','type',x->>'type',
          'teamId',x->>'teamId','minute',x->'minute','extraMinute',x->'extraMinute','playerId',x->>'playerId'))
        from jsonb_array_elements(case when jsonb_typeof(m->'events')='array' then m->'events' else '[]'::jsonb end) x),
        '[]'::jsonb)));
end $$;

-- Strict batch resolution (existing mappings only; never creates or
-- name-matches). Returns {externalId: canonicalId} for the mapped ones.
create or replace function public.futbeat_resolve_provider_entities_strict(
  p_provider text,p_kind text,p_external_ids text[]
) returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_object_agg(x.id,r.canonical),'{}'::jsonb)
  from (select distinct unnest(coalesce(p_external_ids,'{}')) id limit 200) x
  cross join lateral (select futbeat_private.resolve_provider_entity_strict(p_provider,p_kind,x.id) canonical) r
  where r.canonical is not null
$$;

-- Records one secondary observation and applies the precedence above.
create or replace function public.futbeat_record_secondary_observation(
  p_provider text,p_match_id text,p_observation jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare canonical text; ext text:=p_observation->>'externalMatchId'; received timestamptz;
  v_status text:=p_observation->>'status'; home integer; away integer; hash text; obs_id bigint;
  m jsonb; goal_terminal record; goal_latest timestamptz; decision jsonb;
begin
  if p_observation is null or jsonb_typeof(p_observation)<>'object' then raise exception 'Invalid secondary observation'; end if;
  canonical:=futbeat_private.futbeat_resolve_entity_id('match',p_match_id);
  if nullif(ext,'') is null
     or futbeat_private.resolve_provider_entity_strict(p_provider,'match',ext) is distinct from canonical then
    raise exception 'Secondary observation is not strictly mapped to this match';
  end if;
  received:=nullif(p_observation->>'receivedAt','')::timestamptz;
  if received is null then raise exception 'Invalid secondary observation time'; end if;
  if jsonb_typeof(p_observation->'score'->'home')='number' and jsonb_typeof(p_observation->'score'->'away')='number' then
    home:=(p_observation->'score'->>'home')::integer; away:=(p_observation->'score'->>'away')::integer;
  end if;
  hash:=encode(sha256(convert_to(p_observation::text,'UTF8')),'hex');
  select e.payload into m from futbeat_private.entities e where e.id=canonical and e.kind='match';

  -- GOAL's strongest terminal evidence with a complete score.
  select x.home,x.away into goal_terminal from (
    select (m->'score'->>'home')::integer home,(m->'score'->>'away')::integer away,0 rank,now() seen
      where m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and jsonb_typeof(m->'score'->'home')='number' and jsonb_typeof(m->'score'->'away')='number'
    union all
    select o.home_score,o.away_score,1,o.received_at from futbeat_private.provider_observations o
      where o.canonical_match_id=canonical and o.provider='goal_api'
        and o.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and o.home_score is not null and o.away_score is not null
    union all
    select l.home_score,l.away_score,1,l.last_seen_at from futbeat_private.live_match_state l
      where l.canonical_match_id=canonical and l.provider='goal_api'
        and l.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and l.home_score is not null and l.away_score is not null
  ) x order by x.rank,x.seen desc limit 1;
  select max(t) into goal_latest from (
    select max(o.received_at) t from futbeat_private.provider_observations o
      where o.canonical_match_id=canonical and o.provider='goal_api'
    union all
    select max(l.last_seen_at) from futbeat_private.live_match_state l
      where l.canonical_match_id=canonical and l.provider='goal_api') g;

  decision:=case
    when coalesce(v_status,'') not in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      then jsonb_build_object('decision','STORED_ONLY','reason','not_terminal')
    when home is null or away is null
      then jsonb_build_object('decision','STORED_ONLY','reason','incomplete_score')
    when goal_terminal.home is not null and goal_terminal.home=home and goal_terminal.away=away
      then jsonb_build_object('decision','CONFIRMED','reason','goal_terminal_agrees')
    when goal_terminal.home is not null
      then jsonb_build_object('decision','CONFLICT','reason','goal_terminal_differs',
        'goal',jsonb_build_object('home',goal_terminal.home,'away',goal_terminal.away))
    when goal_latest is not null and goal_latest>received
      then jsonb_build_object('decision','SUPERSEDED','reason','goal_evidence_newer')
    when nullif(m->>'startTime','')::timestamptz is null or nullif(m->>'startTime','')::timestamptz>received
      then jsonb_build_object('decision','STORED_ONLY','reason','before_kickoff')
    else jsonb_build_object('decision','APPLIED_FINAL','reason','goal_result_missing')
  end;

  insert into futbeat_private.provider_secondary_observations(provider,external_match_id,canonical_match_id,
    received_at,status,minute,home_score,away_score,events,observation,payload_hash,reconciliation)
  values(p_provider,ext,canonical,received,v_status,
    case when jsonb_typeof(p_observation->'minute')='number' then (p_observation->>'minute')::integer end,
    home,away,
    case when jsonb_typeof(p_observation->'events')='array' then p_observation->'events' else '[]'::jsonb end,
    p_observation-'raw',hash,decision)
  on conflict(provider,external_match_id,payload_hash) do nothing
  returning id into obs_id;
  if obs_id is null then
    return jsonb_build_object('status','DUPLICATE')||decision;
  end if;

  if decision->>'decision'='APPLIED_FINAL' then
    -- Terminal evidence for the canonical read model; its rules apply.
    insert into futbeat_private.provider_observations(provider,external_match_id,canonical_match_id,
      received_at,status,minute,home_score,away_score,events,payload_hash,raw_payload)
    values(p_provider,ext,canonical,received,v_status,null,home,away,'[]'::jsonb,hash,
      jsonb_build_object('source','provider_hub_secondary','secondaryObservationId',obs_id))
    on conflict(provider,external_match_id,payload_hash) do nothing;
  end if;
  return jsonb_build_object('status','RECORDED','observationId',obs_id)||decision;
end $$;

-- Per-provider status. Health (same rules as backend/providers/core/hub.mjs):
--   DISABLED     enabled=false
--   UNSEEN       no completed call in the last 24 h
--   UNAVAILABLE  last completion failed with 401/403 or an availability
--                error code (*_AUTH, *_ACCOUNT_SUSPENDED: a suspended
--                account can arrive inside an HTTP 200 envelope), or the
--                last 3 completions all failed
--   DEGRADED     failures >= 20% of the last 24 h completions, or p95 >= 10 s
--   HEALTHY      otherwise
create or replace function public.futbeat_provider_hub_status()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
begin
  with cfg as (
    select * from futbeat_private.provider_hub_config
  ), window_calls as (
    select l.provider,l.status,l.http_status,l.error_code,l.reserved_at,l.completed_at,l.metadata,
      extract(epoch from (l.completed_at-l.reserved_at))*1000 latency_ms
    from futbeat_private.provider_call_ledger l join cfg on cfg.provider=l.provider
    where l.reserved_at>=now()-interval '24 hours'
  ), stats as (
    select c.provider,
      count(*) filter(where w.reserved_at>=day_start) calls_today,
      coalesce(sum(futbeat_private.provider_call_units(w.metadata)) filter(where w.reserved_at>=day_start),0) units_today,
      count(*) filter(where w.reserved_at>=day_start and w.status='SUCCEEDED') success_today,
      count(*) filter(where w.reserved_at>=day_start and w.status='FAILED') failed_today,
      count(*) filter(where w.status='SUCCEEDED') success_24h,
      count(*) filter(where w.status='FAILED') failed_24h,
      max(w.completed_at) filter(where w.status='SUCCEEDED') last_success_at,
      max(w.completed_at) filter(where w.status='FAILED') last_failure_at,
      round(avg(w.latency_ms) filter(where w.completed_at is not null)::numeric,0) avg_latency_ms,
      round((percentile_cont(0.95) within group(order by w.latency_ms)
        filter(where w.completed_at is not null))::numeric,0) p95_latency_ms
    from cfg c left join window_calls w on w.provider=c.provider
    group by c.provider
  ), recent as (
    select c.provider,
      (select array_agg(x.status order by x.completed_at desc) from (
        select w.status,w.completed_at from window_calls w
        where w.provider=c.provider and w.completed_at is not null
        order by w.completed_at desc limit 3) x) last_statuses,
      (select w.http_status from window_calls w where w.provider=c.provider and w.completed_at is not null
        order by w.completed_at desc limit 1) last_http_status,
      (select w.error_code from window_calls w where w.provider=c.provider and w.completed_at is not null
        order by w.completed_at desc limit 1) last_error_code
    from cfg c
  ), rows as (
    select c.*,s.calls_today,s.units_today,s.success_today,s.failed_today,s.success_24h,s.failed_24h,
      s.last_success_at,s.last_failure_at,s.avg_latency_ms,s.p95_latency_ms,r.last_statuses,r.last_http_status,
      r.last_error_code,
      case
        when not c.enabled then 'DISABLED'
        when s.success_24h+s.failed_24h=0 then 'UNSEEN'
        when r.last_statuses[1]='FAILED' and (r.last_http_status in (401,403)
          or coalesce(r.last_error_code,'') ~ '_(AUTH|ACCOUNT_SUSPENDED)$') then 'UNAVAILABLE'
        when cardinality(r.last_statuses)>=3 and r.last_statuses[1:3]<@array['FAILED'] then 'UNAVAILABLE'
        when s.failed_24h::numeric/(s.success_24h+s.failed_24h)>=0.2 then 'DEGRADED'
        when coalesce(s.p95_latency_ms,0)>=10000 then 'DEGRADED'
        else 'HEALTHY' end health,
      -- Same rules without the DISABLED short-circuit: what routing would
      -- see if the provider were enabled (dry-run inspection only).
      case
        when s.success_24h+s.failed_24h=0 then 'UNSEEN'
        when r.last_statuses[1]='FAILED' and (r.last_http_status in (401,403)
          or coalesce(r.last_error_code,'') ~ '_(AUTH|ACCOUNT_SUSPENDED)$') then 'UNAVAILABLE'
        when cardinality(r.last_statuses)>=3 and r.last_statuses[1:3]<@array['FAILED'] then 'UNAVAILABLE'
        when s.failed_24h::numeric/(s.success_24h+s.failed_24h)>=0.2 then 'DEGRADED'
        when coalesce(s.p95_latency_ms,0)>=10000 then 'DEGRADED'
        else 'HEALTHY' end health_if_enabled
    from cfg c join stats s on s.provider=c.provider join recent r on r.provider=c.provider
  )
  select jsonb_build_object('generatedAt',now(),'providers',coalesce(jsonb_agg(jsonb_build_object(
      'provider',provider,'enabled',enabled,'role',role,'developmentOnly',development_only,
      'priority',priority,'dailyBudget',daily_budget,'minuteBudget',minute_budget,
      'callsToday',calls_today,'requestUnitsToday',units_today,
      'successToday',success_today,'failedToday',failed_today,
      'lastSuccessAt',last_success_at,'lastFailureAt',last_failure_at,
      'averageLatencyMs',avg_latency_ms,'p95LatencyMs',p95_latency_ms,
      'providerRemaining',futbeat_private.provider_remaining(provider),
      'lastErrorCode',last_error_code,
      'health',health,'healthIfEnabled',health_if_enabled) order by priority,provider),'[]'))
  into result from rows;
  return result;
end $$;

revoke all on function
  public.futbeat_provider_hub_preview(text,text),
  public.futbeat_resolve_provider_entities_strict(text,text,text[]),
  public.futbeat_record_secondary_observation(text,text,jsonb),
  public.futbeat_provider_hub_status()
from public,anon,authenticated;
grant execute on function
  public.futbeat_provider_hub_preview(text,text),
  public.futbeat_resolve_provider_entities_strict(text,text,text[]),
  public.futbeat_record_secondary_observation(text,text,jsonb),
  public.futbeat_provider_hub_status()
to service_role;

notify pgrst,'reload schema';
