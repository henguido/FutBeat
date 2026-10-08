-- Finalize one calendar date ingested in sub-batches.
--
-- Production 2026-10-08 (runs #158/#159, futbeat-global-ingest v38): the
-- calendar date 2026-09-19 (1,477 GOAL fixtures) failed with 57014 under the
-- API role's 8 s statement timeout, first at read-current (8.6 s), then at
-- store (futbeat_store_calendar_range, 11.0 s). 2026-09-18 (430 fixtures)
-- stored in 6.0 s. The ingest now stores a large date in sub-batches with an
-- EMPTY coverage (adds/updates only: futbeat_store_calendar_range deletes
-- nothing and marks no date as covered), then calls this function once.
--
-- This function does the two coverage effects of futbeat_store_calendar_range
-- for ONE UTC date, against the full set of match ids of that date:
--   * deletes the GOAL calendar index rows of the date absent from the set;
--   * records the date's coverage (fetched_at, fixture_count).
-- Guard: every id of the set must already be indexed as a GOAL match inside
-- this exact provider date. Checking entities alone is insufficient: a match
-- entity may pre-exist for another date even when this sub-batch was not
-- stored. A failed/omitted sub-batch therefore cannot finalize coverage or
-- make matches disappear. Idempotent: the same set twice deletes nothing the
-- second time.
-- No provider call, no entity payload write.

create or replace function futbeat_private.futbeat_finalize_calendar_date(
  p_provider text,
  p_received_at timestamptz,
  p_date date,
  p_count integer,
  p_match_ids jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_ids text[];
  v_missing integer;
  v_deleted integer;
begin
  if p_provider <> 'goal_api'
     or p_received_at is null
     or p_date is null
     or p_count is null or p_count < 0
     or jsonb_typeof(p_match_ids) <> 'array'
     or jsonb_array_length(p_match_ids) > 5000
     or exists(
       select 1 from jsonb_array_elements(p_match_ids) x
       where jsonb_typeof(x) <> 'string' or btrim(x #>> '{}') = ''
     )
  then
    raise exception 'Invalid calendar date finalize payload';
  end if;

  select coalesce(array_agg(distinct x #>> '{}'), '{}'::text[])
    into v_ids
    from jsonb_array_elements(p_match_ids) x;

  select count(*) into v_missing
    from unnest(v_ids) u(match_id)
    where not exists(
      select 1 from futbeat_private.calendar_matches cm
      where cm.match_id = u.match_id
        and cm.source = 'GOAL API'
        and cm.start_time >= (p_date::timestamp at time zone 'UTC')
        and cm.start_time < ((p_date + 1)::timestamp at time zone 'UTC')
    );
  if v_missing > 0 then
    raise exception 'calendar finalize %: % match ids are not indexed for provider date', p_date, v_missing;
  end if;

  delete from futbeat_private.calendar_matches cm
  where cm.source = 'GOAL API'
    and cm.start_time >= (p_date::timestamp at time zone 'UTC')
    and cm.start_time < ((p_date + 1)::timestamp at time zone 'UTC')
    and not (cm.match_id = any(v_ids));
  get diagnostics v_deleted = row_count;

  insert into futbeat_private.calendar_coverage(
    provider, provider_date, fetched_at, fixture_count
  ) values (p_provider, p_date, p_received_at, p_count)
  on conflict(provider, provider_date) do update
  set fetched_at = excluded.fetched_at,
      fixture_count = excluded.fixture_count;

  return jsonb_build_object(
    'matches', cardinality(v_ids),
    'deleted', v_deleted,
    'coveredDates', 1
  );
end;
$$;

create or replace function public.futbeat_finalize_calendar_date(
  p_provider text,
  p_received_at timestamptz,
  p_date date,
  p_count integer,
  p_match_ids jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_finalize_calendar_date(
    p_provider, p_received_at, p_date, p_count, p_match_ids
  )
$$;

revoke all on function
  futbeat_private.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb),
  public.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb)
from public, anon, authenticated;

grant execute on function
  futbeat_private.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb),
  public.futbeat_finalize_calendar_date(text,timestamptz,date,integer,jsonb)
to service_role;

notify pgrst, 'reload schema';
