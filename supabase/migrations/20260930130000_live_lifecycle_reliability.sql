-- LIVE lifecycle reliability: a match must go SCHEDULED -> LIVE -> FINAL
-- without staying trapped in an earlier state.
--
-- Evidence (read-only production diagnostics, 2026-09-30):
--   * 67 GOAL live states in 24 h had no canonical match. In 37 of them the
--     competition and both teams were already mapped, but no canonical match
--     existed within 24 h: the fixture was scheduled (or re-issued under a
--     new provider id / kickoff) after the last calendar ingest, and there
--     is no periodic calendar ingest. The linker only attaches a live
--     fixture to an existing match within 3 hours, so those games were
--     never shown as LIVE while their stale calendar copy stayed
--     "scheduled" forever.
--   * 278 of 282 terminal-recovery rows exhausted in 72 h had attempts=0
--     ('expired'): recovery needs provider quota above the protected floor,
--     which is gone by the European afternoon, and the row expires 6 h
--     after detection, before the daily quota reset. One detail call per
--     match is also the expensive way to learn a final.
--
-- Fix (generic; strong identity only, never names, never the clock):
--   1. Discovery. For a fixture the linker left unmapped, when its
--      competition AND both teams are already mapped to canonical entities:
--        a. relink: exactly one scheduled ghost of the same competition and
--           teams (no observation trail, not terminal) kicking off up to
--           24 h before this fixture or up to 3 h after it, whose own
--           provider id is not reported in the same batch, IS this fixture
--           under its old id / kickoff: the new provider id is attached to
--           it and its kickoff corrected (audited in provenance). No second
--           entity. A ghost more than 3 h later may be a real second game.
--        b. create: no such match and nothing played within 24 hours: a new
--           canonical match is created from the provider evidence (status
--           SCHEDULED; LIVE / final status comes from the normal observation
--           path, never from here). Only for fixtures the provider reports
--           as in play or finished, with a kickoff in the last 36 hours.
--      Anything ambiguous (two ghosts, a played twin, unmapped team or
--      competition, old kickoff) stays unmapped exactly as before.
--      Concurrency: one advisory lock per provider match id, shared with
--      the catalogue resolver (futbeat_resolve_global_entity), taken in
--      ascending id order; mappings are inserted with DO NOTHING and
--      re-read, so two writers never produce two entities for one id.
--      The results-date lane also calls the linker: discovery then runs
--      on finished fixtures of that date (creation still needs a kickoff
--      in the last 36 hours).
--   2. Pending terminal recoveries ask the results lane for their provider
--      date (the existing results_date_user_demand queue): one paginated
--      results call resolves every final of that date, inside the results
--      lane's own quota class, caps and per-date backoff. Detail recovery
--      is unchanged and still runs when quota allows.
--
-- No provider call is made here; no cron, quota policy or ledger change.

-- ---------------------------------------------------------------------------
-- 1. Discovery of live fixtures the calendar does not know
-- ---------------------------------------------------------------------------

-- One lock key per provider match id, shared by every writer that can
-- create or map a GOAL match (this discovery and the catalogue resolver
-- below). Same shape as the existing player key.
create or replace function futbeat_private.goal_match_identity_lock(p_external text)
returns void language sql volatile set search_path='' as $$
  select pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('match:goal_api:'||p_external,0))
$$;

-- p_reported: every provider id of the batch being linked. A ghost still
-- reported by the provider in that same batch is alive, never relinked.
create or replace function futbeat_private.discover_goal_live_match(
  p_fixture jsonb,p_reported text[] default '{}'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_ext text:=nullif(coalesce(p_fixture->>'apiId',p_fixture->>'id'),'');
  v_home_ext text:=nullif(coalesce(p_fixture#>>'{homeTeam,id}',p_fixture->>'homeTeamId'),'');
  v_away_ext text:=nullif(coalesce(p_fixture#>>'{awayTeam,id}',p_fixture->>'awayTeamId'),'');
  v_comp_ext text:=nullif(coalesce(p_fixture#>>'{league,id}',p_fixture->>'leagueId'),'');
  v_kickoff timestamptz:=futbeat_private.try_timestamptz(p_fixture->>'kickoffUtc');
  v_status text:=upper(coalesce(p_fixture->>'matchStatus',''));
  v_home text; v_away text; v_comp text; v_match text; v_ghosts integer; v_old_start text;
  v_old_ids jsonb; v_alive boolean;
begin
  if v_ext is null then return jsonb_build_object('outcome','skipped','reason','no_external_id'); end if;

  -- Strong identity only: canonical competition and both canonical teams.
  -- Checked before any lock: most unmapped rows of a results date stop here.
  select futbeat_private.futbeat_resolve_entity_id('team',canonical_id) into v_home
    from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=v_home_ext;
  select futbeat_private.futbeat_resolve_entity_id('team',canonical_id) into v_away
    from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=v_away_ext;
  select futbeat_private.futbeat_resolve_entity_id('competition',canonical_id) into v_comp
    from futbeat_private.provider_entities where provider='goal_api' and kind='competition' and external_id=v_comp_ext;
  if v_home is null or v_away is null or v_home=v_away then
    return jsonb_build_object('outcome','skipped','reason','team_unmapped');
  end if;
  if v_comp is null then return jsonb_build_object('outcome','skipped','reason','competition_unmapped'); end if;
  if v_kickoff is null then return jsonb_build_object('outcome','skipped','reason','no_kickoff'); end if;

  -- Serialized per provider id with every other creator of this mapping
  -- (another worker, the catalogue resolver). Under READ COMMITTED each
  -- statement below sees what the previous holder committed.
  perform futbeat_private.goal_match_identity_lock(v_ext);
  select canonical_id into v_match from futbeat_private.provider_entities
   where provider='goal_api' and kind='match' and external_id=v_ext;
  if v_match is not null then return jsonb_build_object('outcome','already_linked','matchId',v_match); end if;

  -- A played / playing match of the same competition and teams within 24 h
  -- is another representation already being tracked: never a second entity.
  if exists(
    select 1 from futbeat_private.entities x
    where x.kind='match' and x.payload->>'homeTeamId'=v_home and x.payload->>'awayTeamId'=v_away
      and futbeat_private.futbeat_resolve_entity_id('competition',x.payload->>'competitionId')=v_comp
      and abs(extract(epoch from (futbeat_private.try_timestamptz(x.payload->>'startTime')-v_kickoff)))<=86400
      and (futbeat_private.fixture_has_observations(x.id)
        or not futbeat_private.fixture_is_ghost(futbeat_private.match_read_model_core(x.payload,false)))) then
    return jsonb_build_object('outcome','skipped','reason','played_twin_exists');
  end if;

  -- a. The scheduled ghost of this very fixture under its old id / kickoff:
  -- a ghost whose kickoff is up to 24 h BEFORE this one (its time passed
  -- with no evidence: postponed or re-issued) or up to 3 h after it (the
  -- linker's own tolerance). A ghost more than 3 h LATER may be a second
  -- real game of the pairing and is never taken (nor does it block).
  select count(*)::integer,min(x.id),coalesce(bool_or(exists(
      select 1 from futbeat_private.provider_entities pe
      where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=x.id
        and pe.external_id=any(p_reported))),false)
    into v_ghosts,v_match,v_alive
  from futbeat_private.entities x
  where x.kind='match' and x.payload->>'homeTeamId'=v_home and x.payload->>'awayTeamId'=v_away
    and futbeat_private.futbeat_resolve_entity_id('competition',x.payload->>'competitionId')=v_comp
    and futbeat_private.try_timestamptz(x.payload->>'startTime')>=v_kickoff-interval '24 hours'
    and futbeat_private.try_timestamptz(x.payload->>'startTime')<=v_kickoff+interval '3 hours';
  if v_ghosts>1 then return jsonb_build_object('outcome','skipped','reason','ambiguous_ghosts','candidates',v_ghosts); end if;
  if v_ghosts=1 and v_alive then
    -- The provider reports the ghost's own id in this batch: two fixtures.
    return jsonb_build_object('outcome','skipped','reason','ghost_still_reported');
  end if;
  if v_ghosts=1 then
    -- Take the new id first; if anything else holds it, change nothing.
    insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
    values('goal_api','match',v_ext,v_match)
    on conflict(provider,kind,external_id) do nothing;
    if not found then
      select canonical_id into v_match from futbeat_private.provider_entities
       where provider='goal_api' and kind='match' and external_id=v_ext;
      return jsonb_build_object('outcome','already_linked','matchId',v_match);
    end if;
    select payload->>'startTime' into v_old_start from futbeat_private.entities where id=v_match;
    -- The fixture has ONE current provider id. The ids it was known by are
    -- kept in provenance (audit) and retired as mappings, so detail /
    -- recovery calls never ask the provider for the dead id.
    select coalesce(jsonb_agg(pe.external_id order by pe.external_id),'[]'::jsonb) into v_old_ids
    from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=v_match and pe.external_id<>v_ext;
    delete from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='match' and pe.canonical_id=v_match and pe.external_id<>v_ext;
    update futbeat_private.entities e set payload=e.payload
      ||jsonb_build_object('startTime',to_jsonb(v_kickoff))
      ||jsonb_build_object('provenance',coalesce(e.payload->'provenance','{}'::jsonb)
        ||jsonb_build_object('externalId',v_ext,'relinkedAt',now(),'previousExternalIds',
          coalesce(e.payload#>'{provenance,previousExternalIds}','[]'::jsonb)||v_old_ids)
        ||case when futbeat_private.try_timestamptz(v_old_start) is distinct from v_kickoff
          then jsonb_build_object('kickoffCorrectedFrom',v_old_start) else '{}'::jsonb end)
    where e.id=v_match and e.kind='match';
    return jsonb_build_object('outcome','relinked','matchId',v_match);
  end if;

  -- b. A fixture the calendar never knew: only while the provider reports it
  -- in play or finished, and recent.
  if v_status not in ('LIVE','HALF_TIME','FINISHED','AFTER_ET','AFTER_PEN','AWARDED') then
    return jsonb_build_object('outcome','skipped','reason','not_in_play');
  end if;
  if v_kickoff<now()-interval '36 hours' or v_kickoff>now()+interval '3 hours' then
    return jsonb_build_object('outcome','skipped','reason','kickoff_out_of_window');
  end if;
  v_match:='fb_match_'||replace(gen_random_uuid()::text,'-','');
  insert into futbeat_private.entities(id,kind,payload)
  values(v_match,'match',jsonb_strip_nulls(jsonb_build_object(
    'id',v_match,'competitionId',v_comp,'homeTeamId',v_home,'awayTeamId',v_away,
    'startTime',to_jsonb(v_kickoff),
    -- Never a provider status: LIVE / final comes from the observations.
    'status','SCHEDULED','events','[]'::jsonb,'statistics','[]'::jsonb,
    'season',nullif(p_fixture->>'leagueYear',''),
    'provenance',jsonb_build_object('source','GOAL API','externalId',v_ext,'receivedAt',now(),
      'verificationStatus','PROVISIONAL','discoveredVia','live-feed'))));
  insert into futbeat_private.provider_entities(provider,kind,external_id,canonical_id)
  values('goal_api','match',v_ext,v_match)
  on conflict(provider,kind,external_id) do nothing;
  if not found then
    -- A writer outside the lock mapped this id meanwhile: keep its match,
    -- never leave a second unmapped entity behind.
    delete from futbeat_private.entities where id=v_match and kind='match';
    select canonical_id into v_match from futbeat_private.provider_entities
     where provider='goal_api' and kind='match' and external_id=v_ext;
    return jsonb_build_object('outcome','already_linked','matchId',v_match);
  end if;
  return jsonb_build_object('outcome','created','matchId',v_match);
end $$;

-- Linker + discovery. The existing linker (provider id, then teams within
-- 3 hours) is untouched and always runs first.
create or replace function futbeat_private.link_and_discover_goal_live_matches(p_fixtures jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_result jsonb; v_fixture jsonb; v_out jsonb; v_ext text; v_match text;
  v_relinked integer:=0; v_created integer:=0; v_still jsonb:='[]'::jsonb; v_unmapped jsonb;
  v_reported text[];
begin
  v_result:=futbeat_private.futbeat_link_goal_live_matches(p_fixtures);
  v_unmapped:=coalesce(v_result->'unmapped','[]'::jsonb);
  if jsonb_array_length(v_unmapped)=0 then
    return v_result||jsonb_build_object('relinked',0,'created',0);
  end if;
  select coalesce(array_agg(distinct nullif(coalesce(value->>'apiId',value->>'id'),'')),'{}')
    into v_reported from jsonb_array_elements(p_fixtures);
  -- Ascending provider id: identity locks are always taken in the same
  -- order as the catalogue resolver takes them (no lock-order deadlock).
  for v_fixture in select value from jsonb_array_elements(p_fixtures)
      order by nullif(coalesce(value->>'apiId',value->>'id'),'') loop
    v_ext:=nullif(coalesce(v_fixture->>'apiId',v_fixture->>'id'),'');
    if v_ext is null or not exists(select 1 from jsonb_array_elements(v_unmapped) u
        where u->>'externalMatchId'=v_ext) then
      continue;
    end if;
    v_out:=futbeat_private.discover_goal_live_match(v_fixture,v_reported);
    if v_out->>'outcome' in ('relinked','created','already_linked') then
      v_match:=v_out->>'matchId';
      if v_out->>'outcome'='relinked' then v_relinked:=v_relinked+1;
      elsif v_out->>'outcome'='created' then v_created:=v_created+1; end if;
      -- Evidence stored while the fixture was unmapped now belongs to it.
      update futbeat_private.live_match_state set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.provider_observations set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.live_events set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      if exists(select 1 from futbeat_private.live_match_state
          where provider='goal_api' and external_match_id=v_ext and canonical_match_id=v_match) then
        perform public.futbeat_publish_live_state('goal_api',v_ext);
      end if;
    else
      v_still:=v_still||(select jsonb_agg(u||jsonb_build_object('discovery',v_out->>'reason'))
        from jsonb_array_elements(v_unmapped) u where u->>'externalMatchId'=v_ext);
    end if;
  end loop;
  return v_result||jsonb_build_object(
    'linked',coalesce((v_result->>'linked')::integer,0)+v_relinked+v_created,
    'relinked',v_relinked,'created',v_created,
    'unmappedCount',jsonb_array_length(v_still),'unmapped',v_still);
end $$;

create or replace function public.futbeat_link_goal_live_matches(p_fixtures jsonb)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.link_and_discover_goal_live_matches(p_fixtures)
$$;

-- The catalogue resolver (calendar / team-fixtures ingest) is the other
-- creator of GOAL match entities. It mapped with "last writer wins", so a
-- concurrent discovery and ingest of one provider id could each create an
-- entity and orphan one of them. It now takes the same per-id lock as
-- discovery (players keep their existing lock); body otherwise unchanged
-- from 20260922041454_player_media_squad_coverage.sql. Its batch caller
-- resolves items ordered by (kind, external id), the order discovery uses.
create or replace function futbeat_private.futbeat_resolve_global_entity(p_provider text,p_kind text,p_external text,
 p_name text default '',p_country text default '',p_short_name text default '') returns text
language plpgsql security definer set search_path='' as $$
begin
 if p_kind='player' then
   perform pg_catalog.pg_advisory_xact_lock(hashtextextended('player:'||p_provider||':'||p_external,0));
 elsif p_kind='match' and p_provider='goal_api' and nullif(p_external,'') is not null then
   perform futbeat_private.goal_match_identity_lock(p_external);
 end if;
 return futbeat_private.resolve_global_entity_before_player_lock(p_provider,p_kind,p_external,p_name,p_country,p_short_name);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Pending terminal recoveries ask the results lane for their date
-- ---------------------------------------------------------------------------

-- Base: settle_terminal_recovery from 20260926100000 (the three settlement
-- updates and the cleanup are verbatim); only the results demand is new.
create or replace function futbeat_private.settle_terminal_recovery()
returns void language plpgsql security definer set search_path='' as $$
declare v_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryMaxAttempts',6)::integer;
  v_demanded integer:=0;
begin
  update futbeat_private.live_terminal_recovery r
  set state='RESOLVED',resolved_at=now(),resolution='terminal_evidence'
  where r.state='PENDING' and r.canonical_match_id is not null
    and futbeat_private.match_effectively_terminal(r.canonical_match_id);
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts'
  where r.state='PENDING' and r.attempts>=v_max;

  -- A recovery still pending after 10 minutes: one results call for its
  -- provider date resolves every final of that date. Same queue, quota
  -- class, caps and per-date backoff as a user opening the match; refreshed
  -- at most hourly per date.
  with dates as (
    select distinct futbeat_private.match_provider_date(r.canonical_match_id) d
    from futbeat_private.live_terminal_recovery r
    where r.provider='goal_api' and r.state='PENDING' and r.canonical_match_id is not null
      and r.detected_at<now()-interval '10 minutes'
  ), asked as (
    insert into futbeat_private.results_date_user_demand as q(provider,provider_date,requested_at,request_count)
    select 'goal_api',d,now(),1 from dates where d is not null
    on conflict(provider,provider_date) do update
      set requested_at=excluded.requested_at,request_count=q.request_count+1
      where q.requested_at<now()-interval '1 hour'
    returning 1
  )
  select count(*) into v_demanded from asked;
  if v_demanded>0 then
    perform futbeat_private.bump_metric('terminal_recovery_results_demands',v_demanded);
    begin
      perform futbeat_private.wake_provider_worker('results-only');
    exception when others then
      -- The periodic results lane still serves the demand.
      null;
    end;
  end if;

  -- A row that can no longer be served (mapping relinked or removed) expires.
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='expired'
  where r.state='PENDING' and r.detected_at<now()-make_interval(
    hours=>futbeat_private.quota_setting('goal_api','terminalRecoveryWindowHours',6)::integer);
  delete from futbeat_private.live_terminal_recovery
  where state<>'PENDING' and coalesce(resolved_at,detected_at)<now()-interval '3 days';
end $$;

revoke all on function
  futbeat_private.goal_match_identity_lock(text),
  futbeat_private.discover_goal_live_match(jsonb,text[]),
  futbeat_private.link_and_discover_goal_live_matches(jsonb),
  futbeat_private.settle_terminal_recovery()
from public,anon,authenticated;
do $$ begin
  if exists(select 1 from pg_roles where rolname='service_role') then
    grant execute on function futbeat_private.link_and_discover_goal_live_matches(jsonb) to service_role;
  end if;
end $$;
