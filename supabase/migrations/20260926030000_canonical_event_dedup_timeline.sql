-- #121: canonical event dedup + Match Center timeline.
--
-- Root causes:
--   * synthesize_goal_from_score_change created a provisional GOAL
--     ("Marcador actualizado") for every score increase, even when the same
--     observation already carried the rich GOAL, and nothing superseded it
--     when the rich GOAL arrived later: both were shown and could both push.
--   * LIVE normalization dropped added time (90+5 -> 90), so one provider
--     event existed as LIVE 90' and detail 90+5'.
--
-- Rules (generic; never by team, fixture, player, date or competition):
--   * events_equivalent(a,b): same logical occurrence between two RICH
--     events, conservatively: same id, or same upstream key from the same
--     provider (two distinct upstream row ids are two occurrences).
--     Otherwise same type and team AND either the same canonical player
--     (compatible minute, +-1) or, without player identity on a side, the
--     exact same score after the event plus a compatible minute. Different
--     players or different score-after are always two events; type + team +
--     minute alone never merges. Phases (KICKOFF/HALFTIME/FULL_TIME) only
--     by id.
--   * dedupe_match_events: rich events merge first (strongest evidence
--     wins, missing fields filled from the other). A synthetic GOAL then
--     folds into at most ONE rich GOAL of the same team: the one whose
--     ordinal among that team's rich goals equals the synthetic's
--     score-after-goal, within 3 minutes (closest wins). Synthetic
--     synthetic pairs never merge (each is a distinct score increase).
--   * visible_match_events: the read model, public realtime and the push
--     guard all use this projection; technical synthetic copy is removed
--     (the synthetic stays a plain GOAL fallback).
--   * LIVE identity: rows without a provider id carry a stable fallback key
--     (signature hash + occurrence, see _shared/live_events.ts). Two
--     distinct fallback occurrences never share one canonical id: the first
--     keeps the historical id (claiming a pre-#121 row without a key), any
--     other gets its own stable id. Rows with a provider id are unchanged.
--   * canonical_events are never deleted or rewritten: old duplicates
--     disappear from the projection immediately.

create or replace function futbeat_private.is_phase_event(p_type text)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(p_type in ('KICKOFF','HALFTIME','FULL_TIME'),false)
$$;

create or replace function futbeat_private.is_synthetic_event(e jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(e->>'synthetic','')='true'
$$;

-- Absolute minute (minute + added time); null without a minute.
create or replace function futbeat_private.event_minute_value(e jsonb)
returns integer language sql immutable set search_path='' as $$
  select futbeat_private.safe_result_integer(e->>'minute')
    +coalesce(futbeat_private.safe_result_integer(e->>'extraMinute'),0)
$$;

-- Same minute; added time equal or missing on one side (LIVE used to drop it).
create or replace function futbeat_private.event_minutes_compatible(a jsonb,b jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(futbeat_private.safe_result_integer(a->>'minute')
      =futbeat_private.safe_result_integer(b->>'minute'),false)
    and (futbeat_private.safe_result_integer(a->>'extraMinute') is null
      or futbeat_private.safe_result_integer(b->>'extraMinute') is null
      or futbeat_private.safe_result_integer(a->>'extraMinute')
        =futbeat_private.safe_result_integer(b->>'extraMinute'))
$$;

-- Score after the event as "home-away"; null unless both sides are integers.
create or replace function futbeat_private.event_score_after(e jsonb)
returns text language sql immutable set search_path='' as $$
  select case when futbeat_private.safe_result_integer(e#>>'{score,home}') is not null
      and futbeat_private.safe_result_integer(e#>>'{score,away}') is not null
    then futbeat_private.safe_result_integer(e#>>'{score,home}')||'-'
      ||futbeat_private.safe_result_integer(e#>>'{score,away}') end
$$;

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

-- Keep the stronger event; fill only what it lacks. Added time is only
-- borrowed for the same base minute.
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

-- One entry per logical occurrence; '_members' lists the merged event ids.
create or replace function futbeat_private.dedupe_match_events(p_events jsonb,p_home_team text,p_away_team text)
returns jsonb language plpgsql immutable set search_path='' as $$
declare
 kept jsonb:='[]'; synth jsonb:='[]'; e jsonb; k jsonb; i integer; best integer; best_diff integer;
 d integer; n integer; rank integer;
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
     kept:=jsonb_set(kept,array[best::text],futbeat_private.merge_event_evidence(kept->best,e));
   end if;
 end loop;
 -- 2. Each synthetic GOAL folds into at most one rich GOAL of its team.
 for e in select value from jsonb_array_elements(synth)
   order by futbeat_private.safe_result_integer(value->>'minute') nulls last,value->>'id'
 loop
   n:=case when nullif(e->>'teamId','') is null then null
     when e->>'teamId'=p_home_team then futbeat_private.safe_result_integer(e#>>'{score,home}')
     when e->>'teamId'=p_away_team then futbeat_private.safe_result_integer(e#>>'{score,away}') end;
   best:=null; best_diff:=null;
   for i in 0..jsonb_array_length(kept)-1 loop
     k:=kept->i;
     if k->>'type' is distinct from 'GOAL' or futbeat_private.is_synthetic_event(k)
       or e->>'type' is distinct from 'GOAL' or nullif(e->>'teamId','') is null
       or k->>'teamId' is distinct from e->>'teamId' or coalesce(k->>'_absorbedSynthetic','')='true' then
       continue;
     end if;
     if n is not null then
       -- Ordinal of this rich goal among the team's rich goals.
       select count(*) into rank from jsonb_array_elements(kept) x
       where x->>'type'='GOAL' and not futbeat_private.is_synthetic_event(x) and x->>'teamId'=k->>'teamId'
         and (coalesce(futbeat_private.event_minute_value(x),999)<coalesce(futbeat_private.event_minute_value(k),999)
           or (coalesce(futbeat_private.event_minute_value(x),999)=coalesce(futbeat_private.event_minute_value(k),999)
             and coalesce(x->>'id','')<=coalesce(k->>'id','')));
       if rank<>n then continue; end if;
     end if;
     d:=abs(futbeat_private.event_minute_value(k)-futbeat_private.event_minute_value(e));
     if not (futbeat_private.event_minutes_compatible(k,e) or d<=3 or (d is null and n is not null)) then
       continue;
     end if;
     if best is null or coalesce(d,99)<best_diff then best:=i; best_diff:=coalesce(d,99); end if;
   end loop;
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

-- What users see: deduplicated, without technical synthetic copy.
create or replace function futbeat_private.visible_match_events(p_events jsonb,p_home_team text,p_away_team text)
returns jsonb language sql immutable set search_path='' as $$
  select coalesce(jsonb_agg(case
      when futbeat_private.is_synthetic_event(x) or x->>'detail'='Marcador actualizado'
        then x-'_members'-'detail' else x-'_members' end order by ordinal),'[]'::jsonb)
  from jsonb_array_elements(futbeat_private.dedupe_match_events(p_events,p_home_team,p_away_team))
    with ordinality as events(x,ordinal)
$$;

-- True when a just-stored event is the same occurrence as another event
-- already stored for the match (used before any push is enqueued).
create or replace function futbeat_private.event_already_known(ev jsonb,m jsonb)
returns boolean language sql stable security invoker set search_path='' as $$
  select not futbeat_private.is_phase_event(ev->>'type') and exists(
    select 1 from jsonb_array_elements(futbeat_private.dedupe_match_events(
      (select coalesce(jsonb_agg(c.payload||jsonb_build_object('id',c.id,'type',c.event_type)),'[]'::jsonb)
         from futbeat_private.canonical_events c
        where c.match_id=ev->>'matchId' and c.event_type=ev->>'type'),
      m->>'homeTeamId',m->>'awayTeamId')) g
    where g->'_members' ? (ev->>'id') and jsonb_array_length(g->'_members')>1)
$$;

-- Store: notification dedup (base: 20260918100000_user_profile_v1.sql).
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
begin
  insert into futbeat_private.canonical_events
  values(ev->>'id',ev->>'matchId',p_provider,ev->>'type',ev,p_notify,p_at)
  on conflict(id) do nothing;

  get diagnostics inserted=row_count;
  if inserted=0 or not p_notify then return; end if;

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

-- Synthetic GOAL only when the same observation does not already explain it.
-- Base: 20260918213000_match_event_history.sql. Same ids and payload as
-- before; a side's synthetic GOAL is skipped when the observation that
-- raised its score already carries enough rich GOAL rows for that side,
-- first seen in that very observation and near the current minute.
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
  v_increase integer;
  v_team text;
  v_explained integer;
begin
  if new.provider<>'goal_api'
     or new.canonical_match_id is null
     or (
       coalesce(new.home_score,0)<=coalesce(old.home_score,0)
       and coalesce(new.away_score,0)<=coalesce(old.away_score,0)
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
    v_increase:=case v_side
      when 'home' then coalesce(new.home_score,0)-coalesce(old.home_score,0)
      else coalesce(new.away_score,0)-coalesce(old.away_score,0) end;
    if v_increase<=0 then
      continue;
    end if;
    v_team:=m->>(v_side||'TeamId');

    select count(*) into v_explained
    from futbeat_private.live_events le
    where le.provider=new.provider
      and le.external_match_id=new.external_match_id
      and le.event_type='GOAL'
      -- New in this observation: an old goal never explains a new increase.
      and le.first_seen_at=new.last_seen_at
      and (
        le.team_external_id=coalesce(
          v_raw#>>array[v_side||'Team','id'],v_raw->>(v_side||'TeamId'))
        or exists(
          select 1 from futbeat_private.provider_entities pe
          where pe.provider=new.provider and pe.kind='team'
            and pe.external_id=le.team_external_id and pe.canonical_id=v_team)
      )
      and (
        new.minute is null or le.minute is null
        or (
          le.minute<=new.minute+1
          and new.minute-le.minute<=5+coalesce(
            futbeat_private.safe_result_integer(le.payload->>'extraMinute'),0)
        )
      );
    if v_explained>=v_increase then
      continue;
    end if;

    ev:=jsonb_build_object(
      'id','fb_event_'||md5(concat_ws(
        '|',new.canonical_match_id,'goal_api','GOAL',v_side,
        new.revision,new.minute,new.home_score,new.away_score
      )),
      'matchId',new.canonical_match_id,
      'type','GOAL',
      'minute',new.minute,
      'teamId',v_team,
      'score',jsonb_build_object(
        'home',new.home_score,
        'away',new.away_score
      ),
      -- Internal audit text; the visible projection never shows it.
      'detail','Marcador actualizado',
      'synthetic',true
    );
    perform futbeat_private.store_canonical_event(
      ev,'goal_api',baseline,new.changed_at,m
    );
  end loop;

  return new;
end
$event$;

-- LIVE events keep upstream identity (base: 20260926020000, #120 logic unchanged).
create or replace function futbeat_private.record_live_events(p_provider text,p_received_at timestamptz,p_observations jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb; c jsonb; m jsonb; mid text; e record; tid text; pid text; aid text;
 ev jsonb; eid text; can_notify boolean; baseline boolean; typ text; state futbeat_private.live_match_state;
 obs jsonb; kept jsonb:='[]'; suppressed jsonb:='[]'; v_ext text; v_status text; v_claimed text;
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
  -- Deterministic order: the first occurrence always keeps the historical id.
  for e in select * from futbeat_private.live_events where provider=p_provider and external_match_id=c->>'externalMatchId'
    order by first_seen_at,event_key loop
   if e.event_type not in ('GOAL','YELLOW_CARD','RED_CARD','SUBSTITUTION','VAR','MISSED_PENALTY') then continue; end if;
   tid:=null; pid:=null; aid:=null;
   select canonical_id into tid from futbeat_private.provider_entities where provider=p_provider and kind='team' and external_id=e.team_external_id;
   if tid not in (m->>'homeTeamId',m->>'awayTeamId') then continue; end if;
   -- Unknown identity stays null; external IDs never masquerade as canonical IDs.
   select canonical_id into pid from futbeat_private.provider_entities where provider=p_provider and kind='player' and external_id=e.player_external_id;
   select canonical_id into aid from futbeat_private.provider_entities where provider=p_provider and kind='player'
     and external_id=coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}');
   eid:='fb_event_'||md5(concat_ws('|',mid,p_provider,e.event_type,e.minute,
     coalesce(e.payload->>'extraMinute',e.payload#>>'{payload,time,extra}'),
     e.team_external_id,e.player_external_id,
     case when e.event_type='SUBSTITUTION' then coalesce(e.payload->>'assistExternalId',e.payload#>>'{payload,assist,id}') else '' end));
   -- #121: two anonymous rows (fallback keys: no provider id) with the
   -- same attributes are distinct occurrences and must not share one
   -- canonical id. The first keeps the historical id (claiming a pre-#121
   -- row that has no key yet); any other fallback occurrence gets its own
   -- stable id. Same key -> same id on every poll. Rows with a provider id
   -- keep the historical behavior (a re-keyed provider row stays one event).
   if e.event_key like 'fallback:%' then
    select payload->>'providerEventKey' into v_claimed from futbeat_private.canonical_events where id=eid;
    if found then
     if v_claimed is null then
      update futbeat_private.canonical_events
        set payload=payload||jsonb_build_object('providerEventKey',e.event_key,'provider',p_provider)
        where id=eid;
     elsif v_claimed like 'fallback:%' and v_claimed<>e.event_key then
      eid:='fb_event_'||md5(eid||'|'||e.event_key);
     end if;
    end if;
   end if;
   ev:=jsonb_strip_nulls(jsonb_build_object('id',eid,'matchId',mid,'type',e.event_type,'minute',e.minute,
    'extraMinute',coalesce(e.payload->'extraMinute',e.payload#>'{payload,time,extra}'),
    'teamId',tid,'playerId',pid,'assistPlayerId',aid,
    -- #121: upstream identity (provider row id, or the stable fallback key).
    'providerEventKey',e.event_key,'provider',p_provider,
    'score',case when jsonb_typeof(e.payload->'scoreAfter')='object' then e.payload->'scoreAfter' end));
   perform futbeat_private.store_canonical_event(ev,p_provider,can_notify and e.first_seen_at=p_received_at,p_received_at,m);
  end loop;
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

-- Public realtime uses the visible projection (base: 20260926020000, #120 guard unchanged).
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
 from futbeat_private.canonical_events where match_id=s.canonical_match_id and provider=p_provider;
 -- #121: open clients get the same deduplicated visible events as the read model.
 select payload into m from futbeat_private.entities where id=s.canonical_match_id and kind='match';
 ev:=futbeat_private.visible_match_events(ev,m->>'homeTeamId',m->>'awayTeamId');
 insert into public.live_match_updates(match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at)
 values(s.canonical_match_id,s.provider,s.external_match_id,s.status,s.minute,s.home_score,s.away_score,s.revision,jsonb_array_length(ev),ev,s.changed_at,now())
 on conflict(match_id) do update set provider=excluded.provider,external_match_id=excluded.external_match_id,
 status=excluded.status,minute=excluded.minute,home_score=excluded.home_score,away_score=excluded.away_score,
 revision=excluded.revision,event_count=excluded.event_count,latest_events=excluded.latest_events,
 changed_at=excluded.changed_at,updated_at=excluded.updated_at;
end $$;

-- Read model uses the visible projection (base: 20260924100000).
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
        or (v_relax_terminal and status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')))
      and (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
        or (status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') and received_at>=now()-interval '15 minutes'))
    order by (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')) desc,received_at desc,id desc limit 1;
   if found then
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

do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='futbeat_private' and p.proname in
   ('is_phase_event','is_synthetic_event','event_minute_value','event_minutes_compatible','event_score_after',
    'events_equivalent','merge_event_evidence','dedupe_match_events','visible_match_events',
    'event_already_known','synthesize_goal_from_score_change')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then execute format('revoke all on function %s from %I',fn,role_name); end if;
  end loop;
 end loop;
end $$;

notify pgrst,'reload schema';
