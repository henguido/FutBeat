-- Remaining match-entity writers: apply the same non-degradation merge as
-- futbeat_store_calendar_range (20260922230000_preserve_terminal_match_writes.sql).
-- Audit of every function writing futbeat_private.entities(kind='match'):
--   vulnerable (full payload overwrite, fixed here):
--     futbeat_store_country_snapshot   (country/regional sync)
--     futbeat_store_fixture_window     (API-Football fixtures sync)
--     futbeat_store_global_fixture_window (ESPN/SofaScore/GOAL global window)
--   already safe:
--     futbeat_store_calendar_range, reconcile_goal_results_local (prior migration);
--     finalize_goal_results_date (delegates to reconcile);
--     futbeat_resolve_country_entity / futbeat_resolve_global_entity (insert of
--       a brand-new {id} payload only, on conflict do nothing);
--     futbeat_register_entity_redirect (jsonb_set of team/competition ids and
--       metadata only, never status/score);
--     normalize_canonical_event_contract (normalizes events array only);
--     futbeat_index_calendar_match (writes calendar_matches, not payloads).
-- Only the match UPDATE statement changes in each function; validation,
-- ordering guards, imports snapshots and team/competition writes are verbatim.
-- Same precedence and reschedule rule; no provider calls, ledger or backfill.

create or replace function futbeat_private.futbeat_store_country_snapshot(
  p_job_id uuid,
  p_received_at timestamptz,
  p_raw jsonb,
  p_snapshot jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  item jsonb;
  merged jsonb;
  previous jsonb;
begin
  if p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
  then
    raise exception 'Invalid country snapshot';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'competitions') c
    where coalesce(c->>'country', '') not in ('Costa Rica', 'CONCACAF')
  ) then
    raise exception 'Unexpected country';
  end if;

  if exists(select 1 from futbeat_private.imports where job_id = p_job_id::text) then
    return '{"duplicate":true}'::jsonb;
  end if;

  if exists(select 1 from futbeat_private.imports where received_at >= p_received_at) then
    raise exception 'Out-of-order import';
  end if;

  select snapshot
    into previous
    from futbeat_private.imports
   order by received_at desc
   limit 1;

  previous := coalesce(
    previous,
    '{"competitions":[],"teams":[],"matches":[]}'::jsonb
  );

  for item in select value from jsonb_array_elements(p_snapshot->'competitions') loop
    update futbeat_private.entities
       set payload = item
     where id = item->>'id' and kind = 'competition';
  end loop;

  for item in select value from jsonb_array_elements(p_snapshot->'teams') loop
    update futbeat_private.entities
       set payload = item
     where id = item->>'id' and kind = 'team';
  end loop;

  for item in select value from jsonb_array_elements(p_snapshot->'matches') loop
    update futbeat_private.entities
       set payload = futbeat_private.merge_calendar_match_payload(payload, item)
     where id = item->>'id' and kind = 'match';
  end loop;

  merged := p_snapshot || jsonb_build_object(
    'competitions', (
      select coalesce(jsonb_agg(value order by value->>'id'), '[]')
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'competitions', '[]')) old
         where not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'competitions') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'competitions')
      ) scoped
    ),
    'teams', (
      select coalesce(jsonb_agg(value order by value->>'id'), '[]')
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'teams', '[]')) old
         where not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'teams') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'teams')
      ) scoped
    ),
    'matches', (
      select coalesce(jsonb_agg(value order by value->>'id'), '[]')
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'matches', '[]')) old
         where not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'matches') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'matches')
      ) scoped
    )
  );

  insert into futbeat_private.imports(job_id, received_at, raw_payload, snapshot)
  values(p_job_id::text, p_received_at, p_raw, merged);

  update futbeat_private.coverage_interests
     set last_updated_at = p_received_at,
         next_refresh_at = p_received_at + interval '12 hours'
   where subject_type = 'country' and subject_id = 'CR';

  return jsonb_build_object(
    'duplicate', false,
    'teams', jsonb_array_length(merged->'teams'),
    'matches', jsonb_array_length(merged->'matches'),
    'standings', jsonb_array_length(merged->'standings')
  );
end;
$$;

create or replace function futbeat_private.futbeat_store_fixture_window(
 p_job_id uuid,p_received_at timestamptz,p_from_date date,p_to_date date,
 p_raw jsonb,p_snapshot jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare item jsonb; previous jsonb; merged jsonb;
begin
 if p_from_date>p_to_date or p_snapshot->>'demo'<>'false' or
    p_snapshot->>'schemaVersion'<>'1' or
    jsonb_typeof(p_snapshot->'competitions')<>'array' or
    jsonb_typeof(p_snapshot->'teams')<>'array' or
    jsonb_typeof(p_snapshot->'matches')<>'array'
  then raise exception 'Invalid fixture snapshot'; end if;
 if exists(select 1 from futbeat_private.imports where job_id=p_job_id::text)
  then return '{"duplicate":true}'::jsonb; end if;
 if exists(select 1 from futbeat_private.imports where received_at>=p_received_at)
  then raise exception 'Out-of-order import'; end if;
 if exists(select 1 from jsonb_array_elements(p_snapshot->'matches') m
   where m->'provenance'->>'source'<>'API-Football')
  then raise exception 'Unexpected fixture source'; end if;

 select snapshot into previous from futbeat_private.imports order by received_at desc limit 1;
 previous:=coalesce(previous,'{"competitions":[],"teams":[],"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}'::jsonb);
 for item in select value from jsonb_array_elements(p_snapshot->'competitions') loop
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='competition';
 end loop;
 for item in select value from jsonb_array_elements(p_snapshot->'teams') loop
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='team';
 end loop;
 for item in select value from jsonb_array_elements(p_snapshot->'matches') loop
  update futbeat_private.entities
   set payload=futbeat_private.merge_calendar_match_payload(payload,item)
   where id=item->>'id' and kind='match';
 end loop;

 merged:=p_snapshot||jsonb_build_object(
  'coverage',jsonb_build_object('source','TheSportsDB + API-Football','partial',true,'live',true,
   'description','Calendario compartido en hora de Costa Rica; cobertura según proveedor',
   'sources',jsonb_build_array('TheSportsDB','API-Football')),
  'competitions',(select coalesce(jsonb_agg(value order by value->>'country',value->>'name'),'[]') from (
   select value from jsonb_array_elements(coalesce(previous->'competitions','[]')) old
    where not exists(select 1 from jsonb_array_elements(p_snapshot->'competitions') new where new->>'id'=old.value->>'id')
   union all select value from jsonb_array_elements(p_snapshot->'competitions')) x),
  'teams',(select coalesce(jsonb_agg(value order by value->>'name'),'[]') from (
   select value from jsonb_array_elements(coalesce(previous->'teams','[]')) old
    where not exists(select 1 from jsonb_array_elements(p_snapshot->'teams') new where new->>'id'=old.value->>'id')
   union all select value from jsonb_array_elements(p_snapshot->'teams')) x),
  'players',coalesce(previous->'players','[]'),
  'matches',(select coalesce(jsonb_agg(value order by value->>'startTime',value->>'id'),'[]') from (
   select value from jsonb_array_elements(coalesce(previous->'matches','[]')) old
    where not (
      old.value->'provenance'->>'source'='API-Football' and
      (old.value->>'startTime')::timestamptz >= (p_from_date::timestamp at time zone 'America/Costa_Rica') and
      (old.value->>'startTime')::timestamptz < ((p_to_date+1)::timestamp at time zone 'America/Costa_Rica')
    ) and not exists(select 1 from jsonb_array_elements(p_snapshot->'matches') new where new->>'id'=old.value->>'id')
   union all select value from jsonb_array_elements(p_snapshot->'matches')) x),
  'standings',coalesce(previous->'standings','[]'),
  'news',coalesce(previous->'news','[]'),
  'transfers',coalesce(previous->'transfers','[]'));
 insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot)
  values(p_job_id::text,p_received_at,p_raw,merged);
 return jsonb_build_object('duplicate',false,
  'competitions',jsonb_array_length(merged->'competitions'),
  'teams',jsonb_array_length(merged->'teams'),
  'matches',jsonb_array_length(merged->'matches'));
end $$;

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

  -- Never degrade stored terminal evidence of the same fixture.
  update futbeat_private.entities e
  set payload=futbeat_private.merge_calendar_match_payload(e.payload,x.item)
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  where e.id=x.item->>'id'
    and e.kind='match'
    and e.payload is distinct from
      futbeat_private.merge_calendar_match_payload(e.payload,x.item);

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

-- No cache bump: definitions only; real entity writes keep invalidating
-- exactly their dates through the existing triggers.
notify pgrst,'reload schema';
