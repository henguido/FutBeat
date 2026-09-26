-- #120: terminal recovery for matches that leave the LIVE feed (or stay LIVE
-- far too long) before FutBeat has recorded any terminal provider state.
--
-- Gap: live_match_state is fed only by what /fixtures/live returns. A match
-- that drops out of that feed before one FT observation was captured stays
-- frozen as LIVE in live_match_state; the read model hides it after 15 min but
-- nothing fetches its final state (results-date only covers dates < UTC today,
-- the detail planner only does a post-match fetch at kickoff+2h and the live
-- bucket is capped). Result: a real final never reaches the read model.
--
-- Fix (generic, provider-evidence only, never the clock):
--   * the central worker reports every COMPLETE live poll; LIVE-family matches
--     absent from it (or still LIVE long after kickoff) become a bounded
--     recovery row;
--   * a recovery row is served by one /fixtures/{id} detail call at a time
--     under the protected 'results' quota class, with exponential backoff and
--     a hard attempt cap;
--   * only a terminal status returned by the provider (recorded through the
--     normal live pipeline) resolves it; reappearing in the feed cancels it;
--     partial/truncated polls never count as absence.
-- Mobile never calls the provider; this runs only in futbeat-goal-live-sync.

create table if not exists futbeat_private.live_terminal_recovery (
  provider text not null,
  external_match_id text not null,
  canonical_match_id text references futbeat_private.entities(id) on delete cascade,
  reason text not null check (reason in ('absent_from_live','overdue_live')),
  state text not null default 'PENDING'
    check (state in ('PENDING','RESOLVED','EXHAUSTED','CANCELLED')),
  last_live_status text,
  detected_at timestamptz not null,
  attempts integer not null default 0 check (attempts>=0),
  next_attempt_at timestamptz not null,
  last_attempt_at timestamptz,
  last_provider_status text,
  resolved_at timestamptz,
  resolution text,
  -- Set when an exhausted overdue_live reopened as absent_from_live: that
  -- reset happens once per fixture lifecycle, never again.
  absence_reopened_at timestamptz,
  primary key (provider,external_match_id)
);
create index if not exists live_terminal_recovery_due_idx
  on futbeat_private.live_terminal_recovery(next_attempt_at) where state='PENDING';
alter table futbeat_private.live_terminal_recovery enable row level security;
revoke all on futbeat_private.live_terminal_recovery from public,anon,authenticated;

create or replace function futbeat_private.recovery_backoff(p_attempts integer)
returns interval language sql immutable set search_path='' as $$
  select least(interval '30 minutes',interval '2 minutes'*power(2,greatest(p_attempts-1,0)))
$$;

-- A paginated feed may take several polls (truncated at the page budget, the
-- next poll resumes at its offset). One sweep = from offset 0 to the last
-- page, possibly across polls; absence is evaluated only on a finished sweep.
create table if not exists futbeat_private.live_poll_sweep (
  provider text primary key,
  started_at timestamptz not null,
  seen text[] not null
);
alter table futbeat_private.live_poll_sweep enable row level security;
revoke all on futbeat_private.live_poll_sweep from public,anon,authenticated;

-- Called by the worker after each persisted live poll: p_from_start when the
-- poll read from offset 0, p_reached_end when it read the last page.
create or replace function futbeat_private.note_live_poll(
  p_provider text,p_seen jsonb,p_from_start boolean,p_reached_end boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_seen text[]; v_all text[]; v_complete boolean:=false;
  v_window interval:=make_interval(hours=>futbeat_private.quota_setting('goal_api','terminalRecoveryWindowHours',6)::integer);
  v_overdue interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','overdueLiveMinutes',150)::integer);
  v_first interval:=make_interval(secs=>futbeat_private.quota_setting('goal_api','terminalRecoveryFirstDelaySeconds',60)::integer);
  v_sweep_max interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','liveSweepMaxMinutes',20)::integer);
  v_absent integer:=0; v_overdue_n integer:=0; v_back integer:=0;
begin
  if p_provider is null or btrim(p_provider)='' then raise exception 'provider is required'; end if;
  if p_seen is null or jsonb_typeof(p_seen)<>'array' then raise exception 'seen must be an array'; end if;
  select coalesce(array_agg(distinct value),array[]::text[]) into v_seen
  from jsonb_array_elements_text(p_seen) where btrim(value)<>'';

  -- Back in the feed: an absence was temporary, never a final.
  update futbeat_private.live_terminal_recovery r
  set state='CANCELLED',resolved_at=now(),resolution='reappeared'
  where r.provider=p_provider and r.state='PENDING' and r.reason='absent_from_live'
    and r.external_match_id=any(v_seen);
  get diagnostics v_back=row_count;

  -- Sweep bookkeeping: a resumed poll only extends a recent sweep.
  if coalesce(p_from_start,false) then
    insert into futbeat_private.live_poll_sweep as w(provider,started_at,seen) values(p_provider,now(),v_seen)
    on conflict(provider) do update set started_at=now(),seen=excluded.seen;
  else
    update futbeat_private.live_poll_sweep w
    set seen=array(select distinct x from unnest(w.seen||v_seen) x)
    where w.provider=p_provider and w.started_at>now()-v_sweep_max;
  end if;
  if coalesce(p_reached_end,false) then
    select w.seen into v_all from futbeat_private.live_poll_sweep w
    where w.provider=p_provider and w.started_at>now()-v_sweep_max;
    v_complete:=v_all is not null;
    -- Finished (or stale partial) sweep: the next poll starts over.
    delete from futbeat_private.live_poll_sweep w where w.provider=p_provider;
  end if;

  -- Absence is evidence only when a whole sweep was read.
  if v_complete then
    with gone as (
      select s.external_match_id,s.canonical_match_id,s.status
      from futbeat_private.live_match_state s
      where s.provider=p_provider
        and s.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        and s.last_seen_at>now()-v_window
        and not (s.external_match_id=any(v_all))
        -- Unmapped fixtures have no read model to repair.
        and s.canonical_match_id is not null
        -- Rows already tracked are left alone (and cost nothing), except an
        -- exhausted overdue_live: disappearing from a whole sweep is new,
        -- stronger evidence than "still LIVE too long" (see below).
        and not exists(select 1 from futbeat_private.live_terminal_recovery t
          where t.provider=s.provider and t.external_match_id=s.external_match_id
            and t.state<>'CANCELLED'
            and not (t.state='EXHAUSTED' and t.reason='overdue_live' and t.absence_reopened_at is null))
        and not futbeat_private.match_effectively_terminal(s.canonical_match_id)
    ), upserted as (
      insert into futbeat_private.live_terminal_recovery as r(
        provider,external_match_id,canonical_match_id,reason,last_live_status,detected_at,next_attempt_at)
      select p_provider,g.external_match_id,g.canonical_match_id,'absent_from_live',g.status,now(),now()+v_first
      from gone g
      on conflict(provider,external_match_id) do update set
        reason='absent_from_live',state='PENDING',canonical_match_id=excluded.canonical_match_id,
        last_live_status=excluded.last_live_status,detected_at=now(),resolved_at=null,resolution=null,
        -- Exhausted overdue_live -> absent_from_live: a new evidence level with
        -- its own bounded budget (at most once: the row is now absent_from_live
        -- and an exhausted absence never reopens). A reappeared absence
        -- (CANCELLED) never resets the attempt budget nor the backoff.
        attempts=case when r.state='EXHAUSTED' then 0 else r.attempts end,
        last_attempt_at=case when r.state='EXHAUSTED' then null else r.last_attempt_at end,
        next_attempt_at=case when r.state='EXHAUSTED' then excluded.next_attempt_at
          else greatest(r.next_attempt_at,excluded.next_attempt_at) end,
        absence_reopened_at=case when r.state='EXHAUSTED' then now() else r.absence_reopened_at end
      where r.state='CANCELLED'
        or (r.state='EXHAUSTED' and r.reason='overdue_live' and r.absence_reopened_at is null)
      returning 1
    )
    select count(*) into v_absent from upserted;
  end if;

  -- Still in the feed as LIVE long after kickoff: ask the provider directly.
  with overdue as (
    select s.external_match_id,s.canonical_match_id,s.status
    from futbeat_private.live_match_state s
    join futbeat_private.entities e on e.id=s.canonical_match_id and e.kind='match'
    where s.provider=p_provider and s.external_match_id=any(v_seen)
      and s.status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
      and nullif(e.payload->>'startTime','')::timestamptz<now()-v_overdue
      and not exists(select 1 from futbeat_private.live_terminal_recovery t
        where t.provider=s.provider and t.external_match_id=s.external_match_id and t.state<>'CANCELLED')
      and not futbeat_private.match_effectively_terminal(s.canonical_match_id)
  ), upserted as (
    insert into futbeat_private.live_terminal_recovery as r(
      provider,external_match_id,canonical_match_id,reason,last_live_status,detected_at,next_attempt_at)
    select p_provider,o.external_match_id,o.canonical_match_id,'overdue_live',o.status,now(),now()
    from overdue o
    on conflict(provider,external_match_id) do update set
      reason='overdue_live',state='PENDING',canonical_match_id=excluded.canonical_match_id,
      last_live_status=excluded.last_live_status,detected_at=now(),resolved_at=null,resolution=null,
      next_attempt_at=greatest(r.next_attempt_at,now())
    where r.state='CANCELLED'
    returning 1
  )
  select count(*) into v_overdue_n from upserted;

  return jsonb_build_object('complete',v_complete,'absent',v_absent,
    'overdue',v_overdue_n,'reappeared',v_back);
end $$;

-- Settles rows that no longer need a call (any path produced terminal
-- evidence, or the attempt budget is spent).
create or replace function futbeat_private.settle_terminal_recovery()
returns void language plpgsql security definer set search_path='' as $$
declare v_max integer:=futbeat_private.quota_setting('goal_api','terminalRecoveryMaxAttempts',6)::integer;
begin
  update futbeat_private.live_terminal_recovery r
  set state='RESOLVED',resolved_at=now(),resolution='terminal_evidence'
  where r.state='PENDING' and r.canonical_match_id is not null
    and futbeat_private.match_effectively_terminal(r.canonical_match_id);
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='max_attempts'
  where r.state='PENDING' and r.attempts>=v_max;
  -- A row that can no longer be served (mapping relinked or removed) expires.
  update futbeat_private.live_terminal_recovery r
  set state='EXHAUSTED',resolved_at=now(),resolution='expired'
  where r.state='PENDING' and r.detected_at<now()-make_interval(
    hours=>futbeat_private.quota_setting('goal_api','terminalRecoveryWindowHours',6)::integer);
  delete from futbeat_private.live_terminal_recovery
  where state<>'PENDING' and coalesce(resolved_at,detected_at)<now()-interval '3 days';
end $$;

-- One recovery detail call, under the central quota manager ('results'
-- class, match-detail kind cap) and the per-match inflight lock.
create or replace function futbeat_private.reserve_terminal_recovery_call(p_trigger_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r futbeat_private.live_terminal_recovery; v_decision jsonb; v_reservation bigint;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;
  perform futbeat_private.lock_provider_quota('goal_api');
  perform futbeat_private.settle_terminal_recovery();
  select t.* into r from futbeat_private.live_terminal_recovery t
  join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='match'
    and pe.external_id=t.external_match_id and pe.canonical_id=t.canonical_match_id
  where t.provider='goal_api' and t.state='PENDING' and t.next_attempt_at<=now()
    and not futbeat_private.detail_inflight(t.canonical_match_id)
  order by t.next_attempt_at,t.external_match_id
  limit 1 for update of t skip locked;
  if not found then return jsonb_build_object('allowed',false,'reason','no_recovery_due'); end if;

  v_decision:=futbeat_private.quota_decision('goal_api','match-detail','results');
  if not (v_decision->>'allowed')::boolean then
    return v_decision||jsonb_build_object('allowed',false,'matchId',r.canonical_match_id);
  end if;
  perform pg_advisory_xact_lock(hashtext('futbeat-match-detail-inflight'),hashtext(r.canonical_match_id));
  if futbeat_private.detail_inflight(r.canonical_match_id) then
    return jsonb_build_object('allowed',false,'reason','detail_inflight','matchId',r.canonical_match_id);
  end if;

  insert into futbeat_private.provider_call_ledger(provider,call_kind,trigger_source,reserved_at,metadata)
  values('goal_api','match-detail',left(p_trigger_source,40),now(),
    jsonb_build_object('matchId',r.canonical_match_id,'externalMatchId',r.external_match_id,
      'status',r.last_live_status,'quotaClass','results','bucket','recovery','source','recovery',
      'recoveryReason',r.reason,'attempt',r.attempts+1))
  returning id into v_reservation;
  update futbeat_private.live_terminal_recovery t
  set attempts=t.attempts+1,last_attempt_at=now(),
    next_attempt_at=now()+futbeat_private.recovery_backoff(t.attempts+1)
  where t.provider=r.provider and t.external_match_id=r.external_match_id;
  return jsonb_build_object('allowed',true,'reservationId',v_reservation,
    'matchId',r.canonical_match_id,'externalMatchId',r.external_match_id,
    'reason',r.reason,'attempt',r.attempts+1,'quotaClass','results','bucket','recovery');
end $$;

-- After the recovery fetch was stored and recorded: keep the provider's raw
-- status for diagnosis and settle the row if terminal evidence now exists.
create or replace function futbeat_private.complete_terminal_recovery(
  p_external_match_id text,p_provider_status text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r futbeat_private.live_terminal_recovery;
begin
  update futbeat_private.live_terminal_recovery t set last_provider_status=left(p_provider_status,40)
  where t.provider='goal_api' and t.external_match_id=p_external_match_id
  returning * into r;
  if not found then return jsonb_build_object('state',null); end if;
  perform futbeat_private.settle_terminal_recovery();
  -- A pre-match decision is the provider's answer too: stop spending calls;
  -- the results reconciliation owns postponed/cancelled (with provenance).
  update futbeat_private.live_terminal_recovery t
  set state='RESOLVED',resolved_at=now(),resolution='provider_'||lower(p_provider_status)
  where t.provider='goal_api' and t.external_match_id=p_external_match_id and t.state='PENDING'
    and upper(p_provider_status) in ('POSTPONED','CANCELLED');
  select * into r from futbeat_private.live_terminal_recovery t
  where t.provider='goal_api' and t.external_match_id=p_external_match_id;
  return jsonb_build_object('state',r.state,'resolution',r.resolution,'attempts',r.attempts);
end $$;

-- Service-only diagnostics (read-only).
create or replace function futbeat_private.terminal_recovery_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select jsonb_build_object(
    'pending',count(*) filter(where state='PENDING'),
    'resolved',count(*) filter(where state='RESOLVED'),
    'exhausted',count(*) filter(where state='EXHAUSTED'),
    'cancelled',count(*) filter(where state='CANCELLED'),
    'exhaustedRecent',coalesce(jsonb_agg(jsonb_build_object('externalMatchId',external_match_id,
      'matchId',canonical_match_id,'reason',reason,'lastProviderStatus',last_provider_status))
      filter(where state='EXHAUSTED' and resolved_at>now()-interval '1 day'),'[]'::jsonb))
  from futbeat_private.live_terminal_recovery
$$;

create or replace function public.futbeat_note_live_poll(
  p_provider text,p_seen jsonb,p_from_start boolean,p_reached_end boolean)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.note_live_poll(p_provider,p_seen,p_from_start,p_reached_end)
$$;
create or replace function public.futbeat_reserve_terminal_recovery_call(p_trigger_source text)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.reserve_terminal_recovery_call(p_trigger_source)
$$;
create or replace function public.futbeat_complete_terminal_recovery(p_external_match_id text,p_provider_status text)
returns jsonb language sql security definer set search_path='' as $$
  select futbeat_private.complete_terminal_recovery(p_external_match_id,p_provider_status)
$$;
create or replace function public.futbeat_terminal_recovery_status()
returns jsonb language sql stable security definer set search_path='' as $$
  select futbeat_private.terminal_recovery_status()
$$;

do $$ declare fn regprocedure; begin
  for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where (n.nspname='futbeat_private' and p.proname in ('recovery_backoff','note_live_poll',
      'settle_terminal_recovery','reserve_terminal_recovery_call','complete_terminal_recovery',
      'terminal_recovery_status'))
    or (n.nspname='public' and p.proname in ('futbeat_note_live_poll','futbeat_reserve_terminal_recovery_call',
      'futbeat_complete_terminal_recovery','futbeat_terminal_recovery_status'))
  loop
    execute format('revoke all on function %s from public,anon,authenticated',fn);
  end loop;
end $$;
grant execute on function public.futbeat_note_live_poll(text,jsonb,boolean,boolean) to service_role;
grant execute on function public.futbeat_reserve_terminal_recovery_call(text) to service_role;
grant execute on function public.futbeat_complete_terminal_recovery(text,text) to service_role;
grant execute on function public.futbeat_terminal_recovery_status() to service_role;

-- Read model: the newest in-play stop reported by the provider (ABANDONED,
-- SUSPENDED) is surfaced instead of being dropped, so a recovery fetch (or any
-- live/detail observation) that reports it replaces an older LIVE. Finals still
-- outrank everything; evidence older than the kickoff stays ignored.
-- POSTPONED/CANCELLED stay with the results reconciliation, which checks
-- reschedule provenance (an old postponement must not hide a new kickoff).
-- Copied from 20260926030000; only the evidence filter/selection changed.
create or replace function futbeat_private.match_read_model_core(p_match jsonb,p_events boolean)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 v_score jsonb; v_status text:=p_match->>'status'; v_events jsonb; v_has_events boolean;
 v_start timestamptz:=(p_match->>'startTime')::timestamptz;
 v_received timestamptz:=coalesce(nullif(p_match#>>'{provenance,receivedAt}','')::timestamptz,'-infinity');
 v_evidence record;
 v_relax_terminal boolean;
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
     select jsonb_build_object('home',o.home_score,'away',o.away_score),o.received_at,1
       from (select * from futbeat_private.provider_observations
         where canonical_match_id=p_match->>'id' and home_score is not null and away_score is not null
           and received_at>=v_start
           and status not in ('POSTPONED','CANCELLED')
         order by received_at desc,id desc limit 1) o
     union all
     select jsonb_build_object('home',l.home_score,'away',l.away_score),l.last_seen_at,2
       from futbeat_private.live_match_state l where l.canonical_match_id=p_match->>'id'
         and l.home_score is not null and l.away_score is not null and l.last_seen_at>=v_start
         and l.status not in ('POSTPONED','CANCELLED')
     union all
     select jsonb_build_object('home',(c.payload->>'homeTeamScore')::integer,
       'away',(c.payload->>'awayTeamScore')::integer),c.fetched_at,3
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
       and c.fetched_at>=v_start and now()>=v_start
       and coalesce(c.payload->>'homeTeamScore','')~'^\d+$'
       and coalesce(c.payload->>'awayTeamScore','')~'^\d+$'
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
       select value event from jsonb_array_elements(coalesce(p_match->'events','[]'::jsonb))
       union all select payload||jsonb_build_object('id',id,'type',event_type)
         from futbeat_private.canonical_events where match_id=p_match->>'id'
     ) all_events order by coalesce(event->>'id',event::text)
   ) unique_events;
   -- #121: one visible occurrence per logical football event.
   v_events:=futbeat_private.visible_match_events(v_events,p_match->>'homeTeamId',p_match->>'awayTeamId');
   v_has_events:=jsonb_array_length(v_events)>0;
 else
   -- Same answer as a non-empty merged array, without building it.
   v_has_events:=coalesce(jsonb_array_length(case when jsonb_typeof(p_match->'events')='array'
       then p_match->'events' end),0)>0
     or exists(select 1 from futbeat_private.canonical_events where match_id=p_match->>'id');
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
   ||case when v_events is null then '{}'::jsonb else jsonb_build_object('events',v_events) end;
end $$;

-- #120 recovery calls have their own attempt cap: they never consume the
-- planner's per-match post-match budget (copied from 20260924200000; only
-- the ledger phase mapping changed).
create or replace function futbeat_private.match_detail_planner_due(p_match_id text,p_bucket text)
returns boolean language plpgsql stable set search_path='' as $$
declare cov futbeat_private.match_detail_coverage; fetched timestamptz; kickoff timestamptz;
  sections jsonb; gap interval; final_after interval; phase text; used integer;
begin
  if p_bucket is null or p_bucket not in ('live','results','prematch','upcoming','recent_hot','recent','history') then
    return false;
  end if;
  select * into cov from futbeat_private.match_detail_coverage where match_id=p_match_id;
  if coalesce(cov.next_retry_at>now(),false) then return false; end if;
  select c.fetched_at into fetched from futbeat_private.match_detail_cache c where c.match_id=p_match_id;
  -- Hard bound on background work per match and phase (user opens are not
  -- counted): pre-match, LIVE and results attempts never eat the post-match
  -- fetch, and each phase has its own cap.
  phase:=case p_bucket when 'prematch' then 'prematch' when 'live' then 'live'
    when 'results' then 'results' else 'finished' end;
  select count(*) into used from futbeat_private.provider_call_ledger l
  where l.call_kind='match-detail' and l.metadata->>'matchId'=p_match_id
    and l.reserved_at>now()-interval '1 day' and coalesce(l.metadata->>'source','')<>'user'
    and case coalesce(l.metadata->>'bucket','') when 'prematch' then 'prematch' when 'live' then 'live'
      when 'results' then 'results' when 'recovery' then 'recovery' else 'finished' end=phase;
  if used>=(case phase
      when 'prematch' then futbeat_private.quota_setting('goal_api','plannerMaxPrematchFetches',3)
      when 'live' then futbeat_private.quota_setting('goal_api','plannerMaxLiveFetches',6)
      when 'results' then futbeat_private.quota_setting('goal_api','plannerMaxResultFetches',2)
      else futbeat_private.quota_setting('goal_api','plannerMaxFetchesPerMatchDay',4) end) then
    return false;
  end if;
  if fetched is null then return true; end if;
  if p_bucket='results' then
    return futbeat_private.match_detail_due('FINISHED_PENDING_VERIFICATION',fetched);
  end if;
  if p_bucket='upcoming' then return false; end if;
  if p_bucket='live' then
    return coalesce((coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
        and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','liveRetryMinutes',5)::integer))
      -- Periodic refresh only while the provider budget is comfortable.
      or (fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','plannerLiveRefreshMinutes',30)::integer)
        and futbeat_private.detail_planner_band()->>'band' in ('abundant','normal')),false);
  end if;
  sections:=futbeat_private.match_detail_sections(p_match_id);
  if sections is null then return false; end if;
  gap:=make_interval(secs=>(sections->>'retryGap')::double precision);
  if p_bucket='prematch' then
    return coalesce((sections->>'lineupWanted')::boolean and coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN'
      and fetched<now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','prematchRetryMinutes',20)::integer),false);
  end if;
  -- Finished: one post-match fetch, then only missing sections / due rechecks.
  select nullif(e.payload->>'startTime','')::timestamptz into kickoff
  from futbeat_private.entities e where e.id=p_match_id and e.kind='match';
  final_after:=make_interval(mins=>futbeat_private.quota_setting('goal_api','finalFetchAfterMinutes',120)::integer);
  if kickoff is not null and now()>=kickoff+final_after and fetched<kickoff+final_after then
    return true;
  end if;
  return coalesce(fetched<now()-gap and (
    coalesce(cov.lineup_state,'UNKNOWN')='UNKNOWN' or coalesce(cov.statistics_state,'UNKNOWN')='UNKNOWN'
    -- A NO_DATA without a recheck time (older rows) is never rechecked.
    or (cov.lineup_state='NO_DATA' and coalesce(cov.lineup_recheck_at,'infinity')<=now())
    or (cov.statistics_state='NO_DATA' and coalesce(cov.statistics_recheck_at,'infinity')<=now())),false);
end $$;
