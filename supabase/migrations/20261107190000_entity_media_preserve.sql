-- BE11-A3: team/competition media is never erased, emptied or stripped by a writer.
--
-- Evidence (production, read-only, 2026-11-07):
--   * futbeat_store_calendar_entities / futbeat_store_calendar_range /
--     futbeat_store_global_fixture_window replace entities.payload of teams and
--     competitions wholesale with the normalizer output.
--   * In calendar mode the ingest's `existing` is the compact calendar read
--     (futbeat_read_calendar_range -> build_compact_calendar), whose team and
--     competition media is only {url, verificationStatus}, and `{}` when the
--     stored media is JSON null (`item->'media' is null` is false for jsonb
--     'null'; jsonb_strip_nulls of {url:null,...} is `{}`). The normalizer
--     wrote that back: sample of 3,000 teams = 2,249 complete GOAL media,
--     609 JSON null, 126 {url,verificationStatus} without source/rights, 16 `{}`;
--     the last two groups have exactly the compact key set (no country/aliases).
--   * A normalizer item without a badge and without a previous entry carries
--     `media: null` and erased a stored image.
-- Rule (futbeat_private.entity_payload_media, also used by the new BEFORE
-- trigger for every writer, kind team/competition only):
--   * new media with an https url wins, except when the stored media has the
--     same url, is complete (source + rightsStatus) and the new one is lossy or
--     differs only in receivedAt: then the stored one is kept (no
--     receivedAt-only rewrite, no catalog/calendar cache bump);
--   * new media unusable ({} / null / no https url) and stored media usable:
--     the stored media is kept;
--   * neither usable: the media key is removed (no `{}` / null stored).
-- The two calendar stores compare against the merged payload, so an ingest
-- that brings nothing new writes nothing. Bodies are the production
-- definitions (2026-11-07, identical to the repository modulo whitespace)
-- with only the team/competition upserts changed.
-- Not applied. Rollback: supabase/manual/20261107190000_entity_media_preserve_rollback.sql.

create or replace function futbeat_private.usable_entity_media(p_media jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p_media)='object'
    and jsonb_typeof(p_media->'url')='string'
    and (p_media->>'url') like 'https://%',false)
$$;

create or replace function futbeat_private.entity_payload_media(p_old jsonb, p_new jsonb)
returns jsonb language sql immutable set search_path='' as $$
  select case
    when p_new is null or jsonb_typeof(p_new)<>'object' then p_new
    when futbeat_private.usable_entity_media(p_new->'media') then
      case when futbeat_private.usable_entity_media(p_old->'media')
          and p_old#>>'{media,url}'=p_new#>>'{media,url}'
          and p_old->'media' ? 'source' and p_old->'media' ? 'rightsStatus'
          and (not (p_new->'media' ? 'source' and p_new->'media' ? 'rightsStatus')
            or (p_old->'media')-'receivedAt'=(p_new->'media')-'receivedAt')
        then jsonb_set(p_new,'{media}',p_old->'media',true)
        else p_new end
    when futbeat_private.usable_entity_media(p_old->'media')
      then jsonb_set(p_new,'{media}',p_old->'media',true)
    else p_new-'media'
  end
$$;

create or replace function futbeat_private.preserve_entity_media()
returns trigger language plpgsql set search_path='' as $$
begin
  new.payload:=futbeat_private.entity_payload_media(
    case when TG_OP='UPDATE' and old.kind=new.kind then old.payload end,new.payload);
  return new;
end $$;

drop trigger if exists futbeat_preserve_entity_media on futbeat_private.entities;
create trigger futbeat_preserve_entity_media before insert or update of payload
on futbeat_private.entities for each row when (new.kind in ('team','competition'))
execute function futbeat_private.preserve_entity_media();

revoke all on function futbeat_private.usable_entity_media(jsonb) from public;
revoke all on function futbeat_private.entity_payload_media(jsonb,jsonb) from public;
revoke all on function futbeat_private.preserve_entity_media() from public;

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
  on conflict(id) do update set payload=futbeat_private.entity_payload_media(e.payload,excluded.payload)
    where e.kind='competition' and e.payload is distinct from futbeat_private.entity_payload_media(e.payload,excluded.payload);
  get diagnostics v_competitions=row_count;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update set payload=futbeat_private.entity_payload_media(e.payload,excluded.payload)
    where e.kind='team' and e.payload is distinct from futbeat_private.entity_payload_media(e.payload,excluded.payload);
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
    set payload=futbeat_private.entity_payload_media(e.payload,excluded.payload)
    where e.kind='competition'
      and e.payload is distinct from futbeat_private.entity_payload_media(e.payload,excluded.payload);

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update
    set payload=futbeat_private.entity_payload_media(e.payload,excluded.payload)
    where e.kind='team'
      and e.payload is distinct from futbeat_private.entity_payload_media(e.payload,excluded.payload);

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

notify pgrst,'reload schema';
