-- Penalty shoot-out kicks stored as canonical GOAL events (timeline "goals"
-- at 1', 2', 3'..., inflated goal counts). Local only: no provider calls,
-- no cron, no ledger.
--
-- Measured in production (read-only, 2026-10-01): after AFTER_PEN GOAL lists
-- every scored shoot-out kick in events[] as a plain "goal" row, in the live
-- list and in the match detail alike: scoreInfoTime 'Penalty', info
-- 'Penalty', time = kick round (1, 2, ...), score = shoot-out tally. A
-- penalty scored during the match is info 'Penalty' with scoreInfoTime
-- '1st Half' / '2nd Half' / 'Extra Time' and stays a goal. 216 kick rows in
-- live_events (27 fixtures), 113 active canonical GOAL rows derived from
-- them (23 matches), none pushed.
--
-- Fixed here (the worker normalizers skip kicks too: _shared/live_events.ts
-- isShootoutKickRow, _shared/match_detail.ts):
--   * record_live_events never turns a kick row into a canonical event, even
--     when an older worker still sends it (a complete answer then retracts a
--     kick row stored before, 'absent_from_snapshot'), and kicks never count
--     as goals in the re-keyed-copy score guard;
--   * record_live_batch_core: kicks never count as goals of their team in
--     the GOAL snapshot-replace guard / trim (a transient omission of a real
--     goal never retracts it while a kick is kept); an unlisted kick follows
--     the path rule (retracted by a complete answer);
--   * detail_side_goals (the match detail score guard) ignores kicks.
--
-- Unchanged: score semantics (goal_fixture_score), push rules, keys / ids.
-- Rows already stored: supabase/manual/20261001110000_shootout_kicks_cleanup.sql
-- (separate, dry-run first; this migration never rewrites existing data).

-- A raw GOAL events[] row of the penalty shoot-out phase. Identical to
-- _shared/live_events.ts isShootoutKickRow: the phase (scoreInfoTime)
-- decides, never info; exact values only (case, spaces, '-' and '_'
-- ignored): Penalty, Penalties, Penalty Shootout, Penalties Shootout,
-- Shootout. Anything else (e.g. 'Penalty (Extra Time)', a translation) stays
-- a goal: losing a real goal is worse than showing a kick.
create or replace function futbeat_private.is_shootout_kick_row(p_row jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(jsonb_typeof(p_row)='object'
    and regexp_replace(upper(btrim(coalesce(p_row->>'scoreInfoTime',''))),'[[:space:]_-]+','','g')
      ~ '^((PENALTY|PENALTIES)(SHOOTOUT)?|SHOOTOUT)$',false)
$$;

-- ---------------------------------------------------------------------------
-- Copied from 20260930100000 (verbatim). Changed only: shoot-out kicks are
-- not goals of either side.
-- ---------------------------------------------------------------------------
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
      -- CHANGED: a shoot-out kick is not a goal.
      and not futbeat_private.is_shootout_kick_row(r)
  ) x
  where t like '%GOAL%' and not (t like '%MISSED%' and t like '%PENAL%') and t not like '%VAR%'
    and case when own then case side when 'home' then 'away' when 'away' then 'home' end else side end=p_side
$$;

-- ---------------------------------------------------------------------------
-- Change detection core. Copied from 20260930100000 (verbatim). Changed only
-- in the GOAL snapshot-replace: a shoot-out kick row never counts as a goal
-- of its team (score guard / trim) and, unlisted from a complete answer, is
-- retracted by the path rule like any non-goal row.
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
             and event_type = 'GOAL' and team_external_id = v_team_ext and retracted_at is null
             -- CHANGED: a shoot-out kick is not a goal of its team.
             and not futbeat_private.is_shootout_kick_row(payload -> 'payload');
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
           -- CHANGED: a shoot-out kick follows the path rule (never a goal).
           when event_type = 'GOAL' and team_external_id is not null
             and not futbeat_private.is_shootout_kick_row(payload -> 'payload')
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
-- LIVE -> canonical. Copied from 20260930140000 (verbatim). Changed only in
-- pass 2: a shoot-out kick row is never a canonical event and never counts as
-- a goal of its team.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.record_live_events(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; c jsonb; m jsonb; mid text; e record; tid text; pid text; aid text;
 ev jsonb; eid text; can_notify boolean; baseline boolean; typ text; state futbeat_private.live_match_state;
 obs jsonb; kept jsonb:='[]'; suppressed jsonb:='[]'; v_ext text; v_status text; v_claimed text;
 v_hit text; v_obs jsonb; v_sections text[]; v_backed text[]; r record; v_key text; v_dup text; v_content text;
 v_team_goals integer; v_team_score integer; v_dups jsonb;
 v_goal_counts jsonb; -- CHANGED: active goals per team, counted once per match
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
  -- CHANGED: active live goals per team, shoot-out kicks excluded. Counted
  -- once per match (pass 2 never changes live_events) instead of once per
  -- re-keyed copy.
  select coalesce(jsonb_object_agg(x.t,x.n),'{}') into v_goal_counts
    from (select o.team_external_id t,count(*) n from futbeat_private.live_events o
      where o.provider=p_provider and o.external_match_id=c->>'externalMatchId'
        and o.event_type='GOAL' and o.retracted_at is null and o.team_external_id is not null
        and not futbeat_private.is_shootout_kick_row(o.payload->'payload')
      group by o.team_external_id) x;
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
  -- CHANGED: rows first seen in this observation are ordered by how well
  -- they match a row this observation retracted (same player first, then the
  -- closest minute), so each correction claims its own twin before a
  -- genuinely new event of the same team can (store_canonical_event pairs
  -- greedily). With content keys a correction (assist, minute) is a new key:
  -- by key order alone a new goal could take the twin and lose its push
  -- while the corrected goal pushed again.
  for e in select le.* from futbeat_private.live_events le where le.provider=p_provider and le.external_match_id=c->>'externalMatchId'
    and le.retracted_at is null
    order by le.first_seen_at=p_received_at,
      case when le.first_seen_at=p_received_at then (
        select min(case when nullif(x.payload->>'playerId','') is not null and x.payload->>'playerId'=pp.canonical_id then 0 else 1000 end
            +abs(coalesce(futbeat_private.event_minute_value(x.payload),999)-coalesce(le.minute,0)))
        from futbeat_private.canonical_events x
        left join futbeat_private.provider_entities pp
          on pp.provider=p_provider and pp.kind='player' and pp.external_id=le.player_external_id
        left join futbeat_private.provider_entities pt
          on pt.provider=p_provider and pt.kind='team' and pt.external_id=le.team_external_id
        where x.match_id=mid and x.event_type=le.event_type and x.retracted_at=p_received_at
          and coalesce(x.retraction_reason,'') in ('provider_retracted','absent_from_snapshot','superseded')
          and (x.payload->>'teamId' is not distinct from pt.canonical_id
            or (nullif(x.payload->>'playerId','') is not null and x.payload->>'playerId'=pp.canonical_id))) end nulls last,
      le.first_seen_at,le.event_key loop
   if e.event_type not in ('GOAL','YELLOW_CARD','RED_CARD','SUBSTITUTION','VAR','MISSED_PENALTY') then continue; end if;
   -- CHANGED: a shoot-out kick (sent by a worker older than the
   -- isShootoutKickRow normalizer) is not a match event: never stored, never
   -- backed (a complete answer retracts a kick row stored before).
   if futbeat_private.is_shootout_kick_row(e.payload->'payload') then continue; end if;
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
     -- CHANGED: the per-match count (kicks excluded, see v_goal_counts).
     v_team_goals:=coalesce((v_goal_counts->>e.team_external_id)::integer,0);
     if v_team_score is null
        or v_team_goals-coalesce((v_dups->>coalesce(tid,''))::integer,0)-1<v_team_score then
      v_dup:=null;
     else
      v_dups:=v_dups||jsonb_build_object(coalesce(tid,''),coalesce((v_dups->>coalesce(tid,''))::integer,0)+1);
     end if;
    end if;
   end if;
   -- CHANGED: a copy is that occurrence, not a row of its own. The content
   -- row it copies backs it; a copy stored before this fix is retracted
   -- (audited, never a correction twin: its reason is not one of theirs).
   if v_dup is not null then
    for r in select id from futbeat_private.canonical_events
      where match_id=mid and provider=p_provider and payload->>'providerEventKey'=v_key
        and id<>v_dup and retracted_at is null loop
     perform futbeat_private.retract_canonical_event(r.id,p_received_at,'duplicate_upstream_key');
    end loop;
    v_backed:=v_backed||v_dup;
    continue;
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

-- create or replace keeps the existing privileges; restated defensively.
do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='futbeat_private' and p.proname in ('is_shootout_kick_row','detail_side_goals','record_live_batch_core','record_live_events')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
end $$;

notify pgrst,'reload schema';
