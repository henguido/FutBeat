-- Turn 244: the calendar plan spends the GOAL budget it really has.
--
-- Measured 10-23..10-31: a run with >= 650 left lands on about 4 days of 10 and fetches at most
-- 90 pages. Refreshing +2..+14 every day and +15..+90 every 7 days costs about 130 pages a day,
-- so the nearest dates ate the budget and the far ones never came up. Refresh by distance:
--   +2..+3 1 day, +4..+14 3 days, +15..+45 7 days, beyond +45 21 days. Order unchanged: nearest first.
--
-- A date whose ingest failed twice in 24 h rests for 24 h: a large date costs up to 16 pages per
-- attempt and a persistent failure repeated them on every run. It comes back alone.
--
-- Past 64 ingests a day v44 answers 200 skipped after the workflow paid the pages. The plan now
-- stops offering dates when no slot is left, with the same count as futbeat_reserve_provider_call.
--
-- Not applied by db push: production uses the turn 244 kit, guarded by the previous md5
-- (aec1bcabed0ea28bfabb675154d199f7 and 8bd083b3f718e99adefb57e6056a33bc). Rollback in the kit.

create or replace function futbeat_private.calendar_ingest_slots_left()
returns integer language sql stable security definer set search_path to ''
as $function$
  select greatest(0,64-count(*)::integer)
  from futbeat_private.provider_call_ledger
  where provider='goal_api' and call_kind='calendar-ingest'
    and reserved_at>=date_trunc('day',now() at time zone 'UTC') at time zone 'UTC'
$function$;

create or replace function futbeat_private.calendar_dates_resting()
returns setof date language sql stable security definer set search_path to ''
as $function$
  select (metadata->>'failedDate')::date
  from futbeat_private.provider_call_ledger
  where provider='goal_api' and call_kind='calendar-ingest' and status='FAILED'
    and reserved_at>=now()-interval '24 hours'
    and coalesce(metadata->>'failedDate','')~'^\d{4}-\d{2}-\d{2}$'
  group by 1 having count(*)>=2
$function$;

create or replace function futbeat_private.futbeat_calendar_missing_provider_dates(p_provider text, p_from_date date, p_to_date date, p_limit integer DEFAULT 45)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  today_utc date := (now() at time zone 'UTC')::date;
  slots integer;
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

  slots := futbeat_private.calendar_ingest_slots_left();
  if slots = 0 then
    return '[]'::jsonb;
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
        and d::date not in (select futbeat_private.calendar_dates_resting())
        and (
          c.provider_date is null
          or case
            when d::date < today_utc - 1
              then c.fetched_at < ((d::date + 2)::timestamp at time zone 'UTC')
            when d::date <= today_utc + 3
              then c.fetched_at < now() - interval '1 day'
            when d::date <= today_utc + 14
              then c.fetched_at < now() - interval '3 days'
            when d::date <= today_utc + 45
              then c.fetched_at < now() - interval '7 days'
            else c.fetched_at < now() - interval '21 days'
          end
        )
    ) candidates
    order by priority,sort_distance
    limit least(p_limit,slots)
  ) picked;

  return result;
end;
$function$;

create or replace function futbeat_private.futbeat_requested_calendar_dates(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_result jsonb;
  slots integer;
begin
  if p_limit<1 or p_limit>45 then
    raise exception 'Invalid calendar request limit';
  end if;

  -- BE-229: a request nobody repeated in three days is not a demand any more.
  delete from futbeat_private.calendar_date_requests
  where last_requested_at<now()-interval '3 days';

  delete from futbeat_private.calendar_date_requests r
  using futbeat_private.calendar_coverage c
  where c.provider=r.provider and c.provider_date=r.provider_date
    and c.fetched_at>=r.last_requested_at;

  slots:=futbeat_private.calendar_ingest_slots_left();
  if slots=0 then
    return '[]'::jsonb;
  end if;

  select coalesce(
    jsonb_agg(to_char(provider_date,'YYYY-MM-DD') order by last_requested_at desc,provider_date),
    '[]'::jsonb
  ) into v_result
  from (
    select provider_date,last_requested_at
    from futbeat_private.calendar_date_requests
    where provider='goal_api'
      and provider_date not in (select futbeat_private.calendar_dates_resting())
    order by last_requested_at desc,provider_date
    limit least(p_limit,slots)
  ) requested;

  return v_result;
end
$function$;

revoke all on function futbeat_private.calendar_ingest_slots_left() from public,anon,authenticated,service_role;
revoke all on function futbeat_private.calendar_dates_resting() from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_requested_calendar_dates(integer) from public,anon,authenticated,service_role;
