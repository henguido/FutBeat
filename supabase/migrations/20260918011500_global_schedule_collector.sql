-- Central global schedule collector.
-- SofaScore is used as a development-only discovery source; mobile clients never call it directly.

create or replace function futbeat_private.futbeat_identity_key(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
    translate(lower(coalesce(p_value,'')), 'áéíóúüñç', 'aeiouunc'),
    '[^a-z0-9]+', '', 'g'
  )
$$;

create or replace function futbeat_private.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text,
  p_country text default '',
  p_short_name text default ''
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result text;
  v_candidates text[];
  v_name_key text := futbeat_private.futbeat_identity_key(p_name);
  v_country_key text := futbeat_private.futbeat_identity_key(p_country);
  v_short_key text := futbeat_private.futbeat_identity_key(p_short_name);
begin
  if p_provider <> 'sofascore'
     or p_kind not in ('competition','team')
     or nullif(btrim(p_external),'') is null
     or nullif(btrim(p_name),'') is null
  then
    raise exception 'Invalid global provider identity';
  end if;

  select canonical_id into v_result
  from futbeat_private.provider_entities
  where provider = p_provider
    and kind = p_kind
    and external_id = p_external;

  if v_result is not null then
    return v_result;
  end if;

  select array_agg(e.id order by e.id)
    into v_candidates
  from futbeat_private.entities e
  where e.kind = p_kind
    and (
      futbeat_private.futbeat_identity_key(e.payload->>'name') = v_name_key
      or (
        v_short_key <> ''
        and futbeat_private.futbeat_identity_key(e.payload->>'shortName') = v_short_key
      )
      or exists (
        select 1
        from jsonb_array_elements_text(coalesce(e.payload->'aliases','[]'::jsonb)) alias(value)
        where futbeat_private.futbeat_identity_key(alias.value) in (v_name_key, v_short_key)
      )
    )
    and (
      p_kind <> 'team'
      or v_country_key = ''
      or futbeat_private.futbeat_identity_key(e.payload->>'country') in ('', v_country_key)
      or (
        v_short_key <> ''
        and futbeat_private.futbeat_identity_key(e.payload->>'shortName') = v_short_key
      )
    );

  if cardinality(v_candidates) = 1 then
    v_result := v_candidates[1];
  else
    v_result := 'fb_' || p_kind || '_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(v_result,p_kind,jsonb_build_object('id',v_result));
  end if;

  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values(p_provider,p_kind,p_external,v_result)
  on conflict (provider,kind,external_id)
  do update set canonical_id = excluded.canonical_id;

  return v_result;
end
$$;

create or replace function public.futbeat_resolve_global_entity(
  p_provider text,
  p_kind text,
  p_external text,
  p_name text,
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

create or replace function futbeat_private.futbeat_resolve_global_match(
  p_provider text,
  p_external text,
  p_home_team text,
  p_away_team text,
  p_start_time timestamptz
) returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result text;
  v_candidates text[];
begin
  if p_provider <> 'sofascore'
     or nullif(btrim(p_external),'') is null
     or nullif(btrim(p_home_team),'') is null
     or nullif(btrim(p_away_team),'') is null
     or p_home_team = p_away_team
     or p_start_time is null
  then
    raise exception 'Invalid global match identity';
  end if;

  select canonical_id into v_result
  from futbeat_private.provider_entities
  where provider = p_provider
    and kind = 'match'
    and external_id = p_external;

  if v_result is not null then
    return v_result;
  end if;

  select array_agg(e.id order by e.id)
    into v_candidates
  from futbeat_private.entities e
  where e.kind = 'match'
    and e.payload->>'homeTeamId' = p_home_team
    and e.payload->>'awayTeamId' = p_away_team
    and nullif(e.payload->>'startTime','') is not null
    and abs(extract(epoch from ((e.payload->>'startTime')::timestamptz - p_start_time))) <= 300;

  if cardinality(v_candidates) = 1 then
    v_result := v_candidates[1];
  else
    v_result := 'fb_match_' || replace(gen_random_uuid()::text,'-','');
    insert into futbeat_private.entities(id,kind,payload)
    values(v_result,'match',jsonb_build_object('id',v_result));
  end if;

  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values(p_provider,'match',p_external,v_result)
  on conflict (provider,kind,external_id)
  do update set canonical_id = excluded.canonical_id;

  return v_result;
end
$$;

create or replace function public.futbeat_resolve_global_match(
  p_provider text,
  p_external text,
  p_home_team text,
  p_away_team text,
  p_start_time timestamptz
) returns text
language sql
security definer
set search_path = ''
as $$
  select futbeat_private.futbeat_resolve_global_match(
    p_provider,p_external,p_home_team,p_away_team,p_start_time
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
  v_previous jsonb;
  v_merged jsonb;
  v_item jsonb;
  v_commit_at timestamptz := greatest(p_received_at, clock_timestamp());
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

  if exists (
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' <> 'SofaScore'
  ) then
    raise exception 'Unexpected global fixture source';
  end if;

  if exists(select 1 from futbeat_private.imports where job_id = p_job_id::text) then
    return '{"duplicate":true}'::jsonb;
  end if;

  perform pg_advisory_xact_lock(hashtext('futbeat-global-fixture-window'));
  select snapshot into v_previous
  from futbeat_private.imports
  order by received_at desc, job_id desc
  limit 1;

  v_previous := coalesce(
    v_previous,
    '{"competitions":[],"teams":[],"players":[],"matches":[],"standings":[],"news":[],"transfers":[]}'::jsonb
  );

  v_merged := p_snapshot || jsonb_build_object(
    'updatedAt', v_commit_at,
    'coverage', jsonb_build_object(
      'source','FutBeat Global',
      'partial',true,
      'live',coalesce((v_previous->'coverage'->>'live')::boolean,false),
      'developmentOnly',true,
      'description','Calendario global centralizado y cacheado por FutBeat; favoritos solo cambian el orden.',
      'sources',(
        select coalesce(jsonb_agg(source order by source),'[]'::jsonb)
        from (
          select distinct source
          from (
            select jsonb_array_elements_text(coalesce(v_previous->'coverage'->'sources','[]'::jsonb)) source
            union all
            select 'SofaScore'
          ) all_sources
        ) unique_sources
      )
    ),
    'competitions',(
      select coalesce(jsonb_agg(
        case
          when old_item is null then new_item
          when new_item is null then old_item
          when coalesce(old_item->'media','null'::jsonb) = 'null'::jsonb
               and coalesce(new_item->'media','null'::jsonb) <> 'null'::jsonb
            then jsonb_set(old_item,'{media}',new_item->'media',true)
          else old_item
        end
        order by coalesce(old_item,new_item)->>'country',
                 coalesce(old_item,new_item)->>'name'
      ),'[]'::jsonb)
      from (
        select old.value old_item, new.value new_item
        from jsonb_array_elements(coalesce(v_previous->'competitions','[]'::jsonb)) old
        full join jsonb_array_elements(p_snapshot->'competitions') new
          on new.value->>'id' = old.value->>'id'
      ) joined
    ),
    'teams',(
      select coalesce(jsonb_agg(
        case
          when old_item is null then new_item
          when new_item is null then old_item
          when coalesce(old_item->'media','null'::jsonb) = 'null'::jsonb
               and coalesce(new_item->'media','null'::jsonb) <> 'null'::jsonb
            then jsonb_set(old_item,'{media}',new_item->'media',true)
          else old_item
        end
        order by coalesce(old_item,new_item)->>'name'
      ),'[]'::jsonb)
      from (
        select old.value old_item, new.value new_item
        from jsonb_array_elements(coalesce(v_previous->'teams','[]'::jsonb)) old
        full join jsonb_array_elements(p_snapshot->'teams') new
          on new.value->>'id' = old.value->>'id'
      ) joined
    ),
    'players',coalesce(v_previous->'players','[]'::jsonb),
    'matches',(
      select coalesce(jsonb_agg(value order by value->>'startTime',value->>'id'),'[]'::jsonb)
      from (
        select old.value
        from jsonb_array_elements(coalesce(v_previous->'matches','[]'::jsonb)) old
        where not (
          old.value->'provenance'->>'source' = 'SofaScore'
          and (old.value->>'startTime')::timestamptz >=
              (p_from_date::timestamp at time zone 'America/Costa_Rica')
          and (old.value->>'startTime')::timestamptz <
              ((p_to_date + 1)::timestamp at time zone 'America/Costa_Rica')
        )
        and not exists (
          select 1
          from jsonb_array_elements(p_snapshot->'matches') new
          where new->>'id' = old.value->>'id'
        )
        union all
        select value from jsonb_array_elements(p_snapshot->'matches')
      ) all_matches
    ),
    'standings',coalesce(v_previous->'standings','[]'::jsonb),
    'news',coalesce(v_previous->'news','[]'::jsonb),
    'transfers',coalesce(v_previous->'transfers','[]'::jsonb)
  );

  for v_item in select value from jsonb_array_elements(v_merged->'competitions') loop
    update futbeat_private.entities
       set payload = v_item
     where id = v_item->>'id' and kind = 'competition';
  end loop;
  for v_item in select value from jsonb_array_elements(v_merged->'teams') loop
    update futbeat_private.entities
       set payload = v_item
     where id = v_item->>'id' and kind = 'team';
  end loop;
  for v_item in select value from jsonb_array_elements(v_merged->'matches') loop
    update futbeat_private.entities
       set payload = v_item
     where id = v_item->>'id' and kind = 'match';
  end loop;

  insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot)
  values(p_job_id::text,v_commit_at,p_raw,v_merged);

  return jsonb_build_object(
    'duplicate',false,
    'competitions',jsonb_array_length(v_merged->'competitions'),
    'teams',jsonb_array_length(v_merged->'teams'),
    'matches',jsonb_array_length(v_merged->'matches')
  );
end
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

revoke all on function futbeat_private.futbeat_identity_key(text) from public,anon,authenticated;
revoke all on function futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function public.futbeat_resolve_global_entity(text,text,text,text,text,text) from public,anon,authenticated;
revoke all on function futbeat_private.futbeat_resolve_global_match(text,text,text,text,timestamptz) from public,anon,authenticated;
revoke all on function public.futbeat_resolve_global_match(text,text,text,text,timestamptz) from public,anon,authenticated;
revoke all on function futbeat_private.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb) from public,anon,authenticated;
revoke all on function public.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb) from public,anon,authenticated;

grant execute on function public.futbeat_resolve_global_entity(text,text,text,text,text,text) to service_role;
grant execute on function public.futbeat_resolve_global_match(text,text,text,text,timestamptz) to service_role;
grant execute on function public.futbeat_store_global_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb) to service_role;

do $$
declare
  v_command text;
  v_job_id bigint;
begin
  if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then
    return;
  end if;

  select jobid into v_job_id from cron.job where jobname = 'futbeat-global-three-day';
  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  v_command := $job$
    select net.http_post(
      url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-global-sync',
      headers:=jsonb_build_object(
        'Content-Type','application/json',
        'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
        'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')
      ),
      body:='{}'::jsonb,
      timeout_milliseconds:=60000
    )
    where exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')
      and exists(select 1 from vault.secrets where name='futbeat_push_scheduler_token');
  $job$;

  perform cron.schedule('futbeat-global-three-day','17 * * * *',v_command);
end
$$;

notify pgrst,'reload schema';
