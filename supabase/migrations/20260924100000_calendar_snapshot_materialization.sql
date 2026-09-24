-- Calendar snapshots materialized off the request path.
--
-- Measured root cause (backend/bench/calendar_cold_build.mjs, 1 000 matches):
-- the cold build ran futbeat_private.match_read_model for every match, which
-- aggregates and normalizes the FULL events array (payload events + every
-- canonical event, normalize_event_minutes per event) although the Partidos
-- list only needs latestEvent for live matches and "has any event". The cost
-- grows with events per match (10 -> 40 events: 0.87 s -> 1.54 s locally),
-- and team/competition redirects were resolved twice (read model + builder,
-- ~15% of the build). Snapshot lookups stay ~0.2 ms; cold builds dominate.
--
-- Fixes:
--   * match_read_model_core(p_match,p_events): one source of truth for
--     status/score/evidence. The list build skips the events aggregation
--     except for live matches (latestEvent) and answers "has any event" with
--     an EXISTS; Match Center keeps the full model (match_read_model).
--   * build_compact_calendar resolves redirects once (in the model).
--   * calendar_snapshot_queue: deduplicated (date,timezone) builds with a
--     priority (1 visible request, 2 today, 3 yesterday/tomorrow, 4 hot
--     window, 5 dirty after ingest, 6 background seeding), lease, attempts
--     and retry backoff. DB-only: never a provider call.
--   * Ingest marks only the affected local dates dirty (bump_calendar_date).
--   * The worker lane (futbeat_warm_calendar_window, unchanged name) enqueues
--     the hot window, seeds every known date (-calendarSeedBackDays ..
--     +calendarSeedForwardDays) without a snapshot, and drains the queue
--     within a batch/time budget.
--   * The read path never blocks on a heavy build: stale snapshot ->
--     served at once + priority-1 rebuild; no snapshot and a large day
--     (> calendarSyncBuildMaxMatches) -> a "pending" snapshot + priority-1
--     build + worker wake; small days are still built inline (fast).
--   * Complete history is kept for calendarHistoryCompleteDays (versioned:
--     any new evidence bumps the day and rebuilds it); future days keep
--     calendarFutureHours and are rebuilt when their fixtures change.

update futbeat_private.provider_quota_policy set
  freshness=freshness||'{"calendarSyncBuildMaxMatches":150,"calendarHistoryCompleteDays":30,
    "calendarFutureHours":24,"calendarRetentionDays":120,"calendarBuildBatch":4,
    "calendarBuildBudgetMs":20000,"calendarSeedBackDays":90,"calendarSeedForwardDays":120,
    "calendarSeedBatch":6,"calendarPendingRetrySeconds":3}',
  updated_at=now()
where provider='goal_api';

-- ---------------------------------------------------------------------------
-- Lean list projection with a single source of truth.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.match_read_model_core(p_match jsonb,p_events boolean)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 v_score jsonb; v_status text:=p_match->>'status'; v_events jsonb; v_has_events boolean;
 v_start timestamptz:=(p_match->>'startTime')::timestamptz;
 v_received timestamptz:=coalesce(nullif(p_match#>>'{provenance,receivedAt}','')::timestamptz,'-infinity');
 v_evidence record;
 v_relax_terminal boolean;
begin
 if futbeat_private.safe_result_integer(p_match#>>'{score,home}') is null
   or futbeat_private.safe_result_integer(p_match#>>'{score,away}') is null then
   p_match:=p_match-'score';
 end if;
 -- Expire stale LIVE presentation, but retain its real score independently.
 if v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
   and v_received<now()-interval '15 minutes' then v_status:='SCHEDULED'; end if;
 v_relax_terminal:=v_status in ('DISCOVERED','SCHEDULED','PRE_MATCH');
 -- Terminal canonical scores are authoritative. Otherwise choose the newest
 -- complete score field, not the newest status-only observation.
 if v_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION') then
   v_score:=nullif(p_match->'score','null'::jsonb);
 end if;
 if v_score is null then
   select score into v_score from (
     select nullif(p_match->'score','null'::jsonb) score,v_received seen,0 priority
     union all
     select jsonb_build_object('home',o.home_score,'away',o.away_score),o.received_at,1
       from (select * from futbeat_private.provider_observations
         where canonical_match_id=p_match->>'id' and home_score is not null and away_score is not null
           and received_at>=v_start
           and status not in ('POSTPONED','CANCELLED')
         order by received_at desc,id desc limit 1) o
     union all
     select jsonb_build_object('home',l.home_score,'away',l.away_score),l.last_seen_at,2
       from futbeat_private.live_match_state l where l.canonical_match_id=p_match->>'id'
         and l.home_score is not null and l.away_score is not null and l.last_seen_at>=v_start
         and l.status not in ('POSTPONED','CANCELLED')
     union all
     select jsonb_build_object('home',(c.payload->>'homeTeamScore')::integer,
       'away',(c.payload->>'awayTeamScore')::integer),c.fetched_at,3
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
       and c.fetched_at>=v_start and now()>=v_start
       and coalesce(c.payload->>'homeTeamScore','')~'^\d+$'
       and coalesce(c.payload->>'awayTeamScore','')~'^\d+$'
   ) candidates where score is not null order by seen desc,priority limit 1;
 end if;
 -- Never infer FINISHED from the clock, goals or the presence of a score.
 if v_status not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED','POSTPONED') then
   select status,received_at,minute into v_evidence from (
     select status,received_at,minute,id from futbeat_private.provider_observations
       where canonical_match_id=p_match->>'id'
     union all
     select status,last_seen_at,minute,0 from futbeat_private.live_match_state
       where canonical_match_id=p_match->>'id'
     union all
     select case upper(c.payload->>'matchStatus')
       when 'FINISHED' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_ET' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_PEN' then 'FINISHED_PENDING_VERIFICATION'
       when 'AWARDED' then 'FINISHED_PENDING_VERIFICATION'
       when 'HALF_TIME' then 'HALFTIME'
       when 'LIVE' then case upper(c.payload->>'matchPeriod')
         when 'EXTRA_TIME' then 'EXTRA_TIME' when 'PENALTIES' then 'PENALTIES'
         when 'HALF_TIME' then 'HALFTIME' else 'LIVE' end
       else upper(c.payload->>'matchStatus') end,
       c.fetched_at,futbeat_private.safe_result_integer(coalesce(c.payload->>'matchElapsed',c.payload->>'matchMinute')),0
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
     union all
     -- Real final whistle recorded from a provider terminal state.
     select 'FINISHED_PENDING_VERIFICATION',e.first_seen_at,
       futbeat_private.safe_result_integer(e.payload->>'minute'),0
       from futbeat_private.canonical_events e
       where e.match_id=p_match->>'id' and e.event_type='FULL_TIME'
   ) evidence
    where received_at>=v_start
      and (received_at>=v_received
        or (v_relax_terminal and status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')))
      and (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
        or (status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') and received_at>=now()-interval '15 minutes'))
    order by (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')) desc,received_at desc,id desc limit 1;
   if found then
     v_status:=v_evidence.status;
     p_match:=p_match||jsonb_strip_nulls(jsonb_build_object('minute',v_evidence.minute,
       'liveChangedAt',v_evidence.received_at));
   end if;
 end if;
 if p_events or v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then
   select futbeat_private.normalize_event_array(coalesce(jsonb_agg(event order by
     futbeat_private.safe_result_integer(event->>'minute'),event->>'id'),'[]'::jsonb))
   into v_events from (
     select distinct on (coalesce(event->>'id',event::text)) event from (
       select value event from jsonb_array_elements(coalesce(p_match->'events','[]'::jsonb))
       union all select payload||jsonb_build_object('id',id,'type',event_type)
         from futbeat_private.canonical_events where match_id=p_match->>'id'
     ) all_events order by coalesce(event->>'id',event::text)
   ) unique_events;
   v_has_events:=jsonb_array_length(v_events)>0;
 else
   -- Same answer as a non-empty merged array, without building it.
   v_has_events:=coalesce(jsonb_array_length(case when jsonb_typeof(p_match->'events')='array'
       then p_match->'events' end),0)>0
     or exists(select 1 from futbeat_private.canonical_events where match_id=p_match->>'id');
   p_match:=p_match-'events';
 end if;
 return p_match||jsonb_build_object('score',v_score,'status',v_status,
   'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'homeTeamId'),
   'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'awayTeamId'),
   'competitionId',futbeat_private.futbeat_resolve_entity_id('competition',p_match->>'competitionId'),
   'hasPlayedEvidence',now()>v_start+interval '15 minutes'
     and (v_score is not null or v_has_events
       or exists(select 1 from futbeat_private.match_detail_cache c
         where c.match_id=p_match->>'id' and c.fetched_at>=v_start
         and (jsonb_array_length(case when jsonb_typeof(c.payload->'events')='array'
           then c.payload->'events' else '[]'::jsonb end)>0
           or jsonb_array_length(case when jsonb_typeof(c.payload->'incidents')='array'
           then c.payload->'incidents' else '[]'::jsonb end)>0))))
   ||case when v_events is null then '{}'::jsonb else jsonb_build_object('events',v_events) end;
end $$;

-- Match Center and every other caller keep the full model (events included).
create or replace function futbeat_private.match_read_model(p_match jsonb)
returns jsonb language sql stable security invoker set search_path='' as $$
  select futbeat_private.match_read_model_core(p_match,true)
$$;

create or replace function futbeat_private.build_compact_calendar(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  with bounds as (
    select p_from_date::timestamp at time zone p_timezone lo,
      (p_to_date+1)::timestamp at time zone p_timezone hi
  ), reconciled as materialized (
    -- The list projection resolves team/competition redirects (chained
    -- included) exactly once; events are only built for live matches.
    select futbeat_private.match_read_model_core(e.payload,false) item,c.updated_at
    from bounds b join futbeat_private.calendar_matches c
      on c.start_time>=b.lo and c.start_time<b.hi
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  ), source as (
    select jsonb_build_object(
      'updatedAt',coalesce((select max(greatest(
        nullif(item#>>'{provenance,receivedAt}','')::timestamptz,
        nullif(item->>'liveChangedAt','')::timestamptz,updated_at)) from reconciled),now()),
      'freshness',jsonb_build_object('stale',false),
      'coverage',jsonb_build_object('source','FutBeat','partial',not complete,
        'live',false,'developmentOnly',false,'sources',jsonb_build_array('GOAL API'),
        'calendar',jsonb_build_object('from',p_from_date,'to',p_to_date,
          'timezone',p_timezone,'complete',complete))) value
    from (
      select count(*)=(select ((hi-interval '1 microsecond') at time zone 'UTC')::date
        -(lo at time zone 'UTC')::date+1 from bounds) complete
      from futbeat_private.calendar_coverage,bounds
      where provider='goal_api' and provider_date between (lo at time zone 'UTC')::date
        and ((hi-interval '1 microsecond') at time zone 'UTC')::date
    ) coverage
  ), team_items as (
    select e.payload item from futbeat_private.entities e where e.kind='team'
      and e.id in (select item->>'homeTeamId' from reconciled
                   union select item->>'awayTeamId' from reconciled)
  ), competition_items as (
    select e.payload item from futbeat_private.entities e where e.kind='competition'
      and e.id in (select item->>'competitionId' from reconciled)
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from team_items
  ), compact_competitions as (
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    ))||jsonb_build_object(
      'countryCode',meta.country_code,
      'relevanceScore',coalesce(meta.relevance_score,
        futbeat_private.derived_competition_relevance(item->>'competitionClass',item->>'audienceClass')),
      'competitionClass',coalesce(meta.competition_class,'other'),
      'domesticTier',meta.domestic_tier,
      'isPrimaryDomestic',coalesce(meta.is_primary_domestic,false),
      'isGlobalRelevant',coalesce(meta.is_global_relevant,false),
      'audienceClass',coalesce(meta.audience_class,'unknown'),
      'relevanceSource',coalesce(meta.source,'derived')
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from competition_items
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status',
      'score',item->'score','minute',item->'minute',
      'hasPlayedEvidence',item->'hasPlayedEvidence',
      'latestEvent',case when item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        then (select event from jsonb_array_elements(item->'events') event
          order by (event->>'minute')::integer desc nulls last,
            (event->>'extraMinute')::integer desc nulls last,event->>'id' desc limit 1) end
    )) order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from reconciled
  )
  select jsonb_build_object(
    'schemaVersion',1,'demo',false,'updatedAt',source.value->'updatedAt',
    'coverage',source.value->'coverage','freshness',source.value->'freshness',
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value,'players','[]'::jsonb,'standings','[]'::jsonb)
  from source,compact_teams,compact_competitions,compact_matches
$$;

-- ---------------------------------------------------------------------------
-- Build queue, reader timezones, dirty marking.
-- ---------------------------------------------------------------------------
create table futbeat_private.calendar_snapshot_queue (
  calendar_date date not null,
  timezone text not null,
  priority smallint not null check(priority between 1 and 9),
  sort_key integer not null default 0,
  status text not null default 'pending' check(status in ('pending','building','done','failed')),
  requested_at timestamptz not null default now(),
  dirty_since timestamptz,
  lease_until timestamptz,
  attempt_count integer not null default 0,
  next_retry_at timestamptz,
  last_error text,
  built_at timestamptz,
  primary key(calendar_date,timezone)
);
create index calendar_snapshot_queue_ready_idx
  on futbeat_private.calendar_snapshot_queue(priority,sort_key,requested_at)
  where status in ('pending','building');
alter table futbeat_private.calendar_snapshot_queue enable row level security;
revoke all on futbeat_private.calendar_snapshot_queue from public,anon,authenticated;

-- Timezones readers use (tiny table, written at most hourly per zone).
create table futbeat_private.calendar_snapshot_zones (
  timezone text primary key,
  last_seen_at timestamptz not null default now()
);
alter table futbeat_private.calendar_snapshot_zones enable row level security;
revoke all on futbeat_private.calendar_snapshot_zones from public,anon,authenticated;
-- Seed from snapshots readers built recently (no fixed zone is assumed).
insert into futbeat_private.calendar_snapshot_zones(timezone,last_seen_at)
select timezone,max(built_at) from futbeat_private.compact_calendar_cache
where built_at>now()-interval '7 days' group by timezone
on conflict do nothing;

create or replace function futbeat_private.calendar_reader_zones()
returns text[] language sql stable set search_path='' as $$
  select coalesce(nullif(array(select z.timezone from futbeat_private.calendar_snapshot_zones z
      where z.last_seen_at>now()-interval '7 days' order by z.last_seen_at desc,z.timezone limit 3),'{}'),
    array[coalesce((select value from futbeat_private.runtime_settings where key='default_calendar_timezone'),'UTC')])
$$;

-- Deduplicated enqueue. Writes only on a state/priority transition, so many
-- changes (or readers) of one date never contend on its row.
create or replace function futbeat_private.enqueue_calendar_snapshot(
  p_date date,p_timezone text,p_priority integer,p_sort_key integer default 0)
returns void language plpgsql security definer set search_path='' as $$
begin
  if p_date is null or p_timezone is null then return; end if;
  if exists(select 1 from futbeat_private.calendar_snapshot_queue q
      where q.calendar_date=p_date and q.timezone=p_timezone
        and q.status='pending' and q.priority<=p_priority) then
    return;
  end if;
  update futbeat_private.calendar_snapshot_queue q set
    status='pending',
    priority=case when q.status='pending' then least(q.priority,p_priority) else p_priority end,
    sort_key=case when q.status='pending' and q.priority<=p_priority then q.sort_key else p_sort_key end,
    requested_at=now(),
    dirty_since=coalesce(q.dirty_since,now()),
    next_retry_at=case when p_priority=1 then null else q.next_retry_at end,
    attempt_count=case when q.status in ('done','failed') then 0 else q.attempt_count end
  where q.calendar_date=p_date and q.timezone=p_timezone
    and (q.status<>'pending' or q.priority>p_priority);
  if not found then
    insert into futbeat_private.calendar_snapshot_queue(calendar_date,timezone,priority,sort_key,dirty_since)
    values(p_date,p_timezone,p_priority,p_sort_key,now())
    on conflict do nothing;
  end if;
end $$;

-- Local dates (per reader timezone) intersecting a UTC date become dirty.
create or replace function futbeat_private.mark_calendar_dirty(p_utc_date date)
returns void language plpgsql security definer set search_path='' as $$
declare tz text; d date;
begin
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    for d in select distinct (x at time zone tz)::date
      from unnest(array[p_utc_date::timestamp at time zone 'UTC',
        (p_utc_date+1)::timestamp at time zone 'UTC'-interval '1 microsecond']) x order by 1 loop
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,5);
    end loop;
  end loop;
end $$;

create or replace function futbeat_private.bump_calendar_date(p_date date)
returns void language plpgsql volatile security definer set search_path='' as $$
begin
  -- UTC today stays unversioned (short-TTL snapshot, no hot row).
  if p_date is null or p_date=(now() at time zone 'UTC')::date then return; end if;
  insert into futbeat_private.calendar_cache_versions values(p_date,1)
  on conflict(utc_date) do update set revision=futbeat_private.calendar_cache_versions.revision+1;
  perform futbeat_private.mark_calendar_dirty(p_date);
end $$;

-- ---------------------------------------------------------------------------
-- Materialization (shared by the read path and the queue).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.materialize_calendar_day(p_date date,p_timezone text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_version text; v_payload jsonb; v_expiry timestamptz; v_today date;
 v_utc_today date; v_first_utc date; v_last_utc date; v_unversioned boolean; v_live boolean;
 live_ttl interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarLiveSeconds',15));
begin
 v_today:=(now() at time zone p_timezone)::date;
 v_utc_today:=(now() at time zone 'UTC')::date;
 v_first_utc:=(p_date::timestamp at time zone p_timezone at time zone 'UTC')::date;
 v_last_utc:=(((p_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date;
 v_unversioned:=v_utc_today between v_first_utc and v_last_utc;
 -- One build per date/timezone; version is read AFTER the lock.
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('calendar:'||p_date||':'||p_timezone,0));
 v_version:=futbeat_private.calendar_cache_version(p_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 v_payload:=futbeat_private.build_compact_calendar(p_date,p_date,p_timezone);
 v_live:=exists(select 1 from jsonb_array_elements(v_payload->'matches') m
   where m->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     or (m->>'startTime')::timestamptz between now()-interval '3 hours' and now()+interval '30 minutes');
 if v_unversioned then
   v_expiry:=now()+case when v_live then live_ttl
     else make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarTodaySeconds',60)) end;
 elsif p_date<v_today then
   -- Complete history is effectively frozen; new evidence bumps its version.
   v_expiry:=now()+case when not (v_payload#>>'{coverage,partial}')::boolean
     and not exists(select 1 from futbeat_private.calendar_coverage c where c.provider='goal_api'
       and c.provider_date between v_first_utc and v_last_utc and not c.results_complete)
     then make_interval(days=>futbeat_private.quota_setting('goal_api','calendarHistoryCompleteDays',30)::integer)
     else make_interval(mins=>futbeat_private.quota_setting('goal_api','calendarHistoryIncompleteMinutes',10)::integer) end;
 else
   v_expiry:=now()+make_interval(hours=>futbeat_private.quota_setting('goal_api','calendarFutureHours',24)::integer);
   -- Re-evaluated when the day enters the UTC-today (short TTL) window.
   v_expiry:=least(v_expiry,v_first_utc::timestamp at time zone 'UTC');
 end if;
 if v_live then v_expiry:=least(v_expiry,now()+live_ttl); end if;
 insert into futbeat_private.compact_calendar_cache values(p_date,p_timezone,v_version,v_payload,now(),v_expiry)
 on conflict(calendar_date,timezone) do update set version=excluded.version,payload=excluded.payload,
   built_at=excluded.built_at,expires_at=excluded.expires_at;
 perform futbeat_private.bump_metric('calendar_snapshot_builds');
 return v_payload;
end $$;

-- Drains the queue within a batch and a wall-clock budget. DB-only.
create or replace function futbeat_private.process_calendar_snapshot_queue(p_limit integer default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare lim integer:=greatest(1,least(coalesce(p_limit,
    futbeat_private.quota_setting('goal_api','calendarBuildBatch',4)::integer),20));
  deadline timestamptz:=clock_timestamp()+make_interval(secs=>
    futbeat_private.quota_setting('goal_api','calendarBuildBudgetMs',20000)/1000.0);
  r record; built jsonb:='[]'; failed integer:=0; v_version text;
begin
  loop
    exit when jsonb_array_length(built)+failed>=lim or clock_timestamp()>deadline;
    select q.calendar_date,q.timezone,q.priority into r from futbeat_private.calendar_snapshot_queue q
    where (q.status='pending' and coalesce(q.next_retry_at,'-infinity')<=now())
       or (q.status='building' and q.lease_until<now())
    order by q.priority,q.sort_key,q.requested_at,q.calendar_date,q.timezone
    limit 1 for update skip locked;
    exit when not found;
    update futbeat_private.calendar_snapshot_queue q set status='building',
      lease_until=now()+interval '2 minutes',attempt_count=q.attempt_count+1
    where q.calendar_date=r.calendar_date and q.timezone=r.timezone;
    begin
      -- Already valid (a reader built it): nothing to do.
      v_version:=futbeat_private.calendar_cache_version(r.calendar_date,r.timezone);
      if not exists(select 1 from futbeat_private.compact_calendar_cache c
          where c.calendar_date=r.calendar_date and c.timezone=r.timezone
            and c.version=v_version and c.expires_at>now()+interval '5 seconds') then
        perform futbeat_private.materialize_calendar_day(r.calendar_date,r.timezone);
        built:=built||jsonb_build_array(jsonb_build_object('date',r.calendar_date,'timezone',r.timezone,
          'priority',r.priority));
      end if;
      update futbeat_private.calendar_snapshot_queue q set status='done',built_at=now(),
        dirty_since=null,lease_until=null,next_retry_at=null,last_error=null
      where q.calendar_date=r.calendar_date and q.timezone=r.timezone and q.status='building';
    exception when others then
      failed:=failed+1;
      update futbeat_private.calendar_snapshot_queue q set
        status=case when q.attempt_count>=5 then 'failed' else 'pending' end,lease_until=null,
        next_retry_at=now()+least(interval '1 hour',interval '1 minute'*power(2,least(q.attempt_count,6))),
        last_error=left(sqlerrm,200)
      where q.calendar_date=r.calendar_date and q.timezone=r.timezone;
      perform futbeat_private.bump_metric('calendar_snapshot_build_failures');
    end;
  end loop;
  return jsonb_build_object('built',built,'failed',failed);
end $$;

-- Seeds every known date (fixtures or coverage) that has no snapshot yet:
-- history and far future get built once, in the background.
create or replace function futbeat_private.seed_calendar_snapshot_queue(p_limit integer default null)
returns integer language plpgsql volatile security definer set search_path='' as $$
declare lim integer:=greatest(0,least(coalesce(p_limit,
    futbeat_private.quota_setting('goal_api','calendarSeedBatch',6)::integer),50));
  back integer:=futbeat_private.quota_setting('goal_api','calendarSeedBackDays',90)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarSeedForwardDays',120)::integer;
  tz text; d date; queued integer:=0;
begin
  if lim=0 then return 0; end if;
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    -- Nearest dates first.
    for d in select (now() at time zone tz)::date+g from generate_series(-back,forward) g order by abs(g),g loop
      exit when queued>=lim;
      continue when exists(select 1 from futbeat_private.compact_calendar_cache c
        where c.calendar_date=d and c.timezone=tz);
      continue when exists(select 1 from futbeat_private.calendar_snapshot_queue q
        where q.calendar_date=d and q.timezone=tz and q.status in ('pending','building','failed'));
      continue when not exists(select 1 from futbeat_private.calendar_matches m
        where m.start_time>=d::timestamp at time zone tz and m.start_time<(d+1)::timestamp at time zone tz);
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,6,abs((d-(now() at time zone tz)::date)));
      queued:=queued+1;
    end loop;
  end loop;
  return queued;
end $$;

-- ---------------------------------------------------------------------------
-- Read path: never blocks on a heavy build.
-- ---------------------------------------------------------------------------
create or replace function public.futbeat_read_calendar_range(
 p_from_date date,p_to_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_row futbeat_private.compact_calendar_cache; v_version text; v_count integer;
 retry integer:=futbeat_private.quota_setting('goal_api','calendarPendingRetrySeconds',3)::integer;
begin
 if p_from_date is null or p_to_date is null or p_from_date>p_to_date
   or p_to_date-p_from_date>31 or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then
   raise exception 'Invalid calendar range';
 end if;
 if p_from_date<>p_to_date then
   return futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 end if;
 -- Remember reader timezones (at most one write per zone per hour).
 if not exists(select 1 from futbeat_private.calendar_snapshot_zones z
     where z.timezone=p_timezone and z.last_seen_at>now()-interval '1 hour') then
   insert into futbeat_private.calendar_snapshot_zones(timezone,last_seen_at) values(p_timezone,now())
   on conflict(timezone) do update set last_seen_at=excluded.last_seen_at;
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
   perform futbeat_private.wake_provider_worker('demand');
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
end $$;

-- Worker lane (name kept): hot window + dirty + seeding, drained in budget.
create or replace function public.futbeat_warm_calendar_window(p_limit integer default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare back integer:=futbeat_private.quota_setting('goal_api','calendarWarmBackDays',2)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarWarmForwardDays',7)::integer;
  tz text; offs integer; d date; checked integer:=0; seeded integer; result jsonb; rank integer;
begin
  foreach tz in array futbeat_private.calendar_reader_zones() loop
    if not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then continue; end if;
    -- today, +1, -1, +2, -2, ... within the window.
    for offs,rank in select g,abs(g)*2-case when g>0 then 1 else 0 end from generate_series(-back,forward) g loop
      d:=(now() at time zone tz)::date+offs;
      checked:=checked+1;
      if exists(select 1 from futbeat_private.compact_calendar_cache c where c.calendar_date=d and c.timezone=tz
          and c.version=futbeat_private.calendar_cache_version(d,tz) and c.expires_at>now()+interval '5 seconds') then
        continue;
      end if;
      perform futbeat_private.enqueue_calendar_snapshot(d,tz,
        case when offs=0 then 2 when abs(offs)=1 then 3 else 4 end,rank);
    end loop;
  end loop;
  seeded:=futbeat_private.seed_calendar_snapshot_queue(null);
  result:=futbeat_private.process_calendar_snapshot_queue(p_limit);
  if jsonb_array_length(result->'built')>0 then
    perform futbeat_private.bump_metric('calendar_warm_builds',jsonb_array_length(result->'built'));
  end if;
  -- Bounded retention of snapshots and finished queue rows.
  delete from futbeat_private.compact_calendar_cache where built_at<now()-make_interval(
    days=>futbeat_private.quota_setting('goal_api','calendarRetentionDays',120)::integer);
  delete from futbeat_private.calendar_snapshot_queue where status='done' and built_at<now()-interval '1 day';
  return result||jsonb_build_object('checked',checked,'seeded',seeded);
end $$;

-- Operational view of the queue (service role).
create or replace function public.futbeat_calendar_snapshot_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'pending',(select count(*) from futbeat_private.calendar_snapshot_queue where status='pending'),
    'building',(select count(*) from futbeat_private.calendar_snapshot_queue where status='building'),
    'failed',(select count(*) from futbeat_private.calendar_snapshot_queue where status='failed'),
    'snapshots',(select count(*) from futbeat_private.compact_calendar_cache),
    'oldestPending',(select min(requested_at) from futbeat_private.calendar_snapshot_queue where status='pending'),
    'zones',to_jsonb(futbeat_private.calendar_reader_zones()))
$$;

revoke all on function
  futbeat_private.match_read_model_core(jsonb,boolean),
  futbeat_private.calendar_reader_zones(),
  futbeat_private.enqueue_calendar_snapshot(date,text,integer,integer),
  futbeat_private.mark_calendar_dirty(date),
  futbeat_private.bump_calendar_date(date),
  futbeat_private.materialize_calendar_day(date,text),
  futbeat_private.process_calendar_snapshot_queue(integer),
  futbeat_private.seed_calendar_snapshot_queue(integer),
  futbeat_private.build_compact_calendar(date,date,text)
from public,anon,authenticated,service_role;
revoke all on function futbeat_private.match_read_model(jsonb) from public,anon,authenticated;
revoke all on function public.futbeat_read_calendar_range(date,date,text) from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;
revoke all on function public.futbeat_warm_calendar_window(integer) from public,anon,authenticated;
grant execute on function public.futbeat_warm_calendar_window(integer) to service_role;
revoke all on function public.futbeat_calendar_snapshot_status() from public,anon,authenticated;
grant execute on function public.futbeat_calendar_snapshot_status() to service_role;

notify pgrst,'reload schema';
