-- No provider calls. Reuse canonical entity media and existing coverage tables.
-- Encapsulate the exact global-ingest read path; do not grant private table SELECT.
alter function public.futbeat_read_snapshot() security definer;
alter function public.futbeat_read_snapshot() owner to postgres;
alter function public.futbeat_read_snapshot() set search_path='';
revoke all on function public.futbeat_read_snapshot() from public,anon,authenticated;
grant execute on function public.futbeat_read_snapshot() to service_role;

alter table futbeat_private.player_media_coverage
 add column external_id text,
 add column last_seen_at timestamptz,
 add column verified_at timestamptz,
 add column last_error text;
update futbeat_private.player_media_coverage c set last_seen_at=last_checked_at,
 verified_at=case when status='AVAILABLE' then last_checked_at end,
 external_id=e.payload#>>'{provenance,externalId}'
from futbeat_private.entities e where e.id=c.player_id;
-- Legacy absence was inferred from arbitrary entity updates. Keep the record,
-- but do not treat that unconfirmed signal as a successful no-photo response.
update futbeat_private.player_media_coverage c set status='TEMPORARY_ERROR',retry_after=now(),
 last_error='LEGACY_ABSENCE_UNCONFIRMED'
from futbeat_private.entities e where e.id=c.player_id and c.status='NOT_AVAILABLE'
 and e.payload#>>'{provenance,mediaStatus}' is distinct from 'NO_PHOTO';

-- Single SQL GOAL policy. Other verified editorial sources retain their contract.
create function futbeat_private.futbeat_valid_goal_player_media_url(p_url text,p_source text)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(p_source='GOAL API'
   and substring(p_url from '^https://([A-Za-z0-9.-]+)/')=any(array['media.goal-api.com'])
   and p_url ~ '^https://[A-Za-z0-9.-]+/[^[:space:]\\]+$'
   and p_url !~ '%([^0-9A-Fa-f]|[0-9A-Fa-f]([^0-9A-Fa-f]|$)|$)',false)
$$;

create function futbeat_private.valid_player_media(p_media jsonb)
returns boolean language sql immutable set search_path='' as $$
 select coalesce(p_media->>'verificationStatus'='VERIFIED'
   and case when p_media->>'source'='GOAL API' then
     futbeat_private.futbeat_valid_goal_player_media_url(p_media->>'url',p_media->>'source')
   else p_media->>'url' ~ '^https://[A-Za-z0-9.-]+/[^[:space:]]*$' end,false)
$$;

create or replace function futbeat_private.preserve_verified_player_media()
returns trigger language plpgsql set search_path='' as $$
begin
 if new.kind='player' then
   if TG_OP='UPDATE' and futbeat_private.valid_player_media(old.payload->'media')
     and (not futbeat_private.valid_player_media(new.payload->'media')
       or (old.payload#>>'{media,source}' is distinct from 'GOAL API'
         and new.payload#>>'{media,source}'='GOAL API')
       or coalesce(nullif(new.payload#>>'{media,receivedAt}','')::timestamptz,'-infinity')
         <coalesce(nullif(old.payload#>>'{media,receivedAt}','')::timestamptz,'-infinity')) then
     new.payload:=jsonb_set(new.payload,'{media}',old.payload->'media',true);
   elsif not futbeat_private.valid_player_media(new.payload->'media') then
     new.payload:=new.payload-'media';
   end if;
 end if;
 return new;
end $$;
drop trigger futbeat_preserve_player_media on futbeat_private.entities;
create trigger futbeat_preserve_player_media before insert or update of payload
on futbeat_private.entities for each row execute function futbeat_private.preserve_verified_player_media();

create or replace function futbeat_private.track_player_media_coverage()
returns trigger language plpgsql security definer set search_path='' as $$
declare available boolean; stamp timestamptz; outcome text; origin text;
begin
 if new.kind<>'player' then return new; end if;
 available:=futbeat_private.valid_player_media(new.payload->'media');
 stamp:=coalesce(nullif(new.payload#>>'{media,receivedAt}','')::timestamptz,
   nullif(new.payload#>>'{provenance,receivedAt}','')::timestamptz,now());
 origin:=coalesce(new.payload#>>'{media,discoveredVia}',new.payload#>>'{provenance,mediaSource}','squad');
 if origin not in ('lineup','squad','player_profile') then origin:='squad'; end if;
 outcome:=case when available then 'AVAILABLE'
   when new.payload#>>'{provenance,mediaStatus}'='NO_PHOTO' then 'NOT_AVAILABLE'
   when new.payload#>>'{provenance,mediaStatus}'='FETCH_FAILED' then 'TEMPORARY_ERROR' end;
 if outcome is null then return new; end if;
 -- Partial metadata updates cannot extend a previously verified photo's TTL.
 if TG_OP='UPDATE' and available and new.payload->'media' is not distinct from old.payload->'media'
   and exists(select 1 from futbeat_private.player_media_coverage where player_id=new.id) then
   update futbeat_private.player_media_coverage set last_seen_at=greatest(last_seen_at,now()) where player_id=new.id;
   return new;
 end if;
 insert into futbeat_private.player_media_coverage as c
 (player_id,provider,status,last_checked_at,retry_after,source,external_id,last_seen_at,verified_at,last_error)
 values(new.id,case when available then case when new.payload#>>'{media,source}'='GOAL API' then 'goal_api'
   else coalesce(nullif(lower(new.payload#>>'{media,source}'),''),'canonical') end else 'goal_api' end,
   outcome,stamp,stamp+case outcome when 'AVAILABLE' then interval '90 days'
   when 'NOT_AVAILABLE' then interval '30 days' else interval '1 hour' end,origin,
   coalesce(new.payload#>>'{media,externalId}',new.payload#>>'{provenance,externalId}'),now(),
   case when available then stamp end,case when outcome='TEMPORARY_ERROR' then 'INVALID_OR_FAILED_MEDIA' end)
 on conflict(player_id) do update set provider=excluded.provider,status=excluded.status,last_checked_at=excluded.last_checked_at,
   retry_after=excluded.retry_after,source=excluded.source,external_id=coalesce(excluded.external_id,c.external_id),
   last_seen_at=excluded.last_seen_at,verified_at=excluded.verified_at,last_error=excluded.last_error
 where excluded.last_checked_at>=c.last_checked_at and (c.status<>'AVAILABLE' or available);
 return new;
end $$;

-- Lock identity creation: concurrent detail/squad discovery cannot create orphans.
alter function futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text)
 rename to resolve_global_entity_before_player_lock;
create function futbeat_private.futbeat_resolve_global_entity(p_provider text,p_kind text,p_external text,
 p_name text default '',p_country text default '',p_short_name text default '') returns text
language plpgsql security definer set search_path='' as $$
begin
 if p_kind='player' then
   perform pg_catalog.pg_advisory_xact_lock(hashtextextended('player:'||p_provider||':'||p_external,0));
 end if;
 return futbeat_private.resolve_global_entity_before_player_lock(p_provider,p_kind,p_external,p_name,p_country,p_short_name);
end $$;

create function futbeat_private.harvest_lineup_media(p_payload jsonb,p_seen timestamptz)
returns void language plpgsql security definer set search_path='' as $$
declare r jsonb; ext text; pid text; photo text; media jsonb;
begin
 for r in select value from jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups')='array'
   then p_payload->'lineups' else '[]'::jsonb end) loop
   if lower(coalesce(r->>'type','')) not like 'start%' and lower(coalesce(r->>'type','')) not like 'sub%' then continue; end if;
   ext:=coalesce(nullif(r->>'playerId',''),nullif(r->>'playerKey',''),nullif(r#>>'{player,id}',''));
   if ext is null then continue; end if;
   pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,
     coalesce(r->>'lineupPlayer',r->>'playerName',r#>>'{player,name}',''));
   photo:=coalesce(nullif(r->>'playerImage',''),nullif(r#>>'{player,image}',''),nullif(r->>'photo',''));
   -- Detail omission is NOT evidence of NO_PHOTO. Only harvest trusted CDN URLs.
   if futbeat_private.futbeat_valid_goal_player_media_url(photo,'GOAL API') then
     media:=jsonb_build_object('url',photo,'kind','PLAYER_PHOTO','source','GOAL API','externalId',ext,
       'receivedAt',p_seen,'verificationStatus','VERIFIED','rightsStatus','REVIEW_REQUIRED',
       'usageScope','DEVELOPMENT_ONLY','discoveredVia','lineup');
     update futbeat_private.entities set payload=jsonb_set(payload,'{media}',media,true) where id=pid and kind='player';
   end if;
 end loop;
end $$;
alter function futbeat_private.store_match_detail(text,text,timestamptz,jsonb) rename to store_match_detail_before_media;
create function futbeat_private.store_match_detail(p_match_id text,p_external_match_id text,p_fetched_at timestamptz,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=futbeat_private.store_match_detail_before_media(p_match_id,p_external_match_id,p_fetched_at,p_payload);
 perform futbeat_private.harvest_lineup_media(p_payload,p_fetched_at);
 return result;
end $$;

alter table futbeat_private.team_detail_coverage
 alter column fetched_at drop not null,
 add column status text not null default 'AVAILABLE' check(status in ('AVAILABLE','NO_DATA','FETCH_FAILED')),
 add column last_success_at timestamptz,
 add column last_attempt_at timestamptz,
 add column next_retry_at timestamptz,
 add column failure_count integer not null default 0,
 add column last_error text,
 add column media_count integer not null default 0,
 add column lease_until timestamptz;
update futbeat_private.team_detail_coverage set last_success_at=fetched_at,
 next_retry_at=fetched_at+interval '7 days',status=case when player_count=0 then 'NO_DATA' else 'AVAILABLE' end;

alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb) rename to store_team_squad_before_media;
create function futbeat_private.futbeat_store_team_squad(p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id); p jsonb; pid text; ext text;
 merged jsonb:='[]'; retained jsonb; result jsonb; old_payload jsonb; affected_teams text[]:=array[tid];
begin
 if p_provider is distinct from 'goal_api' or p_received_at is null or p_players is null
   or jsonb_typeof(p_players)<>'array' or jsonb_array_length(p_players)>100 then raise exception 'Invalid squad'; end if;
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('squad:'||tid,0));
 if exists(select 1 from futbeat_private.team_detail_coverage where team_id=tid and last_success_at>p_received_at) then
   return jsonb_build_object('teamId',tid,'status','ignored_older');
 end if;
 for p in select value from jsonb_array_elements(p_players) order by value#>>'{provenance,externalId}' loop
   ext:=nullif(p#>>'{provenance,externalId}','');
   if p#>>'{provenance,source}' is distinct from 'GOAL API' then raise exception 'Invalid squad provenance'; end if;
   -- Accept an established legacy canonical identity only when its provenance
   -- agrees; otherwise the provider mapping is authoritative, never a supplied ID.
   if ext is null then raise exception 'Missing provider player identity'; end if;
   perform pg_catalog.pg_advisory_xact_lock(hashtextextended('player:goal_api:'||ext,0));
   insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
     select 'goal_api','player',ext,e.id from futbeat_private.entities e
     where e.id=p->>'id' and e.kind='player' and e.payload#>>'{provenance,externalId}'=ext
       and e.payload#>>'{provenance,source}'='GOAL API'
     on conflict do nothing;
   pid:=futbeat_private.futbeat_resolve_global_entity('goal_api','player',ext,coalesce(p->>'name',''));
   select payload into old_payload from futbeat_private.entities where id=pid for update;
   -- Ignore older cross-team observations; preserve previous known metadata.
   if nullif(old_payload#>>'{provenance,receivedAt}','')::timestamptz>p_received_at then continue; end if;
   affected_teams:=array_append(affected_teams,futbeat_private.futbeat_resolve_entity_id('team',old_payload->>'teamId'));
   if p->'media' is not null and p->'media'<>'null'::jsonb
     and not futbeat_private.futbeat_valid_goal_player_media_url(p#>>'{media,url}',p#>>'{media,source}') then
     p:=jsonb_set(p-'media','{provenance,mediaStatus}','"FETCH_FAILED"',true);
   end if;
   select coalesce(jsonb_object_agg(key,value),'{}') into p from jsonb_each(p)
     where value<>'null'::jsonb and value<>'""'::jsonb;
   p:=coalesce(old_payload,'{}')||p||jsonb_build_object('id',pid,'teamId',tid);
   merged:=merged||jsonb_build_array(p);
 end loop;
 select coalesce(jsonb_agg(item order by item->>'id'),'[]') into merged from (
   select distinct on (item->>'id') item from jsonb_array_elements(merged) x(item) order by item->>'id'
 ) deduplicated;
 if jsonb_array_length(p_players)>0 and jsonb_array_length(merged)=0 then
   return jsonb_build_object('teamId',tid,'status','ignored_older_players');
 end if;
 select coalesce(jsonb_agg(to_jsonb(sm)),'[]') into retained from futbeat_private.team_squad_members sm where team_id=tid;
 -- Keep existing transfer detection unchanged. Restore omitted members below:
 -- omission is not reliable evidence of departure; an observed move is.
 result:=futbeat_private.store_team_squad_before_media(tid,p_provider,p_received_at,merged);
 insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
 select tid,r->>'player_id',r->>'provider',(r->>'updated_at')::timestamptz from jsonb_array_elements(retained) r
 where exists(select 1 from futbeat_private.entities e where e.id=r->>'player_id'
   and futbeat_private.futbeat_resolve_entity_id('team',e.payload->>'teamId')=tid)
 on conflict do nothing;
 -- A positive transfer also changes the previous team's retained coverage counts.
 update futbeat_private.team_detail_coverage c set
   player_count=(select count(*) from futbeat_private.team_squad_members sm where sm.team_id=c.team_id),
   media_count=(select count(*) from futbeat_private.team_squad_members sm join futbeat_private.entities e on e.id=sm.player_id
     where sm.team_id=c.team_id and futbeat_private.valid_player_media(e.payload->'media'))
 where c.team_id=any(affected_teams);
 update futbeat_private.team_detail_coverage set last_success_at=p_received_at,last_attempt_at=p_received_at,
   status=case when jsonb_array_length(merged)=0 then 'NO_DATA' else 'AVAILABLE' end,
   next_retry_at=p_received_at+case when jsonb_array_length(merged)=0 then interval '30 days' else interval '7 days' end,
   failure_count=0,last_error=null,lease_until=null,
   player_count=(select count(*) from futbeat_private.team_squad_members where team_id=tid),
   media_count=(select count(*) from futbeat_private.team_squad_members sm join futbeat_private.entities e on e.id=sm.player_id
     where sm.team_id=tid and futbeat_private.valid_player_media(e.payload->'media'))
 where team_id=tid;
 return result;
end $$;

update futbeat_private.entities e set payload=e.payload where kind='player'
 and futbeat_private.valid_player_media(payload->'media')
 and not exists(select 1 from futbeat_private.player_media_coverage c where c.player_id=e.id);

-- Valid goal_api batches (<=100 input entries) return every distinct nonempty ID.
-- Unresolved IDs have canonicalId=null/image=null; missing media is not an error.
-- One set-based lookup, never one query/request per player.
create or replace function futbeat_private.futbeat_read_lineup_player_media(p_provider text,p_external_ids text[])
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_object_agg(ids.ext,jsonb_build_object('providerId',ids.ext,'canonicalId',e.id,
   'image',case when futbeat_private.valid_player_media(e.payload->'media') then e.payload#>>'{media,url}' end)),'{}')
 from (select distinct unnest(p_external_ids) ext) ids
 left join futbeat_private.provider_entities pe on pe.provider=p_provider and pe.kind='player' and pe.external_id=ids.ext
 left join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) and e.kind='player'
 where p_provider='goal_api' and cardinality(p_external_ids)<=100 and nullif(ids.ext,'') is not null
$$;

-- Backfill only already stored detail. Zero provider requests and no image downloads.
do $$ declare r record; begin
 for r in select payload,fetched_at from futbeat_private.match_detail_cache order by fetched_at loop
   perform futbeat_private.harvest_lineup_media(r.payload,r.fetched_at);
 end loop;
end $$;

-- Private helpers are not endpoints. Public wrappers retain service-only grants.
revoke all on function futbeat_private.valid_player_media(jsonb),
 futbeat_private.futbeat_valid_goal_player_media_url(text,text),
 futbeat_private.resolve_global_entity_before_player_lock(text,text,text,text,text,text),
 futbeat_private.harvest_lineup_media(jsonb,timestamptz),
 futbeat_private.store_match_detail_before_media(text,text,timestamptz,jsonb),
 futbeat_private.store_team_squad_before_media(text,text,timestamptz,jsonb)
 from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text),
 futbeat_private.store_match_detail(text,text,timestamptz,jsonb),
 futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb) from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_resolve_global_entity(text,text,text,text,text,text),
 futbeat_private.store_match_detail(text,text,timestamptz,jsonb),
 futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb) to service_role;

create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer default 3)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 with recent_provider_teams as materialized (
   -- Keep the established latest-observation preference when a team has several
   -- provider IDs; lexical ordering alone can repeatedly select a retired ID.
   select x.external_id,max(o.received_at) last_seen_at from futbeat_private.provider_observations o
   cross join lateral (values(coalesce(o.raw_payload#>>'{homeTeam,id}',o.raw_payload->>'homeTeamId')),
     (coalesce(o.raw_payload#>>'{awayTeam,id}',o.raw_payload->>'awayTeamId'))) x(external_id)
   where o.provider='goal_api' and o.received_at>=now()-interval '180 days'
     and nullif(x.external_id,'') is not null group by x.external_id
 ), active_matches as materialized (
   select e.payload,c.start_time from futbeat_private.calendar_matches c
   join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
 ), candidates as (
   select futbeat_private.futbeat_resolve_entity_id('team',x.id) team_id,
     case when m.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 0 else 2 end tier
   from active_matches m cross join lateral (values(m.payload->>'homeTeamId'),(m.payload->>'awayTeamId')) x(id)
   where m.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
     or (m.start_time>=now() and m.payload->>'status'='SCHEDULED')
   union all
   select futbeat_private.futbeat_resolve_entity_id('team',subject_id),1
     from futbeat_private.coverage_interests where subject_type='team' and explicit_followers>0
   union all
   select futbeat_private.futbeat_resolve_entity_id('team',t.id),3
     from futbeat_private.entities t join futbeat_private.coverage_interests ci
     on ci.subject_type='competition' and ci.subject_id=futbeat_private.futbeat_resolve_entity_id('competition',t.payload->>'competitionId')
     where t.kind='team' and ci.explicit_followers>0
   union all
   -- Only authoritative high-relevance competitions; never a country/name fallback.
   select futbeat_private.futbeat_resolve_entity_id('team',t.id),4
     from futbeat_private.entities t join futbeat_private.competition_editorial_metadata meta
     on meta.competition_id=futbeat_private.futbeat_resolve_entity_id('competition',t.payload->>'competitionId')
     where t.kind='team' and meta.relevance_score>=800 and meta.source<>'derived'
   union all
   select futbeat_private.futbeat_resolve_entity_id('team',entity_id),5
     from futbeat_private.temporary_interests where entity_type='team' and expires_at>now()
 ), ranked as (
   select team_id,min(tier) tier from candidates where team_id is not null group by team_id
 ), due as (
   select r.team_id,r.tier,m.external_id,c.fetched_at from ranked r
   left join futbeat_private.team_detail_coverage c on c.team_id=r.team_id
   join lateral (
     select pe.external_id from futbeat_private.provider_entities pe
     left join recent_provider_teams recent on recent.external_id=pe.external_id
     where pe.provider='goal_api' and pe.kind='team'
       and futbeat_private.futbeat_resolve_entity_id('team',pe.canonical_id)=r.team_id
     order by recent.last_seen_at desc nulls last,pe.external_id desc limit 1
   ) m on true
   where coalesce(c.next_retry_at,c.fetched_at+interval '7 days','-infinity')<=now()
     and coalesce(c.lease_until,'-infinity')<=now()
   order by r.tier,c.fetched_at nulls first,r.team_id limit p_limit
 ) select coalesce(jsonb_agg(jsonb_build_object('teamId',team_id,'externalTeamId',external_id,
   'priority',60000-tier*10000,'priorityTier',tier,'reason',
   (array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened'])[tier+1],
   'lastFetchedAt',fetched_at) order by tier,fetched_at nulls first,team_id),'[]') into result from due;
 return result;
end $$;

alter function futbeat_private.futbeat_reserve_goal_squad_call(text,text,text) rename to reserve_squad_before_coverage;
create function futbeat_private.futbeat_reserve_goal_squad_call(p_team_id text,p_external_team_id text,
 p_trigger_source text default 'github-actions') returns jsonb
language plpgsql security definer set search_path='' as $$
declare tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id); result jsonb; mapped_tid text;
begin
 perform pg_catalog.pg_advisory_xact_lock(hashtextextended('squad:'||tid,0));
 if exists(select 1 from futbeat_private.team_detail_coverage where team_id=tid
   and (coalesce(next_retry_at,fetched_at+interval '7 days','-infinity')>now() or lease_until>now())) then
   return jsonb_build_object('allowed',false,'reason','squad_fresh_backoff_or_inflight');
 end if;
 -- Keep the existing daily cap and LIVE reserve exactly as before.
 select canonical_id into mapped_tid from futbeat_private.provider_entities pe
   where pe.provider='goal_api' and pe.kind='team' and pe.external_id=p_external_team_id
     and futbeat_private.futbeat_resolve_entity_id('team',pe.canonical_id)=tid;
 result:=futbeat_private.reserve_squad_before_coverage(coalesce(mapped_tid,tid),p_external_team_id,p_trigger_source);
 result:=result||jsonb_build_object('teamId',tid);
 if (result->>'allowed')::boolean then
   insert into futbeat_private.team_detail_coverage(team_id,provider,fetched_at,player_count,last_attempt_at,lease_until)
   values(tid,'goal_api',null,0,now(),now()+interval '10 minutes')
   on conflict(team_id) do update set last_attempt_at=excluded.last_attempt_at,lease_until=excluded.lease_until;
 end if;
 return result;
end $$;

-- Central ledger completion catches failures from either existing transport.
-- Only squad rows are handled; LIVE/results/news/standings behavior is untouched.
create function futbeat_private.track_squad_call_outcome() returns trigger
language plpgsql security definer set search_path='' as $$
declare tid text; failures integer;
begin
 if new.call_kind not in ('team-squad','team-squad-ingest') or old.status<>'RESERVED' or new.status<>'FAILED' then return new; end if;
 tid:=futbeat_private.futbeat_resolve_entity_id('team',coalesce(old.metadata->>'teamId',new.metadata->>'teamId'));
 if tid is null then return new; end if;
 select failure_count+1 into failures from futbeat_private.team_detail_coverage where team_id=tid for update;
 failures:=coalesce(failures,1);
 update futbeat_private.team_detail_coverage set
   status=case when new.http_status=404 then 'NO_DATA' else 'FETCH_FAILED' end,
   last_attempt_at=new.completed_at,failure_count=failures,last_error=left(coalesce(new.error_code,'SQUAD_FETCH_FAILED'),120),
   lease_until=null,next_retry_at=new.completed_at+case when new.http_status=404 then interval '30 days'
     when new.http_status=429 then interval '1 day'
     else make_interval(secs=>least(86400,900*power(2,least(failures-1,7)))::integer) end
 where team_id=tid and (last_success_at is null or last_success_at<=old.reserved_at);
 return new;
end $$;
create trigger squad_call_outcome after update of status on futbeat_private.provider_call_ledger
for each row execute function futbeat_private.track_squad_call_outcome();

-- Eligibility only, not a dispatcher. No individual-player fetch path is added.
create function futbeat_private.player_media_refresh_due(p_player_id text,p_has_demand boolean default false)
returns boolean language sql stable set search_path='' as $$
 select p_has_demand and exists(select 1 from futbeat_private.entities e
   left join futbeat_private.player_media_coverage c on c.player_id=e.id
   where e.id=p_player_id and e.kind='player'
     and (c.retry_after<=now() or (c.player_id is null and not futbeat_private.valid_player_media(e.payload->'media'))))
$$;

create function public.futbeat_player_coverage_metrics() returns jsonb
language sql stable security definer set search_path='' as $$
 with players as (
   select count(*) n,count(*) filter(where futbeat_private.valid_player_media(e.payload->'media')) photos,
     count(*) filter(where c.status='NOT_AVAILABLE' and c.retry_after>now()
       and not futbeat_private.valid_player_media(e.payload->'media')) missing
   from futbeat_private.entities e left join futbeat_private.player_media_coverage c on c.player_id=e.id where e.kind='player'
 ), members as (
   select count(*) n,count(*) filter(where exists(select 1 from futbeat_private.provider_entities pe
     where pe.kind='player' and pe.provider=sm.provider and pe.canonical_id=e.id)) mapped,
     count(*) filter(where futbeat_private.valid_player_media(e.payload->'media')) photos
   from futbeat_private.team_squad_members sm join futbeat_private.entities e on e.id=sm.player_id and e.kind='player'
 ), teams as (
   select count(*) filter(where last_success_at is not null and player_count>0) n,
     count(*) filter(where status='AVAILABLE' and player_count>0 and last_success_at>now()-interval '7 days') fresh
   from futbeat_private.team_detail_coverage c
   where exists(select 1 from futbeat_private.team_squad_members sm where sm.team_id=c.team_id)
 ) select jsonb_build_object('canonical_players',p.n,'players_with_photo',p.photos,'players_without_photo_known',p.missing,
   'squad_members',m.n,'teams_with_squad',t.n,'teams_with_fresh_squad',t.fresh,'teams_with_stale_squad',t.n-t.fresh,
   'canonical_photo_pct',round(100.0*p.photos/nullif(p.n,0),2),
   'squad_mapping_pct',round(100.0*m.mapped/nullif(m.n,0),2),
   'squad_photo_pct',round(100.0*m.photos/nullif(m.n,0),2),
   'teams_total',(select count(*) from futbeat_private.entities e where kind='team'
     and not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id)),
   'teams_fresh_pct',round(100.0*t.fresh/nullif((select count(*) from futbeat_private.entities e where kind='team'
     and not exists(select 1 from futbeat_private.entity_redirects r where r.alias_id=e.id)),0),2)) from players p,members m,teams t
$$;
revoke all on function futbeat_private.reserve_squad_before_coverage(text,text,text),
 futbeat_private.track_squad_call_outcome(),futbeat_private.player_media_refresh_due(text,boolean)
 from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_reserve_goal_squad_call(text,text,text),
 public.futbeat_player_coverage_metrics() from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_reserve_goal_squad_call(text,text,text),
 public.futbeat_player_coverage_metrics() to service_role;
notify pgrst,'reload schema';
