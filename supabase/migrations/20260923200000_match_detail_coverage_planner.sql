-- Lineup/detail coverage planner: generic temporal profile per match.
--
-- Root causes fixed (see docs/calendar-coverage-performance.md):
--   * the background enqueuer admitted ONE match per ~10 minutes, only for
--     followed/editorial matches, never finished ones, rarely healthy LIVE
--     ones; any open request (even a user one) blocked the whole queue, and a
--     candidate in backoff sat at the head of the queue for 10 minutes;
--   * lineups already present in bulk live/results payloads were ignored.
--
-- Temporal profile (all values in provider_quota_policy.freshness):
--   LIVE              highest priority, detail due on the live cadence
--   PRE-MATCH         kickoff within prematchMinutes: lineup retried on the
--                     15-minute gap until it appears (class user_high)
--   OPENED BY USER    unchanged (request_match_detail)
--   RECENT FINISHED   kickoff within recentFinishedHours: complete detail,
--                     lineup, stats, events, then frozen (class coverage)
--   UPCOMING          within upcomingDetailHours and never fetched: one fetch
--                     (no hammering; lineups are not wanted that early)
--   HISTORY           finished up to historyCoverageDays ago with a wanted
--                     section still UNKNOWN: spaced 6 h retries until the
--                     section is AVAILABLE or NO_DATA (class bootstrap)
--   FAR FUTURE        never polled for detail
-- Selection reuses match_detail_needs_fetch (freshness, retry gaps, backoff,
-- NO_DATA), so complete matches cost nothing and nothing loops. Up to
-- detailPlannerBatch matches are queued per run, deduplicated per match.
-- One provider call per match detail; player hydration stays deduplicated.
--
-- Bounded by construction:
--   * a LIVE status is live evidence only within liveMaxHours of kickoff; an
--     older one is treated as unknown (no endless 5-minute polling);
--   * only LIVE and pending-verification matches follow a clock cadence;
--     everything else is fetched only while a wanted section is UNKNOWN, on
--     the section retry gap, and a match past kickoff+liveMaxHours counts
--     misses so empty sections reach NO_DATA;
--   * background work (planner sources) may use at most detailBackgroundShare
--     of the daily match-detail cap; LIVE, results and user opens keep the
--     rest, so background never locks out a user or a live match.

update futbeat_private.provider_quota_policy set
  kind_daily_caps=kind_daily_caps||'{"match-detail":900}',
  freshness=freshness||'{"prematchMinutes":90,"recentFinishedHours":36,"upcomingDetailHours":24,
    "historyCoverageDays":7,"detailPlannerBatch":4,"lineupWantedMinutesBeforeKickoff":90,
    "liveRetryMinutes":5,"nearRetryMinutes":15,"historyRetryHours":6,
    "liveMaxHours":4,"detailBackgroundShare":0.6}',
  updated_at=now()
where provider='goal_api';

alter table futbeat_private.match_detail_requests drop constraint if exists match_detail_requests_source_check;
alter table futbeat_private.match_detail_requests add constraint match_detail_requests_source_check
  check(source in ('user','prefetch','bootstrap','prematch','recent'));

-- The expired-row reset only applies to upserts that did not choose a source.
create or replace function futbeat_private.reset_expired_detail_request_source()
returns trigger language plpgsql set search_path='' as $$
begin
  if old.expires_at<=now() and new.user_requested_at is not distinct from old.user_requested_at
     and new.source is not distinct from old.source then
    new.source:='prefetch';
    new.user_requested_at:=null;
  end if;
  return new;
end $$;

-- A LIVE status far past kickoff is stale evidence, not a live match.
create or replace function futbeat_private.match_detail_status(p_match_id text)
returns text language sql stable set search_path='' as $$
  with s as (
    select coalesce(
      (select l.status from public.live_match_updates l where l.match_id=p_match_id and l.provider='goal_api'),
      (select e.payload->>'status' from futbeat_private.entities e where e.id=p_match_id and e.kind='match')) status,
      (select nullif(e.payload->>'startTime','')::timestamptz from futbeat_private.entities e
        where e.id=p_match_id and e.kind='match') kickoff
  )
  select case when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
      and kickoff<now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','liveMaxHours',4)::integer)
    then null else status end
  from s
$$;

-- Finished for coverage: terminal status, or no live evidence and kickoff
-- more than liveMaxHours ago (was one day), so empty sections settle.
create or replace function futbeat_private.match_is_finished(p_match_id text)
returns boolean language sql stable set search_path='' as $$
  select coalesce(futbeat_private.match_detail_status(p_match_id),'') in ('FINISHED_PENDING_VERIFICATION','VERIFIED','ABANDONED')
    or (coalesce(futbeat_private.match_detail_status(p_match_id),'') not in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
      and exists(select 1 from futbeat_private.entities e where e.id=p_match_id and e.kind='match'
        and nullif(e.payload->>'startTime','')::timestamptz
          <now()-make_interval(hours=>futbeat_private.quota_setting('goal_api','liveMaxHours',4)::integer)))
$$;

-- Clock cadence only for live evidence and pending verification; every other
-- match is fetched only while a wanted section is UNKNOWN (retry gap).
create or replace function futbeat_private.match_detail_needs_fetch(p_match_id text)
returns boolean language plpgsql stable set search_path='' as $$
declare status text:=futbeat_private.match_detail_status(p_match_id); fetched timestamptz;
  cov futbeat_private.match_detail_coverage; sections jsonb;
begin
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if cov.next_retry_at>now() then return false; end if;
  select fetched_at into fetched from futbeat_private.match_detail_cache where match_id=p_match_id;
  if fetched is null then return true; end if;
  if status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES','FINISHED_PENDING_VERIFICATION')
     and futbeat_private.match_detail_due(status,fetched) then
    return true;
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  return fetched<now()-make_interval(secs=>(sections->>'retryGap')::double precision)
    and (((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN')
      or ((sections->>'statisticsWanted')::boolean and coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'));
end $$;

-- Background share of the daily match-detail cap (planner sources only).
create or replace function futbeat_private.detail_background_open()
returns boolean language sql stable set search_path='' as $$
  select coalesce((d->>'usedToday')::numeric<floor((d->>'safetyCap')::numeric
    *futbeat_private.quota_setting('goal_api','detailBackgroundShare',0.6)),true)
  from (select futbeat_private.quota_decision('goal_api','match-detail','live') d) x
$$;

-- Section windows now come from the central policy.
create or replace function futbeat_private.match_detail_sections(p_match_id text)
returns jsonb language sql stable set search_path='' as $$
  with m as (
    select nullif(e.payload->>'startTime','')::timestamptz start_time,
      futbeat_private.match_detail_status(e.id) status
    from futbeat_private.entities e where e.id=p_match_id and e.kind='match'
  )
  select jsonb_build_object(
    'lineupWanted',coalesce(m.status,'') not in ('CANCELLED','POSTPONED')
      and now()>=m.start_time-make_interval(mins=>futbeat_private.quota_setting('goal_api','lineupWantedMinutesBeforeKickoff',90)::integer),
    'statisticsWanted',coalesce(m.status,'') not in ('CANCELLED','POSTPONED')
      and now()>=m.start_time,
    'retryGap',extract(epoch from case
      when m.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        then make_interval(mins=>futbeat_private.quota_setting('goal_api','liveRetryMinutes',5)::integer)
      when m.start_time>now()-interval '6 hours'
        then make_interval(mins=>futbeat_private.quota_setting('goal_api','nearRetryMinutes',15)::integer)
      else make_interval(hours=>futbeat_private.quota_setting('goal_api','historyRetryHours',6)::integer) end))
  from m
$$;

-- Generic planner: queues up to p_limit matches by temporal profile.
create or replace function futbeat_private.plan_match_detail_coverage(p_limit integer default null)
returns text[] language plpgsql security definer set search_path='' as $$
declare lim integer:=greatest(1,least(coalesce(p_limit,
    futbeat_private.quota_setting('goal_api','detailPlannerBatch',4)::integer),20));
  prematch interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer);
  recent interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer);
  upcoming interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer);
  history interval:=make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer);
  queued text[]:='{}'; cand record;
  -- Background share exhausted: only LIVE (class live) is still planned.
  bg_open boolean:=futbeat_private.detail_background_open();
begin
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-enqueue'));
  -- Expired rows are replaced, never upserted (keeps each source's class).
  delete from futbeat_private.match_detail_requests where expires_at<=now();
  for cand in
    with window_matches as (
      select cm.match_id,cm.start_time,futbeat_private.match_detail_status(cm.match_id) status
      from futbeat_private.calendar_matches cm
      where cm.start_time between now()-history and now()+upcoming
    ), profiled as (
      select w.*,
        case
          when w.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 1
          when coalesce(w.status,'') not in ('FINISHED_PENDING_VERIFICATION','VERIFIED','ABANDONED','CANCELLED','POSTPONED')
            and w.start_time between now()-interval '3 hours' and now()+prematch then 2
          when w.start_time>now()-recent and w.start_time<=now() then 4
          when w.start_time>now()+prematch then 5
          else 7
        end bucket
      from window_matches w
      where coalesce(w.status,'') not in ('CANCELLED','POSTPONED')
    )
    select p.match_id,p.bucket,p.start_time
    from profiled p
    join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=p.match_id
    left join futbeat_private.match_detail_coverage c on c.match_id=p.match_id
    left join futbeat_private.match_detail_cache d on d.match_id=p.match_id
    where coalesce(c.next_retry_at,'-infinity')<=now()
      and (bg_open or p.bucket=1)
      -- Upcoming beyond the pre-match window: only a first fetch.
      and (p.bucket<>5 or d.match_id is null)
      -- Settled finished matches (both sections AVAILABLE/NO_DATA) are frozen.
      and not (p.bucket in (4,7) and coalesce(c.lineup_state,'UNKNOWN') in ('AVAILABLE','NO_DATA')
        and coalesce(c.statistics_state,'UNKNOWN') in ('AVAILABLE','NO_DATA'))
      and not exists(select 1 from futbeat_private.match_detail_requests r
        where r.match_id=p.match_id and r.expires_at>now())
    order by p.bucket,abs(extract(epoch from p.start_time-now())),p.match_id
    -- Rows are checked lazily in order; bounded per run.
    limit lim*50
  loop
    exit when cardinality(queued)>=lim;
    if not futbeat_private.match_detail_needs_fetch(cand.match_id) or futbeat_private.detail_inflight(cand.match_id) then
      continue;
    end if;
    insert into futbeat_private.match_detail_requests(match_id,requested_at,expires_at,request_count,source)
    values(cand.match_id,now(),now()+interval '10 minutes',1,
      case cand.bucket when 1 then 'prefetch' when 2 then 'prematch' when 4 then 'recent'
        when 5 then 'prefetch' else 'bootstrap' end)
    on conflict(match_id) do update set requested_at=excluded.requested_at,expires_at=excluded.expires_at,
      request_count=futbeat_private.match_detail_requests.request_count+1,
      source=case when futbeat_private.match_detail_requests.source='user'
        and futbeat_private.match_detail_requests.expires_at>now() then 'user' else excluded.source end;
    queued:=array_append(queued,cand.match_id);
  end loop;
  if cardinality(queued)>0 then perform futbeat_private.bump_metric('detail_planner_queued',cardinality(queued)); end if;
  return queued;
end $$;

-- The worker entry point keeps its name/return type; it now runs the planner
-- (never blocked by another open request, never stuck on a backoff head).
create or replace function futbeat_private.enqueue_stale_interested_match_detail()
returns text language sql security definer set search_path='' as $$
  select (futbeat_private.plan_match_detail_coverage(null))[1]
$$;

-- Bulk live/results payloads that already carry a lineup are promoted to the
-- stored detail (0 extra provider calls). Never fails the live ingest.
create or replace function futbeat_private.promote_bulk_lineup()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  -- Only a first lineup for a match still in play or upcoming: never over a
  -- stored detail (its freshness is not advanced) and never for a finished
  -- match (a bulk payload is not a statistics answer).
  if new.canonical_match_id is null or jsonb_typeof(new.raw_payload)<>'object'
     or not exists(select 1 from futbeat_private.lineup_rows(new.raw_payload))
     or exists(select 1 from futbeat_private.match_detail_cache d where d.match_id=new.canonical_match_id)
     or futbeat_private.match_is_finished(new.canonical_match_id) then
    return new;
  end if;
  begin
    perform futbeat_private.store_match_detail(new.canonical_match_id,new.external_match_id,
      new.received_at,new.raw_payload);
    perform futbeat_private.bump_metric('lineups_from_bulk');
  exception when others then
    perform futbeat_private.bump_metric('lineups_from_bulk_rejected');
  end;
  return new;
end $$;
drop trigger if exists promote_bulk_lineup on futbeat_private.provider_observations;
create trigger promote_bulk_lineup after insert on futbeat_private.provider_observations
for each row when (new.provider='goal_api') execute function futbeat_private.promote_bulk_lineup();

-- Read-only lineup coverage metrics (service role).
create or replace function public.futbeat_lineup_coverage_metrics()
returns jsonb language sql stable security definer set search_path='' as $$
  with m as (
    select cm.match_id,cm.start_time,futbeat_private.match_detail_status(cm.match_id) status,
      exists(select 1 from futbeat_private.provider_entities pe where pe.provider='goal_api' and pe.kind='match'
        and pe.canonical_id=cm.match_id) mapped,
      d.match_id is not null has_detail,
      d.match_id is not null and exists(select 1 from futbeat_private.lineup_rows(d.payload)) has_lineup,
      c.lineup_state,c.statistics_state,c.next_retry_at
    from futbeat_private.calendar_matches cm
    left join futbeat_private.match_detail_cache d on d.match_id=cm.match_id
    left join futbeat_private.match_detail_coverage c on c.match_id=cm.match_id
    where cm.start_time between now()-interval '7 days' and now()+interval '7 days'
  )
  select jsonb_build_object(
    'matches',count(*),'mapped',count(*) filter(where mapped),
    'withDetail',count(*) filter(where has_detail),'withLineup',count(*) filter(where has_lineup),
    'detailWithEmptyLineup',count(*) filter(where has_detail and not has_lineup),
    'liveWithoutLineup',count(*) filter(where mapped and not has_lineup
      and status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')),
    'upcoming24hWithoutLineup',count(*) filter(where mapped and not has_lineup
      and start_time between now() and now()+interval '24 hours'),
    'finished24hWithoutLineup',count(*) filter(where mapped and not has_lineup
      and start_time between now()-interval '24 hours' and now() and coalesce(lineup_state,'')<>'NO_DATA'
      and status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')),
    'finished7dWithoutLineup',count(*) filter(where mapped and not has_lineup
      and start_time<now() and coalesce(lineup_state,'')<>'NO_DATA'
      and status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')),
    'lineupNoData',count(*) filter(where lineup_state='NO_DATA'),
    'statisticsNoData',count(*) filter(where statistics_state='NO_DATA'),
    'inBackoff',count(*) filter(where next_retry_at>now()),
    'openRequests',(select count(*) from futbeat_private.match_detail_requests where expires_at>now()),
    'detailCallsToday',(select count(*) from futbeat_private.provider_call_ledger where call_kind='match-detail'
      and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'))
  from m
$$;

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
  v_source text;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');

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
      nullif(e.payload->>'startTime','')::timestamptz start_time
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
    where futbeat_private.match_detail_needs_fetch(match_id)
  )
  -- Best allowed candidate first; if none fits its class, the best due one
  -- explains the refusal.
  select match_id,external_id,status,quota_class,rank_value,
    futbeat_private.quota_class_allowed('goal_api',quota_class,v_remaining),source
  into v_match_id,v_external,v_status,v_class,v_rank,v_allowed,v_source
  from ranked
  order by 6 desc,rank_value,requested_at desc,match_id
  limit 1;

  if v_match_id is null or not v_allowed then
    return jsonb_build_object(
      'allowed',false,
      'reason',case when v_match_id is null then 'no_detail_due' else 'provider_remaining_reserve' end,
      'quotaClass',v_class,
      'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining
    );
  end if;

  -- Planner work stops at its share of the daily cap; LIVE, results and
  -- user opens keep the remainder.
  if v_class not in ('live','results') and v_source<>'user'
     and not futbeat_private.detail_background_open() then
    return jsonb_build_object('allowed',false,'reason','background_share','quotaClass',v_class,
      'matchId',v_match_id,'detailUsed',(v_cap->>'usedToday')::integer,'providerRemaining',v_remaining);
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
      'status',v_status,'quotaClass',v_class,'priority',v_rank)
  )
  returning id into v_reservation;

  return jsonb_build_object(
    'allowed',true,
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

revoke all on function
  futbeat_private.plan_match_detail_coverage(integer),
  futbeat_private.promote_bulk_lineup(),
  futbeat_private.reset_expired_detail_request_source(),
  futbeat_private.match_detail_sections(text),
  futbeat_private.match_detail_status(text),
  futbeat_private.match_is_finished(text),
  futbeat_private.match_detail_needs_fetch(text),
  futbeat_private.detail_background_open(),
  futbeat_private.enqueue_stale_interested_match_detail()
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_lineup_coverage_metrics() from public,anon,authenticated;
grant execute on function public.futbeat_lineup_coverage_metrics() to service_role;

notify pgrst,'reload schema';
