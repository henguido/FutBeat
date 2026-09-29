-- Issue #99: Match Center "Cara a cara" v2 (correctness + coverage).
--
-- Root causes in read_match_preview (20260925060000):
--   * The head-to-head used the RAW stored status (no match_read_model), so a
--     final only known through terminal evidence never counted.
--   * Team identity was the raw payload id: matches stored under an alias of
--     either team (entity_redirects) were missed.
--   * `h2h.state='none'` whenever no local match existed: a cache miss looked
--     exactly like "no previous meetings", and nothing asked for coverage.
--   * Only the last 5 meetings were read, so the summary counted at most 5.
--   * The current match never counted, even once it had finished.
--
-- v2 (DB-only read, no provider call; same endpoint and schemaVersion):
--   * Pair identity: the two canonical team ids plus every alias redirected
--     to them (team_identity_ids); pairKey = least|greatest, so
--     pair(A,B) == pair(B,A). Never names.
--   * Every candidate goes through match_read_model_core (effective
--     lifecycle, redirects resolved). Only finals with a complete score are
--     meetings; results are computed by canonical team id, so a reversed
--     home/away history counts for the right team.
--   * Meetings up to the target's kickoff; the target itself counts only
--     once it is final (never twice). A scheduled/live target is returned
--     as `current`, outside every count.
--   * `totals` over ALL meetings (pair lookups are two small index scans);
--     `competitionTotals` for the target's canonical competition ("Este
--     torneo"). `meetings` returns the 20 most recent, self-contained.
--   * `availability` from the central per-team coverage (#153) of both
--     teams: AVAILABLE | STALE | PENDING | CONFIRMED_EMPTY | UNAVAILABLE.
--     No local meeting is CONFIRMED_EMPTY only when both teams' coverage was
--     verified (AVAILABLE or provider NO_DATA); otherwise PENDING.
--   * `state`/`matchIds`/`summary` and the `matches` list keep the v1
--     contract for installed apps (5 meetings before kickoff); recent form
--     is unchanged.
--   * futbeat_request_match_h2h: opening Cara a cara asks for the coverage
--     of both teams through futbeat_request_team_matches (one deduplicated
--     demand per canonical team; nothing when coverage is already fine).

create or replace function futbeat_private.read_match_preview(p_match_id text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t jsonb; kickoff timestamptz; home text; away text;
  form_days constant integer:=365; max_items constant integer:=5; max_meetings constant integer:=20;
  home_ids text[]; away_ids text[]; result jsonb;
  -- head-to-head (canonical)
  c_home text; c_away text; c_comp text; home_alias text[]; away_alias text[];
  target jsonb; target_final boolean:=false;
  meetings jsonb:='[]'::jsonb; summary jsonb; comp_summary jsonb;
  legacy_ids text[]:='{}'; legacy_summary jsonb;
  cov_home jsonb; cov_away jsonb; availability text; verified_from date;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return null; end if;
  kickoff:=nullif(t->>'startTime','')::timestamptz;
  home:=nullif(t->>'homeTeamId','');
  away:=nullif(t->>'awayTeamId','');

  if kickoff is not null and home is not null and away is not null then
    -- Recent form per side (unchanged from 20260925060000).
    select array_agg(x.id order by x.st desc,x.id) into home_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=home or e.payload->>'awayTeamId'=home)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;
    select array_agg(x.id order by x.st desc,x.id) into away_ids from (
      select e.id,nullif(e.payload->>'startTime','')::timestamptz st
      from futbeat_private.entities e
      where e.kind='match' and (e.payload->>'homeTeamId'=away or e.payload->>'awayTeamId'=away)
        and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and nullif(e.payload->>'startTime','')::timestamptz<kickoff
        and nullif(e.payload->>'startTime','')::timestamptz>=kickoff-make_interval(days=>form_days)
      order by 2 desc,1 limit max_items) x;

    -- Head-to-head v2: canonical pair, aliases included, effective status.
    c_home:=futbeat_private.futbeat_resolve_entity_id('team',home);
    c_away:=futbeat_private.futbeat_resolve_entity_id('team',away);
    c_comp:=futbeat_private.futbeat_resolve_entity_id('competition',nullif(t->>'competitionId',''));
    target:=futbeat_private.match_read_model_core(t,false);
    target_final:=target->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number';
    if c_home<>c_away then
      home_alias:=futbeat_private.team_identity_ids(c_home);
      away_alias:=futbeat_private.team_identity_ids(c_away);
      with candidates as (
        -- Two index lookups (home/away team indexes), then the pair filter.
        select e.id,e.payload from futbeat_private.entities e
        where e.kind='match' and e.payload->>'homeTeamId'=any(home_alias||away_alias)
          and e.payload->>'awayTeamId'=any(home_alias||away_alias)
          and ((e.payload->>'homeTeamId'=any(home_alias) and e.payload->>'awayTeamId'=any(away_alias))
            or (e.payload->>'homeTeamId'=any(away_alias) and e.payload->>'awayTeamId'=any(home_alias)))
          and nullif(e.payload->>'startTime','') is not null
          and (e.payload->>'startTime')::timestamptz<=kickoff
      ), modeled as (
        select c.id,futbeat_private.match_read_model_core(c.payload,false) m from candidates c
      ), finals as (
        select id,m,futbeat_private.team_match_result(m,c_home) r from modeled
        where m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
          and jsonb_typeof(m->'score'->'home')='number' and jsonb_typeof(m->'score'->'away')='number'
          -- The target counts only once final (and then exactly once).
          and (id<>p_match_id or target_final)
      )
      select
        coalesce((select jsonb_agg(jsonb_build_object(
            'matchId',f.id,
            'competitionId',f.m->>'competitionId',
            'startTime',f.m->>'startTime',
            'status',f.m->>'status',
            'homeTeamId',f.m->>'homeTeamId',
            'awayTeamId',f.m->>'awayTeamId',
            'score',jsonb_build_object('home',f.m->'score'->'home','away',f.m->'score'->'away'),
            'result',f.r)
            order by (f.m->>'startTime')::timestamptz desc,f.id)
          from (select * from finals order by (m->>'startTime')::timestamptz desc,id limit max_meetings) f),'[]'::jsonb),
        (select jsonb_build_object('homeWins',count(*) filter(where r='WIN'),'draws',count(*) filter(where r='DRAW'),
            'awayWins',count(*) filter(where r='LOSS'),'counted',count(r)) from finals),
        (select jsonb_build_object('competitionId',c_comp,'homeWins',count(*) filter(where r='WIN'),
            'draws',count(*) filter(where r='DRAW'),'awayWins',count(*) filter(where r='LOSS'),'counted',count(r))
          from finals where m->>'competitionId'=c_comp)
      into meetings,summary,comp_summary;

      select coalesce(array_agg(x.id order by x.st desc,x.id),'{}') into legacy_ids from (
        select value->>'matchId' id,(value->>'startTime')::timestamptz st
        from jsonb_array_elements(meetings)
        where value->>'matchId'<>p_match_id and (value->>'startTime')::timestamptz<kickoff
        order by 2 desc,1 limit max_items) x;
      select jsonb_build_object('homeWins',count(*) filter(where value->>'result'='WIN'),
          'draws',count(*) filter(where value->>'result'='DRAW'),
          'awayWins',count(*) filter(where value->>'result'='LOSS'),'counted',count(value->>'result'))
        into legacy_summary
        from jsonb_array_elements(meetings) where value->>'matchId'=any(legacy_ids);

      cov_home:=futbeat_private.team_match_coverage_state(c_home);
      cov_away:=futbeat_private.team_match_coverage_state(c_away);
      availability:=case
        when jsonb_array_length(meetings)>0 then
          case when cov_home->>'state' in ('AVAILABLE','NO_DATA','UNAVAILABLE')
            and cov_away->>'state' in ('AVAILABLE','NO_DATA','UNAVAILABLE') then 'AVAILABLE' else 'STALE' end
        when cov_home->>'state' in ('AVAILABLE','NO_DATA') and cov_away->>'state' in ('AVAILABLE','NO_DATA')
          then 'CONFIRMED_EMPTY'
        when cov_home->>'state' in ('PENDING','STALE') or cov_away->>'state' in ('PENDING','STALE')
          then 'PENDING'
        else 'UNAVAILABLE' end;
      -- The verified window is where BOTH teams have an explicit covered
      -- range (a NO_DATA side has none): otherwise null, never a date that
      -- claims more than what was checked.
      verified_from:=case when nullif(cov_home->>'coveredFrom','') is not null
          and nullif(cov_away->>'coveredFrom','') is not null
        then greatest((cov_home->>'coveredFrom')::date,(cov_away->>'coveredFrom')::date) end;
    end if;
  end if;
  home_ids:=coalesce(home_ids,'{}'); away_ids:=coalesce(away_ids,'{}');

  with meeting_rows as (
    select value m from jsonb_array_elements(coalesce(meetings,'[]'::jsonb))
  ), ids as (
    -- Legacy `matches`: form + the legacy 5 meetings (v1 contract).
    select distinct unnest(home_ids||away_ids||legacy_ids) id
  ), items as (
    select e.id,e.payload p from futbeat_private.entities e join ids on ids.id=e.id where e.kind='match'
  ), team_ids as (
    select distinct x id from (
      select home x union all select away union all select c_home union all select c_away
      union all select i.p->>'homeTeamId' from items i
      union all select i.p->>'awayTeamId' from items i
      union all select r.m->>'homeTeamId' from meeting_rows r
      union all select r.m->>'awayTeamId' from meeting_rows r) t where x is not null
  ), comp_ids as (
    select distinct x id from (select i.p->>'competitionId' x from items i
      union all select r.m->>'competitionId' from meeting_rows r union all select c_comp) c where x is not null
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'matchId',p_match_id,
    'homeTeamId',home,
    'awayTeamId',away,
    'startTime',t->>'startTime',
    'formWindowDays',form_days,
    'form',jsonb_build_object(
      'home',jsonb_build_object(
        'state',case cardinality(home_ids) when 0 then 'none' when max_items then 'available' else 'partial' end,
        'matchIds',to_jsonb(home_ids),
        'results',(select coalesce(jsonb_agg(futbeat_private.team_match_result(i.p,home) order by o.n),'[]')
          from unnest(home_ids) with ordinality o(id,n) join items i on i.id=o.id)),
      'away',jsonb_build_object(
        'state',case cardinality(away_ids) when 0 then 'none' when max_items then 'available' else 'partial' end,
        'matchIds',to_jsonb(away_ids),
        'results',(select coalesce(jsonb_agg(futbeat_private.team_match_result(i.p,away) order by o.n),'[]')
          from unnest(away_ids) with ordinality o(id,n) join items i on i.id=o.id))),
    'h2h',jsonb_strip_nulls(jsonb_build_object(
      -- Legacy keys (installed apps, v1 contract: 5 meetings before kickoff).
      'state',case when cardinality(legacy_ids)>0 then 'available' else 'none' end,
      'matchIds',to_jsonb(legacy_ids),
      'summary',coalesce(legacy_summary,jsonb_build_object('homeWins',0,'draws',0,'awayWins',0,'counted',0)),
      -- v2
      'pairKey',case when c_home is not null and c_away is not null
        then least(c_home,c_away)||'|'||greatest(c_home,c_away) end,
      'homeTeamId',c_home,
      'awayTeamId',c_away,
      'competitionId',c_comp,
      'availability',coalesce(availability,'UNAVAILABLE'),
      'coverage',jsonb_build_object('home',cov_home->>'state','away',cov_away->>'state',
        'verifiedFrom',verified_from),
      'totals',coalesce(summary,jsonb_build_object('homeWins',0,'draws',0,'awayWins',0,'counted',0)),
      'competitionTotals',comp_summary,
      'meetings',coalesce(meetings,'[]'::jsonb),
      'current',case when target is not null and not target_final then jsonb_build_object(
        'matchId',p_match_id,'competitionId',target->>'competitionId','startTime',target->>'startTime',
        'status',target->>'status','homeTeamId',target->>'homeTeamId','awayTeamId',target->>'awayTeamId',
        'score',case when jsonb_typeof(target->'score'->'home')='number' and jsonb_typeof(target->'score'->'away')='number'
          then jsonb_build_object('home',target->'score'->'home','away',target->'score'->'away') end) end)),
    'matches',(select coalesce(jsonb_agg(jsonb_build_object(
        'matchId',i.id,
        'competitionId',i.p->>'competitionId',
        'startTime',i.p->>'startTime',
        'status',i.p->>'status',
        'homeTeamId',i.p->>'homeTeamId',
        'awayTeamId',i.p->>'awayTeamId',
        'score',case when jsonb_typeof(i.p->'score'->'home')='number' and jsonb_typeof(i.p->'score'->'away')='number'
          then jsonb_build_object('home',i.p->'score'->'home','away',i.p->'score'->'away') end)
        order by nullif(i.p->>'startTime','')::timestamptz desc,i.id),'[]') from items i),
    'teams',(select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
        'id',e.id,'name',e.payload->>'name','shortName',e.payload->>'shortName',
        'color',e.payload->>'color','media',e.payload->'media')) order by e.id),'[]')
      from futbeat_private.entities e join team_ids on team_ids.id=e.id where e.kind='team'),
    'competitions',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'name',e.payload->>'name') order by e.id),'[]')
      from futbeat_private.entities e join comp_ids on comp_ids.id=e.id where e.kind='competition'))
  into result;
  return result;
end $$;

-- Opening Cara a cara asks for the central coverage of both canonical teams
-- (deduplicated per team, nothing when coverage is fine or has no source).
create function public.futbeat_request_match_h2h(p_match_id text)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare t jsonb; c_home text; c_away text;
begin
  select e.payload into t from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  if t is null then return jsonb_build_object('matchId',p_match_id,'found',false); end if;
  c_home:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'homeTeamId',''));
  c_away:=futbeat_private.futbeat_resolve_entity_id('team',nullif(t->>'awayTeamId',''));
  if c_home is null or c_away is null or c_home=c_away then
    return jsonb_build_object('matchId',p_match_id,'found',true,'requested',false);
  end if;
  return jsonb_build_object('matchId',p_match_id,'found',true,
    'home',public.futbeat_request_team_matches(c_home),
    'away',public.futbeat_request_team_matches(c_away));
end $$;

-- ---------------------------------------------------------------------------
-- Team-match coverage progresses on demand (no new cron).
--
-- #153 left the team-fixtures lane manual-only: a recorded demand (team
-- profile or Cara a cara) could stay PENDING forever. A plain time debounce
-- would strand work too: Cara a cara records two teams in one request, and a
-- second demand arriving inside the debounce window would be dropped.
--
-- Protocol on worker_wakeups row 'team-fixtures-only' (no time debounce):
--   * a NEW demand write (already at most one a minute per team) calls
--     wake_provider_worker('team-fixtures-only');
--   * no run in progress -> take a run lease (running_until) and POST the
--     worker once ('queued');
--   * a run in progress -> only set `pending` ('pending'): no second POST;
--   * the worker drains up to a bounded number of demanded teams, then calls
--     futbeat_finish_team_fixtures_run(), which atomically either renews the
--     lease and clears `pending` (another round: a demand arrived meanwhile)
--     or releases the lease. Every demand recorded before the release is
--     seen by some round; every one after it wakes a new run.
--   * a crashed run releases itself when the lease (5 min) expires.
-- Quota, floor, cap, window, pages and planner order are unchanged: each
-- page is still reserved through quota_decision('goal_api','team-fixtures',
-- 'coverage'); LIVE keeps its floor.
-- ---------------------------------------------------------------------------

alter table futbeat_private.worker_wakeups
  add column if not exists pending boolean not null default false,
  add column if not exists running_until timestamptz;

create or replace function futbeat_private.wake_provider_worker(p_trigger text default 'demand')
returns text language plpgsql security definer set search_path='' as $$
declare debounce interval:=make_interval(secs=>case when p_trigger='calendar'
    then futbeat_private.quota_setting('goal_api','calendarWakeDebounceSeconds',5)
    else futbeat_private.quota_setting('goal_api','wakeDebounceSeconds',15) end);
  last_wake timestamptz; url text; result text; run_until timestamptz;
begin
  if p_trigger is null or p_trigger not in ('demand','results-only','calendar','team-fixtures-only') then
    raise exception 'Invalid wake trigger';
  end if;
  if p_trigger='team-fixtures-only' then
    -- Short, serialized decision: this row is touched only by new demand
    -- writes (<= 1/min per team) and by the worker's finish call.
    perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-worker-wake'),hashtext(p_trigger));
    insert into futbeat_private.worker_wakeups(trigger,last_wake_at,wake_count)
    values(p_trigger,'-infinity',0) on conflict(trigger) do nothing;
    select w.running_until into run_until from futbeat_private.worker_wakeups w
    where w.trigger=p_trigger for update;
    if run_until>now() then
      update futbeat_private.worker_wakeups set pending=true,debounced_count=debounced_count+1
      where trigger=p_trigger;
      perform futbeat_private.bump_metric('team_match_wake_pending');
      return 'pending';
    end if;
    update futbeat_private.worker_wakeups
    set last_wake_at=now(),wake_count=wake_count+1,pending=false,running_until=now()+interval '5 minutes'
    where trigger=p_trigger;
  else
    select w.last_wake_at into last_wake from futbeat_private.worker_wakeups w
    where w.trigger=p_trigger for update skip locked;
    if not found then
      if exists(select 1 from futbeat_private.worker_wakeups where trigger=p_trigger) then
        perform futbeat_private.bump_metric('wake_debounced');
        return 'debounced';
      end if;
      insert into futbeat_private.worker_wakeups(trigger,last_wake_at,wake_count)
      values(p_trigger,now(),1) on conflict(trigger) do nothing;
      if not found then
        perform futbeat_private.bump_metric('wake_debounced');
        return 'debounced';
      end if;
    elsif last_wake>now()-debounce then
      perform futbeat_private.bump_metric('wake_debounced');
      return 'debounced';
    else
      update futbeat_private.worker_wakeups set last_wake_at=now(),wake_count=wake_count+1 where trigger=p_trigger;
    end if;
  end if;
  select value into url from futbeat_private.runtime_settings where key='goal_worker_url';
  if to_regnamespace('net') is null or to_regnamespace('vault') is null or url is null then
    result:='unavailable';
    -- No worker will run: never hold the run lease.
    update futbeat_private.worker_wakeups set running_until=null where trigger=p_trigger and p_trigger='team-fixtures-only';
  else
    execute $q$select net.http_post(
        url:=$1,
        headers:=jsonb_build_object('Content-Type','application/json','x-futbeat-cron-token',(
          select decrypted_secret from vault.decrypted_secrets
          where name='futbeat_goal_live_cron_token' order by updated_at desc nulls last,created_at desc limit 1)),
        body:=jsonb_build_object('trigger',$2),
        timeout_milliseconds:=30000)$q$ using url,p_trigger;
    result:='queued';
    if p_trigger='team-fixtures-only' then perform futbeat_private.bump_metric('team_match_wake_queued'); end if;
  end if;
  update futbeat_private.worker_wakeups set last_result=result where trigger=p_trigger;
  return result;
end $$;

-- Called by the worker after each bounded drain round. Atomically: a demand
-- that arrived during the run (`pending`) renews the lease for one more round;
-- otherwise the lease is released so the next demand wakes a new run.
-- p_release (quota stop, round cap, error): release now, keeping `pending`
-- so the next wake is never refused.
create function public.futbeat_finish_team_fixtures_run(p_release boolean default false)
returns jsonb language plpgsql volatile security definer set search_path='' as $$
declare was_pending boolean;
begin
  perform pg_catalog.pg_advisory_xact_lock(hashtext('futbeat-worker-wake'),hashtext('team-fixtures-only'));
  select w.pending into was_pending from futbeat_private.worker_wakeups w
  where w.trigger='team-fixtures-only' for update;
  if coalesce(p_release,false) then
    update futbeat_private.worker_wakeups set running_until=null where trigger='team-fixtures-only';
    return jsonb_build_object('again',false,'pending',coalesce(was_pending,false));
  end if;
  if coalesce(was_pending,false) then
    update futbeat_private.worker_wakeups set pending=false,running_until=now()+interval '5 minutes'
    where trigger='team-fixtures-only';
  else
    update futbeat_private.worker_wakeups set running_until=null where trigger='team-fixtures-only';
  end if;
  return jsonb_build_object('again',coalesce(was_pending,false));
end $$;

-- Same as 20260929110000, plus: a NEW demand write wakes the worker.
create or replace function public.futbeat_request_team_matches(p_team_id text,p_before date default null)
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
  wake text;
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
    -- Only a real (throttled) demand write wakes the worker.
    if recorded then wake:=futbeat_private.wake_provider_worker('team-fixtures-only'); end if;
  end if;
  return st||jsonb_strip_nulls(jsonb_build_object('teamId',tid,'demandRecorded',recorded,'backfill',backfill,'wake',wake));
end $$;

revoke all on function public.futbeat_finish_team_fixtures_run(boolean) from public,anon,authenticated;
grant execute on function public.futbeat_finish_team_fixtures_run(boolean) to service_role;

revoke all on function futbeat_private.read_match_preview(text) from public,anon,authenticated,service_role;
revoke all on function public.futbeat_request_match_h2h(text) from public,anon,authenticated;
grant execute on function public.futbeat_request_match_h2h(text) to service_role;

notify pgrst,'reload schema';
