create table futbeat_private.user_preferences (
 user_id uuid primary key, detected_country text check(detected_country is null or detected_country~'^[A-Z]{2}$'),
 selected_country text check(selected_country is null or selected_country~'^[A-Z]{2}$'), updated_at timestamptz not null default now());
create table futbeat_private.temporary_interests (
 user_id uuid not null, entity_type text not null check(entity_type in ('team','player','competition','match')),
 entity_id text not null references futbeat_private.entities(id) on delete cascade, touched_at timestamptz not null default now(),
 expires_at timestamptz not null, primary key(user_id,entity_type,entity_id), check(expires_at>touched_at));
create table futbeat_private.coverage_interests (
 subject_type text not null check(subject_type in ('country','team','player','competition','match')), subject_id text not null,
 country_code text not null default '' check(country_code='' or country_code~'^[A-Z]{2}$'),
 explicit_followers int not null default 0 check(explicit_followers>=0), temporary_users int not null default 0 check(temporary_users>=0),
 selected_country_users int not null default 0 check(selected_country_users>=0), detected_country_users int not null default 0 check(detected_country_users>=0),
 priority_score int not null default 1 check(priority_score>0), depth text not null check(depth in ('BASE','DEEP','TEMPORARY')),
 last_updated_at timestamptz, next_refresh_at timestamptz not null default now(), calculated_at timestamptz not null default now(),
 primary key(subject_type,subject_id));
create index temporary_interests_expiry_idx on futbeat_private.temporary_interests(expires_at);
create index coverage_interests_due_idx on futbeat_private.coverage_interests(next_refresh_at,priority_score desc);
alter table futbeat_private.user_preferences enable row level security;
alter table futbeat_private.temporary_interests enable row level security;
alter table futbeat_private.coverage_interests enable row level security;
revoke all on futbeat_private.user_preferences,futbeat_private.temporary_interests,futbeat_private.coverage_interests from public;

alter table futbeat_private.push_follows drop constraint push_follows_entity_type_check;
alter table futbeat_private.push_follows add constraint push_follows_entity_type_check
 check(entity_type in ('team','player','competition','match'));

create function futbeat_private.refresh_interest_aggregates() returns void
language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtext('futbeat-interest-aggregates'));
 delete from futbeat_private.temporary_interests where expires_at<=now();
 delete from futbeat_private.coverage_interests;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,country_code,selected_country_users,
  detected_country_users,priority_score,depth,next_refresh_at,calculated_at)
 select 'country',country_code,country_code,count(*) filter(where source='selected'),
  count(*) filter(where source='detected'),
  case when count(*) filter(where source='selected')>0 then 100000+least(count(*) filter(where source='selected'),9999)
   else 10000+least(count(*),999) end,
  'BASE',now()+interval '12 hours',now()
 from (select selected_country country_code,'selected' source from futbeat_private.user_preferences where selected_country is not null
  union all select detected_country,'detected' from futbeat_private.user_preferences where selected_country is null and detected_country is not null) c
 group by country_code;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,explicit_followers,temporary_users,
  priority_score,depth,next_refresh_at,calculated_at)
 select entity_type,entity_id,explicit_followers,temporary_users,
  case when explicit_followers>0 then 1000000+least(explicit_followers,99999) else 1000+least(temporary_users,999) end,
  case when explicit_followers>0 then 'DEEP' else 'TEMPORARY' end,
  now()+case when entity_type='match' then interval '2 minutes' when explicit_followers>0 then interval '1 hour' else interval '15 minutes' end,now()
 from (select coalesce(f.entity_type,t.entity_type) entity_type,coalesce(f.entity_id,t.entity_id) entity_id,
  count(distinct f.user_id)::int explicit_followers,count(distinct t.user_id)::int temporary_users
  from futbeat_private.push_follows f full join futbeat_private.temporary_interests t
   on t.entity_type=f.entity_type and t.entity_id=f.entity_id and t.expires_at>now()
  group by coalesce(f.entity_type,t.entity_type),coalesce(f.entity_id,t.entity_id)) i;
 insert into futbeat_private.coverage_interests(subject_type,subject_id,country_code,priority_score,depth,next_refresh_at)
 values('country','CR','CR',10000,'BASE',now()+interval '12 hours') on conflict(subject_type,subject_id) do nothing;
end $$;

create function futbeat_private.sync_user_preferences(p_detected text,p_selected text) returns void
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid();
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 p_detected:=nullif(upper(trim(p_detected)),''); p_selected:=nullif(upper(trim(p_selected)),'');
 if (p_detected is not null and p_detected!~'^[A-Z]{2}$') or (p_selected is not null and p_selected!~'^[A-Z]{2}$')
  then raise exception 'Invalid country'; end if;
 insert into futbeat_private.user_preferences values(uid,p_detected,p_selected,now())
 on conflict(user_id) do update set detected_country=excluded.detected_country,selected_country=excluded.selected_country,updated_at=now();
 perform futbeat_private.refresh_interest_aggregates();
end $$;
create function futbeat_private.touch_temporary_interest(p_type text,p_id text,p_ttl_minutes int default 30) returns void
language plpgsql security definer set search_path='' as $$
declare uid uuid:=auth.uid(); expiry timestamptz;
begin
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_type not in ('team','player','competition','match') or not exists(
  select 1 from futbeat_private.entities where id=p_id and kind=p_type) then raise exception 'Unknown canonical entity'; end if;
 expiry:=now()+make_interval(mins=>least(greatest(p_ttl_minutes,5),120));
 insert into futbeat_private.temporary_interests values(uid,p_type,p_id,now(),expiry)
 on conflict(user_id,entity_type,entity_id) do update set touched_at=now(),expires_at=expiry;
 perform futbeat_private.refresh_interest_aggregates();
end $$;

create or replace function futbeat_private.sync_push_follows(p_follows jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare uid uuid; item jsonb;
begin
 uid:=auth.uid(); if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if jsonb_typeof(p_follows) is distinct from 'array' or jsonb_array_length(p_follows)>500 then raise exception 'Invalid follows'; end if;
 perform pg_advisory_xact_lock(hashtext('push-follows:'||uid::text));
 delete from futbeat_private.push_follows f where f.user_id=uid and not exists(
  select 1 from jsonb_array_elements(p_follows) e where e->>'type'=f.entity_type and e->>'id'=f.entity_id);
 for item in select value from jsonb_array_elements(p_follows) loop
  if item->>'type' in ('team','player','competition','match') and exists(
   select 1 from futbeat_private.entities where id=item->>'id' and kind=item->>'type') then
   insert into futbeat_private.push_follows values(uid,item->>'type',item->>'id',now()) on conflict do nothing;
  end if;
 end loop;
 perform futbeat_private.refresh_interest_aggregates();
end $$;

create function public.futbeat_sync_user_preferences(p_detected text,p_selected text) returns void
language sql security invoker set search_path='' as $$select futbeat_private.sync_user_preferences(p_detected,p_selected)$$;
create function public.futbeat_touch_temporary_interest(p_type text,p_id text,p_ttl_minutes int default 30) returns void
language sql security invoker set search_path='' as $$select futbeat_private.touch_temporary_interest(p_type,p_id,p_ttl_minutes)$$;
create function public.futbeat_interest_plan(p_limit int default 100) returns jsonb
language sql stable security invoker set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(i) order by i.priority_score desc,i.next_refresh_at),'[]')
 from (select * from futbeat_private.coverage_interests where next_refresh_at<=now()
 order by priority_score desc,next_refresh_at limit least(greatest(p_limit,1),500)) i$$;

create function public.futbeat_resolve_country_entity(p_provider text,p_kind text,p_external text) returns text
language plpgsql security invoker set search_path='' as $$
declare result text;
begin
 if p_provider<>'thesportsdb' or p_kind not in ('competition','team','match') or nullif(p_external,'') is null
  then raise exception 'Invalid provider identity'; end if;
 select canonical_id into result from futbeat_private.provider_entities
  where provider=p_provider and kind=p_kind and external_id=p_external;
 if result is null then
  result:='fb_'||p_kind||'_'||replace(gen_random_uuid()::text,'-','');
  insert into futbeat_private.entities(id,kind,payload) values(result,p_kind,jsonb_build_object('id',result));
  insert into futbeat_private.provider_entities values(p_provider,p_kind,p_external,result);
 end if;
 return result;
end $$;
create function public.futbeat_store_country_snapshot(p_job_id uuid,p_received_at timestamptz,p_raw jsonb,p_snapshot jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare item jsonb; merged jsonb;
begin
 if p_snapshot->>'demo'<>'false' or p_snapshot->>'schemaVersion'<>'1' or
  jsonb_typeof(p_snapshot->'competitions')<>'array' or jsonb_typeof(p_snapshot->'teams')<>'array' or
  jsonb_typeof(p_snapshot->'matches')<>'array' then raise exception 'Invalid country snapshot'; end if;
 if exists(select 1 from jsonb_array_elements(p_snapshot->'competitions') c where c->>'country'<>'Costa Rica')
  then raise exception 'Unexpected country'; end if;
 if exists(select 1 from futbeat_private.imports where job_id=p_job_id) then return '{"duplicate":true}'::jsonb; end if;
 if exists(select 1 from futbeat_private.imports where received_at>=p_received_at) then raise exception 'Out-of-order import'; end if;
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
  'competitions',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='competition'),
  'teams',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='team'),
  'matches',(select coalesce(jsonb_agg(payload order by id),'[]') from futbeat_private.entities where kind='match'));
 insert into futbeat_private.imports(job_id,received_at,raw_payload,snapshot) values(p_job_id,p_received_at,p_raw,merged);
 update futbeat_private.coverage_interests set last_updated_at=p_received_at,next_refresh_at=p_received_at+interval '12 hours'
  where subject_type='country' and subject_id='CR';
 return jsonb_build_object('duplicate',false,'teams',jsonb_array_length(merged->'teams'),
  'matches',jsonb_array_length(merged->'matches'),'standings',jsonb_array_length(merged->'standings'));
end $$;

revoke all on function futbeat_private.refresh_interest_aggregates(),futbeat_private.sync_user_preferences(text,text),
 futbeat_private.touch_temporary_interest(text,text,int),public.futbeat_sync_user_preferences(text,text),
 public.futbeat_touch_temporary_interest(text,text,int),public.futbeat_interest_plan(int),
 public.futbeat_resolve_country_entity(text,text,text),public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) from public;
do $$ begin
 if exists(select 1 from pg_roles where rolname='authenticated') then
  grant execute on function futbeat_private.sync_user_preferences(text,text),futbeat_private.touch_temporary_interest(text,text,int),
   public.futbeat_sync_user_preferences(text,text),public.futbeat_touch_temporary_interest(text,text,int) to authenticated;
 end if;
 if exists(select 1 from pg_roles where rolname='service_role') then
  grant select on futbeat_private.coverage_interests to service_role;
  grant execute on function futbeat_private.refresh_interest_aggregates(),public.futbeat_interest_plan(int) to service_role;
  grant execute on function public.futbeat_resolve_country_entity(text,text,text),
   public.futbeat_store_country_snapshot(uuid,timestamptz,jsonb,jsonb) to service_role;
 end if;
end $$;
select futbeat_private.refresh_interest_aggregates();

do $$ declare command text; begin
 if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 command:=$job$
 select net.http_post(
  url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-country-sync',
  headers:=jsonb_build_object('Content-Type','application/json',
   'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='{}'::jsonb,timeout_milliseconds:=60000)
 where exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')
 and exists(select 1 from futbeat_private.coverage_interests
  where subject_type='country' and subject_id='CR' and next_refresh_at<=now());
 $job$;
 perform cron.schedule('futbeat-country-bootstrap','15 */12 * * *',command);
end $$;
