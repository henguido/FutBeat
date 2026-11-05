-- BE-229: stale requests must not lead the calendar plan.
--
-- Production (2026-10-31): two requests from 09-24 stayed queued because their
-- dates were never stored. Oldest first put 2026-09-19 at the head of every plan:
-- 1,477 fixtures, 15 calls, then 57014, so no later date was fetched and no
-- coverage was written after 10-08. Requests now expire and the newest goes first.

create or replace function futbeat_private.futbeat_requested_calendar_dates(p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_result jsonb;
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

  select coalesce(
    jsonb_agg(to_char(provider_date,'YYYY-MM-DD') order by last_requested_at desc,provider_date),
    '[]'::jsonb
  ) into v_result
  from (
    select provider_date,last_requested_at
    from futbeat_private.calendar_date_requests
    where provider='goal_api'
    order by last_requested_at desc,provider_date
    limit p_limit
  ) requested;

  return v_result;
end
$function$;

revoke all on function futbeat_private.futbeat_requested_calendar_dates(integer) from public,anon,authenticated,service_role;
