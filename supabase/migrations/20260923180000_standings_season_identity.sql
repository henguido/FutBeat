-- Standings identity = (competition, season), plus standings on demand.
--
-- Root cause fixed: standings_cache is keyed by competition_id alone (a new
-- season overwrites the previous one) and every reader attached "the"
-- competition table to any match, whatever its season. Standings were only
-- fetched by a 6-hourly workflow under a fixed 12/day, remaining<=350 guard.
--
-- Design (no existing writer/reader broken):
--   * standings_cache stays as "latest table per competition" (existing
--     writers, redirect merges and profile readers keep working).
--   * standings_snapshots(competition_id, season_key) is the exact identity.
--     Every standings_cache write is archived there by trigger. season_key is
--     the normalized season (normalize_season); when the provider rows carry
--     no season, the competition's current season at fetch time is used. A
--     table without any season is never archived (it cannot be matched
--     exactly and is never shown for a match).
--   * Match Center reads ONLY the snapshot for the match's exact competition
--     and season (never by name, country, editorial fallback or another
--     season). Provisional live overlay only for the current season.
--   * Opening a match records one deduplicated standings demand per
--     (competition, season) when missing/stale and fetchable (GOAL mapping
--     and the competition's current season), then wakes the worker.
--   * futbeat_reserve_goal_standings_call now serves user demand first
--     (class user_high) and coverage refreshes second (class coverage) through
--     the central quota manager (kind 'standings'); the fixed 12/day and
--     remaining<=350 development guards and the hardcoded country priority
--     are removed. LIVE/results keep their protected floors.

create or replace function futbeat_private.normalize_season(p_value text)
returns text language plpgsql immutable set search_path='' as $$
declare raw text:=lower(btrim(coalesce(p_value,''))); m text[]; first_year integer; second_year integer;
begin
  if raw='' then return ''; end if;
  m:=regexp_match(raw,'^(\d{4})\s*[/\-_]\s*(\d{2}|\d{4})$');
  if m is not null then
    first_year:=m[1]::integer;
    second_year:=case when length(m[2])=2 then (first_year/100)*100+m[2]::integer else m[2]::integer end;
    if second_year<first_year then second_year:=second_year+100; end if;
    return first_year||'-'||second_year;
  end if;
  if raw ~ '^\d{4}$' then return raw; end if;
  return regexp_replace(raw,'\s+',' ','g');
end $$;

create table if not exists futbeat_private.standings_snapshots(
  competition_id text not null references futbeat_private.entities(id) on delete cascade,
  season_key text not null check(season_key<>''),
  season text not null,
  external_league_id text,
  table_payload jsonb not null check(jsonb_typeof(table_payload)='object'),
  fetched_at timestamptz not null,
  primary key(competition_id,season_key)
);
create index if not exists standings_snapshots_fetched_idx on futbeat_private.standings_snapshots(fetched_at);
alter table futbeat_private.standings_snapshots enable row level security;
revoke all on futbeat_private.standings_snapshots from public,anon,authenticated;

create or replace function futbeat_private.competition_season_key(p_competition_id text)
returns text language sql stable set search_path='' as $$
  select futbeat_private.normalize_season(e.payload->>'season') from futbeat_private.entities e
  where e.id=futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id) and e.kind='competition'
$$;

create or replace function futbeat_private.archive_standings_snapshot()
returns trigger language plpgsql security definer set search_path='' as $$
declare key text:=coalesce(nullif(futbeat_private.normalize_season(new.season),''),
  nullif(futbeat_private.competition_season_key(new.competition_id),''));
begin
  if key is null then return new; end if;
  insert into futbeat_private.standings_snapshots as s(
    competition_id,season_key,season,external_league_id,table_payload,fetched_at)
  values(new.competition_id,key,coalesce(nullif(new.season,''),key),new.external_league_id,
    new.table_payload||jsonb_build_object('season',coalesce(nullif(new.season,''),key),'seasonKey',key),new.fetched_at)
  on conflict(competition_id,season_key) do update set
    season=excluded.season,external_league_id=excluded.external_league_id,
    table_payload=excluded.table_payload,fetched_at=excluded.fetched_at
  where s.fetched_at<=excluded.fetched_at;
  -- An answered demand for exactly this identity is complete.
  update futbeat_private.standings_demands d set status='AVAILABLE',lease_until=null,failure_count=0,
    last_success_at=new.fetched_at,next_retry_at=null,last_error=null
  where d.competition_id=new.competition_id and d.season_key=key;
  return new;
end $$;

create table if not exists futbeat_private.standings_demands(
  competition_id text not null references futbeat_private.entities(id) on delete cascade,
  season_key text not null check(season_key<>''),
  external_league_id text not null,
  status text not null default 'QUEUED' check(status in ('QUEUED','AVAILABLE','NO_DATA','FETCH_FAILED')),
  requested_at timestamptz not null default now(),
  request_count bigint not null default 1,
  lease_until timestamptz,
  last_attempt_at timestamptz,
  last_success_at timestamptz,
  next_retry_at timestamptz,
  failure_count integer not null default 0,
  last_error text,
  primary key(competition_id,season_key)
);
alter table futbeat_private.standings_demands enable row level security;
revoke all on futbeat_private.standings_demands from public,anon,authenticated;

drop trigger if exists standings_snapshot_archive on futbeat_private.standings_cache;
create trigger standings_snapshot_archive after insert or update on futbeat_private.standings_cache
for each row execute function futbeat_private.archive_standings_snapshot();

-- Archive what is already stored (no provider calls).
insert into futbeat_private.standings_snapshots(competition_id,season_key,season,external_league_id,table_payload,fetched_at)
select sc.competition_id,k.key,coalesce(nullif(sc.season,''),k.key),sc.external_league_id,
  sc.table_payload||jsonb_build_object('season',coalesce(nullif(sc.season,''),k.key),'seasonKey',k.key),sc.fetched_at
from futbeat_private.standings_cache sc
cross join lateral (select coalesce(nullif(futbeat_private.normalize_season(sc.season),''),
  nullif(futbeat_private.competition_season_key(sc.competition_id),'')) key) k
where k.key is not null
on conflict(competition_id,season_key) do nothing;

-- Policy: standings join the central quota manager.
update futbeat_private.provider_quota_policy set
  kind_daily_caps=kind_daily_caps||'{"standings":120}',
  freshness=freshness||'{"standingsHours":6,"standingsActiveMinutes":30,"standingsNoDataDays":3}',
  updated_at=now()
where provider='goal_api';

-- Exact-identity standings state for one match (read-only).
create or replace function futbeat_private.match_standings_state(p_match_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare m jsonb; comp text; v_key text; current_key text; ext text; snap futbeat_private.standings_snapshots;
  dem futbeat_private.standings_demands; fresh_for interval; active boolean; fetchable boolean; state text;
begin
  select payload into m from futbeat_private.entities where id=p_match_id and kind='match';
  if m is null then return null; end if;
  comp:=futbeat_private.futbeat_resolve_entity_id('competition',m->>'competitionId');
  v_key:=futbeat_private.normalize_season(m->>'season');
  if comp is null or v_key='' then
    return jsonb_build_object('standings','missing','standingsPending',false,'standingsStale',false,
      'competitionId',comp,'seasonKey',nullif(v_key,''));
  end if;
  current_key:=futbeat_private.competition_season_key(comp);
  select pe.external_id into ext from futbeat_private.provider_entities pe
  where pe.provider='goal_api' and pe.kind='competition'
    and futbeat_private.futbeat_resolve_entity_id('competition',pe.canonical_id)=comp
  order by pe.external_id limit 1;
  -- GOAL serves the competition's current table: other seasons are only
  -- available if they were archived while current.
  fetchable:=ext is not null and v_key=coalesce(current_key,'');
  select * into snap from futbeat_private.standings_snapshots s where s.competition_id=comp and s.season_key=v_key;
  select * into dem from futbeat_private.standings_demands d where d.competition_id=comp and d.season_key=v_key;
  active:=exists(select 1 from futbeat_private.entities x where x.kind='match'
    and x.payload->>'competitionId'=comp and x.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES'));
  fresh_for:=case when active
    then make_interval(mins=>futbeat_private.quota_setting('goal_api','standingsActiveMinutes',30)::integer)
    else make_interval(hours=>futbeat_private.quota_setting('goal_api','standingsHours',6)::integer) end;
  state:=case
    when snap.competition_id is not null then 'available'
    when dem.status='QUEUED' or dem.lease_until>now() then 'pending'
    when dem.status='NO_DATA' and dem.next_retry_at>now() then 'unavailable'
    else 'missing' end;
  return jsonb_build_object(
    'standings',state,
    'standingsStale',snap.competition_id is not null and fetchable and snap.fetched_at<now()-fresh_for,
    'standingsPending',coalesce(dem.status='QUEUED' or dem.lease_until>now(),false) and fetchable,
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
  if not (st->>'due')::boolean then
    if st->>'standings'='available' then perform futbeat_private.bump_metric('standings_cache_hits'); end if;
    return st-'due'-'externalLeagueId'-'fetchable'-'demandStatus';
  end if;
  comp:=st->>'competitionId'; key:=st->>'seasonKey';
  perform pg_advisory_xact_lock(hashtext('futbeat-standings-demand'),hashtext(comp||'|'||key));
  select status into prev from futbeat_private.standings_demands where competition_id=comp and season_key=key;
  insert into futbeat_private.standings_demands(competition_id,season_key,external_league_id)
  values(comp,key,st->>'externalLeagueId')
  on conflict(competition_id,season_key) do update set request_count=futbeat_private.standings_demands.request_count+1,
    requested_at=now(),external_league_id=excluded.external_league_id,status='QUEUED';
  if prev='QUEUED' then
    perform futbeat_private.bump_metric('deduped_requests');
  else
    perform futbeat_private.bump_metric('standings_user_demands');
    perform futbeat_private.wake_provider_worker('demand');
  end if;
  return (futbeat_private.match_standings_state(p_match_id))-'due'-'externalLeagueId'-'fetchable'-'demandStatus';
end $$;

-- Replace the development-era reservation (fixed caps, country priority).
drop function if exists futbeat_private.futbeat_reserve_goal_standings_call(text);
create function futbeat_private.futbeat_reserve_goal_standings_call(
  p_trigger_source text default 'github-actions',
  p_demand_only boolean default false
) returns jsonb language plpgsql security definer set search_path='' as $$
declare window_start timestamptz:=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','demandWindowMinutes',30)::integer);
  lease interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','leaseMinutes',10)::integer);
  decision jsonb; dem futbeat_private.standings_demands; v_id bigint; cand record;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then raise exception 'trigger_source is required'; end if;
  perform futbeat_private.lock_provider_quota('goal_api');

  -- 1. Standings a user is waiting for (exact competition + season).
  decision:=futbeat_private.quota_decision('goal_api','standings','user_high');
  if (decision->>'allowed')::boolean then
    select * into dem from futbeat_private.standings_demands d
    where d.status='QUEUED' and d.requested_at>window_start
      and coalesce(d.lease_until,'-infinity')<=now() and coalesce(d.next_retry_at,'-infinity')<=now()
      -- Only the competition's current season can be fetched.
      and d.season_key=futbeat_private.competition_season_key(d.competition_id)
    order by d.requested_at desc,d.competition_id limit 1 for update skip locked;
    if dem.competition_id is not null then
      update futbeat_private.standings_demands set lease_until=now()+lease,last_attempt_at=now()
      where competition_id=dem.competition_id and season_key=dem.season_key;
      insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
      values('goal_api','standings',left(p_trigger_source,40),now(),jsonb_build_object('competitionId',dem.competition_id,
        'externalLeagueId',dem.external_league_id,'seasonKey',dem.season_key,'source','user'))
      returning id into v_id;
      return decision||jsonb_build_object('allowed',true,'reservationId',v_id,'competitionId',dem.competition_id,
        'externalLeagueId',dem.external_league_id,'seasonKey',dem.season_key,'source','user');
    end if;
  end if;
  if p_demand_only then
    return jsonb_build_object('allowed',false,'reason',case when (decision->>'allowed')::boolean
      then 'no_standings_demand' else decision->>'reason' end,'providerRemaining',decision->'providerRemaining');
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

create or replace function public.futbeat_reserve_standings_demand_call(p_trigger_source text default 'supabase-cron')
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.futbeat_reserve_goal_standings_call(p_trigger_source,true)
$$;

-- Completion for demand fetches: ledger + demand bookkeeping. A fetch that
-- did not produce the requested exact season is NO_DATA (negative cache).
create or replace function public.futbeat_complete_standings_call(p_reservation_id bigint,
  p_succeeded boolean,p_http_status integer default null,p_provider_remaining integer default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare meta jsonb; stored boolean; v_status text; failures integer;
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
  if stored then return jsonb_build_object('status','AVAILABLE'); end if;
  v_status:=case when p_succeeded or p_http_status=404 then 'NO_DATA' else 'FETCH_FAILED' end;
  update futbeat_private.standings_demands d set status=v_status,lease_until=null,failure_count=d.failure_count+1,
    last_error=case when v_status='NO_DATA' then 'no table for this season' else 'fetch failed' end
  where d.competition_id=meta->>'competitionId' and d.season_key=meta->>'seasonKey'
  returning d.failure_count into failures;
  update futbeat_private.standings_demands d set next_retry_at=now()+case when v_status='NO_DATA'
      then make_interval(days=>futbeat_private.quota_setting('goal_api','standingsNoDataDays',3)::integer)
      else least(interval '6 hours',interval '5 minutes'*power(2,least(coalesce(failures,1)-1,6))) end
  where d.competition_id=meta->>'competitionId' and d.season_key=meta->>'seasonKey';
  return jsonb_build_object('status',v_status);
end $$;

-- Match Center: previous context + the exact (competition, season) table.
alter function public.futbeat_read_match_context(text) set schema futbeat_private;
alter function futbeat_private.futbeat_read_match_context(text) rename to read_match_context_base;
create function public.futbeat_read_match_context(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare base jsonb:=futbeat_private.read_match_context_base(p_match_id); st jsonb; snap futbeat_private.standings_snapshots;
  table_json jsonb; team_ids text[]; extra jsonb;
begin
  if base is null then return null; end if;
  st:=futbeat_private.match_standings_state(p_match_id);
  select * into snap from futbeat_private.standings_snapshots s
  where s.competition_id=st->>'competitionId' and s.season_key=st->>'seasonKey';
  if snap.competition_id is not null then
    table_json:=case when snap.season_key=coalesce(futbeat_private.competition_season_key(snap.competition_id),'')
      then futbeat_private.futbeat_apply_provisional_standings(snap.table_payload,snap.fetched_at)
      else snap.table_payload end;
    -- Teams of the exact table that the base context did not include.
    select array_agg(distinct r->>'teamId') into team_ids
    from jsonb_array_elements(coalesce(table_json->'rows','[]')) r
    where nullif(r->>'teamId','') is not null
      and not exists(select 1 from jsonb_array_elements(base->'teams') t where t->>'id'=r->>'teamId');
    select coalesce(jsonb_agg(e.payload order by e.id),'[]') into extra from futbeat_private.entities e
    where e.kind='team' and e.id=any(coalesce(team_ids,'{}'));
    base:=jsonb_set(base,'{teams}',(base->'teams')||extra);
  end if;
  return jsonb_set(base,'{standings}',case when table_json is null then '[]'::jsonb else jsonb_build_array(table_json) end)
    ||jsonb_build_object('coverage',coalesce(base->'coverage','{}')||jsonb_build_object(
      'standings',st->>'standings','standingsPending',coalesce((st->>'standingsPending')::boolean,false),
      'standingsStale',coalesce((st->>'standingsStale')::boolean,false)));
end $$;

revoke all on function
  futbeat_private.normalize_season(text),
  futbeat_private.competition_season_key(text),
  futbeat_private.archive_standings_snapshot(),
  futbeat_private.match_standings_state(text),
  futbeat_private.futbeat_reserve_goal_standings_call(text,boolean),
  futbeat_private.read_match_context_base(text)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_request_match_standings(text),
  public.futbeat_reserve_standings_demand_call(text),
  public.futbeat_complete_standings_call(bigint,boolean,integer,integer),
  public.futbeat_read_match_context(text)
from public,anon,authenticated;
grant execute on function
  public.futbeat_request_match_standings(text),
  public.futbeat_reserve_standings_demand_call(text),
  public.futbeat_complete_standings_call(bigint,boolean,integer,integer),
  public.futbeat_read_match_context(text)
to service_role;

notify pgrst,'reload schema';
