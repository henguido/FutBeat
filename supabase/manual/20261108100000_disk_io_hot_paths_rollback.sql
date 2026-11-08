-- Rollback of 20261108100000_disk_io_hot_paths.sql (manual, NOT a
-- migration). Restores the three functions verbatim from their previous
-- migrations. The payload_md5 column and the two observation indexes are
-- harmless to the old code and are kept; drop the indexes only off-peak:
--   drop index concurrently if exists futbeat_private.provider_observations_match_received_all_idx;
--   drop index concurrently if exists futbeat_private.provider_observations_final_states_idx;
begin;
set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- From 20260930125000_goal_terminal_score_semantics.sql
create or replace function futbeat_private.match_read_model_core(p_match jsonb,p_events boolean)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 v_score jsonb; v_status text:=p_match->>'status'; v_events jsonb; v_has_events boolean;
 v_start timestamptz:=(p_match->>'startTime')::timestamptz;
 v_received timestamptz:=coalesce(nullif(p_match#>>'{provenance,receivedAt}','')::timestamptz,'-infinity');
 v_evidence record;
 v_relax_terminal boolean;
 v_mismatch boolean:=false;
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
     -- Newest first; the score rule only runs until the first observation
     -- that carries one (usually the newest), never over the whole trail
     -- (OFFSET 0 keeps the ordered scan below the rule and computes it
     -- once per row).
     (select o.score,o.received_at,1
       from (select futbeat_private.observation_score(x.provider,x.home_score,x.away_score,x.raw_payload) score,
           x.received_at
         from (select provider,home_score,away_score,raw_payload,received_at,id
           from futbeat_private.provider_observations
           where canonical_match_id=p_match->>'id'
             and received_at>=v_start
             and status not in ('POSTPONED','CANCELLED')
             and (provider='goal_api' or (home_score is not null and away_score is not null))
           order by received_at desc,id desc offset 0) x offset 0) o
       where o.score is not null limit 1)
     union all
     select jsonb_build_object('home',l.home_score,'away',l.away_score),l.last_seen_at,2
       from futbeat_private.live_match_state l where l.canonical_match_id=p_match->>'id'
         and l.home_score is not null and l.away_score is not null and l.last_seen_at>=v_start
         and l.status not in ('POSTPONED','CANCELLED')
     union all
     select d.score,d.fetched_at,3
       from (select futbeat_private.goal_fixture_score(c.payload) score,c.fetched_at
         from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
           and c.fetched_at>=v_start and now()>=v_start offset 0) d
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
        or (v_relax_terminal and status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED','SUSPENDED')))
      and (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED','SUSPENDED')
        or status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES'))
    -- Finals first; otherwise the newest provider state wins, and a LIVE one
    -- only while fresh (an older stop never outlives a later, silent LIVE).
    order by (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')) desc,received_at desc,id desc limit 1;
   if found and not (v_evidence.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
       and v_evidence.received_at<now()-interval '15 minutes') then
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
       -- P0-A: a payload copy never re-injects an id canonical_events owns
       -- (retracted or corrected there).
       select value event from jsonb_array_elements(coalesce(p_match->'events','[]'::jsonb))
         where not exists(select 1 from futbeat_private.canonical_events x where x.id=value->>'id')
       union all select payload||jsonb_build_object('id',id,'type',event_type)
         from futbeat_private.canonical_events where match_id=p_match->>'id' and retracted_at is null
     ) all_events order by coalesce(event->>'id',event::text)
   ) unique_events;
   -- #121: one visible occurrence per logical football event; P0-A: the
   -- score decides synthetic goals.
   v_events:=futbeat_private.visible_match_events(v_events,p_match->>'homeTeamId',p_match->>'awayTeamId',v_score);
   v_mismatch:=futbeat_private.event_score_mismatch(v_events,p_match->>'homeTeamId',p_match->>'awayTeamId',v_score);
   v_has_events:=jsonb_array_length(v_events)>0;
 else
   -- Same answer as a non-empty merged array, without building it.
   v_has_events:=coalesce(jsonb_array_length(case when jsonb_typeof(p_match->'events')='array'
       then p_match->'events' end),0)>0
     or exists(select 1 from futbeat_private.canonical_events where match_id=p_match->>'id' and retracted_at is null);
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
   ||case when v_events is null then '{}'::jsonb else jsonb_build_object('events',v_events) end
   ||case when v_mismatch then jsonb_build_object('scoreMismatch',true) else '{}'::jsonb end;
end $$;

-- From 20260927152657_bound_match_detail_planner.sql
create or replace function futbeat_private.plan_match_detail_coverage(p_limit integer default null)
returns text[] language plpgsql security definer set search_path='' as $$
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
        futbeat_private.match_detail_bucket(w.status,w.start_time) bucket
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
end $$;

-- From 20260924100000_calendar_snapshot_materialization.sql
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
 return v_payload;
end $$;

notify pgrst, 'reload schema';
commit;
