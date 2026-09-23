-- Central provider quota manager, demand metrics and worker wake-up.
--
-- Quota: ONE policy row per provider decides every provider call from the
-- provider-reported remaining budget (x-ratelimit-remaining, stored on the
-- ledger), instead of fixed development caps repeated per function.
--   * class_floors: a call of a given priority class is allowed only while
--     remaining > floor. Initial bands (configurable, one place):
--       remaining > 600      -> everything, including bootstrap
--       300 < remaining<=600 -> user demand + priority coverage
--       150 < remaining<=300 -> high-priority user demand + LIVE/results
--       remaining <= 150     -> LIVE/results only (hard reserve)
--   * kind_daily_caps: per call_kind safety caps so a bug cannot burn the
--     whole budget; not a product policy.
--   * freshness: TTLs used by the demand queues (profile vs stats, search,
--     negative cache, demand window).
-- Unknown remaining (no reading yet today) allows LIVE/results freely; every
-- other class also stops once today's total calls reach unknownDailyCap
-- (conservative, in case the provider never reports remaining), and each such
-- kind may use at most unknownKindShare of that total, so no single lane
-- (e.g. player search) can consume the whole blind budget. The per-kind
-- safety caps always apply.
--
-- Metrics: sharded daily counters (no single hot row under concurrency).
--
-- Wake-up: wake_provider_worker() posts to the GOAL worker through pg_net
-- right after demand is recorded (sent after commit), debounced per trigger.
-- The cron token is read from Vault inside the database and sent only to our
-- own worker URL; it never reaches the mobile app or any API response.
-- Without pg_net/Vault (local PGlite) it records the attempt and returns
-- 'unavailable'; the per-minute cron still drains demand.

create table if not exists futbeat_private.provider_quota_policy(
  provider text primary key,
  class_floors jsonb not null check(jsonb_typeof(class_floors)='object'),
  kind_daily_caps jsonb not null check(jsonb_typeof(kind_daily_caps)='object'),
  kind_groups jsonb not null default '{}'::jsonb check(jsonb_typeof(kind_groups)='object'),
  freshness jsonb not null default '{}'::jsonb check(jsonb_typeof(freshness)='object'),
  updated_at timestamptz not null default now()
);
alter table futbeat_private.provider_quota_policy enable row level security;
revoke all on futbeat_private.provider_quota_policy from public,anon,authenticated;

insert into futbeat_private.provider_quota_policy(provider,class_floors,kind_daily_caps,kind_groups,freshness)
values('goal_api',
  '{"live":20,"results":20,"user_high":150,"user":300,"coverage":300,"bootstrap":600}',
  '{"match-detail":400,"team-squad":150,"player-search":150,"player-profile":250,"player-stats":250}',
  '{"team-squad":["team-squad","team-squad-ingest"]}',
  '{"playerProfileDays":30,"playerStatsHours":12,"playerSearchDays":7,
    "playerSearchNegativeDays":3,"playerNoDataDays":30,"demandWindowMinutes":30,
    "leaseMinutes":10,"wakeDebounceSeconds":15,"unknownDailyCap":600,"unknownKindShare":0.25,
    "playerStatsNoDataDays":3,"searchAdmissionWindowMinutes":5,"searchAdmissionsPerWindow":60,
    "searchQueueMax":200}')
on conflict(provider) do nothing;

create table if not exists futbeat_private.runtime_settings(
  key text primary key,
  value text not null
);
alter table futbeat_private.runtime_settings enable row level security;
revoke all on futbeat_private.runtime_settings from public,anon,authenticated;
insert into futbeat_private.runtime_settings(key,value) values
  ('goal_worker_url','https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-goal-live-sync')
on conflict(key) do nothing;

-- Latest provider-reported remaining budget of the current UTC day.
create or replace function futbeat_private.provider_remaining(p_provider text)
returns integer language sql stable set search_path='' as $$
  select provider_remaining from futbeat_private.provider_call_ledger
  where provider=p_provider and provider_remaining is not null
    and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1
$$;

create or replace function futbeat_private.quota_setting(p_provider text,p_key text,p_default numeric)
returns numeric language sql stable set search_path='' as $$
  select coalesce((select (freshness->>p_key)::numeric from futbeat_private.provider_quota_policy
    where provider=p_provider),p_default)
$$;

-- Same UTC-day advisory lock every GOAL reservation already takes.
create or replace function futbeat_private.lock_provider_quota(p_provider text)
returns void language sql set search_path='' as $$
  select pg_advisory_xact_lock(hashtext('futbeat-provider-quota:'||p_provider||':'
    ||(date_trunc('day',now() at time zone 'UTC'))::date::text))
$$;

create or replace function futbeat_private.quota_class_allowed(p_provider text,p_class text,p_remaining integer)
returns boolean language sql stable set search_path='' as $$
  select p_remaining is null or p_remaining>(
    select (class_floors->>p_class)::integer from futbeat_private.provider_quota_policy where provider=p_provider)
$$;

-- The single quota decision. Callers hold lock_provider_quota() and insert
-- their ledger row in the same transaction when allowed.
create or replace function futbeat_private.quota_decision(p_provider text,p_kind text,p_class text)
returns jsonb language plpgsql stable set search_path='' as $$
declare policy futbeat_private.provider_quota_policy; remaining integer; floor_value integer;
  cap integer; used integer; kinds text[]; total integer; unknown_cap integer;
begin
  select * into policy from futbeat_private.provider_quota_policy where provider=p_provider;
  if policy is null then raise exception 'No quota policy for provider %',p_provider; end if;
  floor_value:=(policy.class_floors->>p_class)::integer;
  if floor_value is null then raise exception 'Unknown quota class %',p_class; end if;
  cap:=(policy.kind_daily_caps->>p_kind)::integer;
  if cap is null then raise exception 'No safety cap for call kind %',p_kind; end if;
  kinds:=coalesce(array(select jsonb_array_elements_text(policy.kind_groups->p_kind)),array[p_kind]);
  if cardinality(kinds)=0 then kinds:=array[p_kind]; end if;
  remaining:=futbeat_private.provider_remaining(p_provider);
  select count(*)::integer,count(*) filter(where call_kind=any(kinds))::integer into total,used
  from futbeat_private.provider_call_ledger
  where provider=p_provider
    and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  unknown_cap:=coalesce((policy.freshness->>'unknownDailyCap')::integer,600);
  if remaining is null and p_class not in ('live','results') then
    cap:=least(cap,floor(unknown_cap*coalesce((policy.freshness->>'unknownKindShare')::numeric,0.25))::integer);
  end if;
  return jsonb_build_object(
    'allowed',(remaining is null or remaining>floor_value) and used<cap
      and not (remaining is null and p_class not in ('live','results') and total>=unknown_cap),
    'reason',case when remaining is not null and remaining<=floor_value then 'provider_remaining_reserve'
      when used>=cap then 'kind_daily_cap'
      when remaining is null and p_class not in ('live','results') and total>=unknown_cap then 'unknown_budget_cap' end,
    'provider',p_provider,'kind',p_kind,'class',p_class,'providerRemaining',remaining,
    'floor',floor_value,'usedToday',used,'safetyCap',cap,'totalToday',total,
    'band',case when remaining is null then 'unknown'
      when remaining>(policy.class_floors->>'bootstrap')::integer then 'abundant'
      when remaining>(policy.class_floors->>'user')::integer then 'normal'
      when remaining>(policy.class_floors->>'user_high')::integer then 'tight'
      else 'critical' end);
end $$;

-- Sharded daily counters.
create table if not exists futbeat_private.demand_metrics(
  day date not null,
  metric text not null,
  shard smallint not null,
  value bigint not null default 0,
  primary key(day,metric,shard)
);
alter table futbeat_private.demand_metrics enable row level security;
revoke all on futbeat_private.demand_metrics from public,anon,authenticated;

create or replace function futbeat_private.bump_metric(p_metric text,p_by bigint default 1)
returns void language sql security definer set search_path='' as $$
  insert into futbeat_private.demand_metrics(day,metric,shard,value)
  values((now() at time zone 'UTC')::date,p_metric,(floor(random()*16))::smallint,p_by)
  on conflict(day,metric,shard) do update set value=futbeat_private.demand_metrics.value+excluded.value
$$;

create table if not exists futbeat_private.worker_wakeups(
  trigger text primary key,
  last_wake_at timestamptz not null,
  wake_count bigint not null default 0,
  debounced_count bigint not null default 0,
  last_result text
);
alter table futbeat_private.worker_wakeups enable row level security;
revoke all on futbeat_private.worker_wakeups from public,anon,authenticated;

create or replace function futbeat_private.wake_provider_worker(p_trigger text default 'demand')
returns text language plpgsql security definer set search_path='' as $$
declare debounce interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','wakeDebounceSeconds',15));
  last_wake timestamptz; url text; result text;
begin
  if p_trigger is null or p_trigger not in ('demand') then raise exception 'Invalid wake trigger'; end if;
  -- Never queue request transactions behind each other on this shared row:
  -- whoever finds it locked (another request is waking right now) or recent
  -- simply skips; the debounce counter is a sharded metric.
  select w.last_wake_at into last_wake from futbeat_private.worker_wakeups w
  where w.trigger=p_trigger for update skip locked;
  if not found then
    if exists(select 1 from futbeat_private.worker_wakeups where trigger=p_trigger) then
      perform futbeat_private.bump_metric('wake_debounced');
      return 'debounced';
    end if;
    insert into futbeat_private.worker_wakeups(trigger,last_wake_at,wake_count)
    values(p_trigger,now(),1) on conflict(trigger) do nothing;
    if not found then
      perform futbeat_private.bump_metric('wake_debounced');
      return 'debounced';
    end if;
  elsif last_wake>now()-debounce then
    perform futbeat_private.bump_metric('wake_debounced');
    return 'debounced';
  else
    update futbeat_private.worker_wakeups set last_wake_at=now(),wake_count=wake_count+1 where trigger=p_trigger;
  end if;
  select value into url from futbeat_private.runtime_settings where key='goal_worker_url';
  if to_regnamespace('net') is null or to_regnamespace('vault') is null or url is null then
    result:='unavailable';
  else
    execute $q$select net.http_post(
        url:=$1,
        headers:=jsonb_build_object('Content-Type','application/json','x-futbeat-cron-token',(
          select decrypted_secret from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token' order by updated_at desc nulls last,created_at desc limit 1)),
        body:=jsonb_build_object('trigger',$2),
        timeout_milliseconds:=30000)$q$ using url,p_trigger;
    result:='queued';
  end if;
  update futbeat_private.worker_wakeups set last_result=result where trigger=p_trigger;
  return result;
end $$;

-- Squads: replace the fixed 16/day + remaining<=350 development limits with
-- the central manager (class 'coverage', safety cap 'team-squad'). Everything
-- else in this reservation is unchanged.
create or replace function futbeat_private.reserve_squad_before_coverage(
  p_team_id text,
  p_external_team_id text,
  p_trigger_source text default 'github-actions'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_decision jsonb;
  v_id bigint;
begin
  if nullif(p_team_id,'') is null
     or nullif(p_external_team_id,'') is null
     or nullif(btrim(p_trigger_source),'') is null
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind='team'
         and pe.external_id=p_external_team_id
         and pe.canonical_id=p_team_id
     )
  then
    raise exception 'Invalid GOAL squad reservation';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  v_decision:=futbeat_private.quota_decision('goal_api','team-squad','coverage');
  if not (v_decision->>'allowed')::boolean then
    return v_decision;
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','team-squad',left(p_trigger_source,40),now(),
    jsonb_build_object('teamId',p_team_id,'externalTeamId',p_external_team_id)
  )
  returning id into v_id;

  return v_decision||jsonb_build_object(
    'reservationId',v_id,
    'usedToday',(v_decision->>'usedToday')::integer+1,
    'teamId',p_team_id,
    'externalTeamId',p_external_team_id
  );
end
$$;

-- Service-only diagnostics.
create or replace function public.futbeat_provider_quota_status(p_provider text default 'goal_api')
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'provider',p_provider,
    'providerRemaining',futbeat_private.provider_remaining(p_provider),
    'policy',(select to_jsonb(p)-'provider' from futbeat_private.provider_quota_policy p where p.provider=p_provider),
    'callsByKind',(select coalesce(jsonb_object_agg(call_kind,n),'{}') from (
      select call_kind,count(*) n from futbeat_private.provider_call_ledger
      where provider=p_provider
        and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
      group by call_kind) k))
$$;

revoke all on function
  futbeat_private.provider_remaining(text),
  futbeat_private.quota_setting(text,text,numeric),
  futbeat_private.lock_provider_quota(text),
  futbeat_private.quota_class_allowed(text,text,integer),
  futbeat_private.quota_decision(text,text,text),
  futbeat_private.bump_metric(text,bigint),
  futbeat_private.wake_provider_worker(text),
  futbeat_private.reserve_squad_before_coverage(text,text,text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_provider_quota_status(text) from public,anon,authenticated;
grant execute on function public.futbeat_provider_quota_status(text) to service_role;

notify pgrst,'reload schema';
