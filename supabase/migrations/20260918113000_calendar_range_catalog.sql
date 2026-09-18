-- Persist a broad football calendar without expanding the hot mobile snapshot.
-- Canonical match payloads remain in entities; this index makes day/range reads cheap.

create table if not exists futbeat_private.calendar_matches(
  match_id text primary key references futbeat_private.entities(id) on delete cascade,
  start_time timestamptz not null,
  source text not null,
  updated_at timestamptz not null
);

create index if not exists calendar_matches_start_time_idx
  on futbeat_private.calendar_matches(start_time);

create table if not exists futbeat_private.calendar_coverage(
  provider text not null,
  provider_date date not null,
  fetched_at timestamptz not null,
  fixture_count integer not null default 0 check(fixture_count >= 0),
  primary key(provider,provider_date)
);

create index if not exists calendar_coverage_fetched_idx
  on futbeat_private.calendar_coverage(provider,fetched_at);

alter table futbeat_private.calendar_matches enable row level security;
alter table futbeat_private.calendar_coverage enable row level security;

revoke all on futbeat_private.calendar_matches,
  futbeat_private.calendar_coverage
from public,anon,authenticated;

grant select,insert,update,delete on
  futbeat_private.calendar_matches,
  futbeat_private.calendar_coverage
to service_role;

create or replace function futbeat_private.futbeat_index_calendar_match()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  parsed_start timestamptz;
  parsed_received timestamptz;
  parsed_source text;
begin
  if tg_op='DELETE' then
    delete from futbeat_private.calendar_matches where match_id=old.id;
    return old;
  end if;

  if new.kind <> 'match' or nullif(new.payload->>'startTime','') is null then
    delete from futbeat_private.calendar_matches where match_id=new.id;
    return new;
  end if;

  begin
    parsed_start := (new.payload->>'startTime')::timestamptz;
  exception when others then
    delete from futbeat_private.calendar_matches where match_id=new.id;
    return new;
  end;

  parsed_source := coalesce(
    nullif(new.payload->'provenance'->>'source',''),
    'FutBeat'
  );

  begin
    parsed_received := (new.payload->'provenance'->>'receivedAt')::timestamptz;
  exception when others then
    parsed_received := now();
  end;

  insert into futbeat_private.calendar_matches(
    match_id,start_time,source,updated_at
  )
  values(new.id,parsed_start,parsed_source,coalesce(parsed_received,now()))
  on conflict(match_id) do update set
    start_time=excluded.start_time,
    source=excluded.source,
    updated_at=excluded.updated_at;

  return new;
end;
$$;

drop trigger if exists futbeat_calendar_match_index on futbeat_private.entities;
create trigger futbeat_calendar_match_index
after insert or update of kind,payload or delete
on futbeat_private.entities
for each row execute function futbeat_private.futbeat_index_calendar_match();

-- Populate the index from canonical matches already stored before this migration.
update futbeat_private.entities
   set payload=payload
 where kind='match';

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
declare
  item jsonb;
  coverage_item jsonb;
  coverage_date date;
  coverage_count integer;
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

  for item in select value from jsonb_array_elements(p_snapshot->'competitions') loop
    insert into futbeat_private.entities(id,kind,payload)
    values(item->>'id','competition',item)
    on conflict(id) do update set payload=excluded.payload;
  end loop;

  for item in select value from jsonb_array_elements(p_snapshot->'teams') loop
    insert into futbeat_private.entities(id,kind,payload)
    values(item->>'id','team',item)
    on conflict(id) do update set payload=excluded.payload;
  end loop;

  for item in select value from jsonb_array_elements(p_snapshot->'matches') loop
    insert into futbeat_private.entities(id,kind,payload)
    values(item->>'id','match',item)
    on conflict(id) do update set payload=excluded.payload;
  end loop;

  for coverage_item in select value from jsonb_array_elements(p_coverage) loop
    begin
      coverage_date := (coverage_item->>'date')::date;
      coverage_count := (coverage_item->>'count')::integer;
    exception when others then
      raise exception 'Invalid calendar coverage item';
    end;

    if coverage_count < 0 then
      raise exception 'Invalid calendar coverage count';
    end if;

    insert into futbeat_private.calendar_coverage(
      provider,provider_date,fetched_at,fixture_count
    )
    values(p_provider,coverage_date,p_received_at,coverage_count)
    on conflict(provider,provider_date) do update set
      fetched_at=excluded.fetched_at,
      fixture_count=excluded.fixture_count;
  end loop;

  return jsonb_build_object(
    'matches',jsonb_array_length(p_snapshot->'matches'),
    'competitions',jsonb_array_length(p_snapshot->'competitions'),
    'teams',jsonb_array_length(p_snapshot->'teams'),
    'coveredDates',jsonb_array_length(p_coverage)
  );
end;
$$;

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
  max(cm.updated_at)
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

create or replace function futbeat_private.futbeat_calendar_missing_provider_dates(
  p_provider text,
  p_from_date date,
  p_to_date date,
  p_limit integer default 45
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  today_utc date := (now() at time zone 'UTC')::date;
  result jsonb;
begin
  if p_provider <> 'goal_api'
     or p_from_date is null
     or p_to_date is null
     or p_from_date > p_to_date
     or p_to_date - p_from_date > 400
     or p_limit < 1
     or p_limit > 90
  then
    raise exception 'Invalid calendar coverage request';
  end if;

  select coalesce(jsonb_agg(to_char(provider_date,'YYYY-MM-DD') order by priority,sort_distance),'[]'::jsonb)
  into result
  from (
    select provider_date,priority,sort_distance
    from (
      select
        d::date as provider_date,
        case
          when d::date between today_utc + 2 and today_utc + 90 then 0
          when d::date between today_utc - 30 and today_utc - 2 then 1
          when d::date > today_utc + 90 then 2
          else 3
        end as priority,
        case
          when d::date >= today_utc then d::date - today_utc
          else today_utc - d::date
        end as sort_distance,
        c.fetched_at
      from generate_series(
        p_from_date::timestamp,
        p_to_date::timestamp,
        interval '1 day'
      ) d
      left join futbeat_private.calendar_coverage c
        on c.provider=p_provider
       and c.provider_date=d::date
      where d::date not between today_utc - 1 and today_utc + 1
        and (
          c.provider_date is null
          or case
            when d::date < today_utc - 1
              then c.fetched_at < ((d::date + 2)::timestamp at time zone 'UTC')
            when d::date <= today_utc + 14
              then c.fetched_at < now() - interval '1 day'
            else c.fetched_at < now() - interval '7 days'
          end
        )
    ) candidates
    order by priority,sort_distance
    limit p_limit
  ) picked;

  return result;
end;
$$;

create or replace function public.futbeat_store_calendar_range(
  p_provider text,
  p_received_at timestamptz,
  p_coverage jsonb,
  p_snapshot jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_calendar_range(
    p_provider,p_received_at,p_coverage,p_snapshot
  )
$$;

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,
  p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_read_calendar_range(
    p_from_date,p_to_date,p_timezone
  )
$$;

create or replace function public.futbeat_calendar_missing_provider_dates(
  p_provider text,
  p_from_date date,
  p_to_date date,
  p_limit integer default 45
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_calendar_missing_provider_dates(
    p_provider,p_from_date,p_to_date,p_limit
  )
$$;

revoke all on function
  futbeat_private.futbeat_index_calendar_match(),
  futbeat_private.futbeat_store_calendar_range(text,timestamptz,jsonb,jsonb),
  futbeat_private.futbeat_read_calendar_range(date,date,text),
  futbeat_private.futbeat_calendar_missing_provider_dates(text,date,date,integer),
  public.futbeat_store_calendar_range(text,timestamptz,jsonb,jsonb),
  public.futbeat_read_calendar_range(date,date,text),
  public.futbeat_calendar_missing_provider_dates(text,date,date,integer)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_store_calendar_range(text,timestamptz,jsonb,jsonb),
  futbeat_private.futbeat_read_calendar_range(date,date,text),
  futbeat_private.futbeat_calendar_missing_provider_dates(text,date,date,integer),
  public.futbeat_store_calendar_range(text,timestamptz,jsonb,jsonb),
  public.futbeat_read_calendar_range(date,date,text),
  public.futbeat_calendar_missing_provider_dates(text,date,date,integer)
to service_role;

notify pgrst,'reload schema';
