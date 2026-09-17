-- One shared, cached three-day fixture window. Mobile clients remain read-only.
create or replace function futbeat_private.futbeat_resolve_country_entity(
 p_provider text,p_kind text,p_external text
) returns text language plpgsql security definer set search_path='' as $$
declare result text;
begin
 if p_provider not in ('thesportsdb','api_football') or
    p_kind not in ('competition','team','match') or nullif(p_external,'') is null
  then raise exception 'Invalid provider identity'; end if;
 select canonical_id into result from futbeat_private.provider_entities
  where provider=p_provider and kind=p_kind and external_id=p_external;
 if result is null then
  result:='fb_'||p_kind||'_'||replace(gen_random_uuid()::text,'-','');
  insert into futbeat_private.entities(id,kind,payload)
   values(result,p_kind,jsonb_build_object('id',result));
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
   values(p_provider,p_kind,p_external,result);
 end if;
 return result;
end $$;

create or replace function public.futbeat_resolve_country_entity(
 p_provider text,p_kind text,p_external text
) returns text language sql security definer set search_path='' as $$
 select futbeat_private.futbeat_resolve_country_entity(p_provider,p_kind,p_external)
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
  update futbeat_private.entities set payload=item where id=item->>'id' and kind='match';
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

create or replace function public.futbeat_store_fixture_window(
 p_job_id uuid,p_received_at timestamptz,p_from_date date,p_to_date date,
 p_raw jsonb,p_snapshot jsonb
) returns jsonb language sql security definer set search_path='' as $$
 select futbeat_private.futbeat_store_fixture_window(
  p_job_id,p_received_at,p_from_date,p_to_date,p_raw,p_snapshot)
$$;

revoke all on function futbeat_private.futbeat_resolve_country_entity(text,text,text),
 public.futbeat_resolve_country_entity(text,text,text),
 futbeat_private.futbeat_store_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb),
 public.futbeat_store_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb)
 from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_resolve_country_entity(text,text,text),
 public.futbeat_resolve_country_entity(text,text,text),
 futbeat_private.futbeat_store_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb),
 public.futbeat_store_fixture_window(uuid,timestamptz,date,date,jsonb,jsonb)
 to service_role;

do $$ declare command text; begin
 if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 command:=$job$
 select net.http_post(
  url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-fixtures-sync',
  headers:=jsonb_build_object('Content-Type','application/json',
   'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='{}'::jsonb,timeout_milliseconds:=60000)
 where exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')
   and exists(select 1 from vault.secrets where name='futbeat_push_scheduler_token');
 $job$;
 perform cron.schedule('futbeat-fixtures-three-day-window','20 */6 * * *',command);
 perform cron.alter_job(
  (select jobid from cron.job where jobname='futbeat-fixtures-three-day-window'),
  active:=false);
end $$;

notify pgrst,'reload schema';
