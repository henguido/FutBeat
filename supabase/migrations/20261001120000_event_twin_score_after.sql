-- Correction twins decided by the score after the goal. Local only: no
-- provider calls, no cron, no ledger.
--
-- With content-keyed GOAL rows (20260930140000) a corrected goal (minute,
-- scorer, assist) is retract + add; store_canonical_event pairs the new row
-- with the retracted one (event_correction_twin: one push per goal). When the
-- same answer also lists a genuinely new goal of the same team close to it,
-- the new goal could claim the retracted row (same player, closer minute, or
-- key order on a tie): the new goal never pushed while the corrected one
-- pushed again (adversarial review P2: correction 10'->14' + a brace at 11';
-- scorer + minute corrected + a team-mate scoring nearby; a tie decided by
-- key order; an annulment + a rewritten score + the same player scoring
-- later).
--
-- The score after the goal tells them apart: a correction keeps (or, after
-- an annulment, lowers) its team's tally; a new goal raises it. Changed here:
--   * event_correction_twin: a GOAL whose team tally after it is above the
--     retracted row's (same team, both scores known) is a new goal, never a
--     correction, unless it is the same occurrence (same team, same player,
--     compatible minute: an earlier goal listed late or reinstated by VAR
--     legitimately raises the score-after of the later ones); among
--     candidates the same score-after is preferred right after the same
--     player;
--   * record_live_events pass 2: rows first seen in this observation are
--     ordered by their best ELIGIBLE twin, an equal score-after weighing
--     more than the minute distance (but less than the same player), so a
--     correction claims its row before a new goal can.
--
-- Unchanged: matching without score-after (legacy rows, cards,
-- substitutions) behaves exactly as before; push rules, ids, keys, score
-- semantics.

-- Goals of one team in a score object ({home, away}); null when the team is
-- neither side or the value is not an integer.
create or replace function futbeat_private.team_goals_in_score(p_score jsonb,p_team text,p_home text,p_away text)
returns integer language sql immutable set search_path='' as $$
  select case when jsonb_typeof(p_score)<>'object' or p_team is null then null
    when p_team=p_home then futbeat_private.safe_result_integer(p_score->>'home')
    when p_team=p_away then futbeat_private.safe_result_integer(p_score->>'away') end
$$;

-- True when an event of team p_team with score-after p_score cannot be a
-- correction of the retracted row p_old: same team, both scores known, and
-- the team has more goals after it than after p_old (a new goal).
create or replace function futbeat_private.event_raises_team_tally(p_score jsonb,p_team text,p_old jsonb,p_home text,p_away text)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(p_team=p_old->>'teamId'
    and futbeat_private.team_goals_in_score(p_score,p_team,p_home,p_away)
      >futbeat_private.team_goals_in_score(p_old->'score',p_team,p_home,p_away),false)
$$;

-- ---------------------------------------------------------------------------
-- Copied from 20260930100000 (verbatim). Changed only: a new goal (raises
-- its team tally) is never a twin; the same score-after is preferred.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.event_correction_twin(ev jsonb,p_at timestamptz)
returns text language sql stable security invoker set search_path='' as $$
  select c.id from futbeat_private.canonical_events c
  -- CHANGED (20261001120000): the match sides, to read each team's tally.
  left join futbeat_private.entities mt on mt.id=ev->>'matchId' and mt.kind='match'
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
    -- CHANGED (20261001120000): a goal that raises its team tally above the retracted row's
    -- is a new goal, not its correction; unless it is the same occurrence
    -- (same team, same player, compatible minute: an earlier goal listed
    -- late or reinstated rewrote its score-after upward).
    and (not futbeat_private.event_raises_team_tally(ev->'score',ev->>'teamId',c.payload,
        mt.payload->>'homeTeamId',mt.payload->>'awayTeamId')
      or (nullif(c.payload->>'playerId','') is not null and c.payload->>'playerId'=ev->>'playerId'
        and c.payload->>'teamId' is not distinct from ev->>'teamId'
        and futbeat_private.event_minutes_compatible(c.payload,ev)))
  order by (c.payload->>'playerId' is not distinct from ev->>'playerId') desc,
    -- CHANGED (20261001120000): a correction keeps its score-after.
    coalesce(futbeat_private.event_score_after(c.payload)=futbeat_private.event_score_after(ev),false) desc,
    abs(coalesce(futbeat_private.event_minute_value(c.payload),999)-coalesce(futbeat_private.event_minute_value(ev),0)),c.id
  limit 1
$$;

-- ---------------------------------------------------------------------------
-- LIVE -> canonical. Copied from 20261001110000 (verbatim). Changed only in
-- the pass 2 order (see header).
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
            -- CHANGED (20261001120000): a correction keeps its score-after;
            -- worth more than the minute distance, less than the same player.
            +case when jsonb_typeof(le.payload->'scoreAfter')='object'
                and futbeat_private.event_score_after(x.payload)
                  =futbeat_private.event_score_after(jsonb_build_object('score',le.payload->'scoreAfter')) then 0 else 500 end
            +abs(coalesce(futbeat_private.event_minute_value(x.payload),999)-coalesce(le.minute,0)))
        from futbeat_private.canonical_events x
        left join futbeat_private.provider_entities pp
          on pp.provider=p_provider and pp.kind='player' and pp.external_id=le.player_external_id
        left join futbeat_private.provider_entities pt
          on pt.provider=p_provider and pt.kind='team' and pt.external_id=le.team_external_id
        where x.match_id=mid and x.event_type=le.event_type and x.retracted_at=p_received_at
          and coalesce(x.retraction_reason,'') in ('provider_retracted','absent_from_snapshot','superseded')
          and (x.payload->>'teamId' is not distinct from pt.canonical_id
            or (nullif(x.payload->>'playerId','') is not null and x.payload->>'playerId'=pp.canonical_id))
          -- CHANGED (20261001120000): only rows it may correct (the same rule
          -- as event_correction_twin): a new goal sorts with the new rows;
          -- the same occurrence (team, player, minute) always may.
          and (not futbeat_private.event_raises_team_tally(le.payload->'scoreAfter',pt.canonical_id,x.payload,
              m->>'homeTeamId',m->>'awayTeamId')
            or (nullif(x.payload->>'playerId','') is not null and x.payload->>'playerId'=pp.canonical_id
              and x.payload->>'teamId' is not distinct from pt.canonical_id
              and futbeat_private.event_minutes_compatible(x.payload,jsonb_build_object('minute',le.minute,
                'extraMinute',coalesce(le.payload->'extraMinute',le.payload#>'{payload,time,extra}')))))) end nulls last,
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
 where n.nspname='futbeat_private' and p.proname in ('team_goals_in_score','event_raises_team_tally','event_correction_twin','record_live_events')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
end $$;

notify pgrst,'reload schema';
