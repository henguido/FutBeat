-- Calendar snapshots served from cache for every day, plus a background warmer.
--
-- Root causes fixed (measured locally: cache hit ~18 ms vs rebuild ~300 ms):
--   * any civil day touching UTC today (local today AND yesterday in offset
--     timezones) bypassed the cache and was rebuilt on EVERY request;
--   * future days were cached for 10 s only: the "clock-driven" guard
--     matched every future kickoff (startTime > now()-30min);
--   * nothing prepared the days around today before users opened them.
--
-- Now (TTLs in provider_quota_policy.freshness):
--   * days touching UTC today are cached too, on a short TTL:
--     calendarLiveSeconds when a match is live or within its kickoff window,
--     else calendarTodaySeconds. UTC today stays unversioned on purpose: every
--     live ingest would otherwise update one hot version row (lock waits,
--     cross-midnight deadlocks); live scores reach the app through realtime;
--   * versioned past days: 1 day when results are complete, else
--     calendarHistoryIncompleteMinutes; data changes bump the day's version;
--   * versioned future days: calendarFutureHours (data changes bump the
--     version) and still expire before entering the UTC-today window;
--   * any day with a live/imminent match: calendarLiveSeconds.
-- One rebuild per (date, timezone) under an advisory lock; multi-day ranges
-- are unchanged. The request path never calls the provider.
--
-- futbeat_warm_calendar_window builds missing/expired snapshots around today
-- (today first, then alternating +/- days) for the timezones readers actually
-- used recently, bounded per call. DB-only work; no provider calls.

update futbeat_private.provider_quota_policy set
  freshness=freshness||'{"calendarLiveSeconds":15,"calendarTodaySeconds":60,
    "calendarHistoryIncompleteMinutes":10,"calendarFutureHours":6,
    "calendarWarmBackDays":2,"calendarWarmForwardDays":7,"calendarWarmBatch":3}',
  updated_at=now()
where provider='goal_api';

insert into futbeat_private.runtime_settings(key,value)
values('default_calendar_timezone','America/Costa_Rica')
on conflict(key) do nothing;

create or replace function public.futbeat_read_calendar_range(
 p_from_date date,p_to_date date,p_timezone text default 'America/Costa_Rica')
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare v_version text; v_payload jsonb; v_expiry timestamptz; v_today date;
 v_utc_today date; v_first_utc date; v_last_utc date; v_unversioned boolean; v_live boolean;
 live_ttl interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarLiveSeconds',15));
begin
 if p_from_date is null or p_to_date is null or p_from_date>p_to_date
   or p_to_date-p_from_date>31 or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone) then
   raise exception 'Invalid calendar range';
 end if;
 if p_from_date<>p_to_date then
   return futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 end if;
 v_today:=(now() at time zone p_timezone)::date;
 v_utc_today:=(now() at time zone 'UTC')::date;
 v_first_utc:=(p_from_date::timestamp at time zone p_timezone at time zone 'UTC')::date;
 v_last_utc:=(((p_to_date+1)::timestamp at time zone p_timezone-interval '1 microsecond') at time zone 'UTC')::date;
 -- Days touching UTC today are unversioned: served from a short-TTL snapshot.
 v_unversioned:=v_utc_today between v_first_utc and v_last_utc;
 v_version:=futbeat_private.calendar_cache_version(p_from_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_from_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 -- One rebuild per date/timezone; version is read AFTER the lock, before building.
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('calendar:'||p_from_date||':'||p_timezone,0));
 v_version:=futbeat_private.calendar_cache_version(p_from_date,p_timezone);
 select payload into v_payload from futbeat_private.compact_calendar_cache
   where calendar_date=p_from_date and timezone=p_timezone and version=v_version and expires_at>now();
 if found then return v_payload; end if;
 v_payload:=futbeat_private.build_compact_calendar(p_from_date,p_to_date,p_timezone);
 -- Clock-driven transitions (LIVE expiry, kickoff/evidence grace) only exist
 -- around live or imminent matches.
 v_live:=exists(select 1 from jsonb_array_elements(v_payload->'matches') m
   where m->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     or (m->>'startTime')::timestamptz between now()-interval '3 hours' and now()+interval '30 minutes');
 if v_unversioned then
   v_expiry:=now()+case when v_live then live_ttl
     else make_interval(secs=>futbeat_private.quota_setting('goal_api','calendarTodaySeconds',60)) end;
 elsif p_from_date<v_today then
   v_expiry:=now()+case when not (v_payload#>>'{coverage,partial}')::boolean
     and not exists(select 1 from futbeat_private.calendar_coverage c where c.provider='goal_api'
       and c.provider_date between v_first_utc and v_last_utc and not c.results_complete)
     then interval '1 day'
     else make_interval(mins=>futbeat_private.quota_setting('goal_api','calendarHistoryIncompleteMinutes',10)::integer) end;
 else
   v_expiry:=now()+make_interval(hours=>futbeat_private.quota_setting('goal_api','calendarFutureHours',6)::integer);
   -- Re-evaluated when the day enters the UTC-today (short TTL) window.
   v_expiry:=least(v_expiry,v_first_utc::timestamp at time zone 'UTC');
 end if;
 if v_live then v_expiry:=least(v_expiry,now()+live_ttl); end if;
 insert into futbeat_private.compact_calendar_cache values(p_from_date,p_timezone,v_version,v_payload,now(),v_expiry)
 on conflict(calendar_date,timezone) do update set version=excluded.version,payload=excluded.payload,
   built_at=excluded.built_at,expires_at=excluded.expires_at;
 -- Opportunistic bounded retention; no cron/provider work.
 delete from futbeat_private.compact_calendar_cache where built_at<now()-interval '30 days';
 return v_payload;
end $$;

create or replace function public.futbeat_warm_calendar_window(p_limit integer default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare lim integer:=greatest(1,least(coalesce(p_limit,
    futbeat_private.quota_setting('goal_api','calendarWarmBatch',3)::integer),14));
  back integer:=futbeat_private.quota_setting('goal_api','calendarWarmBackDays',2)::integer;
  forward integer:=futbeat_private.quota_setting('goal_api','calendarWarmForwardDays',7)::integer;
  tz text; offs integer; d date; built jsonb:='[]'; checked integer:=0; zones text[]; zone_builds integer;
begin
  -- Timezones readers actually used in the last day (bounded), else the default.
  -- Deterministic order (timezone tie-break): concurrent warmers lock dates alike.
  select coalesce(array_agg(timezone order by n desc,timezone),'{}') into zones from (
    select timezone,count(*) n from futbeat_private.compact_calendar_cache
    where built_at>now()-interval '1 day' group by timezone order by count(*) desc,timezone limit 3) z;
  if cardinality(zones)=0 then
    zones:=array[coalesce((select value from futbeat_private.runtime_settings where key='default_calendar_timezone'),'UTC')];
  end if;
  foreach tz in array zones loop
    if not exists(select 1 from pg_catalog.pg_timezone_names where name=tz) then continue; end if;
    -- Budget per timezone: one busy zone never starves the others.
    zone_builds:=0;
    -- today, +1, -1, +2, -2, ... within the window.
    for offs in select o from (
        select g o,abs(g)*2-case when g>0 then 1 else 0 end rank from generate_series(-back,forward) g) x
      order by rank loop
      exit when zone_builds>=lim;
      d:=(now() at time zone tz)::date+offs;
      checked:=checked+1;
      if exists(select 1 from futbeat_private.compact_calendar_cache c where c.calendar_date=d and c.timezone=tz
          and c.version=futbeat_private.calendar_cache_version(d,tz) and c.expires_at>now()+interval '5 seconds') then
        continue;
      end if;
      perform public.futbeat_read_calendar_range(d,d,tz);
      -- Count only real builds (a still-valid row is served, not rebuilt).
      if exists(select 1 from futbeat_private.compact_calendar_cache c
          where c.calendar_date=d and c.timezone=tz and c.built_at=now()) then
        built:=built||jsonb_build_array(jsonb_build_object('date',d,'timezone',tz));
        zone_builds:=zone_builds+1;
      end if;
    end loop;
  end loop;
  if jsonb_array_length(built)>0 then perform futbeat_private.bump_metric('calendar_warm_builds',jsonb_array_length(built)); end if;
  return jsonb_build_object('built',built,'checked',checked);
end $$;

revoke all on function public.futbeat_read_calendar_range(date,date,text) from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;
revoke all on function public.futbeat_warm_calendar_window(integer) from public,anon,authenticated;
grant execute on function public.futbeat_warm_calendar_window(integer) to service_role;

notify pgrst,'reload schema';
