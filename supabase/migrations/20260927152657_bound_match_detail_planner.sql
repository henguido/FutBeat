-- Bound the coverage candidate stage before the 400-row priority sort.
-- PostgreSQL previously inlined both CTEs, so match_detail_status() and
-- match_detail_bucket() were re-evaluated several times for every match in
-- the seven-day window. Materializing the narrow profile evaluates each
-- expensive classification once while preserving all quota, queue, retry,
-- priority and idempotency semantics.

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
