-- Issue #102 Provider Hub Phase 1A: multi-provider foundation, no activation.
--
-- GOAL stays the PRIMARY LIVE provider through its existing worker and the
-- central quota manager (provider_quota_policy / quota_decision), untouched.
-- API-Football (SECONDARY) and Sportmonks (INTEGRATION) are registered but
-- DISABLED: nothing schedules them and every reservation is refused.
--
--   * provider_hub_config: enabled / role / development_only / priority /
--     daily + minute budgets / kickoff tolerance. A non-primary provider can
--     never be enabled without a daily budget (CHECK), so Sportmonks (no known
--     contractual limit) cannot run by accident.
--   * One ledger: provider_call_ledger. futbeat_reserve_provider_hub_call
--     reserves under the existing per-provider quota lock and enforces the
--     TOTAL daily budget in request units (provider_call_units) across all
--     call kinds: per-kind caps can never add up past the provider limit.
--   * futbeat_provider_hub_status: health and latency derived from the ledger
--     (no mutable health table), never secrets.
--   * Strict identity for new providers: no name-only auto merge. A provider
--     external id binds to a canonical id only through an existing mapping,
--     an explicit verified binding, or (matches only) a unique structural
--     fixture match on strictly mapped competition + teams + kickoff. The
--     legacy name-matching resolver (futbeat_resolve_global_entity) is not
--     extended to these providers.

create table if not exists futbeat_private.provider_hub_config(
  provider text primary key check(provider ~ '^[a-z0-9_]+$'),
  enabled boolean not null default false,
  role text not null check(role in ('PRIMARY','SECONDARY','INTEGRATION')),
  development_only boolean not null default true,
  priority integer not null check(priority>0),
  daily_budget integer check(daily_budget is null or daily_budget>0),
  minute_budget integer check(minute_budget is null or minute_budget>0),
  kickoff_tolerance_minutes integer not null default 10 check(kickoff_tolerance_minutes between 0 and 120),
  updated_at timestamptz not null default now(),
  -- A secondary/integration provider needs a configured budget to run.
  check(not enabled or role='PRIMARY' or daily_budget is not null)
);
alter table futbeat_private.provider_hub_config enable row level security;
revoke all on futbeat_private.provider_hub_config from public,anon,authenticated;

insert into futbeat_private.provider_hub_config
  (provider,enabled,role,development_only,priority,daily_budget,minute_budget)
values
  ('goal_api',true,'PRIMARY',false,1,null,null),
  ('api_football',false,'SECONDARY',true,2,100,10),
  ('sportmonks',false,'INTEGRATION',true,3,null,null)
on conflict(provider) do nothing;

-- Hub decision for a non-primary provider (no side effects). The caller holds
-- lock_provider_quota(provider) when it reserves.
create or replace function futbeat_private.provider_hub_decision(p_provider text,p_units integer default 1)
returns jsonb language plpgsql stable set search_path='' as $$
declare cfg futbeat_private.provider_hub_config; used integer; minute_used integer;
begin
  select * into cfg from futbeat_private.provider_hub_config where provider=p_provider;
  if cfg.provider is null then
    return jsonb_build_object('allowed',false,'reason','unknown_provider','provider',p_provider);
  end if;
  if p_units is null or p_units<1 then raise exception 'Invalid request units'; end if;
  select coalesce(sum(futbeat_private.provider_call_units(l.metadata)),0)::integer,
    coalesce(sum(futbeat_private.provider_call_units(l.metadata))
      filter(where l.reserved_at>now()-interval '1 minute'),0)::integer
  into used,minute_used
  from futbeat_private.provider_call_ledger l
  where l.provider=p_provider
    and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  return jsonb_build_object(
    'provider',p_provider,'role',cfg.role,'enabled',cfg.enabled,
    'dailyBudget',cfg.daily_budget,'usedToday',used,
    'minuteBudget',cfg.minute_budget,'usedLastMinute',minute_used,
    'allowed',cfg.enabled and cfg.role<>'PRIMARY' and cfg.daily_budget is not null
      and used+p_units<=cfg.daily_budget
      and (cfg.minute_budget is null or minute_used+p_units<=cfg.minute_budget),
    'reason',case
      when not cfg.enabled then 'provider_disabled'
      when cfg.role='PRIMARY' then 'primary_uses_quota_manager'
      when cfg.daily_budget is null then 'no_budget_configured'
      when used+p_units>cfg.daily_budget then 'provider_daily_budget'
      when cfg.minute_budget is not null and minute_used+p_units>cfg.minute_budget then 'provider_minute_budget'
    end);
end $$;

-- Reservation for a non-primary provider: persistent, under the same
-- per-provider advisory lock the quota manager uses. Not called by any
-- worker or workflow in Phase 1A.
create or replace function public.futbeat_reserve_provider_hub_call(
  p_provider text,
  p_call_kind text,
  p_trigger_source text,
  p_units integer default 1,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare decision jsonb; v_id bigint;
begin
  if nullif(btrim(coalesce(p_call_kind,'')),'') is null or nullif(btrim(coalesce(p_trigger_source,'')),'') is null then
    raise exception 'call kind and trigger source are required';
  end if;
  if p_metadata is null or jsonb_typeof(p_metadata)<>'object' then raise exception 'metadata must be an object'; end if;
  perform futbeat_private.lock_provider_quota(p_provider);
  decision:=futbeat_private.provider_hub_decision(p_provider,p_units);
  if not (decision->>'allowed')::boolean then return decision; end if;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values(p_provider,left(p_call_kind,40),left(p_trigger_source,40),now(),
    p_metadata||jsonb_build_object('providerHub',true,'providerRequests',p_units))
  returning id into v_id;
  return decision||jsonb_build_object('reservationId',v_id,
    'usedToday',(decision->>'usedToday')::integer+p_units);
end $$;

-- Per-provider status. Health (same rules as backend/providers/core/hub.mjs):
--   DISABLED     enabled=false
--   UNSEEN       no completed call in the last 24 h
--   UNAVAILABLE  last completion failed with 401/403, or the last 3
--                completions all failed
--   DEGRADED     failures >= 20% of the last 24 h completions, or p95 >= 10 s
--   HEALTHY      otherwise
create or replace function public.futbeat_provider_hub_status()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
begin
  with cfg as (
    select * from futbeat_private.provider_hub_config
  ), window_calls as (
    select l.provider,l.status,l.http_status,l.reserved_at,l.completed_at,l.metadata,
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
        order by w.completed_at desc limit 1) last_http_status
    from cfg c
  ), rows as (
    select c.*,s.calls_today,s.units_today,s.success_today,s.failed_today,s.success_24h,s.failed_24h,
      s.last_success_at,s.last_failure_at,s.avg_latency_ms,s.p95_latency_ms,r.last_statuses,r.last_http_status,
      case
        when not c.enabled then 'DISABLED'
        when s.success_24h+s.failed_24h=0 then 'UNSEEN'
        when r.last_statuses[1]='FAILED' and r.last_http_status in (401,403) then 'UNAVAILABLE'
        when cardinality(r.last_statuses)>=3 and r.last_statuses[1:3]<@array['FAILED'] then 'UNAVAILABLE'
        when s.failed_24h::numeric/(s.success_24h+s.failed_24h)>=0.2 then 'DEGRADED'
        when coalesce(s.p95_latency_ms,0)>=10000 then 'DEGRADED'
        else 'HEALTHY' end health
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
      'health',health) order by priority,provider),'[]'))
  into result from rows;
  return result;
end $$;

-- ---------------------------------------------------------------------------
-- Strict identity for new providers.
-- ---------------------------------------------------------------------------

-- Canonical id of a provider external id through an existing mapping only
-- (redirects followed); null = UNMAPPED. Never creates, never name-matches.
create or replace function futbeat_private.resolve_provider_entity_strict(p_provider text,p_kind text,p_external text)
returns text language sql stable set search_path='' as $$
  select futbeat_private.futbeat_resolve_entity_id(p_kind,pe.canonical_id)
  from futbeat_private.provider_entities pe
  where pe.provider=p_provider and pe.kind=p_kind and pe.external_id=p_external
$$;

-- Explicit verified binding (e.g. an operator-reviewed mapping). A name is
-- never sufficient evidence. An existing mapping is never overwritten.
create or replace function public.futbeat_bind_provider_entity(
  p_provider text,p_kind text,p_external_id text,p_canonical_id text,p_evidence jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg futbeat_private.provider_hub_config; canonical text; existing text;
begin
  select * into cfg from futbeat_private.provider_hub_config where provider=p_provider;
  if cfg.provider is null or cfg.role='PRIMARY' then
    return jsonb_build_object('status','REJECTED','reason','not_a_hub_provider');
  end if;
  if p_kind not in ('competition','team','player','match') or nullif(btrim(coalesce(p_external_id,'')),'') is null then
    return jsonb_build_object('status','REJECTED','reason','invalid_identity');
  end if;
  if coalesce(p_evidence->>'type','')<>'EXPLICIT_VERIFIED'
     or nullif(btrim(coalesce(p_evidence->>'verifiedBy','')),'') is null then
    return jsonb_build_object('status','REJECTED','reason','insufficient_evidence');
  end if;
  canonical:=futbeat_private.futbeat_resolve_entity_id(p_kind,p_canonical_id);
  if not exists(select 1 from futbeat_private.entities e where e.id=canonical and e.kind=p_kind) then
    return jsonb_build_object('status','REJECTED','reason','unknown_canonical');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('provider-bind:'||p_provider||':'||p_kind||':'||p_external_id,0));
  existing:=futbeat_private.resolve_provider_entity_strict(p_provider,p_kind,p_external_id);
  if existing is not null then
    return jsonb_build_object('status',case when existing=canonical then 'EXISTING' else 'CONFLICT' end,
      'canonicalId',existing);
  end if;
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values(p_provider,p_kind,p_external_id,canonical);
  return jsonb_build_object('status','BOUND','canonicalId',canonical);
end $$;

create table if not exists futbeat_private.provider_fixture_diagnostics(
  provider text not null,
  external_match_id text not null,
  status text not null check(status in ('AMBIGUOUS','UNMAPPED','CONFLICT')),
  detail jsonb not null default '{}'::jsonb check(jsonb_typeof(detail)='object'),
  seen_at timestamptz not null default now(),
  primary key(provider,external_match_id)
);
alter table futbeat_private.provider_fixture_diagnostics enable row level security;
revoke all on futbeat_private.provider_fixture_diagnostics from public,anon,authenticated;

-- Cross-provider fixture match (same rules as backend/providers/core/
-- matching.mjs): strictly mapped competition + home + away (no orientation
-- swap without p_orientation_swapped), kickoff within the provider's
-- tolerance, season/round only reject on a clear contradiction. MATCHED binds
-- provider_entities(kind='match'); AMBIGUOUS / UNMAPPED never publish or bind
-- anything, they only leave a private diagnostic.
create or replace function public.futbeat_match_provider_fixture(
  p_provider text,
  p_external_match_id text,
  p_competition_external_id text,
  p_home_external_id text,
  p_away_external_id text,
  p_start_time timestamptz,
  p_season text default null,
  p_round text default null,
  p_orientation_swapped boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare cfg futbeat_private.provider_hub_config; comp text; home text; away text; existing text;
  candidates text[]; result jsonb; tolerance interval;
begin
  select * into cfg from futbeat_private.provider_hub_config where provider=p_provider;
  if cfg.provider is null or cfg.role='PRIMARY' then raise exception 'Not a Provider Hub secondary provider'; end if;
  if nullif(btrim(coalesce(p_external_match_id,'')),'') is null or p_start_time is null then
    raise exception 'Invalid provider fixture';
  end if;
  tolerance:=make_interval(mins=>cfg.kickoff_tolerance_minutes);
  perform pg_advisory_xact_lock(hashtextextended('provider-bind:'||p_provider||':match:'||p_external_match_id,0));
  existing:=futbeat_private.resolve_provider_entity_strict(p_provider,'match',p_external_match_id);
  comp:=futbeat_private.resolve_provider_entity_strict(p_provider,'competition',p_competition_external_id);
  home:=futbeat_private.resolve_provider_entity_strict(p_provider,'team',p_home_external_id);
  away:=futbeat_private.resolve_provider_entity_strict(p_provider,'team',p_away_external_id);
  if comp is null or home is null or away is null or home=away then
    result:=jsonb_build_object('status','UNMAPPED','reason','unmapped_identity',
      'competitionId',comp,'homeTeamId',home,'awayTeamId',away);
  else
    select array_agg(e.id order by e.id) into candidates
    from futbeat_private.entities e
    where e.kind='match'
      and e.payload->>'homeTeamId'=case when p_orientation_swapped then away else home end
      and e.payload->>'awayTeamId'=case when p_orientation_swapped then home else away end
      and futbeat_private.futbeat_resolve_entity_id('competition',e.payload->>'competitionId')=comp
      and abs(extract(epoch from nullif(e.payload->>'startTime','')::timestamptz-p_start_time))
        <=extract(epoch from tolerance)
      and not (coalesce(futbeat_private.normalize_season(p_season),'')<>''
        and coalesce(futbeat_private.normalize_season(e.payload->>'season'),'')<>''
        and futbeat_private.normalize_season(p_season)<>futbeat_private.normalize_season(e.payload->>'season'))
      and not (nullif(btrim(coalesce(p_round,'')),'') is not null
        and nullif(btrim(coalesce(e.payload->>'round','')),'') is not null
        and lower(btrim(p_round))<>lower(btrim(e.payload->>'round')));
    result:=case coalesce(cardinality(candidates),0)
      when 0 then jsonb_build_object('status','UNMAPPED','reason','no_candidate')
      when 1 then jsonb_build_object('status','MATCHED','canonicalMatchId',candidates[1])
      else jsonb_build_object('status','AMBIGUOUS','reason','multiple_candidates','candidates',to_jsonb(candidates))
    end;
  end if;

  if result->>'status'='MATCHED' then
    if existing is not null and existing<>result->>'canonicalMatchId' then
      result:=jsonb_build_object('status','CONFLICT','reason','mapped_elsewhere',
        'canonicalMatchId',existing,'candidate',result->>'canonicalMatchId');
    elsif existing is null then
      insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
      values(p_provider,'match',p_external_match_id,result->>'canonicalMatchId');
      delete from futbeat_private.provider_fixture_diagnostics d
      where d.provider=p_provider and d.external_match_id=p_external_match_id;
      return result;
    else
      return result;
    end if;
  end if;
  insert into futbeat_private.provider_fixture_diagnostics(provider,external_match_id,status,detail,seen_at)
  values(p_provider,p_external_match_id,result->>'status',result,now())
  on conflict(provider,external_match_id) do update set status=excluded.status,detail=excluded.detail,seen_at=now();
  return result;
end $$;

revoke all on function
  futbeat_private.provider_hub_decision(text,integer),
  futbeat_private.resolve_provider_entity_strict(text,text,text)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_reserve_provider_hub_call(text,text,text,integer,jsonb),
  public.futbeat_provider_hub_status(),
  public.futbeat_bind_provider_entity(text,text,text,text,jsonb),
  public.futbeat_match_provider_fixture(text,text,text,text,text,timestamptz,text,text,boolean)
from public,anon,authenticated;
grant execute on function
  public.futbeat_reserve_provider_hub_call(text,text,text,integer,jsonb),
  public.futbeat_provider_hub_status(),
  public.futbeat_bind_provider_entity(text,text,text,text,jsonb),
  public.futbeat_match_provider_fixture(text,text,text,text,text,timestamptz,text,text,boolean)
to service_role;

notify pgrst,'reload schema';
