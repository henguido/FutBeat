-- Notifications v2 (server). Local only: no provider calls, no cron change,
-- no push mode / secret change (production stays dry_run until the owner
-- configures Firebase and flips FUTBEAT_PUSH_MODE / push_settings.mode).
--
-- Approved pushes (everything else is stored for the timeline, never pushed):
--   match / team followers: match start (KICKOFF), goal, goal annulled,
--     red card, final (FULL_TIME);
--   player followers (free, no entitlement): goal / assist, red card,
--     comes on, goes off, official starter, official bench.
--   Stopped: halftime, yellow cards, VAR, missed penalty and team-level
--   substitutions (not kept behind a switch: one less code path; turning one
--   back on is one CASE branch in store_canonical_event). Content pushes
--   (NEWS, TRANSFER) are unchanged.
--   A goal correction (correction twin) keeps the original push: no new one.
--
-- Changes (existing definitions are based on their latest migration):
--   1. event_message (20260916161141): body, collapseKey, "Local vs Visitante"
--      match start title.
--   2. store_canonical_event (20260930100000): approved types and the new
--      preferences gate the player and match/team fan-out.
--   3. record_live_events (20261001120000): KICKOFF may push on the first
--      observation when fresh (kickoff_push_is_fresh), and only when fresh.
--   4. note_lineup_alerts (20260928100000): notify_player_starter /
--      notify_player_bench; body + collapseKey.
--   5. futbeat_claim_notifications_v2 (20260930100000): send-time age check
--      (matchPushMaxDelayMinutes, lineups after kickoff +
--      lineupAlertLateMinutes), types no longer approved are cancelled,
--      GOAL_ANNULLED and preference revalidation; claim reports scanned rows.
--   6. futbeat_finish_notification (20260916161141): a dead token receipt
--      (FCM UNREGISTERED, APNs 410) disables the device.
--   7. GOAL_ANNULLED: deferred constraint trigger on canonical_events ->
--      enqueue_goal_annulled (only devices whose goal push was delivered).
--   8. futbeat_register_push (20260916161141): a token owned by another
--      user / installation moves to the caller (shared phone).
--   9. Preferences: 6 new columns (default true), read_user_profile
--      (20260918134500) returns them, futbeat_sync_user_profile_v3(jsonb)
--      partial update. Older RPCs retain their signature; a preference trigger
--      keeps the legacy cards switch and red-card switch aligned.

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
alter table futbeat_private.user_preferences
  add column if not exists notify_red_cards boolean not null default true,
  add column if not exists notify_goal_annulled boolean not null default true,
  add column if not exists notify_player_starter boolean not null default true,
  add column if not exists notify_player_bench boolean not null default true,
  add column if not exists notify_player_sub_in boolean not null default true,
  add column if not exists notify_player_sub_out boolean not null default true;

-- Carry legacy opt-outs into the new role-specific switches before the v3
-- profile can report them; otherwise a legacy false would look enabled in
-- the app but still be gated at delivery.
update futbeat_private.user_preferences
set notify_red_cards=notify_cards,
    notify_player_starter=notify_lineups,
    notify_player_bench=notify_lineups;

alter table futbeat_private.push_devices
  add column if not exists disabled_at timestamptz,
  add column if not exists disabled_reason text;

alter table futbeat_private.notification_outbox
  add column if not exists attempt_token text,
  add column if not exists transport_started_at timestamptz;

create index if not exists outbox_event_idx on futbeat_private.notification_outbox(event_id)
  where event_id is not null;

-- ---------------------------------------------------------------------------
-- 1. Message (copied from 20260916161141). NOTIFICATIONS V2: body (score
-- line), collapseKey (one notification slot per event: a GOAL_ANNULLED of the
-- same event replaces it), match start titled "Local vs Visitante".
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.event_message(ev jsonb, m jsonb) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare label text; team text; home_name text; away_name text; title text;
 body text; v_score jsonb; -- NOTIFICATIONS V2
begin
 label := case ev->>'type' when 'GOAL' then '⚽' when 'YELLOW_CARD' then '🟨'
 when 'RED_CARD' then '🟥' when 'SUBSTITUTION' then '🔄' when 'VAR' then '📺'
 when 'MISSED_PENALTY' then '❌' when 'KICKOFF' then '▶' when 'HALFTIME' then '⏸'
 when 'FULL_TIME' then '🏁' end;
 if label is null then return null; end if;
 select payload->>'name' into team from futbeat_private.entities where id=ev->>'teamId' and kind='team';
 title := label || case when ev->>'minute' is not null then ' '||(ev->>'minute')||chr(39) else '' end || ' ' ||
 case ev->>'type' when 'GOAL' then 'Gol' when 'YELLOW_CARD' then 'Tarjeta amarilla'
 when 'RED_CARD' then 'Tarjeta roja' when 'SUBSTITUTION' then 'Sustitución'
 when 'VAR' then 'VAR' when 'MISSED_PENALTY' then 'Penal fallado'
 when 'KICKOFF' then 'Inicio' when 'HALFTIME' then 'Medio tiempo' when 'FULL_TIME' then 'Final' end;
 -- NOTIFICATIONS V2: names are read for every type (body).
 select payload->>'name' into home_name from futbeat_private.entities where id=m->>'homeTeamId';
 select payload->>'name' into away_name from futbeat_private.entities where id=m->>'awayTeamId';
 if ev->>'type'='FULL_TIME' then
  title := '🏁 Final';
  if home_name is not null and away_name is not null and ev#>>'{score,home}' is not null and ev#>>'{score,away}' is not null then
   title:=title||' — '||home_name||' '||(ev#>>'{score,home}')||'-'||(ev#>>'{score,away}')||' '||away_name;
  end if;
 elsif team is not null then title:=title||' — '||team;
 end if;
 -- NOTIFICATIONS V2: match start and score body.
 v_score:=case when jsonb_typeof(ev->'score')='object' then ev->'score' end;
 if v_score is null or v_score->>'home' is null or v_score->>'away' is null then
  select jsonb_build_object('home',s.home_score,'away',s.away_score) into v_score
  from futbeat_private.live_match_state s
  where s.canonical_match_id=ev->>'matchId'
  order by s.last_seen_at desc limit 1;
 end if;
 if ev->>'type'='KICKOFF' then
  if home_name is not null and away_name is not null then title:='▶ '||home_name||' vs '||away_name; end if;
  body:='Comienza el partido';
 elsif ev->>'type'='FULL_TIME' then
  body:='Resultado final';
 elsif home_name is not null and away_name is not null then
  body:=home_name||coalesce(' '||(v_score->>'home')||'-'||(v_score->>'away')||' ',' vs ')||away_name;
 end if;
 return jsonb_strip_nulls(jsonb_build_object('title',title,'body',body,'eventId',ev->>'id','matchId',ev->>'matchId',
   'type',ev->>'type','collapseKey',ev->>'id'));
end $$;

-- True when a KICKOFF observed at p_at is a fresh match start: in play, at
-- most kickoffPushMaxMinute (10) played, received within
-- kickoffPushWindowMinutes (15) of the scheduled kickoff (and not before
-- kickoffPushEarlyMinutes (5) earlier), recent (not a replay / backfill),
-- and the match is not over.
create or replace function futbeat_private.kickoff_push_is_fresh(
  p_match_id text,m jsonb,p_status text,p_minute integer,p_at timestamptz)
returns boolean language sql stable security definer set search_path='' as $$
  select p_status='LIVE'
    and coalesce(p_minute,0)<=futbeat_private.quota_setting('goal_api','kickoffPushMaxMinute',10)
    and p_at>=now()-make_interval(mins=>futbeat_private.quota_setting('goal_api','kickoffPushWindowMinutes',15)::integer)
    and coalesce(
      p_at<=futbeat_private.try_timestamptz(m->>'startTime')
          +make_interval(mins=>futbeat_private.quota_setting('goal_api','kickoffPushWindowMinutes',15)::integer)
      and p_at>=futbeat_private.try_timestamptz(m->>'startTime')
          -make_interval(mins=>futbeat_private.quota_setting('goal_api','kickoffPushEarlyMinutes',5)::integer),
      false)
    and not futbeat_private.match_effectively_terminal(p_match_id)
$$;

-- ---------------------------------------------------------------------------
-- 2. Store (copied verbatim from 20260930100000_event_reconciliation.sql).
-- NOTIFICATIONS V2: approved types and the new preferences gate the fan-out.
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
        -- NOTIFICATIONS V2: approved player alerts only (goal / assist, red
        -- card, goes off, comes on); yellow card and missed penalty stopped.
        and case
          when ev->>'type'='GOAL' then coalesce(p.notify_goals,true)
          when ev->>'type'='RED_CARD' and involved.role='primary'
            then coalesce(p.notify_red_cards,true) and coalesce(p.notify_cards,true)
          when ev->>'type'='SUBSTITUTION' and involved.role='primary' then coalesce(p.notify_player_sub_out,true)
          when ev->>'type'='SUBSTITUTION' and involved.role='assist' then coalesce(p.notify_player_sub_in,true)
          else false
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
    -- NOTIFICATIONS V2: approved match / team pushes only (halftime, yellow
    -- card, VAR, missed penalty and team-level substitutions stopped).
    and case ev->>'type'
      when 'KICKOFF' then coalesce(p.notify_kickoff,true)
      when 'GOAL' then coalesce(p.notify_goals,true)
      when 'FULL_TIME' then coalesce(p.notify_final,true)
      when 'RED_CARD' then coalesce(p.notify_red_cards,true) and coalesce(p.notify_cards,true)
      else false
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
-- 3. LIVE -> canonical (copied verbatim from 20261001120000_event_twin_score_after.sql).
-- NOTIFICATIONS V2: only the phase-event push decision (KICKOFF freshness).
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
   -- NOTIFICATIONS V2: a match start pushes only when fresh, also on the
   -- first observation of the match (no baseline yet); a replay finds the
   -- stored KICKOFF and never pushes again.
   perform futbeat_private.store_canonical_event(ev,p_provider,
    case when typ='KICKOFF' then (can_notify or not baseline)
      and futbeat_private.kickoff_push_is_fresh(mid,m,state.status,state.minute,p_received_at)
     else can_notify end,
    p_received_at,m);
  end if;
  insert into futbeat_private.event_baselines values(mid) on conflict do nothing;
  perform public.futbeat_publish_live_state(p_provider,c->>'externalMatchId');
 end loop;
 return result||jsonb_build_object('suppressedByCanonicalTerminal',jsonb_array_length(suppressed)>0,
   'suppressed',suppressed);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Official lineups (copied verbatim from 20260928100000_free_player_alerts.sql).
-- NOTIFICATIONS V2: starter / bench switches; body + collapseKey.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.note_lineup_alerts(
  p_match_id text,p_payload jsonb,p_fetched_at timestamptz)
returns integer language plpgsql security definer set search_path='' as $$
declare
  v_match jsonb; v_kickoff timestamptz; v_official_window boolean;
  v_complete text[]; r record; v_pid text; v_state futbeat_private.lineup_player_alerts;
  v_official boolean; v_name text; v_team text; v_key text; v_msg jsonb; v_sent integer:=0;
begin
  select payload into v_match from futbeat_private.entities where id=p_match_id and kind='match';
  v_kickoff:=nullif(v_match->>'startTime','')::timestamptz;
  if v_kickoff is null or p_payload is null then return 0; end if;
  -- Official only inside the lineup window, for a fresh observation of a
  -- match that is not over. Earlier = probable; later / replayed = history.
  v_official_window:=p_fetched_at>=v_kickoff-make_interval(mins=>futbeat_private.quota_setting(
      'goal_api','officialLineupMinutes',75)::integer)
    and p_fetched_at<=v_kickoff+make_interval(mins=>futbeat_private.quota_setting(
      'goal_api','lineupAlertLateMinutes',20)::integer)
    and p_fetched_at>=now()-interval '30 minutes'
    and not futbeat_private.match_effectively_terminal(p_match_id);
  -- A side is official only with a complete XI.
  select coalesce(array_agg(side),'{}') into v_complete from (
    select side from futbeat_private.lineup_player_roles(p_payload)
    where role='starter' and side in ('home','away') and external_id is not null
    group by side having count(distinct external_id)>=11) s;

  for r in
    select distinct on (x.external_id) x.side,x.role,x.external_id
    from futbeat_private.lineup_player_roles(p_payload) x
    where x.external_id is not null and x.side in ('home','away')
    order by x.external_id,(x.role='starter') desc
  loop
    -- Canonical identity only (never a name).
    select futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id) into v_pid
    from futbeat_private.provider_entities pe
    where pe.provider='goal_api' and pe.kind='player' and pe.external_id=r.external_id;
    continue when v_pid is null
      or not exists(select 1 from futbeat_private.entities e where e.id=v_pid and e.kind='player');
    v_official:=v_official_window and r.side=any(v_complete);

    insert into futbeat_private.lineup_player_alerts as a(
      match_id,player_id,role,official,first_seen_at,updated_at)
    values(p_match_id,v_pid,r.role,v_official,p_fetched_at,p_fetched_at)
    on conflict(match_id,player_id) do update set
      role=excluded.role,
      official=a.official or excluded.official,
      updated_at=greatest(a.updated_at,excluded.updated_at)
    where excluded.updated_at>=a.updated_at
    returning * into v_state;
    continue when v_state is null or not v_official;
    -- Once per role, and at most one correction (starter/bench storms).
    continue when r.role=any(v_state.notified_roles) or cardinality(v_state.notified_roles)>=2;

    select nullif(btrim(payload->>'name'),'') into v_name
    from futbeat_private.entities where id=v_pid and kind='player';
    continue when v_name is null;
    select payload->>'name' into v_team from futbeat_private.entities
    where id=futbeat_private.futbeat_resolve_entity_id('team',
      v_match->>case r.side when 'home' then 'homeTeamId' else 'awayTeamId' end);
    v_key:='lineup:'||p_match_id||':'||v_pid||':'||r.role;
    v_msg:=jsonb_build_object(
      'type','LINEUP',
      'title','📋 '||case r.role when 'starter' then v_name||' es titular'
        else v_name||' empieza en el banquillo' end||coalesce(' — '||v_team,''),
      'matchId',p_match_id,'playerId',v_pid,'playerRole',r.role,
      'subjectRefs',jsonb_build_array(jsonb_build_object('type','player','id',v_pid)))
      -- NOTIFICATIONS V2: body and one notification slot per player / match.
      ||jsonb_build_object('body','Alineación confirmada','collapseKey','lineup:'||p_match_id||':'||v_pid);
    insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message)
    select v_key,d.id,d.user_id,v_msg
    from futbeat_private.push_devices d
    left join futbeat_private.user_preferences p on p.user_id=d.user_id
    where d.enabled and d.registered_at<=p_fetched_at
      and coalesce(p.notify_lineups,true)
      -- NOTIFICATIONS V2: per-role switches.
      and case r.role when 'starter' then coalesce(p.notify_player_starter,true)
        else coalesce(p.notify_player_bench,true) end
      and exists(select 1 from futbeat_private.push_follows f
        where f.user_id=d.user_id and f.entity_type='player' and f.entity_id=v_pid
          and f.created_at<=p_fetched_at)
    on conflict(notification_key,user_id,device_id) do nothing;
    update futbeat_private.lineup_player_alerts
    set notified_roles=array_append(notified_roles,r.role)
    where match_id=p_match_id and player_id=v_pid;
    v_sent:=v_sent+1;
  end loop;
  return v_sent;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Pre-send revalidation (based on 20260930100000_event_reconciliation.sql).
-- NOTIFICATIONS V2: send-time age, approved types, GOAL_ANNULLED rows.
-- ---------------------------------------------------------------------------
create or replace function public.futbeat_claim_notifications_v2(
  p_mode text default 'dry_run',
  p_limit int default 20
) returns jsonb
language plpgsql
-- NOTIFICATIONS V2: definer (reads the policy settings and preferences);
-- still executable by service_role only.
security definer
set search_path=''
as $$
declare
  row record;
  rows jsonb:='[]';
  attempt uuid;
  still_following boolean;
  -- NOTIFICATIONS V2
  v_reason text;
  v_annul boolean;
  v_scanned integer:=0;
  v_push_mode text;
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_late interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','lineupAlertLateMinutes',20)::integer);
begin
  if p_mode not in ('dry_run','live') then
    raise exception 'Invalid mode';
  end if;
  select mode into v_push_mode from futbeat_private.push_settings where id=true;

  update futbeat_private.notification_outbox
  set state=case when transport_started_at is null then 'pending' else 'uncertain' end,
    finished_at=case when transport_started_at is null then null else now() end,
    attempt_id=case when transport_started_at is null then null else attempt_id end,
    attempt_token=case when transport_started_at is null then null else attempt_token end,
    attempt_at=case when transport_started_at is null then now() else attempt_at end,
    provider_receipt=case when transport_started_at is null then 'VALIDATION_RETRY' else provider_receipt end
  where state='sending'
    and attempt_at<now()-interval '5 minutes';

  for row in
    select
      o.*,
      d.transport,
      d.token,
      d.enabled,
      p.notify_kickoff,p.notify_goals,p.notify_final,p.notify_cards,p.notify_red_cards,
      p.notify_player_sub_out,p.notify_player_sub_in,p.notify_lineups,
      p.notify_player_starter,p.notify_player_bench,p.notify_goal_annulled,
      p.notify_news,p.notify_transfers,
      m.payload as match,
      e.retracted_at as event_retracted_at,
      e.retraction_reason as event_retraction_reason
    from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d
      on d.id=o.device_id and d.user_id=o.user_id
    left join futbeat_private.user_preferences p on p.user_id=o.user_id
    left join futbeat_private.canonical_events e
      -- NOTIFICATIONS V2: a GOAL_ANNULLED row reads its goal.
      on e.id=coalesce(o.event_id,o.message->>'annulsEventId')
    left join futbeat_private.entities m
      on m.id=e.match_id
    where o.state='pending'
      and (o.attempt_at is null or o.attempt_at<now()-interval '1 minute')
      and (d.transport='test' or (p_mode='live' and v_push_mode='live'))
      and not exists(select 1 from futbeat_private.notification_outbox active
        where active.device_id=o.device_id and active.id<>o.id and active.state='sending'
          and o.message ? 'collapseKey'
          and active.message->>'collapseKey'=o.message->>'collapseKey')
    order by o.created_at,o.id
    for update of o,d skip locked
    limit least(greatest(p_limit,1),100)
  loop
    v_scanned:=v_scanned+1;
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

    -- NOTIFICATIONS V2: a GOAL_ANNULLED row follows its match like the goal.
    v_annul:=row.event_id is null and row.message ? 'annulsEventId';
    if (row.event_id is not null or v_annul) and not still_following then
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
    -- NOTIFICATIONS V2: one cancellation decision with its reason (receipt).
    v_reason:=case
      when not row.enabled then 'device_disabled'
      when not coalesce(still_following,false) then 'unfollowed'
      when row.message->>'type'='KICKOFF' and not coalesce(row.notify_kickoff,true) then 'preference_disabled'
      when row.message->>'type'='GOAL' and not coalesce(row.notify_goals,true) then 'preference_disabled'
      when row.message->>'type'='FULL_TIME' and not coalesce(row.notify_final,true) then 'preference_disabled'
      when row.message->>'type'='RED_CARD' and not (coalesce(row.notify_red_cards,true) and coalesce(row.notify_cards,true)) then 'preference_disabled'
      when row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='primary'
        and not coalesce(row.notify_player_sub_out,true) then 'preference_disabled'
      when row.message->>'type'='SUBSTITUTION' and row.message->>'playerRole'='assist'
        and not coalesce(row.notify_player_sub_in,true) then 'preference_disabled'
      when row.message->>'type'='LINEUP' and not (coalesce(row.notify_lineups,true)
        and case row.message->>'playerRole' when 'starter' then coalesce(row.notify_player_starter,true)
          when 'bench' then coalesce(row.notify_player_bench,true) else false end) then 'preference_disabled'
      when row.message->>'type'='GOAL_ANNULLED' and not coalesce(row.notify_goal_annulled,true) then 'preference_disabled'
      when row.message->>'type'='NEWS' and not coalesce(row.notify_news,true) then 'preference_disabled'
      when row.message->>'type'='TRANSFER' and not coalesce(row.notify_transfers,true) then 'preference_disabled'
      when row.event_id is not null and row.event_retracted_at is not null
         and coalesce(row.event_retraction_reason,'') not in ('corrected','superseded','legacy_superseded') then 'retracted'
      -- Types no longer pushed (rows queued before this migration).
      when row.event_id is not null and not (row.message->>'type' in ('KICKOFF','GOAL','RED_CARD','FULL_TIME')
         or (row.message->>'type'='SUBSTITUTION' and row.message ? 'playerRole')) then 'type_disabled'
      when row.event_id is not null and row.message->>'type'='RED_CARD' and row.message ? 'playerRole'
         and row.message->>'playerRole'<>'primary' then 'type_disabled'
      -- An annulment whose goal came back, or whose goal push never left.
      when v_annul and row.event_retracted_at is null then 'restored'
      when v_annul and not exists(select 1 from futbeat_private.notification_outbox g
         where g.event_id=row.message->>'annulsEventId' and g.user_id=row.user_id and g.device_id=row.device_id
           and g.state in ('sent','simulated','uncertain','sending')) then 'goal_not_delivered'
      -- Send-time age: a late match push is worse than none.
      when (row.event_id is not null or v_annul) and row.created_at<now()-v_delay then 'expired'
      when row.notification_key like 'lineup:%' and now()>coalesce((
         select futbeat_private.try_timestamptz(x.payload->>'startTime') from futbeat_private.entities x
         where x.id=row.message->>'matchId' and x.kind='match'),'infinity'::timestamptz)+v_late then 'expired'
    end;
    if v_reason is not null then
      update futbeat_private.notification_outbox
      set state='cancelled',finished_at=now(),provider_receipt=v_reason
      where id=row.id;
      continue;
    end if;

    attempt:=gen_random_uuid();
    update futbeat_private.notification_outbox
    set state='sending',attempt_id=attempt,attempt_at=now(),
      attempt_token=row.token,transport_started_at=null
    where id=row.id;

    rows:=rows||jsonb_build_array(
      jsonb_build_object(
        'id',row.id,
        'deviceId',row.device_id,
        'attemptId',attempt,
        'transport',row.transport,
        'token',row.token,
        'message',row.message
      )
    );
  end loop;

  return jsonb_build_object('rows',rows,'scanned',v_scanned);
end
$$;

-- Keep the original array contract for older dispatchers during rollout.
-- They do not call the new mark-started RPC, so conservatively mark their
-- claims before returning them: a lost receipt must never requeue a send.
create or replace function public.futbeat_claim_notifications(p_mode text default 'dry_run',p_limit int default 20)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_rows jsonb;
begin
  v_claim:=public.futbeat_claim_notifications_v2(p_mode,p_limit);
  v_rows:=v_claim->'rows';
  update futbeat_private.notification_outbox o set transport_started_at=now()
  where o.id in (select (r.value->>'id')::uuid from jsonb_array_elements(v_rows) r)
    and o.state='sending';
  return v_rows;
end $$;

-- A claimed row may have been cancelled because its device was reassigned.
create or replace function public.futbeat_notification_attempt_valid(p_id uuid,p_attempt uuid,p_token text)
returns boolean language sql security definer set search_path='' as $$
  select exists(select 1 from futbeat_private.notification_outbox o
    join futbeat_private.push_devices d on d.id=o.device_id and d.user_id=o.user_id
    where o.id=p_id and o.attempt_id=p_attempt and o.state='sending'
      and d.enabled and d.token=p_token
      and (d.transport='test' or (select mode from futbeat_private.push_settings where id=true)='live'))
$$;

-- No provider request has begun if validation fails. A failed requeue RPC is
-- recovered by the stale-attempt sweep above (transport_started_at is null).
create or replace function public.futbeat_requeue_notification_attempt(p_id uuid,p_attempt uuid,p_reason text)
returns boolean language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  update futbeat_private.notification_outbox
  set state='pending',attempt_id=null,attempt_token=null,attempt_at=now(),
    transport_started_at=null,provider_receipt=left(p_reason,200)
  where id=p_id and attempt_id=p_attempt and state='sending';
  get diagnostics affected=row_count;
  return affected=1;
end $$;

-- Mark the boundary immediately before the transport call. A stale attempt
-- after this point is uncertain; before it, it is safe to retry.
create or replace function public.futbeat_mark_notification_send_started(p_id uuid,p_attempt uuid,p_token text)
returns boolean language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  update futbeat_private.notification_outbox o
  set transport_started_at=now()
  from futbeat_private.push_devices d
  where o.id=p_id and o.attempt_id=p_attempt and o.state='sending'
    and d.id=o.device_id and d.user_id=o.user_id and d.enabled and d.token=p_token
    and o.attempt_token=p_token
    and (d.transport='test' or (select mode from futbeat_private.push_settings where id=true)='live');
  get diagnostics affected=row_count;
  return affected=1;
end $$;

create or replace function public.futbeat_cancel_notification_attempt(p_id uuid,p_attempt uuid,p_reason text)
returns boolean language plpgsql security definer set search_path='' as $$
declare affected integer;
begin
  update futbeat_private.notification_outbox
  set state='cancelled',finished_at=now(),provider_receipt=left(p_reason,200)
  where id=p_id and attempt_id=p_attempt and state='sending';
  get diagnostics affected=row_count;
  return affected=1;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Delivery receipt (copied from 20260916161141). NOTIFICATIONS V2: a dead
-- token (FCM UNREGISTERED, APNs 410, as classified by
-- backend/notifications/transports.mjs) disables the device; the app
-- re-enables it by registering a fresh token. Security definer so the
-- service role needs no write grant on push_devices.
-- ---------------------------------------------------------------------------
create or replace function public.futbeat_finish_notification(p_id uuid,p_attempt uuid,p_state text,p_receipt text default null)
returns boolean language plpgsql security definer set search_path='' as $$
declare count_rows int;
 v_device uuid; -- NOTIFICATIONS V2
 v_disabled integer;
begin
 if p_state not in ('sent','simulated','failed','uncertain') then raise exception 'Invalid terminal state'; end if;
 update futbeat_private.notification_outbox set state=p_state,finished_at=now(),provider_receipt=left(p_receipt,200)
 where id=p_id and attempt_id=p_attempt and state='sending'
 returning device_id into v_device; -- NOTIFICATIONS V2
 get diagnostics count_rows=row_count;
 -- NOTIFICATIONS V2: dead token.
 if count_rows=1 and p_state='failed' and p_receipt in ('FCM_UNREGISTERED','APNS_UNREGISTERED') then
  update futbeat_private.push_devices set enabled=false,disabled_at=now(),disabled_reason=p_receipt
  where id=v_device and enabled and token=(
    select attempt_token from futbeat_private.notification_outbox where id=p_id);
  get diagnostics v_disabled=row_count;
  if v_disabled=1 then
   update futbeat_private.notification_outbox set state='cancelled',finished_at=now(),provider_receipt='device_disabled'
   where device_id=v_device and state='pending';
  end if;
 end if;
 return count_rows=1;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Goal annulled. A GOAL retracted for provider_retracted /
-- absent_from_snapshot / score_decrease (never corrected, superseded,
-- legacy_superseded, duplicate_upstream_key: those are not annulments) gets
-- one GOAL_ANNULLED push per device whose goal push was delivered (sent,
-- simulated, uncertain, or in flight), only while fresh: retracted within
-- matchPushMaxDelayMinutes and the goal push within goalAnnulledMaxMinutes
-- (30). A goal retracted before its push was sent is cancelled at claim and
-- produces no push at all. notification_key 'annul:<event_id>' makes it
-- idempotent; collapseKey = the goal's event id replaces the goal
-- notification on the phone. event_id stays null (the goal already owns the
-- (event_id,user_id,device_id) slot); message.annulsEventId links it.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.enqueue_goal_annulled(p_event_id text)
returns integer language plpgsql security definer set search_path='' as $$
declare c futbeat_private.canonical_events%rowtype; m jsonb; v_team text; v_home text; v_away text;
  v_score jsonb; v_body text; v_msg jsonb; v_n integer:=0;
  v_delay interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','matchPushMaxDelayMinutes',10)::integer);
  v_window interval:=make_interval(mins=>futbeat_private.quota_setting('goal_api','goalAnnulledMaxMinutes',30)::integer);
begin
  select * into c from futbeat_private.canonical_events where id=p_event_id;
  if not found or c.event_type<>'GOAL' or c.retracted_at is null
     or coalesce(c.retraction_reason,'') not in ('provider_retracted','absent_from_snapshot','score_decrease')
     or c.retracted_at<now()-v_delay then
    return 0;
  end if;
  select payload into m from futbeat_private.entities where id=c.match_id and kind='match';
  if m is null then return 0; end if;
  select payload->>'name' into v_team from futbeat_private.entities where id=c.payload->>'teamId' and kind='team';
  select payload->>'name' into v_home from futbeat_private.entities where id=m->>'homeTeamId';
  select payload->>'name' into v_away from futbeat_private.entities where id=m->>'awayTeamId';
  select jsonb_build_object('home',s.home_score,'away',s.away_score) into v_score
  from futbeat_private.live_match_state s where s.canonical_match_id=c.match_id
  order by s.last_seen_at desc limit 1;
  if v_home is not null and v_away is not null then
    v_body:=v_home||coalesce(' '||(v_score->>'home')||'-'||(v_score->>'away')||' ',' vs ')||v_away;
  end if;
  v_msg:=jsonb_strip_nulls(jsonb_build_object('type','GOAL_ANNULLED',
    'title','❌ Gol anulado'||coalesce(' — '||v_team,''),'body',v_body,
    'eventId',c.id,'annulsEventId',c.id,'matchId',c.match_id,'collapseKey',c.id));
  insert into futbeat_private.notification_outbox(event_id,notification_key,device_id,user_id,message)
  select null,'annul:'||c.id,o.device_id,o.user_id,
    v_msg||case when o.message->>'playerRole' in ('primary','assist') then
      jsonb_strip_nulls(jsonb_build_object('playerId',o.message->>'playerId',
        'playerRole',o.message->>'playerRole','subjectRefs',o.message->'subjectRefs'))
      else '{}'::jsonb end
      ||case when o.message->>'playerRole'='primary' and pl.name is not null then
        jsonb_build_object('title','❌ Anulado el gol de '||pl.name) else '{}'::jsonb end
  from futbeat_private.notification_outbox o
  join futbeat_private.push_devices d on d.id=o.device_id and d.user_id=o.user_id
  left join futbeat_private.user_preferences p on p.user_id=o.user_id
  left join lateral (select nullif(btrim(e.payload->>'name'),'') name from futbeat_private.entities e
    where e.id=o.message->>'playerId' and e.kind='player') pl on true
  where o.event_id=c.id
    and o.state in ('sent','simulated','uncertain','sending')
    and coalesce(o.attempt_at,o.created_at)>=now()-v_window
    and d.enabled
    and coalesce(p.notify_goal_annulled,true)
  on conflict(notification_key,user_id,device_id) do nothing;
  get diagnostics v_n=row_count;
  return v_n;
end $$;

-- Deferred to commit: a retraction that the same observation turns into a
-- correction twin (store_canonical_event sets retraction_reason='corrected')
-- or restores is re-read at commit and never annulled.
create or replace function futbeat_private.goal_annulled_push_trigger()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  perform futbeat_private.enqueue_goal_annulled(new.id);
  return null;
end $$;
drop trigger if exists futbeat_goal_annulled_push on futbeat_private.canonical_events;
create constraint trigger futbeat_goal_annulled_push
after update on futbeat_private.canonical_events
deferrable initially deferred
for each row
when (new.event_type='GOAL' and new.retracted_at is not null and old.retracted_at is null)
execute function futbeat_private.goal_annulled_push_trigger();

-- ---------------------------------------------------------------------------
-- 8. Registration (copied from 20260916161141, futbeat_private since that
-- migration). NOTIFICATIONS V2: a shared phone. The token physically belongs
-- to this installation now: any other row carrying it (another user, or the
-- same user's old installation) is retired (token released, disabled, its
-- pending pushes cancelled) and the caller's row takes it. Outbox history of
-- the old row is kept.
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.futbeat_register_push(p_installation uuid,p_platform text,p_transport text,p_token text,p_enabled boolean)
returns uuid language plpgsql security definer set search_path='' as $$
declare uid uuid; did uuid;
 v_prev uuid; -- NOTIFICATIONS V2
begin
 uid:=auth.uid();
 if uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
 if p_transport='test' then raise exception 'Test devices are server-only'; end if;
 -- NOTIFICATIONS V2: move the token.
 perform pg_advisory_xact_lock(hashtext('futbeat-push-token:'||coalesce(p_transport,'')||':'||coalesce(p_token,'')));
 for v_prev in select d.id from futbeat_private.push_devices d
   where d.transport=p_transport and d.token=p_token
     and not (d.user_id=uid and d.installation_id=p_installation)
   for update loop
  update futbeat_private.notification_outbox set state='cancelled',finished_at=now(),provider_receipt='token_moved'
  where device_id=v_prev and state in ('pending','sending');
  update futbeat_private.push_devices set token='moved:'||id::text,enabled=false,disabled_at=now(),disabled_reason='token_moved'
  where id=v_prev;
 end loop;
 insert into futbeat_private.push_devices(user_id,installation_id,platform,transport,token,enabled)
 values(uid,p_installation,p_platform,p_transport,p_token,p_enabled)
 on conflict(user_id,installation_id) do update set token=excluded.token,enabled=excluded.enabled,platform=excluded.platform,transport=excluded.transport,
  disabled_at=null,disabled_reason=null -- NOTIFICATIONS V2
 returning id into did;
 return did;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Preferences. read_user_profile copied from 20260918134500; NOTIFICATIONS
-- V2: the six new switches are returned (additive keys).
-- ---------------------------------------------------------------------------
create or replace function futbeat_private.read_user_profile() returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  uid uuid:=auth.uid();
  pref futbeat_private.user_preferences;
  follows jsonb;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  insert into futbeat_private.user_preferences(user_id)
  values(uid)
  on conflict(user_id) do nothing;

  select * into pref
    from futbeat_private.user_preferences
   where user_id=uid;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('type',entity_type,'id',entity_id)
      order by entity_type,entity_id
    ),
    '[]'::jsonb
  )
  into follows
  from futbeat_private.push_follows
  where user_id=uid;

  return jsonb_build_object(
    'preferences',
    jsonb_build_object(
      'detectedCountry',pref.detected_country,
      'selectedCountry',pref.selected_country,
      'displayName',pref.display_name,
      'languageCode',pref.language_code,
      'timezone',pref.timezone,
      'hourFormat',pref.hour_format,
      'notifyKickoff',pref.notify_kickoff,
      'notifyGoals',pref.notify_goals,
      'notifyFinal',pref.notify_final,
      'notifyCards',pref.notify_cards,
      'notifyLineups',pref.notify_lineups,
      'notifyNews',pref.notify_news,
      'notifyTransfers',pref.notify_transfers,
      -- NOTIFICATIONS V2
      'notifyRedCards',pref.notify_red_cards,
      'notifyGoalAnnulled',pref.notify_goal_annulled,
      'notifyPlayerStarter',pref.notify_player_starter,
      'notifyPlayerBench',pref.notify_player_bench,
      'notifyPlayerSubIn',pref.notify_player_sub_in,
      'notifyPlayerSubOut',pref.notify_player_sub_out,
      'updatedAt',pref.updated_at
    ),
    'follows',follows
  );
end;
$$;

-- Partial profile update from one JSON object: only the keys present change
-- (unknown keys are ignored, so newer clients stay compatible). Keys:
-- displayName, languageCode, timezone, hourFormat and the boolean switches
-- notifyKickoff, notifyGoals, notifyFinal, notifyCards, notifyLineups,
-- notifyNews, notifyTransfers, notifyRedCards, notifyGoalAnnulled,
-- notifyPlayerStarter, notifyPlayerBench, notifyPlayerSubIn,
-- notifyPlayerSubOut. notifyRedCards also writes notify_cards (yellow cards
-- no longer push, so for older clients "cards" now means red cards).
-- Returns the profile (same shape as futbeat_read_user_profile).
create or replace function futbeat_private.sync_user_profile_v3(p_profile jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  uid uuid:=auth.uid();
  k text;
  v_display text; v_language text; v_timezone text; v_hour text;
begin
  if uid is null then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  if p_profile is null or jsonb_typeof(p_profile)<>'object' then
    raise exception 'Invalid profile';
  end if;
  foreach k in array array['notifyKickoff','notifyGoals','notifyFinal','notifyCards','notifyLineups',
    'notifyNews','notifyTransfers','notifyRedCards','notifyGoalAnnulled','notifyPlayerStarter',
    'notifyPlayerBench','notifyPlayerSubIn','notifyPlayerSubOut'] loop
    if p_profile ? k and jsonb_typeof(p_profile->k)<>'boolean' then
      raise exception 'Invalid preference %',k;
    end if;
  end loop;
  v_display:=nullif(btrim(p_profile->>'displayName'),'');
  if v_display is not null and char_length(v_display)>80 then raise exception 'Display name too long'; end if;
  v_language:=coalesce(nullif(btrim(p_profile->>'languageCode'),''),'es');
  if p_profile ? 'languageCode' and v_language!~'^[a-z]{2}(-[A-Z]{2})?$' then raise exception 'Invalid language'; end if;
  v_timezone:=coalesce(nullif(btrim(p_profile->>'timezone'),''),'America/Costa_Rica');
  if p_profile ? 'timezone' and char_length(v_timezone)>80 then raise exception 'Invalid timezone'; end if;
  v_hour:=coalesce(nullif(btrim(p_profile->>'hourFormat'),''),'system');
  if p_profile ? 'hourFormat' and v_hour not in ('system','12h','24h') then raise exception 'Invalid hour format'; end if;

  insert into futbeat_private.user_preferences(user_id) values(uid) on conflict(user_id) do nothing;
  update futbeat_private.user_preferences set
    display_name=case when p_profile ? 'displayName' then v_display else display_name end,
    language_code=case when p_profile ? 'languageCode' then v_language else language_code end,
    timezone=case when p_profile ? 'timezone' then v_timezone else timezone end,
    hour_format=case when p_profile ? 'hourFormat' then v_hour else hour_format end,
    notify_kickoff=coalesce((p_profile->>'notifyKickoff')::boolean,notify_kickoff),
    notify_goals=coalesce((p_profile->>'notifyGoals')::boolean,notify_goals),
    notify_final=coalesce((p_profile->>'notifyFinal')::boolean,notify_final),
    notify_cards=coalesce((p_profile->>'notifyRedCards')::boolean,(p_profile->>'notifyCards')::boolean,notify_cards),
    notify_lineups=case when p_profile ? 'notifyPlayerStarter' or p_profile ? 'notifyPlayerBench'
      then coalesce((p_profile->>'notifyPlayerStarter')::boolean,notify_player_starter)
        or coalesce((p_profile->>'notifyPlayerBench')::boolean,notify_player_bench)
      else coalesce((p_profile->>'notifyLineups')::boolean,notify_lineups) end,
    notify_news=coalesce((p_profile->>'notifyNews')::boolean,notify_news),
    notify_transfers=coalesce((p_profile->>'notifyTransfers')::boolean,notify_transfers),
    notify_red_cards=coalesce((p_profile->>'notifyRedCards')::boolean,notify_red_cards),
    notify_goal_annulled=coalesce((p_profile->>'notifyGoalAnnulled')::boolean,notify_goal_annulled),
    notify_player_starter=coalesce((p_profile->>'notifyPlayerStarter')::boolean,notify_player_starter),
    notify_player_bench=coalesce((p_profile->>'notifyPlayerBench')::boolean,notify_player_bench),
    notify_player_sub_in=coalesce((p_profile->>'notifyPlayerSubIn')::boolean,notify_player_sub_in),
    notify_player_sub_out=coalesce((p_profile->>'notifyPlayerSubOut')::boolean,notify_player_sub_out),
    updated_at=now()
  where user_id=uid;
  return futbeat_private.read_user_profile();
end $$;

create or replace function public.futbeat_sync_user_profile_v3(p_profile jsonb)
returns jsonb language sql security invoker set search_path='' as $$
  select futbeat_private.sync_user_profile_v3(p_profile)
$$;

-- Legacy v1/v2 clients still write notify_cards. Keep the new red-card switch
-- in step when those clients change the old switch after a v3 client.
create or replace function futbeat_private.sync_legacy_red_card_preference()
returns trigger language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' or (new.notify_cards is distinct from old.notify_cards
    and new.notify_red_cards is not distinct from old.notify_red_cards) then
    new.notify_red_cards:=new.notify_cards;
  end if;
  if tg_op='INSERT' or (new.notify_lineups is distinct from old.notify_lineups
    and new.notify_player_starter is not distinct from old.notify_player_starter
    and new.notify_player_bench is not distinct from old.notify_player_bench) then
    new.notify_player_starter:=new.notify_lineups;
    new.notify_player_bench:=new.notify_lineups;
  end if;
  return new;
end $$;
drop trigger if exists futbeat_sync_legacy_red_card_preference on futbeat_private.user_preferences;
create trigger futbeat_sync_legacy_red_card_preference
before insert or update on futbeat_private.user_preferences
for each row execute function futbeat_private.sync_legacy_red_card_preference();

-- ---------------------------------------------------------------------------
-- Privileges (create or replace keeps existing grants; restated).
-- ---------------------------------------------------------------------------
do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where (n.nspname='futbeat_private' and p.proname in ('event_message','kickoff_push_is_fresh','store_canonical_event',
     'record_live_events','note_lineup_alerts','enqueue_goal_annulled','goal_annulled_push_trigger',
     'futbeat_register_push','read_user_profile','sync_user_profile_v3','sync_legacy_red_card_preference'))
   or (n.nspname='public' and p.proname in ('futbeat_claim_notifications','futbeat_claim_notifications_v2',
     'futbeat_notification_attempt_valid','futbeat_requeue_notification_attempt',
     'futbeat_mark_notification_send_started','futbeat_cancel_notification_attempt','futbeat_finish_notification',
     'futbeat_sync_user_profile_v3'))
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
 if exists(select 1 from pg_roles where rolname='service_role') then
  grant execute on function public.futbeat_claim_notifications(text,int),
    public.futbeat_claim_notifications_v2(text,int),
    public.futbeat_notification_attempt_valid(uuid,uuid,text),
    public.futbeat_requeue_notification_attempt(uuid,uuid,text),
    public.futbeat_mark_notification_send_started(uuid,uuid,text),
    public.futbeat_cancel_notification_attempt(uuid,uuid,text),
    public.futbeat_finish_notification(uuid,uuid,text,text) to service_role;
 end if;
 if exists(select 1 from pg_roles where rolname='authenticated') then
  grant execute on function futbeat_private.futbeat_register_push(uuid,text,text,text,boolean),
    futbeat_private.read_user_profile(),
    futbeat_private.sync_user_profile_v3(jsonb),
    public.futbeat_sync_user_profile_v3(jsonb) to authenticated;
 end if;
end $$;

notify pgrst,'reload schema';
