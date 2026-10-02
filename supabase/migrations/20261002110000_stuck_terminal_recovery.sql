-- Stuck non-terminal matches: a match FutBeat saw in play must eventually get
-- a final from the provider, even when every fast path missed it.
--
-- Evidence (read-only production diagnostics, 2026-10-02):
--   * 1,944 canonical matches with kickoff 1-14 days ago were last seen in
--     play (LIVE 1,585 / HALFTIME 355 / PENALTIES 4), with no terminal
--     observation and the read model still SCHEDULED. All on the four busy
--     days of the window: 2026-09-19 (908), 09-20 (419), 09-26 (318),
--     09-27 (300). None has a recovery row any more (deleted 3 days after
--     settling) and every one has match_result_reconciliation state
--     'missing_from_provider'.
--   * On those days GOAL caps both bulk lists: /fixtures/live reported
--     total=100 (max 100 fixtures per poll, never paginated further) and
--     /results/date/{d} returns at most 500 rows (offset 500 never makes
--     progress: "pagination cannot make progress", 12 failed calls), for
--     1,107-1,496 calendar matches per day. A fixture that rotates out of the
--     capped live list before full time and is not among the 500 results
--     never reaches FutBeat through the bulk lanes.
--   * Terminal recovery (one detail call per fixture) expired before quota
--     returned on those days (6 h window), and the results lane closed the
--     dates after 4 attempts + 48 h: reconcile_goal_results_local marks the
--     rest 'missing_from_provider', the date counts as complete, the
--     background planner never picks it again and a terminal-result demand
--     is answered by the local repair (0 calls, no evidence).
--   * 2026-09-19 and 09-27 never recorded a single results answer (pagination
--     stall before the worker kept partial pages; then the record RPC hit the
--     8 s statement timeout, see the worker change in the same commit).
--
-- Fix (generic; provider evidence only; never the clock; no quota policy
-- change: everything below runs inside the existing 'results' class and
-- the existing recovery guard above the user_high floor):
--   1. Date reopen. A provider date in the results window whose results lane
--      gave up (>= 4 attempts) while it still holds matches seen in play and
--      not final is offered to the results lane again: its attempt counter is
--      lowered to one below the give-up threshold (exactly ONE more results
--      answer) and the date is queued in results_date_user_demand (same
--      queue, quota class, caps and per-date backoff as a user opening a
--      match). At most stuckResultsMaxReopens (2) reopens per date, at least
--      stuckResultsReopenHours (12) apart, stuckReopenDatesPerSweep (2) per
--      sweep, never while the date is in provider backoff or already queued,
--      and only while the provider budget is above the user_high floor
--      (provider remaining minus in-flight reservations, the recovery guard).
--      A date whose last results attempt failed at the record stage (the
--      statement timeout fixed by chunked recording) gets one reopen even
--      without stuck matches.
--      Big dates are never reopened: the reservation's local repair
--      (reconcile_goal_results_local) locks every calendar match of the date
--      inside the provider quota lock and takes 6-8 s for ~1,100-1,500
--      matches, at the 8 s statement timeout; a timed-out reservation would
--      leave the demand queued and stall the results lane. A date with more
--      than stuckReopenMaxDateMatches (600) calendar matches is marked as
--      spent instead (skipped_reason 'date_too_large') and its stuck matches
--      go straight to the detail path.
--   2. Detail request. A stuck match whose date was already answered by the
--      results lane after its kickoff (GOAL's list did not carry it) or whose
--      reopen budget is spent gets a terminal-recovery row with reason
--      'stuck_nonterminal' (the existing /fixtures/{id} recovery path, with
--      its quota guard and inflight lock). Bounded: stuckDetailMaxRequests (2)
--      requests per match, stuckDetailRetryHours (24) apart; at most
--      stuckDetailDailyRequests (40) per UTC day, stuckDetailMaxPending (4)
--      pending and stuckDetailBatch (4) per sweep; each row makes at most
--      stuckDetailMaxAttempts (2) calls, stuckDetailRetryMinutes (180) apart,
--      and lives stuckDetailWindowHours (24). Fresh recoveries (absent /
--      overdue LIVE of today's games) are always served first.
--   3. The sweep is its own service-only RPC pair, called by the detail
--      worker before it reserves a recovery call (no new cron): a claim
--      (commits the throttle, once per stuckSweepMinutes = 15) and a run.
--      It never runs inside the provider quota lock and a slow or failed
--      sweep never fails a reservation; the committed claim keeps a failing
--      sweep from retrying every minute. Candidates are computed once per run
--      (driven by the in-play rows of live_match_state; production ~70 ms
--      warm, ~2.8 s cold).
--   4. Late pushes. Provider answers for old matches would create "first
--      seen" GOAL / FULL_TIME events days later. Outbox rows for match events
--      more than matchPushMaxAgeHours (8) after the match's EFFECTIVE kickoff
--      are dropped at insert (canonical events are still stored); metric
--      stale_match_push_skipped. Effective kickoff: the newest of the stored
--      startTime and the provider's kickoffUtc on the latest observation; a
--      match the provider reported in play within the last 60 minutes always
--      pushes (rescheduled / suspended-and-resumed games). Product behaviour
--      change: every match push later than that is dropped.
-- Worst case per UTC day (all limits at their defaults): detail recovery
-- 40 requests x 2 calls = 80 match-detail units; reopens 2 dates per sweep,
-- in practice bounded by the dates in the window (each date at most 2
-- reopens, 1 for a record failure), 1-5 units each: about 10-20 units on the
-- first day after deploy, ~0-4/day after. Typical: ~40-60 units/day.
-- A match is "stuck" when: kickoff in the last stuckTerminalWindowDays (14)
-- days and older than stuckTerminalHours (6) h, a GOAL mapping, the latest
-- live state of that mapping is in play and seen after kickoff, the canonical
-- status is not terminal and the read model is not terminal. Matches never
-- seen in play are not chased (no evidence they were played); they still
-- benefit from a reopened date's results answer.
-- Only provider answers recorded through the normal pipeline can close a
-- match; nothing here writes a status or a score.

-- ---------------------------------------------------------------------------
-- Bookkeeping
-- ---------------------------------------------------------------------------
do $$ declare c record; begin
  for c in select con.conname from pg_constraint con
    where con.conrelid='futbeat_private.live_terminal_recovery'::regclass and con.contype='c'
      and pg_get_constraintdef(con.oid) like '%reason%'
  loop
    execute format('alter table futbeat_private.live_terminal_recovery drop constraint %I',c.conname);
  end loop;
end $$;
alter table futbeat_private.live_terminal_recovery add constraint live_terminal_recovery_reason_check
  check (reason in ('absent_from_live','overdue_live','stuck_nonterminal'));

create table if not exists futbeat_private.stuck_results_reopen (
  provider text not null,
  provider_date date not null,
  reopen_count integer not null default 0 check (reopen_count>=0),
  last_reopened_at timestamptz,
  stuck_matches integer not null default 0,
  -- 'stuck' (matches seen in play) or 'record_failed' (last answer lost).
  reopen_reason text,
  -- Set when the date must never be reopened (its stuck matches go to the
  -- detail path at once): 'date_too_large'.
  skipped_reason text,
  primary key (provider,provider_date)
);
alter table futbeat_private.stuck_results_reopen enable row level security;
revoke all on futbeat_private.stuck_results_reopen from public,anon,authenticated;

-- One row per detail request (a match's lifetime cap and the daily cap).
create table if not exists futbeat_private.stuck_terminal_requests (
  match_id text not null,
  requested_at timestamptz not null,
  external_match_id text not null,
  provider_date date,
  primary key (match_id,requested_at)
);
create index if not exists stuck_terminal_requests_requested_idx
  on futbeat_private.stuck_terminal_requests(requested_at);
alter table futbeat_private.stuck_terminal_requests enable row level security;
revoke all on futbeat_private.stuck_terminal_requests from public,anon,authenticated;

create table if not exists futbeat_private.stuck_terminal_sweep (
  provider text primary key,
  -- Committed by the claim (its own transaction): the throttle survives a
  -- failed or timed-out run.
  claimed_at timestamptz,
  last_run_at timestamptz,
  last_result jsonb
);
alter table futbeat_private.stuck_terminal_sweep enable row level security;
revoke all on futbeat_private.stuck_terminal_sweep from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- Candidates (cheap filter; the read-model check is applied by the callers
-- on the few rows they act on)
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.stuck_nonterminal_candidates()
returns table(match_id text,external_match_id text,provider_date date,start_time timestamptz,
  last_live_status text,last_seen_at timestamptz)
language sql stable security definer set search_path='' as $$
  with bounds as (
    select ((now() at time zone 'UTC')::date
        -futbeat_private.quota_setting('goal_api','stuckTerminalWindowDays',14)::integer)::timestamp at time zone 'UTC' lo,
      now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckTerminalHours',6)::integer) hi
  )
  select cm.match_id,l.external_match_id,(cm.start_time at time zone 'UTC')::date,cm.start_time,l.status,l.last_seen_at
  from bounds b
  join futbeat_private.live_match_state l on l.provider='goal_api'
    and l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') and l.last_seen_at>=b.lo
  -- The live state of the CURRENT mapping (a relinked id is not this match).
  cross join lateral (select pe.canonical_id from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='match' and pe.external_id=l.external_match_id) pe
  join futbeat_private.calendar_matches cm on cm.match_id=pe.canonical_id
  join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
  where cm.start_time>=b.lo and cm.start_time<b.hi
    and l.last_seen_at>=cm.start_time
    and not futbeat_private.is_terminal_match_status(e.payload->>'status')
    and not exists(select 1 from futbeat_private.live_terminal_recovery t
      where t.provider='goal_api' and t.external_match_id=l.external_match_id and t.state='PENDING')
$$;

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------
-- Provider budget above the protected user_high floor, the same guard the
-- recovery reservation applies (latest provider-reported remaining minus
-- still-open reservations). Unknown policy/remaining is no permission.
create or replace function futbeat_private.recovery_headroom()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare v_floor integer; v_remaining integer; v_committed integer;
begin
  select (p.class_floors->>'user_high')::integer into v_floor
    from futbeat_private.provider_quota_policy p where p.provider='goal_api';
  v_remaining:=futbeat_private.provider_remaining('goal_api');
  if v_floor is null or v_remaining is null then
    return jsonb_build_object('allowed',false,'reason','headroom_unknown','floor',v_floor,'providerRemaining',v_remaining);
  end if;
  select coalesce(sum(futbeat_private.provider_call_units(l.metadata)),0)::integer into v_committed
    from futbeat_private.provider_call_ledger l
   where l.provider='goal_api' and l.completed_at is null
     and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  return jsonb_build_object('allowed',greatest(0,v_remaining-v_committed)>v_floor,
    'reason',case when greatest(0,v_remaining-v_committed)>v_floor then 'ok' else 'provider_remaining_reserve' end,
    'providerRemaining',v_remaining,'effectiveProviderRemaining',greatest(0,v_remaining-v_committed),'floor',v_floor);
end $$;

-- Claim: its own short transaction, so the throttle is committed whatever
-- happens to the run that follows. Returns due=false while throttled.
create or replace function futbeat_private.claim_stuck_sweep()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_every interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','stuckSweepMinutes',15)::integer);
  v_claimed timestamptz;
begin
  insert into futbeat_private.stuck_terminal_sweep as s(provider,claimed_at)
  values('goal_api',now())
  on conflict(provider) do update set claimed_at=excluded.claimed_at
    where s.claimed_at is null or s.claimed_at<=now()-v_every
  returning s.claimed_at into v_claimed;
  return jsonb_build_object('due',v_claimed is not null);
end $$;

-- The sweep. Runs only for a fresh claim that has not run yet (or forced in
-- tests / by an operator), never inside the provider quota lock.
create or replace function futbeat_private.sweep_stuck_terminal(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_max_reopens integer:=futbeat_private.quota_setting('goal_api','stuckResultsMaxReopens',2)::integer;
  v_reopen_gap interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckResultsReopenHours',12)::integer);
  v_dates_per_sweep integer:=futbeat_private.quota_setting('goal_api','stuckReopenDatesPerSweep',2)::integer;
  v_max_date_matches integer:=futbeat_private.quota_setting('goal_api','stuckReopenMaxDateMatches',600)::integer;
  v_window_days integer:=futbeat_private.quota_setting('goal_api','stuckTerminalWindowDays',14)::integer;
  v_max_requests integer:=futbeat_private.quota_setting('goal_api','stuckDetailMaxRequests',2)::integer;
  v_request_gap interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckDetailRetryHours',24)::integer);
  v_daily integer:=futbeat_private.quota_setting('goal_api','stuckDetailDailyRequests',40)::integer;
  v_max_pending integer:=futbeat_private.quota_setting('goal_api','stuckDetailMaxPending',4)::integer;
  v_batch integer:=futbeat_private.quota_setting('goal_api','stuckDetailBatch',4)::integer;
  v_sweep futbeat_private.stuck_terminal_sweep;
  v_cands jsonb; v_headroom jsonb; v_room integer; v_today integer; v_pending integer;
  v_reopened jsonb:='[]'::jsonb; v_skipped jsonb:='[]'::jsonb; v_requested jsonb:='[]'::jsonb;
  d record; c record; v_result jsonb;
begin
  if not p_force then
    select * into v_sweep from futbeat_private.stuck_terminal_sweep s where s.provider='goal_api';
    if v_sweep.claimed_at is null or v_sweep.claimed_at<now()-interval '5 minutes'
       or coalesce(v_sweep.last_run_at,'-infinity'::timestamptz)>=v_sweep.claimed_at then
      return jsonb_build_object('ran',false,'reason','not_claimed');
    end if;
  end if;
  -- One sweep at a time; a concurrent caller simply skips.
  if not pg_try_advisory_xact_lock(hashtext('futbeat-stuck-terminal-sweep')) then
    return jsonb_build_object('ran',false,'reason','busy');
  end if;

  delete from futbeat_private.stuck_terminal_requests where requested_at<now()-interval '30 days';
  delete from futbeat_private.stuck_results_reopen
   where provider='goal_api' and provider_date<(now() at time zone 'UTC')::date-90;

  -- Candidates once per run.
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_cands
    from futbeat_private.stuck_nonterminal_candidates() x;

  -- 1. Dates whose results lane gave up: ONE more results answer each.
  v_headroom:=futbeat_private.recovery_headroom();
  for d in
    with stuck as (
      select s.provider_date,count(*)::integer n
      from jsonb_to_recordset(v_cands) s(match_id text,provider_date date)
      group by s.provider_date
    ), record_failed as (
      -- The last results answer was lost at the record stage (statement
      -- timeout before chunked recording): one reopen, stuck or not.
      select a.provider_date,0 n
      from futbeat_private.results_date_attempts a
      where a.provider='goal_api' and a.attempt_count>=4 and a.last_outcome='FAILED'
        and a.provider_date>=(now() at time zone 'UTC')::date-v_window_days
        and (select l.status='FAILED' and l.metadata->>'stage'='record'
          from futbeat_private.provider_call_ledger l
          where l.provider='goal_api' and l.call_kind='results-date'
            and l.reserved_at>now()-make_interval(days=>v_window_days+2)
            and l.metadata->>'date'=a.provider_date::text
          order by l.reserved_at desc,l.id desc limit 1)
    ), dates as (
      select provider_date,max(n) n,bool_or(n>0) has_stuck from (
        select provider_date,n from stuck union all select provider_date,n from record_failed) u
      group by provider_date
    )
    select x.provider_date,x.n,x.has_stuck,
      (select count(*) from futbeat_private.calendar_matches cm
        where cm.start_time>=x.provider_date::timestamp at time zone 'UTC'
          and cm.start_time<(x.provider_date+1)::timestamp at time zone 'UTC')::integer calendar_matches
    from dates x
    join futbeat_private.results_date_attempts a on a.provider='goal_api' and a.provider_date=x.provider_date
    left join futbeat_private.stuck_results_reopen r on r.provider='goal_api' and r.provider_date=x.provider_date
    left join futbeat_private.results_date_user_demand q on q.provider='goal_api' and q.provider_date=x.provider_date
    where a.attempt_count>=4
      and a.next_retry_at<=now()
      and r.skipped_reason is null
      and coalesce(r.reopen_count,0)<case when x.has_stuck then v_max_reopens else 1 end
      and coalesce(r.last_reopened_at,'-infinity'::timestamptz)<now()-v_reopen_gap
      -- Not while a demand for it is still waiting to be served.
      and not (q.provider_date is not null and q.requested_at>now()-interval '24 hours'
        and a.updated_at<q.requested_at)
    order by x.n desc,x.provider_date desc
  loop
    if d.calendar_matches>v_max_date_matches then
      -- Too big for the reservation's local repair under the statement
      -- timeout: never reopened; its stuck matches go to the detail path.
      insert into futbeat_private.stuck_results_reopen as r(provider,provider_date,reopen_count,stuck_matches,skipped_reason)
      values('goal_api',d.provider_date,0,d.n,'date_too_large')
      on conflict(provider,provider_date) do update set skipped_reason='date_too_large',stuck_matches=excluded.stuck_matches;
      v_skipped:=v_skipped||jsonb_build_object('date',d.provider_date,'calendarMatches',d.calendar_matches);
      continue;
    end if;
    continue when jsonb_array_length(v_reopened)>=greatest(v_dates_per_sweep,0);
    -- Same protected floor as recovery: a reopen never spends user_high.
    continue when not coalesce((v_headroom->>'allowed')::boolean,false);
    -- updated_at is left alone: the demand below is served only while
    -- updated_at < requested_at (both would be now() in this transaction).
    update futbeat_private.results_date_attempts a set attempt_count=3
     where a.provider='goal_api' and a.provider_date=d.provider_date and a.attempt_count>3;
    insert into futbeat_private.results_date_user_demand as q(provider,provider_date,requested_at,request_count)
    values('goal_api',d.provider_date,now(),1)
    on conflict(provider,provider_date) do update set requested_at=now(),request_count=q.request_count+1;
    insert into futbeat_private.stuck_results_reopen as r(provider,provider_date,reopen_count,last_reopened_at,stuck_matches,reopen_reason)
    values('goal_api',d.provider_date,1,now(),d.n,case when d.has_stuck then 'stuck' else 'record_failed' end)
    on conflict(provider,provider_date) do update
      set reopen_count=r.reopen_count+1,last_reopened_at=now(),stuck_matches=excluded.stuck_matches,
        reopen_reason=excluded.reopen_reason;
    v_reopened:=v_reopened||jsonb_build_object('date',d.provider_date,'stuck',d.n,
      'reason',case when d.has_stuck then 'stuck' else 'record_failed' end);
  end loop;
  if jsonb_array_length(v_reopened)>0 then
    perform futbeat_private.bump_metric('stuck_results_reopens',jsonb_array_length(v_reopened));
    begin
      perform futbeat_private.wake_provider_worker('results-only');
    exception when others then
      null; -- the periodic results lane still serves the demand
    end;
  end if;

  -- 2. Matches the results lane cannot answer: one bounded detail request.
  select count(*) into v_today from futbeat_private.stuck_terminal_requests
   where requested_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  select count(*) into v_pending from futbeat_private.live_terminal_recovery
   where provider='goal_api' and reason='stuck_nonterminal' and state='PENDING';
  v_room:=least(v_batch,v_daily-v_today,v_max_pending-v_pending);
  if v_room>0 then
    for c in
      with served as (
        select (l.metadata->>'date')::date d,max(l.reserved_at) last_ok
        from futbeat_private.provider_call_ledger l
        where l.provider='goal_api' and l.call_kind='results-date' and l.status='SUCCEEDED'
          and l.reserved_at>now()-interval '30 days'
          and coalesce(l.metadata->>'date','')~'^\d{4}-\d{2}-\d{2}$'
        group by 1
      )
      select s.* from jsonb_to_recordset(v_cands) s(match_id text,external_match_id text,provider_date date,
        start_time timestamptz,last_live_status text,last_seen_at timestamptz)
      left join served v on v.d=s.provider_date
      left join futbeat_private.stuck_results_reopen r on r.provider='goal_api' and r.provider_date=s.provider_date
      where (
          -- The results list was read after this game could have ended...
          v.last_ok>=s.start_time+interval '2 hours'
          -- ...or the date cannot (or can no longer) be reopened.
          or r.skipped_reason is not null
          or (coalesce(r.reopen_count,0)>=v_max_reopens and r.last_reopened_at<now()-v_reopen_gap))
        and (select count(*) from futbeat_private.stuck_terminal_requests q where q.match_id=s.match_id)<v_max_requests
        and not exists(select 1 from futbeat_private.stuck_terminal_requests q
          where q.match_id=s.match_id and q.requested_at>now()-v_request_gap)
      order by s.start_time desc,s.match_id
      limit 200
    loop
      exit when v_room<=0;
      -- The read model may already be final through another path.
      continue when futbeat_private.match_effectively_terminal(c.match_id);
      insert into futbeat_private.live_terminal_recovery as t(
        provider,external_match_id,canonical_match_id,reason,state,last_live_status,
        detected_at,attempts,next_attempt_at)
      values('goal_api',c.external_match_id,c.match_id,'stuck_nonterminal','PENDING',c.last_live_status,
        now(),0,now())
      on conflict(provider,external_match_id) do update set
        canonical_match_id=excluded.canonical_match_id,reason='stuck_nonterminal',state='PENDING',
        last_live_status=excluded.last_live_status,detected_at=now(),attempts=0,
        next_attempt_at=now(),last_attempt_at=null,last_provider_status=null,
        resolved_at=null,resolution=null
      where t.state<>'PENDING';
      continue when not found;
      insert into futbeat_private.stuck_terminal_requests(match_id,requested_at,external_match_id,provider_date)
      values(c.match_id,now(),c.external_match_id,c.provider_date);
      v_requested:=v_requested||jsonb_build_object('matchId',c.match_id,'date',c.provider_date);
      v_room:=v_room-1;
    end loop;
    if jsonb_array_length(v_requested)>0 then
      perform futbeat_private.bump_metric('stuck_detail_requests',jsonb_array_length(v_requested));
    end if;
  end if;

  v_result:=jsonb_build_object('ran',true,'stuck',jsonb_array_length(v_cands),'reopenedDates',v_reopened,
    'skippedDates',v_skipped,'headroom',v_headroom,
    'detailRequests',v_requested,'requestsToday',v_today+jsonb_array_length(v_requested));
  insert into futbeat_private.stuck_terminal_sweep as s(provider,claimed_at,last_run_at,last_result)
  values('goal_api',now(),now(),v_result)
  on conflict(provider) do update set last_run_at=excluded.last_run_at,last_result=excluded.last_result;
  return v_result;
end $$;

-- Worker entry points (service-only). Called before a recovery reservation:
-- claim, then run only when due. Each is its own transaction.
create or replace function public.futbeat_claim_stuck_sweep()
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.claim_stuck_sweep()
$$;
create or replace function public.futbeat_run_stuck_sweep()
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.sweep_stuck_terminal(false)
$$;

-- ---------------------------------------------------------------------------
-- Settlement. Base: 20260930130000 (verbatim) except: stuck rows have their
-- own attempt cap and window and never re-demand their (already answered)
-- date. The sweep does NOT run here (it runs outside the quota lock).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.settle_terminal_recovery()
returns void language plpgsql security definer set search_path='' as $$
declare v_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryMaxAttempts',6)::integer;
  -- CHANGED: stuck rows (see header).
  v_stuck_max integer:=futbeat_private.quota_setting('goal_api','stuckDetailMaxAttempts',2)::integer;
  v_stuck_window interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckDetailWindowHours',24)::integer);
  v_demanded integer:=0;
begin
  update futbeat_private.live_terminal_recovery r
  set state='RESOLVED',resolved_at=now(),resolution='terminal_evidence'
  where r.state='PENDING' and r.canonical_match_id is not null
    and futbeat_private.match_effectively_terminal(r.canonical_match_id);
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts'
  where r.state='PENDING'
    and r.attempts>=case when r.reason='stuck_nonterminal' then v_stuck_max else v_max end;

  -- A recovery still pending after 10 minutes: one results call for its
  -- provider date resolves every final of that date. Same queue, quota
  -- class, caps and per-date backoff as a user opening the match; refreshed
  -- at most hourly per date.
  with dates as (
    select distinct futbeat_private.match_provider_date(r.canonical_match_id) d
    from futbeat_private.live_terminal_recovery r
    where r.provider='goal_api' and r.state='PENDING' and r.canonical_match_id is not null
      and r.detected_at<now()-interval '10 minutes'
      -- CHANGED: a stuck row's date was already answered (or given up).
      and r.reason<>'stuck_nonterminal'
  ), asked as (
    insert into futbeat_private.results_date_user_demand as q(provider,provider_date,requested_at,request_count)
    select 'goal_api',d,now(),1 from dates where d is not null
    on conflict(provider,provider_date) do update
      set requested_at=excluded.requested_at,request_count=q.request_count+1
      where q.requested_at<now()-interval '1 hour'
    returning 1
  )
  select count(*) into v_demanded from asked;
  if v_demanded>0 then
    perform futbeat_private.bump_metric('terminal_recovery_results_demands',v_demanded);
    begin
      perform futbeat_private.wake_provider_worker('results-only');
    exception when others then
      -- The periodic results lane still serves the demand.
      null;
    end;
  end if;

  -- A row that can no longer be served (mapping relinked or removed) expires.
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='expired'
  where r.state='PENDING' and r.detected_at<now()-case when r.reason='stuck_nonterminal' then v_stuck_window
    else make_interval(hours=>futbeat_private.quota_setting('goal_api','terminalRecoveryWindowHours',6)::integer) end;
  delete from futbeat_private.live_terminal_recovery
  where state<>'PENDING' and coalesce(resolved_at,detected_at)<now()-interval '3 days';
end $$;

-- ---------------------------------------------------------------------------
-- Recovery reservation. Base: 20260926174500 (verbatim) except: fresh
-- recoveries are served before stuck ones, and a stuck row's second call
-- waits stuckDetailRetryMinutes (the provider rarely changes its answer for
-- an old fixture within minutes).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.reserve_terminal_recovery_call(p_trigger_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  r futbeat_private.live_terminal_recovery;
  v_decision jsonb;
  v_reservation bigint;
  v_provider_remaining integer;
  v_effective_remaining integer;
  v_committed_units integer:=0;
  v_protected_floor integer;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  perform futbeat_private.settle_terminal_recovery();

  select (p.class_floors->>'user_high')::integer
    into v_protected_floor
  from futbeat_private.provider_quota_policy p
  where p.provider='goal_api';

  if v_protected_floor is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','protected_floor_unknown',
      'quotaClass','recovery'
    );
  end if;

  v_provider_remaining:=futbeat_private.provider_remaining('goal_api');
  if v_provider_remaining is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_unknown',
      'providerRemaining',null,
      'effectiveProviderRemaining',null,
      'committedUnits',0,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  select coalesce(sum(futbeat_private.provider_call_units(l.metadata)),0)::integer
    into v_committed_units
  from futbeat_private.provider_call_ledger l
  where l.provider='goal_api'
    and l.completed_at is null
    and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';

  v_effective_remaining:=greatest(0,v_provider_remaining-v_committed_units);
  if v_effective_remaining<=v_protected_floor then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_provider_remaining,
      'effectiveProviderRemaining',v_effective_remaining,
      'committedUnits',v_committed_units,
      'floor',v_protected_floor,
      'quotaClass','recovery'
    );
  end if;

  select t.* into r
  from futbeat_private.live_terminal_recovery t
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match'
    and pe.external_id=t.external_match_id
    and pe.canonical_id=t.canonical_match_id
  where t.provider='goal_api'
    and t.state='PENDING'
    and t.next_attempt_at<=now()
    and not futbeat_private.detail_inflight(t.canonical_match_id)
  -- CHANGED: today's games first; old stuck matches use what is left.
  order by (t.reason='stuck_nonterminal'),t.next_attempt_at,t.external_match_id
  limit 1
  for update of t skip locked;

  if not found then
    return jsonb_build_object('allowed',false,'reason','no_recovery_due');
  end if;

  v_decision:=futbeat_private.quota_decision('goal_api','match-detail','results');
  if not (v_decision->>'allowed')::boolean then
    return v_decision||jsonb_build_object(
      'allowed',false,
      'matchId',r.canonical_match_id,
      'quotaClass','recovery'
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),
    hashtext(r.canonical_match_id)
  );
  if futbeat_private.detail_inflight(r.canonical_match_id) then
    return jsonb_build_object(
      'allowed',false,
      'reason','detail_inflight',
      'matchId',r.canonical_match_id
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api',
    'match-detail',
    left(p_trigger_source,40),
    now(),
    jsonb_build_object(
      'matchId',r.canonical_match_id,
      'externalMatchId',r.external_match_id,
      'status',r.last_live_status,
      'quotaClass','results',
      'bucket','recovery',
      'source','recovery',
      'recoveryReason',r.reason,
      'attempt',r.attempts+1,
      'providerRequests',1
    )
  )
  returning id into v_reservation;

  update futbeat_private.live_terminal_recovery t
  set attempts=t.attempts+1,
      last_attempt_at=now(),
      -- CHANGED: a stuck row's next call is hours, not minutes, away.
      next_attempt_at=now()+case when t.reason='stuck_nonterminal'
        then make_interval(mins=>futbeat_private.quota_setting('goal_api','stuckDetailRetryMinutes',180)::integer)
        else futbeat_private.recovery_backoff(t.attempts+1) end
  where t.provider=r.provider
    and t.external_match_id=r.external_match_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_reservation,
    'matchId',r.canonical_match_id,
    'externalMatchId',r.external_match_id,
    'reason',r.reason,
    'attempt',r.attempts+1,
    'quotaClass','results',
    'bucket','recovery',
    'providerRemaining',v_provider_remaining,
    'effectiveProviderRemaining',v_effective_remaining,
    'committedUnits',v_committed_units,
    'protectedFloor',v_protected_floor
  );
end $$;

-- ---------------------------------------------------------------------------
-- Service-only diagnostics (read-only).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.stuck_terminal_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'stuck',(select count(*) from futbeat_private.stuck_nonterminal_candidates()),
    'byDate',(select coalesce(jsonb_object_agg(d,n),'{}'::jsonb) from (
      select provider_date::text d,count(*) n from futbeat_private.stuck_nonterminal_candidates() group by 1) x),
    'byLastLiveStatus',(select coalesce(jsonb_object_agg(s,n),'{}'::jsonb) from (
      select last_live_status s,count(*) n from futbeat_private.stuck_nonterminal_candidates() group by 1) x),
    'pendingDetail',(select count(*) from futbeat_private.live_terminal_recovery
      where provider='goal_api' and reason='stuck_nonterminal' and state='PENDING'),
    'detailRequestsToday',(select count(*) from futbeat_private.stuck_terminal_requests
      where requested_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'),
    'reopenedDates',(select coalesce(jsonb_agg(jsonb_build_object('date',provider_date,'reopens',reopen_count,
      'lastReopenedAt',last_reopened_at,'stuckAtReopen',stuck_matches) order by provider_date),'[]'::jsonb)
      from futbeat_private.stuck_results_reopen where provider='goal_api'),
    'lastSweep',(select to_jsonb(s)-'provider' from futbeat_private.stuck_terminal_sweep s where s.provider='goal_api'))
$$;

create or replace function public.futbeat_stuck_terminal_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.stuck_terminal_status()
$$;

-- ---------------------------------------------------------------------------
-- No late pushes. A provider answer for an old match (stuck recovery, a
-- reopened results date, any late detail) stores its events as "first seen"
-- now; pushing them days after the game is wrong. Outbox rows of match
-- events whose kickoff is older than matchPushMaxAgeHours are dropped at
-- insert; the canonical events themselves are unchanged. Content pushes
-- (no match event) are untouched.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.drop_stale_match_push()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_kickoff timestamptz; v_match text; v_provider text;
  v_max interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','matchPushMaxAgeHours',8)::integer);
begin
  if new.event_id is null then return new; end if;
  select c.match_id,c.provider,futbeat_private.try_timestamptz(e.payload->>'startTime')
    into v_match,v_provider,v_kickoff
    from futbeat_private.canonical_events c
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   where c.id=new.event_id;
  if v_kickoff is null or v_kickoff>=now()-v_max then return new; end if;
  -- The stored kickoff can be stale (rescheduled, postponed then played,
  -- suspended and resumed another day): the effective kickoff is the
  -- newest the provider reported for this match...
  if exists(select 1 from (
      select futbeat_private.try_timestamptz(o.raw_payload->>'kickoffUtc') k
      from futbeat_private.provider_observations o
      where o.provider=v_provider and o.canonical_match_id=v_match
      order by o.received_at desc,o.id desc limit 1) x where x.k>=now()-v_max) then
    return new;
  end if;
  -- ...and a match the provider reported in play within the last hour is
  -- being played now (its live events and its final whistle push).
  if exists(select 1 from futbeat_private.provider_observations o
      where o.provider=v_provider and o.canonical_match_id=v_match
        and o.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        and o.received_at>=now()-interval '60 minutes') then
    return new;
  end if;
  -- A genuinely late answer (stuck recovery, an old results date).
  perform futbeat_private.bump_metric('stale_match_push_skipped');
  return null;
end $$;
drop trigger if exists futbeat_drop_stale_match_push on futbeat_private.notification_outbox;
create trigger futbeat_drop_stale_match_push before insert on futbeat_private.notification_outbox
for each row execute function futbeat_private.drop_stale_match_push();

do $$ declare fn regprocedure; begin
  for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='futbeat_private' and p.proname in ('stuck_nonterminal_candidates','sweep_stuck_terminal',
      'settle_terminal_recovery','reserve_terminal_recovery_call','stuck_terminal_status','recovery_headroom',
      'claim_stuck_sweep','drop_stale_match_push'))
    or (n.nspname='public' and p.proname in ('futbeat_stuck_terminal_status','futbeat_claim_stuck_sweep','futbeat_run_stuck_sweep'))
  loop
    execute format('revoke all on function %s from public',fn);
    if exists(select 1 from pg_roles where rolname='anon') then execute format('revoke all on function %s from anon',fn); end if;
    if exists(select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on function %s from authenticated',fn); end if;
  end loop;
  if exists(select 1 from pg_roles where rolname='service_role') then
    grant execute on function public.futbeat_stuck_terminal_status() to service_role;
    grant execute on function public.futbeat_claim_stuck_sweep() to service_role;
    grant execute on function public.futbeat_run_stuck_sweep() to service_role;
  end if;
end $$;

notify pgrst,'reload schema';
