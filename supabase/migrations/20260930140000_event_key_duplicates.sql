-- Re-issued GOAL event ids: duplicated scorers / cards / substitutions in the
-- Match Center (one goal shown as "10', 10', 10'"). Local only: no provider
-- calls, no cron, no ledger.
--
-- Measured in production (read-only): GOAL re-issues events[].id (a fresh
-- opaque id) for EVERY row of a fixture on every answer; ~95k live_events
-- rows, ~60% of event contents seen under 2+ keys, none ever retracted (the
-- deployed worker sends no completeSections / source). record_live_events
-- (20260930100000) then gave every re-issued key a canonical row of its own
-- (md5(content id|key), duplicateOf=content id): one more row per event and
-- per answer (452 such rows in 8 matches within an hour of that migration).
--
-- Root causes fixed here:
--   * events_equivalent only knew "a.duplicateOf = b.id". dedupe_match_events
--     keeps the FIRST row (by id) of an occurrence as its representative;
--     when that is a copy, the content row folds into it, but every other copy
--     (duplicateOf = content id <> representative id, two distinct upstream
--     ids) is "a different occurrence": each copy was shown.
--     Now two rows that are copies of the same row (same duplicateOf) are the
--     same occurrence as well (transitive collapse).
--   * record_live_events materialised every re-keyed copy. A copy of a
--     still-listed row is now NOT stored: the content row it copies backs it
--     (v_backed), and an active row of that key stored before this fix (a
--     materialised copy) is retracted ('duplicate_upstream_key', audited,
--     never deleted, never a correction twin, never pushed). When the copied
--     key is no longer listed the copy becomes the identity exactly as
--     before (new row + correction twin, no second push).
--
-- Unchanged: the content-based id formula, push rules, the team-score guard
-- (a copy is never folded when the team would have fewer active goals than
-- its score), fallback-key semantics, snapshot-replace.
--
-- Rows already duplicated: see supabase/manual/20260930140000_event_key_duplicates_cleanup.sql
-- (separate, dry-run first; this migration never rewrites existing data).

-- ---------------------------------------------------------------------------
-- Same logical occurrence. Copied from 20260930100000 (verbatim). Changed
-- only: two copies of the same row (equal duplicateOf) are that occurrence.
-- ---------------------------------------------------------------------------
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
 -- CHANGED: two copies of the same row are that one occurrence too, so the
 -- collapse no longer depends on which member dedupe keeps as representative.
 if nullif(a->>'duplicateOf','') is not null and a->>'duplicateOf'=b->>'duplicateOf' then return true; end if;
 if ka is not null and kb is not null and coalesce(a->>'provider','')=coalesce(b->>'provider','') then
   if ka=kb then return true; end if;
   -- CHANGED: two occurrences (:1, :2) of one content signature listed in
   -- the same answer are two events by construction (content keys, see
   -- _shared/live_events.ts), never a weak match.
   if ka like 'fallback:%' and kb like 'fallback:%'
     and regexp_replace(ka,':\d+$','')=regexp_replace(kb,':\d+$','') then return false; end if;
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

-- ---------------------------------------------------------------------------
-- LIVE -> canonical. Copied from 20260930100000 (verbatim). Changed only in
-- pass 2: a re-keyed copy of a still-listed row is not stored (see header).
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
 where n.nspname='futbeat_private' and p.proname in ('events_equivalent','record_live_events')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
end $$;

notify pgrst,'reload schema';
