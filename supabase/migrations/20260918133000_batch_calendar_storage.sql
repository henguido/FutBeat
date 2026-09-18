-- Batch calendar/global storage so catalog size does not make hot ingestion O(n^2).
-- Also avoid touching the calendar index for ordinary score/status/media updates.

drop trigger if exists futbeat_calendar_match_index on futbeat_private.entities;
drop trigger if exists futbeat_calendar_match_insert on futbeat_private.entities;
drop trigger if exists futbeat_calendar_match_update on futbeat_private.entities;
drop trigger if exists futbeat_calendar_match_delete on futbeat_private.entities;

create trigger futbeat_calendar_match_insert
after insert on futbeat_private.entities
for each row
when (
  new.kind = 'match'
  and nullif(new.payload->>'startTime','') is not null
)
execute function futbeat_private.futbeat_index_calendar_match();

create trigger futbeat_calendar_match_update
after update of kind,payload on futbeat_private.entities
for each row
when (
  old.kind is distinct from new.kind
  or old.payload->>'startTime' is distinct from new.payload->>'startTime'
  or old.payload->'provenance'->>'source'
       is distinct from new.payload->'provenance'->>'source'
)
execute function futbeat_private.futbeat_index_calendar_match();

create trigger futbeat_calendar_match_delete
after delete on futbeat_private.entities
for each row
when (old.kind = 'match')
execute function futbeat_private.futbeat_index_calendar_match();

create or replace function futbeat_private.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
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
    jsonb_agg(e.payload order by cm.start_time,e.id),
    '[]'::jsonb
  ),
  max(
    coalesce(
      nullif(e.payload->'provenance'->>'receivedAt','')::timestamptz,
      cm.updated_at
    )
  )
  into matches_json,updated_at
  from futbeat_private.calendar_matches cm
  join futbeat_private.entities e
    on e.id=cm.match_id and e.kind='match'
  where cm.start_time >= start_at
    and cm.start_time < end_at;

  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into teams_json
  from futbeat_private.entities e
  where e.kind='team'
    and e.id in (
      select value->>'homeTeamId'
      from jsonb_array_elements(matches_json)
      union
      select value->>'awayTeamId'
      from jsonb_array_elements(matches_json)
    );

  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'country',e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into competitions_json
  from futbeat_private.entities e
  where e.kind='competition'
    and e.id in (
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
$$;

create or replace function futbeat_private.futbeat_store_global_fixture_window(
  p_job_id uuid,
  p_received_at timestamptz,
  p_from_date date,
  p_to_date date,
  p_raw jsonb,
  p_snapshot jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  previous jsonb;
  merged jsonb;
  merged_competitions jsonb;
  merged_teams jsonb;
  merged_matches jsonb;
begin
  if p_from_date > p_to_date
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
  then
    raise exception 'Invalid global fixture snapshot';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' not in ('SofaScore','ESPN','GOAL API')
  ) then
    raise exception 'Unexpected global fixture source';
  end if;

  if exists(
    select 1
    from futbeat_private.imports
    where job_id=p_job_id::text
  ) then
    return '{"duplicate":true}'::jsonb;
  end if;

  if exists(
    select 1
    from futbeat_private.imports
    where received_at >= p_received_at
  ) then
    raise exception 'Out-of-order import';
  end if;

  select snapshot
  into previous
  from futbeat_private.imports
  order by received_at desc,job_id desc
  limit 1;

  previous := coalesce(
    previous,
    '{"competitions":[],"teams":[],"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}'::jsonb
  );

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'competitions') x(item)
  where e.id=x.item->>'id'
    and e.kind='competition'
    and e.payload is distinct from x.item;

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  where e.id=x.item->>'id'
    and e.kind='team'
    and e.payload is distinct from x.item;

  update futbeat_private.entities e
  set payload=x.item
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  where e.id=x.item->>'id'
    and e.kind='match'
    and e.payload is distinct from x.item;

  with old_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(coalesce(previous->'competitions','[]'::jsonb))
  ),
  new_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(p_snapshot->'competitions')
  )
  select coalesce(
    jsonb_agg(e.value order by e.value->>'country',e.value->>'name'),
    '[]'::jsonb
  )
  into merged_competitions
  from old_map
  cross join new_map
  cross join lateral jsonb_each(old_map.m || new_map.m) e;

  with old_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(coalesce(previous->'teams','[]'::jsonb))
  ),
  new_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(p_snapshot->'teams')
  )
  select coalesce(
    jsonb_agg(e.value order by e.value->>'name',e.value->>'id'),
    '[]'::jsonb
  )
  into merged_teams
  from old_map
  cross join new_map
  cross join lateral jsonb_each(old_map.m || new_map.m) e;

  with old_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(coalesce(previous->'matches','[]'::jsonb))
    where not (
      value->'provenance'->>'source' in ('SofaScore','ESPN','GOAL API')
      and (value->>'startTime')::timestamptz >=
        (p_from_date::timestamp at time zone 'America/Costa_Rica')
      and (value->>'startTime')::timestamptz <
        ((p_to_date + 1)::timestamp at time zone 'America/Costa_Rica')
    )
  ),
  new_map as (
    select coalesce(
      jsonb_object_agg(value->>'id',value),
      '{}'::jsonb
    ) as m
    from jsonb_array_elements(p_snapshot->'matches')
  )
  select coalesce(
    jsonb_agg(e.value order by e.value->>'startTime',e.value->>'id'),
    '[]'::jsonb
  )
  into merged_matches
  from old_map
  cross join new_map
  cross join lateral jsonb_each(old_map.m || new_map.m) e;

  merged := p_snapshot || jsonb_build_object(
    'coverage',
    jsonb_build_object(
      'source','FutBeat Global',
      'partial',true,
      'live',coalesce((previous->'coverage'->>'live')::boolean,false),
      'developmentOnly',true,
      'description','Cobertura global de partidos',
      'sources',jsonb_build_array(
        'TheSportsDB','API-Football','SofaScore','ESPN','GOAL API'
      )
    ),
    'competitions',merged_competitions,
    'teams',merged_teams,
    'players',coalesce(previous->'players','[]'::jsonb),
    'matches',merged_matches,
    'standings',coalesce(previous->'standings','[]'::jsonb),
    'news',coalesce(previous->'news','[]'::jsonb),
    'transfers',coalesce(previous->'transfers','[]'::jsonb)
  );

  insert into futbeat_private.imports(
    job_id,received_at,raw_payload,snapshot
  )
  values(
    p_job_id::text,p_received_at,p_raw,merged
  );

  return jsonb_build_object(
    'duplicate',false,
    'competitions',jsonb_array_length(merged->'competitions'),
    'teams',jsonb_array_length(merged->'teams'),
    'matches',jsonb_array_length(merged->'matches')
  );
end;
$$;

create or replace function futbeat_private.futbeat_store_calendar_range(
  p_provider text,
  p_received_at timestamptz,
  p_coverage jsonb,
  p_snapshot jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  if p_provider <> 'goal_api'
     or jsonb_typeof(p_coverage) <> 'array'
     or jsonb_array_length(p_coverage) > 31
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
  then
    raise exception 'Invalid calendar range payload';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' <> 'GOAL API'
  ) then
    raise exception 'Unexpected calendar fixture source';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_coverage) c
    where coalesce(c->>'date','') !~ '^\d{4}-\d{2}-\d{2}$'
       or coalesce(c->>'count','') !~ '^\d+$'
  ) then
    raise exception 'Invalid calendar coverage item';
  end if;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','competition',item
  from jsonb_array_elements(p_snapshot->'competitions') x(item)
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='competition'
      and e.payload is distinct from excluded.payload;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='team'
      and e.payload is distinct from excluded.payload;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','match',item
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='match'
      and e.payload is distinct from excluded.payload;

  with coverage_dates as materialized (
    select (value->>'date')::date as d
    from jsonb_array_elements(p_coverage)
  ),
  snapshot_ids as materialized (
    select value->>'id' as id
    from jsonb_array_elements(p_snapshot->'matches')
  )
  delete from futbeat_private.calendar_matches cm
  where cm.source='GOAL API'
    and exists(
      select 1
      from coverage_dates cd
      where cm.start_time >= (cd.d::timestamp at time zone 'UTC')
        and cm.start_time < ((cd.d + 1)::timestamp at time zone 'UTC')
    )
    and not exists(
      select 1
      from snapshot_ids s
      where s.id=cm.match_id
    );

  insert into futbeat_private.calendar_coverage(
    provider,provider_date,fetched_at,fixture_count
  )
  select
    p_provider,
    (value->>'date')::date,
    p_received_at,
    (value->>'count')::integer
  from jsonb_array_elements(p_coverage)
  on conflict(provider,provider_date) do update
  set
    fetched_at=excluded.fetched_at,
    fixture_count=excluded.fixture_count;

  return jsonb_build_object(
    'matches',jsonb_array_length(p_snapshot->'matches'),
    'competitions',jsonb_array_length(p_snapshot->'competitions'),
    'teams',jsonb_array_length(p_snapshot->'teams'),
    'coveredDates',jsonb_array_length(p_coverage)
  );
end;
$$;

notify pgrst,'reload schema';
