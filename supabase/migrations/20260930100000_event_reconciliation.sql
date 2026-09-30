-- P0-A: match events / goals reconciliation (corrections, annulments, own
-- goals, re-issued ids). Local only: no provider calls, no cron, no ledger.
--
-- Root causes (append-only pipeline):
--   * live_events were insert-only (on conflict do nothing): a corrected
--     scorer / minute / team with the same provider id never reached the
--     canonical timeline, and a row the provider stopped sending (VAR
--     annulment, deleted card / substitution) stayed forever.
--   * canonical ids were derived from the event content, so a correction of a
--     row without a provider id became a second event, and store_canonical_event
--     never rewrote an existing row (stale values won).
--   * synthetic score-change goals were only folded within 3 minutes and only
--     created/checked on score increases: a late first sighting or a score
--     drop left permanent extra goals.
--   * match detail kept the LONGER events/cards/substitutions array, so an
--     annulled goal survived a later, shorter answer.
--   * the read model re-injected raw event copies stored in the match payload
--     (results lifecycle) next to canonical_events.
--
-- Rules (generic; never by team, fixture, player, date or competition):
--   * Snapshot-replace per source: an observation carrying completeSections
--     (event sections the provider answered as an ARRAY, possibly empty) is
--     the complete set of that section for (provider, external match). Rows
--     it no longer lists are soft-retracted (retracted_at); a row that comes
--     back is restored. An absent / null section never retracts. Observations
--     without completeSections (older workers, other providers, the results
--     list) only add and correct.
--   * live_events content is upserted (latest observation wins).
--   * Canonical identity is the upstream key: the canonical row already
--     carrying (match, provider, providerEventKey) is reused and its payload
--     is updated in place; new rows keep the historical content-based id
--     formula (so existing ids and pushes stay valid). When another key
--     already owns that id the new key branches to an id of its own (two
--     upstream keys are two rows; a copy of a still-listed row is marked
--     duplicateOf: shown once, never pushed again). Fallback
--     keys (no provider id) change with the content: a correction there is
--     retract old + add new.
--   * Every rewrite / retraction / restoration is audited in
--     canonical_event_revisions (canonical rows are never deleted).
--   * Projection: retracted rows are excluded everywhere (read model,
--     realtime, push guard); two rows of the same provider key keep the
--     latest observation. Payload event copies are only used for ids that
--     canonical_events does not own.
--   * Score is authoritative for synthetic goals: per team, a synthetic goal
--     with ordinal n (its team score after the goal) is folded into the rich
--     goal of rank n (no minute limit), hidden when n exceeds the current
--     score, and at most one is shown per ordinal. Rich goals are never hidden
--     by the score; when they exceed it the read model flags scoreMismatch.
--   * Pushes: an update / restoration never notifies. A new row that replaces
--     a row retracted by the same observation (same type and team, or the
--     same player) is a correction and never notifies again.
--   * Match detail: a present array (even shorter or empty) replaces the
--     stored events / cards / substitutions; only an absent / non-array key
--     keeps the stored one.
--
--   * Per-path authority (review P1-2, re-review): each live_events row
--     remembers the path of its last sighting (observation 'source':
--     live-list | detail | results). A DETAIL answer is authoritative over
--     every path; a LIST answer (or one without a source) only retracts rows
--     last seen on the list or with no recorded path (legacy); the results
--     list never retracts. GOALs follow the score: path retraction never
--     leaves a team with fewer active goals than its current score, and when
--     a team's active goals exceed its score any answer retracts that team's
--     unlisted goals (newest first) down to the score. The detail cache
--     applies a (coarser) score guard.
--   * Score decrease (review P1-1): active synthetic goals above the new team
--     score are retracted (reason score_decrease), so a stale provisional goal
--     never absorbs (or silences) the next real goal.
--   * Pending pushes of a retracted event are cancelled at claim time, except
--     when the row was replaced by a correction (that push stands for it).
--
-- Deploy notes:
--   * Own goals without a provider id: the fallback key includes the credited
--     team, so an own-goal reclassification of an anonymous row is retract +
--     add (one push, via the correction twin); with a provider id it is an
--     in-place update.
--   * The new index is created non-concurrently and the legacy repair scans
--     canonical_events once: apply outside a live-match window.
--
-- UNVERIFIED provider shapes (no captured GOAL sample): whether events[].id
-- always exists and is stable across corrections, how VAR and own goals are
-- encoded, whether an empty events array means "none". The design is correct
-- for id-present and id-absent rows and never retracts on an absent section.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
alter table futbeat_private.live_events
  add column if not exists source text,
  add column if not exists retracted_at timestamptz,
  add column if not exists updated_at timestamptz,
  add column if not exists revision integer not null default 1;

alter table futbeat_private.canonical_events
  add column if not exists retracted_at timestamptz,
  add column if not exists retraction_reason text,
  add column if not exists updated_at timestamptz,
  add column if not exists revision integer not null default 1;

create index if not exists canonical_events_upstream_key_idx
  on futbeat_private.canonical_events(match_id,provider,(payload->>'providerEventKey'));

create table if not exists futbeat_private.canonical_event_revisions(
  id bigint generated always as identity primary key,
  event_id text not null references futbeat_private.canonical_events(id) on delete cascade,
  match_id text not null,
  revised_at timestamptz not null,
  action text not null check(action in ('update','retract','restore')),
  reason text,
  previous_payload jsonb,
  payload jsonb
);
create index if not exists canonical_event_revisions_event_idx
  on futbeat_private.canonical_event_revisions(event_id,revised_at);
alter table futbeat_private.canonical_event_revisions enable row level security;
revoke all on futbeat_private.canonical_event_revisions from public,anon,authenticated;

-- Section of the provider answer an event type comes from.
create or replace function futbeat_private.live_event_section(p_type text)
returns text language sql immutable set search_path='' as $$
  select case
    when p_type in ('GOAL','VAR','MISSED_PENALTY','OTHER') then 'events'
    when p_type in ('YELLOW_CARD','RED_CARD') then 'cards'
    when p_type='SUBSTITUTION' then 'substitutions'
  end
$$;

-- The normalized content of a LIVE event (never the raw provider row, whose
-- volatile fields or list-vs-detail shape must not count as a correction).
create or replace function futbeat_private.live_event_content(evt jsonb)
returns jsonb language sql immutable set search_path='' as $$
  select jsonb_build_object(
    'type',coalesce(nullif(evt->>'type',''),'OTHER'),
    'minute',futbeat_private.safe_result_integer(evt->>'minute'),
    'extraMinute',futbeat_private.safe_result_integer(evt->>'extraMinute'),
    'teamExternalId',nullif(evt->>'teamExternalId',''),
    'playerExternalId',nullif(evt->>'playerExternalId',''),
    'assistExternalId',nullif(evt->>'assistExternalId',''),
    'scoreAfter',case when jsonb_typeof(evt->'scoreAfter')='object' then evt->'scoreAfter' end,
    'ownGoal',coalesce(evt->>'ownGoal','')='true')
$$;

-- ---------------------------------------------------------------------------
-- Change detection core (copied from 20260916060404, renamed in
-- 20260916161141). Changed: live_events content is upserted, rows absent from
-- a complete section are retracted / restored, corrections count as a state
-- change (revision + realtime), event_count counts active rows.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.record_live_batch_core(
  p_provider text,
  p_received_at timestamptz,
  p_observations jsonb
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  obs jsonb;
  evt jsonb;
  v_external_match_id text;
  v_canonical_match_id text;
  v_payload_hash text;
  v_status text;
  v_minute integer;
  v_home_score integer;
  v_away_score integer;
  v_events jsonb;
  v_provider_observed_at timestamptz;
  v_observation_id bigint;
  v_initial boolean;
  v_score_changed boolean;
  v_status_changed boolean;
  v_minute_changed boolean;
  v_any_changed boolean;
  v_new_events integer;
  v_inserted integer;
  v_revision bigint;
  v_existing futbeat_private.live_match_state%rowtype;
  v_changes jsonb := '[]'::jsonb;
  v_inserted_observations integer := 0;
  v_duplicates integer := 0;
  v_prev futbeat_private.live_events%rowtype;
  v_keys text[];
  v_sections text[];
  v_corrected integer;
  v_retracted integer;
  v_active integer;
  v_source text;
  v_side text;
  v_team_ext text;
  v_team_score integer;
  v_goal_active integer;
  v_goal_candidates integer;
  v_protected text[];
  v_guard_all boolean;
  v_detail boolean;
  v_unlisted text[];
  v_unlisted_path text[];
  v_rest text[];
  v_goal_keys text[];
  v_take integer;
begin
  if p_provider is null or btrim(p_provider) = '' then raise exception 'provider is required'; end if;
  if p_received_at is null then raise exception 'received_at is required'; end if;
  if p_observations is null or jsonb_typeof(p_observations) <> 'array' then raise exception 'observations must be an array'; end if;

  for obs in select value from jsonb_array_elements(p_observations)
  loop
    v_external_match_id := nullif(obs ->> 'externalMatchId', '');
    v_payload_hash := nullif(obs ->> 'payloadHash', '');
    v_status := nullif(obs ->> 'status', '');
    v_minute := nullif(obs ->> 'minute', '')::integer;
    v_home_score := nullif(obs #>> '{score,home}', '')::integer;
    v_away_score := nullif(obs #>> '{score,away}', '')::integer;
    v_events := coalesce(obs -> 'events', '[]'::jsonb);
    v_provider_observed_at := nullif(obs ->> 'providerObservedAt', '')::timestamptz;
    v_observation_id := null;
    v_canonical_match_id := null;
    v_source := nullif(obs ->> 'source', '');

    if v_external_match_id is null then raise exception 'externalMatchId is required'; end if;
    if v_payload_hash is null or v_payload_hash !~ '^[0-9a-f]{64}$' then raise exception 'invalid payloadHash'; end if;
    if v_status is null then raise exception 'status is required'; end if;
    if jsonb_typeof(v_events) <> 'array' then raise exception 'events must be an array'; end if;

    perform pg_advisory_xact_lock(hashtext(p_provider || ':' || v_external_match_id));

    if p_provider = 'api_football' then
      v_canonical_match_id := futbeat_private.try_link_api_football_match(obs);
    else
      select pe.canonical_id into v_canonical_match_id
        from futbeat_private.provider_entities pe
       where pe.provider = p_provider and pe.kind = 'match' and pe.external_id = v_external_match_id;
    end if;

    insert into futbeat_private.provider_observations (
      provider, external_match_id, canonical_match_id, received_at, provider_observed_at,
      status, minute, home_score, away_score, events, payload_hash, raw_payload
    ) values (
      p_provider, v_external_match_id, v_canonical_match_id, p_received_at, v_provider_observed_at,
      v_status, v_minute, v_home_score, v_away_score, v_events, v_payload_hash,
      coalesce(obs -> 'rawPayload', '{}'::jsonb)
    )
    on conflict (provider, external_match_id, payload_hash) do nothing
    returning id into v_observation_id;

    if v_observation_id is null then
      v_duplicates := v_duplicates + 1;
      update futbeat_private.live_match_state
         set last_seen_at = greatest(last_seen_at, p_received_at),
             canonical_match_id = coalesce(v_canonical_match_id, canonical_match_id)
       where provider = p_provider and external_match_id = v_external_match_id;
      if v_canonical_match_id is not null then
        update futbeat_private.provider_observations set canonical_match_id=v_canonical_match_id
         where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
        update futbeat_private.live_events set canonical_match_id=v_canonical_match_id
         where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
        perform public.futbeat_publish_live_state(p_provider, v_external_match_id);
      end if;
      continue;
    end if;

    v_inserted_observations := v_inserted_observations + 1;
    select * into v_existing from futbeat_private.live_match_state
     where provider = p_provider and external_match_id = v_external_match_id for update;
    v_initial := not found;

    v_new_events := 0;
    v_corrected := 0;
    v_retracted := 0;
    v_keys := '{}';
    for evt in select value from jsonb_array_elements(v_events)
    loop
      if nullif(evt ->> 'eventKey', '') is null then raise exception 'eventKey is required'; end if;
      -- A key repeated inside one answer is one row (first occurrence wins).
      if (evt ->> 'eventKey') = any(v_keys) then continue; end if;
      v_keys := v_keys || (evt ->> 'eventKey');
      select * into v_prev from futbeat_private.live_events
       where provider = p_provider and external_match_id = v_external_match_id
         and event_key = evt ->> 'eventKey'
       for update;
      if not found then
        insert into futbeat_private.live_events (
          provider, external_match_id, event_key, canonical_match_id, event_type, minute,
          team_external_id, player_external_id, payload, first_seen_at, source
        ) values (
          p_provider, v_external_match_id, evt ->> 'eventKey', v_canonical_match_id,
          coalesce(nullif(evt ->> 'type', ''), 'OTHER'), nullif(evt ->> 'minute', '')::integer,
          nullif(evt ->> 'teamExternalId', ''), nullif(evt ->> 'playerExternalId', ''), evt, p_received_at, v_source
        ) on conflict (provider, external_match_id, event_key) do nothing;
        get diagnostics v_inserted = row_count;
        v_new_events := v_new_events + v_inserted;
      elsif futbeat_private.live_event_content(v_prev.payload) is not distinct from futbeat_private.live_event_content(evt)
        and v_prev.retracted_at is null then
        -- Same normalized content: never a correction; only the path of the
        -- last sighting is remembered (no revision).
        if v_prev.source is distinct from v_source then
          update futbeat_private.live_events set source = v_source
           where provider = p_provider and external_match_id = v_external_match_id
             and event_key = evt ->> 'eventKey';
        end if;
      else
        -- P0-A: the latest observation of one upstream row wins (correction
        -- or restoration after a retraction).
        update futbeat_private.live_events
           set event_type = coalesce(nullif(evt ->> 'type', ''), 'OTHER'),
               minute = nullif(evt ->> 'minute', '')::integer,
               team_external_id = nullif(evt ->> 'teamExternalId', ''),
               player_external_id = nullif(evt ->> 'playerExternalId', ''),
               payload = evt,
               canonical_match_id = coalesce(v_canonical_match_id, canonical_match_id),
               source = v_source,
               retracted_at = null,
               updated_at = p_received_at,
               revision = revision + 1
         where provider = p_provider and external_match_id = v_external_match_id
           and event_key = evt ->> 'eventKey';
        v_corrected := v_corrected + 1;
      end if;
    end loop;

    -- P0-A snapshot-replace: only sections answered as a complete array.
    -- Path rule: a detail answer covers every path; any other answer only
    -- rows last seen on the list or with no recorded path (legacy).
    -- GOALs: never below the team score; above it, any path trims the
    -- team's unlisted goals (newest first) down to the score.
    if jsonb_typeof(obs -> 'completeSections') = 'array' then
      select coalesce(array_agg(value), '{}') into v_sections
        from jsonb_array_elements_text(obs -> 'completeSections');
      v_detail := v_source = 'detail';
      v_guard_all := false;
      v_goal_keys := '{}';
      if 'events' = any(v_sections) then
        foreach v_side in array array['home','away'] loop
          v_team_ext := coalesce(nullif(obs #>> array['rawPayload', v_side || 'Team', 'id'], ''),
            nullif(obs #>> array['rawPayload', v_side || 'TeamId'], ''));
          v_team_score := case v_side when 'home' then v_home_score else v_away_score end;
          if v_team_ext is null or v_team_score is null then
            -- Unknown side or score: goals are never retracted by this answer.
            v_guard_all := true;
            continue;
          end if;
          -- Newest first (latest minute, then latest sighting): an annulment
          -- almost always removes the most recent goal.
          select count(*),
                 coalesce(array_agg(event_key order by minute desc nulls last, first_seen_at desc, event_key desc)
                   filter (where not (event_key = any(v_keys))), '{}'),
                 coalesce(array_agg(event_key order by minute desc nulls last, first_seen_at desc, event_key desc)
                   filter (where not (event_key = any(v_keys))
                     and (v_detail or source is null or source = 'live-list')), '{}')
            into v_goal_active, v_unlisted, v_unlisted_path
            from futbeat_private.live_events
           where provider = p_provider and external_match_id = v_external_match_id
             and event_type = 'GOAL' and team_external_id = v_team_ext and retracted_at is null;
          -- (a)/(b) path retraction, only when the score still holds.
          if v_goal_active - cardinality(v_unlisted_path) >= v_team_score then
            v_goal_keys := v_goal_keys || v_unlisted_path;
            v_goal_candidates := cardinality(v_unlisted_path);
            select coalesce(array_agg(k order by o), '{}') into v_rest
              from unnest(v_unlisted) with ordinality u(k, o) where not (k = any(v_unlisted_path));
          else
            v_goal_candidates := 0;
            v_rest := v_unlisted;
          end if;
          -- (c) score evidence overrides the path: trim down to the score.
          v_take := greatest(0, least(v_goal_active - v_goal_candidates - v_team_score, cardinality(v_rest)));
          if v_take > 0 then
            v_goal_keys := v_goal_keys || v_rest[1:v_take];
          end if;
        end loop;
      end if;
      update futbeat_private.live_events
         set retracted_at = p_received_at, updated_at = p_received_at, revision = revision + 1
       where provider = p_provider and external_match_id = v_external_match_id
         and retracted_at is null
         and futbeat_private.live_event_section(event_type) = any(v_sections)
         and not (event_key = any(v_keys))
         and case
           when event_type = 'GOAL' and team_external_id is not null
             then not v_guard_all and event_key = any(v_goal_keys)
           else v_detail or source is null or source = 'live-list'
         end;
      get diagnostics v_retracted = row_count;
    end if;

    select count(*) into v_active from futbeat_private.live_events
     where provider = p_provider and external_match_id = v_external_match_id and retracted_at is null;

    if v_initial then
      insert into futbeat_private.live_match_state (
        provider, external_match_id, canonical_match_id, status, minute, home_score, away_score,
        event_count, last_payload_hash, revision, first_seen_at, last_seen_at, changed_at
      ) values (
        p_provider, v_external_match_id, v_canonical_match_id, v_status, v_minute,
        v_home_score, v_away_score, v_active, v_payload_hash, 1,
        p_received_at, p_received_at, p_received_at
      );
      v_revision := 1;
      v_score_changed := false;
      v_status_changed := false;
      v_minute_changed := false;
      v_any_changed := true;
    else
      v_score_changed := v_existing.home_score is distinct from v_home_score or v_existing.away_score is distinct from v_away_score;
      v_status_changed := v_existing.status is distinct from v_status;
      v_minute_changed := v_existing.minute is distinct from v_minute;
      v_any_changed := v_score_changed or v_status_changed or v_minute_changed or v_new_events > 0
        or v_corrected > 0 or v_retracted > 0;
      v_revision := v_existing.revision + case when v_any_changed then 1 else 0 end;
      update futbeat_private.live_match_state
         set canonical_match_id = coalesce(v_canonical_match_id, canonical_match_id),
             status = v_status, minute = v_minute, home_score = v_home_score, away_score = v_away_score,
             event_count = v_active, last_payload_hash = v_payload_hash,
             revision = v_revision, last_seen_at = p_received_at,
             changed_at = case when v_any_changed then p_received_at else changed_at end
       where provider = p_provider and external_match_id = v_external_match_id;
    end if;

    if v_canonical_match_id is not null then
      update futbeat_private.provider_observations set canonical_match_id=v_canonical_match_id
       where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
      update futbeat_private.live_events set canonical_match_id=v_canonical_match_id
       where provider=p_provider and external_match_id=v_external_match_id and canonical_match_id is null;
      perform public.futbeat_publish_live_state(p_provider, v_external_match_id);
    end if;

    v_changes := v_changes || jsonb_build_array(jsonb_build_object(
      'externalMatchId', v_external_match_id,
      'canonicalMatchId', v_canonical_match_id,
      'initial', v_initial,
      'stateChanged', v_any_changed,
      'scoreChanged', v_score_changed,
      'statusChanged', v_status_changed,
      'minuteChanged', v_minute_changed,
      'newEvents', case when v_initial then 0 else v_new_events end,
      'storedEvents', v_new_events,
      'correctedEvents', v_corrected,
      'retractedEvents', v_retracted,
      'notifyCandidate', (not v_initial) and (v_score_changed or v_status_changed or v_new_events > 0),
      'revision', v_revision
    ));
  end loop;

  return jsonb_build_object(
    'provider', p_provider,
    'insertedObservations', v_inserted_observations,
    'duplicates', v_duplicates,
    'changes', v_changes
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Projection
-- ---------------------------------------------------------------------------

-- Same logical occurrence (copied from 20260926030000). Changed only: a row
-- stored as the re-keyed copy of another (duplicateOf, see
-- record_live_events) is that occurrence; it keeps its own canonical row (no
-- shared id, no key ping-pong) but is shown once, as #121 did.
create or replace function futbeat_private.events_equivalent(a jsonb,b jsonb)
returns boolean language plpgsql immutable set search_path='' as $$
declare
 ka text:=nullif(a->>'providerEventKey',''); kb text:=nullif(b->>'providerEventKey','');
 ta text:=nullif(a->>'teamId',''); tb text:=nullif(b->>'teamId','');
 pa text:=nullif(a->>'playerId',''); pb text:=nullif(b->>'playerId','');
 va integer; vb integer; sa text; sb text;
begin
 if a->>'type' is distinct from b->>'type' then return false; end if;
 if nullif(a->>'id','') is not null and a->>'id'=b->>'id' then return true; end if;
 if futbeat_private.is_phase_event(a->>'type') then return false; end if;
 if nullif(a->>'matchId','') is not null and nullif(b->>'matchId','') is not null
   and a->>'matchId'<>b->>'matchId' then return false; end if;
 -- Synthetic goals need the match context (ordinal); see dedupe_match_events.
 if futbeat_private.is_synthetic_event(a) or futbeat_private.is_synthetic_event(b) then return false; end if;
 if (nullif(a->>'duplicateOf','') is not null and a->>'duplicateOf'=b->>'id')
   or (nullif(b->>'duplicateOf','') is not null and b->>'duplicateOf'=a->>'id') then return true; end if;
 if ka is not null and kb is not null and coalesce(a->>'provider','')=coalesce(b->>'provider','') then
   if ka=kb then return true; end if;
   -- Two upstream row ids of one provider are two occurrences; composed
   -- fallback keys (type:minute:...) are weak and fall through.
   if position(':' in ka)=0 and position(':' in kb)=0 then return false; end if;
 end if;
 -- Conservative from here on: type + team + minute alone never merges two
 -- real events. A possible duplicate is better than losing a real goal.
 if ta is null or tb is null or ta<>tb then return false; end if;
 if pa is not null and pb is not null and pa<>pb then return false; end if;
 if a->>'type'='SUBSTITUTION' and nullif(a->>'assistPlayerId','') is not null
   and nullif(b->>'assistPlayerId','') is not null and a->>'assistPlayerId'<>b->>'assistPlayerId' then
   return false;
 end if;
 sa:=futbeat_private.event_score_after(a); sb:=futbeat_private.event_score_after(b);
 -- Different score after the event: always two events.
 if sa is not null and sb is not null and sa<>sb then return false; end if;
 va:=futbeat_private.event_minute_value(a); vb:=futbeat_private.event_minute_value(b);
 if pa is not null and pb is not null then
   -- The same canonical player: compatible minute (one minute of
   -- cross-provider rounding).
   return futbeat_private.event_minutes_compatible(a,b)
     or (va is not null and vb is not null and abs(va-vb)<=1);
 end if;
 -- Player identity missing on either side: only the exact same score after
 -- the event (GOAL) plus a compatible minute is strong enough.
 return sa is not null and sb is not null and sa=sb and futbeat_private.event_minutes_compatible(a,b);
end $$;

-- Keep the stronger event; fill only what it lacks (copied from
-- 20260926030000, unchanged; the latest-observation rule lives in
-- dedupe_match_events).
create or replace function futbeat_private.merge_event_evidence(k jsonb,e jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare r jsonb:=k; f text;
begin
 foreach f in array array['teamId','playerId','assistPlayerId','score'] loop
   if nullif(r->>f,'') is null and nullif(e->>f,'') is not null then r:=r||jsonb_build_object(f,e->f); end if;
 end loop;
 if nullif(r->>'providerEventKey','') is null and nullif(e->>'providerEventKey','') is not null then
   r:=r||jsonb_build_object('providerEventKey',e->'providerEventKey','provider',e->'provider');
 end if;
 if futbeat_private.safe_result_integer(r->>'extraMinute') is null
   and futbeat_private.safe_result_integer(e->>'extraMinute') is not null
   and futbeat_private.safe_result_integer(r->>'minute')=futbeat_private.safe_result_integer(e->>'minute') then
   r:=r||jsonb_build_object('extraMinute',e->'extraMinute');
 end if;
 return r||jsonb_build_object('_members',coalesce(r->'_members','[]'::jsonb)||jsonb_build_array(e->>'id'));
end $$;

-- Team goals after the event for its side (the synthetic ordinal), or null.
create or replace function futbeat_private.event_team_ordinal(e jsonb,p_home_team text,p_away_team text)
returns integer language sql immutable set search_path='' as $$
  select case when nullif(e->>'teamId','') is null then null
    when e->>'teamId'=p_home_team then futbeat_private.safe_result_integer(e#>>'{score,home}')
    when e->>'teamId'=p_away_team then futbeat_private.safe_result_integer(e#>>'{score,away}') end
$$;

-- One entry per logical occurrence; '_members' lists the merged event ids.
-- Base: 20260926030000. Changed: rows of the same provider key keep the
-- latest observation (observedAt); synthetic goals fold by ordinal without a
-- minute limit, are hidden above the current score (p_score, when known) and
-- at most one is kept per ordinal.
create or replace function futbeat_private.dedupe_match_events(
  p_events jsonb,p_home_team text,p_away_team text,p_score jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
 kept jsonb:='[]'; synth jsonb:='[]'; e jsonb; k jsonb; i integer; best integer; best_diff integer;
 d integer; n integer; rank integer; v_cap integer;
begin
 if jsonb_typeof(p_events) is distinct from 'array' then return '[]'::jsonb; end if;
 -- 1. Rich events, strongest evidence first (identified player, then minute).
 for e in select value from jsonb_array_elements(p_events)
   order by futbeat_private.is_synthetic_event(value),nullif(value->>'playerId','') is null,
     futbeat_private.safe_result_integer(value->>'minute') nulls last,
     futbeat_private.safe_result_integer(value->>'extraMinute') nulls first,value->>'id'
 loop
   if jsonb_typeof(e) is distinct from 'object' then continue; end if;
   if futbeat_private.is_synthetic_event(e) then synth:=synth||jsonb_build_array(e); continue; end if;
   best:=null;
   for i in 0..jsonb_array_length(kept)-1 loop
     if futbeat_private.events_equivalent(kept->i,e) then best:=i; exit; end if;
   end loop;
   if best is null then
     kept:=kept||jsonb_build_array(e||jsonb_build_object('_members',jsonb_build_array(e->>'id')));
   else
     k:=kept->best;
     if nullif(e->>'providerEventKey','') is not null and e->>'providerEventKey'=k->>'providerEventKey'
       and coalesce(e->>'provider','')=coalesce(k->>'provider','')
       and coalesce(e->>'observedAt','')>coalesce(k->>'observedAt','') then
       -- Same upstream row: the latest observation wins, older evidence only
       -- fills what it lacks.
       kept:=jsonb_set(kept,array[best::text],
         futbeat_private.merge_event_evidence(e-'_members',k-'_members')
           ||jsonb_build_object('_members',k->'_members'||jsonb_build_array(e->>'id')));
     else
       kept:=jsonb_set(kept,array[best::text],futbeat_private.merge_event_evidence(k,e));
     end if;
   end if;
 end loop;
 -- 2. Synthetic GOALs: the score decides.
 for e in select value from jsonb_array_elements(synth)
   order by futbeat_private.safe_result_integer(value->>'minute') nulls last,value->>'id'
 loop
   n:=futbeat_private.event_team_ordinal(e,p_home_team,p_away_team);
   v_cap:=case when nullif(e->>'teamId','') is null then null
     when e->>'teamId'=p_home_team then futbeat_private.safe_result_integer(p_score->>'home')
     when e->>'teamId'=p_away_team then futbeat_private.safe_result_integer(p_score->>'away') end;
   -- Above the current score: the goal it stood for no longer counts.
   if n is not null and v_cap is not null and n>v_cap then continue; end if;
   best:=null; best_diff:=null;
   if n is not null and e->>'type'='GOAL' then
     -- The rich goal with that ordinal explains it, whatever its minute.
     for i in 0..jsonb_array_length(kept)-1 loop
       k:=kept->i;
       if k->>'type' is distinct from 'GOAL' or futbeat_private.is_synthetic_event(k)
         or k->>'teamId' is distinct from e->>'teamId' then continue; end if;
       select count(*) into rank from jsonb_array_elements(kept) x
       where x->>'type'='GOAL' and not futbeat_private.is_synthetic_event(x) and x->>'teamId'=k->>'teamId'
         and (coalesce(futbeat_private.event_minute_value(x),999)<coalesce(futbeat_private.event_minute_value(k),999)
           or (coalesce(futbeat_private.event_minute_value(x),999)=coalesce(futbeat_private.event_minute_value(k),999)
             and coalesce(x->>'id','')<=coalesce(k->>'id','')));
       if rank=n then best:=i; exit; end if;
     end loop;
     -- Otherwise at most one synthetic per ordinal (a repeated increase).
     if best is null then
       for i in 0..jsonb_array_length(kept)-1 loop
         k:=kept->i;
         if futbeat_private.is_synthetic_event(k) and k->>'teamId'=e->>'teamId'
           and futbeat_private.event_team_ordinal(k,p_home_team,p_away_team)=n then best:=i; exit; end if;
       end loop;
     end if;
   else
     -- No ordinal: the #121 rule (closest rich goal of the team, 3 minutes).
     for i in 0..jsonb_array_length(kept)-1 loop
       k:=kept->i;
       if k->>'type' is distinct from 'GOAL' or futbeat_private.is_synthetic_event(k)
         or e->>'type' is distinct from 'GOAL' or nullif(e->>'teamId','') is null
         or k->>'teamId' is distinct from e->>'teamId' or coalesce(k->>'_absorbedSynthetic','')='true' then
         continue;
       end if;
       d:=abs(futbeat_private.event_minute_value(k)-futbeat_private.event_minute_value(e));
       if not (futbeat_private.event_minutes_compatible(k,e) or d<=3) then continue; end if;
       if best is null or coalesce(d,99)<best_diff then best:=i; best_diff:=coalesce(d,99); end if;
     end loop;
   end if;
   if best is null then
     kept:=kept||jsonb_build_array(e||jsonb_build_object('_members',jsonb_build_array(e->>'id')));
   else
     kept:=jsonb_set(kept,array[best::text],
       futbeat_private.merge_event_evidence(kept->best,e)||jsonb_build_object('_absorbedSynthetic',true));
   end if;
 end loop;
 return coalesce((select jsonb_agg(x-'_absorbedSynthetic' order by
     futbeat_private.safe_result_integer(x->>'minute') nulls last,
     futbeat_private.safe_result_integer(x->>'extraMinute') nulls first,x->>'id')
   from jsonb_array_elements(kept) x),'[]'::jsonb);
end $$;

-- Without a known score (the push guard): no synthetic is hidden by it.
create or replace function futbeat_private.dedupe_match_events(p_events jsonb,p_home_team text,p_away_team text)
returns jsonb language sql immutable set search_path='' as $$
  select futbeat_private.dedupe_match_events(p_events,p_home_team,p_away_team,null::jsonb)
$$;

-- What users see: deduplicated, score-authoritative, without technical copy.
create or replace function futbeat_private.visible_match_events(
  p_events jsonb,p_home_team text,p_away_team text,p_score jsonb)
returns jsonb language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(case
      when futbeat_private.is_synthetic_event(x) or x->>'detail'='Marcador actualizado'
        then x-'_members'-'observedAt'-'duplicateOf'-'detail' else x-'_members'-'observedAt'-'duplicateOf' end order by ordinal),'[]'::jsonb)
  from jsonb_array_elements(futbeat_private.dedupe_match_events(p_events,p_home_team,p_away_team,p_score))
    with ordinality as events(x,ordinal)
$$;

create or replace function futbeat_private.visible_match_events(p_events jsonb,p_home_team text,p_away_team text)
returns jsonb language sql immutable set search_path='' as $$
  select futbeat_private.visible_match_events(p_events,p_home_team,p_away_team,null::jsonb)
$$;

-- More visible rich goals than the score for either team.
create or replace function futbeat_private.event_score_mismatch(
  p_visible jsonb,p_home_team text,p_away_team text,p_score jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(bool_or(goals>cap),false) from (
    select s.side,
      futbeat_private.safe_result_integer(p_score->>s.side) cap,
      (select count(*) from jsonb_array_elements(case when jsonb_typeof(p_visible)='array'
          then p_visible else '[]'::jsonb end) x
        where x->>'type'='GOAL' and not futbeat_private.is_synthetic_event(x)
          and x->>'teamId'=case s.side when 'home' then p_home_team else p_away_team end) goals
    from (values('home'),('away')) s(side)
  ) t where cap is not null
$$;

-- True when a just-stored event is the same occurrence as another ACTIVE
-- event already stored for the match (base: 20260926030000; retracted rows
-- are excluded, corrections are caught by event_correction_twin).
create or replace function futbeat_private.event_already_known(ev jsonb,m jsonb)
returns boolean language sql stable security invoker set search_path='' as $$
  select not futbeat_private.is_phase_event(ev->>'type') and exists(
    select 1 from jsonb_array_elements(futbeat_private.dedupe_match_events(
      (select coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb)
         from futbeat_private.canonical_events c
        where c.match_id=ev->>'matchId' and c.event_type=ev->>'type' and c.retracted_at is null),
      m->>'homeTeamId',m->>'awayTeamId',null::jsonb)) g
    where g->'_members' ? (ev->>'id') and jsonb_array_length(g->'_members')>1)
$$;

-- The row a new event corrects: retracted by the same observation, same
-- type, same team or the same identified player, and close enough to be the
-- same occurrence (same player, minute within 5, or the same score-after).
-- Rows already consumed by another correction are never reused.
create or replace function futbeat_private.event_correction_twin(ev jsonb,p_at timestamptz)
returns text language sql stable security invoker set search_path='' as $$
  select c.id from futbeat_private.canonical_events c
  where not futbeat_private.is_phase_event(ev->>'type')
    and c.match_id=ev->>'matchId' and c.event_type=ev->>'type' and c.id<>ev->>'id'
    and c.retracted_at=p_at
    and coalesce(c.retraction_reason,'') in ('provider_retracted','absent_from_snapshot','superseded')
    and (c.payload->>'teamId' is not distinct from ev->>'teamId'
      or (nullif(c.payload->>'playerId','') is not null and c.payload->>'playerId'=ev->>'playerId'))
    and ((nullif(c.payload->>'playerId','') is not null and c.payload->>'playerId'=ev->>'playerId')
      or abs(futbeat_private.event_minute_value(c.payload)-futbeat_private.event_minute_value(ev))<=5
      or (futbeat_private.event_score_after(c.payload) is not null
        and futbeat_private.event_score_after(c.payload)=futbeat_private.event_score_after(ev)))
  order by (c.payload->>'playerId' is not distinct from ev->>'playerId') desc,
    abs(coalesce(futbeat_private.event_minute_value(c.payload),999)-coalesce(futbeat_private.event_minute_value(ev),0)),c.id
  limit 1
$$;

-- Soft retraction with audit; never deletes. True when it changed the row.
create or replace function futbeat_private.retract_canonical_event(p_id text,p_at timestamptz,p_reason text)
returns boolean language plpgsql security invoker set search_path='' as $$
declare v_old futbeat_private.canonical_events%rowtype;
begin
 select * into v_old from futbeat_private.canonical_events where id=p_id for update;
 if not found or v_old.retracted_at is not null then return false; end if;
 update futbeat_private.canonical_events
    set retracted_at=p_at,retraction_reason=p_reason,updated_at=p_at,revision=revision+1
  where id=p_id;
 insert into futbeat_private.canonical_event_revisions(event_id,match_id,revised_at,action,reason,previous_payload,payload)
 values(p_id,v_old.match_id,p_at,'retract',p_reason,v_old.payload,v_old.payload);
 return true;
end $$;

-- ---------------------------------------------------------------------------
-- Store (copied from 20260928100000_free_player_alerts.sql). Changed: an
-- existing non-phase, non-synthetic row is updated in place when its content
-- changed or it was retracted (audited, never notified); a new row that
-- corrects one retracted in the same observation never notifies.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.store_canonical_event(
  ev jsonb,
  p_provider text,
  p_notify boolean,
  p_at timestamptz,
  m jsonb
) returns void
language plpgsql
security invoker
set search_path=''
as $$
declare
  inserted integer;
  msg jsonb;
  pmsg jsonb;
  involved record;
  v_old futbeat_private.canonical_events%rowtype;
  v_new jsonb;
  v_twin text;
begin
  select * into v_old from futbeat_private.canonical_events where id=ev->>'id' for update;
  if found then
    -- Phase and synthetic rows keep their first observation (#121).
    if futbeat_private.is_phase_event(ev->>'type')
      or futbeat_private.is_synthetic_event(ev)
      or futbeat_private.is_synthetic_event(v_old.payload) then
      return;
    end if;
    v_new:=futbeat_private.normalize_event_minutes(ev);
    if (jsonb_strip_nulls(v_new)-'observedAt') is distinct from (jsonb_strip_nulls(v_old.payload)-'observedAt')
      or v_old.retracted_at is not null then
      insert into futbeat_private.canonical_event_revisions(event_id,match_id,revised_at,action,reason,previous_payload,payload)
      values(v_old.id,v_old.match_id,p_at,
        case when v_old.retracted_at is not null then 'restore' else 'update' end,
        'provider_observation',v_old.payload,v_new);
      update futbeat_private.canonical_events
         set payload=ev,event_type=ev->>'type',retracted_at=null,retraction_reason=null,
             updated_at=p_at,revision=revision+1
       where id=v_old.id;
    end if;
    -- A correction / restoration is never a new push.
    return;
  end if;

  insert into futbeat_private.canonical_events
  values(ev->>'id',ev->>'matchId',p_provider,ev->>'type',ev,p_notify,p_at)
  on conflict(id) do nothing;

  get diagnostics inserted=row_count;
  if inserted=0 then return; end if;

  -- P0-A: the same observation retracted the row this one replaces (a
  -- re-keyed or corrected upstream row): one push per logical occurrence.
  -- Resolved even when this row may not notify, so the twin's push is never
  -- cancelled at claim time.
  v_twin:=futbeat_private.event_correction_twin(ev,p_at);
  if v_twin is not null then
    -- The twin's push (sent or pending) stands for this occurrence.
    update futbeat_private.canonical_events set retraction_reason='corrected' where id=v_twin;
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;
  if not p_notify then return; end if;
  -- #121: a re-keyed copy of an active row never pushes again.
  if nullif(ev->>'duplicateOf','') is not null then
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;

  -- #121: one push per logical occurrence. A new event equivalent to one
  -- already stored for the match (a rich GOAL after its provisional
  -- synthetic, the same goal from another provider, a re-keyed event) is
  -- kept for audit but never notified again.
  if futbeat_private.event_already_known(ev,m) then
    update futbeat_private.canonical_events set notify_candidate=false where id=ev->>'id';
    return;
  end if;

  msg:=futbeat_private.event_message(ev,m);
  if msg is null then return; end if;

  -- #106: followed players first (scorer / carded / out, then assist / in),
  -- so the player copy wins the (event,user,device) slot.
  if not futbeat_private.player_event_is_stale(ev) then
    for involved in
      select x.role,x.pid from (values
        (1,'primary',ev->>'playerId'),
        (2,'assist',ev->>'assistPlayerId')) x(ord,role,pid)
      where x.pid is not null order by x.ord
    loop
      pmsg:=futbeat_private.player_event_message(ev,msg,involved.pid,involved.role);
      continue when pmsg is null;
      insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
      select ev->>'id',d.id,d.user_id,pmsg
      from futbeat_private.push_devices d
      left join futbeat_private.user_preferences p on p.user_id=d.user_id
      where d.enabled
        and d.registered_at<=p_at
        and case ev->>'type'
          when 'GOAL' then coalesce(p.notify_goals,true)
          when 'YELLOW_CARD' then coalesce(p.notify_cards,true)
          when 'RED_CARD' then coalesce(p.notify_cards,true)
          else true
        end
        and exists(
          select 1 from futbeat_private.push_follows f
          where f.user_id=d.user_id and f.created_at<=p_at
            and f.entity_type='player' and f.entity_id=involved.pid
        )
      on conflict(event_id,user_id,device_id) do nothing;
    end loop;
  end if;

  insert into futbeat_private.notification_outbox(event_id,device_id,user_id,message)
  select ev->>'id',d.id,d.user_id,msg
  from futbeat_private.push_devices d
  left join futbeat_private.user_preferences p on p.user_id=d.user_id
  where d.enabled
    and d.registered_at<=p_at
    and case ev->>'type'
      when 'KICKOFF' then coalesce(p.notify_kickoff,true)
      when 'GOAL' then coalesce(p.notify_goals,true)
      when 'FULL_TIME' then coalesce(p.notify_final,true)
      when 'YELLOW_CARD' then coalesce(p.notify_cards,true)
      when 'RED_CARD' then coalesce(p.notify_cards,true)
      else true
    end
    and exists(
      select 1
      from futbeat_private.push_follows f
      where f.user_id=d.user_id
        and f.created_at<=p_at
        and (
          (f.entity_type='match' and f.entity_id=ev->>'matchId')
          or (
            f.entity_type='team'
            and f.entity_id in (m->>'homeTeamId',m->>'awayTeamId')
          )
        )
    )
  on conflict(event_id,user_id,device_id) do nothing;
end;
$$;

-- ---------------------------------------------------------------------------
-- Synthetic goals (copied from 20260926030000). Changed: the score deficit
-- decides. On an increase, one synthetic goal per team ordinal that the
-- active rich goals of that side do not explain (no "first seen in this
-- observation, near the current minute" rule: a late first sighting of a
-- rich goal explains the increase). A score drop hides synthetics in the
-- projection (score-authoritative), nothing is deleted.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.synthesize_goal_from_score_change()
returns trigger
language plpgsql
security definer
set search_path=''
as $event$
declare
  m jsonb;
  ev jsonb;
  baseline boolean;
  v_raw jsonb;
  v_side text;
  v_old integer;
  v_new integer;
  v_team text;
  v_explained integer;
  v_ordinal integer;
  v_retract record;
begin
  if new.provider<>'goal_api'
     or new.canonical_match_id is null
     or (
       new.home_score is not distinct from old.home_score
       and new.away_score is not distinct from old.away_score
     )
  then
    return new;
  end if;

  select payload into m
  from futbeat_private.entities
  where id=new.canonical_match_id and kind='match';

  if m is null then
    return new;
  end if;

  -- Review P1-1: a (known) score decrease retracts the provisional goals it
  -- no longer supports, so they never absorb or silence a later real goal.
  if new.home_score is not null and new.away_score is not null then
    foreach v_side in array array['home','away'] loop
      v_new:=case v_side when 'home' then new.home_score else new.away_score end;
      v_old:=case v_side when 'home' then coalesce(old.home_score,0) else coalesce(old.away_score,0) end;
      continue when v_new>=v_old;
      for v_retract in select c.id from futbeat_private.canonical_events c
        where c.match_id=new.canonical_match_id and c.provider='goal_api'
          and c.retracted_at is null and futbeat_private.is_synthetic_event(c.payload)
          and c.payload->>'teamId'=m->>(v_side||'TeamId')
          and coalesce(futbeat_private.event_team_ordinal(c.payload,m->>'homeTeamId',m->>'awayTeamId'),0)>v_new
      loop
        perform futbeat_private.retract_canonical_event(v_retract.id,new.changed_at,'score_decrease');
      end loop;
    end loop;
  end if;

  if coalesce(new.home_score,0)<=coalesce(old.home_score,0)
     and coalesce(new.away_score,0)<=coalesce(old.away_score,0) then
    return new;
  end if;

  select exists(
    select 1
    from futbeat_private.event_baselines
    where match_id=new.canonical_match_id
  ) into baseline;

  select raw_payload into v_raw
  from futbeat_private.provider_observations
  where provider=new.provider
    and external_match_id=new.external_match_id
    and payload_hash=new.last_payload_hash;

  foreach v_side in array array['home','away'] loop
    v_old:=case v_side when 'home' then coalesce(old.home_score,0) else coalesce(old.away_score,0) end;
    v_new:=case v_side when 'home' then coalesce(new.home_score,0) else coalesce(new.away_score,0) end;
    if v_new<=v_old then
      continue;
    end if;
    v_team:=m->>(v_side||'TeamId');

    -- Active rich goals of this side (any observation).
    select count(*) into v_explained
    from futbeat_private.live_events le
    where le.provider=new.provider
      and le.external_match_id=new.external_match_id
      and le.event_type='GOAL'
      and le.retracted_at is null
      and (
        le.team_external_id=coalesce(
          v_raw#>>array[v_side||'Team','id'],v_raw->>(v_side||'TeamId'))
        or exists(
          select 1 from futbeat_private.provider_entities pe
          where pe.provider=new.provider and pe.kind='team'
            and pe.external_id=le.team_external_id and pe.canonical_id=v_team)
      );

    for v_ordinal in greatest(v_old,v_explained)+1..v_new loop
      ev:=jsonb_build_object(
        -- The top ordinal keeps the historical id formula.
        'id','fb_event_'||md5(concat_ws(
          '|',new.canonical_match_id,'goal_api','GOAL',v_side,
          new.revision,new.minute,new.home_score,new.away_score,
          case when v_ordinal<>v_new then v_ordinal end
        )),
        'matchId',new.canonical_match_id,
        'type','GOAL',
        'minute',new.minute,
        'teamId',v_team,
        'score',jsonb_build_object(
          'home',case when v_side='home' then v_ordinal else new.home_score end,
          'away',case when v_side='away' then v_ordinal else new.away_score end
        ),
        -- Internal audit text; the visible projection never shows it.
        'detail','Marcador actualizado',
        'synthetic',true
      );
      perform futbeat_private.store_canonical_event(
        ev,'goal_api',baseline,new.changed_at,m
      );
    end loop;
  end loop;

  return new;
end
$event$;

-- ---------------------------------------------------------------------------
-- LIVE -> canonical (copied from 20260926030000). Changed: retracted upstream
-- rows retract their canonical rows first; canonical identity is the upstream
-- key (the row already carrying it is reused and updated); legacy rows of the
-- same key are superseded; a complete section retracts canonical rows it no
-- longer backs (legacy content-id rows included).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.record_live_events(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; c jsonb; m jsonb; mid text; e record; tid text; pid text; aid text;
 ev jsonb; eid text; can_notify boolean; baseline boolean; typ text; state futbeat_private.live_match_state;
 obs jsonb; kept jsonb:='[]'; suppressed jsonb:='[]'; v_ext text; v_status text; v_claimed text;
 v_hit text; v_obs jsonb; v_sections text[]; v_backed text[]; r record; v_key text; v_dup text; v_content text;
 v_team_goals integer; v_team_score integer; v_dups jsonb;
begin
 -- Ignore delayed observations instead of regressing a live match.
 if exists(select 1 from jsonb_array_elements(p_observations) o
  join futbeat_private.live_match_state s on s.provider=p_provider and s.external_match_id=o->>'externalMatchId'
  where s.last_seen_at>p_received_at) then raise exception 'Stale live batch'; end if;
 -- Validate the WHOLE batch first (same rules as the core) so nothing
 -- malformed is ever mapped, suppressed or audited: it is rejected as before.
 if p_provider is null or btrim(p_provider)='' then raise exception 'provider is required'; end if;
 if p_received_at is null then raise exception 'received_at is required'; end if;
 if p_observations is null or jsonb_typeof(p_observations)<>'array' then raise exception 'observations must be an array'; end if;
 for obs in select value from jsonb_array_elements(p_observations) loop
  perform futbeat_private.validate_live_observation(obs);
 end loop;
 -- #120: a non-terminal observation never revives an effectively terminal
 -- match.
 for obs in select value from jsonb_array_elements(p_observations) loop
  v_ext:=obs->>'externalMatchId'; v_status:=obs->>'status'; mid:=null;
  if not futbeat_private.is_terminal_match_status(v_status) then
   if p_provider='api_football' then
    mid:=futbeat_private.try_link_api_football_match(obs);
   else
    select canonical_id into mid from futbeat_private.provider_entities
     where provider=p_provider and kind='match' and external_id=v_ext;
   end if;
   if mid is null then
    select canonical_match_id into mid from futbeat_private.live_match_state
     where provider=p_provider and external_match_id=v_ext;
   end if;
   if mid is not null and futbeat_private.match_effectively_terminal(mid) then
    insert into futbeat_private.live_suppressed_observations(provider,external_match_id,canonical_match_id,
      received_at,status,minute,home_score,away_score,payload_hash)
    values(p_provider,v_ext,mid,p_received_at,v_status,
      nullif(obs->>'minute','')::integer,
      nullif(obs#>>'{score,home}','')::integer,
      nullif(obs#>>'{score,away}','')::integer,
      obs->>'payloadHash')
    on conflict(provider,external_match_id,payload_hash) do nothing;
    suppressed:=suppressed||jsonb_build_array(jsonb_build_object('externalMatchId',v_ext,
      'canonicalMatchId',mid,'status',v_status,'reason','canonical_terminal'));
    continue;
   end if;
  end if;
  kept:=kept||jsonb_build_array(obs);
 end loop;
 result:=futbeat_private.record_live_batch_core(p_provider,p_received_at,kept);
 for c in select value from jsonb_array_elements(result->'changes') loop
  mid:=c->>'canonicalMatchId';
  if mid is null then continue; end if;
  select payload into m from futbeat_private.entities where id=mid and kind='match';
  if m is null then continue; end if;
  select exists(select 1 from futbeat_private.event_baselines where match_id=mid) into baseline;
  can_notify:=baseline and coalesce((c->>'notifyCandidate')::boolean,false);
  v_obs:=null;
  select value into v_obs from jsonb_array_elements(kept)
   where value->>'externalMatchId'=c->>'externalMatchId' limit 1;
  v_sections:=case when jsonb_typeof(v_obs->'completeSections')='array'
    then array(select jsonb_array_elements_text(v_obs->'completeSections')) end;
  v_backed:='{}';
  v_dups:='{}';
  select * into state from futbeat_private.live_match_state where provider=p_provider and external_match_id=c->>'externalMatchId';
  -- P0-A pass 1: upstream rows the provider no longer lists.
  for e in select * from futbeat_private.live_events
    where provider=p_provider and external_match_id=c->>'externalMatchId' and retracted_at is not null loop
   for r in select id from futbeat_private.canonical_events
     where match_id=mid and provider=p_provider and payload->>'providerEventKey'=e.event_key
       and retracted_at is null loop
    perform futbeat_private.retract_canonical_event(r.id,p_received_at,'provider_retracted');
   end loop;
  end loop;
  -- Pass 2: active rows. Deterministic order: the first occurrence always
  -- keeps the historical id.
  for e in select * from futbeat_private.live_events where provider=p_provider and external_match_id=c->>'externalMatchId'
    and retracted_at is null
    order by first_seen_at,event_key loop
   if e.event_type not in ('GOAL','YELLOW_CARD','RED_CARD','SUBSTITUTION','VAR','MISSED_PENALTY') then continue; end if;
   tid:=null; pid:=null; aid:=null;
   select canonical_id into tid from futbeat_private.provider_entities where provider=p_provider and kind='team' and external_id=e.team_external_id;
   if tid not in (m->>'homeTeamId',m->>'awayTeamId') then continue; end if;
   -- Unknown identity stays null; external IDs never masquerade as canonical IDs.
   select canonical_id into pid from futbeat_private.provider_entities where provider=p_provider and kind='player' and external_id=e.player_external_id;
   select canonical_id into aid from futbeat_private.provider_entities where provider=p_provider and kind='player'
     and external_id=coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}');
   v_hit:=null; v_key:=e.event_key; v_dup:=null;
   -- Historical content-based id of this row.
   v_content:='fb_event_'||md5(concat_ws('|',mid,p_provider,e.event_type,e.minute,
     coalesce(e.payload->>'extraMinute',e.payload#>>'{payload,time,extra}'),
     e.team_external_id,e.player_external_id,
     case when e.event_type='SUBSTITUTION' then coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}') else '' end));
   -- P0-A: the canonical row already carrying this upstream key is the
   -- identity (active first, then the oldest), whatever its content.
   select id into v_hit from futbeat_private.canonical_events
    where match_id=mid and provider=p_provider and payload->>'providerEventKey'=e.event_key
    order by (retracted_at is not null),first_seen_at,id limit 1;
   v_claimed:=null;
   select payload->>'providerEventKey' into v_claimed from futbeat_private.canonical_events where id=v_content;
   if v_hit is not null then
    eid:=v_hit;
   elsif v_claimed is not null and v_claimed<>e.event_key then
    -- New upstream key whose historical id another key owns: an id of its
    -- own (two upstream keys are two rows: no shared row, no ping-pong).
    eid:='fb_event_'||md5(v_content||'|'||e.event_key);
   else
    -- The historical id (a pre-#121 row without a key is claimed).
    eid:=v_content;
   end if;
   -- A copy of a still-listed row (#121 re-keyed row, real provider ids) is
   -- that occurrence: duplicateOf, shown once, never pushed again. Two
   -- anonymous occurrences stay distinct (#121).
   if v_claimed is not null and v_claimed<>e.event_key and eid<>v_content
      and not (v_claimed like 'fallback:%' and e.event_key like 'fallback:%')
      and exists(select 1 from futbeat_private.live_events o
        where o.provider=p_provider and o.external_match_id=c->>'externalMatchId'
          and o.event_key=v_claimed and o.retracted_at is null)
      and exists(select 1 from futbeat_private.canonical_events x
        where x.id=v_content and x.retracted_at is null
          -- Never when the score-after tells them apart.
          and not (jsonb_typeof(x.payload->'score')='object' and jsonb_typeof(e.payload->'scoreAfter')='object'
            and futbeat_private.event_score_after(x.payload)
              is distinct from futbeat_private.event_score_after(jsonb_build_object('score',e.payload->'scoreAfter')))) then
    v_dup:=v_content;
    -- Never when it would leave the team with fewer active goals than its
    -- current score (two ids, same content, score 2-0: two goals).
    if e.event_type='GOAL' then
     v_team_score:=case tid when m->>'homeTeamId' then state.home_score when m->>'awayTeamId' then state.away_score end;
     select count(*) into v_team_goals from futbeat_private.live_events o
      where o.provider=p_provider and o.external_match_id=c->>'externalMatchId'
        and o.event_type='GOAL' and o.retracted_at is null and o.team_external_id=e.team_external_id;
     if v_team_score is null
        or v_team_goals-coalesce((v_dups->>coalesce(tid,''))::integer,0)-1<v_team_score then
      v_dup:=null;
     else
      v_dups:=v_dups||jsonb_build_object(coalesce(tid,''),coalesce((v_dups->>coalesce(tid,''))::integer,0)+1);
     end if;
    end if;
   end if;
   ev:=jsonb_strip_nulls(jsonb_build_object('id',eid,'matchId',mid,'type',e.event_type,'minute',e.minute,
    'extraMinute',coalesce(e.payload->'extraMinute',e.payload#>'{payload,time,extra}'),
    'teamId',tid,'playerId',pid,'assistPlayerId',aid,
    -- #121: upstream identity (provider row id, or the stable fallback key).
    'providerEventKey',v_key,'provider',p_provider,'duplicateOf',v_dup,
    'score',case when jsonb_typeof(e.payload->'scoreAfter')='object' then e.payload->'scoreAfter' end,
    -- UNVERIFIED own-goal marker (see _shared/live_events.ts): teamId is the
    -- benefiting team, playerId the scorer.
    'ownGoal',case when coalesce(e.payload->>'ownGoal','')='true' then true end,
    -- P0-A: when this content was observed (latest observation wins).
    'observedAt',coalesce(e.updated_at,e.first_seen_at)));
   perform futbeat_private.store_canonical_event(ev,p_provider,can_notify and e.first_seen_at=p_received_at,p_received_at,m);
   v_backed:=v_backed||eid;
   -- Legacy rows of the same upstream key (content ids of older corrections).
   for r in select id from futbeat_private.canonical_events
     where match_id=mid and provider=p_provider and payload->>'providerEventKey'=v_key
       and id<>eid and retracted_at is null loop
    perform futbeat_private.retract_canonical_event(r.id,p_received_at,'superseded');
   end loop;
  end loop;
  -- Pass 3: a complete section retracts every rich canonical row of this
  -- provider it no longer backs (pre-#121 rows without a key included).
  if v_sections is not null then
   for r in select id from futbeat_private.canonical_events
     where match_id=mid and provider=p_provider and retracted_at is null
       and not futbeat_private.is_phase_event(event_type)
       and not futbeat_private.is_synthetic_event(payload)
       and futbeat_private.live_event_section(event_type)=any(v_sections)
       and not (id=any(v_backed)) loop
    perform futbeat_private.retract_canonical_event(r.id,p_received_at,'absent_from_snapshot');
   end loop;
  end if;
  select * into state from futbeat_private.live_match_state where provider=p_provider and external_match_id=c->>'externalMatchId';
  typ:=case state.status when 'LIVE' then 'KICKOFF' when 'HALFTIME' then 'HALFTIME'
    when 'FINISHED_PENDING_VERIFICATION' then 'FULL_TIME' when 'VERIFIED' then 'FULL_TIME' end;
  if typ is not null and ((c->>'statusChanged')::boolean or (c->>'initial')::boolean) then
   ev:=jsonb_build_object('id','fb_event_'||md5(mid||'|'||typ),'matchId',mid,'type',typ,
    'minute',case when typ='KICKOFF' then 0 else state.minute end,
    'score',jsonb_build_object('home',state.home_score,'away',state.away_score));
   perform futbeat_private.store_canonical_event(ev,p_provider,can_notify,p_received_at,m);
  end if;
  insert into futbeat_private.event_baselines values(mid) on conflict do nothing;
  perform public.futbeat_publish_live_state(p_provider,c->>'externalMatchId');
 end loop;
 return result||jsonb_build_object('suppressedByCanonicalTerminal',jsonb_array_length(suppressed)>0,
   'suppressed',suppressed);
end $$;

-- Public realtime (copied from 20260926030000). Changed: retracted rows are
-- excluded and the current score is authoritative for synthetic goals.
create or replace function public.futbeat_publish_live_state(p_provider text,p_external_match_id text)
returns void language plpgsql security definer set search_path='' as $$
declare s futbeat_private.live_match_state; ev jsonb; m jsonb;
begin
 select * into s from futbeat_private.live_match_state where provider=p_provider and external_match_id=p_external_match_id;
 if not found or s.canonical_match_id is null then return; end if;
 -- #120 defense in depth: never expose a non-terminal realtime state for an
 -- effectively terminal match, and drop one already exposed. Canonical data,
 -- provider observations and canonical events are untouched.
 if not futbeat_private.is_terminal_match_status(s.status)
   and futbeat_private.match_effectively_terminal(s.canonical_match_id) then
  delete from public.live_match_updates
   where match_id=s.canonical_match_id
     and not futbeat_private.is_terminal_match_status(status);
  return;
 end if;
 select coalesce(jsonb_agg(payload order by coalesce((payload->>'minute')::int,0),id),'[]') into ev
 from futbeat_private.canonical_events where match_id=s.canonical_match_id and provider=p_provider
   and retracted_at is null;
 -- #121: open clients get the same deduplicated visible events as the read model.
 select payload into m from futbeat_private.entities where id=s.canonical_match_id and kind='match';
 ev:=futbeat_private.visible_match_events(ev,m->>'homeTeamId',m->>'awayTeamId',
   jsonb_build_object('home',s.home_score,'away',s.away_score));
 insert into public.live_match_updates(match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at)
 values(s.canonical_match_id,s.provider,s.external_match_id,s.status,s.minute,s.home_score,s.away_score,s.revision,jsonb_array_length(ev),ev,s.changed_at,now())
 on conflict(match_id) do update set provider=excluded.provider,external_match_id=excluded.external_match_id,
 status=excluded.status,minute=excluded.minute,home_score=excluded.home_score,away_score=excluded.away_score,
 revision=excluded.revision,event_count=excluded.event_count,latest_events=excluded.latest_events,
 changed_at=excluded.changed_at,updated_at=excluded.updated_at;
end $$;

-- ---------------------------------------------------------------------------
-- Read model (copied from 20260926100000). Changed only in the events block:
-- canonical_events is the source for every id it owns (retracted rows
-- excluded, raw payload copies of those ids ignored), the score is
-- authoritative for synthetic goals and scoreMismatch flags more rich goals
-- than the score.
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

-- GOAL rows of one side in a stored detail events list (same classification
-- as _shared/match_detail.ts, own goals credited to the other side).
create or replace function futbeat_private.detail_side_goals(p_events jsonb,p_side text)
returns integer language sql immutable set search_path='' as $$
  select count(*)::integer from (
    select upper(coalesce(r->>'type','')) t,
      case when coalesce(nullif(btrim(r->>'homeScorer'),''),nullif(btrim(r->>'homeScorerId'),''),
          nullif(btrim(r->>'homeAssist'),'')) is not null then 'home'
        when coalesce(nullif(btrim(r->>'awayScorer'),''),nullif(btrim(r->>'awayScorerId'),''),
          nullif(btrim(r->>'awayAssist'),'')) is not null then 'away' end side,
      coalesce(r->>'isOwnGoal','')='true' or coalesce(r->>'ownGoal','')='true'
        or upper(coalesce(r->>'type','')) ~ '(^|[^A-Z])OWN' own
    from jsonb_array_elements(case when jsonb_typeof(p_events)='array' then p_events else '[]'::jsonb end) r
    where jsonb_typeof(r)='object'
  ) x
  where t like '%GOAL%' and not (t like '%MISSED%' and t like '%PENAL%') and t not like '%VAR%'
    and case when own then case side when 'home' then 'away' when 'away' then 'home' end else side end=p_side
$$;

-- ---------------------------------------------------------------------------
-- Match detail storage (copied from 20260923020000). Changed only for
-- events / cards / substitutions: a present array (even shorter or empty:
-- an annulled goal, a deleted card) replaces the stored one; the stored one
-- is kept only when the newer answer omits the key or it is not an array,
-- or (events) when the shorter list drops goals the score still requires.
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
         and v_new_count<coalesce(futbeat_private.safe_result_integer(v_merged->>(v_key||'TeamScore')),0) then
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

-- ---------------------------------------------------------------------------
-- Pre-send revalidation (copied from 20260928100000). Changed: pending rows
-- of a retracted event are cancelled.
-- ---------------------------------------------------------------------------
create or replace function public.futbeat_claim_notifications(
  p_mode text default 'dry_run',
  p_limit int default 20
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;

  update futbeat_private.notification_outbox
  set state='uncertain',finished_at=now()
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      m.payload as match,
      e.retracted_at as event_retracted_at,
      e.retraction_reason as event_retraction_reason
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.canonical_events e
      on e.id=o.event_id
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (p_mode='live' or d.transport='test')
    order by o.created_at
    for update of o skip locked
    limit least(greatest(p_limit,1),100)
  loop
    -- Any subject carried by the message (#106 player alerts, news,
    -- transfers, lineups) that is still followed keeps the row.
    select exists(
      select 1
      from futbeat_private.push_follows f
      join lateral jsonb_array_elements(
        coalesce(row.message->'subjectRefs','[]'::jsonb)
      ) ref on true
      where f.user_id=row.user_id
        and f.entity_type=ref->>'type'
        and f.entity_id=ref->>'id'
    )
    into still_following;

    if row.event_id is not null and not still_following then
      select exists(
        select 1
        from futbeat_private.push_follows f
        where f.user_id=row.user_id
          and (
            f.entity_id=row.message->>'matchId'
            or (
              row.match is not null
              and f.entity_id in (
                row.match->>'homeTeamId',
                row.match->>'awayTeamId'
              )
            )
          )
      )
      into still_following;
    end if;

    -- P0-A: an event retracted before dispatch (annulled goal, deleted card,
    -- score decrease) is never sent; a correction's twin keeps its push.
    if not row.enabled or not coalesce(still_following,false)
       or (row.event_retracted_at is not null
         and coalesce(row.event_retraction_reason,'') not in ('corrected','superseded','legacy_superseded')) then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now()
      where id=row.id;
      continue;
    end if;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now()
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'attemptId',attempt,
        'transport',row.transport,
        'token',row.token,
        'message',row.message
      )
    );
  end loop;

  return rows;
end
$$;

-- ---------------------------------------------------------------------------
-- Legacy repair (one time, audited, nothing deleted): several active rich
-- canonical rows carrying the same upstream key of one provider keep the
-- most recent one. Rows without a key reconcile on the next complete
-- observation of their match (pass 3 of record_live_events).
-- ---------------------------------------------------------------------------
do $$ declare r record; begin
 for r in
  select id from (
    select id,row_number() over(partition by match_id,provider,payload->>'providerEventKey'
      order by first_seen_at desc,id desc) rn
    from futbeat_private.canonical_events
    where nullif(payload->>'providerEventKey','') is not null and retracted_at is null
      and not futbeat_private.is_phase_event(event_type)
      and not futbeat_private.is_synthetic_event(payload)
  ) ranked where rn>1
 loop
  perform futbeat_private.retract_canonical_event(r.id,now(),'legacy_superseded');
 end loop;
end $$;

do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='futbeat_private' and p.proname in
   ('live_event_section','event_team_ordinal','dedupe_match_events','visible_match_events',
    'event_score_mismatch','event_already_known','event_correction_twin',
    'retract_canonical_event','live_event_content','detail_side_goals','events_equivalent',
    'merge_event_evidence','store_canonical_event','record_live_batch_core','record_live_events',
    'synthesize_goal_from_score_change','store_match_detail_before_media')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
end $$;

notify pgrst,'reload schema';
