-- Central global fixture ingestion. Mobile clients remain read-only and no
-- competition allow-list is used here.

create or replace function futbeat_private.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text default '',
  p_country text default '',
  p_short_name text default ''
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  result text;
  matched text;
  matches integer;
begin
  if p_provider <> 'sofascore'
     or p_kind not in ('competition','team','match')
     or nullif(p_external,'') is null
  then
    raise exception 'Invalid global provider identity';
  end if;

  select canonical_id into result
    from futbeat_private.provider_entities
   where provider = p_provider
     and kind = p_kind
     and external_id = p_external;

  if result is not null then
    return result;
  end if;

  -- Reuse an existing canonical entity when names/short codes identify one
  -- unique entity. This prevents provider-specific duplicates such as LDA.
  if p_kind in ('competition','team') and nullif(p_name,'') is not null then
    select count(*), min(id)
      into matches, matched
      from futbeat_private.entities
     where kind = p_kind
       and (
         lower(coalesce(payload->>'name','')) = lower(p_name)
         or (
           nullif(p_short_name,'') is not null
           and lower(coalesce(payload->>'shortName','')) = lower(p_short_name)
         )
       )
       and (
         nullif(p_country,'') is null
         or nullif(payload->>'country','') is null
         or lower(payload->>'country') = lower(p_country)
       );

    if matches = 1 then
      result := matched;
    end if;
  end if;

  if result is null then
    result := 'fb_' || p_kind || '_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(
      result,
      p_kind,
      jsonb_build_object(
        'id', result,
        'name', coalesce(p_name,''),
        'country', coalesce(p_country,''),
        'shortName', coalesce(p_short_name,'')
      )
    )
    on conflict (id) do nothing;
  end if;

  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values(p_provider,p_kind,p_external,result)
  on conflict (provider,kind,external_id)
  do update set canonical_id = excluded.canonical_id;

  return result;
end;
$$;

create or replace function public.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text default '',
  p_country text default '',
  p_short_name text default ''
) returns text
language sql
security definer
set search_path = ''
as $$
  select futbeat_private.futbeat_resolve_global_entity(
    p_provider,p_kind,p_external,p_name,p_country,p_short_name
  )
$$;

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
set search_path = ''
as $$
declare
  item jsonb;
  previous jsonb;
  merged jsonb;
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
     where m->'provenance'->>'source' <> 'SofaScore'
  ) then
    raise exception 'Unexpected global fixture source';
  end if;

  if exists(select 1 from futbeat_private.imports where job_id = p_job_id::text) then
    return '{"duplicate":true}'::jsonb;
  end if;

  if exists(select 1 from futbeat_private.imports where received_at >= p_received_at) then
    raise exception 'Out-of-order import';
  end if;

  select snapshot into previous
    from futbeat_private.imports
   order by received_at desc, job_id desc
   limit 1;

  previous := coalesce(
    previous,
    '{"competitions":[],"teams":[],"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}'::jsonb
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
       set payload = item
     where id = item->>'id' and kind = 'match';
  end loop;

  merged := p_snapshot || jsonb_build_object(
    'coverage',
    jsonb_build_object(
      'source','FutBeat Global',
      'partial',true,
      'live',coalesce((previous->'coverage'->>'live')::boolean,false),
      'developmentOnly',true,
      'description','Calendario global centralizado; favoritos solo cambian el orden',
      'sources',jsonb_build_array('TheSportsDB','API-Football','SofaScore')
    ),
    'competitions',(
      select coalesce(jsonb_agg(value order by value->>'country',value->>'name'),'[]'::jsonb)
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'competitions','[]'::jsonb)) old
         where not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'competitions') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'competitions')
      ) x
    ),
    'teams',(
      select coalesce(jsonb_agg(value order by value->>'name'),'[]'::jsonb)
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'teams','[]'::jsonb)) old
         where not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'teams') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'teams')
      ) x
    ),
    'players',coalesce(previous->'players','[]'::jsonb),
    'matches',(
      select coalesce(jsonb_agg(value order by value->>'startTime',value->>'id'),'[]'::jsonb)
      from (
        select value
          from jsonb_array_elements(coalesce(previous->'matches','[]'::jsonb)) old
         where not (
           old.value->'provenance'->>'source' = 'SofaScore'
           and (old.value->>'startTime')::timestamptz >=
             (p_from_date::timestamp at time zone 'America/Costa_Rica')
           and (old.value->>'startTime')::timestamptz <
             ((p_to_date + 1)::timestamp at time zone 'America/Costa_Rica')
         )
         and not exists(
           select 1
             from jsonb_array_elements(p_snapshot->'matches') new
            where new->>'id' = old.value->>'id'
         )
        union all
        select value from jsonb_array_elements(p_snapshot->'matches')
      ) x
    ),
    'standings',coalesce(previous->'standings','[]'::jsonb),
    'news',coalesce(previous->'news','[]'::jsonb),
    'transfers',coalesce(previous->'transfers','[]'::jsonb)
  );

  insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot)
  values(p_job_id::text,p_received_at,p_raw,merged);

  return jsonb_build_object(
    'duplicate',false,
    'competitions',jsonb_array_length(merged->'competitions'),
    'teams',jsonb_array_length(merged->'teams'),
    'matches',jsonb_array_length(merged->'matches')
  );
end;
$$;

create or replace function public.futbeat_store_global_fixture_window(
  p_job_id uuid,
  p_received_at timestamptz,
  p_from_date date,
  p_to_date date,
  p_raw jsonb,
  p_snapshot jsonb
) returns jsonb
language sql
security definer
set search_path = ''
as $$
  select futbeat_private.futbeat_store_global_fixture_window(
    p_job_id,p_received_at,p_from_date,p_to_date,p_raw,p_snapshot
  )
$$;

revoke all on function
  futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text),
  public.futbeat_resolve_global_entity(text,text,text,text,text,text),
  futbeat_private.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb),
  public.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text),
  public.futbeat_resolve_global_entity(text,text,text,text,text,text),
  futbeat_private.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb),
  public.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb)
to service_role;

do $$
declare
  command text;
begin
  if to_regnamespace('cron') is null
     or to_regnamespace('net') is null
     or to_regnamespace('vault') is null
  then
    return;
  end if;

  command := $job$
    select net.http_post(
      url := 'https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-global-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer ' ||
          (select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
        'x-futbeat-scheduler',
          (select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    )
    where exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')
      and exists(select 1 from vault.secrets where name='futbeat_push_scheduler_token');
  $job$;

  perform cron.schedule('futbeat-global-fixtures','17 */3 * * *',command);
end;
$$;

notify pgrst,'reload schema';
