-- Load relief: two per-call costs paid every minute (no behaviour change).
--
-- Evidence (read-only production, 2026-10-05, pg_stat_statements since the
-- 14:07 UTC restart + EXPLAIN ANALYZE of the same SELECTs):
--   1. `exists(select 1 from pg_catalog.pg_timezone_names where name=tz)`
--      costs ~494 ms per evaluation (the view enumerates the whole tz
--      database). It ran twice per calendar planner call (plan + seed, the
--      planner averaged ~1.1 s) and once or twice per USER calendar read
--      (public.futbeat_read_calendar_range -> ..._before_field_merge), plus
--      calendar date requests.
--   2. The detail planner (futbeat_enqueue_stale_live_detail ->
--      plan_match_detail_coverage, ~1.2-2.3 s per run, about once a minute)
--      spent ~1.15 s of a 2.0 s candidate query in match_detail_bucket():
--      not inlinable (SET search_path), evaluated for ~2,700 window rows,
--      each doing up to 7 quota_setting() lookups of the policy row.
-- Before the restart the instance degraded after ~15 h of this baseline
-- (PGRST002, cron "job startup timeout").
--
-- Fix:
--   1. futbeat_private.timezone_names: the server's tz names, copied once
--      from pg_timezone_names; is_timezone_name() is an index probe and falls
--      back to the exact (slow) view only for a name it does not know, so
--      the accepted set is exactly the same as before. The five functions
--      are re-created from their production definitions with only that
--      expression replaced.
--   2. match_detail_bucket_at(): the same bucket rules as a pure, inlinable
--      SQL function taking the windows as arguments. The planner reads the
--      windows once per run; match_detail_bucket() keeps its signature and
--      result (it now delegates to match_detail_bucket_at).
-- Expected: calendar planner ~1.1 s -> ~0.1 s per call; user calendar reads
-- -0.5 to -1 s; detail planner candidate query ~2.0 s -> ~0.9 s.
-- Rollback: re-create the six functions from their previous migrations
-- (20260920021500, 20260924100000, 20260921065000, 20260927152657,
-- 20260924200000); drop is_timezone_name, match_detail_bucket_at and the
-- timezone_names table. No data is changed.

create table if not exists futbeat_private.timezone_names(name text primary key);
alter table futbeat_private.timezone_names enable row level security;
revoke all on futbeat_private.timezone_names from public,anon,authenticated;
insert into futbeat_private.timezone_names(name)
select name from pg_catalog.pg_timezone_names
on conflict do nothing;

create or replace function futbeat_private.is_timezone_name(p_name text)
returns boolean language plpgsql stable set search_path='' as $$
begin
  if p_name is null or p_name='' then return false; end if;
  if exists(select 1 from futbeat_private.timezone_names where name=p_name) then
    return true;
  end if;
  -- Unknown here (a tz database newer than the copy, or not a zone): the
  -- exact original check decides.
  return exists(select 1 from pg_catalog.pg_timezone_names where name=p_name);
end $$;
revoke all on function futbeat_private.is_timezone_name(text) from public,anon,authenticated;

create or replace function futbeat_private.futbeat_request_calendar_date(p_local_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_today date := (now() at time zone p_timezone)::date;
  v_result jsonb;
begin
  if p_local_date is null
     or not futbeat_private.is_timezone_name(p_timezone) then
    raise exception 'Invalid calendar date request';
  end if;

  -- Reads remain unrestricted for already stored history. Provider recovery is
  -- intentionally bounded to a reasonable moving window.
  if p_local_date < v_today-400 or p_local_date > v_today+400 then
    return '[]'::jsonb;
  end if;

  v_start:=p_local_date::timestamp at time zone p_timezone;
  v_end:=(p_local_date+1)::timestamp at time zone p_timezone;

  with provider_dates as (
    select d::date provider_date
    from generate_series(
      (v_start at time zone 'UTC')::date::timestamp,
      (((v_end-interval '1 microsecond') at time zone 'UTC')::date)::timestamp,
      interval '1 day'
    ) d
  ), missing as (
    select d.provider_date
    from provider_dates d
    left join futbeat_private.calendar_coverage c
      on c.provider='goal_api' and c.provider_date=d.provider_date
    where c.provider_date is null
       or case
         when d.provider_date < (now() at time zone 'UTC')::date-1
           then c.fetched_at < ((d.provider_date+2)::timestamp at time zone 'UTC')
         when d.provider_date <= (now() at time zone 'UTC')::date+14
           then c.fetched_at < now()-interval '1 day'
         else c.fetched_at < now()-interval '7 days'
       end
  ), queued as (
    insert into futbeat_private.calendar_date_requests(
      provider,provider_date,first_requested_at,last_requested_at,request_count
    )
    select 'goal_api',provider_date,now(),now(),1 from missing
    on conflict(provider,provider_date) do update
      set last_requested_at=excluded.last_requested_at,
          request_count=futbeat_private.calendar_date_requests.request_count+1
    returning provider_date
  )
  select coalesce(
    jsonb_agg(to_char(provider_date,'YYYY-MM-DD') order by provider_date),
    '[]'::jsonb
  ) into v_result from queued;

  return v_result;
end
$function$;

create or replace function public.futbeat_read_calendar_range(p_from_date date, p_to_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_row futbeat_private.compact_calendar_cache; v_version text; v_count integer;
 retry integer:=futbeat_private.quota_setting('goal_api','calendarPendingRetrySeconds',3)::integer;
begin
 if p_from_date is null or p_to_date is null or p_from_date>p_to_date
   or p_to_date-p_from_date>31 or not futbeat_private.is_timezone_name(p_timezone) then
   raise exception 'Invalid calendar range';
 end if;
 if p_from_date<>p_to_date then
   return futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 end if;
 -- Remember reader timezones: at most hourly, skip-locked (never waits).
 if not exists(select 1 from futbeat_private.calendar_snapshot_zones z
     where z.timezone=p_timezone and z.last_seen_at>now()-interval '1 hour') then
   update futbeat_private.calendar_snapshot_zones z set last_seen_at=now()
   where z.timezone in (select y.timezone from futbeat_private.calendar_snapshot_zones y
     where y.timezone=p_timezone for update skip locked);
   if not found and not exists(select 1 from futbeat_private.calendar_snapshot_zones where timezone=p_timezone) then
     insert into futbeat_private.calendar_snapshot_zones(timezone,last_seen_at) values(p_timezone,now())
     on conflict do nothing;
   end if;
 end if;
 v_version:=futbeat_private.calendar_cache_version(p_from_date,p_timezone);
 select * into v_row from futbeat_private.compact_calendar_cache
   where calendar_date=p_from_date and timezone=p_timezone;
 if found and v_row.version=v_version and v_row.expires_at>now() then
   return v_row.payload;
 end if;
 select count(*) into v_count from futbeat_private.calendar_matches m
   where m.start_time>=p_from_date::timestamp at time zone p_timezone
     and m.start_time<(p_from_date+1)::timestamp at time zone p_timezone;
 -- Small days: inline build is cheap and always fresh.
 if v_count<=futbeat_private.quota_setting('goal_api','calendarSyncBuildMaxMatches',150) then
   return futbeat_private.materialize_calendar_day(p_from_date,p_timezone);
 end if;
 perform futbeat_private.enqueue_calendar_snapshot(p_from_date,p_timezone,1);
 begin
   perform futbeat_private.wake_provider_worker('calendar');
 exception when others then
   null; -- the per-minute worker still drains the queue
 end;
 if v_row.payload is not null then
   -- Stale-while-revalidate: the previous snapshot now, the rebuild in background.
   perform futbeat_private.bump_metric('calendar_stale_served');
   return v_row.payload||jsonb_build_object('freshness',jsonb_build_object('stale',false,'revalidating',true));
 end if;
 perform futbeat_private.bump_metric('calendar_pending_responses');
 return jsonb_build_object('schemaVersion',1,'demo',false,'updatedAt',now(),
   'freshness',jsonb_build_object('stale',false,'revalidating',true),
   'coverage',jsonb_build_object('source','FutBeat','partial',false,'pending',true,
     'retryAfterSeconds',retry,'live',false,'developmentOnly',false,
     'sources',jsonb_build_array('GOAL API'),
     'calendar',jsonb_build_object('from',p_from_date,'to',p_to_date,'timezone',p_timezone,'complete',false)),
   'teams','[]'::jsonb,'competitions','[]'::jsonb,'matches','[]'::jsonb,
   'players','[]'::jsonb,'standings','[]'::jsonb);
end $function$;

create or replace function futbeat_private.seed_calendar_snapshot_queue(p_limit integer DEFAULT NULL::integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare lim integer:=greatest(0,least(coalesce(p_limit,
    futbeat_private.quota_setting('goal_api','calendarSeedBatch',6)::integer),50));
  back integer:=futbeat_private.quota_setting('goal_api','calendarSeedBackDays',90)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarSeedForwardDays',120)::integer;
  tz text; d date; queued integer:=0;
begin
  if lim=0 then return 0; end if;
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    if not futbeat_private.is_timezone_name(tz) then continue; end if;
    -- Nearest dates first; index probes only.
    for d in select (now() at time zone tz)::date+g from generate_series(-back,forward) g order by abs(g),g loop
      exit when queued>=lim;
      continue when exists(select 1 from futbeat_private.compact_calendar_cache c
        where c.calendar_date=d and c.timezone=tz);
      continue when exists(select 1 from futbeat_private.calendar_snapshot_queue q
        where q.calendar_date=d and q.timezone=tz and q.status in ('pending','failed'));
      continue when not exists(select 1 from futbeat_private.calendar_matches m
        where m.start_time>=d::timestamp at time zone tz and m.start_time<(d+1)::timestamp at time zone tz);
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,6,abs(d-(now() at time zone tz)::date));
      queued:=queued+1;
    end loop;
  end loop;
  return queued;
end $function$;

create or replace function public.futbeat_plan_calendar_snapshots()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare back integer:=futbeat_private.quota_setting('goal_api','calendarWarmBackDays',2)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarWarmForwardDays',7)::integer;
  seed_back integer:=futbeat_private.quota_setting('goal_api','calendarSeedBackDays',90)::integer;
  seed_forward integer:=futbeat_private.quota_setting('goal_api','calendarSeedForwardDays',120)::integer;
  tz text; offs integer; rank integer; d date; checked integer:=0; dirty integer:=0; seeded integer;
  c record;
begin
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    if not futbeat_private.is_timezone_name(tz) then continue; end if;
    -- Hot window: today, +1, -1, +2, -2, ...
    for offs,rank in select g,abs(g)*2-case when g>0 then 1 else 0 end from generate_series(-back,forward) g loop
      d:=(now() at time zone tz)::date+offs;
      checked:=checked+1;
      if exists(select 1 from futbeat_private.compact_calendar_cache s where s.calendar_date=d and s.timezone=tz
          and s.version=futbeat_private.calendar_cache_version(d,tz) and s.expires_at>now()+interval '5 seconds') then
        continue;
      end if;
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,
        case when offs=0 then 2 when abs(offs)=1 then 3 else 4 end,rank);
    end loop;
    -- Dirty: the day's own data changed (per-date part of the version). A
    -- catalog-only change is rebuilt lazily by the next read.
    for c in select s.calendar_date,
        split_part(s.version,':',2) is distinct from
          split_part(futbeat_private.calendar_cache_version(s.calendar_date,tz),':',2) changed
      from futbeat_private.compact_calendar_cache s
      where s.timezone=tz and s.calendar_date between (now() at time zone tz)::date-seed_back
        and (now() at time zone tz)::date+seed_forward loop
      continue when not c.changed;
      perform futbeat_private.enqueue_calendar_snapshot(c.calendar_date,tz,5,
        abs(c.calendar_date-(now() at time zone tz)::date));
      dirty:=dirty+1;
    end loop;
  end loop;
  seeded:=futbeat_private.seed_calendar_snapshot_queue(null);
  -- Bounded retention.
  delete from futbeat_private.compact_calendar_cache where built_at<now()-make_interval(
    days=>futbeat_private.quota_setting('goal_api','calendarRetentionDays',120)::integer);
  delete from futbeat_private.calendar_snapshot_queue
  where (status='done' and built_at<now()-interval '1 day')
     or (status='failed' and requested_at<now()-interval '1 day');
  return jsonb_build_object('checked',checked,'dirty',dirty,'seeded',seeded,
    'batch',futbeat_private.quota_setting('goal_api','calendarBuildBatch',4)::integer,
    'budgetMs',futbeat_private.quota_setting('goal_api','calendarBuildBudgetMs',20000)::integer);
end $function$;

create or replace function futbeat_private.futbeat_read_calendar_range_before_field_merge(p_from_date date, p_to_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  start_at timestamptz;
  end_at timestamptz;
  provider_from date;
  provider_to date;
  expected_dates integer;
  covered_dates integer;
  matches_json jsonb;
  teams_json jsonb;
  competitions_json jsonb;
  updated_at timestamptz;
begin
  if p_from_date is null
     or p_to_date is null
     or p_from_date > p_to_date
     or p_to_date - p_from_date > 31
     or not futbeat_private.is_timezone_name(p_timezone)
  then
    raise exception 'Invalid calendar range';
  end if;

  start_at := p_from_date::timestamp at time zone p_timezone;
  end_at := (p_to_date + 1)::timestamp at time zone p_timezone;

  select coalesce(
    jsonb_agg(
      case
        when resolved.status is not null then entity.payload ||
          jsonb_build_object(
            'status',resolved.status,
            'minute',resolved.minute,
            'score',resolved.score,
            'liveProvider',resolved.provider,
            'liveChangedAt',resolved.observed_at
          )
        else entity.payload
      end
      order by calendar.start_time,entity.id
    ),
    '[]'::jsonb
  ),
  max(
    greatest(
      coalesce(
        nullif(entity.payload->'provenance'->>'receivedAt','')::timestamptz,
        calendar.updated_at
      ),
      coalesce(resolved.observed_at,'-infinity'::timestamptz)
    )
  )
  into matches_json,updated_at
  from futbeat_private.calendar_matches calendar
  join futbeat_private.entities entity
    on entity.id=calendar.match_id and entity.kind='match'
  left join lateral (
    select l.*
    from futbeat_private.live_match_state l
    where l.canonical_match_id=entity.id
    order by l.changed_at desc,l.last_seen_at desc
    limit 1
  ) live on true
  left join futbeat_private.match_detail_cache cache on cache.match_id=entity.id
  left join lateral (
    select
      case
        when upper(coalesce(cache.payload->>'matchStatus',''))='POSTPONED'
          then 'POSTPONED'
        when upper(coalesce(cache.payload->>'matchStatus',''))='CANCELLED'
          then 'CANCELLED'
        when upper(coalesce(cache.payload->>'matchStatus',''))='SUSPENDED'
          then 'SUSPENDED'
        when upper(coalesce(cache.payload->>'matchStatus',''))='ABANDONED'
          then 'ABANDONED'
        when upper(coalesce(cache.payload->>'matchStatus',''))='HALF_TIME'
          or upper(coalesce(cache.payload->>'matchPeriod',''))='HALF_TIME'
          then 'HALFTIME'
        when upper(coalesce(cache.payload->>'matchStatus',''))='LIVE'
          and upper(coalesce(cache.payload->>'matchPeriod',''))='EXTRA_TIME'
          then 'EXTRA_TIME'
        when upper(coalesce(cache.payload->>'matchStatus',''))='LIVE'
          and upper(coalesce(cache.payload->>'matchPeriod',''))='PENALTIES'
          then 'PENALTIES'
        when upper(coalesce(cache.payload->>'matchStatus',''))='LIVE'
          then 'LIVE'
        when upper(coalesce(cache.payload->>'matchStatus','')) in (
          'FINISHED','AFTER_ET','AFTER_PEN','AWARDED'
        ) then 'FINISHED_PENDING_VERIFICATION'
        else null
      end as status,
      case
        when coalesce(
          cache.payload->>'matchElapsed',cache.payload->>'matchMinute',''
        ) ~ '^\d+$'
        then coalesce(
          cache.payload->>'matchElapsed',cache.payload->>'matchMinute'
        )::integer
        else null
      end as minute,
      case
        when coalesce(cache.payload->>'homeTeamScore','') ~ '^\d+$'
         and coalesce(cache.payload->>'awayTeamScore','') ~ '^\d+$'
        then jsonb_build_object(
          'home',(cache.payload->>'homeTeamScore')::integer,
          'away',(cache.payload->>'awayTeamScore')::integer
        )
        else null
      end as score
  ) detail on cache.payload is not null
  left join lateral (
    select candidate.status,candidate.minute,candidate.score,
      candidate.provider,candidate.observed_at
    from (
      values
        (
          case
            when entity.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and coalesce(
               nullif(entity.payload->'provenance'->>'receivedAt','')::timestamptz,
               calendar.updated_at
             )<now()-interval '15 minutes'
            then 'SCHEDULED'
            else entity.payload->>'status'
          end,
          case
            when entity.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and coalesce(
               nullif(entity.payload->'provenance'->>'receivedAt','')::timestamptz,
               calendar.updated_at
             )<now()-interval '15 minutes'
            then null
            when coalesce(entity.payload->>'minute','') ~ '^\d+$'
            then (entity.payload->>'minute')::integer else null
          end,
          case
            when entity.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and coalesce(
               nullif(entity.payload->'provenance'->>'receivedAt','')::timestamptz,
               calendar.updated_at
             )<now()-interval '15 minutes'
            then null
            else entity.payload->'score'
          end,
          entity.payload->'provenance'->>'source',
          coalesce(
            nullif(entity.payload->'provenance'->>'receivedAt','')::timestamptz,
            calendar.updated_at
          ),
          case when entity.payload->>'status' in (
            'FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','CANCELLED',
            'SUSPENDED','ABANDONED'
          ) then 500 else 100 end
        ),
        (
          live.status,live.minute,
          case when live.home_score is not null and live.away_score is not null
            then jsonb_build_object('home',live.home_score,'away',live.away_score)
            else null end,
          live.provider,live.changed_at,
          case
            when live.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','CANCELLED','SUSPENDED','ABANDONED') then 400
            when live.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
              and live.last_seen_at>=now()-interval '15 minutes' then 300
            else 0
          end
        ),
        (
          detail.status,detail.minute,detail.score,'goal_api',cache.fetched_at,
          case
            when detail.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','CANCELLED','SUSPENDED','ABANDONED') then 450
            when cache.fetched_at>=now()-interval '15 minutes' then 200
            else 0
          end
        )
    ) as candidate(status,minute,score,provider,observed_at,priority)
    where candidate.status is not null and candidate.priority>0
    order by
      case
        when candidate.priority>=400 then candidate.priority
        else 0
      end desc,
      case
        when candidate.priority>=400 then candidate.observed_at
        else null
      end desc nulls last,
      candidate.priority desc,
      candidate.observed_at desc
    limit 1
  ) resolved on true
  where calendar.start_time >= start_at
    and calendar.start_time < end_at;

  select coalesce(
    jsonb_agg(entity.payload order by entity.payload->>'name',entity.id),
    '[]'::jsonb
  )
  into teams_json
  from futbeat_private.entities entity
  where entity.kind='team'
    and entity.id in (
      select value->>'homeTeamId'
      from jsonb_array_elements(matches_json)
      union
      select value->>'awayTeamId'
      from jsonb_array_elements(matches_json)
    );

  select coalesce(
    jsonb_agg(
      entity.payload
      order by entity.payload->>'country',entity.payload->>'name',entity.id
    ),
    '[]'::jsonb
  )
  into competitions_json
  from futbeat_private.entities entity
  where entity.kind='competition'
    and entity.id in (
      select value->>'competitionId'
      from jsonb_array_elements(matches_json)
      union
      select value->>'competitionId'
      from jsonb_array_elements(teams_json)
      where nullif(value->>'competitionId','') is not null
    );

  provider_from := (start_at at time zone 'UTC')::date;
  provider_to := ((end_at - interval '1 microsecond') at time zone 'UTC')::date;
  expected_dates := provider_to - provider_from + 1;

  select count(*)::integer
  into covered_dates
  from futbeat_private.calendar_coverage
  where provider='goal_api'
    and provider_date between provider_from and provider_to;

  return jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',coalesce(updated_at,now()),
    'freshness',jsonb_build_object('stale',false),
    'coverage',jsonb_build_object(
      'source','FutBeat',
      'partial',covered_dates < expected_dates,
      'live',false,
      'developmentOnly',false,
      'sources',jsonb_build_array('GOAL API'),
      'calendar',jsonb_build_object(
        'from',p_from_date,
        'to',p_to_date,
        'timezone',p_timezone,
        'complete',covered_dates >= expected_dates
      )
    ),
    'competitions',competitions_json,
    'teams',teams_json,
    'players','[]'::jsonb,
    'matches',matches_json,
    'standings','[]'::jsonb
  );
end;
$function$;

create or replace function futbeat_private.plan_match_detail_coverage(p_limit integer DEFAULT NULL::integer)
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
        case
          when coalesce(l.status,x.payload->>'status') in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
            and nullif(x.payload->>'startTime','')::timestamptz<now()-live_max then null
          else coalesce(l.status,x.payload->>'status')
        end status
      from futbeat_private.calendar_matches cm
      join futbeat_private.entities x on x.id=cm.match_id and x.kind='match'
      left join public.live_match_updates l on l.match_id=cm.match_id and l.provider='goal_api'
      where cm.start_time between now()-history and now()+upcoming
    ), profiled as materialized (
      select w.match_id,w.start_time,w.competition_id,
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
    where p.bucket in ('live','results','prematch','upcoming','recent_hot','recent','history')
      and coalesce(c.next_retry_at,'-infinity')<=now()
      and (p.bucket<>'upcoming' or d.match_id is null)
      and not (p.bucket in ('recent_hot','recent','history')
        and d.fetched_at>=p.start_time+final_after
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

-- Same rules as match_detail_bucket, windows as arguments. Pure SQL with no
-- SET clause and no table access, so the planner inlines it per row.
create or replace function futbeat_private.match_detail_bucket_at(
  p_status text,p_start timestamptz,p_now timestamptz,
  p_results interval,p_prematch interval,p_upcoming interval,
  p_recent_hot interval,p_recent interval,p_history interval
) returns text language sql stable as $$
  select case
    when p_start is null or coalesce(p_status,'') in ('CANCELLED','POSTPONED') then 'none'
    when p_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 'live'
    when p_status='FINISHED_PENDING_VERIFICATION' and p_start>p_now-p_results then 'results'
    when p_start>p_now+p_prematch then
      case when p_start<=p_now+p_upcoming then 'upcoming' else 'future' end
    when p_start>p_now then 'prematch'
    when p_start>p_now-p_recent_hot then 'recent_hot'
    when p_start>p_now-p_recent then 'recent'
    when p_start>p_now-p_history then 'history'
    else 'old' end
$$;

create or replace function futbeat_private.match_detail_bucket(p_status text,p_start timestamptz)
returns text language sql stable set search_path='' as $$
  select futbeat_private.match_detail_bucket_at(p_status,p_start,now(),
    make_interval(hours=>futbeat_private.quota_setting('goal_api','resultsWindowHours',4)::integer),
    make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchMinutes',90)::integer),
    make_interval(hours=>futbeat_private.quota_setting('goal_api','upcomingDetailHours',24)::integer),
    make_interval(hours=>futbeat_private.quota_setting('goal_api','recentHotHours',6)::integer),
    make_interval(hours=>futbeat_private.quota_setting('goal_api','recentFinishedHours',36)::integer),
    make_interval(days=>futbeat_private.quota_setting('goal_api','historyCoverageDays',7)::integer))
$$;

revoke all on function futbeat_private.match_detail_bucket_at(text,timestamptz,timestamptz,interval,interval,interval,interval,interval,interval)
  from public,anon,authenticated;
