-- Issue #98: Match Center standings that never load.
--
-- Root causes (code as of 20260923180000_standings_season_identity):
--   * The demand lane only selected QUEUED demands with
--     requested_at > now() - demandWindowMinutes (30). A demand recorded while
--     GOAL was below the user_high floor stayed QUEUED forever once it aged
--     past the window: the quota came back but nothing reserved it, and
--     match_standings_state kept reporting it as pending.
--   * Ordering by requested_at desc also let a steady stream of fresh demands
--     starve older ones.
--   * A transient fetch failure parked the demand in FETCH_FAILED, which the
--     worker never retries (only a new open could requeue it).
--   * A QUEUED demand for a season that is no longer the competition's
--     current one (rollover) could never be fetched but stayed "pending".
--
-- Fix (identity stays exactly (competition_id, season_key)):
--   * Durable queue: a QUEUED demand stays eligible regardless of its age
--     while its lease expired, next_retry_at allows it, it is fetchable
--     (current season of a GOAL-mapped competition) and quota_decision allows.
--   * Fairness without starvation: two lanes. "recent" (queued within
--     standingsDemandAgingMinutes, newest request first) and "aged" (oldest
--     queued first). Consecutive user reservations alternate lanes when both
--     have work, so fresh demands stay responsive and every aged demand
--     progresses in FIFO order.
--   * queued_at records when the demand (re)entered QUEUED; deduplicated
--     re-requests bump requested_at (priority) but never reset queued_at.
--   * Before spending provider quota, QUEUED demands already satisfied by a
--     fresh exact snapshot are marked AVAILABLE (no call). A stale snapshot
--     never satisfies the revalidation it was queued for.
--   * Transient failures stay QUEUED with exponential backoff (next_retry_at)
--     up to standingsMaxAutoRetries, then FETCH_FAILED (reopening the match
--     after next_retry_at requeues it). NO_DATA stays a negative cache for
--     standingsNoDataDays; opening the match never requeues it early.
--   * QUEUED demands whose season is no longer current are closed as NO_DATA
--     (they can never be fetched), so nothing is pending forever.
--   * match_standings_state returns exactly one of available | pending |
--     unavailable | missing, plus standingsStale / standingsPending. A stale
--     exact table stays "available" (shown) while it is revalidated.

alter table futbeat_private.standings_demands add column if not exists queued_at timestamptz;
update futbeat_private.standings_demands set queued_at=requested_at where queued_at is null;
alter table futbeat_private.standings_demands alter column queued_at set default now();
alter table futbeat_private.standings_demands alter column queued_at set not null;
create index if not exists standings_demands_queued_idx
  on futbeat_private.standings_demands(queued_at) where status='QUEUED';

update futbeat_private.provider_quota_policy set
  freshness=freshness||'{"standingsDemandAgingMinutes":30,"standingsMaxAutoRetries":5}',
  updated_at=now()
where provider='goal_api';

-- Freshness an exact snapshot of this competition must meet (shorter while
-- one of its matches is live).
create or replace function futbeat_private.standings_fresh_for(p_competition_id text)
returns interval language sql stable set search_path='' as $$
  select case when exists(select 1 from futbeat_private.entities x where x.kind='match'
      and x.payload->>'competitionId'=p_competition_id
      and x.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES'))
    then make_interval(mins=>futbeat_private.quota_setting('goal_api','standingsActiveMinutes',30)::integer)
    else make_interval(hours=>futbeat_private.quota_setting('goal_api','standingsHours',6)::integer) end
$$;

-- Exact-identity standings state for one match (read-only).
create or replace function futbeat_private.match_standings_state(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare m jsonb; comp text; v_key text; current_key text; ext text; snap futbeat_private.standings_snapshots;
  dem futbeat_private.standings_demands; fresh_for interval; fetchable boolean; queued boolean; state text;
  alias_ids text[];
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
  with recursive ids(id,depth) as (
    select comp,0
    union
    select r.alias_id,ids.depth+1 from futbeat_private.entity_redirects r
    join ids on r.kind='competition' and r.canonical_id=ids.id
    where ids.depth<8
  )
  select array_agg(id) into alias_ids from ids;
  select pe.external_id into ext from futbeat_private.provider_entities pe
  where pe.canonical_id=any(alias_ids) and pe.provider='goal_api' and pe.kind='competition'
  order by pe.external_id limit 1;
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
declare v_satisfied integer; v_closed integer;
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
  if v_satisfied>0 then perform futbeat_private.bump_metric('standings_demands_reconciled',v_satisfied); end if;
  if v_closed>0 then perform futbeat_private.bump_metric('standings_demands_season_closed',v_closed); end if;
  return jsonb_build_object('satisfied',v_satisfied,'closed',v_closed);
end $$;

-- p_demand_only=true: the worker's demand lane (user demands, completed via
-- futbeat_complete_standings_call). false (existing workflow/ingest path):
-- coverage refresh only (unchanged).
create or replace function futbeat_private.futbeat_reserve_goal_standings_call(
  p_trigger_source text default 'github-actions',
  p_demand_only boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  aging interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','standingsDemandAgingMinutes',30)::integer);
  decision jsonb; dem futbeat_private.standings_demands; v_id bigint; cand record; last_lane text;
  prefer_aged boolean; v_lane text; reconciled jsonb;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  if p_demand_only then
    -- DB-only reconciliation first: never pay for a table we already have.
    reconciled:=futbeat_private.reconcile_standings_demands();
    -- 1. Standings a user is waiting for (exact competition + season). The
    -- age of a demand never makes it ineligible (durable queue).
    decision:=futbeat_private.quota_decision('goal_api','standings','user_high');
    if not (decision->>'allowed')::boolean then
      return jsonb_build_object('allowed',false,'reason',decision->>'reason',
        'providerRemaining',decision->'providerRemaining','reconciled',reconciled);
    end if;
    -- Alternate lanes: after an aged demand serve a recent one and vice versa.
    select l.metadata->>'lane' into last_lane from futbeat_private.provider_call_ledger l
    where l.provider='goal_api' and l.call_kind='standings' and l.metadata->>'source'='user'
      and l.reserved_at>now()-interval '1 day'
    order by l.reserved_at desc,l.id desc limit 1;
    prefer_aged:=coalesce(last_lane,'recent')<>'aged';
    select * into dem from futbeat_private.standings_demands d
    where d.status='QUEUED'
      and coalesce(d.lease_until,'-infinity')<=now() and coalesce(d.next_retry_at,'-infinity')<=now()
      -- Only the competition's current season can be fetched.
      and d.season_key=futbeat_private.competition_season_key(d.competition_id)
    order by
      case when (d.queued_at<=now()-aging)=prefer_aged then 0 else 1 end,
      -- aged lane: oldest queued first (FIFO); recent lane: newest request first.
      case when d.queued_at<=now()-aging then extract(epoch from d.queued_at)
        else -extract(epoch from d.requested_at) end,
      d.competition_id,d.season_key
    limit 1 for update skip locked;
    if dem.competition_id is null then
      return jsonb_build_object('allowed',false,'reason','no_standings_demand',
        'providerRemaining',decision->'providerRemaining','reconciled',reconciled);
    end if;
    v_lane:=case when dem.queued_at<=now()-aging then 'aged' else 'recent' end;
    update futbeat_private.standings_demands set lease_until=now()+lease,last_attempt_at=now()
    where competition_id=dem.competition_id and season_key=dem.season_key;
    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
    values('goal_api','standings',left(p_trigger_source,40),now(),jsonb_build_object('competitionId',dem.competition_id,
      'externalLeagueId',dem.external_league_id,'seasonKey',dem.season_key,'source','user','lane',v_lane,
      'queuedAt',dem.queued_at))
    returning id into v_id;
    return decision||jsonb_build_object('allowed',true,'reservationId',v_id,'competitionId',dem.competition_id,
      'externalLeagueId',dem.external_league_id,'seasonKey',dem.season_key,'source','user','lane',v_lane,
      'reconciled',reconciled);
  end if;

  -- 2. Coverage refresh: mapped competitions with nearby matches, oldest first.
  decision:=futbeat_private.quota_decision('goal_api','standings','coverage');
  if not (decision->>'allowed')::boolean then return decision; end if;
  select pe.canonical_id competition_id,pe.external_id external_league_id,e.payload->>'name' name,
    e.payload->>'country' country,sc.fetched_at
  into cand
  from futbeat_private.provider_entities pe
  join futbeat_private.entities e on e.id=pe.canonical_id and e.kind='competition'
  left join futbeat_private.standings_cache sc on sc.competition_id=pe.canonical_id
  left join futbeat_private.coverage_interests ci on ci.subject_type='competition' and ci.subject_id=pe.canonical_id
  where pe.provider='goal_api' and pe.kind='competition'
    and (sc.fetched_at is null or sc.fetched_at<now()-make_interval(
      hours=>futbeat_private.quota_setting('goal_api','standingsHours',6)::integer))
    and exists(select 1 from futbeat_private.entities m where m.kind='match'
      and m.payload->>'competitionId'=pe.canonical_id and nullif(m.payload->>'startTime','') is not null
      and (m.payload->>'startTime')::timestamptz between now()-interval '45 days' and now()+interval '45 days')
    and not exists(select 1 from futbeat_private.entities a where a.kind='match'
      and a.payload->>'competitionId'=pe.canonical_id and nullif(a.payload->>'startTime','') is not null
      and coalesce(a.payload->>'status','') not in ('FINISHED_PENDING_VERIFICATION','VERIFIED','POSTPONED','ABANDONED','CANCELLED')
      and now() between (a.payload->>'startTime')::timestamptz-interval '5 minutes'
        and (a.payload->>'startTime')::timestamptz+interval '135 minutes')
  order by coalesce(ci.priority_score,0) desc,sc.fetched_at nulls first,e.payload->>'name',pe.canonical_id
  limit 1;
  if cand.competition_id is null then
    return jsonb_build_object('allowed',false,'reason','no_standings_due','providerRemaining',decision->'providerRemaining');
  end if;
  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','standings',left(p_trigger_source,40),now(),jsonb_build_object('competitionId',cand.competition_id,
    'externalLeagueId',cand.external_league_id,'source','coverage'))
  returning id into v_id;
  return decision||jsonb_build_object('allowed',true,'reservationId',v_id,'competitionId',cand.competition_id,
    'externalLeagueId',cand.external_league_id,'name',cand.name,'country',cand.country,
    'lastFetchedAt',cand.fetched_at,'source','coverage');
end $$;

-- Completion for demand fetches: ledger + demand bookkeeping.
--   * exact season stored            -> AVAILABLE (archive trigger)
--   * answered without that season   -> NO_DATA (negative cache, days)
--   * 404                            -> NO_DATA
--   * transient failure              -> QUEUED with backoff, FETCH_FAILED
--                                       after standingsMaxAutoRetries
create or replace function public.futbeat_complete_standings_call(p_reservation_id bigint,
  p_succeeded boolean,p_http_status integer default null,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; stored boolean; v_status text; failures integer;
  max_retries integer:=futbeat_private.quota_setting('goal_api','standingsMaxAutoRetries',5)::integer;
begin
  update futbeat_private.provider_call_ledger set status=case when p_succeeded then 'SUCCEEDED' else 'FAILED' end,
    completed_at=now(),provider_remaining=p_provider_remaining,
    http_status=case when p_http_status between 100 and 599 then p_http_status end,
    error_code=case when p_succeeded then null else 'GOAL_STANDINGS_FETCH_FAILED' end
  where id=p_reservation_id and provider='goal_api' and call_kind='standings' and status='RESERVED'
  returning metadata into meta;
  if meta is null then raise exception 'Unknown or completed standings reservation'; end if;
  if meta->>'seasonKey' is null then return jsonb_build_object('status','coverage'); end if;
  stored:=exists(select 1 from futbeat_private.standings_snapshots s where s.competition_id=meta->>'competitionId'
    and s.season_key=meta->>'seasonKey' and s.fetched_at>=now()-interval '15 minutes');
  if stored then
    -- The archive trigger already answered the demand; make sure the lease is released.
    update futbeat_private.standings_demands d set status='AVAILABLE',lease_until=null,failure_count=0,
      next_retry_at=null,last_error=null
    where d.competition_id=meta->>'competitionId' and d.season_key=meta->>'seasonKey' and d.status<>'AVAILABLE';
    return jsonb_build_object('status','AVAILABLE');
  end if;
  select d.failure_count+1 into failures from futbeat_private.standings_demands d
  where d.competition_id=meta->>'competitionId' and d.season_key=meta->>'seasonKey' for update;
  v_status:=case when p_succeeded or p_http_status=404 then 'NO_DATA'
    when coalesce(failures,1)<max_retries then 'QUEUED'
    else 'FETCH_FAILED' end;
  if p_succeeded then
    -- The provider answered but not for the demanded season (format or
    -- rollover mismatch): make it visible instead of silently empty.
    perform futbeat_private.bump_metric('standings_season_mismatch');
  end if;
  update futbeat_private.standings_demands d set status=v_status,lease_until=null,failure_count=coalesce(failures,1),
    last_error=case when v_status='NO_DATA' then left('no table for this season, latest stored: '||coalesce((
      select string_agg(s.season_key,',' order by s.fetched_at desc) from futbeat_private.standings_snapshots s
      where s.competition_id=meta->>'competitionId' and s.fetched_at>=now()-interval '15 minutes'),'none'),120)
      else 'fetch failed' end,
    next_retry_at=now()+case when v_status='NO_DATA'
      then make_interval(days=>futbeat_private.quota_setting('goal_api','standingsNoDataDays',3)::integer)
      else least(interval '6 hours',interval '5 minutes'*power(2,least(coalesce(failures,1)-1,6))) end
  where d.competition_id=meta->>'competitionId' and d.season_key=meta->>'seasonKey';
  return jsonb_build_object('status',v_status);
end $$;

revoke all on function
  futbeat_private.standings_fresh_for(text),
  futbeat_private.match_standings_state(text),
  futbeat_private.reconcile_standings_demands(),
  futbeat_private.futbeat_reserve_goal_standings_call(text,boolean)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_request_match_standings(text),
  public.futbeat_complete_standings_call(bigint,boolean,integer,integer)
from public,anon,authenticated;
grant execute on function
  public.futbeat_request_match_standings(text),
  public.futbeat_complete_standings_call(bigint,boolean,integer,integer)
to service_role;

notify pgrst,'reload schema';
