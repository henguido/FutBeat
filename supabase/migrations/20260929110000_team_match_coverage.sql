-- #150 (part 2): per-team match COVERAGE for club and national-team profiles.
--
-- #152 made the profile read model correct (futbeat_read_team_matches), but it
-- can only page matches FutBeat already ingested: the calendar ingests by
-- DATE windows, so a team with few matches in those windows looks empty.
--
-- Provider capability (audited, no provider call made): the GOAL API
-- documents `GET /teams/{id}/fixtures` with `status`, `from`, `to`,
-- `limit` (<=100) and `offset` (official SDK ENDPOINTS.md), in the standard
-- `{success,data,pagination}` envelope. It is the only active provider; the
-- API-Football adapter has no by-team route and the account is disabled.
--
-- Design (central, deduplicated, governed; no user-triggered provider call):
--   * team_match_coverage: one row per canonical team with the EXACT window
--     known (covered_from..covered_to), whether that window was fully paged
--     (window_complete), status AVAILABLE | NO_DATA | FETCH_FAILED | PENDING,
--     lease and backoff. Nothing is ever "complete" beyond that window.
--   * team_match_demands: one row per canonical team (dedup), written at
--     most once a minute; past_target lets "end of Resultados" ask for an
--     older window later (backfill) without a new mechanism.
--   * futbeat_team_fixtures_plan: demand-driven only (followed teams and a
--     near match rank first); every GOAL mapping of the canonical team (and
--     its aliases), most recently seen first, capped at 3.
--   * futbeat_reserve_goal_team_fixtures_call: per-page reservation through
--     quota_decision('goal_api','team-fixtures','coverage'): the coverage
--     floor (300) keeps LIVE/results/user_high untouched; own daily cap.
--   * Fixtures are stored through the SAME canonical path as the calendar
--     (futbeat_store_calendar_range with empty coverage: no day is marked as
--     covered and nothing outside the answer is removed). Match identity is
--     the GOAL fixture id, so date-ingest and team-ingest converge.
--   * No cron: the worker lane runs only on an explicit manual trigger.

-- Initial window and policy (see docs/team-match-coverage.md).
create function futbeat_private.team_match_window()
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object(
    'pastDays',180,          -- initial history
    'futureDays',120,        -- initial schedule
    'backfillDays',180,      -- one older step per backfill demand
    'historyFloorDays',1095, -- never ask for more than 3 years back
    'freshDays',3,           -- the future side changes (reschedules)
    'noDataDays',14,         -- negative cache for an empty answer
    'maxExternalIds',3,
    'maxPages',3,            -- per external id per run (limit 100)
    'pageLimit',100)
$$;

update futbeat_private.provider_quota_policy
set kind_daily_caps=kind_daily_caps||'{"team-fixtures":60}'::jsonb,
    updated_at=now()
where provider='goal_api';

create table futbeat_private.team_match_coverage (
  team_id text primary key references futbeat_private.entities(id) on delete cascade,
  status text not null default 'PENDING'
    check(status in ('PENDING','AVAILABLE','NO_DATA','FETCH_FAILED')),
  covered_from date,
  covered_to date,
  window_complete boolean not null default false,
  last_success_at timestamptz,
  last_attempt_at timestamptz,
  next_retry_at timestamptz,
  failure_count integer not null default 0 check(failure_count>=0),
  lease_until timestamptz,
  fixtures_received integer not null default 0 check(fixtures_received>=0),
  last_error text,
  check(covered_from is null or covered_to is null or covered_from<=covered_to)
);
revoke all on futbeat_private.team_match_coverage from public,anon,authenticated;

create table futbeat_private.team_match_demands (
  team_id text primary key references futbeat_private.entities(id) on delete cascade,
  first_requested_at timestamptz not null default now(),
  requested_at timestamptz not null default now(),
  request_count integer not null default 1 check(request_count>0),
  past_target date,
  reason text not null default 'profile'
);
create index team_match_demands_requested_idx
  on futbeat_private.team_match_demands(requested_at desc);
revoke all on futbeat_private.team_match_demands from public,anon,authenticated;

-- GOAL identities of a canonical team (and its aliases), most recently seen
-- first. Several are normal (e.g. two provider ids for one club).
create function futbeat_private.team_goal_external_ids(p_team_id text,p_limit integer default 3)
returns text[] language sql stable set search_path='' as $$
  select coalesce(array_agg(external_id order by rank_seen desc nulls last,external_id),array[]::text[])
  from (
    select pe.external_id,max(pe.last_seen_at) rank_seen
    from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='team'
      and nullif(btrim(pe.external_id),'') is not null
      and pe.canonical_id=any(futbeat_private.team_identity_ids(p_team_id))
    group by pe.external_id
    order by 2 desc nulls last,1
    limit greatest(p_limit,1)
  ) x
$$;

-- AVAILABLE   fresh, fully paged window that covers the initial target
-- STALE       known window, but old, partial or narrower than the target
-- PENDING     a source exists, no usable answer yet (never, in flight, retry)
-- NO_DATA     the provider validly answered "no fixtures" (negative cache)
-- UNAVAILABLE no GOAL mapping for this team: nothing to ask
create function futbeat_private.team_match_coverage_state(p_team_id text)
returns jsonb language plpgsql stable set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  cov futbeat_private.team_match_coverage;
  target_from date:=current_date-(w->>'pastDays')::integer;
  target_to date:=current_date+(w->>'futureDays')::integer;
  state text;
  reason text;
begin
  select * into cov from futbeat_private.team_match_coverage where team_id=p_team_id;
  if cardinality(futbeat_private.team_goal_external_ids(p_team_id,1))=0 then
    state:='UNAVAILABLE'; reason:='no_provider_source';
  elsif cov.team_id is null then
    state:='PENDING'; reason:='never_fetched';
  elsif cov.lease_until>now() then
    state:=case when cov.covered_from is null then 'PENDING' else 'STALE' end; reason:='in_flight';
  elsif cov.status='NO_DATA' and coalesce(cov.next_retry_at,'-infinity')>now() then
    state:='NO_DATA'; reason:='provider_no_data';
  elsif cov.covered_from is null and cov.status='AVAILABLE' then
    -- Fixtures stored, but no identity set/window was fully validated yet.
    state:='STALE'; reason:='partial';
  elsif cov.covered_from is null then
    state:='PENDING'; reason:=case when cov.status='FETCH_FAILED' then 'retrying' else 'queued' end;
  elsif cov.window_complete and cov.last_success_at>now()-make_interval(days=>(w->>'freshDays')::integer)
    and cov.covered_from<=target_from and cov.covered_to>=target_to then
    state:='AVAILABLE';
  else
    state:='STALE';
    reason:=case when not cov.window_complete then 'partial'
      when cov.last_success_at<=now()-make_interval(days=>(w->>'freshDays')::integer) then 'old'
      else 'narrow' end;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'state',state,'reason',reason,
    'coveredFrom',cov.covered_from,'coveredTo',cov.covered_to,
    'windowComplete',coalesce(cov.window_complete,false),
    'lastSuccessAt',cov.last_success_at));
end $$;

-- Called by the API (team profile open; end of Resultados with p_before).
-- One demand row per canonical team, written at most once a minute, only
-- when coverage is missing/stale or an older window is asked for.
create function public.futbeat_request_team_matches(p_team_id text,p_before date default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  tid text;
  st jsonb;
  floor_date date:=current_date-(w->>'historyFloorDays')::integer;
  wanted date;
  backfill boolean:=false;
  created boolean;
  recorded boolean:=false;
begin
  if nullif(p_team_id,'') is null then raise exception 'Invalid team'; end if;
  tid:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  if not exists(select 1 from futbeat_private.entities where id=tid and kind='team') then
    return jsonb_build_object('state','MISSING','demandRecorded',false);
  end if;
  st:=futbeat_private.team_match_coverage_state(tid);
  if p_before is not null and st ? 'coveredFrom' and p_before<=(st->>'coveredFrom')::date
    and p_before>floor_date then
    wanted:=greatest(floor_date,p_before-(w->>'backfillDays')::integer);
    backfill:=true;
  end if;
  if st->>'state' in ('PENDING','STALE') or backfill then
    perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-team-match-demand'),hashtext(tid));
    insert into futbeat_private.team_match_demands as d(team_id,past_target,reason)
    values(tid,wanted,case when backfill then 'history' else 'profile' end)
    on conflict(team_id) do update
      set requested_at=now(),request_count=d.request_count+1,
          past_target=least(d.past_target,excluded.past_target),
          reason=excluded.reason
      where d.requested_at<now()-interval '1 minute'
        or (excluded.past_target is not null
          and excluded.past_target<coalesce(d.past_target,'infinity'::date))
    returning (xmax=0) into created;
    recorded:=found;
    perform futbeat_private.bump_metric(case
      when created then 'team_match_demand_created' else 'team_match_demand_deduped' end);
  end if;
  return st||jsonb_build_object('teamId',tid,'demandRecorded',recorded,'backfill',backfill);
end $$;

-- Planner: demand-driven only. A demand is consumed by the next reservation
-- attempt (last_attempt_at), exactly like the squad 'requested' tier.
create function public.futbeat_team_fixtures_plan(p_limit integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  result jsonb;
begin
  if p_limit is null or p_limit<1 or p_limit>10 then raise exception 'Invalid team fixtures plan limit'; end if;
  with candidates as (
    select d.team_id,d.requested_at,d.past_target,c.covered_from,c.covered_to,
      futbeat_private.team_match_coverage_state(d.team_id) st,
      exists(select 1 from futbeat_private.coverage_interests ci
        where ci.subject_type='team' and ci.subject_id=d.team_id and ci.explicit_followers>0) followed,
      exists(select 1 from futbeat_private.entities m
        where m.kind='match'
          and (m.payload->>'homeTeamId'=any(futbeat_private.team_identity_ids(d.team_id))
            or m.payload->>'awayTeamId'=any(futbeat_private.team_identity_ids(d.team_id)))
          and nullif(m.payload->>'startTime','') is not null
          and (m.payload->>'startTime')::timestamptz between now() and now()+interval '7 days') near
    from futbeat_private.team_match_demands d
    join futbeat_private.entities t on t.id=d.team_id and t.kind='team'
    left join futbeat_private.team_match_coverage c on c.team_id=d.team_id
    where d.requested_at>now()-interval '7 days'
      and d.requested_at>coalesce(c.last_attempt_at,'-infinity')
      and coalesce(c.lease_until,'-infinity')<=now()
      and coalesce(c.next_retry_at,'-infinity')<=now()
  ), due as (
    select c.*,futbeat_private.team_goal_external_ids(c.team_id,(w->>'maxExternalIds')::integer) ext,
      -- A backfill asks only for the older, missing window.
      (c.st->>'state' in ('AVAILABLE','STALE') and c.past_target is not null
        and c.covered_from is not null and c.past_target<c.covered_from) backfill
    from candidates c
    where c.st->>'state' in ('PENDING','STALE')
      or (c.past_target is not null and c.covered_from is not null and c.past_target<c.covered_from)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'teamId',team_id,
      'externalTeamIds',to_jsonb(ext),
      'from',case when backfill then past_target
        else least(current_date-(w->>'pastDays')::integer,coalesce(past_target,'infinity'::date)) end,
      'to',case when backfill then covered_from else current_date+(w->>'futureDays')::integer end,
      'mode',case when backfill then 'history' else 'window' end,
      'reason',case when followed then 'followed' when near then 'near_match' else 'profile' end)
    order by followed desc,near desc,requested_at desc,team_id),'[]'::jsonb)
  into result
  from (select * from due where cardinality(ext)>0
        order by followed desc,near desc,requested_at desc,team_id limit p_limit) x;
  return result;
end $$;

-- One reservation per provider page. Page 0 takes the per-team lease; later
-- pages of the same run need that lease. LIVE is protected by the class
-- floor ('coverage' 300 vs live 20) and this kind has its own daily cap.
create function public.futbeat_reserve_goal_team_fixtures_call(
  p_team_id text,
  p_external_team_id text,
  p_page integer default 0,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  cov futbeat_private.team_match_coverage;
  v_decision jsonb;
  v_id bigint;
begin
  if nullif(p_team_id,'') is null or nullif(p_external_team_id,'') is null
     or p_page is null or p_page<0 or p_page>=(futbeat_private.team_match_window()->>'maxPages')::integer*3
     or nullif(btrim(p_trigger_source),'') is null
     or not (p_external_team_id=any(futbeat_private.team_goal_external_ids(tid,100))) then
    raise exception 'Invalid GOAL team fixtures reservation';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('team-fixtures:'||tid,0));
  select * into cov from futbeat_private.team_match_coverage where team_id=tid;
  if p_page=0 then
    if cov.lease_until>now() or cov.next_retry_at>now() then
      return jsonb_build_object('allowed',false,'reason','team_fixtures_inflight_or_backoff');
    end if;
  elsif not coalesce(cov.lease_until>now(),false) then
    return jsonb_build_object('allowed',false,'reason','team_fixtures_lease_lost');
  end if;

  perform futbeat_private.lock_provider_quota('goal_api');
  v_decision:=futbeat_private.quota_decision('goal_api','team-fixtures','coverage');
  if not (v_decision->>'allowed')::boolean then
    return v_decision;
  end if;

  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','team-fixtures',left(p_trigger_source,40),now(),
    jsonb_build_object('teamId',tid,'externalTeamId',p_external_team_id,'page',p_page))
  returning id into v_id;

  if p_page=0 then
    insert into futbeat_private.team_match_coverage as c(team_id,last_attempt_at,lease_until)
    values(tid,now(),now()+interval '10 minutes')
    on conflict(team_id) do update set last_attempt_at=now(),lease_until=now()+interval '10 minutes';
  end if;
  perform futbeat_private.bump_metric('team_match_fetch_reserved');
  return v_decision||jsonb_build_object('reservationId',v_id,'teamId',tid,
    'externalTeamId',p_external_team_id,'page',p_page);
end $$;

-- Page failures are per provider call: a 404/500 of ONE GOAL identity never
-- changes the team coverage by itself (another identity may still work) and
-- never releases the batch lease. The worker reports the team-level outcome
-- once, after every planned identity was tried (futbeat_complete_team_fixtures
-- or futbeat_fail_team_fixtures).

-- Canonical matches that already exist for these GOAL fixture ids, read BEFORE
-- the ingest resolves them (resolution creates the unknown ones).
create function public.futbeat_known_goal_fixtures(p_external_ids jsonb)
returns jsonb language sql stable security definer set search_path='' as $$
  select coalesce(jsonb_agg(distinct pe.canonical_id),'[]'::jsonb)
  from futbeat_private.provider_entities pe
  join futbeat_private.entities e on e.id=pe.canonical_id and e.kind='match'
  where pe.provider='goal_api' and pe.kind='match'
    and pe.external_id in (select value from jsonb_array_elements_text(
      case when jsonb_typeof(p_external_ids)='array' then p_external_ids else '[]'::jsonb end))
$$;

-- Team-level failure: no identity gave a usable answer, or the answer could
-- not be normalized. Never NO_DATA, never a complete window, stored matches
-- untouched. Every planned identity answering 404 suggests stale mappings:
-- a long backoff instead of a negative cache.
create function public.futbeat_fail_team_fixtures(
  p_team_id text,
  p_reason text,
  p_http_statuses jsonb default '[]'::jsonb
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  statuses integer[];
  failures integer;
begin
  if tid is null or nullif(btrim(p_reason),'') is null then raise exception 'Invalid team fixtures failure'; end if;
  select coalesce(array_agg(value::integer),array[]::integer[]) into statuses
  from jsonb_array_elements_text(case when jsonb_typeof(p_http_statuses)='array' then p_http_statuses else '[]'::jsonb end)
  where value ~ '^\d{3}$';
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('team-fixtures:'||tid,0));
  select failure_count+1 into failures from futbeat_private.team_match_coverage where team_id=tid for update;
  if failures is null then raise exception 'Team fixtures failure without reservation'; end if;
  update futbeat_private.team_match_coverage set
    status=case when covered_from is null then 'FETCH_FAILED' else status end,
    window_complete=false,
    failure_count=failures,
    last_error=left(p_reason,120),
    lease_until=null,
    next_retry_at=now()+case
      when cardinality(statuses)>0 and 404=all(statuses) then interval '7 days'
      when 429=any(statuses) then interval '1 day'
      else make_interval(secs=>least(86400,900*power(2,least(failures-1,7)))::integer) end
  where team_id=tid;
  perform futbeat_private.bump_metric('team_match_fetch_failed');
  return futbeat_private.team_match_coverage_state(tid)||jsonb_build_object('teamId',tid);
end $$;

-- Called by global ingest after the fixtures were stored (every planned
-- identity was tried). p_raw is the number of distinct raw provider items,
-- p_received the canonical matches accepted from them.
--   * p_raw>0 and nothing accepted: normalization/schema failure, never
--     NO_DATA and never complete (futbeat_fail_team_fixtures).
--   * fewer accepted than raw: the window is NOT complete.
--   * NO_DATA only for a complete run (every identity answered, no partial
--     pagination) with zero raw items: the provider confirmed no fixtures.
--   * The window only grows for a complete run; otherwise what was known is
--     kept and the team is retried soon.
create function public.futbeat_complete_team_fixtures(
  p_team_id text,
  p_from date,
  p_to date,
  p_complete boolean,
  p_raw integer,
  p_received integer,
  p_new integer,
  p_existing integer
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  cov futbeat_private.team_match_coverage;
  contiguous boolean;
  full_window boolean;
begin
  if tid is null or p_from is null or p_to is null or p_from>p_to or p_complete is null
     or coalesce(p_raw,-1)<0 or coalesce(p_received,-1)<0 or coalesce(p_new,-1)<0
     or coalesce(p_existing,-1)<0 or p_new+p_existing<>p_received then
    raise exception 'Invalid team fixtures completion';
  end if;
  if p_raw>0 and p_received=0 then
    return public.futbeat_fail_team_fixtures(tid,'NORMALIZATION_FAILED','[]'::jsonb);
  end if;
  full_window:=p_complete and p_received>=p_raw;
  perform pg_catalog.pg_advisory_xact_lock(hashtextextended('team-fixtures:'||tid,0));
  select * into cov from futbeat_private.team_match_coverage where team_id=tid for update;
  if cov.team_id is null then raise exception 'Team fixtures completion without reservation'; end if;
  contiguous:=cov.covered_from is null
    or (p_from<=cov.covered_to+1 and p_to>=cov.covered_from-1);

  if p_received=0 and full_window then
    -- Every identity answered 200 with no items: confirmed empty.
    update futbeat_private.team_match_coverage set
      status=case when covered_from is null then 'NO_DATA' else status end,
      -- An empty OLDER window extends the known range (nothing there).
      covered_from=case when covered_from is not null and contiguous then least(covered_from,p_from) else covered_from end,
      lease_until=null,failure_count=0,last_error=null,
      next_retry_at=now()+make_interval(days=>(w->>'noDataDays')::integer)
    where team_id=tid;
    perform futbeat_private.bump_metric('team_match_fetch_no_data');
  elsif p_received=0 then
    -- Nothing usable and not every identity answered: unknown, retry soon.
    update futbeat_private.team_match_coverage set
      status=case when covered_from is null then 'FETCH_FAILED' else status end,
      window_complete=false,lease_until=null,last_error='PARTIAL_IDENTITIES',
      next_retry_at=now()+interval '30 minutes'
    where team_id=tid;
  else
    update futbeat_private.team_match_coverage set
      status='AVAILABLE',
      covered_from=case when full_window and contiguous then least(coalesce(covered_from,p_from),p_from) else covered_from end,
      covered_to=case when full_window and contiguous then greatest(coalesce(covered_to,p_to),p_to) else covered_to end,
      window_complete=case when full_window then (contiguous or window_complete) else false end,
      last_success_at=now(),lease_until=null,failure_count=0,
      last_error=case when full_window then null else 'PARTIAL_WINDOW' end,
      fixtures_received=p_received,
      -- A partial answer is retried soon; a full one waits for new demand.
      next_retry_at=case when full_window then null else now()+interval '30 minutes' end
    where team_id=tid;
    perform futbeat_private.bump_metric('team_match_fetch_success');
  end if;
  if p_raw>0 then perform futbeat_private.bump_metric('team_match_fixtures_received',p_raw); end if;
  if p_new>0 then perform futbeat_private.bump_metric('team_match_fixtures_new',p_new); end if;
  if p_existing>0 then perform futbeat_private.bump_metric('team_match_fixtures_existing',p_existing); end if;
  return futbeat_private.team_match_coverage_state(tid)||jsonb_build_object('teamId',tid,'windowComplete',full_window);
end $$;

-- Grants: API / workers (service_role) only.
revoke all on function
  futbeat_private.team_match_window(),
  futbeat_private.team_goal_external_ids(text,integer),
  futbeat_private.team_match_coverage_state(text),
  public.futbeat_request_team_matches(text,date),
  public.futbeat_team_fixtures_plan(integer),
  public.futbeat_reserve_goal_team_fixtures_call(text,text,integer,text),
  public.futbeat_known_goal_fixtures(jsonb),
  public.futbeat_fail_team_fixtures(text,text,jsonb),
  public.futbeat_complete_team_fixtures(text,date,date,boolean,integer,integer,integer,integer)
from public,anon,authenticated;
grant execute on function
  public.futbeat_request_team_matches(text,date),
  public.futbeat_team_fixtures_plan(integer),
  public.futbeat_reserve_goal_team_fixtures_call(text,text,integer,text),
  public.futbeat_known_goal_fixtures(jsonb),
  public.futbeat_fail_team_fixtures(text,text,jsonb),
  public.futbeat_complete_team_fixtures(text,date,date,boolean,integer,integer,integer,integer)
to service_role;

notify pgrst,'reload schema';
