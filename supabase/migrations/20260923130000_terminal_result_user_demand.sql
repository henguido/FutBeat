-- Terminal result recovery on user demand. Opening a historical match whose
-- kickoff has passed but has no terminal evidence (still shows "Marcador
-- parcial") elevates that whole GOAL provider-date for result recovery,
-- instead of one call per match. Never infers FINISHED from the clock or
-- score; only real evidence (local reconciliation from stored observations,
-- or a fresh GOAL /results/date fetch) can promote status.
--
-- This builds on the existing results-date lifecycle
-- (supabase/migrations/20260921194839_competition_order_historical_reconciliation.sql):
-- futbeat_private.reserve_goal_results_date already picks a candidate date
-- via next_goal_results_candidate(), tries a zero-provider-call local repair
-- via reconcile_goal_results_local() first, and only then reserves a real
-- GOAL call under a hardcoded quota guard. We add ONE new priority lane in
-- front of that: a date a user opened in the last 24h (via
-- futbeat_request_terminal_result, called when Match Center opens a
-- historical partial) is tried first, gated by the central quota manager's
-- 'results' class, before falling back to the existing background planner
-- and its existing guard untouched. A date already resolved never re-enters
-- (0 provider calls, via the existing local-repair step). A date in
-- provider backoff (results_date_attempts.next_retry_at) is skipped even
-- when user-requested.

create table if not exists futbeat_private.results_date_user_demand(
  provider text not null,
  provider_date date not null,
  requested_at timestamptz not null default now(),
  request_count bigint not null default 1 check(request_count>0),
  primary key(provider,provider_date)
);
alter table futbeat_private.results_date_user_demand enable row level security;
revoke all on futbeat_private.results_date_user_demand from public,anon,authenticated;

update futbeat_private.provider_quota_policy
set kind_daily_caps=kind_daily_caps||'{"results-date":100}'::jsonb,updated_at=now()
where provider='goal_api' and not (kind_daily_caps ? 'results-date');

-- One canonical match -> the GOAL provider-date its kickoff falls in (UTC),
-- the same bucketing calendar_matches/calendar_coverage already use.
create or replace function futbeat_private.match_provider_date(p_match_id text)
returns date language sql stable set search_path='' as $$
  select (start_time at time zone 'UTC')::date
  from futbeat_private.calendar_matches where match_id=p_match_id
$$;

create or replace function public.futbeat_request_terminal_result(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_payload jsonb;
  v_model jsonb;
  v_status text;
  v_date date;
  v_previous timestamptz;
begin
  select payload into v_payload from futbeat_private.entities
  where id=p_match_id and kind='match';
  if v_payload is null then
    return jsonb_build_object('resultsPending',false,'reason','unknown_match');
  end if;

  v_model:=futbeat_private.match_read_model(v_payload);
  v_status:=v_model->>'status';
  if v_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED',
                  'POSTPONED','SUSPENDED','ABANDONED') then
    return jsonb_build_object('resultsPending',false,'reason','terminal');
  end if;
  -- A fresh LIVE match legitimately has hasPlayedEvidence=true (kickoff was
  -- >15 minutes ago); that is not a stuck partial, it is the match actually
  -- being played. Recovering "today" is not excluded on principle.
  if v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then
    return jsonb_build_object('resultsPending',false,'reason','live');
  end if;
  if not coalesce((v_model->>'hasPlayedEvidence')::boolean,false) then
    return jsonb_build_object('resultsPending',false,'reason','no_evidence');
  end if;

  v_date:=futbeat_private.match_provider_date(p_match_id);
  if v_date is null then
    return jsonb_build_object('resultsPending',false,'reason','unscheduled');
  end if;

  perform pg_advisory_xact_lock(hashtext('futbeat-terminal-result-request'),hashtext(v_date::text));
  select requested_at into v_previous from futbeat_private.results_date_user_demand
  where provider='goal_api' and provider_date=v_date;

  insert into futbeat_private.results_date_user_demand(provider,provider_date,requested_at,request_count)
  values('goal_api',v_date,now(),1)
  on conflict(provider,provider_date) do update set
    requested_at=now(),
    request_count=futbeat_private.results_date_user_demand.request_count+1;

  if v_previous is not null and v_previous>now()-interval '5 minutes' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('terminal_result_user_demands');
    perform futbeat_private.wake_provider_worker('results-only');
  end if;

  return jsonb_build_object('resultsPending',true,'providerDate',v_date);
end
$$;

-- Same signature/behavior as the current implementation, with one new block:
-- try a user-requested date first (central 'results' quota class), then fall
-- back to the unmodified background planner and its unmodified guard.
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
  select coalesce(sum(case when status='SUCCEEDED' then greatest(
    coalesce((metadata->>'providerRequests')::integer,1),1) else 1 end),0)::integer
    into v_used from futbeat_private.provider_call_ledger where provider='goal_api'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select count(*)::integer into v_results_used from futbeat_private.provider_call_ledger
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

-- The wake for terminal-result recovery reuses the worker's existing
-- 'results-only' branch (supabase/functions/futbeat-goal-live-sync/index.ts,
-- the same trigger the 2-hourly results cron already posts), so opening a
-- stale historical match runs a real syncOneResultsDate() call instead of
-- falling through the Deno.serve handler's default branch (which runs
-- syncLive/detail/squad/news/video and never touches results at all). It
-- still debounces separately from the match-detail/player 'demand' lane, so
-- a stale historical open never competes with a live Match Center's detail
-- refresh budget.
create or replace function futbeat_private.wake_provider_worker(p_trigger text default 'demand')
returns text language plpgsql security definer set search_path='' as $$
declare debounce interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','wakeDebounceSeconds',15));
  last_wake timestamptz; url text; result text;
begin
  if p_trigger is null or p_trigger not in ('demand','results-only') then raise exception 'Invalid wake trigger'; end if;
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

revoke all on function futbeat_private.match_provider_date(text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_request_terminal_result(text)
from public,anon,authenticated;
grant execute on function public.futbeat_request_terminal_result(text) to service_role;

notify pgrst,'reload schema';
