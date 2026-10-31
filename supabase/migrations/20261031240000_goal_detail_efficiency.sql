-- Turn 244: fewer GOAL match-detail and team-squad calls, same results.
-- Measured on the ledger, 2026-10-24 to 2026-10-31: 4,104 detail calls, 2,029 of
-- them terminal recovery, and 947 calls spent on matches whose canonical entity is
-- an empty stub, so no answer could ever settle their recovery row.
--
-- Every replaced body comes from pg_get_functiondef on production, not from main.
-- Nothing changes until goal_api freshness.detailEfficiency244 is set above 0:
-- the bodies are dormant by default and setting it back to 0 is the rollback.
--
-- Rules while it is on:
-- 1. A provider final ends a recovery row, even on a stub entity.
-- 2. A stub match (no startTime) has no read model to repair: no recovery calls.
-- 3. Low priority finals wait for the one results call of their date; only what is
--    still open after terminalRecoveryBatchDelayMinutes gets a single detail call.
-- 4. overdue_live rows, still in the feed, get 3 calls 30 minutes apart.
-- 5. Priority (followed or recently opened team or competition, or a competition at
--    detailPriorityRelevance or above) keeps the lineup and statistics fetches, less
--    tight. Everything else gets one background fetch, only while the band is
--    abundant. A user open is not touched: reserve_match_detail_call is unchanged.
-- 6. A cached provider final needs no results-window refresh, only the final capture.
-- 7. Squads of teams nobody follows refresh every squadTtlDaysDefault days, at most
--    squadBackgroundDailyCap a day. Followed and requested teams keep 7 days.

create or replace function futbeat_private.detail_efficiency_on()
returns boolean language sql stable set search_path to '' as $function$
  select futbeat_private.quota_setting('goal_api','detailEfficiency244',0)>0
$function$;

-- Followed and recently opened teams and competitions, with their aliases: match
-- payloads can still carry an id that was merged into the followed one.
create or replace function futbeat_private.detail_priority_subjects()
returns text[] language sql stable set search_path to '' as $function$
  with s as (
    select futbeat_private.squad_candidate_id(i.subject_type,i.subject_id) id
    from futbeat_private.coverage_interests i
    where i.explicit_followers>0 and i.subject_type in ('team','competition')
    union
    select futbeat_private.squad_candidate_id(t.entity_type,t.entity_id)
    from futbeat_private.temporary_interests t
    where t.expires_at>now() and t.entity_type in ('team','competition')
  )
  select coalesce(array_agg(distinct x.id),array[]::text[]) from (
    select s.id from s
    union
    select r.alias_id from futbeat_private.entity_redirects r
    join s on s.id=r.canonical_id
    where r.kind in ('team','competition')
  ) x
$function$;

create or replace function futbeat_private.match_detail_is_priority(p_match_id text)
returns boolean language sql stable set search_path to '' as $function$
  select coalesce((
    select coalesce(m.relevance_score,0)>=futbeat_private.quota_setting('goal_api','detailPriorityRelevance',500)
      or array[e.payload->>'competitionId',e.payload->>'homeTeamId',e.payload->>'awayTeamId']
        && futbeat_private.detail_priority_subjects()
      or exists(select 1 from futbeat_private.temporary_interests t
        where t.entity_type='match' and t.entity_id=p_match_id and t.expires_at>now())
    from futbeat_private.entities e
    left join futbeat_private.competition_editorial_metadata m on m.competition_id=e.payload->>'competitionId'
    where e.id=p_match_id and e.kind='match'),false)
$function$;

create or replace function futbeat_private.team_squad_ttl(p_team_id text)
returns interval language sql stable set search_path to '' as $function$
  select case when futbeat_private.detail_efficiency_on()
      and not p_team_id=any(futbeat_private.detail_priority_subjects())
    then make_interval(days=>futbeat_private.quota_setting('goal_api','squadTtlDaysDefault',21)::integer)
    else interval '7 days' end
$function$;

revoke all on function futbeat_private.detail_efficiency_on() from public,anon,authenticated;
revoke all on function futbeat_private.detail_priority_subjects() from public,anon,authenticated;
revoke all on function futbeat_private.match_detail_is_priority(text) from public,anon,authenticated;
revoke all on function futbeat_private.team_squad_ttl(text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.complete_terminal_recovery(p_external_match_id text, p_provider_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare r futbeat_private.live_terminal_recovery;
  v_final text[]:=case when futbeat_private.detail_efficiency_on()
    then array['FINISHED','AFTER_ET','AFTER_PEN','AWARDED','ABANDONED'] else array[]::text[] end;
begin
  update futbeat_private.live_terminal_recovery t set last_provider_status=left(p_provider_status,40)
  where t.provider='goal_api' and t.external_match_id=p_external_match_id
  returning * into r;
  if not found then return jsonb_build_object('state',null); end if;
  perform futbeat_private.settle_terminal_recovery();
  -- A pre-match decision is the provider's answer too: stop spending calls;
  -- the results reconciliation owns postponed/cancelled (with provenance).
  update futbeat_private.live_terminal_recovery t
  set state='RESOLVED',resolved_at=now(),resolution='provider_'||lower(p_provider_status)
  where t.provider='goal_api' and t.external_match_id=p_external_match_id and t.state='PENDING'
    and upper(p_provider_status) in ('POSTPONED','CANCELLED');
  -- A final is the provider's answer as well, and a stub entity never shows it
  -- as terminal evidence: without this the row spends its second attempt.
  update futbeat_private.live_terminal_recovery t
  set state='RESOLVED',resolved_at=now(),resolution='provider_final'
  where t.provider='goal_api' and t.external_match_id=p_external_match_id and t.state='PENDING'
    and upper(p_provider_status)=any(v_final);
  select * into r from futbeat_private.live_terminal_recovery t
  where t.provider='goal_api' and t.external_match_id=p_external_match_id;
  return jsonb_build_object('state',r.state,'resolution',r.resolution,'attempts',r.attempts);
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.settle_terminal_recovery()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryMaxAttempts',6)::integer;
  -- CHANGED: stuck rows (see header).
  v_stuck_max integer:=futbeat_private.quota_setting('goal_api','stuckDetailMaxAttempts',2)::integer;
  v_stuck_window interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','stuckDetailWindowHours',24)::integer);
  v_demanded integer:=0;
  v_eff boolean:=futbeat_private.detail_efficiency_on();
  v_every interval:=case when futbeat_private.detail_efficiency_on()
    then make_interval(mins=>futbeat_private.quota_setting('goal_api','terminalRecoveryResultsMinutes',30)::integer)
    else interval '1 hour' end;
  v_batch_min integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryBatchMinPending',3)::integer;
  v_overdue_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryOverdueMaxAttempts',3)::integer;
begin
  update futbeat_private.live_terminal_recovery r
  set state='RESOLVED',resolved_at=now(),resolution='terminal_evidence'
  where r.state='PENDING' and r.canonical_match_id is not null
    and futbeat_private.match_effectively_terminal(r.canonical_match_id);
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts'
  where r.state='PENDING'
    and r.attempts>=case when r.reason='stuck_nonterminal' then v_stuck_max
      when v_eff and r.reason='overdue_live' then v_overdue_max else v_max end;
  -- A stub has no kickoff and no read model: no detail answer can settle it.
  -- A later calendar store brings the entity, and the results lane its final.
  if v_eff then
    update futbeat_private.live_terminal_recovery r
    set state='EXHAUSTED',resolved_at=now(),resolution='no_read_model'
    from futbeat_private.entities e
    where r.state='PENDING' and e.id=r.canonical_match_id and e.kind='match'
      and nullif(e.payload->>'startTime','') is null;
  end if;

  -- A recovery still pending after 10 minutes: one results call for its
  -- provider date resolves every final of that date. Same queue, quota
  -- class, caps and per-date backoff as a user opening the match; refreshed
  -- at most hourly per date.
  with dates as (
    select futbeat_private.match_provider_date(r.canonical_match_id) d,
      count(*) filter(where r.attempts=0) waiting
    from futbeat_private.live_terminal_recovery r
    where r.provider='goal_api' and r.state='PENDING' and r.canonical_match_id is not null
      and r.detected_at<now()-interval '10 minutes'
      -- CHANGED: a stuck row's date was already answered (or given up).
      and r.reason<>'stuck_nonterminal'
    group by 1
  ), asked as (
    insert into futbeat_private.results_date_user_demand as q(provider,provider_date,requested_at,request_count)
    select 'goal_api',d,now(),1 from dates where d is not null
    on conflict(provider,provider_date) do update
      set requested_at=excluded.requested_at,request_count=q.request_count+1
      where q.requested_at<now()-v_every
    returning q.provider_date
  ), due_now as (
    -- The date backoff (2 hours and up) would hold this demand back. Lifted only
    -- when one call replaces several detail calls.
    update futbeat_private.results_date_attempts a set next_retry_at=now()
    from asked join dates on dates.d=asked.provider_date
    where v_eff and dates.waiting>=v_batch_min
      and a.provider='goal_api' and a.provider_date=asked.provider_date
      and a.next_retry_at>now()
    returning 1
  )
  select (select count(*) from asked) into v_demanded;
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
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.reserve_terminal_recovery_call(p_trigger_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  r futbeat_private.live_terminal_recovery;
  v_decision jsonb;
  v_reservation bigint;
  v_provider_remaining integer;
  v_effective_remaining integer;
  v_committed_units integer:=0;
  v_protected_floor integer;
  v_eff boolean:=futbeat_private.detail_efficiency_on();
  v_batch_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','terminalRecoveryBatchDelayMinutes',45)::integer);
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
    -- GOAL-QUOTA-36: a match that left the live feed gets at most N detail
    -- calls; it stays PENDING so the per-date results call (settle) resolves it.
    and not (t.reason='absent_from_live' and t.attempts>=
      futbeat_private.quota_setting('goal_api','terminalRecoveryAbsentDetailAttempts',2)::integer)
    -- Low priority finals are the date's results call to settle; a single detail
    -- call is the fallback for what that call did not answer.
    and (not v_eff or t.reason<>'absent_from_live'
      or futbeat_private.match_detail_is_priority(t.canonical_match_id)
      or (t.detected_at<=now()-v_batch_delay and t.attempts=0))
  -- CHANGED: today's games first; old stuck matches use what is left.
  order by (t.reason='stuck_nonterminal'),
    (v_eff and futbeat_private.match_detail_is_priority(t.canonical_match_id)) desc,
    t.next_attempt_at,t.external_match_id
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
        when v_eff and t.reason='overdue_live'
        then make_interval(mins=>futbeat_private.quota_setting('goal_api','overdueDetailRetryMinutes',30)::integer)
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
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.match_detail_planner_due(p_match_id text, p_bucket text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare cov futbeat_private.match_detail_coverage; fetched timestamptz; kickoff timestamptz;
  sections jsonb; gap interval; final_after interval; phase text; used integer;
  v_eff boolean:=futbeat_private.detail_efficiency_on(); cached_status text;
begin
  if p_bucket is null or p_bucket not in ('live','results','prematch','upcoming','recent_hot','recent','history') then
    return false;
  end if;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if coalesce(cov.next_retry_at>now(),false) then return false; end if;
  select c.fetched_at,upper(c.payload->>'matchStatus') into fetched,cached_status
  from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  -- Low priority: one background fetch, only on spare quota. A user open still
  -- fetches through match_detail_needs_fetch.
  if v_eff and not futbeat_private.match_detail_is_priority(p_match_id) then
    return fetched is null and p_bucket in ('live','results','recent_hot','recent')
      and futbeat_private.detail_planner_band()->>'band'='abundant';
  end if;
  -- Hard bound on background work per match and phase (user opens are not
  -- counted): pre-match, LIVE and results attempts never eat the post-match
  -- fetch, and each phase has its own cap.
  phase:=case p_bucket when 'prematch' then 'prematch' when 'live' then 'live'
    when 'results' then 'results' else 'finished' end;
  select count(*) into used from futbeat_private.provider_call_ledger l
  where l.call_kind='match-detail' and l.metadata->>'matchId'=p_match_id
    and l.reserved_at>now()-interval '1 day' and coalesce(l.metadata->>'source','')<>'user'
    and case coalesce(l.metadata->>'bucket','') when 'prematch' then 'prematch' when 'live' then 'live'
      when 'results' then 'results' when 'recovery' then 'recovery' else 'finished' end=phase;
  if used>=(case phase
      when 'prematch' then futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetches',3)
      when 'live' then case when v_eff then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetchesEfficient',4)
        else futbeat_private.quota_setting('goal_api','plannerMaxLiveFetches',6) end
      when 'results' then futbeat_private.quota_setting('goal_api','plannerMaxResultFetches',2)
      else futbeat_private.quota_setting('goal_api','plannerMaxFetchesPerMatchDay',4) end) then
    return false;
  end if;
  if fetched is null then return true; end if;
  if p_bucket='results' then
    -- The answer is already final: only the final capture is left.
    if v_eff and cached_status in ('FINISHED','AFTER_ET','AFTER_PEN','AWARDED') then
      select nullif(e.payload->>'startTime','')::timestamptz into kickoff
      from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
      final_after:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
      return coalesce(now()>=kickoff+final_after and fetched<kickoff+final_after,false);
    end if;
    return futbeat_private.match_detail_due('FINISHED_PENDING_VERIFICATION',fetched);
  end if;
  if p_bucket='upcoming' then return false; end if;
  if p_bucket='live' then
    return coalesce((coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
        and fetched<now()-make_interval(mins=>case when v_eff
          then futbeat_private.quota_setting('goal_api','plannerLiveLineupRetryMinutes',10)
          else futbeat_private.quota_setting('goal_api','liveRetryMinutes',5) end::integer))
      -- Periodic refresh only while the provider budget is comfortable.
      or (fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30)::integer)
        and futbeat_private.detail_planner_band()->>'band' in ('abundant','normal')),false);
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  gap:=make_interval(secs=>(sections->>'retryGap')::double precision);
  if p_bucket='prematch' then
    return coalesce((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
      and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchRetryMinutes',20)::integer),false);
  end if;
  -- Finished: one post-match fetch, then only missing sections / due rechecks.
  select nullif(e.payload->>'startTime','')::timestamptz into kickoff
  from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  final_after:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  if kickoff is not null and now()>=kickoff+final_after and fetched<kickoff+final_after then
    return true;
  end if;
  return coalesce(fetched<now()-gap and (
    coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN' or coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'
    -- A NO_DATA without a recheck time (older rows) is never rechecked.
    or (cov.lineup_state='NO_DATA' and coalesce(cov.lineup_recheck_at,'infinity')<=now())
    or (cov.statistics_state='NO_DATA' and coalesce(cov.statistics_recheck_at,'infinity')<=now())),false);
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.plan_match_detail_coverage(p_limit integer, p_full boolean)
 RETURNS text[]
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare band jsonb:=futbeat_private.detail_planner_band();
  high integer:=futbeat_private.quota_setting('goal_api','plannerQueueHighWater',12)::integer;
  low integer:=futbeat_private.quota_setting('goal_api','plannerQueueLowWater',4)::integer;
  urgent_lim integer:=greatest(1,least(coalesce(p_limit,4),20));
  bg_lim integer; depth integer; paused boolean; queued text[]:='{}'; bg_queued integer:=0;
  bg_open boolean:=futbeat_private.detail_share_open('background');
  live_open boolean:=futbeat_private.detail_share_open('live');
  floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
  urgent_queued integer:=0; cand record; extra integer;
  prematch interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer);
  upcoming interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer);
  history interval:=make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer);
  -- Bucket windows read once per run (match_detail_bucket read them per row).
  results_win interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer);
  recent_hot interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer);
  recent_fin interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer);
  live_max interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','liveMaxHours',4)::integer);
  final_after interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  row_ttl interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerRowTtlMinutes',60)::integer);
  -- Hot run (p_full=false): only the buckets that change minute to minute
  -- (live, results, prematch, recent_hot). Every row such a bucket can hold
  -- starts after now-hot_back (live: liveMaxHours; results: resultsWindowHours;
  -- recent_hot: recentHotHours) and, like the full window, before now+upcoming
  -- (a LIVE/results row may carry a later kickoff). Those buckets rank first,
  -- so the hot run plans exactly the hot part of a full run.
  hot_back interval:=greatest(results_win,recent_hot,live_max);
  v_eff boolean:=futbeat_private.detail_efficiency_on();
  prio_subjects text[]:=futbeat_private.detail_priority_subjects();
  prio_relevance numeric:=futbeat_private.quota_setting('goal_api','detailPriorityRelevance',500);
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));
  delete from futbeat_private.match_detail_requests where expires_at<=now();
  with dropped as (
    delete from futbeat_private.match_detail_requests r
    where r.source<>'user' and (
      not exists(select 1 from futbeat_private.provider_entities pe
        where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id)
      or futbeat_private.match_detail_planner_due(r.match_id,futbeat_private.match_detail_bucket(
        futbeat_private.match_detail_status(r.match_id),
        (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id)))
        is not true)
    returning r.source
  )
  insert into futbeat_private.match_detail_queue_log(event,source) select 'dropped',source from dropped;
  select count(*) into depth from futbeat_private.match_detail_requests r
  where r.expires_at>now() and r.source<>'user'
    and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
      (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e where e.id=r.match_id))
      not in ('live','results');
  select background_paused into paused from futbeat_private.detail_planner_state for update;
  if not paused and depth>=high then
    paused:=true;
    update futbeat_private.detail_planner_state set background_paused=true,paused_changed_at=now() where singleton;
  elsif paused and depth<=low then
    paused:=false;
    update futbeat_private.detail_planner_state set background_paused=false,paused_changed_at=now() where singleton;
  end if;
  bg_lim:=case when paused then 0 else greatest(0,least(coalesce(p_limit,(band->>'batch')::integer),high-depth)) end;
  for cand in
    with window_matches as materialized (
      select cm.match_id,nullif(x.payload->>'startTime','')::timestamptz start_time,
        x.payload->>'competitionId' competition_id,
        array[x.payload->>'competitionId',x.payload->>'homeTeamId',x.payload->>'awayTeamId'] subjects,
        case
          when coalesce(l.status,x.payload->>'status') in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
            and nullif(x.payload->>'startTime','')::timestamptz<now()-live_max then null
          else coalesce(l.status,x.payload->>'status')
        end status
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities x on x.id=cm.match_id and x.kind='match'
      left join public.live_match_updates l on l.match_id=cm.match_id and l.provider='goal_api'
      where cm.start_time between now()-case when p_full then history else hot_back end
        and now()+upcoming
    ), profiled as materialized (
      select w.match_id,w.start_time,w.competition_id,w.subjects,
        futbeat_private.match_detail_bucket_at(w.status,w.start_time,now(),
          results_win,prematch,upcoming,recent_hot,recent_fin,history) bucket
      from window_matches w
    )
    select p.match_id,p.bucket,p.start_time,coalesce(meta.relevance_score,0) relevance
    from profiled p
    join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=p.competition_id
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    cross join lateral (select coalesce(meta.relevance_score,0)>=prio_relevance or p.subjects&&prio_subjects priority) f
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      -- Low priority rows that planner_due would refuse must not fill the 400 below.
      and (not v_eff or f.priority or (band->>'band'='abundant' and d.match_id is null
        and p.bucket in ('live','results','recent_hot','recent')))
      and (p_full or p.bucket in ('live','results','prematch','recent_hot'))
      and coalesce(c.next_retry_at,'-infinity')<=now()
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history')
        and d.fetched_at>=p.start_time+final_after
        and coalesce(c.lineup_state,'UNKNOWN')<>'UNKNOWN' and coalesce(c.statistics_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.lineup_recheck_at,'infinity')>now() and coalesce(c.statistics_recheck_at,'infinity')>now())
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by futbeat_private.match_detail_bucket_rank(p.bucket),(v_eff and f.priority) desc,coalesce(meta.relevance_score,0) desc,
      abs(extract(epoch from p.start_time-now())),p.match_id
    limit 400
  loop
    exit when urgent_queued>=urgent_lim and bg_queued>=bg_lim;
    if cand.bucket in ('live','results') then
      continue when urgent_queued>=urgent_lim or not live_open;
      continue when cand.bucket='live' and not floor_ok;
    else
      continue when bg_queued>=bg_lim or not bg_open or not floor_ok;
      continue when cand.bucket='history' and not (band->>'history')::boolean;
      continue when cand.bucket in ('recent','upcoming') and not (band->>'recent')::boolean;
    end if;
    continue when futbeat_private.match_detail_planner_due(cand.match_id,cand.bucket) is not true
      or futbeat_private.detail_inflight(cand.match_id);
    extra:=(select count(*) from futbeat_private.match_detail_requests r
        where r.expires_at>now() and r.source<>'user'
          and futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
            (select nullif(x.payload->>'startTime','')::timestamptz from futbeat_private.entities x where x.id=r.match_id))
            =cand.bucket);
    continue when not futbeat_private.detail_bucket_budget_open(cand.bucket,extra);
    insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source)
    values(cand.match_id,now(),now()+row_ttl,1,
      case cand.bucket when 'live' then 'prefetch' when 'results' then 'recent' when 'prematch' then 'prematch'
        when 'recent_hot' then 'recent' when 'recent' then 'recent' when 'upcoming' then 'prefetch'
        else 'bootstrap' end)
    on conflict(match_id) do nothing;
    if not found then continue; end if;
    insert into futbeat_private.match_detail_queue_log(event,bucket,source) values('enqueued',cand.bucket,'planner');
    if cand.bucket in ('live','results') then urgent_queued:=urgent_queued+1; else bg_queued:=bg_queued+1; end if;
    queued:=array_append(queued,cand.match_id);
  end loop;
  if cardinality(queued)>0 then perform futbeat_private.bump_metric('detail_planner_queued',cardinality(queued)); end if;
  delete from futbeat_private.match_detail_queue_log where at<now()-interval '2 days';
  return queued;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.squad_pool_due(p_ids text[], p_excluded text[], p_limit integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare eligible_ids text[]; batch_ids text[]; result jsonb:='[]'; part jsonb; pos integer:=1; batch_size integer;
  v_eff boolean:=futbeat_private.detail_efficiency_on();
begin
 if p_limit<1 or coalesce(cardinality(p_ids),0)=0 then return result; end if;
 -- Eligibility precedes the bounded mapping batches. Same-kickoff ties remain
 -- deterministic even if thousands of matches share one kickoff.
 with canonical as materialized (
  select distinct futbeat_private.squad_candidate_id('team',id) team_id from (select distinct unnest(p_ids) id) x
 ), eligible as (
  select c.team_id,d.fetched_at from canonical c
  join futbeat_private.entities e on e.id=c.team_id and e.kind='team'
  left join futbeat_private.team_detail_coverage d on d.team_id=c.team_id
  where not c.team_id=any(p_excluded)
   and coalesce(d.next_retry_at,d.fetched_at+case when v_eff and d.fetched_at is not null
     then futbeat_private.team_squad_ttl(c.team_id) else interval '7 days' end,'-infinity')<=now()
   and coalesce(d.lease_until,'-infinity')<=now()
 ) select array_agg(team_id order by fetched_at nulls first,team_id) into eligible_ids from eligible;
 batch_size:=greatest(16,least(p_limit,25));
 while pos<=coalesce(cardinality(eligible_ids),0) and jsonb_array_length(result)<p_limit loop
  batch_ids:=eligible_ids[pos:pos+batch_size-1];
  -- Bounded set-based mapping query; refill until enough valid mappings exist.
  -- Reverse redirect traversal starts ONLY from this eligible batch.
  with recursive mapping_targets(team_id,mapping_id,depth,path) as (
   select id,id,0,array[id] from unnest(batch_ids) id
   union all
   select t.team_id,r.alias_id,t.depth+1,t.path||r.alias_id from mapping_targets t
   join futbeat_private.entity_redirects r on r.kind='team' and r.canonical_id=t.mapping_id
   where t.depth<8 and not r.alias_id=any(t.path)
  ), provider_mapping as (
   select distinct on(t.team_id) t.team_id,pe.external_id from mapping_targets t
   join futbeat_private.provider_entities pe on pe.canonical_id=t.mapping_id
   where pe.provider='goal_api' and pe.kind='team' and nullif(btrim(pe.external_id),'') is not null
   order by t.team_id,case when pe.last_seen_at>=now()-interval '180 days' then pe.last_seen_at end desc nulls last,pe.external_id desc
  ), selected as (
   select m.team_id,m.external_id,d.fetched_at from provider_mapping m
   left join futbeat_private.team_detail_coverage d on d.team_id=m.team_id
   order by array_position(batch_ids,m.team_id) limit p_limit-jsonb_array_length(result)
  ) select coalesce(jsonb_agg(jsonb_build_object('teamId',team_id,'externalTeamId',external_id,'lastFetchedAt',fetched_at)
    order by array_position(batch_ids,team_id)),'[]') into part from selected;
  result:=result||part;
  pos:=pos+batch_size;
 end loop;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.futbeat_reserve_goal_squad_call(p_team_id text, p_external_team_id text, p_trigger_source text DEFAULT 'github-actions'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id); result jsonb; mapped_tid text;
begin
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('squad:'||tid,0));
 if exists(select 1 from futbeat_private.team_detail_coverage where team_id=tid
   and (coalesce(next_retry_at,fetched_at+futbeat_private.team_squad_ttl(tid),'-infinity')>now() or lease_until>now())) then
   return jsonb_build_object('allowed',false,'reason','squad_fresh_backoff_or_inflight');
 end if;
 -- Keep the existing daily cap and LIVE reserve exactly as before.
 select canonical_id into mapped_tid from futbeat_private.provider_entities pe
   where pe.provider='goal_api' and pe.kind='team' and pe.external_id=p_external_team_id
     and futbeat_private.futbeat_resolve_entity_id('team',pe.canonical_id)=tid;
 result:=futbeat_private.reserve_squad_before_coverage(coalesce(mapped_tid,tid),p_external_team_id,p_trigger_source);
 result:=result||jsonb_build_object('teamId',tid);
 if (result->>'allowed')::boolean then
   insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,last_attempt_at,lease_until)
   values(tid,'goal_api',null,0,now(),now()+interval '10 minutes')
   on conflict(team_id) do update set last_attempt_at=excluded.last_attempt_at,lease_until=excluded.lease_until;
 end if;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.team_squad_state(p_team_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare
  players integer;
  cov futbeat_private.team_detail_coverage;
  fresh_until timestamptz;
  state text;
  reason text;
begin
  select count(*)::integer into players
  from futbeat_private.team_squad_player_ids(p_team_id);
  select * into cov from futbeat_private.team_detail_coverage where team_id=p_team_id;
  fresh_until:=coalesce(cov.last_success_at,cov.fetched_at)+futbeat_private.team_squad_ttl(p_team_id);
  if players>0 then
    state:=case when fresh_until>now() then 'AVAILABLE' else 'STALE' end;
  elsif cov.status='NO_DATA'
    and coalesce(cov.next_retry_at,cov.fetched_at+interval '30 days','-infinity')>now() then
    state:='CONFIRMED_EMPTY'; reason:='provider_no_data';
  elsif not futbeat_private.team_squad_mapped(p_team_id) then
    state:='UNAVAILABLE'; reason:='no_provider_source';
  else
    state:='PENDING';
    reason:=case
      when cov.team_id is null then 'never_fetched'
      when cov.lease_until>now() then 'in_flight'
      when cov.status='FETCH_FAILED' then 'retrying'
      when cov.status='NO_DATA' then 'revalidating'
      else 'queued' end;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'state',state,
    'reason',reason,
    'playerCount',players,
    'updatedAt',coalesce(cov.last_success_at,cov.fetched_at)));
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.futbeat_team_squad_plan(p_limit integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb:='[]'; part jsonb; ids text[]; comps text[]; chosen text[]:=array[]::text[];
 tier integer; remaining integer;
 -- Background refreshes stop at the daily pace; followed and requested teams do not.
 v_paced boolean:=futbeat_private.detail_efficiency_on() and (
   select count(*) from futbeat_private.provider_call_ledger l
   where l.provider='goal_api' and l.call_kind='team-squad'
     and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
 )>=futbeat_private.quota_setting('goal_api','squadBackgroundDailyCap',25);
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 foreach tier in array array[0,1,6,2,3,4,5] loop
  remaining:=p_limit-jsonb_array_length(result);
  exit when remaining<=0;
  continue when v_paced and tier not in (1,6);
  part:='[]'; ids:=array[]::text[];
  if tier=0 then
   -- Exhaustive LIVE source, no match pre-limit. Global result limit follows.
   select array_agg(distinct x.id) into ids from futbeat_private.calendar_matches c
   join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   cross join lateral(values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) x(id)
   where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
    and e.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES');
   part:=futbeat_private.squad_pool_due(ids,chosen,coalesce(cardinality(ids),0));
   select coalesce(jsonb_agg(value order by ord),'[]') into part from
    (select value,ord from jsonb_array_elements(part) with ordinality x(value,ord) order by ord limit remaining) q;
  elsif tier=1 then
   select array_agg(subject_id) into ids from futbeat_private.coverage_interests where subject_type='team' and explicit_followers>0;
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  elsif tier=2 then
   part:=futbeat_private.squad_upcoming_due(chosen,remaining);
  elsif tier=6 then
   select array_agg(d.team_id order by d.requested_at desc,d.team_id) into ids
   from futbeat_private.team_squad_demands d
   left join futbeat_private.team_detail_coverage c on c.team_id=d.team_id
   where d.requested_at>now()-interval '7 days'
     and d.requested_at>coalesce(c.last_attempt_at,'-infinity');
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  elsif tier in (3,4) then
   if tier=3 then
    select array_agg(distinct futbeat_private.squad_candidate_id('competition',subject_id)) into comps
    from futbeat_private.coverage_interests where subject_type='competition' and explicit_followers>0;
   else
    select array_agg(competition_id) into comps from futbeat_private.competition_editorial_metadata where relevance_score>=800 and source<>'derived';
   end if;
   if coalesce(cardinality(comps),0)>0 then
    ids:=futbeat_private.squad_competition_pool(comps);
    part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
   end if;
  else
   select array_agg(distinct entity_id) into ids from futbeat_private.temporary_interests where entity_type='team' and expires_at>now();
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  end if;
  select result||coalesce(jsonb_agg(value||jsonb_build_object(
   'priority',case when tier=6 then 45000 else 60000-tier*10000 end,'priorityTier',tier,
   'reason',(array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened','requested'])[tier+1]) order by ord),'[]'),
   chosen||coalesce(array_agg(value->>'teamId' order by ord),array[]::text[])
  into result,chosen from jsonb_array_elements(part) with ordinality x(value,ord);
 end loop;
 return result;
end $function$;
