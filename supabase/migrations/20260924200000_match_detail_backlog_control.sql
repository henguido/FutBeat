-- Match-detail backlog control: cost-aware, section-aware planning.
--
-- Measured root cause (backend/bench/detail_backlog_sim.mjs, stationary mix,
-- simulated provider): the worker runs the planner before EVERY reservation
-- (up to 4 per minute) and each run admits up to detailPlannerBatch rows,
-- while at most ~4 are drained per minute, so the queue grows without bound
-- (recent: 112 rows in 10 simulated minutes). Meanwhile every mapped LIVE
-- match is re-fetched on the 5-minute user cadence by the planner, ranked
-- above everything but user LIVE opens: 93% of calls were planner LIVE
-- refreshes, most of them adding nothing, and pre-match rows were starved.
--
-- Policy (all values in provider_quota_policy.freshness, generic):
--   * the planner runs at most once per plannerMinIntervalSeconds;
--   * temporal buckets: live, results (pending verification), prematch,
--     upcoming (first fetch only), recent_hot (< recentHotHours), recent
--     (< recentFinishedHours), history (< historyCoverageDays), old (user
--     demand only);
--   * section-aware background need (match_detail_planner_due): live only
--     while its lineup is missing (liveRetryMinutes) or every
--     plannerLiveRefreshMinutes; finished matches get one post-match fetch
--     and then only while a wanted section is UNKNOWN (retry gap by age) or a
--     NO_DATA recheck is due; complete matches cost nothing;
--   * per match and phase at most plannerMaxFetchesPerMatchDay background
--     fetches per 24 h (plannerMaxPrematchFetches before kickoff, spaced
--     prematchRetryMinutes);
--   * all background work except result verification stops at
--     plannerMinRemaining (above the user floor), so user opens always keep
--     a reserve of their own; background LIVE refresh only runs in the
--     abundant/normal bands;
--   * admission control with hysteresis (plannerQueueHighWater /
--     plannerQueueLowWater) for background buckets; live and results are
--     always admitted; user opens never go through the planner;
--   * adaptive batch by provider band (abundant/normal/tight/critical/
--     unknown); history only runs in the abundant band;
--   * per-bucket daily budgets (detailShare*) inside the central quota
--     manager's blind-aware cap; user opens and results keep their capacity;
--   * NO_DATA keeps reason, first/last empty time and a recheck time
--     (noDataRecheckRecentHours / noDataRecheckHistoryDays);
--   * usefulness metrics per bucket and a queue log for enqueue/drain rates;
--     futbeat_match_detail_backlog_audit() answers where the calls went.

update futbeat_private.provider_quota_policy set
  freshness=freshness||'{"plannerLiveRefreshMinutes":30,"recentHotHours":6,"finalFetchAfterMinutes":120,
    "plannerMaxFetchesPerMatchDay":4,"plannerMaxLiveFetches":6,"plannerRowTtlMinutes":60,"plannerMinRemaining":400,"plannerMaxPrematchFetches":3,"prematchRetryMinutes":20,"plannerQueueHighWater":12,"plannerQueueLowWater":4,
    "plannerMinIntervalSeconds":50,"noDataRecheckRecentHours":12,"noDataRecheckHistoryDays":30,
    "fairnessAgingMinutes":20,"plannerBatchAbundant":4,"plannerBatchNormal":2,"plannerBatchTight":1,
    "plannerBatchUnknown":1,"detailShareLive":0.25,"detailSharePrematch":0.15,"detailShareResults":0.15,
    "detailShareRecent":0.25,"detailShareHistory":0.08,"detailShareUpcoming":0.03}',
  updated_at=now()
where provider='goal_api';

create index if not exists provider_call_ledger_detail_match_idx
  on futbeat_private.provider_call_ledger((metadata->>'matchId'),reserved_at desc)
  where call_kind='match-detail';

alter table futbeat_private.match_detail_coverage
  add column if not exists lineup_empty_first_at timestamptz,
  add column if not exists lineup_empty_last_at timestamptz,
  add column if not exists lineup_recheck_at timestamptz,
  add column if not exists lineup_no_data_reason text,
  add column if not exists statistics_empty_first_at timestamptz,
  add column if not exists statistics_empty_last_at timestamptz,
  add column if not exists statistics_recheck_at timestamptz,
  add column if not exists statistics_no_data_reason text,
  add column if not exists last_bucket text;

-- Planner hysteresis and pacing (single row).
create table futbeat_private.detail_planner_state (
  singleton boolean primary key default true check(singleton),
  background_paused boolean not null default false,
  paused_changed_at timestamptz not null default now(),
  last_planned_at timestamptz
);
insert into futbeat_private.detail_planner_state(singleton) values(true);
alter table futbeat_private.detail_planner_state enable row level security;
revoke all on futbeat_private.detail_planner_state from public,anon,authenticated;

-- Insert-only queue log (enqueue/drain rates); pruned after two days.
create table futbeat_private.match_detail_queue_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  event text not null check(event in ('enqueued','dropped','reserved','useful','empty')),
  bucket text,
  source text
);
create index match_detail_queue_log_at_idx on futbeat_private.match_detail_queue_log(at);
alter table futbeat_private.match_detail_queue_log enable row level security;
revoke all on futbeat_private.match_detail_queue_log from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- Temporal bucket and section-aware background need.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.match_detail_bucket(p_status text,p_start timestamptz)
returns text language sql stable set search_path='' as $$
  select case
    when p_start is null or coalesce(p_status,'') in ('CANCELLED','POSTPONED') then 'none'
    when p_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
    when p_status='FINISHED_PENDING_VERIFICATION' then 'results'
    when p_start>now()+make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer) then
      case when p_start<=now()+make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer)
        then 'upcoming' else 'future' end
    when p_start>now() then 'prematch'
    when p_start>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer) then 'recent_hot'
    when p_start>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer) then 'recent'
    when p_start>now()-make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer) then 'history'
    else 'old' end
$$;

create or replace function futbeat_private.match_detail_bucket_rank(p_bucket text)
returns integer language sql immutable set search_path='' as $$
  select case p_bucket when 'live' then 1 when 'results' then 2 when 'prematch' then 3
    when 'recent_hot' then 4 when 'recent' then 5 when 'upcoming' then 6 when 'history' then 7 else 9 end
$$;

create or replace function futbeat_private.match_detail_planner_due(p_match_id text,p_bucket text)
returns boolean language plpgsql stable set search_path='' as $$
declare cov futbeat_private.match_detail_coverage; fetched timestamptz; kickoff timestamptz;
  sections jsonb; gap interval; final_after interval; phase text; used integer;
begin
  if p_bucket is null or p_bucket not in ('live','results','prematch','upcoming','recent_hot','recent','history') then
    return false;
  end if;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if coalesce(cov.next_retry_at>now(),false) then return false; end if;
  select c.fetched_at into fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  -- Result verification is protected: its own cadence, no per-match cap.
  if p_bucket='results' then
    return fetched is null or futbeat_private.match_detail_due('FINISHED_PENDING_VERIFICATION',fetched);
  end if;
  -- Hard bound on background work per match and phase (user opens are not
  -- counted): pre-match and LIVE attempts never eat the post-match fetch.
  phase:=case p_bucket when 'prematch' then 'prematch' when 'live' then 'live' else 'finished' end;
  select count(*) into used from futbeat_private.provider_call_ledger l
  where l.call_kind='match-detail' and l.metadata->>'matchId'=p_match_id
    and l.reserved_at>now()-interval '1 day' and coalesce(l.metadata->>'source','')<>'user'
    and case coalesce(l.metadata->>'bucket','') when 'prematch' then 'prematch' when 'live' then 'live'
      else 'finished' end=phase;
  if used>=(case phase
      when 'prematch' then futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetches',3)
      when 'live' then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetches',6)
      else futbeat_private.quota_setting('goal_api','plannerMaxFetchesPerMatchDay',4) end) then
    return false;
  end if;
  if fetched is null then return true; end if;
  if p_bucket='upcoming' then return false; end if;
  if p_bucket='live' then
    return coalesce((coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
        and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','liveRetryMinutes',5)::integer))
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
end $$;

-- Daily budget of a background bucket (blind-aware base cap).
create or replace function futbeat_private.detail_bucket_budget_open(p_bucket text,p_extra integer default 0)
returns boolean language sql stable set search_path='' as $$
  with d as (select futbeat_private.quota_decision('goal_api','match-detail','coverage') d),
  share as (select case p_bucket
      when 'live' then futbeat_private.quota_setting('goal_api','detailShareLive',0.25)
      when 'results' then futbeat_private.quota_setting('goal_api','detailShareResults',0.15)
      when 'prematch' then futbeat_private.quota_setting('goal_api','detailSharePrematch',0.15)
      when 'recent_hot' then futbeat_private.quota_setting('goal_api','detailShareRecent',0.25)
      when 'recent' then futbeat_private.quota_setting('goal_api','detailShareRecent',0.25)
      when 'history' then futbeat_private.quota_setting('goal_api','detailShareHistory',0.08)
      when 'upcoming' then futbeat_private.quota_setting('goal_api','detailShareUpcoming',0.03)
      else 0 end s)
  select p_bucket='results' or (select count(*) from futbeat_private.provider_call_ledger l
      where l.provider='goal_api' and l.call_kind='match-detail'
        and l.reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
        and coalesce(l.metadata->>'source','')<>'user'
        and case when p_bucket in ('recent_hot','recent') then l.metadata->>'bucket' in ('recent_hot','recent')
          else l.metadata->>'bucket'=p_bucket end)+p_extra
    <floor((d.d->>'safetyCap')::numeric*share.s)
  from d,share
$$;

-- Adaptive background batch by provider band (history only when abundant).
create or replace function futbeat_private.detail_planner_band()
returns jsonb language sql stable set search_path='' as $$
  with d as (select futbeat_private.quota_decision('goal_api','match-detail','coverage') d)
  select jsonb_build_object('band',d->>'band','batch',case d->>'band'
      when 'abundant' then futbeat_private.quota_setting('goal_api','plannerBatchAbundant',4)
      when 'normal' then futbeat_private.quota_setting('goal_api','plannerBatchNormal',2)
      when 'tight' then futbeat_private.quota_setting('goal_api','plannerBatchTight',1)
      when 'unknown' then futbeat_private.quota_setting('goal_api','plannerBatchUnknown',1)
      else 0 end::integer,
    'history',d->>'band'='abundant',
    'recent',d->>'band' in ('abundant','normal','unknown'))
  from d
$$;

-- Background work (except result verification) stops above the user floor.
create or replace function futbeat_private.detail_planner_floor_ok()
returns boolean language sql stable set search_path='' as $$
  select coalesce(futbeat_private.provider_remaining('goal_api')
    >futbeat_private.quota_setting('goal_api','plannerMinRemaining',400),true)
$$;

-- ---------------------------------------------------------------------------
-- Planner.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.plan_match_detail_coverage(p_limit integer default null)
returns text[] language plpgsql security definer set search_path='' as $$
declare band jsonb:=futbeat_private.detail_planner_band();
  high integer:=futbeat_private.quota_setting('goal_api','plannerQueueHighWater',12)::integer;
  low integer:=futbeat_private.quota_setting('goal_api','plannerQueueLowWater',4)::integer;
  urgent_lim integer:=greatest(1,least(coalesce(p_limit,4),20));
  bg_lim integer; depth integer; paused boolean; queued text[]:='{}'; bg_queued integer:=0;
  -- The central shares still bound all planner work (background / LIVE lane).
  bg_open boolean:=futbeat_private.detail_share_open('background');
  live_open boolean:=futbeat_private.detail_share_open('live');
  -- Background work (except results) stops above the user floor.
  floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
  urgent_queued integer:=0; cand record; extra integer;
  prematch interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer);
  upcoming interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer);
  history interval:=make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer);
  final_after interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  row_ttl interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerRowTtlMinutes',60)::integer);
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));
  -- Cleanup: expired rows are replaced (not upserted); background rows that
  -- no longer need a fetch or lost their mapping are dropped.
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
  -- Admission control with hysteresis on the background backlog.
  -- Background depth only (LIVE and results rows never pause background).
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
    with window_matches as (
      select cm.match_id,cm.start_time,futbeat_private.match_detail_status(cm.match_id) status
      from futbeat_private.calendar_matches cm
      where cm.start_time between now()-history and now()+upcoming
    ), profiled as (
      select w.*,futbeat_private.match_detail_bucket(w.status,w.start_time) bucket
      from window_matches w
    )
    select p.match_id,p.bucket,p.start_time,
      coalesce(meta.relevance_score,0) relevance
    from profiled p
    join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.entities e on e.id=p.match_id
    left join futbeat_private.competition_editorial_metadata meta on meta.competition_id=e.payload->>'competitionId'
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      and coalesce(c.next_retry_at,'-infinity')<=now()
      -- Cheap SQL prefilter so settled matches never crowd the candidate limit:
      -- upcoming only without any detail; finished only when not settled.
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history') and d.fetched_at>=p.start_time+final_after
        and coalesce(c.lineup_state,'UNKNOWN')<>'UNKNOWN' and coalesce(c.statistics_state,'UNKNOWN')<>'UNKNOWN'
        and coalesce(c.lineup_recheck_at,'infinity')>now() and coalesce(c.statistics_recheck_at,'infinity')>now())
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by futbeat_private.match_detail_bucket_rank(p.bucket),coalesce(meta.relevance_score,0) desc,
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
    -- Cheapest checks first; open rows of this bucket (including the ones
    -- queued in this run) count against its daily budget exactly once.
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
end $$;

-- Worker entry (called before each reservation): planning at most once per
-- plannerMinIntervalSeconds, never twice at the same time.
create or replace function futbeat_private.enqueue_stale_interested_match_detail()
returns text language plpgsql security definer set search_path='' as $$
declare last_run timestamptz;
begin
  select last_planned_at into last_run from futbeat_private.detail_planner_state for update skip locked;
  if not found then return null; end if;
  if last_run>now()-make_interval(secs=>futbeat_private.quota_setting('goal_api','plannerMinIntervalSeconds',50)) then
    return null;
  end if;
  update futbeat_private.detail_planner_state set last_planned_at=now() where singleton;
  return (futbeat_private.plan_match_detail_coverage(null))[1];
end $$;

-- ---------------------------------------------------------------------------
-- Negative cache with provenance, and usefulness per call.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.track_match_detail_sections()
returns trigger language plpgsql security definer set search_path='' as $$
declare has_lineup boolean; has_stats boolean; finished boolean; miss_limit constant integer:=2;
  miss_spacing constant interval:=interval '15 minutes'; prior timestamptz; counts boolean;
  before_cov futbeat_private.match_detail_coverage; after_cov futbeat_private.match_detail_coverage;
  kickoff timestamptz; recheck interval; bucket text;
begin
  has_lineup:=exists(select 1 from futbeat_private.lineup_rows(new.payload));
  has_stats:=futbeat_private.detail_statistics_count(new.payload->'statistics')>0;
  finished:=futbeat_private.match_is_finished(new.match_id);
  select * into before_cov from futbeat_private.match_detail_coverage where match_id=new.match_id;
  prior:=before_cov.last_fetch_at;
  counts:=finished and (prior is null or new.fetched_at>=prior+miss_spacing);
  insert into futbeat_private.match_detail_coverage as c(
    match_id,lineup_state,statistics_state,lineup_misses,statistics_misses,last_fetch_at)
  values(new.match_id,
    case when has_lineup then 'AVAILABLE' else 'UNKNOWN' end,
    case when has_stats then 'AVAILABLE' else 'UNKNOWN' end,
    case when has_lineup or not counts then 0 else 1 end,
    case when has_stats or not counts then 0 else 1 end,
    new.fetched_at)
  on conflict(match_id) do update set
    lineup_misses=case when has_lineup then 0 when counts then c.lineup_misses+1 else c.lineup_misses end,
    statistics_misses=case when has_stats then 0 when counts then c.statistics_misses+1 else c.statistics_misses end,
    lineup_state=case when has_lineup then 'AVAILABLE'
      when counts and c.lineup_misses+1>=miss_limit then 'NO_DATA'
      when c.lineup_state='NO_DATA' then 'NO_DATA' else 'UNKNOWN' end,
    statistics_state=case when has_stats then 'AVAILABLE'
      when counts and c.statistics_misses+1>=miss_limit then 'NO_DATA'
      when c.statistics_state='NO_DATA' then 'NO_DATA' else 'UNKNOWN' end,
    last_fetch_at=case when counts or c.last_fetch_at is null then new.fetched_at else c.last_fetch_at end,
    failure_count=0,next_retry_at=null,last_error=null
  returning * into after_cov;
  -- NO_DATA provenance and recheck: long for history, shorter for recent.
  select nullif(e.payload->>'startTime','')::timestamptz into kickoff
  from futbeat_private.entities e where e.id=new.match_id and e.kind='match';
  recheck:=case when kickoff>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer)
    then make_interval(hours=>futbeat_private.quota_setting('goal_api','noDataRecheckRecentHours',12)::integer)
    else make_interval(days=>futbeat_private.quota_setting('goal_api','noDataRecheckHistoryDays',30)::integer) end;
  bucket:=(select l.metadata->>'bucket' from futbeat_private.provider_call_ledger l
    where l.call_kind='match-detail' and l.metadata->>'matchId'=new.match_id
      and l.reserved_at>now()-interval '15 minutes' order by l.reserved_at desc limit 1);
  update futbeat_private.match_detail_coverage c set
    lineup_empty_first_at=case when has_lineup then null when counts then coalesce(c.lineup_empty_first_at,new.fetched_at) else c.lineup_empty_first_at end,
    lineup_empty_last_at=case when has_lineup then null when counts then new.fetched_at else c.lineup_empty_last_at end,
    lineup_recheck_at=case when after_cov.lineup_state='NO_DATA' and not has_lineup and counts then new.fetched_at+recheck
      when after_cov.lineup_state<>'NO_DATA' then null else c.lineup_recheck_at end,
    lineup_no_data_reason=case when after_cov.lineup_state='NO_DATA' then coalesce(c.lineup_no_data_reason,'empty_after_spaced_fetches') end,
    statistics_empty_first_at=case when has_stats then null when counts then coalesce(c.statistics_empty_first_at,new.fetched_at) else c.statistics_empty_first_at end,
    statistics_empty_last_at=case when has_stats then null when counts then new.fetched_at else c.statistics_empty_last_at end,
    statistics_recheck_at=case when after_cov.statistics_state='NO_DATA' and not has_stats and counts then new.fetched_at+recheck
      when after_cov.statistics_state<>'NO_DATA' then null else c.statistics_recheck_at end,
    statistics_no_data_reason=case when after_cov.statistics_state='NO_DATA' then coalesce(c.statistics_no_data_reason,'empty_after_spaced_fetches') end,
    last_bucket=coalesce(bucket,c.last_bucket)
  where c.match_id=new.match_id;
  if after_cov.lineup_state='NO_DATA' and coalesce(before_cov.lineup_state,'UNKNOWN')<>'NO_DATA' then
    perform futbeat_private.bump_metric('md_no_data_transitions');
  end if;
  if after_cov.statistics_state='NO_DATA' and coalesce(before_cov.statistics_state,'UNKNOWN')<>'NO_DATA' then
    perform futbeat_private.bump_metric('md_no_data_transitions');
  end if;
  return new;
end $$;

-- Usefulness of every stored detail: a new lineup, statistics or events.
create or replace function futbeat_private.track_match_detail_gain()
returns trigger language plpgsql security definer set search_path='' as $$
declare old_lineup boolean:=false; old_stats boolean:=false; old_events integer:=0;
  new_lineup boolean; new_stats boolean; new_events integer; bucket text; gained boolean;
begin
  if TG_OP='UPDATE' then
    old_lineup:=exists(select 1 from futbeat_private.lineup_rows(old.payload));
    old_stats:=futbeat_private.detail_statistics_count(old.payload->'statistics')>0;
    old_events:=coalesce(jsonb_array_length(case when jsonb_typeof(old.payload->'events')='array' then old.payload->'events' end),0);
  end if;
  new_lineup:=exists(select 1 from futbeat_private.lineup_rows(new.payload));
  new_stats:=futbeat_private.detail_statistics_count(new.payload->'statistics')>0;
  new_events:=coalesce(jsonb_array_length(case when jsonb_typeof(new.payload->'events')='array' then new.payload->'events' end),0);
  bucket:=coalesce((select l.metadata->>'bucket' from futbeat_private.provider_call_ledger l
    where l.call_kind='match-detail' and l.metadata->>'matchId'=new.match_id
      and l.reserved_at>now()-interval '15 minutes' order by l.reserved_at desc limit 1),'unattributed');
  if new_lineup and not old_lineup then perform futbeat_private.bump_metric('md_lineup_gained'); end if;
  if new_stats and not old_stats then perform futbeat_private.bump_metric('md_statistics_gained'); end if;
  if new_events>old_events then perform futbeat_private.bump_metric('md_events_gained'); end if;
  gained:=(new_lineup and not old_lineup) or (new_stats and not old_stats) or new_events>old_events;
  perform futbeat_private.bump_metric('md_calls_'||bucket);
  perform futbeat_private.bump_metric(case when gained then 'md_useful_' else 'md_empty_' end||bucket);
  insert into futbeat_private.match_detail_queue_log(event,bucket) values(case when gained then 'useful' else 'empty' end,bucket);
  -- A served planner row leaves the queue once its detail is stored (a failed
  -- call keeps it for its retry); user rows stay for the Match Center pending
  -- state until they expire.
  delete from futbeat_private.match_detail_requests r
  where r.match_id=new.match_id and r.source<>'user' and r.requested_at<=new.fetched_at;
  return null;
end $$;
drop trigger if exists match_detail_gain on futbeat_private.match_detail_cache;
drop trigger if exists match_detail_gain_update on futbeat_private.match_detail_cache;
create trigger match_detail_gain after insert on futbeat_private.match_detail_cache
for each row execute function futbeat_private.track_match_detail_gain();
create trigger match_detail_gain_update after update of payload,fetched_at on futbeat_private.match_detail_cache
for each row when (new.fetched_at>old.fetched_at) execute function futbeat_private.track_match_detail_gain();

-- Completion merges its metadata into the reservation's (completion keys
-- win), so reservation attribution (bucket, source, class) is not lost.
create or replace function public.futbeat_complete_provider_call(
  p_reservation_id bigint,
  p_status text,
  p_provider_remaining integer default null,
  p_http_status integer default null,
  p_error_code text default null,
  p_metadata jsonb default '{}'::jsonb
) returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_updated integer;
begin
  if p_status not in ('SUCCEEDED','FAILED') then raise exception 'invalid status'; end if;
  if p_metadata is null or jsonb_typeof(p_metadata) <> 'object' then raise exception 'metadata must be an object'; end if;

  update futbeat_private.provider_call_ledger
     set completed_at = now(),
         status = p_status,
         provider_remaining = p_provider_remaining,
         http_status = p_http_status,
         error_code = p_error_code,
         metadata = coalesce(metadata,'{}'::jsonb)||jsonb_strip_nulls(p_metadata)
   where id = p_reservation_id
     and status = 'RESERVED';
  get diagnostics v_updated = row_count;
  return v_updated = 1;
end;
$$;
revoke all on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) from public,anon,authenticated;
grant execute on function public.futbeat_complete_provider_call(bigint,text,integer,integer,text,jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Reservation: section/budget-aware eligibility, fair drain, attribution.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.reserve_match_detail_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_remaining integer;
  v_cap jsonb;
  v_match_id text;
  v_external text;
  v_reservation bigint;
  v_status text;
  v_class text;
  v_rank integer;
  v_allowed boolean;
  v_bg_open boolean;
  v_live_open boolean;
  v_class_ok jsonb;
  v_bucket text;
  v_source text;
  v_floor_ok boolean:=futbeat_private.detail_planner_floor_ok();
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  -- Shares are read under the quota lock (concurrent reservers cannot overrun).
  v_bg_open:=futbeat_private.detail_share_open('background');
  v_live_open:=futbeat_private.detail_share_open('live');
  -- Full quota decision per class (floors, kind caps and the blind budget),
  -- so the chosen head is always servable when any candidate is.
  select jsonb_object_agg(c,(futbeat_private.quota_decision('goal_api','match-detail',c)->>'allowed')::boolean)
  into v_class_ok
  from unnest(array['live','results','user_high','user','coverage','bootstrap']) c;

  delete from futbeat_private.match_detail_requests
  where expires_at<=now();

  -- Safety cap per kind; the class is checked per candidate below.
  v_cap:=futbeat_private.quota_decision('goal_api','match-detail','live');
  v_remaining:=(v_cap->>'providerRemaining')::integer;
  if v_cap->>'reason'='kind_daily_cap' then
    return v_cap||jsonb_build_object('allowed',false);
  end if;

  with candidates as (
    select
      r.match_id,
      pe.external_id,
      futbeat_private.match_detail_status(r.match_id) status,
      c.fetched_at,
      r.source,
      r.requested_at,
      r.user_requested_at,
      nullif(e.payload->>'startTime','')::timestamptz start_time,
      futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
        nullif(e.payload->>'startTime','')::timestamptz) bucket
    from futbeat_private.match_detail_requests r
    join futbeat_private.entities e on e.id=r.match_id and e.kind='match'
    join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=r.match_id
    left join futbeat_private.match_detail_cache c on c.match_id=r.match_id
    where r.expires_at>now()
      and not futbeat_private.detail_inflight(r.match_id)
  ), ranked as (
    select *,
      case
        when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then case when source='user' then 1 else 2 end
        when status='FINISHED_PENDING_VERIFICATION' then 2
        when source='prematch' then 3
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 3
        when source='user' then 4
        when source='recent' then 5
        when source='prefetch' then 6
        else 7
      end rank_value,
      case
        when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
        when status='FINISHED_PENDING_VERIFICATION' then 'results'
        when source='prematch' then 'user_high'
        when source='user' and coalesce(status,'SCHEDULED') not in ('VERIFIED','CANCELLED','ABANDONED','POSTPONED')
          and start_time>now()-interval '3 hours' then 'user_high'
        when source='user' then 'user'
        when source in ('recent','prefetch') then 'coverage'
        else 'bootstrap'
      end quota_class
    from candidates
    -- User opens keep the full freshness rules; background rows must still
    -- be due by the section-aware policy and fit their bucket budget.
    where case when source='user' then futbeat_private.match_detail_needs_fetch(match_id)
      else coalesce(futbeat_private.match_detail_planner_due(match_id,bucket)
        and futbeat_private.detail_bucket_budget_open(bucket),false) end
  )
  -- Best allowed candidate first; if none fits its class, the best due one
  -- explains the refusal.
  select match_id,external_id,status,quota_class,rank_value,
    coalesce((v_class_ok->>quota_class)::boolean,false),bucket,source
  into v_match_id,v_external,v_status,v_class,v_rank,v_allowed,v_bucket,v_source
  from ranked
  -- Planner work only within its share: never picked when it cannot be
  -- served, so it cannot block a user open or a result.
  where source='user' or quota_class='results'
    -- Background work stops above the user floor: users keep their reserve.
    or (quota_class='live' and v_live_open and v_floor_ok)
    or (quota_class<>'live' and v_bg_open and v_floor_ok)
  order by 6 desc,
    (source='user' and coalesce(user_requested_at,requested_at)
      <now()-make_interval(secs=>futbeat_private.quota_setting('goal_api','userAgingSeconds',60))) desc,
    -- Fair drain: waiting background rows climb within the background ranks
    -- (never above a user open); oldest first within a rank.
    case when source<>'user' and rank_value>=5 then greatest(5,rank_value-floor(extract(epoch from now()-requested_at)/60
      /futbeat_private.quota_setting('goal_api','fairnessAgingMinutes',20))::integer) else rank_value end,
    requested_at,match_id
  limit 1;

  if v_match_id is null or not v_allowed then
    return jsonb_build_object(
      'allowed',false,
      'reason',case when v_match_id is null then 'no_detail_due'
        else coalesce(futbeat_private.quota_decision('goal_api','match-detail',v_class)->>'reason',
          'provider_remaining_reserve') end,
      'quotaClass',v_class,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  -- Full decision for the chosen class: when remaining is unknown, non-LIVE
  -- classes also respect the conservative daily total and per-kind share.
  if not (futbeat_private.quota_decision('goal_api','match-detail',v_class)->>'allowed')::boolean then
    return futbeat_private.quota_decision('goal_api','match-detail',v_class)||jsonb_build_object(
      'allowed',false,'quotaClass',v_class,'matchId',v_match_id);
  end if;

  -- Always acquire quota then match lock; recheck in a fresh statement.
  perform pg_advisory_xact_lock(
    hashtext('futbeat-match-detail-inflight'),hashtext(v_match_id)
  );
  if futbeat_private.detail_inflight(v_match_id) then
    return jsonb_build_object(
      'allowed',false,'reason','detail_inflight','matchId',v_match_id,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','match-detail',left(p_trigger_source,40),now(),
    jsonb_build_object('matchId',v_match_id,'externalMatchId',v_external,
      'status',v_status,'quotaClass',v_class,'priority',v_rank,'bucket',v_bucket,'source',v_source)
  )
  returning id into v_reservation;
  insert into futbeat_private.match_detail_queue_log(event,bucket,source) values('reserved',v_bucket,v_source);

  return jsonb_build_object(
    'allowed',true,
    'bucket',v_bucket,
    'reservationId',v_reservation,
    'matchId',v_match_id,
    'externalMatchId',v_external,
    'status',v_status,
    'quotaClass',v_class,
    'priority',v_rank,
    'detailUsed',(v_cap->>'usedToday')::integer+1,
    'safetyCap',(v_cap->>'safetyCap')::integer,
    'providerRemaining',v_remaining
  );
end
$$;

-- ---------------------------------------------------------------------------
-- Reproducible audit: where do match-detail calls go and what do they buy?
-- ---------------------------------------------------------------------------
create or replace function public.futbeat_match_detail_backlog_audit()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
begin
  with q as (
    select r.match_id,r.source,r.requested_at,
      futbeat_private.match_detail_bucket(futbeat_private.match_detail_status(r.match_id),
        nullif(e.payload->>'startTime','')::timestamptz) bucket,
      exists(select 1 from futbeat_private.provider_entities pe where pe.provider='goal_api' and pe.kind='match'
        and pe.canonical_id=r.match_id) mapped,
      c.fetched_at is not null has_detail,
      cov.lineup_state,cov.statistics_state,coalesce(cov.next_retry_at>now(),false) in_backoff,
      futbeat_private.detail_inflight(r.match_id) inflight
    from futbeat_private.match_detail_requests r
    left join futbeat_private.entities e on e.id=r.match_id
    left join futbeat_private.match_detail_cache c on c.match_id=r.match_id
    left join futbeat_private.match_detail_coverage cov on cov.match_id=r.match_id
    where r.expires_at>now()
  ), q2 as (
    select q.*,case when source='user' then futbeat_private.match_detail_needs_fetch(match_id)
      else futbeat_private.match_detail_planner_due(match_id,bucket) end eligible from q
  ), calls as (
    select coalesce(l.metadata->>'bucket','legacy:'||coalesce(l.metadata->>'quotaClass','unknown')) bucket,
      coalesce(l.metadata->>'source','unknown') source,l.metadata->>'matchId' match_id,l.status
    from futbeat_private.provider_call_ledger l
    where l.provider='goal_api' and l.call_kind='match-detail' and l.reserved_at>=day_start
  ), metrics as (
    select metric,sum(value)::bigint v from futbeat_private.demand_metrics
    where day=(now() at time zone 'UTC')::date and metric like 'md\_%' group by metric
  ), log1h as (
    select event,count(*) n from futbeat_private.match_detail_queue_log where at>now()-interval '1 hour' group by event
  )
  select jsonb_build_object(
    'queue',jsonb_build_object(
      'depth',(select count(*) from q2),
      'bySource',(select coalesce(jsonb_object_agg(source,n),'{}') from (select source,count(*) n from q2 group by source) x),
      'byBucket',(select coalesce(jsonb_object_agg(bucket,n),'{}') from (select bucket,count(*) n from q2 group by bucket) x),
      'eligible',(select count(*) from q2 where eligible),
      'noLongerNeeded',(select count(*) from q2 where not eligible),
      'withLineupAvailable',(select count(*) from q2 where lineup_state='AVAILABLE'),
      'withSectionNoData',(select count(*) from q2 where 'NO_DATA' in (lineup_state,statistics_state)),
      'inBackoff',(select count(*) from q2 where in_backoff),
      'withDetail',(select count(*) from q2 where has_detail),
      'unmapped',(select count(*) from q2 where not mapped),
      'inflight',(select count(*) from q2 where inflight),
      'oldestAgeSecondsBySource',(select coalesce(jsonb_object_agg(source,s),'{}') from
        (select source,extract(epoch from now()-min(requested_at))::integer s from q2 group by source) x)),
    'callsToday',jsonb_build_object(
      'total',(select count(*) from calls),
      'byBucket',(select coalesce(jsonb_object_agg(bucket,n),'{}') from (select bucket,count(*) n from calls group by bucket) x),
      'bySource',(select coalesce(jsonb_object_agg(source,n),'{}') from (select source,count(*) n from calls group by source) x),
      'distinctMatches',(select count(distinct match_id) from calls),
      'repeatCalls',(select count(*)-count(distinct match_id) from calls),
      'failed',(select count(*) from calls where status='FAILED')),
    'outcomesToday',jsonb_build_object(
      'metrics',(select coalesce(jsonb_object_agg(metric,v),'{}') from metrics),
      'usefulCoveragePerCall',(select round(coalesce(sum(v) filter(where metric like 'md\_useful\_%'),0)::numeric
        /nullif(sum(v) filter(where metric like 'md\_calls\_%'),0),3) from metrics)),
    'ratesPerMinuteLastHour',(select coalesce(jsonb_object_agg(event,round(n/60.0,2)),'{}') from log1h),
    'backlogGrowing',coalesce((select n from log1h where event='enqueued'),0)
      >coalesce((select n from log1h where event='reserved'),0)+coalesce((select n from log1h where event='dropped'),0),
    'planner',(select jsonb_build_object('backgroundPaused',background_paused,'pausedChangedAt',paused_changed_at,
      'lastPlannedAt',last_planned_at) from futbeat_private.detail_planner_state)
      ||futbeat_private.detail_planner_band())
  into result;
  return result;
end $$;

revoke all on function
  futbeat_private.match_detail_bucket(text,timestamptz),
  futbeat_private.match_detail_bucket_rank(text),
  futbeat_private.match_detail_planner_due(text,text),
  futbeat_private.detail_bucket_budget_open(text,integer),
  futbeat_private.detail_planner_band(),
  futbeat_private.detail_planner_floor_ok(),
  futbeat_private.plan_match_detail_coverage(integer),
  futbeat_private.enqueue_stale_interested_match_detail(),
  futbeat_private.track_match_detail_sections(),
  futbeat_private.track_match_detail_gain(),
  futbeat_private.reserve_match_detail_call(text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_match_detail_backlog_audit() from public,anon,authenticated;
grant execute on function public.futbeat_match_detail_backlog_audit() to service_role;

notify pgrst,'reload schema';
