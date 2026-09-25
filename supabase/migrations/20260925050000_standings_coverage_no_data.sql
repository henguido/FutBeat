-- Issue #116: GOAL "no standings for this league" is a stable NO_DATA, not a
-- failed scheduled workflow.
--
-- Root cause: the standings workflow (coverage lane) used Invoke-RestMethod,
-- which throws on the provider's 404 STANDINGS_NOT_FOUND before the body can
-- be read; the catch recorded GOAL_STANDINGS_FETCH_FAILED (httpStatus null)
-- and failed the run. Coverage freshness only looks at standings_cache, which
-- is never written for a league without a table, so the same competition was
-- selected again on every run.
--
-- Model (coverage lane only; the #98 user-demand lifecycle in
-- standings_demands is untouched):
--   * standings_coverage_state(competition_id canonical): NO_DATA with
--     next_retry_at = now + standingsNoDataDays (central setting, default 3,
--     the same TTL as user-demand NO_DATA). Its identity is the canonical
--     competition + the external league id that answered "no table" + the
--     competition's current season_key at that moment (resolved server-side
--     by competition_season_key, '' when unknown). A different current
--     mapping OR a different current season (rollover, or a season that
--     becomes known) makes the competition eligible again at once.
--   * futbeat_record_standings_no_data completes a coverage reservation as
--     SUCCEEDED (the provider answered correctly: no such resource) with the
--     real HTTP status and the provider code in metadata, and writes the state.
--   * The coverage planner skips a competition while its NO_DATA is valid for
--     its current mapping.
--   * Any stored table for the competition (standings_cache write) clears the
--     negative cache.

create table if not exists futbeat_private.standings_coverage_state(
  competition_id text primary key references futbeat_private.entities(id) on delete cascade,
  status text not null check(status in ('NO_DATA')),
  external_league_id text not null,
  -- normalize_season of the competition's season when NO_DATA was recorded
  -- ('' = unknown; a season that becomes known is a new identity).
  season_key text not null default '',
  provider_error_code text,
  http_status integer check(http_status is null or http_status between 100 and 599),
  last_attempt_at timestamptz not null default now(),
  next_retry_at timestamptz not null,
  updated_at timestamptz not null default now()
);
create index if not exists standings_coverage_state_retry_idx
  on futbeat_private.standings_coverage_state(next_retry_at);
alter table futbeat_private.standings_coverage_state enable row level security;
revoke all on futbeat_private.standings_coverage_state from public,anon,authenticated;

-- Completion of a coverage reservation whose provider answer means "this
-- league has no standings". Identity comes from the reservation, never from
-- the caller or a name.
create or replace function public.futbeat_record_standings_no_data(
  p_reservation_id bigint,
  p_http_status integer default null,
  p_provider_code text default null,
  p_provider_remaining integer default null,
  p_competition_id text default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; retry_at timestamptz:=now()+make_interval(
    days=>futbeat_private.quota_setting('goal_api','standingsNoDataDays',3)::integer);
  code text:=left(coalesce(nullif(btrim(p_provider_code),''),'NO_DATA'),80);
begin
  update futbeat_private.provider_call_ledger set status='SUCCEEDED',completed_at=now(),
    provider_remaining=p_provider_remaining,
    http_status=case when p_http_status between 100 and 599 then p_http_status end,
    error_code=null,
    metadata=metadata||jsonb_build_object('outcome','NO_DATA','providerCode',code,'mode','standings')
  where id=p_reservation_id and provider='goal_api' and call_kind='standings' and status='RESERVED'
    and metadata->>'source'='coverage'
    and (p_competition_id is null or metadata->>'competitionId'=p_competition_id)
  returning metadata into meta;
  if meta is null then raise exception 'Unknown or completed standings coverage reservation'; end if;
  insert into futbeat_private.standings_coverage_state as s(
    competition_id,status,external_league_id,season_key,provider_error_code,http_status,last_attempt_at,next_retry_at,updated_at)
  values(meta->>'competitionId','NO_DATA',meta->>'externalLeagueId',
    coalesce(futbeat_private.competition_season_key(meta->>'competitionId'),''),code,
    case when p_http_status between 100 and 599 then p_http_status end,now(),retry_at,now())
  on conflict(competition_id) do update set status='NO_DATA',external_league_id=excluded.external_league_id,
    season_key=excluded.season_key,provider_error_code=excluded.provider_error_code,http_status=excluded.http_status,
    last_attempt_at=now(),next_retry_at=excluded.next_retry_at,updated_at=now();
  perform futbeat_private.bump_metric('standings_coverage_no_data');
  return jsonb_build_object('status','NO_DATA','competitionId',meta->>'competitionId',
    'externalLeagueId',meta->>'externalLeagueId',
    'seasonKey',coalesce(futbeat_private.competition_season_key(meta->>'competitionId'),''),
    'providerCode',code,'retryAt',retry_at);
end $$;

-- A stored table (any writer) ends the negative cache for the competition.
create or replace function futbeat_private.clear_standings_coverage_no_data()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  delete from futbeat_private.standings_coverage_state s where s.competition_id=new.competition_id;
  return new;
end $$;
drop trigger if exists standings_coverage_no_data_clear on futbeat_private.standings_cache;
create trigger standings_coverage_no_data_clear after insert or update on futbeat_private.standings_cache
for each row execute function futbeat_private.clear_standings_coverage_no_data();

-- Reservation (copied from 20260925030000, unchanged except the coverage
-- negative cache filter).
create or replace function futbeat_private.futbeat_reserve_goal_standings_call(
  p_trigger_source text default 'github-actions',
  p_demand_only boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  aging interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','standingsDemandAgingMinutes',30)::integer);
  decision jsonb; dem futbeat_private.standings_demands; v_id bigint; cand record; last_lane text;
  prefer_aged boolean; v_lane text; reconciled jsonb; v_ext text;
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
    -- Always the current mapping (reconciled above, under the quota lock).
    v_ext:=futbeat_private.standings_provider_league_id(dem.competition_id);
    if v_ext is null then
      return jsonb_build_object('allowed',false,'reason','no_standings_demand',
        'providerRemaining',decision->'providerRemaining','reconciled',reconciled);
    end if;
    update futbeat_private.standings_demands set lease_until=now()+lease,last_attempt_at=now(),external_league_id=v_ext
    where competition_id=dem.competition_id and season_key=dem.season_key;
    insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
    values('goal_api','standings',left(p_trigger_source,40),now(),jsonb_build_object('competitionId',dem.competition_id,
      'externalLeagueId',v_ext,'seasonKey',dem.season_key,'source','user','lane',v_lane,
      'queuedAt',dem.queued_at))
    returning id into v_id;
    return decision||jsonb_build_object('allowed',true,'reservationId',v_id,'competitionId',dem.competition_id,
      'externalLeagueId',v_ext,'seasonKey',dem.season_key,'source','user','lane',v_lane,
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
    -- #116: the provider said this league has no table for this mapping and
    -- this season: skip it until the negative cache expires. A new mapping
    -- or a new current season (rollover / season now known) retries at once.
    and not exists(select 1 from futbeat_private.standings_coverage_state ns
      where ns.competition_id=pe.canonical_id and ns.status='NO_DATA'
        and ns.next_retry_at>now() and ns.external_league_id=pe.external_id
        and ns.season_key=coalesce(futbeat_private.competition_season_key(pe.canonical_id),''))
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

revoke all on function
  futbeat_private.clear_standings_coverage_no_data(),
  futbeat_private.futbeat_reserve_goal_standings_call(text,boolean)
from public,anon,authenticated,service_role;
revoke all on function public.futbeat_record_standings_no_data(bigint,integer,text,integer,text) from public,anon,authenticated;
grant execute on function public.futbeat_record_standings_no_data(bigint,integer,text,integer,text) to service_role;

notify pgrst,'reload schema';
