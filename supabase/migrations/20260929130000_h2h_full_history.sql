-- Issue #155: Cara a cara must expose the full stored history of the pair.
--
-- Evidence (production, read-only, 29-sep-2026): Belgium-France had exactly
-- two canonical matches stored (a final on 2026-09-28 and the scheduled
-- 2026-10-05 fixture) and the v2 read returned exactly those (1 counted
-- meeting + the scheduled one as `current`). The read was correct; the
-- product was not:
--   * both teams' coverage only spans the initial window (2026-04-02 ..
--     2027-01-27); nothing ever asked for OLDER history of a pair, so two
--     national teams that met years ago show one meeting;
--   * `AVAILABLE` did not say since when records exist;
--   * the list stopped at 20 with no way to page further.
--
-- Fix (same canonical data, same central coverage pipeline):
--   * futbeat_private.h2h_meetings(match): the single source of the pair's
--     meetings (canonical ids + aliases, effective lifecycle, finals with a
--     complete score, up to the target's kickoff, the target only once it is
--     final). Two index lookups (home/away team indexes).
--   * public.futbeat_read_match_h2h(match, scope, cursor, limit): keyset
--     pages (startTime desc, id desc) for scope 'all' or 'competition' (the
--     target's canonical competition). Totals are over EVERY meeting of the
--     scope, independent of the page. `window` states what was verified:
--     verifiedFrom (both teams' explicit covered range), historyFloor and
--     canExtend. Never "total history" beyond that.
--   * public.futbeat_request_match_h2h_history(match): extends BOTH teams'
--     central coverage one step back through futbeat_request_team_matches
--     (p_before = its covered_from; 180-day steps, 3-year floor, one
--     deduplicated demand per team, the #153/#154 wake + safety net).
--   * NO_DATA progress (review): a mapped team whose recent window was
--     confirmed EMPTY keeps NO_DATA but stores that range (empty_from/to), so
--     H2H and the profile can ask for the window before it; see the block
--     below.

-- ---------------------------------------------------------------------------
-- NO_DATA can progress to an older window (#155 review).
--
-- A mapped team whose initial window came back complete and EMPTY was left
-- as status NO_DATA with covered_from null: which window was confirmed empty
-- was not stored, so neither H2H nor the profile could ask for anything older,
-- and the 14-day negative cache (next_retry_at) also blocked OLDER windows
-- (after any empty answer, NO_DATA or an empty historical backfill).
--
-- NO_DATA still means "the provider confirmed no fixtures in THAT window":
--   * team_match_coverage.empty_from/empty_to store the confirmed-empty range
--     of a team without covered range (never promoted to covered/AVAILABLE);
--   * the verified start of a team is covered_from, else (NO_DATA) empty_from
--     (team_match_known_from);
--   * the negative cache gates re-asking the SAME window; a history demand for
--     an older range passes it only when the last outcome was a confirmed
--     answer (no error, no failures). Failure backoff, leases, the history
--     floor, the team-fixtures quota (reservation) and the wake are unchanged.
--   * when an older window brings fixtures, the confirmed-empty range that
--     touches it is part of the verified range (both were answered).
-- Existing NO_DATA rows get a conservative empty range from their
-- completion day (next_retry_at - noDataDays): completion-pastDays ..
-- completion+futureDays (the planned window started no later than that; its
-- end may differ by one day across UTC midnight).
-- Accepted, as before this change: each empty answer renews the 14-day
-- negative cache of the team; merging a confirmed-empty range into the
-- covered one on a later non-empty answer keeps it STALE/narrow until the
-- recent window is refreshed.
-- ---------------------------------------------------------------------------

alter table futbeat_private.team_match_coverage
  add column if not exists empty_from date,
  add column if not exists empty_to date;
alter table futbeat_private.team_match_coverage
  drop constraint if exists team_match_coverage_empty_range_check;
alter table futbeat_private.team_match_coverage
  add constraint team_match_coverage_empty_range_check
  check(empty_from is null or empty_to is null or empty_from<=empty_to);

update futbeat_private.team_match_coverage c set
  empty_from=(c.next_retry_at-make_interval(days=>(futbeat_private.team_match_window()->>'noDataDays')::integer))::date
    -(futbeat_private.team_match_window()->>'pastDays')::integer,
  empty_to=(c.next_retry_at-make_interval(days=>(futbeat_private.team_match_window()->>'noDataDays')::integer))::date
    +(futbeat_private.team_match_window()->>'futureDays')::integer
where c.status='NO_DATA' and c.covered_from is null and c.empty_from is null
  and c.next_retry_at is not null and c.last_error is null and c.failure_count=0;

-- Verified start: covered range, else the confirmed-empty range of NO_DATA.
create function futbeat_private.team_match_known_from(p_cov futbeat_private.team_match_coverage)
returns date language sql stable set search_path='' as $$
  select coalesce(p_cov.covered_from,
    case when p_cov.status='NO_DATA' then p_cov.empty_from end)
$$;

-- The last outcome was a confirmed answer (not a failure/partial): only then
-- may an OLDER history window pass the negative cache.
create function futbeat_private.team_match_history_may_pass(
  p_cov futbeat_private.team_match_coverage,p_past_target date)
returns boolean language sql stable set search_path='' as $$
  select p_past_target is not null
    and p_past_target<futbeat_private.team_match_known_from(p_cov)
    and p_cov.last_error is null and coalesce(p_cov.failure_count,0)=0
    and p_cov.status in ('NO_DATA','AVAILABLE')
    and coalesce(p_cov.lease_until,'-infinity')<=now()
$$;

-- Same as 20260929110000, plus emptyFrom/emptyTo while NO_DATA.
create or replace function futbeat_private.team_match_coverage_state(p_team_id text)
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
    'emptyFrom',case when state='NO_DATA' then cov.empty_from end,
    'emptyTo',case when state='NO_DATA' then cov.empty_to end,
    'windowComplete',coalesce(cov.window_complete,false),
    'lastSuccessAt',cov.last_success_at));
end $$;

-- Same as 20260929120000 (throttled demand + wake), plus: a NO_DATA team can
-- ask for the window before its confirmed-empty range.
create or replace function public.futbeat_request_team_matches(p_team_id text,p_before date default null)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  tid text;
  st jsonb;
  floor_date date:=current_date-(w->>'historyFloorDays')::integer;
  known date;
  wanted date;
  backfill boolean:=false;
  created boolean;
  recorded boolean:=false;
  wake text;
begin
  if nullif(p_team_id,'') is null then raise exception 'Invalid team'; end if;
  tid:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  if not exists(select 1 from futbeat_private.entities where id=tid and kind='team') then
    return jsonb_build_object('state','MISSING','demandRecorded',false);
  end if;
  st:=futbeat_private.team_match_coverage_state(tid);
  known:=coalesce(nullif(st->>'coveredFrom','')::date,
    case when st->>'state'='NO_DATA' then nullif(st->>'emptyFrom','')::date end);
  if p_before is not null and known is not null and p_before<=known and p_before>floor_date then
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
    if recorded then wake:=futbeat_private.wake_provider_worker('team-fixtures-only'); end if;
  end if;
  return st||jsonb_strip_nulls(jsonb_build_object('teamId',tid,'demandRecorded',recorded,'backfill',backfill,'wake',wake));
end $$;

-- Same as 20260929110000, plus: the verified start is known_from (NO_DATA
-- included) and an older history window passes the negative cache only after
-- a confirmed answer.
create or replace function public.futbeat_team_fixtures_plan(p_limit integer default 1)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  result jsonb;
begin
  if p_limit is null or p_limit<1 or p_limit>10 then raise exception 'Invalid team fixtures plan limit'; end if;
  with candidates as (
    select d.team_id,d.requested_at,d.past_target,c.covered_to,
      futbeat_private.team_match_known_from(c) known_from,
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
      and (coalesce(c.next_retry_at,'-infinity')<=now()
        or (c.team_id is not null and futbeat_private.team_match_history_may_pass(c,d.past_target)))
  ), due as (
    select c.*,futbeat_private.team_goal_external_ids(c.team_id,(w->>'maxExternalIds')::integer) ext,
      (c.st->>'state' in ('AVAILABLE','STALE','NO_DATA') and c.past_target is not null
        and c.known_from is not null and c.past_target<c.known_from) backfill
    from candidates c
    where c.st->>'state' in ('PENDING','STALE')
      or (c.past_target is not null and c.known_from is not null and c.past_target<c.known_from)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'teamId',team_id,
      'externalTeamIds',to_jsonb(ext),
      'from',case when backfill then past_target
        else least(current_date-(w->>'pastDays')::integer,coalesce(past_target,'infinity'::date)) end,
      'to',case when backfill then known_from else current_date+(w->>'futureDays')::integer end,
      'mode',case when backfill then 'history' else 'window' end,
      'reason',case when followed then 'followed' when near then 'near_match' else 'profile' end)
    order by followed desc,near desc,requested_at desc,team_id),'[]'::jsonb)
  into result
  from (select * from due where cardinality(ext)>0
        order by followed desc,near desc,requested_at desc,team_id limit p_limit) x;
  return result;
end $$;

-- Same as 20260929110000, plus the same history pass on page 0.
create or replace function public.futbeat_reserve_goal_team_fixtures_call(
  p_team_id text,
  p_external_team_id text,
  p_page integer default 0,
  p_trigger_source text default 'supabase-cron'
) returns jsonb
language plpgsql volatile security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  cov futbeat_private.team_match_coverage;
  history_pass boolean:=false;
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
    if cov.team_id is not null and cov.next_retry_at>now() then
      select futbeat_private.team_match_history_may_pass(cov,d.past_target) into history_pass
      from futbeat_private.team_match_demands d where d.team_id=tid;
    end if;
    if cov.lease_until>now() or (cov.next_retry_at>now() and not coalesce(history_pass,false)) then
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

-- Same as 20260929110000, plus the confirmed-empty range of a team without
-- covered range (kept as NO_DATA), merged into the verified range once an
-- adjacent window brings fixtures.
create or replace function public.futbeat_complete_team_fixtures(
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
  empty_touch boolean;
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
  -- The answered window touches the confirmed-empty range (no gap).
  empty_touch:=cov.empty_from is not null
    and p_from<=cov.empty_to+1 and p_to>=cov.empty_from-1;

  if p_received=0 and full_window then
    update futbeat_private.team_match_coverage set
      status=case when covered_from is null then 'NO_DATA' else status end,
      covered_from=case when covered_from is not null and contiguous then least(covered_from,p_from) else covered_from end,
      -- No covered range: remember WHICH window was confirmed empty (a gap
      -- restarts it at this window).
      empty_from=case when covered_from is not null then empty_from
        when empty_touch then least(empty_from,p_from) else p_from end,
      empty_to=case when covered_from is not null then empty_to
        when empty_touch then greatest(empty_to,p_to) else p_to end,
      lease_until=null,failure_count=0,last_error=null,
      next_retry_at=now()+make_interval(days=>(w->>'noDataDays')::integer)
    where team_id=tid;
    perform futbeat_private.bump_metric('team_match_fetch_no_data');
  elsif p_received=0 then
    update futbeat_private.team_match_coverage set
      -- Unknown outcome: not NO_DATA (the stored empty range is kept in the
      -- row and returns once a window is confirmed empty again).
      status=case when covered_from is null then 'FETCH_FAILED' else status end,
      window_complete=false,lease_until=null,last_error='PARTIAL_IDENTITIES',
      next_retry_at=now()+interval '30 minutes'
    where team_id=tid;
  else
    update futbeat_private.team_match_coverage set
      status='AVAILABLE',
      covered_from=case when full_window and contiguous then
        least(coalesce(covered_from,p_from),p_from,
          case when covered_from is null and empty_touch then empty_from end)
        else covered_from end,
      covered_to=case when full_window and contiguous then
        greatest(coalesce(covered_to,p_to),p_to,
          case when covered_from is null and empty_touch then empty_to end)
        else covered_to end,
      empty_from=case when full_window and contiguous and covered_from is null and empty_touch then null else empty_from end,
      empty_to=case when full_window and contiguous and covered_from is null and empty_touch then null else empty_to end,
      window_complete=case when full_window then (contiguous or window_complete) else false end,
      last_success_at=now(),lease_until=null,failure_count=0,
      last_error=case when full_window then null else 'PARTIAL_WINDOW' end,
      fixtures_received=p_received,
      next_retry_at=case when full_window then null else now()+interval '30 minutes' end
    where team_id=tid;
    perform futbeat_private.bump_metric('team_match_fetch_success');
  end if;
  if p_raw>0 then perform futbeat_private.bump_metric('team_match_fixtures_received',p_raw); end if;
  if p_new>0 then perform futbeat_private.bump_metric('team_match_fixtures_new',p_new); end if;
  if p_existing>0 then perform futbeat_private.bump_metric('team_match_fixtures_existing',p_existing); end if;
  return futbeat_private.team_match_coverage_state(tid)||jsonb_build_object('teamId',tid,'windowComplete',full_window);
end $$;


revoke all on function
  futbeat_private.team_match_known_from(futbeat_private.team_match_coverage),
  futbeat_private.team_match_history_may_pass(futbeat_private.team_match_coverage,date)
from public,anon,authenticated,service_role;


create function futbeat_private.h2h_meetings(p_match_id text)
returns table(match_id text,start_time timestamptz,competition_id text,result text,meeting jsonb)
language plpgsql stable security definer set search_path='' as $$
declare t jsonb; kickoff timestamptz; c_home text; c_away text;
  home_alias text[]; away_alias text[]; target jsonb; target_final boolean;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return; end if;
  kickoff:=nullif(t->>'startTime','')::timestamptz;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if kickoff is null or c_home is null or c_away is null or c_home=c_away then return; end if;
  target:=futbeat_private.match_read_model_core(t,false);
  target_final:=target->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number';
  home_alias:=futbeat_private.team_identity_ids(c_home);
  away_alias:=futbeat_private.team_identity_ids(c_away);
  return query
  with candidates as (
    select e.id,e.payload from futbeat_private.entities e
    where e.kind='match' and e.payload->>'homeTeamId'=any(home_alias||away_alias)
      and e.payload->>'awayTeamId'=any(home_alias||away_alias)
      and ((e.payload->>'homeTeamId'=any(home_alias) and e.payload->>'awayTeamId'=any(away_alias))
        or (e.payload->>'homeTeamId'=any(away_alias) and e.payload->>'awayTeamId'=any(home_alias)))
      and nullif(e.payload->>'startTime','') is not null
      and (e.payload->>'startTime')::timestamptz<=kickoff
  ), modeled as (
    select c.id,futbeat_private.match_read_model_core(c.payload,false) m from candidates c
  )
  select x.id,(x.m->>'startTime')::timestamptz,x.m->>'competitionId',
    futbeat_private.team_match_result(x.m,c_home),
    jsonb_build_object(
      'matchId',x.id,'competitionId',x.m->>'competitionId','startTime',x.m->>'startTime',
      'status',x.m->>'status','homeTeamId',x.m->>'homeTeamId','awayTeamId',x.m->>'awayTeamId',
      'score',jsonb_build_object('home',x.m->'score'->'home','away',x.m->'score'->'away'),
      'result',futbeat_private.team_match_result(x.m,c_home))
  from modeled x
  where x.m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
    and jsonb_typeof(x.m->'score'->'home')='number' and jsonb_typeof(x.m->'score'->'away')='number'
    and (x.id<>p_match_id or target_final);
end $$;

-- What is actually verified for the pair: both teams' explicit covered range
-- (a NO_DATA side has none -> null), the floor, and whether one more step
-- back can be asked for.
create function futbeat_private.h2h_window(p_home text,p_away text)
returns jsonb language plpgsql stable set search_path='' as $$
declare
  w jsonb:=futbeat_private.team_match_window();
  floor_date date:=current_date-(w->>'historyFloorDays')::integer;
  hs jsonb:=futbeat_private.team_match_coverage_state(p_home);
  aw jsonb:=futbeat_private.team_match_coverage_state(p_away);
  -- Verified start: covered range, else (NO_DATA) the confirmed-empty one,
  -- read from the row so it holds while a step is being fetched; never for
  -- a team without provider source.
  h_from date:=case when hs->>'state'<>'UNAVAILABLE' then futbeat_private.team_match_known_from(
    (select c from futbeat_private.team_match_coverage c where c.team_id=p_home)) end;
  a_from date:=case when aw->>'state'<>'UNAVAILABLE' then futbeat_private.team_match_known_from(
    (select c from futbeat_private.team_match_coverage c where c.team_id=p_away)) end;
  requested boolean;
begin
  -- Extending = at least one of the two teams has a LIVE demand for a range
  -- older than its own verified start: the planner can still pick it (same
  -- conditions: recent, not yet attempted) or it is being fetched. A used
  -- or expired attempt (partial answer, failure) is no longer "extending",
  -- so a new request can be recorded.
  select coalesce(bool_or(d.past_target is not null
      and d.past_target<case d.team_id when p_home then h_from else a_from end
      and d.requested_at>now()-interval '7 days'
      and (d.requested_at>coalesce(c.last_attempt_at,'-infinity')
        or coalesce(c.lease_until,'-infinity')>now())),false)
  into requested
  from futbeat_private.team_match_demands d
  left join futbeat_private.team_match_coverage c on c.team_id=d.team_id
  where d.team_id in (p_home,p_away);
  return jsonb_strip_nulls(jsonb_build_object(
    'verifiedFrom',case when h_from is not null and a_from is not null then greatest(h_from,a_from) end,
    'historyFloor',floor_date,
    -- One more step back makes sense for a team with a known range above
    -- the floor and a provider source.
    'canExtend',coalesce(hs->>'state' in ('AVAILABLE','STALE','NO_DATA') and h_from>floor_date,false)
      or coalesce(aw->>'state' in ('AVAILABLE','STALE','NO_DATA') and a_from>floor_date,false),
    'extending',requested));
end $$;

create function public.futbeat_read_match_h2h(
  p_match_id text,
  p_scope text default 'all',
  p_cursor text default null,
  p_limit integer default 20
) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t jsonb; c_home text; c_away text; c_comp text;
  cursor_time timestamptz; cursor_id text;
  page jsonb; has_more boolean; totals jsonb; out_json jsonb;
begin
  if p_scope not in ('all','competition') or p_limit is null or p_limit<1 or p_limit>50 then
    raise exception 'Invalid h2h request';
  end if;
  if p_cursor is not null then
    begin
      cursor_time:=split_part(p_cursor,'|',1)::timestamptz;
      cursor_id:=nullif(substr(p_cursor,position('|' in p_cursor)+1),'');
      if position('|' in p_cursor)=0 then cursor_id:=null; end if;
    exception when others then raise exception 'Invalid h2h cursor';
    end;
    if cursor_id is null then raise exception 'Invalid h2h cursor'; end if;
  end if;
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  c_comp:=futbeat_private.futbeat_resolve_entity_id('competition',nullif(t->>'competitionId',''));

  with scoped as materialized (
    select * from futbeat_private.h2h_meetings(p_match_id) x
    where p_scope='all' or x.competition_id=c_comp
  ), windowed as (
    select * from scoped s
    where cursor_time is null or (s.start_time,s.match_id)<(cursor_time,cursor_id)
    order by s.start_time desc,s.match_id desc
    limit p_limit+1
  )
  select
    (select coalesce(jsonb_agg(w.meeting order by w.start_time desc,w.match_id desc),'[]'::jsonb)
      from (select * from windowed order by start_time desc,match_id desc limit p_limit) w),
    (select count(*)>p_limit from windowed),
    (select jsonb_build_object('homeWins',count(*) filter(where result='WIN'),
      'draws',count(*) filter(where result='DRAW'),'awayWins',count(*) filter(where result='LOSS'),
      'counted',count(result)) from scoped)
  into page,has_more,totals;

  select jsonb_build_object(
    'schemaVersion',1,
    'matchId',p_match_id,
    'pairKey',case when c_home is not null and c_away is not null then least(c_home,c_away)||'|'||greatest(c_home,c_away) end,
    'homeTeamId',c_home,
    'awayTeamId',c_away,
    'scope',p_scope,
    'competitionId',c_comp,
    'totals',totals,
    'meetings',page,
    'hasMore',has_more,
    'nextCursor',case when has_more then
      to_char((page->-1->>'startTime')::timestamptz at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
        ||'|'||(page->-1->>'matchId') end,
    'window',case when c_home is not null and c_away is not null and c_home<>c_away
      then futbeat_private.h2h_window(c_home,c_away) else '{}'::jsonb end,
    'teams',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id',e.id,'name',e.payload->>'name','shortName',e.payload->>'shortName',
        'color',e.payload->>'color','media',e.payload->'media')) order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='team' and e.id in (
        select c_home union select c_away
        union select value->>'homeTeamId' from jsonb_array_elements(page)
        union select value->>'awayTeamId' from jsonb_array_elements(page))),
    'competitions',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.payload->>'name') order by e.id),'[]'::jsonb)
      from futbeat_private.entities e where e.kind='competition' and e.id in (
        select c_comp union select value->>'competitionId' from jsonb_array_elements(page))))
  into out_json;
  return out_json;
end $$;

-- "Cargar historial anterior": one step back of BOTH teams' central coverage.
create function public.futbeat_request_match_h2h_history(p_match_id text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare t jsonb; c_home text; c_away text; hs jsonb; aw jsonb; out_home jsonb; out_away jsonb; w jsonb;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return jsonb_build_object('matchId',p_match_id,'found',false); end if;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if c_home is null or c_away is null or c_home=c_away then
    return jsonb_build_object('matchId',p_match_id,'found',true,'requested',false);
  end if;
  -- A step already in flight, or nothing left to ask: no new demand (a
  -- repeated or scripted extend never stacks steps).
  w:=futbeat_private.h2h_window(c_home,c_away);
  if (w->>'extending')::boolean or not (w->>'canExtend')::boolean then
    return jsonb_build_object('matchId',p_match_id,'found',true,'requested',false,'window',w);
  end if;
  hs:=futbeat_private.team_match_coverage_state(c_home);
  aw:=futbeat_private.team_match_coverage_state(c_away);
  -- p_before = the team's own covered_from; the request itself enforces the
  -- floor, the dedup and the throttle.
  out_home:=public.futbeat_request_team_matches(c_home,
    coalesce(nullif(hs->>'coveredFrom','')::date,nullif(hs->>'emptyFrom','')::date));
  out_away:=public.futbeat_request_team_matches(c_away,
    coalesce(nullif(aw->>'coveredFrom','')::date,nullif(aw->>'emptyFrom','')::date));
  return jsonb_build_object('matchId',p_match_id,'found',true,'home',out_home,'away',out_away,
    'window',futbeat_private.h2h_window(c_home,c_away));
end $$;

revoke all on function
  futbeat_private.h2h_meetings(text),
  futbeat_private.h2h_window(text,text)
from public,anon,authenticated,service_role;
revoke all on function
  public.futbeat_read_match_h2h(text,text,text,integer),
  public.futbeat_request_match_h2h_history(text)
from public,anon,authenticated;
grant execute on function
  public.futbeat_read_match_h2h(text,text,text,integer),
  public.futbeat_request_match_h2h_history(text)
to service_role;

notify pgrst,'reload schema';
