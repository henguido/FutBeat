-- Durable, provider-date demand queue for calendar cache misses. A civil day
-- can span two UTC provider dates; the primary key deduplicates every client.
create table futbeat_private.calendar_date_requests(
  provider text not null,
  provider_date date not null,
  first_requested_at timestamptz not null default now(),
  last_requested_at timestamptz not null default now(),
  request_count bigint not null default 1 check(request_count>0),
  primary key(provider,provider_date)
);

alter table futbeat_private.calendar_date_requests enable row level security;
revoke all on futbeat_private.calendar_date_requests
from public,anon,authenticated;

create index calendar_date_requests_priority_idx
on futbeat_private.calendar_date_requests(last_requested_at,provider_date);

create or replace function futbeat_private.futbeat_request_calendar_date(
  p_local_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_today date := (now() at time zone p_timezone)::date;
  v_result jsonb;
begin
  if p_local_date is null
     or not exists(
       select 1 from pg_catalog.pg_timezone_names where name=p_timezone
     ) then
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
$$;

create or replace function futbeat_private.futbeat_requested_calendar_dates(
  p_limit integer default 12
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
begin
  if p_limit<1 or p_limit>45 then
    raise exception 'Invalid calendar request limit';
  end if;

  delete from futbeat_private.calendar_date_requests r
  using futbeat_private.calendar_coverage c
  where c.provider=r.provider and c.provider_date=r.provider_date
    and c.fetched_at>=r.last_requested_at;

  select coalesce(
    jsonb_agg(to_char(provider_date,'YYYY-MM-DD') order by last_requested_at,provider_date),
    '[]'::jsonb
  ) into v_result
  from (
    select provider_date,last_requested_at
    from futbeat_private.calendar_date_requests
    where provider='goal_api'
    order by last_requested_at,provider_date
    limit p_limit
  ) requested;

  return v_result;
end
$$;

create or replace function public.futbeat_request_calendar_date(
  p_local_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_request_calendar_date(p_local_date,p_timezone)
$$;

create or replace function public.futbeat_requested_calendar_dates(
  p_limit integer default 12
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_requested_calendar_dates(p_limit)
$$;

revoke all on function public.futbeat_request_calendar_date(date,text)
from public,anon,authenticated;
revoke all on function public.futbeat_requested_calendar_dates(integer)
from public,anon,authenticated;
grant execute on function public.futbeat_request_calendar_date(date,text)
to service_role;
grant execute on function public.futbeat_requested_calendar_dates(integer)
to service_role;

notify pgrst,'reload schema';
