-- GOAL LIVE as a protected class of the central quota manager, and generic
-- overdue-SCHEDULED recovery (Issue #111).
--
-- Root cause in code: futbeat_private.futbeat_reserve_goal_live_call (last
-- defined in 20260919174500) predates the central quota manager. It kept its
-- own copy of the reserve (remaining <= 20), a blind fallback (950 total calls
-- when the remaining budget is unknown) and a fixed LIVE window of kickoff
-- -5 min .. +135 min read from the raw entity status. So:
--   * LIVE shared the bottom of the budget with every other lane but was not
--     part of the central class policy (no 'live-goal' safety cap, no single
--     source of truth for its floor);
--   * a SCHEDULED match whose kickoff passed more than 135 minutes ago (late
--     start, slow provider status, missed ingest, recovery after a quota
--     outage) stopped driving the global LIVE poll, even while it was still
--     within the central liveMaxHours window.
--
-- Now:
--   * the reservation uses quota_decision('goal_api','live-goal','live'): the
--     central 'live' floor (class_floors.live, the only reserve), the new
--     kind_daily_caps['live-goal'] safety cap (independent of match-detail and
--     every other kind), and no blind fallback for LIVE (class 'live' is
--     exempt from the unknown-budget caps, as for results);
--   * futbeat_private.live_poll_need(provider) decides whether a LIVE poll is
--     needed: mapped matches whose kickoff is within
--     [now - liveMaxHours, now + liveWindowLeadMinutes] and whose canonical
--     status is not terminal. Each is classified as live (live evidence),
--     upcoming (before kickoff) or overdueScheduled (kickoff passed, no live
--     evidence, not terminal). Overdue matches keep the single global
--     /fixtures/live poll running; there is never one call per match;
--   * the clock never changes a status: overdue only means "verify with
--     priority". LIVE/HALFTIME/.../terminal states still come only from
--     provider evidence (futbeat_record_live_batch + the read model), and a
--     LIVE status past liveMaxHours is not live evidence (match_detail_status);
--   * the minimum interval between LIVE polls is liveMinIntervalSeconds (240,
--     tolerating five-minute cron jitter);
--   * caps and the blind budget count provider REQUEST UNITS, not ledger rows:
--     a paginated call records metadata.providerRequests (every attempted
--     request, failures included); rows without it count as 1
--     (provider_call_units). x-ratelimit-remaining stays the primary truth;
--   * a LIVE poll gets a page budget (remaining - live floor, the room left in
--     the live-goal cap and livePageLimit) and stops paging when the observed
--     remaining reaches the floor. A truncated batch is recorded as such, the
--     next poll resumes from its offset, and matches on unread pages are left
--     untouched (absence is never evidence).

update futbeat_private.provider_quota_policy set
  kind_daily_caps=kind_daily_caps||'{"live-goal":400}',
  freshness=freshness||'{"liveWindowLeadMinutes":5,"liveMinIntervalSeconds":240,"livePageLimit":10}',
  updated_at=now()
where provider='goal_api';

-- ---------------------------------------------------------------------------
-- Provider request units. A reservation may cover several real provider
-- requests (pagination); the worker stores the count as
-- metadata.providerRequests. Rows without it (every non-paginated kind, old
-- rows) count conservatively as 1. A LIVE reservation in flight carries its
-- whole pageBudget; completion replaces it with the real count. Invalid
-- values count as 1; a single call is bounded to 1000 units (clamped as
-- numeric before the cast, so a huge value never overflows integer).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.provider_call_units(p_metadata jsonb)
returns integer language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_metadata->'providerRequests')='number'
    then least(greatest(floor((p_metadata->>'providerRequests')::numeric),1),1000)::integer
    else 1 end
$$;
revoke all on function futbeat_private.provider_call_units(jsonb) from public,anon,authenticated,service_role;

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
  -- Provider request units (a paginated call spends several), not rows.
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer,
    coalesce(sum(futbeat_private.provider_call_units(metadata)) filter(where call_kind=any(kinds)),0)::integer
  into total,used
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
      group by call_kind) k),
    -- Provider request units per kind (what caps and the blind budget count).
    'requestUnitsByKind',(select coalesce(jsonb_object_agg(call_kind,n),'{}') from (
      select call_kind,sum(futbeat_private.provider_call_units(metadata)) n from futbeat_private.provider_call_ledger
      where provider=p_provider
        and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
      group by call_kind) k),
    'live',(select jsonb_build_object(
        'pollCyclesToday',count(*),
        'providerRequestsToday',coalesce(sum(futbeat_private.provider_call_units(metadata)),0),
        'averagePagesPerPoll',round(coalesce(avg(futbeat_private.provider_call_units(metadata)),0),2),
        'paginationTruncatedToday',count(*) filter(where metadata->>'paginationTruncated'='true'),
        'lastProviderRequests',(select futbeat_private.provider_call_units(l2.metadata)
          from futbeat_private.provider_call_ledger l2 where l2.provider=p_provider and l2.call_kind='live-goal'
          order by l2.reserved_at desc,l2.id desc limit 1))
      from futbeat_private.provider_call_ledger
      where provider=p_provider and call_kind='live-goal'
        and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'))
$$;

create or replace function futbeat_private.reserve_goal_results_date(
  p_trigger_source text default 'supabase-cron'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_date date; v_id bigint; v_remaining integer; v_used integer;
  v_results_used integer; v_local jsonb; v_attempt integer; v_user_priority boolean:=false;
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-provider-quota:goal_api:'||(now() at time zone 'UTC')::date::text));
  -- Retain 90 days, well beyond the 14-day automatic window. Primary key
  -- supports deletion by provider/date; old evidence remains in observations.
  delete from futbeat_private.results_date_attempts
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  -- Indexed by (provider,provider_date,state); never scans JSON.
  delete from futbeat_private.match_result_reconciliation
    where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;
  delete from futbeat_private.results_date_user_demand
    where provider='goal_api' and requested_at<now()-interval '90 days';

  -- A date a user opened in the last 24h, not yet reserved since that
  -- request and not in provider backoff, jumps the background planner --
  -- but only while the central 'results' quota class allows it, so a flood
  -- of user opens cannot outrun the budget everything else shares.
  select d.provider_date into v_date
  from futbeat_private.results_date_user_demand d
  left join futbeat_private.results_date_attempts a
    on a.provider='goal_api' and a.provider_date=d.provider_date
  where d.provider='goal_api' and d.requested_at>now()-interval '24 hours'
    -- Outside the 90-day retention window, results_date_attempts rows for
    -- this date are deleted every call below, so no backoff could ever
    -- stick and a single stale request would win every reservation.
    and d.provider_date>=(now() at time zone 'UTC')::date-90
    and (a.next_retry_at is null or a.next_retry_at<=now())
    and (a.updated_at is null or a.updated_at<d.requested_at)
  order by d.requested_at desc limit 1;
  if v_date is not null then
    v_user_priority:=true;
    if not coalesce((futbeat_private.quota_decision('goal_api','results-date','results')->>'allowed')::boolean,false) then
      v_date:=null;
      v_user_priority:=false;
    end if;
  end if;

  if v_date is null then
    v_date:=futbeat_private.next_goal_results_candidate();
  end if;
  if v_date is null then return jsonb_build_object('allowed',false,'reason','no_results_due'); end if;
  v_local:=futbeat_private.reconcile_goal_results_local(v_date);
  if coalesce((v_local->>'resultsComplete')::boolean,false) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at,updated_at)
    values('goal_api',v_date,'LOCAL_REPAIRED',now(),now())
    on conflict(provider,provider_date) do update set last_outcome='LOCAL_REPAIRED',
      next_retry_at=now(),updated_at=now();
    return jsonb_build_object('allowed',false,'reason','reconciled_locally','date',v_date,'localRepair',v_local);
  end if;
  select provider_remaining into v_remaining from futbeat_private.provider_call_ledger
    where provider='goal_api' and provider_remaining is not null
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
    order by coalesce(completed_at,reserved_at) desc,id desc limit 1;
  -- Provider request units of every call (failed paginated calls included).
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select coalesce(sum(futbeat_private.provider_call_units(metadata)),0)::integer into v_results_used
    from futbeat_private.provider_call_ledger
    where provider='goal_api' and call_kind='results-date'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  -- A user-priority date already cleared the central 'results' quota class
  -- above; it is not re-gated by the legacy fixed thresholds below, which
  -- remain exactly as they were for the unmodified background path.
  if not v_user_priority and (v_results_used>=60 or v_used>=880 or (v_remaining is not null and v_remaining<=120)) then
    insert into futbeat_private.results_date_attempts(provider,provider_date,last_outcome,next_retry_at)
    values('goal_api',v_date,'QUOTA_DEFERRED',now()+interval '30 minutes')
    on conflict(provider,provider_date) do update set last_outcome='QUOTA_DEFERRED',
      next_retry_at=now()+interval '30 minutes',updated_at=now();
    return jsonb_build_object('allowed',false,'reason','results_quota_guard','localRepair',v_local,
      'usedToday',v_used,'resultsUsedToday',v_results_used,'providerRemaining',v_remaining);
  end if;
  insert into futbeat_private.results_date_attempts(
    provider,provider_date,last_attempt_at,attempt_count,last_outcome,next_retry_at,updated_at)
  values('goal_api',v_date,now(),1,'RESERVED',now()+futbeat_private.results_retry_delay(v_date,1),now())
  on conflict(provider,provider_date) do update set last_attempt_at=now(),
    attempt_count=futbeat_private.results_date_attempts.attempt_count+1,
    last_outcome='RESERVED',next_retry_at=now()+futbeat_private.results_retry_delay(
      v_date,futbeat_private.results_date_attempts.attempt_count+1),updated_at=now()
  returning attempt_count into v_attempt;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','results-date',left(p_trigger_source,40),now(),
    jsonb_build_object('date',v_date,'attempt',v_attempt,'userPriority',v_user_priority)) returning id into v_id;
  return jsonb_build_object('allowed',true,'reservationId',v_id,'date',v_date,
    'attempt',v_attempt,'localRepair',v_local,'providerRemaining',v_remaining,'userPriority',v_user_priority);
end $$;

-- Whether the global LIVE poll is needed for a provider (DB-only, generic).
create or replace function futbeat_private.live_poll_need(p_provider text default 'goal_api')
returns jsonb language sql stable security definer set search_path='' as $$
  with bounds as (
    select now()-make_interval(hours=>futbeat_private.quota_setting(p_provider,'liveMaxHours',4)::integer) lo,
      now()+make_interval(mins=>futbeat_private.quota_setting(p_provider,'liveWindowLeadMinutes',5)::integer) hi
  ), window_matches as (
    select cm.match_id,cm.start_time,futbeat_private.match_detail_status(cm.match_id) status
    from bounds b
    join futbeat_private.calendar_matches cm on cm.start_time>=b.lo and cm.start_time<=b.hi
    where exists(select 1 from futbeat_private.provider_entities pe
      where pe.provider=p_provider and pe.kind='match' and pe.canonical_id=cm.match_id)
  ), classified as (
    select w.*,case
      when coalesce(w.status,'') in ('FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','POSTPONED','ABANDONED')
        then 'terminal'
      when w.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
      when w.start_time>now() then 'upcoming'
      -- Kickoff passed, no live evidence, not terminal (SCHEDULED, PRE_MATCH,
      -- DISCOVERED, SUSPENDED, a stale LIVE, or no status at all).
      else 'overdue'
    end cls
    from window_matches w
  )
  select jsonb_build_object(
    'active',count(*) filter(where cls<>'terminal'),
    'live',count(*) filter(where cls='live'),
    'upcoming',count(*) filter(where cls='upcoming'),
    'overdueScheduled',count(*) filter(where cls='overdue'),
    'terminal',count(*) filter(where cls='terminal'),
    'windowHours',futbeat_private.quota_setting(p_provider,'liveMaxHours',4),
    -- Bounded lookup: only the nearest upcoming kickoffs are inspected.
    'nextStart',(select min(n.start_time) from (
        select cm.match_id,cm.start_time from futbeat_private.calendar_matches cm
        where cm.start_time>now() order by cm.start_time limit 200) n
      where exists(select 1 from futbeat_private.provider_entities pe
          where pe.provider=p_provider and pe.kind='match' and pe.canonical_id=n.match_id)
        and coalesce(futbeat_private.match_detail_status(n.match_id),'')
          not in ('FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','POSTPONED','ABANDONED')))
  from classified
$$;

create or replace function futbeat_private.futbeat_reserve_goal_live_call(
  p_trigger_source text default 'cron'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_need jsonb;
  v_decision jsonb;
  v_last timestamptz;
  v_min_interval integer:=futbeat_private.quota_setting('goal_api','liveMinIntervalSeconds',240)::integer;
  v_id bigint;
  v_base jsonb;
  v_remaining integer;
  v_page_budget integer;
  v_start_offset integer:=0;
  v_prev jsonb;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  -- Read-only need first (outside the lock), then the same daily quota lock as
  -- every GOAL reservation for the decision, interval and ledger insert.
  v_need:=futbeat_private.live_poll_need('goal_api');
  perform futbeat_private.lock_provider_quota('goal_api');
  v_decision:=futbeat_private.quota_decision('goal_api','live-goal','live');
  v_base:=jsonb_build_object(
    'reserve',(v_decision->>'floor')::integer,
    'providerRemaining',v_decision->'providerRemaining',
    'usedToday',(v_decision->>'totalToday')::integer,
    'liveUsed',(v_decision->>'usedToday')::integer,
    'safetyCap',(v_decision->>'safetyCap')::integer,
    'band',v_decision->>'band',
    'activeMatches',(v_need->>'active')::integer,
    'liveMatches',(v_need->>'live')::integer,
    'upcomingMatches',(v_need->>'upcoming')::integer,
    'overdueScheduled',(v_need->>'overdueScheduled')::integer,
    'nextStart',v_need->'nextStart');

  -- No mapped match is live, about to start or overdue: spend nothing.
  if (v_need->>'active')::integer=0 then
    return v_base||jsonb_build_object('allowed',false,'reason','outside_live_window');
  end if;

  -- Central policy: the 'live' floor is the only reserve; live-goal has its
  -- own safety cap, independent of match-detail and background kinds.
  if not (v_decision->>'allowed')::boolean then
    return v_base||jsonb_build_object('allowed',false,'reason',v_decision->>'reason');
  end if;

  select max(l.reserved_at) into v_last
  from futbeat_private.provider_call_ledger l
  where l.provider='goal_api' and l.call_kind='live-goal'
    and l.reserved_at>now()-make_interval(secs=>v_min_interval);
  if v_last is not null then
    return v_base||jsonb_build_object('allowed',false,'reason','min_interval',
      'retryAfterSeconds',greatest(0,v_min_interval-extract(epoch from (now()-v_last))::integer));
  end if;

  -- Page budget: never page through the protected live reserve, never past
  -- the live-goal safety cap (both in provider request units).
  v_remaining:=(v_decision->>'providerRemaining')::integer;
  v_page_budget:=least(
    futbeat_private.quota_setting('goal_api','livePageLimit',10)::integer,
    (v_decision->>'safetyCap')::integer-(v_decision->>'usedToday')::integer,
    coalesce(v_remaining-(v_decision->>'floor')::integer,2147483647));
  v_page_budget:=greatest(v_page_budget,1);
  -- Resume after a truncated batch so unread pages are not starved.
  select l.metadata into v_prev from futbeat_private.provider_call_ledger l
  where l.provider='goal_api' and l.call_kind='live-goal' and l.completed_at is not null
  order by l.reserved_at desc,l.id desc limit 1;
  if v_prev->>'paginationTruncated'='true' and jsonb_typeof(v_prev->'resumeOffset')='number' then
    v_start_offset:=greatest(0,(v_prev->>'resumeOffset')::integer);
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values('goal_api','live-goal',left(p_trigger_source,40),now(),
    jsonb_build_object('activeMatches',(v_need->>'active')::integer,
      'liveMatches',(v_need->>'live')::integer,
      'overdueScheduled',(v_need->>'overdueScheduled')::integer,
      'pageBudget',v_page_budget,'startOffset',v_start_offset,
      -- Conservative in-flight units: the whole page budget is committed
      -- until completion merges the real count (completion values win).
      'providerRequests',v_page_budget))
  returning id into v_id;
  if (v_need->>'overdueScheduled')::integer>0 then
    perform futbeat_private.bump_metric('live_polls_with_overdue_scheduled');
  end if;

  return v_base||jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'pageBudget',v_page_budget,
    'startOffset',v_start_offset,
    'usedToday',(v_decision->>'totalToday')::integer+v_page_budget,
    'liveUsed',(v_decision->>'usedToday')::integer+v_page_budget);
end
$$;

-- Service-only diagnostics for production verification.
create or replace function public.futbeat_live_poll_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'need',futbeat_private.live_poll_need('goal_api'),
    'quota',futbeat_private.quota_decision('goal_api','live-goal','live'),
    'lastLiveCall',(select max(reserved_at) from futbeat_private.provider_call_ledger
      where provider='goal_api' and call_kind='live-goal'),
    'minIntervalSeconds',futbeat_private.quota_setting('goal_api','liveMinIntervalSeconds',240))
$$;

revoke all on function futbeat_private.live_poll_need(text) from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_reserve_goal_live_call(text) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_reserve_goal_live_call(text) to service_role;
revoke all on function public.futbeat_live_poll_status() from public,anon,authenticated;
grant execute on function public.futbeat_live_poll_status() to service_role;

notify pgrst,'reload schema';
