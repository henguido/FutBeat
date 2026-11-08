-- BE11-A1: settle_terminal_recovery() must not cost O(PENDING x read model).
--
-- Evidence (production, read-only, 2026-11-07):
--   * live_terminal_recovery held 583 PENDING rows (581 absent_from_live) at
--     18:06Z, all attempts=0: GOAL /fixtures/live answers at most 100 rows
--     (providerTotal=100, reachedEnd=true) while 587-815 matches were active,
--     so every live poll marks dozens of matches "absent"; and no recovery
--     call could be reserved after 12:10Z (quota live reserve, then the
--     user_high floor 150: remaining 101 at 18:06Z).
--   * settle_terminal_recovery() runs first in every
--     reserve_terminal_recovery_call (each detail-lane run, every minute),
--     INSIDE the global provider quota lock, and evaluates
--     match_effectively_terminal() = match_read_model_core() for EVERY
--     pending row. Measured: 20 rows = 1.7 s warm / 3.8 s cold
--     (87-190 ms per row) -> 583 rows = 50-110 s, above the 8 s statement
--     timeout. Since ~17:30Z every reservation failed with 57014: no
--     settlement (86 rows past the 6 h window still PENDING at 18:48Z, last
--     resolved_at 17:30:14Z), no results-date demand refresh, and each
--     failed call held the quota lock ~8 s (reserve_match_detail_call
--     max 7.98 s; 0 successful reserve_goal_results_date since 17:02Z).
--
-- Fix: the read model can only answer a terminal status when the match has
-- terminal evidence somewhere. match_may_be_terminal() checks exactly those
-- sources (the ones match_read_model_core reads) with indexed lookups; the
-- read model runs only for matches that pass. Same result as before
-- (necessary condition, see function comment), no quota/policy change, no
-- GOAL call. Base of settle: production definition 2026-11-07 (=
-- 20261002110000) verbatim except the marked line.

create or replace function futbeat_private.match_may_be_terminal(p_match_id text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
  -- match_read_model_core returns a terminal status
  -- (is_terminal_match_status: FINISHED_PENDING_VERIFICATION, VERIFIED,
  -- POSTPONED, ABANDONED, CANCELLED) only if (a) the stored payload status is
  -- terminal, or (b) its evidence union yields VERIFIED,
  -- FINISHED_PENDING_VERIFICATION or ABANDONED from provider_observations,
  -- live_match_state, match_detail_cache (mapped matchStatus) or a FULL_TIME
  -- canonical event. Any of them -> true; none -> the read model cannot be
  -- terminal.
  return exists(select 1 from futbeat_private.entities e
      where e.id=p_match_id and e.kind='match'
        and futbeat_private.is_terminal_match_status(e.payload->>'status'))
    or exists(select 1 from futbeat_private.provider_observations o
      where o.canonical_match_id=p_match_id
        and o.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.live_match_state l
      where l.canonical_match_id=p_match_id
        and l.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.match_detail_cache c
      where c.match_id=p_match_id
        and upper(c.payload->>'matchStatus') in ('FINISHED','AFTER_ET','AFTER_PEN','AWARDED',
          'VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED'))
    or exists(select 1 from futbeat_private.canonical_events ce
      where ce.match_id=p_match_id and ce.event_type='FULL_TIME');
end $$;
revoke all on function futbeat_private.match_may_be_terminal(text) from public,anon,authenticated;

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
    -- BE11-A1: CASE fixes the evaluation order (the read model only after
    -- the cheap evidence check).
    and case when futbeat_private.match_may_be_terminal(r.canonical_match_id)
      then futbeat_private.match_effectively_terminal(r.canonical_match_id) else false end;
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
