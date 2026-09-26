-- #120: terminal canonical state is absorbing across realtime.
--
-- Root cause: the realtime projection (live_match_state -> public
-- live_match_updates) kept accepting and publishing non-terminal provider
-- states (LIVE, HALFTIME, ...) for matches whose canonical truth is already
-- terminal, and the mobile overlay let a later realtime row win over the
-- canonical final. A finished match could show LIVE / "Marcador parcial"
-- again.
--
-- Rules (generic; never by provider, team, match or clock):
--   * "Effectively terminal" is the effective read model
--     (match_read_model_core), so terminal evidence stored in
--     provider_observations, live_match_state, match_detail_cache or a
--     FULL_TIME canonical event counts even if the raw entity payload still
--     says SCHEDULED. Terminal is never inferred from the clock.
--   * record_live_events: a NON-terminal observation for an effectively
--     terminal match is suppressed before the change-detection core: it does
--     not touch live_match_state, live_events, canonical_events, the outbox
--     or provider_observations (which feed the read model's score/status),
--     and is kept for audit in live_suppressed_observations. The rest of the
--     batch is processed normally. Terminal observations are unchanged.
--   * futbeat_publish_live_state: defense in depth. For an effectively
--     terminal match a non-terminal state is never published and any
--     non-terminal public row is removed. A terminal realtime row is still
--     published: it agrees with the terminal truth and is how the final
--     whistle reaches open clients instantly.
--   * Legitimate corrections after the final (e.g. FPV 2-1 -> 2-2) stay on
--     the canonical ingest/reconciliation path, never through realtime.
--
-- Current bases: record_live_events and futbeat_publish_live_state from
-- 20260916161141_live_events_push_outbox.sql (latest definitions).

create or replace function futbeat_private.is_terminal_match_status(p_status text)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(p_status in ('FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','ABANDONED','CANCELLED'),false)
$$;

create or replace function futbeat_private.match_effectively_terminal(p_match_id text)
returns boolean language sql stable security definer set search_path='' as $$
  select coalesce((
    select futbeat_private.is_terminal_match_status(
      futbeat_private.match_read_model_core(e.payload,false)->>'status')
    from futbeat_private.entities e
    where e.id=p_match_id and e.kind='match'),false)
$$;

-- Audit of suppressed realtime observations. Never read by the read model,
-- the scheduler or the public projection.
create table if not exists futbeat_private.live_suppressed_observations (
  id bigint generated always as identity primary key,
  provider text not null,
  external_match_id text not null,
  canonical_match_id text not null,
  received_at timestamptz not null,
  status text not null,
  minute integer,
  home_score integer,
  away_score integer,
  payload_hash text,
  reason text not null default 'canonical_terminal',
  recorded_at timestamptz not null default now(),
  unique(provider,external_match_id,payload_hash)
);
alter table futbeat_private.live_suppressed_observations enable row level security;
revoke all on futbeat_private.live_suppressed_observations from public;
do $$ declare role_name text; begin
  foreach role_name in array array['anon','authenticated'] loop
    if exists(select 1 from pg_roles where rolname=role_name) then
      execute format('revoke all on futbeat_private.live_suppressed_observations from %I',role_name);
    end if;
  end loop;
end $$;

create or replace function futbeat_private.record_live_events(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; c jsonb; m jsonb; mid text; e record; tid text; pid text; aid text;
 ev jsonb; eid text; can_notify boolean; baseline boolean; typ text; state futbeat_private.live_match_state;
 obs jsonb; kept jsonb:='[]'; suppressed jsonb:='[]'; v_ext text; v_status text;
begin
 -- Ignore delayed observations instead of regressing a live match.
 if exists(select 1 from jsonb_array_elements(p_observations) o
  join futbeat_private.live_match_state s on s.provider=p_provider and s.external_match_id=o->>'externalMatchId'
  where s.last_seen_at>p_received_at) then raise exception 'Stale live batch'; end if;
 -- #120: a non-terminal observation never revives an effectively terminal
 -- match. Invalid input is left to the core, which validates it.
 if jsonb_typeof(p_observations)='array' then
  for obs in select value from jsonb_array_elements(p_observations) loop
   v_ext:=nullif(obs->>'externalMatchId',''); v_status:=nullif(obs->>'status',''); mid:=null;
   if v_ext is not null and v_status is not null and not futbeat_private.is_terminal_match_status(v_status) then
    if p_provider='api_football' then
     mid:=futbeat_private.try_link_api_football_match(obs);
    else
     select canonical_id into mid from futbeat_private.provider_entities
      where provider=p_provider and kind='match' and external_id=v_ext;
    end if;
    if mid is null then
     select canonical_match_id into mid from futbeat_private.live_match_state
      where provider=p_provider and external_match_id=v_ext;
    end if;
    if mid is not null and futbeat_private.match_effectively_terminal(mid) then
     insert into futbeat_private.live_suppressed_observations(provider,external_match_id,canonical_match_id,
       received_at,status,minute,home_score,away_score,payload_hash)
     values(p_provider,v_ext,mid,p_received_at,v_status,
       futbeat_private.safe_result_integer(obs->>'minute'),
       futbeat_private.safe_result_integer(obs#>>'{score,home}'),
       futbeat_private.safe_result_integer(obs#>>'{score,away}'),
       nullif(obs->>'payloadHash',''))
     on conflict(provider,external_match_id,payload_hash) do nothing;
     suppressed:=suppressed||jsonb_build_array(jsonb_build_object('externalMatchId',v_ext,
       'canonicalMatchId',mid,'status',v_status,'reason','canonical_terminal'));
     continue;
    end if;
   end if;
   kept:=kept||jsonb_build_array(obs);
  end loop;
 else
  kept:=p_observations;
 end if;
 result:=futbeat_private.record_live_batch_core(p_provider,p_received_at,kept);
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
 return result||jsonb_build_object('suppressedByCanonicalTerminal',jsonb_array_length(suppressed)>0,
   'suppressed',suppressed);
end $$;

create or replace function public.futbeat_publish_live_state(p_provider text,p_external_match_id text)
returns void language plpgsql security definer set search_path='' as $$
declare s futbeat_private.live_match_state; ev jsonb;
begin
 select * into s from futbeat_private.live_match_state where provider=p_provider and external_match_id=p_external_match_id;
 if not found or s.canonical_match_id is null then return; end if;
 -- #120 defense in depth: never expose a non-terminal realtime state for an
 -- effectively terminal match, and drop one already exposed. Canonical data,
 -- provider observations and canonical events are untouched.
 if not futbeat_private.is_terminal_match_status(s.status)
   and futbeat_private.match_effectively_terminal(s.canonical_match_id) then
  delete from public.live_match_updates
   where match_id=s.canonical_match_id
     and not futbeat_private.is_terminal_match_status(status);
  return;
 end if;
 select coalesce(jsonb_agg(payload order by coalesce((payload->>'minute')::int,0),id),'[]') into ev
 from futbeat_private.canonical_events where match_id=s.canonical_match_id and provider=p_provider;
 insert into public.live_match_updates(match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at)
 values(s.canonical_match_id,s.provider,s.external_match_id,s.status,s.minute,s.home_score,s.away_score,s.revision,jsonb_array_length(ev),ev,s.changed_at,now())
 on conflict(match_id) do update set provider=excluded.provider,external_match_id=excluded.external_match_id,
 status=excluded.status,minute=excluded.minute,home_score=excluded.home_score,away_score=excluded.away_score,
 revision=excluded.revision,event_count=excluded.event_count,latest_events=excluded.latest_events,
 changed_at=excluded.changed_at,updated_at=excluded.updated_at;
end $$;

-- Read-only diagnostic: effectively terminal matches still publicly exposed
-- with a non-terminal realtime row. Expected: 0.
create or replace function futbeat_private.terminal_realtime_regressions()
returns table(match_id text,realtime_status text,effective_status text)
language sql stable security definer set search_path='' as $$
  select l.match_id,l.status,
    futbeat_private.match_read_model_core(e.payload,false)->>'status'
  from public.live_match_updates l
  join futbeat_private.entities e on e.id=l.match_id and e.kind='match'
  where not futbeat_private.is_terminal_match_status(l.status)
    and futbeat_private.match_effectively_terminal(l.match_id)
$$;

-- Clean the current invalid PUBLIC projection only: non-terminal rows of
-- effectively terminal matches. Terminal rows and every other row stay.
-- futbeat_private.live_match_state is kept as provider/diagnostic state: the
-- read model already ranks terminal evidence first, change detection needs
-- it to avoid re-emitting KICKOFF/FULL_TIME, and the guards above stop it
-- from reaching clients.
delete from public.live_match_updates l
where not futbeat_private.is_terminal_match_status(l.status)
  and futbeat_private.match_effectively_terminal(l.match_id);

do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='futbeat_private' and p.proname in
   ('is_terminal_match_status','match_effectively_terminal','record_live_events','terminal_realtime_regressions')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
 if exists(select 1 from pg_roles where rolname='service_role') then
  grant execute on function futbeat_private.record_live_events(text,timestamptz,jsonb) to service_role;
 end if;
end $$;
