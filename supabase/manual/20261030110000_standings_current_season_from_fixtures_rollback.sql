-- Rollback of 20261030110000_standings_current_season_from_fixtures (BE-205).
-- Restores the previous bodies verbatim:
--   competition_season_key  <- 20260923180000_standings_season_identity.sql:58-62
--   match_standings_state, futbeat_request_match_standings,
--   reconcile_standings_demands <- 20260925030000_standings_demand_lifecycle.sql:85-211
-- then drops the two BE-205 helpers. No table or row is touched: demands
-- reopened by the BE-205 reconcile stay as they are (QUEUED/AVAILABLE/NO_DATA
-- under the previous lifecycle). Run in one transaction.
begin;

create or replace function futbeat_private.competition_season_key(p_competition_id text)
returns text language sql stable set search_path='' as $$
  select futbeat_private.normalize_season(e.payload->>'season') from futbeat_private.entities e
  where e.id=futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id) and e.kind='competition'
$$;

-- Exact-identity standings state for one match (read-only).
create or replace function futbeat_private.match_standings_state(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare m jsonb; comp text; v_key text; current_key text; ext text; snap futbeat_private.standings_snapshots;
  dem futbeat_private.standings_demands; fresh_for interval; fetchable boolean; queued boolean; state text;
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
  -- Pending only while it can still be answered.
  queued:=fetchable and coalesce(dem.status='QUEUED' or dem.lease_until>now(),false);
  state:=case
    when snap.competition_id is not null then 'available'
    when queued then 'pending'
    when dem.status in ('NO_DATA','FETCH_FAILED') and dem.next_retry_at>now() then 'unavailable'
    else 'missing' end;
  return jsonb_build_object(
    'standings',state,
    'standingsStale',snap.competition_id is not null and fetchable and snap.fetched_at<now()-fresh_for,
    'standingsPending',queued,
    'competitionId',comp,'seasonKey',v_key,'fetchable',fetchable,
    'externalLeagueId',ext,'demandStatus',dem.status,
    'demandRetryAt',dem.next_retry_at,
    'due',fetchable and (snap.competition_id is null or snap.fetched_at<now()-fresh_for)
      and coalesce(dem.next_retry_at,'-infinity')<=now());
end $$;

-- Opening a match: cache hit, or one deduplicated demand per (competition, season).
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
    status='QUEUED';
  if prev='QUEUED' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('standings_user_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return (futbeat_private.match_standings_state(p_match_id))-'due'-'externalLeagueId'-'fetchable'-'demandStatus';
end $$;

-- Queue hygiene without provider calls: demands already answered by a fresh
-- exact snapshot become AVAILABLE; demands for a season that is no longer
-- current can never be fetched and are closed as NO_DATA.
create or replace function futbeat_private.reconcile_standings_demands()
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_satisfied integer; v_closed integer; v_remapped integer; v_unmapped integer;
begin
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
  if v_satisfied>0 then perform futbeat_private.bump_metric('standings_demands_reconciled',v_satisfied); end if;
  if v_remapped>0 then perform futbeat_private.bump_metric('standings_demands_remapped',v_remapped); end if;
  if v_unmapped>0 then perform futbeat_private.bump_metric('standings_demands_unmapped',v_unmapped); end if;
  if v_closed>0 then perform futbeat_private.bump_metric('standings_demands_season_closed',v_closed); end if;
  return jsonb_build_object('satisfied',v_satisfied,'closed',v_closed,'remapped',v_remapped,'unmapped',v_unmapped);
end $$;

drop function if exists futbeat_private.competition_season_active(text,text);
drop function if exists futbeat_private.season_rank(text);

revoke all on function
  futbeat_private.competition_season_key(text),
  futbeat_private.match_standings_state(text),
  futbeat_private.reconcile_standings_demands()
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_request_match_standings(text) from public,anon,authenticated;
grant execute on function public.futbeat_request_match_standings(text) to service_role;

commit;
notify pgrst,'reload schema';
