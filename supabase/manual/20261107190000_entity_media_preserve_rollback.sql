-- Rollback of 20261107190000_entity_media_preserve.sql (verbatim production
-- bodies of 2026-11-07, captured read-only with pg_get_functiondef).
-- Data written while the trigger was active stays as written (it only kept or
-- restored media); nothing to undo in rows.

drop trigger if exists futbeat_preserve_entity_media on futbeat_private.entities;

CREATE OR REPLACE FUNCTION futbeat_private.futbeat_store_calendar_entities(p_provider text, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_competitions integer; v_teams integer; v_matches integer;
begin
  if p_provider <> 'goal_api'
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
     or jsonb_array_length(p_snapshot->'matches') > 500
  then
    raise exception 'Invalid calendar entity batch';
  end if;
  if exists(select 1 from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' is distinct from 'GOAL API') then
    raise exception 'Unexpected calendar fixture source';
  end if;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','competition',item from jsonb_array_elements(p_snapshot->'competitions') x(item)
  on conflict(id) do update set payload=excluded.payload
    where e.kind='competition' and e.payload is distinct from excluded.payload;
  get diagnostics v_competitions=row_count;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update set payload=excluded.payload
    where e.kind='team' and e.payload is distinct from excluded.payload;
  get diagnostics v_teams=row_count;

  -- Never degrade stored terminal evidence of the same fixture (same merge as the date store).
  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','match',item from jsonb_array_elements(p_snapshot->'matches') x(item)
  on conflict(id) do update
    set payload=futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload)
    where e.kind='match'
      and e.payload is distinct from
        futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload);
  get diagnostics v_matches=row_count;

  return jsonb_build_object('competitions',v_competitions,'teams',v_teams,'matches',v_matches);
end $function$;

CREATE OR REPLACE FUNCTION futbeat_private.futbeat_store_calendar_range(p_provider text, p_received_at timestamp with time zone, p_coverage jsonb, p_snapshot jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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

  -- Never degrade stored terminal evidence of the same fixture.
  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','match',item
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  on conflict(id) do update
    set payload=futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload)
    where e.kind='match'
      and e.payload is distinct from
        futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload);

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
$function$;

drop function if exists futbeat_private.preserve_entity_media();
drop function if exists futbeat_private.entity_payload_media(jsonb,jsonb);
drop function if exists futbeat_private.usable_entity_media(jsonb);

notify pgrst,'reload schema';
