-- REOPEN-1 fix: stale missing_from_provider after a stuck-sweep reopen
-- Function: futbeat_private.reconcile_goal_results_local(date). No data change, no grant change.
CREATE OR REPLACE FUNCTION futbeat_private.reconcile_goal_results_local(p_provider_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r record; v_original jsonb; v_payload jsonb; v_events jsonb;
  v_changed integer:=0; v_events_changed integer:=0; v_state text;
  v_complete boolean; v_kickoff timestamptz; v_canonical_at timestamptz;
  v_attempts integer; v_current_start timestamptz;
  -- BE16: at most v_limit due rows per call (one short transaction); the rest waits for the next call.
  v_limit constant integer:=250; v_seen integer:=0; v_more boolean:=false; v_promoted integer:=0;
begin
  if p_provider_date is null then raise exception 'Invalid result date'; end if;
  select coalesce(a.attempt_count,0) into v_attempts
    from (select 1) seed left join futbeat_private.results_date_attempts a
      on a.provider='goal_api' and a.provider_date=p_provider_date;
  for r in
    select cm.match_id,cm.start_time,cm.updated_at as calendar_updated_at,o.status,o.minute,o.home_score,o.away_score,
      o.received_at,o.provider_observed_at,o.raw_payload,
      futbeat_private.observation_score(o.provider,o.home_score,o.away_score,o.raw_payload) score,
      t.status t_status,t.minute t_minute,
      futbeat_private.observation_score(t.provider,t.home_score,t.away_score,t.raw_payload) t_score,
      t.received_at t_received_at,t.provider_observed_at t_observed_at
    from (
      -- BE16: only rows whose inputs changed since their last reconciliation (the same test as
      -- next_goal_results_candidate) or that hold a promotable GOAL final. A skipped row would be
      -- rewritten with identical values: reconcile is a function of exactly these inputs.
      select c.match_id,c.start_time,c.updated_at from futbeat_private.calendar_matches c
      join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
      left join futbeat_private.match_result_reconciliation mr on mr.match_id=c.match_id
      where c.start_time>=p_provider_date::timestamp at time zone 'UTC'
        and c.start_time<(p_provider_date+1)::timestamp at time zone 'UTC'
        and (mr.match_id is null or mr.state='unresolved'
          -- REOPEN-1: 'missing_from_provider' is decided by the date's attempt count and age, which are
          -- not among the inputs above. When the stuck sweep lowers attempts below 4, that state is stale:
          -- the row is due again so the date can reach GOAL once more (regression from BE16 skip-unchanged).
          or (mr.state='missing_from_provider'
            and not (v_attempts>=4 and c.start_time<now()-interval '48 hours'))
          or mr.canonical_payload_hash is distinct from md5(e.payload::text)
          or mr.provider_date<>(c.start_time at time zone 'UTC')::date
          or exists(select 1 from futbeat_private.provider_observations o
            where o.provider='goal_api' and o.canonical_match_id=c.match_id
              and o.received_at>coalesce(mr.evidence_at,'-infinity'::timestamptz))
          or exists(select 1 from futbeat_private.canonical_events ce
            where ce.match_id=c.match_id and not coalesce(e.payload->'events','[]'::jsonb)
              @> jsonb_build_array(ce.payload))
          or case when e.payload->>'status'='FINISHED_PENDING_VERIFICATION'
            then futbeat_private.goal_final_promotable(c.match_id,e.payload) else false end)
      order by c.start_time,c.match_id limit v_limit+1
    ) cm
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
    v_seen:=v_seen+1;
    if v_seen>v_limit then v_more:=true; exit; end if;
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
          'score',coalesce(r.score,v_payload->'score'),
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
          'score',coalesce(r.score,v_payload->'score')));
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
        'score',coalesce(r.t_score,v_payload->'score'),
        'minute',coalesce(to_jsonb(r.t_minute),v_payload->'minute'),
        'provenance',coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
          'receivedAt',r.t_received_at,'verificationStatus','VERIFIED','reconciledLocally',true)
      ));
    end if;
    -- BE16: provider final with the same score -> VERIFIED (status only, see goal_final_promotable).
    if v_payload->>'status'='FINISHED_PENDING_VERIFICATION'
       and futbeat_private.goal_final_promotable(r.match_id,v_payload) then
      v_payload:=jsonb_set(v_payload||jsonb_build_object('status','VERIFIED'),'{provenance}',
        coalesce(v_payload->'provenance','{}'::jsonb)||jsonb_build_object(
          'verificationStatus','VERIFIED',
          -- previous verificationStatus, kept so rollback_data_be16.sql can restore the payload exactly
          'promotedFromPending',coalesce(v_payload#>>'{provenance,verificationStatus}','')),true);
      v_promoted:=v_promoted+1;
    end if;
    if v_payload is distinct from v_original then
      -- BE16: hash what was stored (BEFORE triggers may normalise events), so a row is never due forever.
      update futbeat_private.entities set payload=v_payload where id=r.match_id returning payload into v_payload;
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
  v_complete:=v_complete and not v_more;
  update futbeat_private.calendar_coverage set results_complete=v_complete,
    results_checked_at=now() where provider='goal_api' and provider_date=p_provider_date
      and results_complete is distinct from v_complete;
  return jsonb_build_object('date',p_provider_date,'updated',v_changed,
    'eventsUpdated',v_events_changed,'resultsComplete',v_complete,'more',v_more,'promoted',v_promoted,
    'unresolved',(select count(*) from futbeat_private.match_result_reconciliation mr
      where mr.provider='goal_api' and mr.provider_date=p_provider_date and mr.state='unresolved'));
end $function$
;

