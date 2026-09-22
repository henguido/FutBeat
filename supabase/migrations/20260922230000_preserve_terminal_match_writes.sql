-- Write-side complement of 20260922220000_terminal_evidence_read_model.sql.
-- No provider calls, ledger writes, cron changes or data backfill here.
--
-- Cause: futbeat_store_calendar_range replaced the whole match payload, so a
-- later calendar re-ingest reporting DISCOVERED/SCHEDULED/PRE_MATCH degraded a
-- stored final (and its score/provenance). reconcile_goal_results_local only
-- looked at the newest observation and required it to be newer than
-- payload.receivedAt, which that same re-ingest had just bumped, so the date
-- stayed "unresolved" forever and kept consuming results attempts.
--
-- Precedence (never inferred from the clock, goals or a score):
-- 1. A stored VERIFIED/FINISHED_PENDING_VERIFICATION (or SUSPENDED/ABANDONED)
--    is kept against a pre-match re-ingest of the same fixture.
-- 2. Same fixture = same kickoff, or a kickoff correction that still precedes
--    the stored evidence. A final recorded before a rescheduled (later)
--    kickoff is NOT kept: the new fixture wins.
-- 3. Terminal/interrupted incoming states, LIVE and POSTPONED/CANCELLED keep
--    their existing overwrite semantics; nothing is converted to FINISHED.

create or replace function futbeat_private.merge_calendar_match_payload(
  p_old jsonb,p_new jsonb
) returns jsonb language plpgsql stable set search_path='' as $$
declare
  v_old_start timestamptz:=futbeat_private.try_timestamptz(p_old->>'startTime');
  v_new_start timestamptz:=futbeat_private.try_timestamptz(p_new->>'startTime');
  v_evidence_at timestamptz:=futbeat_private.try_timestamptz(p_old#>>'{provenance,receivedAt}');
  v_merged jsonb;
begin
  if p_old is null or v_new_start is null
     or coalesce(p_old->>'status','') not in
       ('VERIFIED','FINISHED_PENDING_VERIFICATION','SUSPENDED','ABANDONED')
     or coalesce(p_new->>'status','') not in ('DISCOVERED','SCHEDULED','PRE_MATCH')
     or not (v_old_start is not distinct from v_new_start
       or (v_evidence_at is not null and v_evidence_at>=v_new_start))
  then
    return p_new;
  end if;
  -- Fresh descriptive fields from the calendar; lifecycle fields from the
  -- stored evidence. Provenance keeps the evidence time for later reschedule
  -- checks, so an unchanged re-ingest is a no-op (no cache invalidation).
  v_merged:=p_new||jsonb_build_object('status',p_old->'status',
    'provenance',coalesce(p_old->'provenance',p_new->'provenance'));
  if p_old ? 'score' then v_merged:=v_merged||jsonb_build_object('score',p_old->'score'); end if;
  if p_old ? 'minute' then v_merged:=v_merged||jsonb_build_object('minute',p_old->'minute'); end if;
  if jsonb_typeof(p_old->'events')='array' and jsonb_array_length(p_old->'events')>0
     and coalesce(jsonb_array_length(case when jsonb_typeof(p_new->'events')='array'
       then p_new->'events' end),0)=0 then
    v_merged:=v_merged||jsonb_build_object('events',p_old->'events');
  end if;
  if jsonb_typeof(p_old->'statistics')='array' and jsonb_array_length(p_old->'statistics')>0
     and coalesce(jsonb_array_length(case when jsonb_typeof(p_new->'statistics')='array'
       then p_new->'statistics' end),0)=0 then
    v_merged:=v_merged||jsonb_build_object('statistics',p_old->'statistics');
  end if;
  return v_merged;
end $$;

create or replace function futbeat_private.futbeat_store_calendar_range(
  p_provider text,
  p_received_at timestamptz,
  p_coverage jsonb,
  p_snapshot jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
begin
  if p_provider <> 'goal_api'
     or jsonb_typeof(p_coverage) <> 'array'
     or jsonb_array_length(p_coverage) > 31
     or p_snapshot->>'demo' <> 'false'
     or p_snapshot->>'schemaVersion' <> '1'
     or jsonb_typeof(p_snapshot->'competitions') <> 'array'
     or jsonb_typeof(p_snapshot->'teams') <> 'array'
     or jsonb_typeof(p_snapshot->'matches') <> 'array'
  then
    raise exception 'Invalid calendar range payload';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_snapshot->'matches') m
    where m->'provenance'->>'source' <> 'GOAL API'
  ) then
    raise exception 'Unexpected calendar fixture source';
  end if;

  if exists(
    select 1
    from jsonb_array_elements(p_coverage) c
    where coalesce(c->>'date','') !~ '^\d{4}-\d{2}-\d{2}$'
       or coalesce(c->>'count','') !~ '^\d+$'
  ) then
    raise exception 'Invalid calendar coverage item';
  end if;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','competition',item
  from jsonb_array_elements(p_snapshot->'competitions') x(item)
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='competition'
      and e.payload is distinct from excluded.payload;

  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','team',item
  from jsonb_array_elements(p_snapshot->'teams') x(item)
  on conflict(id) do update
    set payload=excluded.payload
    where e.kind='team'
      and e.payload is distinct from excluded.payload;

  -- Never degrade stored terminal evidence of the same fixture.
  insert into futbeat_private.entities as e(id,kind,payload)
  select item->>'id','match',item
  from jsonb_array_elements(p_snapshot->'matches') x(item)
  on conflict(id) do update
    set payload=futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload)
    where e.kind='match'
      and e.payload is distinct from
        futbeat_private.merge_calendar_match_payload(e.payload,excluded.payload);

  with coverage_dates as materialized (
    select (value->>'date')::date as d
    from jsonb_array_elements(p_coverage)
  ),
  snapshot_ids as materialized (
    select value->>'id' as id
    from jsonb_array_elements(p_snapshot->'matches')
  )
  delete from futbeat_private.calendar_matches cm
  where cm.source='GOAL API'
    and exists(
      select 1
      from coverage_dates cd
      where cm.start_time >= (cd.d::timestamp at time zone 'UTC')
        and cm.start_time < ((cd.d + 1)::timestamp at time zone 'UTC')
    )
    and not exists(
      select 1
      from snapshot_ids s
      where s.id=cm.match_id
    );

  insert into futbeat_private.calendar_coverage(
    provider,provider_date,fetched_at,fixture_count
  )
  select
    p_provider,
    (value->>'date')::date,
    p_received_at,
    (value->>'count')::integer
  from jsonb_array_elements(p_coverage)
  on conflict(provider,provider_date) do update
  set
    fetched_at=excluded.fetched_at,
    fixture_count=excluded.fixture_count;

  return jsonb_build_object(
    'matches',jsonb_array_length(p_snapshot->'matches'),
    'competitions',jsonb_array_length(p_snapshot->'competitions'),
    'teams',jsonb_array_length(p_snapshot->'teams'),
    'coveredDates',jsonb_array_length(p_coverage)
  );
end;
$$;

create or replace function futbeat_private.reconcile_goal_results_local(p_provider_date date)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare r record; v_original jsonb; v_payload jsonb; v_events jsonb;
  v_changed integer:=0; v_events_changed integer:=0; v_state text;
  v_complete boolean; v_kickoff timestamptz; v_canonical_at timestamptz;
  v_attempts integer; v_current_start timestamptz;
begin
  if p_provider_date is null then raise exception 'Invalid result date'; end if;
  select coalesce(a.attempt_count,0) into v_attempts
    from (select 1) seed left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=p_provider_date;
  for r in
    select cm.match_id,cm.start_time,cm.updated_at as calendar_updated_at,o.status,o.minute,o.home_score,o.away_score,
      o.received_at,o.provider_observed_at,o.raw_payload,
      t.status t_status,t.minute t_minute,t.home_score t_home,t.away_score t_away,
      t.received_at t_received_at,t.provider_observed_at t_observed_at
    from futbeat_private.calendar_matches cm
    left join lateral (
      select observation.* from futbeat_private.provider_observations observation
      where observation.provider='goal_api' and observation.canonical_match_id=cm.match_id
      order by observation.received_at desc,observation.id desc limit 1
    ) o on true
    -- Newest real terminal observation, even if not the newest observation
    -- overall (a lagging LIVE feed can follow the final whistle).
    left join lateral (
      select observation.* from futbeat_private.provider_observations observation
      where observation.provider='goal_api' and observation.canonical_match_id=cm.match_id
        and observation.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
      order by observation.received_at desc,observation.id desc limit 1
    ) t on true
    where cm.start_time>=p_provider_date::timestamp at time zone 'UTC'
      and cm.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
  loop
    select payload into v_original from futbeat_private.entities
      where id=r.match_id and kind='match' for update;
    if v_original is null then continue; end if;
    v_payload:=v_original;
    select coalesce(jsonb_agg(payload order by
      coalesce(futbeat_private.safe_result_integer(payload->>'minute'),-1),
      coalesce(futbeat_private.safe_result_integer(payload->>'extraMinute'),0),first_seen_at,id),'[]'::jsonb)
      into v_events from futbeat_private.canonical_events where match_id=r.match_id;
    if jsonb_array_length(v_events)>0
       and coalesce(v_payload->'events','[]'::jsonb) is distinct from v_events then
      v_payload:=jsonb_set(v_payload,'{events}',v_events,true);
      v_events_changed:=v_events_changed+1;
    end if;
    v_canonical_at:=coalesce(
      futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}'),
      r.calendar_updated_at);
    v_kickoff:=futbeat_private.try_timestamptz(r.raw_payload->>'kickoffUtc');
    if r.received_at is not null
       and coalesce(r.provider_observed_at,r.received_at)>=v_canonical_at then
      if v_payload->>'status' not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and v_kickoff is not null and v_kickoff is distinct from
         futbeat_private.try_timestamptz(v_payload->>'startTime') then
        v_payload:=jsonb_set(v_payload,'{startTime}',to_jsonb(v_kickoff),true);
      end if;
      if coalesce(v_payload->>'status','') not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED')
         and (
           r.status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
           or (r.status in ('SCHEDULED','PRE_MATCH','LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
             and v_payload->>'status' in ('POSTPONED','SUSPENDED','ABANDONED')
             and (r.status not in ('SCHEDULED','PRE_MATCH') or v_kickoff is not null))
         ) then
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',r.status,
          'score',case when r.home_score is not null and r.away_score is not null
            then jsonb_build_object('home',r.home_score,'away',r.away_score)
            else v_payload->'score' end,
          'minute',coalesce(to_jsonb(r.minute),v_payload->'minute'),
          'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
            'receivedAt',r.received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
        ));
      elsif v_payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and r.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
        -- A final score can be corrected by newer real evidence, but finished
        -- status never regresses and CANCELLED remains a strong terminal state.
        v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
          'status',case when v_payload->>'status'='VERIFIED' or r.status='VERIFIED'
            then 'VERIFIED' else 'FINISHED_PENDING_VERIFICATION' end,
          'score',case when r.home_score is not null and r.away_score is not null
            then jsonb_build_object('home',r.home_score,'away',r.away_score)
            else v_payload->'score' end));
        if v_payload is distinct from v_original then
          v_payload:=jsonb_set(v_payload,'{provenance}',
            coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
              'receivedAt',r.received_at,'reconciledLocally',true),true);
        end if;
      end if;
    end if;
    -- A real terminal observation after the CURRENT kickoff closes a pre-match
    -- (or expired LIVE) payload even when a calendar re-ingest made
    -- payload.receivedAt newer. Same rule as match_read_model; a fresh LIVE
    -- and SUSPENDED/ABANDONED/POSTPONED/CANCELLED are never converted here.
    v_current_start:=futbeat_private.try_timestamptz(v_payload->>'startTime');
    if r.t_received_at is not null and v_current_start is not null
       and coalesce(r.t_observed_at,r.t_received_at)>=v_current_start
       and (coalesce(v_payload->>'status','') in ('DISCOVERED','SCHEDULED','PRE_MATCH')
         or (v_payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
           and coalesce(futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}'),
             '-infinity'::timestamptz)<now()-interval '15 minutes')) then
      v_payload:=v_payload||jsonb_strip_nulls(jsonb_build_object(
        'status',r.t_status,
        'score',case when r.t_home is not null and r.t_away is not null
          then jsonb_build_object('home',r.t_home,'away',r.t_away)
          else v_payload->'score' end,
        'minute',coalesce(to_jsonb(r.t_minute),v_payload->'minute'),
        'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
          'receivedAt',r.t_received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
      ));
    end if;
    if v_payload is distinct from v_original then
      update futbeat_private.entities set payload=v_payload where id=r.match_id;
      v_changed:=v_changed+1;
    end if;
    v_state:=case
      when (futbeat_private.try_timestamptz(v_payload->>'startTime') at time zone 'UTC')::date<>p_provider_date
        then 'rescheduled'
      when v_payload->>'status' in
        ('VERIFIED','FINISHED_PENDING_VERIFICATION','POSTPONED','CANCELLED','SUSPENDED','ABANDONED')
        then 'resolved'
      when v_attempts>=4 and r.start_time<now()-interval '48 hours'
        then 'missing_from_provider'
      else 'unresolved' end;
    insert into futbeat_private.match_result_reconciliation(
      match_id,state,provider,provider_date,evidence_at,canonical_payload_hash,updated_at)
    values(r.match_id,v_state,'goal_api',p_provider_date,r.received_at,md5(v_payload::text),now())
    on conflict(match_id) do update set state=excluded.state,provider_date=excluded.provider_date,
      evidence_at=excluded.evidence_at,canonical_payload_hash=excluded.canonical_payload_hash,updated_at=excluded.updated_at
    where (futbeat_private.match_result_reconciliation.state,
           futbeat_private.match_result_reconciliation.provider_date,
           futbeat_private.match_result_reconciliation.evidence_at,
           futbeat_private.match_result_reconciliation.canonical_payload_hash)
       is distinct from (excluded.state,excluded.provider_date,excluded.evidence_at,excluded.canonical_payload_hash);
  end loop;
  select not exists(select 1 from futbeat_private.match_result_reconciliation mr
    where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved')
    into v_complete;
  update futbeat_private.calendar_coverage set results_complete=v_complete,
    results_checked_at=now() where provider='goal_api' and provider_date=p_provider_date
      and results_complete is distinct from v_complete;
  return jsonb_build_object('date',p_provider_date,'updated',v_changed,
    'eventsUpdated',v_events_changed,'resultsComplete',v_complete,
    'unresolved',(select count(*) from futbeat_private.match_result_reconciliation mr
      where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved'));
end $$;

revoke all on function
  futbeat_private.merge_calendar_match_payload(jsonb,jsonb),
  futbeat_private.futbeat_store_calendar_range(text,timestamptz,jsonb,jsonb),
  futbeat_private.reconcile_goal_results_local(date)
from public,anon,authenticated;

-- No cache bump: functions only. Entity writes produced by these functions
-- invalidate exactly the affected calendar dates through existing triggers,
-- and a no-op re-ingest no longer writes at all.
notify pgrst,'reload schema';
