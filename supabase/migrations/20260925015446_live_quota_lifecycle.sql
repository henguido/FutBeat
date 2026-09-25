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
--     tolerating five-minute cron jitter).

update futbeat_private.provider_quota_policy set
  kind_daily_caps=kind_daily_caps||'{"live-goal":400}',
  freshness=freshness||'{"liveWindowLeadMinutes":5,"liveMinIntervalSeconds":240}',
  updated_at=now()
where provider='goal_api';

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

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values('goal_api','live-goal',left(p_trigger_source,40),now(),
    jsonb_build_object('activeMatches',(v_need->>'active')::integer,
      'liveMatches',(v_need->>'live')::integer,
      'overdueScheduled',(v_need->>'overdueScheduled')::integer))
  returning id into v_id;
  if (v_need->>'overdueScheduled')::integer>0 then
    perform futbeat_private.bump_metric('live_polls_with_overdue_scheduled');
  end if;

  return v_base||jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'usedToday',(v_decision->>'totalToday')::integer+1,
    'liveUsed',(v_decision->>'usedToday')::integer+1);
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
