-- LOCAL CANDIDATE FOR CLAUDE REVIEW; not a migration or deployment command.
-- Only existing materialized payloads. Never build, enqueue, wake or touch zones.
create or replace function public.futbeat_read_qa_stored_calendar(
  p_local_date date, p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  select c.payload || jsonb_build_object('freshness', jsonb_build_object(
    'stale', c.expires_at <= now(), 'revalidating', false))
  from futbeat_private.compact_calendar_cache c
  where c.calendar_date=p_local_date and c.timezone=p_timezone
    and p_timezone='America/Costa_Rica'
$$;
revoke all on function public.futbeat_read_qa_stored_calendar(date,text) from public, anon, authenticated;
grant execute on function public.futbeat_read_qa_stored_calendar(date,text) to service_role;
-- Rollback: drop function public.futbeat_read_qa_stored_calendar(date,text);
