-- GOAL terminal result semantics: one rule for every reader of a GOAL
-- answer (worker normalizer, terminal score correction, results
-- reconciliation, read model).
--
-- Incident (2026-10-01, production, read-only evidence): GOAL match detail
-- answered two finished matches (finals 6-3 and 1-2) with matchStatus
-- FINISHED and homeTeamScore/awayTeamScore = 0-0, while
-- homeTeamFtScore/awayTeamFtScore and the half-time score kept the real
-- result. 147 stored terminal answers have that shape. Every FutBeat writer
-- read the running total only, so such an answer looked like a final 0-0:
-- the terminal score correction trigger (20260930120000, disabled in
-- production before it wrote anything) and the existing per-date results
-- reconciliation would have replaced the real final.
--
-- GOAL fields (measured on ~70 000 stored answers):
--   homeTeamScore / awayTeamScore      running total, extra time included,
--                                      penalties excluded;
--   homeTeamFtScore / awayTeamFtScore  regulation (90') score, filled when
--                                      regulation ends;
--   homeTeamExtraScore / ...           goals in extra time only;
--   homeTeamPenaltyScore / ...         shoot-out, never part of the score;
--   homeTeamHalftimeScore / ...        first half.
-- Rule (mirrors goalFixtureScore in supabase/functions/_shared/
-- live_events.ts; a parity test runs both on the same fixtures):
--   * not terminal (anything but FINISHED / AFTER_ET / AFTER_PEN / AWARDED):
--     the running total;
--   * terminal with a complete FtScore: FT + ExtraScore (ExtraScore required
--     after extra time, 0 otherwise). The running total must equal it, be
--     absent or be the 0-0 reset; any other running total is incoherent;
--   * terminal without FtScore: the running total;
--   * a terminal result below the half-time score is impossible;
--   * values: non-negative integers (JSON number or digit text, <= 999);
--     anything unknown or incoherent -> NULL (never a guess, and a NULL
--     score never replaces a stored one).
-- observation_score() applies it to a stored observation: a GOAL answer is
-- re-read from its raw payload (so the 0-0 answers already stored are
-- harmless); any other provider keeps its stored columns.
--
-- Changed functions (bodies otherwise verbatim):
--   apply_terminal_score_correction  from 20260930120000;
--   reconcile_goal_results_local     from 20260922230000;
--   match_read_model_core            from 20260930100000;
--   store_match_detail_before_media  from 20260930100000 (events score guard).
-- The trigger futbeat_terminal_score_correction is NOT re-enabled here: in
-- production it stays disabled until an explicit operational decision.
-- No data is written, no provider call, cron, quota or ledger change.

create or replace function futbeat_private.goal_score_value(p_value jsonb)
returns integer language sql immutable set search_path='' as $$
  select case
    when jsonb_typeof(p_value)='number' and p_value::text~'^\d{1,3}$' then p_value::text::integer
    when jsonb_typeof(p_value)='string' and (p_value#>>'{}')~'^\s*\d{1,3}\s*$'
      then btrim(p_value#>>'{}')::integer
  end
$$;

-- One read of the answer (jsonb_to_record): a stored match detail is tens of
-- kB and every field access would otherwise decompress it again.
create or replace function futbeat_private.goal_fixture_score(p_fixture jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
  r record; v_status text;
  v_lh integer; v_la integer; v_fh integer; v_fa integer;
  v_eh integer; v_ea integer; v_hh integer; v_ha integer;
  v_home integer; v_away integer;
begin
  if p_fixture is null or jsonb_typeof(p_fixture)<>'object' then return null; end if;
  select * into r from jsonb_to_record(p_fixture) as x(
    "matchStatus" jsonb,"homeTeamScore" jsonb,"awayTeamScore" jsonb,
    "homeTeamFtScore" jsonb,"awayTeamFtScore" jsonb,
    "homeTeamExtraScore" jsonb,"awayTeamExtraScore" jsonb,
    "homeTeamHalftimeScore" jsonb,"awayTeamHalftimeScore" jsonb);
  v_status:=upper(btrim(coalesce(case when jsonb_typeof(r."matchStatus")='string'
    then r."matchStatus"#>>'{}' end,'')));
  v_lh:=futbeat_private.goal_score_value(r."homeTeamScore");
  v_la:=futbeat_private.goal_score_value(r."awayTeamScore");
  if v_lh is null or v_la is null then v_lh:=null; v_la:=null; end if;
  -- Not over: the running total (extra time included, penalties never).
  if v_status not in ('FINISHED','AFTER_ET','AFTER_PEN','AWARDED') then
    return case when v_lh is not null then jsonb_build_object('home',v_lh,'away',v_la) end;
  end if;
  v_home:=v_lh; v_away:=v_la;
  v_fh:=futbeat_private.goal_score_value(r."homeTeamFtScore");
  v_fa:=futbeat_private.goal_score_value(r."awayTeamFtScore");
  if v_fh is not null and v_fa is not null then
    v_eh:=futbeat_private.goal_score_value(r."homeTeamExtraScore");
    v_ea:=futbeat_private.goal_score_value(r."awayTeamExtraScore");
    if v_eh is null or v_ea is null then
      -- After extra time the extra-time goals are required: unknown.
      if v_status in ('AFTER_ET','AFTER_PEN') then return null; end if;
      v_eh:=0; v_ea:=0;
    end if;
    -- The running total must agree, be absent, or be the 0-0 reset.
    if v_lh is not null and not (v_lh=0 and v_la=0)
       and (v_lh<>v_fh+v_eh or v_la<>v_fa+v_ea) then
      return null;
    end if;
    v_home:=v_fh+v_eh; v_away:=v_fa+v_ea;
  end if;
  if v_home is null then return null; end if;
  -- A final below the half-time score is impossible.
  v_hh:=futbeat_private.goal_score_value(r."homeTeamHalftimeScore");
  v_ha:=futbeat_private.goal_score_value(r."awayTeamHalftimeScore");
  if v_hh is not null and v_ha is not null and (v_home<v_hh or v_away<v_ha) then
    return null;
  end if;
  return jsonb_build_object('home',v_home,'away',v_away);
end $$;

-- The score a stored observation carries. GOAL answers are re-read from the
-- raw payload with goal_fixture_score; other providers keep their columns.
create or replace function futbeat_private.observation_score(
  p_provider text,p_home integer,p_away integer,p_raw jsonb
) returns jsonb language sql immutable set search_path='' as $$
  select case
    when p_provider='goal_api' and jsonb_typeof(p_raw)='object' and p_raw ? 'matchStatus'
      then futbeat_private.goal_fixture_score(p_raw)
    when p_home is not null and p_away is not null
      then jsonb_build_object('home',p_home,'away',p_away)
  end
$$;

-- ---------------------------------------------------------------------------
-- Terminal score correction (from 20260930120000): the observation's score
-- is observation_score(); an observation without one never applies.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.apply_terminal_score_correction()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_payload jsonb; v_canonical_at timestamptz; v_kickoff timestamptz; v_score jsonb;
begin
  if new.canonical_match_id is null
     or new.status not in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
    return new;
  end if;
  -- Only the primary provider is authoritative for a stored final. A
  -- secondary or integration-only source never rewrites it here (its
  -- reconciled finals go through futbeat_record_secondary_observation).
  if new.provider is distinct from futbeat_private.primary_result_provider() then
    return new;
  end if;
  -- The result this observation really carries (provider semantics, not
  -- the stored columns): a reset running total or an incoherent answer
  -- carries none and never touches a stored final.
  v_score:=futbeat_private.observation_score(new.provider,new.home_score,new.away_score,new.raw_payload);
  if v_score is null then
    return new;
  end if;
  -- Plain read (no row lock): almost every terminal observation confirms
  -- the stored final, and the results reconciliation locks match rows in
  -- its own order.
  select payload into v_payload from futbeat_private.entities
   where id=new.canonical_match_id and kind='match';
  if v_payload is null
     or coalesce(v_payload->>'status','') not in ('FINISHED_PENDING_VERIFICATION','VERIFIED') then
    return new;
  end if;
  if v_payload->'score' is not distinct from v_score
     and (v_payload->>'status'='VERIFIED' or new.status<>'VERIFIED') then
    return new;
  end if;
  -- Evidence of this fixture only: never before its kickoff.
  v_kickoff:=futbeat_private.try_timestamptz(v_payload->>'startTime');
  if v_kickoff is null or coalesce(new.provider_observed_at,new.received_at)<v_kickoff then
    return new;
  end if;
  -- Never let an older observation rewrite newer canonical evidence. Both
  -- sides are FutBeat receive times (the provider clock is only used against
  -- the kickoff above).
  v_canonical_at:=futbeat_private.try_timestamptz(v_payload#>>'{provenance,receivedAt}');
  if v_canonical_at is not null and new.received_at<v_canonical_at then
    return new;
  end if;
  -- ...nor an observation older than a newer terminal one already stored.
  if exists(
    select 1 from futbeat_private.provider_observations o
    where o.provider=new.provider and o.canonical_match_id=new.canonical_match_id
      and o.status in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and futbeat_private.observation_score(o.provider,o.home_score,o.away_score,o.raw_payload) is not null
      and (o.received_at,o.id)>(new.received_at,new.id)) then
    return new;
  end if;
  -- One guarded UPDATE. Its WHERE is re-evaluated by PostgreSQL on the row
  -- version actually written (READ COMMITTED re-check after a concurrent
  -- writer commits), so the guards hold against whatever committed last:
  --   * still terminal;
  --   * the canonical evidence on that row is not newer than this
  --     observation (monotonic: a newer concurrent correction is never
  --     overwritten by an older one; an older one is overwritten by this);
  --   * something still changes (no write, no lock, when it is a no-op).
  -- Observations of one provider fixture are already serialized by the
  -- per-fixture advisory lock of futbeat_record_live_batch.
  update futbeat_private.entities e set payload=e.payload
    ||jsonb_build_object(
      'status',case when e.payload->>'status'='VERIFIED' or new.status='VERIFIED'
        then 'VERIFIED' else 'FINISHED_PENDING_VERIFICATION' end,
      'score',v_score)
    ||jsonb_build_object('provenance',coalesce(e.payload->'provenance','{}'::jsonb)
      ||jsonb_build_object('receivedAt',new.received_at,'reconciledLocally',true,'scoreCorrected',true)
      -- Audit: the final that was replaced (only when the score changes).
      ||case when e.payload->'score' is distinct from v_score
          and e.payload->'score' is not null and e.payload->'score'<>'null'::jsonb
        then jsonb_build_object('scoreCorrectedFrom',e.payload->'score') else '{}'::jsonb end)
   where e.id=new.canonical_match_id and e.kind='match'
     and e.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
     and coalesce(futbeat_private.try_timestamptz(e.payload#>>'{provenance,receivedAt}'),
       '-infinity'::timestamptz)<=new.received_at
     and (e.payload->'score' is distinct from v_score
       or (new.status='VERIFIED' and e.payload->>'status'<>'VERIFIED'));
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Results reconciliation (from 20260922230000): the observation scores are
-- observation_score(); a NULL score keeps the stored one.
-- ---------------------------------------------------------------------------
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
      futbeat_private.observation_score(o.provider,o.home_score,o.away_score,o.raw_payload) score,
      t.status t_status,t.minute t_minute,
      futbeat_private.observation_score(t.provider,t.home_score,t.away_score,t.raw_payload) t_score,
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

-- ---------------------------------------------------------------------------
-- Read model (from 20260930100000): the observation and match-detail score
-- candidates use the same semantics.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.match_read_model_core(p_match jsonb,p_events boolean)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 v_score jsonb; v_status text:=p_match->>'status'; v_events jsonb; v_has_events boolean;
 v_start timestamptz:=(p_match->>'startTime')::timestamptz;
 v_received timestamptz:=coalesce(nullif(p_match#>>'{provenance,receivedAt}','')::timestamptz,'-infinity');
 v_evidence record;
 v_relax_terminal boolean;
 v_mismatch boolean:=false;
begin
 if futbeat_private.safe_result_integer(p_match#>>'{score,home}') is null
   or futbeat_private.safe_result_integer(p_match#>>'{score,away}') is null then
   p_match:=p_match-'score';
 end if;
 -- Expire stale LIVE presentation, but retain its real score independently.
 if v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
   and v_received<now()-interval '15 minutes' then v_status:='SCHEDULED'; end if;
 v_relax_terminal:=v_status in ('DISCOVERED','SCHEDULED','PRE_MATCH');
 -- Terminal canonical scores are authoritative. Otherwise choose the newest
 -- complete score field, not the newest status-only observation.
 if v_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION') then
   v_score:=nullif(p_match->'score','null'::jsonb);
 end if;
 if v_score is null then
   select score into v_score from (
     select nullif(p_match->'score','null'::jsonb) score,v_received seen,0 priority
     union all
     -- Newest first; the score rule only runs until the first observation
     -- that carries one (usually the newest), never over the whole trail
     -- (OFFSET 0 keeps the ordered scan below the rule and computes it
     -- once per row).
     (select o.score,o.received_at,1
       from (select futbeat_private.observation_score(x.provider,x.home_score,x.away_score,x.raw_payload) score,
           x.received_at
         from (select provider,home_score,away_score,raw_payload,received_at,id
           from futbeat_private.provider_observations
           where canonical_match_id=p_match->>'id'
             and received_at>=v_start
             and status not in ('POSTPONED','CANCELLED')
             and (provider='goal_api' or (home_score is not null and away_score is not null))
           order by received_at desc,id desc offset 0) x offset 0) o
       where o.score is not null limit 1)
     union all
     select jsonb_build_object('home',l.home_score,'away',l.away_score),l.last_seen_at,2
       from futbeat_private.live_match_state l where l.canonical_match_id=p_match->>'id'
         and l.home_score is not null and l.away_score is not null and l.last_seen_at>=v_start
         and l.status not in ('POSTPONED','CANCELLED')
     union all
     select d.score,d.fetched_at,3
       from (select futbeat_private.goal_fixture_score(c.payload) score,c.fetched_at
         from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
           and c.fetched_at>=v_start and now()>=v_start offset 0) d
   ) candidates where score is not null order by seen desc,priority limit 1;
 end if;
 -- Never infer FINISHED from the clock, goals or the presence of a score.
 if v_status not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED','POSTPONED') then
   select status,received_at,minute into v_evidence from (
     select status,received_at,minute,id from futbeat_private.provider_observations
       where canonical_match_id=p_match->>'id'
     union all
     select status,last_seen_at,minute,0 from futbeat_private.live_match_state
       where canonical_match_id=p_match->>'id'
     union all
     select case upper(c.payload->>'matchStatus')
       when 'FINISHED' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_ET' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_PEN' then 'FINISHED_PENDING_VERIFICATION'
       when 'AWARDED' then 'FINISHED_PENDING_VERIFICATION'
       when 'HALF_TIME' then 'HALFTIME'
       when 'LIVE' then case upper(c.payload->>'matchPeriod')
         when 'EXTRA_TIME' then 'EXTRA_TIME' when 'PENALTIES' then 'PENALTIES'
         when 'HALF_TIME' then 'HALFTIME' else 'LIVE' end
       else upper(c.payload->>'matchStatus') end,
       c.fetched_at,futbeat_private.safe_result_integer(coalesce(c.payload->>'matchElapsed',c.payload->>'matchMinute')),0
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
     union all
     -- Real final whistle recorded from a provider terminal state.
     select 'FINISHED_PENDING_VERIFICATION',e.first_seen_at,
       futbeat_private.safe_result_integer(e.payload->>'minute'),0
       from futbeat_private.canonical_events e
       where e.match_id=p_match->>'id' and e.event_type='FULL_TIME'
   ) evidence
    where received_at>=v_start
      and (received_at>=v_received
        or (v_relax_terminal and status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED','SUSPENDED')))
      and (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED','SUSPENDED')
        or status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES'))
    -- Finals first; otherwise the newest provider state wins, and a LIVE one
    -- only while fresh (an older stop never outlives a later, silent LIVE).
    order by (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')) desc,received_at desc,id desc limit 1;
   if found and not (v_evidence.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
       and v_evidence.received_at<now()-interval '15 minutes') then
     v_status:=v_evidence.status;
     p_match:=p_match||jsonb_strip_nulls(jsonb_build_object('minute',v_evidence.minute,
       'liveChangedAt',v_evidence.received_at));
   end if;
 end if;
 if p_events or v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then
   select futbeat_private.normalize_event_array(coalesce(jsonb_agg(event order by
     futbeat_private.safe_result_integer(event->>'minute'),event->>'id'),'[]'::jsonb))
   into v_events from (
     select distinct on (coalesce(event->>'id',event::text)) event from (
       -- P0-A: a payload copy never re-injects an id canonical_events owns
       -- (retracted or corrected there).
       select value event from jsonb_array_elements(coalesce(p_match->'events','[]'::jsonb))
         where not exists(select 1 from futbeat_private.canonical_events x where x.id=value->>'id')
       union all select payload||jsonb_build_object('id',id,'type',event_type)
         from futbeat_private.canonical_events where match_id=p_match->>'id' and retracted_at is null
     ) all_events order by coalesce(event->>'id',event::text)
   ) unique_events;
   -- #121: one visible occurrence per logical football event; P0-A: the
   -- score decides synthetic goals.
   v_events:=futbeat_private.visible_match_events(v_events,p_match->>'homeTeamId',p_match->>'awayTeamId',v_score);
   v_mismatch:=futbeat_private.event_score_mismatch(v_events,p_match->>'homeTeamId',p_match->>'awayTeamId',v_score);
   v_has_events:=jsonb_array_length(v_events)>0;
 else
   -- Same answer as a non-empty merged array, without building it.
   v_has_events:=coalesce(jsonb_array_length(case when jsonb_typeof(p_match->'events')='array'
       then p_match->'events' end),0)>0
     or exists(select 1 from futbeat_private.canonical_events where match_id=p_match->>'id' and retracted_at is null);
   p_match:=p_match-'events';
 end if;
 return p_match||jsonb_build_object('score',v_score,'status',v_status,
   'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'homeTeamId'),
   'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'awayTeamId'),
   'competitionId',futbeat_private.futbeat_resolve_entity_id('competition',p_match->>'competitionId'),
   'hasPlayedEvidence',now()>v_start+interval '15 minutes'
     and (v_score is not null or v_has_events
       or exists(select 1 from futbeat_private.match_detail_cache c
         where c.match_id=p_match->>'id' and c.fetched_at>=v_start
         and (jsonb_array_length(case when jsonb_typeof(c.payload->'events')='array'
           then c.payload->'events' else '[]'::jsonb end)>0
           or jsonb_array_length(case when jsonb_typeof(c.payload->'incidents')='array'
           then c.payload->'incidents' else '[]'::jsonb end)>0))))
   ||case when v_events is null then '{}'::jsonb else jsonb_build_object('events',v_events) end
   ||case when v_mismatch then jsonb_build_object('scoreMismatch',true) else '{}'::jsonb end;
end $$;

-- ---------------------------------------------------------------------------
-- Match detail cache (from 20260930100000): the score guard that keeps the
-- stored events when a shorter list would drop goals the score requires
-- uses the same result semantics (a reset 0-0 running total disabled it).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.store_match_detail_before_media(
  p_match_id text,
  p_external_match_id text,
  p_fetched_at timestamptz,
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_existing jsonb;
  v_merged jsonb;
  v_key text;
  v_old_count integer;
  v_new_count integer;
begin
  if p_fetched_at is null
     or p_payload is null
     or jsonb_typeof(p_payload)<>'object'
     or not exists(
       select 1 from futbeat_private.provider_entities
       where provider='goal_api' and kind='match'
         and external_id=p_external_match_id and canonical_id=p_match_id
     ) then
    raise exception 'Invalid match detail payload';
  end if;

  select payload into v_existing
  from futbeat_private.match_detail_cache
  where match_id=p_match_id;

  v_merged:=coalesce(v_existing,'{}'::jsonb)||p_payload;

  -- An endpoint response may temporarily omit previously published sections:
  -- keep them only then. A present array is the provider's current list.
  foreach v_key in array array['events','cards','substitutions'] loop
    if jsonb_typeof(p_payload->v_key) is distinct from 'array'
       and jsonb_typeof(v_existing->v_key)='array' then
      v_merged:=jsonb_set(v_merged,array[v_key],v_existing->v_key,true);
    end if;
  end loop;
  -- Score guard (review P1-2): a shorter events list never drops goals the
  -- stored score still requires (a genuine annulment lowers the score).
  -- Deliberately coarse: the whole stored events list is kept (other rows'
  -- corrections wait for the next answer that satisfies the score).
  if jsonb_typeof(p_payload->'events')='array' and jsonb_typeof(v_existing->'events')='array' then
    foreach v_key in array array['home','away'] loop
      v_new_count:=futbeat_private.detail_side_goals(p_payload->'events',v_key);
      v_old_count:=futbeat_private.detail_side_goals(v_existing->'events',v_key);
      if v_new_count<v_old_count
         and v_new_count<coalesce((coalesce(futbeat_private.goal_fixture_score(v_merged),
           futbeat_private.goal_fixture_score(v_existing))->>v_key)::integer,0) then
        v_merged:=jsonb_set(v_merged,'{events}',v_existing->'events',true);
        exit;
      end if;
    end loop;
  end if;

  -- Statistics in any shape (array rows, {match:{fullTime}}, team-keyed):
  -- keep the stored ones only when the newer response has none.
  if v_existing ? 'statistics'
     and futbeat_private.detail_statistics_count(p_payload->'statistics')=0
     and futbeat_private.detail_statistics_count(v_existing->'statistics')>0 then
    v_merged:=jsonb_set(v_merged,'{statistics}',v_existing->'statistics',true);
  end if;

  -- Lineups in both GOAL shapes: keep the stored lineup only when the newer
  -- response has no players at all.
  select count(*) into v_old_count from futbeat_private.lineup_rows(coalesce(v_existing,'{}'::jsonb));
  select count(*) into v_new_count from futbeat_private.lineup_rows(p_payload);
  if v_new_count=0 and v_old_count>0 then
    v_merged:=jsonb_set(v_merged,'{lineups}',v_existing->'lineups',true);
  end if;

  foreach v_key in array array[
    'kickoffUtc','matchDate','matchTime','matchStatus','matchPeriod',
    'matchStadium','matchReferee','homeTeamScore','awayTeamScore',
    'homeTeamSystem','awayTeamSystem'
  ] loop
    if nullif(btrim(coalesce(p_payload->>v_key,'')),'') is null
       and nullif(btrim(coalesce(v_existing->>v_key,'')),'') is not null then
      v_merged:=jsonb_set(v_merged,array[v_key],v_existing->v_key,true);
    end if;
  end loop;

  insert into futbeat_private.match_detail_cache(
    match_id,provider,external_match_id,fetched_at,payload
  ) values(p_match_id,'goal_api',p_external_match_id,p_fetched_at,v_merged)
  on conflict(match_id) do update
    set provider=excluded.provider,
        external_match_id=excluded.external_match_id,
        fetched_at=excluded.fetched_at,
        payload=excluded.payload
  where futbeat_private.match_detail_cache.fetched_at<=excluded.fetched_at;

  return futbeat_private.read_match_detail(p_match_id);
end
$$;

revoke all on function
  futbeat_private.goal_score_value(jsonb),
  futbeat_private.goal_fixture_score(jsonb),
  futbeat_private.observation_score(text,integer,integer,jsonb)
from public,anon,authenticated;

notify pgrst,'reload schema';
