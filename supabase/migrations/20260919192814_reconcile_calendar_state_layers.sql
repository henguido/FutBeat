-- Reconcile every calendar row from the canonical entity, the durable LIVE
-- state and the detail cache. A terminal canonical value is immutable here;
-- active overlays expire, and a newer terminal detail cannot be reopened by
-- an older LIVE observation.
create or replace function futbeat_private.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
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
     or not exists(
       select 1
       from pg_catalog.pg_timezone_names
       where name=p_timezone
     )
  then
    raise exception 'Invalid calendar range';
  end if;

  start_at := p_from_date::timestamp at time zone p_timezone;
  end_at := (p_to_date + 1)::timestamp at time zone p_timezone;

  select coalesce(
    jsonb_agg(
      case
        when resolved.status is not null then entity.payload || jsonb_strip_nulls(
          jsonb_build_object(
            'status',resolved.status,
            'minute',resolved.minute,
            'score',resolved.score,
            'liveProvider',resolved.provider,
            'liveChangedAt',resolved.observed_at
          )
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
          entity.payload->>'status',
          case when coalesce(entity.payload->>'minute','') ~ '^\d+$'
            then (entity.payload->>'minute')::integer else null end,
          entity.payload->'score',
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

-- The minute worker may recover one stale, mapped match even when nobody has
-- opened Match Center. Provider quota reservation remains the hard spending
-- guard, and a single queue row per canonical match prevents fan-out.
create or replace function futbeat_private.enqueue_stale_interested_match_detail()
returns text
language plpgsql
security definer
set search_path=''
as $$
declare
  v_match_id text;
begin
  if exists(
    select 1 from futbeat_private.match_detail_requests where expires_at>now()
  ) then
    return null;
  end if;

  select e.id into v_match_id
  from futbeat_private.entities e
  join futbeat_private.provider_entities pe
    on pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=e.id
  join futbeat_private.live_match_state l
    on l.canonical_match_id=e.id
   and l.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
   and l.last_seen_at<now()-interval '15 minutes'
  left join futbeat_private.match_detail_cache c on c.match_id=e.id
  where e.kind='match'
    and nullif(e.payload->>'startTime','') is not null
    and (e.payload->>'startTime')::timestamptz
      between now()-interval '36 hours' and now()-interval '15 minutes'
    and coalesce(e.payload->>'status','') not in (
      'FINISHED_PENDING_VERIFICATION','VERIFIED','CANCELLED','SUSPENDED',
      'ABANDONED','POSTPONED'
    )
    and (c.fetched_at is null or c.fetched_at<l.last_seen_at)
  order by l.last_seen_at desc,(e.payload->>'startTime')::timestamptz desc
  limit 1;

  if v_match_id is null then
    return null;
  end if;

  insert into futbeat_private.match_detail_requests(
    match_id,requested_at,expires_at,request_count
  ) values(v_match_id,now(),now()+interval '10 minutes',1)
  on conflict(match_id) do update
    set requested_at=excluded.requested_at,
        expires_at=excluded.expires_at,
        request_count=futbeat_private.match_detail_requests.request_count+1;

  return v_match_id;
end
$$;

notify pgrst,'reload schema';
