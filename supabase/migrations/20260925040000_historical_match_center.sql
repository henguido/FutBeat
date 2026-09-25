-- Issue #101: historical Match Center detail loading.
--
-- Root causes (reads are already fast: 9-18 ms in production):
--   * `available` means "something displayable is persisted" (a detail cache
--     row OR a provider observation). The phone used it as "complete", so a
--     historical match with only a provider observation (detailLevel 'live',
--     coverage.detail 'missing') never asked for its full detail.
--   * GOAL finals stay FINISHED_PENDING_VERIFICATION forever (nothing sets
--     VERIFIED). match_detail_needs_fetch applied the 30-minute FPV clock
--     cadence at any age, so a settled historical detail was re-fetched on
--     every open instead of staying frozen.
--
-- Changes:
--   * match_detail_fetchable(match): GOAL-mapped and inside the provider
--     horizon (historyHorizonDays, default 90, unchanged behaviour). Single
--     definition used by request_match_detail and the read model.
--   * FPV clock cadence only inside resultsWindowHours after kickoff (the same
--     window #112 uses for the 'results' bucket). Later, only the section
--     rules apply: lineup/statistics AVAILABLE or NO_DATA = frozen.
--   * read_match_detail adds `hydrationNeeded` (top level and in coverage):
--     true only when the match is fetchable, a fetch is needed and nothing is
--     queued/in flight for it. It is the single server-side answer to "should
--     the client register demand"; `available` keeps meaning "displayable".
--   * request_match_detail records the kind of open (warm | refresh |
--     partial | cold | out_of_horizon) in the existing sharded demand_metrics
--     counters (one light increment; no per-read row).
--   * reserve_match_detail_call: a user open of a FINISHED_PENDING_VERIFICATION
--     match is the protected 'results' class only inside the results window
--     (bucket 'results'); older finals are history and stay 'user' demand
--     (they used to borrow the results floor). Planner logic is unchanged.
--   * futbeat_historical_match_center_metrics(): service-only diagnostic for
--     warm/cold/partial opens, hydration duration and coverage per age bucket.
-- No planner, quota class, floor or reserve changes: a historical open stays
-- user demand, and nothing pre-fetches history.

create or replace function futbeat_private.match_detail_fetchable(p_match_id text)
returns boolean language sql stable set search_path='' as $$
  select exists(
    select 1 from futbeat_private.entities e
    join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=e.id
    where e.id=p_match_id and e.kind='match'
      and nullif(e.payload->>'startTime','')::timestamptz
        between now()-make_interval(days=>futbeat_private.quota_setting('goal_api','historyHorizonDays',90)::integer)
          and now()+interval '24 hours')
$$;

-- Clock cadence only for live evidence and for a final inside the results
-- window; every other match is fetched only while a wanted section is
-- UNKNOWN (retry gap). A settled historical detail is frozen.
create or replace function futbeat_private.match_detail_needs_fetch(p_match_id text)
returns boolean language plpgsql stable set search_path='' as $$
declare status text:=futbeat_private.match_detail_status(p_match_id); fetched timestamptz;
  cov futbeat_private.match_detail_coverage; sections jsonb; kickoff timestamptz;
begin
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if cov.next_retry_at>now() then return false; end if;
  select fetched_at into fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
  if fetched is null then return true; end if;
  if status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     and futbeat_private.match_detail_due(status,fetched) then
    return true;
  end if;
  if status='FINISHED_PENDING_VERIFICATION' and futbeat_private.match_detail_due(status,fetched) then
    select nullif(e.payload->>'startTime','')::timestamptz into kickoff
    from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
    if kickoff>now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer) then
      return true;
    end if;
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  return fetched<now()-make_interval(secs=>(sections->>'retryGap')::double precision)
    and (((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN')
      or ((sections->>'statisticsWanted')::boolean and coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'));
end $$;

create or replace function futbeat_private.match_detail_completeness(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare payload jsonb; fetched timestamptz; cov futbeat_private.match_detail_coverage; sections jsonb;
  active boolean; needs boolean; has_lineup boolean; has_stats boolean; lineup text; stats text; detail text;
begin
  select c.payload,c.fetched_at into payload,fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  sections:=coalesce(futbeat_private.match_detail_sections(p_match_id),'{}');
  needs:=futbeat_private.match_detail_needs_fetch(p_match_id);
  -- A fetch will actually happen: in flight, or needed and requested.
  active:=futbeat_private.detail_inflight(p_match_id)
    or (needs and exists(select 1 from futbeat_private.match_detail_requests r where r.match_id=p_match_id and r.expires_at>now()));
  has_lineup:=payload is not null and exists(select 1 from futbeat_private.lineup_rows(payload));
  has_stats:=payload is not null and futbeat_private.detail_statistics_count(payload->'statistics')>0;
  lineup:=case when has_lineup then 'available' when cov.lineup_state='NO_DATA' then 'unavailable'
    when active and coalesce((sections->>'lineupWanted')::boolean,false) then 'pending' else 'missing' end;
  stats:=case when has_stats then 'available' when cov.statistics_state='NO_DATA' then 'unavailable'
    when active and coalesce((sections->>'statisticsWanted')::boolean,false) then 'pending' else 'missing' end;
  detail:=case when payload is not null then 'available' when active then 'pending' else 'missing' end;
  return jsonb_build_object(
    'detail',detail,'lineup',lineup,'statistics',stats,
    'stale',payload is not null and futbeat_private.match_detail_due(futbeat_private.match_detail_status(p_match_id),fetched),
    'pending','pending' in (detail,lineup,stats),
    -- Displayable is not complete: registering demand would help (fetchable,
    -- needed, nothing queued or in flight). Server-side single source.
    'hydrationNeeded',needs and not active and futbeat_private.match_detail_fetchable(p_match_id),
    'retryAt',case when cov.next_retry_at>now() then cov.next_retry_at end);
end $$;

create or replace function futbeat_private.read_match_detail(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb:=futbeat_private.read_match_detail_base(p_match_id); coverage jsonb;
begin
  if base is null then return null; end if;
  coverage:=futbeat_private.match_detail_completeness(p_match_id);
  return base||jsonb_build_object('coverage',coverage,'pending',(coverage->>'pending')::boolean,
    'hydrationNeeded',(coverage->>'hydrationNeeded')::boolean);
end $$;

create or replace function futbeat_private.request_match_detail(
  p_match_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_start timestamptz;
  v_fetched timestamptz;
  v_existing futbeat_private.match_detail_requests;
  v_open text;
begin
  select nullif(payload->>'startTime','')::timestamptz
  into v_start
  from futbeat_private.entities
  where id=p_match_id and kind='match';

  if p_match_id is null or v_start is null then
    raise exception 'Unknown canonical match';
  end if;

  -- Anonymous requests only enqueue trusted canonical matches. Historical
  -- hydration is intentionally bounded to the provider horizon.
  if futbeat_private.match_detail_fetchable(p_match_id) then
    -- Serialize opens of the same match so dedupe accounting is exact.
    perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-request'),hashtext(p_match_id));
    select fetched_at into v_fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
    if not futbeat_private.match_detail_needs_fetch(p_match_id) then
      v_open:=case when v_fetched is not null then 'warm' else 'backoff' end;
      perform futbeat_private.bump_metric('match_detail_cache_hits');
    else
      v_open:=case when v_fetched is not null then 'refresh'
        when exists(select 1 from futbeat_private.provider_observations po
          where po.provider='goal_api' and po.canonical_match_id=p_match_id) then 'partial'
        else 'cold' end;
      select * into v_existing from futbeat_private.match_detail_requests
      where match_id=p_match_id and expires_at>now();
      insert into futbeat_private.match_detail_requests(
        match_id,requested_at,expires_at,request_count,source,user_requested_at
      )
      values(p_match_id,now(),now()+interval '15 minutes',1,'user',now())
      on conflict(match_id) do update
        set requested_at=now(),
            expires_at=now()+interval '15 minutes',
            request_count=futbeat_private.match_detail_requests.request_count+1,
            source='user',
            user_requested_at=now();
      if futbeat_private.detail_inflight(p_match_id) then
        perform futbeat_private.bump_metric('deduped_requests');
      else
        if v_existing.match_id is not null and v_existing.source='user'
           and v_existing.user_requested_at>now()-interval '1 minute' then
          perform futbeat_private.bump_metric('deduped_requests');
        else
          perform futbeat_private.bump_metric('match_detail_user_demands');
        end if;
        -- Due and not in flight: wake (debounced).
        perform futbeat_private.wake_provider_worker('demand');
      end if;
    end if;
  else
    v_open:='out_of_horizon';
  end if;
  -- Warm/cold/partial opens, only for finished (historical) matches.
  if v_start<now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer) then
    perform futbeat_private.bump_metric('md_history_open_'||v_open);
  end if;

  return futbeat_private.read_match_detail(p_match_id);
end
$$;

-- Reservation (copied from 20260924200000, unchanged except the results class
-- of user opens, see above).
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
        when status='FINISHED_PENDING_VERIFICATION' and bucket='results' then 2
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
        -- #101: GOAL finals stay FPV forever; only the results window is the
        -- protected results class. A historical open stays user demand.
        when status='FINISHED_PENDING_VERIFICATION' and bucket='results' then 'results'
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

-- Service-only diagnostic for historical Match Center (read-only).
create or replace function public.futbeat_historical_match_center_metrics()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare day_start timestamptz:=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'; result jsonb;
begin
  with m as (
    select e.id,nullif(e.payload->>'startTime','')::timestamptz start_time,
      jsonb_typeof(e.payload->'score')='object' has_score,
      coalesce(jsonb_array_length(case when jsonb_typeof(e.payload->'events')='array' then e.payload->'events' end),0)>0 has_events
    from futbeat_private.entities e
    where e.kind='match' and nullif(e.payload->>'startTime','')::timestamptz<now()-interval '1 day'
  ), b as (
    select m.*,case
        when start_time>=now()-interval '3 days' then '1-3d'
        when start_time>=now()-interval '7 days' then '3-7d'
        when start_time>=now()-interval '30 days' then '7-30d'
        when start_time>=now()-interval '90 days' then '30-90d'
        else '>90d' end bucket,
      c.match_id is not null has_detail,
      coalesce(cov.lineup_state,'UNKNOWN')<>'UNKNOWN' and coalesce(cov.statistics_state,'UNKNOWN')<>'UNKNOWN' settled,
      exists(select 1 from futbeat_private.provider_observations po
        where po.provider='goal_api' and po.canonical_match_id=m.id) has_observation
    from m
    left join futbeat_private.match_detail_cache c on c.match_id=m.id
    left join futbeat_private.match_detail_coverage cov on cov.match_id=m.id
  ), durations as (
    select case when nullif(e.payload->>'startTime','')::timestamptz
        <now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer)
        then 'history' else 'recent' end age,
      extract(epoch from l.completed_at-l.reserved_at) seconds
    from futbeat_private.provider_call_ledger l
    left join futbeat_private.entities e on e.id=l.metadata->>'matchId'
    where l.provider='goal_api' and l.call_kind='match-detail' and l.status='SUCCEEDED'
      and l.reserved_at>=day_start and l.completed_at is not null
  ), opens as (
    select replace(metric,'md_history_open_','') kind,sum(value)::bigint n
    from futbeat_private.demand_metrics
    where day=(now() at time zone 'UTC')::date and metric like 'md\_history\_open\_%'
    group by metric
  )
  select jsonb_build_object(
    'coverageByAge',(select coalesce(jsonb_object_agg(bucket,x),'{}') from (
      select bucket,jsonb_build_object('matches',count(*),'withScore',count(*) filter(where has_score),
        'withEvents',count(*) filter(where has_events),'withObservation',count(*) filter(where has_observation),
        'withDetail',count(*) filter(where has_detail),'settled',count(*) filter(where has_detail and settled)) x
      from b group by bucket) y),
    'historyOpensToday',(select coalesce(jsonb_object_agg(kind,n),'{}') from opens),
    'hydrationSecondsToday',(select coalesce(jsonb_object_agg(age,x),'{}') from (
      select age,jsonb_build_object('calls',count(*),'avg',round(avg(seconds)::numeric,2),
        'p95',round((percentile_cont(0.95) within group(order by seconds))::numeric,2),
        'max',round(max(seconds)::numeric,2)) x
      from durations group by age) y))
  into result;
  return result;
end $$;

revoke all on function
  futbeat_private.match_detail_fetchable(text),
  futbeat_private.match_detail_needs_fetch(text),
  futbeat_private.match_detail_completeness(text),
  futbeat_private.read_match_detail(text),
  futbeat_private.request_match_detail(text),
  futbeat_private.reserve_match_detail_call(text)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_historical_match_center_metrics() from public,anon,authenticated;
grant execute on function public.futbeat_historical_match_center_metrics() to service_role;

notify pgrst,'reload schema';
