alter table futbeat_private.entities drop constraint if exists entities_kind_check;
alter table futbeat_private.entities add constraint entities_kind_check check(kind in ('competition','team','match','player'));

-- Public rows contain only a canonical timeline; provider payloads stay private.
create table futbeat_private.canonical_events (
 id text primary key check(id like 'fb_event_%'),
 match_id text not null references futbeat_private.entities(id),
 provider text not null, event_type text not null, payload jsonb not null,
 notify_candidate boolean not null default false, first_seen_at timestamptz not null
);
create index canonical_events_match_idx on futbeat_private.canonical_events(match_id,first_seen_at);
create table futbeat_private.event_baselines(match_id text primary key references futbeat_private.entities(id));
create table futbeat_private.push_devices(
 id uuid primary key default gen_random_uuid(), user_id uuid not null,
 installation_id uuid not null, platform text not null check(platform in ('android','ios')),
 transport text not null check(transport in ('fcm','apns','test')),
 token text not null check(length(token) between 1 and 4096),
 enabled boolean not null default true, registered_at timestamptz not null default now(),
 unique(user_id,installation_id), unique(transport,token)
);
create index push_devices_user_idx on futbeat_private.push_devices(user_id);
create table futbeat_private.push_follows(
 user_id uuid not null, entity_type text not null check(entity_type in ('team','match')),
 entity_id text not null references futbeat_private.entities(id),
 created_at timestamptz not null default now(), primary key(user_id,entity_type,entity_id)
);
create index push_follows_entity_idx on futbeat_private.push_follows(entity_id);
create table futbeat_private.notification_outbox(
 id uuid primary key default gen_random_uuid(),
 event_id text not null references futbeat_private.canonical_events(id),
 device_id uuid not null references futbeat_private.push_devices(id),
 user_id uuid not null, message jsonb not null,
 state text not null default 'pending' check(state in ('pending','sending','sent','simulated','failed','uncertain','cancelled')),
 attempt_id uuid, attempt_at timestamptz, finished_at timestamptz, provider_receipt text,
 created_at timestamptz not null default now(),
 unique(event_id,user_id,device_id)
);
create index outbox_device_idx on futbeat_private.notification_outbox(device_id);
create index outbox_pending_idx on futbeat_private.notification_outbox(state,created_at);

do $$ declare t text; begin
 foreach t in array array['canonical_events','event_baselines','push_devices','push_follows','notification_outbox'] loop
  execute format('alter table futbeat_private.%I enable row level security',t);
  execute format('revoke all on futbeat_private.%I from public',t);
 end loop;
end $$;

create function futbeat_private.event_message(ev jsonb, m jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare label text; team text; home_name text; away_name text; title text;
begin
 label := case ev->>'type' when 'GOAL' then '⚽' when 'YELLOW_CARD' then '🟨'
 when 'RED_CARD' then '🟥' when 'SUBSTITUTION' then '🔄' when 'VAR' then '📺'
 when 'MISSED_PENALTY' then '❌' when 'KICKOFF' then '▶' when 'HALFTIME' then '⏸'
 when 'FULL_TIME' then '🏁' end;
 if label is null then return null; end if;
 select payload->>'name' into team from futbeat_private.entities where id=ev->>'teamId' and kind='team';
 title := label || case when ev->>'minute' is not null then ' '||(ev->>'minute')||chr(39) else '' end || ' ' ||
 case ev->>'type' when 'GOAL' then 'Gol' when 'YELLOW_CARD' then 'Tarjeta amarilla'
 when 'RED_CARD' then 'Tarjeta roja' when 'SUBSTITUTION' then 'Sustitución'
 when 'VAR' then 'VAR' when 'MISSED_PENALTY' then 'Penal fallado'
 when 'KICKOFF' then 'Inicio' when 'HALFTIME' then 'Medio tiempo' when 'FULL_TIME' then 'Final' end;
 if ev->>'type'='FULL_TIME' then
  select payload->>'name' into home_name from futbeat_private.entities where id=m->>'homeTeamId';
  select payload->>'name' into away_name from futbeat_private.entities where id=m->>'awayTeamId';
  title := '🏁 Final';
  if home_name is not null and away_name is not null and ev#>>'{score,home}' is not null and ev#>>'{score,away}' is not null then
   title:=title||' — '||home_name||' '||(ev#>>'{score,home}')||'-'||(ev#>>'{score,away}')||' '||away_name;
  end if;
 elsif team is not null then title:=title||' — '||team;
 end if;
 return jsonb_build_object('title',title,'eventId',ev->>'id','matchId',ev->>'matchId','type',ev->>'type');
end $$;

create function futbeat_private.store_canonical_event(ev jsonb,p_provider text,p_notify boolean,p_at timestamptz,m jsonb)
returns void language plpgsql security invoker set search_path='' as $$
declare inserted integer; msg jsonb;
begin
 insert into futbeat_private.canonical_events values(ev->>'id',ev->>'matchId',p_provider,ev->>'type',ev,p_notify,p_at)
 on conflict(id) do nothing;
 get diagnostics inserted=row_count;
 if inserted=0 or not p_notify then return; end if;
 msg:=futbeat_private.event_message(ev,m);
 if msg is null then return; end if;
 insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
 select ev->>'id',d.id,d.user_id,msg
 from futbeat_private.push_devices d
 where d.enabled and d.registered_at<=p_at and exists(
  select 1 from futbeat_private.push_follows f where f.user_id=d.user_id and f.created_at<=p_at and
  ((f.entity_type='match' and f.entity_id=ev->>'matchId') or
   (f.entity_type='team' and f.entity_id in (m->>'homeTeamId',m->>'awayTeamId'))))
 on conflict(event_id,user_id,device_id) do nothing;
end $$;

-- Keep existing durable change detection, including notifyCandidate, as the source.
alter function public.futbeat_record_live_batch(text,timestamptz,jsonb) set schema futbeat_private;
alter function futbeat_private.futbeat_record_live_batch(text,timestamptz,jsonb) rename to record_live_batch_core;

create function public.futbeat_record_live_batch(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
begin
 return futbeat_private.record_live_events(p_provider,p_received_at,p_observations);
end $$;

create function futbeat_private.record_live_events(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; c jsonb; m jsonb; mid text; e record; tid text; pid text; aid text;
 ev jsonb; eid text; can_notify boolean; baseline boolean; typ text; state futbeat_private.live_match_state;
begin
 -- Ignore delayed observations instead of regressing a live match.
 if exists(select 1 from jsonb_array_elements(p_observations) o
  join futbeat_private.live_match_state s on s.provider=p_provider and s.external_match_id=o->>'externalMatchId'
  where s.last_seen_at>p_received_at) then raise exception 'Stale live batch'; end if;
 result:=futbeat_private.record_live_batch_core(p_provider,p_received_at,p_observations);
 for c in select value from jsonb_array_elements(result->'changes') loop
  mid:=c->>'canonicalMatchId';
  if mid is null then continue; end if;
  select payload into m from futbeat_private.entities where id=mid and kind='match';
  if m is null then continue; end if;
  select exists(select 1 from futbeat_private.event_baselines where match_id=mid) into baseline;
  can_notify:=baseline and coalesce((c->>'notifyCandidate')::boolean,false);
  for e in select * from futbeat_private.live_events where provider=p_provider and external_match_id=c->>'externalMatchId' loop
   if e.event_type not in ('GOAL','YELLOW_CARD','RED_CARD','SUBSTITUTION','VAR','MISSED_PENALTY') then continue; end if;
   tid:=null; pid:=null; aid:=null;
   select canonical_id into tid from futbeat_private.provider_entities where provider=p_provider and kind='team' and external_id=e.team_external_id;
   if tid not in (m->>'homeTeamId',m->>'awayTeamId') then continue; end if;
   -- Unknown identity stays null; external IDs never masquerade as canonical IDs.
   select canonical_id into pid from futbeat_private.provider_entities where provider=p_provider and kind='player' and external_id=e.player_external_id;
   select canonical_id into aid from futbeat_private.provider_entities where provider=p_provider and kind='player'
     and external_id=coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}');
   eid:='fb_event_'||md5(concat_ws('|',mid,p_provider,e.event_type,e.minute,
     coalesce(e.payload->>'extraMinute',e.payload#>>'{payload,time,extra}'),
     e.team_external_id,e.player_external_id,
     case when e.event_type='SUBSTITUTION' then coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}') else '' end));
   ev:=jsonb_strip_nulls(jsonb_build_object('id',eid,'matchId',mid,'type',e.event_type,'minute',e.minute,
    'extraMinute',coalesce(e.payload->'extraMinute',e.payload#>'{payload,time,extra}'),
    'teamId',tid,'playerId',pid,'assistPlayerId',aid));
   perform futbeat_private.store_canonical_event(ev,p_provider,can_notify and e.first_seen_at=p_received_at,p_received_at,m);
  end loop;
  select * into state from futbeat_private.live_match_state where provider=p_provider and external_match_id=c->>'externalMatchId';
  typ:=case state.status when 'LIVE' then 'KICKOFF' when 'HALFTIME' then 'HALFTIME'
    when 'FINISHED_PENDING_VERIFICATION' then 'FULL_TIME' when 'VERIFIED' then 'FULL_TIME' end;
  if typ is not null and ((c->>'statusChanged')::boolean or (c->>'initial')::boolean) then
   ev:=jsonb_build_object('id','fb_event_'||md5(mid||'|'||typ),'matchId',mid,'type',typ,
    'minute',case when typ='KICKOFF' then 0 else state.minute end,
    'score',jsonb_build_object('home',state.home_score,'away',state.away_score));
   perform futbeat_private.store_canonical_event(ev,p_provider,can_notify,p_received_at,m);
  end if;
  insert into futbeat_private.event_baselines values(mid) on conflict do nothing;
  perform public.futbeat_publish_live_state(p_provider,c->>'externalMatchId');
 end loop;
 return result;
end $$;

create or replace function public.futbeat_publish_live_state(p_provider text,p_external_match_id text)
returns void language plpgsql security definer set search_path='' as $$
declare s futbeat_private.live_match_state; ev jsonb;
begin
 select * into s from futbeat_private.live_match_state where provider=p_provider and external_match_id=p_external_match_id;
 if not found or s.canonical_match_id is null then return; end if;
 select coalesce(jsonb_agg(payload order by coalesce((payload->>'minute')::int,0),id),'[]') into ev
 from futbeat_private.canonical_events where match_id=s.canonical_match_id and provider=p_provider;
 insert into public.live_match_updates(match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at)
 values(s.canonical_match_id,s.provider,s.external_match_id,s.status,s.minute,s.home_score,s.away_score,s.revision,jsonb_array_length(ev),ev,s.changed_at,now())
 on conflict(match_id) do update set provider=excluded.provider,external_match_id=excluded.external_match_id,
 status=excluded.status,minute=excluded.minute,home_score=excluded.home_score,away_score=excluded.away_score,
 revision=excluded.revision,event_count=excluded.event_count,latest_events=excluded.latest_events,
 changed_at=excluded.changed_at,updated_at=excluded.updated_at;
end $$;

-- Existing HTTP snapshot remains a complete fallback, with the same timeline.
create or replace function public.futbeat_read_snapshot() returns jsonb
language sql stable security invoker set search_path='' as $$
 select i.snapshot || jsonb_build_object('matches',
  (select coalesce(jsonb_agg(case when l.match_id is null then m else m || jsonb_build_object(
    'status',l.status,'minute',l.minute,'score',jsonb_build_object('home',l.home_score,'away',l.away_score),
    'events',l.latest_events,'liveRevision',l.revision,'liveProvider',l.provider,'liveChangedAt',l.changed_at) end),'[]')
   from jsonb_array_elements(i.snapshot->'matches') m left join public.live_match_updates l on l.match_id=m->>'id'),
  'freshness',jsonb_build_object('stale',i.received_at<now()-interval '6 hours'))
 from futbeat_private.imports i order by received_at desc,job_id desc limit 1
$$;

-- Session ownership is derived from a verified Auth JWT, never a supplied user ID.
create function public.futbeat_register_push(p_installation uuid,p_platform text,p_transport text,p_token text,p_enabled boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid; did uuid;
begin
 uid:=auth.uid();
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_transport='test' then raise exception 'Test devices are server-only'; end if;
 insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token,enabled)
 values(uid,p_installation,p_platform,p_transport,p_token,p_enabled)
 on conflict(user_id,installation_id) do update set token=excluded.token,enabled=excluded.enabled,platform=excluded.platform,transport=excluded.transport
 returning id into did;
 return did;
end $$;
create function public.futbeat_set_push_follow(p_type text,p_id text,p_follow boolean)
returns void language plpgsql security definer set search_path='' as $$
declare uid uuid;
begin
 uid:=auth.uid(); if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_type not in ('team','match') or not exists(select 1 from futbeat_private.entities where id=p_id and kind=p_type)
 then raise exception 'Unknown canonical entity'; end if;
 if p_follow then insert into futbeat_private.push_follows values(uid,p_type,p_id,now()) on conflict do nothing;
 else delete from futbeat_private.push_follows where user_id=uid and entity_type=p_type and entity_id=p_id; end if;
end $$;

create function public.futbeat_claim_notifications(p_mode text default 'dry_run',p_limit int default 20)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare row record; rows jsonb:='[]'; attempt uuid;
begin
 if p_mode not in ('dry_run','live') then raise exception 'Invalid mode'; end if;
 -- An expired send may have reached the provider. Never blindly retry it.
 update futbeat_private.notification_outbox set state='uncertain',finished_at=now()
 where state='sending' and attempt_at<now()-interval '5 minutes';
 for row in select o.*,d.transport,d.token,d.enabled,m.payload as match
 from futbeat_private.notification_outbox o join futbeat_private.push_devices d on d.id=o.device_id and d.user_id=o.user_id
 join futbeat_private.canonical_events e on e.id=o.event_id join futbeat_private.entities m on m.id=e.match_id
 where o.state='pending' and (p_mode='live' or d.transport='test')
 order by o.created_at for update of o skip locked limit least(greatest(p_limit,1),100) loop
  if not row.enabled or not exists(select 1 from futbeat_private.push_follows f where f.user_id=row.user_id and
   (f.entity_id=row.message->>'matchId' or f.entity_id in (row.match->>'homeTeamId',row.match->>'awayTeamId'))) then
   update futbeat_private.notification_outbox set state='cancelled',finished_at=now() where id=row.id; continue;
  end if;
  attempt:=gen_random_uuid();
  update futbeat_private.notification_outbox set state='sending',attempt_id=attempt,attempt_at=now() where id=row.id;
  rows:=rows||jsonb_build_array(jsonb_build_object('id',row.id,'attemptId',attempt,'transport',row.transport,'token',row.token,'message',row.message));
 end loop;
 return rows;
end $$;
create function public.futbeat_finish_notification(p_id uuid,p_attempt uuid,p_state text,p_receipt text default null)
returns boolean language plpgsql security invoker set search_path='' as $$
declare count_rows int;
begin
 if p_state not in ('sent','simulated','failed','uncertain') then raise exception 'Invalid terminal state'; end if;
 update futbeat_private.notification_outbox set state=p_state,finished_at=now(),provider_receipt=left(p_receipt,200)
 where id=p_id and attempt_id=p_attempt and state='sending';
 get diagnostics count_rows=row_count; return count_rows=1;
end $$;

-- Explicit allowlist: public clients cannot call ingestion or delivery RPCs.
do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='futbeat_private' and p.proname in ('record_live_events','record_live_batch_core','event_message','store_canonical_event'))
 or (n.nspname='public' and p.proname in ('futbeat_record_live_batch','futbeat_register_push','futbeat_set_push_follow','futbeat_claim_notifications','futbeat_finish_notification')) loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
 if exists(select 1 from pg_roles where rolname='service_role') then
  grant select on public.live_match_updates to service_role;
  grant select,update on futbeat_private.notification_outbox to service_role;
  grant select on futbeat_private.push_devices,futbeat_private.push_follows,futbeat_private.canonical_events,futbeat_private.entities to service_role;
  grant execute on function public.futbeat_record_live_batch(text,timestamptz,jsonb),futbeat_private.record_live_events(text,timestamptz,jsonb),
   public.futbeat_claim_notifications(text,int),public.futbeat_finish_notification(uuid,uuid,text,text) to service_role;
 end if;
 if exists(select 1 from pg_roles where rolname='authenticated') then
  grant execute on function public.futbeat_register_push(uuid,text,text,text,boolean),public.futbeat_set_push_follow(text,text,boolean) to authenticated;
 end if;
end $$;

-- Preserve every historical event while rebuilding the sanitized public projection.
do $$ declare s record; e record; mid text; m jsonb; tid text; pid text; aid text; eid text; ev jsonb; begin
 for s in select * from futbeat_private.live_match_state where canonical_match_id is not null loop
  mid:=s.canonical_match_id;
  select payload into m from futbeat_private.entities where id=mid and kind='match';
  if m is null then continue; end if;
  for e in select * from futbeat_private.live_events where provider=s.provider and external_match_id=s.external_match_id loop
   tid:=null;pid:=null;aid:=null;
   select canonical_id into tid from futbeat_private.provider_entities where provider=s.provider and kind='team' and external_id=e.team_external_id;
   if tid is not null and tid not in (m->>'homeTeamId',m->>'awayTeamId') then tid:=null; end if;
   select canonical_id into pid from futbeat_private.provider_entities where provider=s.provider and kind='player' and external_id=e.player_external_id;
   select canonical_id into aid from futbeat_private.provider_entities where provider=s.provider and kind='player'
    and external_id=coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}');
   eid:='fb_event_'||md5(concat_ws('|',mid,s.provider,e.event_type,e.minute,
    coalesce(e.payload->>'extraMinute',e.payload#>>'{payload,time,extra}'),e.team_external_id,e.player_external_id,
    case when e.event_type='SUBSTITUTION' then coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}') else '' end));
   ev:=jsonb_strip_nulls(jsonb_build_object('id',eid,'matchId',mid,'type',e.event_type,'minute',e.minute,
    'extraMinute',coalesce(e.payload->'extraMinute',e.payload#>'{payload,time,extra}'),'teamId',tid,'playerId',pid,'assistPlayerId',aid));
   perform futbeat_private.store_canonical_event(ev,s.provider,false,e.first_seen_at,m);
  end loop;
  insert into futbeat_private.event_baselines values(mid) on conflict do nothing;
  perform public.futbeat_publish_live_state(s.provider,s.external_match_id);
 end loop;
end $$;


create function futbeat_private.sync_push_follows(p_follows jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare uid uuid; item jsonb;
begin
 uid:=auth.uid(); if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if jsonb_typeof(p_follows) is distinct from 'array' or jsonb_array_length(p_follows)>500 then raise exception 'Invalid follows'; end if;
 perform pg_advisory_xact_lock(hashtext('push-follows:'||uid::text));
 delete from futbeat_private.push_follows f where f.user_id=uid and not exists(
  select 1 from jsonb_array_elements(p_follows) e where e->>'type'=f.entity_type and e->>'id'=f.entity_id);
 for item in select value from jsonb_array_elements(p_follows) loop
  if item->>'type' in ('team','match') and exists(select 1 from futbeat_private.entities where id=item->>'id' and kind=item->>'type') then
   insert into futbeat_private.push_follows values(uid,item->>'type',item->>'id',now()) on conflict do nothing;
  end if;
 end loop;
end $$;
create function public.futbeat_sync_push_follows(p_follows jsonb) returns void
language sql security invoker set search_path='' as $$ select futbeat_private.sync_push_follows(p_follows) $$;
alter function public.futbeat_register_push(uuid,text,text,text,boolean) set schema futbeat_private;
alter function public.futbeat_set_push_follow(text,text,boolean) set schema futbeat_private;
create function public.futbeat_register_push(p_installation uuid,p_platform text,p_transport text,p_token text,p_enabled boolean)
returns uuid language sql security invoker set search_path='' as $$
 select futbeat_private.futbeat_register_push(p_installation,p_platform,p_transport,p_token,p_enabled)
$$;
create function public.futbeat_set_push_follow(p_type text,p_id text,p_follow boolean)
returns void language sql security invoker set search_path='' as $$ select futbeat_private.futbeat_set_push_follow(p_type,p_id,p_follow) $$;
revoke all on function futbeat_private.sync_push_follows(jsonb),public.futbeat_sync_push_follows(jsonb),
 public.futbeat_register_push(uuid,text,text,text,boolean),public.futbeat_set_push_follow(text,text,boolean) from public;
do $$ begin
 if exists(select 1 from pg_roles where rolname='authenticated') then
  grant usage on schema futbeat_private to authenticated;
  grant execute on function futbeat_private.sync_push_follows(jsonb),public.futbeat_sync_push_follows(jsonb),
   public.futbeat_register_push(uuid,text,text,text,boolean),public.futbeat_set_push_follow(text,text,boolean) to authenticated;
 end if;
end $$;
revoke all on function futbeat_private.try_link_api_football_match(jsonb) from public;

create function futbeat_private.authorize_push_scheduler(p_token text) returns boolean
language plpgsql security definer set search_path='' as $$
declare valid boolean:=false;
begin
 if p_token is null or length(p_token)<32 or to_regnamespace('vault') is null then return false; end if;
 execute 'select exists(select 1 from vault.decrypted_secrets where name=$1 and decrypted_secret=$2)'
 into valid using 'futbeat_push_scheduler_token',p_token;
 return valid;
end $$;
create function public.futbeat_authorize_push_scheduler(p_token text) returns boolean
language sql security invoker set search_path='' as $$ select futbeat_private.authorize_push_scheduler(p_token) $$;
revoke all on function futbeat_private.authorize_push_scheduler(text),public.futbeat_authorize_push_scheduler(text) from public;
do $$ begin
 if exists(select 1 from pg_roles where rolname='service_role') then
 grant execute on function futbeat_private.authorize_push_scheduler(text),public.futbeat_authorize_push_scheduler(text) to service_role;
 end if;
end $$;

create table futbeat_private.push_settings(id boolean primary key default true check(id), mode text not null default 'dry_run' check(mode in ('dry_run','live')));
insert into futbeat_private.push_settings values(true,'dry_run');
alter table futbeat_private.push_settings enable row level security;
revoke all on futbeat_private.push_settings from public;
do $$ declare command text; begin
 if to_regnamespace('cron') is null or to_regnamespace('net') is null or to_regnamespace('vault') is null then return; end if;
 execute 'select vault.create_secret(gen_random_uuid()::text || gen_random_uuid()::text,$1) where not exists(select 1 from vault.secrets where name=$1)' using 'futbeat_push_scheduler_token';
 command:=$job$
 select net.http_post(
  url:='https://izlmruqawgagwdcsjhte.supabase.co/functions/v1/futbeat-push-dispatch',
  headers:=jsonb_build_object('Content-Type','application/json',
   'Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_public_jwt'),
   'x-futbeat-scheduler',(select decrypted_secret from vault.decrypted_secrets where name='futbeat_push_scheduler_token')),
  body:='{}'::jsonb,timeout_milliseconds:=60000)
 where exists(select 1 from vault.secrets where name='futbeat_push_public_jwt')
 and exists(select 1 from futbeat_private.notification_outbox o join futbeat_private.push_devices d on d.id=o.device_id
   where o.state='pending' and (d.transport='test' or (select mode from futbeat_private.push_settings where id)='live'));
 $job$;
 perform cron.schedule('futbeat-push-outbox','* * * * *',command);
end $$;
