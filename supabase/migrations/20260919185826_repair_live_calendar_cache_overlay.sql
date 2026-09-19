-- Overlay recent GOAL detail on the calendar while the canonical LIVE state
-- catches up. The underlying fixture remains the same canonical match.
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
        when detail.status is not null
          and (
            detail.status in (
              'FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
              'SUSPENDED','ABANDONED'
            )
            or cache.fetched_at>=now()-interval '15 minutes'
          )
        then entity.payload || jsonb_strip_nulls(
          jsonb_build_object(
            'status',detail.status,
            'minute',detail.minute,
            'score',detail.score,
            'liveProvider','goal_api',
            'liveChangedAt',cache.fetched_at
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
      case
        when detail.status is not null
          and (
            detail.status in (
              'FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED',
              'SUSPENDED','ABANDONED'
            )
            or cache.fetched_at>=now()-interval '15 minutes'
          )
        then cache.fetched_at
        else '-infinity'::timestamptz
      end
    )
  )
  into matches_json,updated_at
  from futbeat_private.calendar_matches calendar
  join futbeat_private.entities entity
    on entity.id=calendar.match_id and entity.kind='match'
  left join futbeat_private.match_detail_cache cache
    on cache.match_id=entity.id
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

notify pgrst,'reload schema';
