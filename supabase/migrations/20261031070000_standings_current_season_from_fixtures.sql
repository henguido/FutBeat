-- BE-205: a competition's "current season" is no longer decided by a possibly
-- stale competition entity field alone.
--
-- Production defect (BE-181, 2026-10-30): Serie A canonical competition had
-- entity payload season "2025/2026" while its recent fixtures (233 of 262) were
-- "2026/2027". futbeat_private.competition_season_key (20260923180000:58) read
-- only normalize_season(entity.payload->>'season'), so:
--   * match_standings_state (20260925030000:85) marked the 2026-2027 demand as
--     not fetchable (v_key <> current_key);
--   * reconcile_standings_demands (20260925030000:176) closed the user demand
--     as NO_DATA 'season is no longer current' with a standingsNoDataDays TTL;
--   * the demand lane (20260925050000:131) never selected it;
--   * opening the match never requeued it (negative cache).
-- Liga MX had a demand closed the same way while its entity was briefly stale.
--
-- Why the entity season goes stale: every GOAL fixture writer rebuilds the
-- competition entity from the fixture being normalized
-- (backend/providers/goal_api.mjs:166-178: season = fixture.leagueYear, last
-- fixture of the batch wins) and the calendar/hot-window stores upsert that
-- payload whenever it differs (20261030030000:37-40). A batch whose last
-- fixture of the competition belongs to the previous season (late/postponed
-- fixture, past-date calendar or results pass) rolls the entity back, and no
-- later batch necessarily rewrites it. The field is "season of the last
-- written fixture", not "current season".
--
-- Fix (general, no competition special-cased, identity stays exactly
-- (competition_id, season_key); tables of different seasons or groups are
-- never mixed because nothing here touches snapshots or group selection):
--   * competition_season_key = the most advanced season among the entity
--     season and the seasons of the competition's fixtures that started in
--     the last 180 days (indexed by entities_match_competition_idx). Order:
--     season_rank (end year, then start year: "2026/2027" > "2025/2026",
--     "2026" > "2025"; text labels such as Apertura/Clausura rank by their
--     year), then the latest started fixture, then the entity. A fixture
--     season that starts after the year the fixture was played is ignored
--     (mislabelled). An entity that
--     is ahead (new season announced, opener not played) still wins, as
--     before; an entity that is behind its own fixtures no longer does. A
--     stray replayed fixture of an older season never rolls it back.
--   * reconcile_standings_demands closes a QUEUED demand as "season is no
--     longer current" only when the season is not current AND has no fixture
--     from 3 days ago onwards (a season with current fixtures is never
--     closed).
--   * Demands closed by this bug (NO_DATA, last_error exactly 'season is no
--     longer current') whose season IS current now are reopened: reconcile
--     requeues them (no provider call by itself; the demand lane serves it
--     under the normal quota decision), match_standings_state reports them
--     due/not unavailable, and opening the match requeues them before
--     next_retry_at. A truly finished season never becomes current again, so
--     it stays closed. Self-healing: no data migration.
-- Public response shapes are unchanged (reconcile's internal summary gains a
-- "reopened" counter).
-- Rollback: supabase/manual/20261031070000_standings_current_season_from_fixtures_rollback.sql
-- (previous bodies of the three functions + drop of the two helpers).

-- Order of a normalized season key: end year * 10000 + start year.
-- '2026-2027' -> 20272026, '2026' -> 20262026, 'apertura 2026' -> 20262026,
-- no year -> null (ranked last).
create or replace function futbeat_private.season_rank(p_key text)
returns bigint language plpgsql immutable set search_path='' as $$
declare m text[]; y integer;
begin
  if p_key is null or p_key='' then return null; end if;
  m:=regexp_match(p_key,'^(\d{4})-(\d{4})$');
  if m is not null then return m[2]::bigint*10000+m[1]::bigint; end if;
  select max(x[1]::integer) into y from regexp_matches(p_key,'(\d{4})','g') x;
  if y is null then return null; end if;
  return y::bigint*10000+y;
end $$;

create or replace function futbeat_private.competition_season_key(p_competition_id text)
returns text language plpgsql stable set search_path='' as $$
declare comp text:=futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id);
  entity_key text; best text;
begin
  select futbeat_private.normalize_season(e.payload->>'season') into entity_key
  from futbeat_private.entities e where e.id=comp and e.kind='competition';
  if not found then return null; end if;
  with recent as (
    select futbeat_private.normalize_season(m.payload->>'season') k,
      max((m.payload->>'startTime')::timestamptz) last_start
    from futbeat_private.entities m
    where m.kind='match' and m.payload->>'competitionId'=comp
      and nullif(m.payload->>'startTime','') is not null
      and coalesce(m.payload->>'status','') not in ('CANCELLED','POSTPONED')
      and (m.payload->>'startTime')::timestamptz between now()-interval '180 days' and now()
    group by 1
  ), cand as (
    -- A fixture never belongs to a season that starts after the year it was
    -- played in (a mislabelled fixture cannot jump the season ahead).
    select r.k,r.last_start,false is_entity from recent r where r.k<>''
      and coalesce(futbeat_private.season_rank(r.k)%10000<=extract(year from r.last_start),true)
    union all
    select entity_key,(select r.last_start from recent r where r.k=entity_key),true
    where entity_key<>''
  )
  select c.k into best from cand c
  order by futbeat_private.season_rank(c.k) desc nulls last,c.last_start desc nulls last,c.is_entity desc
  limit 1;
  return coalesce(best,entity_key);
end $$;

-- A season with fixtures from 3 days ago onwards (recent or upcoming) is still
-- being played: never closed as finished.
create or replace function futbeat_private.competition_season_active(p_competition_id text,p_season_key text)
returns boolean language sql stable set search_path='' as $$
  select exists(select 1 from futbeat_private.entities m
    where m.kind='match' and m.payload->>'competitionId'=p_competition_id
      and nullif(m.payload->>'startTime','') is not null
      and coalesce(m.payload->>'status','') not in ('CANCELLED','POSTPONED')
      and futbeat_private.normalize_season(m.payload->>'season')=p_season_key
      and (m.payload->>'startTime')::timestamptz>=now()-interval '3 days')
$$;

-- Exact-identity standings state for one match (read-only). Body of
-- 20260925030000 plus: a demand closed as "season is no longer current" whose
-- season is current (fetchable) again is not a negative cache.
create or replace function futbeat_private.match_standings_state(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare m jsonb; comp text; v_key text; current_key text; ext text; snap futbeat_private.standings_snapshots;
  dem futbeat_private.standings_demands; fresh_for interval; fetchable boolean; queued boolean; state text;
  reopenable boolean;
begin
  select payload into m from futbeat_private.entities where id=p_match_id and kind='match';
  if m is null then return null; end if;
  comp:=futbeat_private.futbeat_resolve_entity_id('competition',m->>'competitionId');
  v_key:=futbeat_private.normalize_season(m->>'season');
  if comp is null or v_key='' then
    return jsonb_build_object('standings','missing','standingsPending',false,'standingsStale',false,
      'competitionId',comp,'seasonKey',nullif(v_key,''),'due',false);
  end if;
  current_key:=futbeat_private.competition_season_key(comp);
  -- Mapping of this canonical competition or of any alias redirected to it.
  ext:=futbeat_private.standings_provider_league_id(comp);
  -- GOAL serves the competition's current table only: other seasons are
  -- available only if they were archived while current.
  fetchable:=ext is not null and v_key=coalesce(current_key,'');
  select * into snap from futbeat_private.standings_snapshots s where s.competition_id=comp and s.season_key=v_key;
  select * into dem from futbeat_private.standings_demands d where d.competition_id=comp and d.season_key=v_key;
  fresh_for:=futbeat_private.standings_fresh_for(comp);
  -- BE-205: closed while a stale entity season made it look finished.
  reopenable:=fetchable and coalesce(dem.status='NO_DATA' and dem.last_error='season is no longer current',false);
  -- Pending only while it can still be answered.
  queued:=fetchable and coalesce(dem.status='QUEUED' or dem.lease_until>now(),false);
  state:=case
    when snap.competition_id is not null then 'available'
    when queued then 'pending'
    when dem.status in ('NO_DATA','FETCH_FAILED') and dem.next_retry_at>now() and not reopenable then 'unavailable'
    else 'missing' end;
  return jsonb_build_object(
    'standings',state,
    'standingsStale',snap.competition_id is not null and fetchable and snap.fetched_at<now()-fresh_for,
    'standingsPending',queued,
    'competitionId',comp,'seasonKey',v_key,'fetchable',fetchable,
    'externalLeagueId',ext,'demandStatus',dem.status,
    'demandRetryAt',dem.next_retry_at,
    'due',fetchable and (snap.competition_id is null or snap.fetched_at<now()-fresh_for)
      and (coalesce(dem.next_retry_at,'-infinity')<=now() or reopenable));
end $$;

-- Opening a match: body of 20260925030000 plus: re-entering the queue from a
-- closed state clears next_retry_at (re-entry only happens when due, i.e. the
-- TTL already passed or the demand is reopenable), so the demand lane can
-- select it at once.
create or replace function public.futbeat_request_match_standings(p_match_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare st jsonb:=futbeat_private.match_standings_state(p_match_id); comp text; key text; prev text;
begin
  if st is null then return null; end if;
  -- Not due: fresh table, not fetchable, or a negative cache/backoff still
  -- running (NO_DATA with next_retry_at in the future is never requeued).
  if not coalesce((st->>'due')::boolean,false) then
    if st->>'standings'='available' then perform futbeat_private.bump_metric('standings_cache_hits'); end if;
    return st-'due'-'externalLeagueId'-'fetchable'-'demandStatus';
  end if;
  comp:=st->>'competitionId'; key:=st->>'seasonKey';
  perform pg_advisory_xact_lock(hashtext('futbeat-standings-demand'),hashtext(comp||'|'||key));
  select status into prev from futbeat_private.standings_demands where competition_id=comp and season_key=key;
  insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id,queued_at)
  values(comp,key,st->>'externalLeagueId',now())
  on conflict(competition_id,season_key) do update set
    request_count=futbeat_private.standings_demands.request_count+1,
    requested_at=now(),external_league_id=excluded.external_league_id,
    -- Re-entering the queue starts a new episode; a dedup keeps its age.
    queued_at=case when futbeat_private.standings_demands.status='QUEUED'
      then futbeat_private.standings_demands.queued_at else now() end,
    failure_count=case when futbeat_private.standings_demands.status='QUEUED'
      then futbeat_private.standings_demands.failure_count else 0 end,
    next_retry_at=case when futbeat_private.standings_demands.status='QUEUED'
      then futbeat_private.standings_demands.next_retry_at end,
    status='QUEUED';
  if prev='QUEUED' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('standings_user_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return (futbeat_private.match_standings_state(p_match_id))-'due'-'externalLeagueId'-'fetchable'-'demandStatus';
end $$;

-- Queue hygiene without provider calls. Body of 20260925030000 plus the BE-205
-- reopen step and the "still being played" guard on the season closure.
create or replace function futbeat_private.reconcile_standings_demands()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_satisfied integer; v_closed integer; v_remapped integer; v_unmapped integer; v_reopened integer;
begin
  -- Demands closed as "no longer current" whose season is current again
  -- (closed while the entity season was stale): back to the queue.
  with reopened as (
    update futbeat_private.standings_demands d set status='QUEUED',lease_until=null,failure_count=0,
      queued_at=now(),next_retry_at=null,last_error=null
    where d.status='NO_DATA' and d.last_error='season is no longer current'
      and d.season_key=futbeat_private.competition_season_key(d.competition_id)
    returning 1)
  select count(*) into v_reopened from reopened;
  with done as (
    update futbeat_private.standings_demands d set status='AVAILABLE',lease_until=null,failure_count=0,
      last_success_at=s.fetched_at,next_retry_at=null,last_error=null
    from futbeat_private.standings_snapshots s
    where d.status='QUEUED' and coalesce(d.lease_until,'-infinity')<=now()
      and s.competition_id=d.competition_id and s.season_key=d.season_key
      and s.fetched_at>=now()-futbeat_private.standings_fresh_for(d.competition_id)
    returning 1)
  select count(*) into v_satisfied from done;
  with closed as (
    update futbeat_private.standings_demands d set status='NO_DATA',lease_until=null,
      last_error='season is no longer current',
      next_retry_at=now()+make_interval(days=>futbeat_private.quota_setting('goal_api','standingsNoDataDays',3)::integer)
    where d.status='QUEUED' and coalesce(d.lease_until,'-infinity')<=now()
      and d.season_key<>coalesce(futbeat_private.competition_season_key(d.competition_id),'')
      and futbeat_private.competition_season_key(d.competition_id)<>''
      -- A season with current fixtures is never "no longer current".
      and not futbeat_private.competition_season_active(d.competition_id,d.season_key)
    returning 1)
  select count(*) into v_closed from closed;
  -- Provider mapping is revalidated, never trusted from the demand row: a
  -- changed mapping is updated in place (same demand), a removed one closes
  -- the demand without spending quota. Short retry: once remapped, reopening
  -- the match can queue it again.
  with m as (
    select d.competition_id,d.season_key,futbeat_private.standings_provider_league_id(d.competition_id) ext
    from futbeat_private.standings_demands d
    where d.status='QUEUED' and coalesce(d.lease_until,'-infinity')<=now()
  ), remapped as (
    update futbeat_private.standings_demands d set external_league_id=m.ext
    from m where d.competition_id=m.competition_id and d.season_key=m.season_key
      and m.ext is not null and m.ext<>d.external_league_id
    returning 1
  ), unmapped as (
    update futbeat_private.standings_demands d set status='NO_DATA',lease_until=null,
      last_error='provider mapping unavailable',
      next_retry_at=now()+make_interval(mins=>futbeat_private.quota_setting('goal_api','standingsUnmappedRetryMinutes',60)::integer)
    from m where d.competition_id=m.competition_id and d.season_key=m.season_key and m.ext is null
    returning 1
  )
  select (select count(*) from remapped),(select count(*) from unmapped) into v_remapped,v_unmapped;
  if v_reopened>0 then perform futbeat_private.bump_metric('standings_demands_season_reopened',v_reopened); end if;
  if v_satisfied>0 then perform futbeat_private.bump_metric('standings_demands_reconciled',v_satisfied); end if;
  if v_remapped>0 then perform futbeat_private.bump_metric('standings_demands_remapped',v_remapped); end if;
  if v_unmapped>0 then perform futbeat_private.bump_metric('standings_demands_unmapped',v_unmapped); end if;
  if v_closed>0 then perform futbeat_private.bump_metric('standings_demands_season_closed',v_closed); end if;
  return jsonb_build_object('satisfied',v_satisfied,'closed',v_closed,'remapped',v_remapped,
    'unmapped',v_unmapped,'reopened',v_reopened);
end $$;

revoke all on function
  futbeat_private.season_rank(text),
  futbeat_private.competition_season_key(text),
  futbeat_private.competition_season_active(text,text),
  futbeat_private.match_standings_state(text),
  futbeat_private.reconcile_standings_demands()
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_request_match_standings(text) from public,anon,authenticated;
grant execute on function public.futbeat_request_match_standings(text) to service_role;

notify pgrst,'reload schema';
