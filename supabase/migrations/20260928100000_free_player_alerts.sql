-- #106 Free player alerts: followed players get official lineup (starter /
-- bench) and LIVE event alerts (goal, assist, cards, in / out, missed
-- penalty). Free, no entitlement checks.
--
-- Architecture (unchanged): one canonical observation -> internal fan-out to
-- every follower. Nothing here calls a provider; followers never cause
-- upstream requests.
--
-- * Identity: canonical player ids only (canonical_events.playerId /
--   assistPlayerId, and lineup provider ids mapped through provider_entities).
--   An event or lineup row without a canonical player never alerts a player
--   follower.
-- * LIVE events ride the existing store_canonical_event pass: player
--   followers are inserted first with a player-specific copy, then the
--   existing match/team fan-out runs with the same
--   on conflict(event_id,user_id,device_id): one logical notification per
--   event, user and device, the most relevant copy wins. #121 (one push per
--   logical occurrence, second-provider confirmation, first-batch baseline,
--   first_seen gate) applies unchanged because it runs before any insert.
-- * Player alerts also skip events whose match minute lags the current live
--   minute by more than playerAlertMaxLagMinutes (a recovered/backfilled
--   event is kept for history but never becomes a fresh player alert).
-- * Lineups: official = observed inside the lineup window (from
--   officialLineupMinutes before kickoff to lineupAlertLateMinutes after it)
--   with a complete XI (>= 11 starters) on that side; anything else is
--   probable/historical and never alerts. Each player/match alerts once per
--   role and at most twice in total (the first official role + one
--   correction): starter -> bench -> starter cannot storm.
-- * Pre-send revalidation (claim) now also honours player follows carried
--   in subjectRefs, so a player-only follower is sent, and an unfollow before
--   dispatch cancels a player-only alert (match/team followers are kept).

-- ---------------------------------------------------------------------------
-- LIVE events
-- ---------------------------------------------------------------------------

-- True when the event's match minute lags the latest live minute of its
-- match by more than the allowed window (a recovered/backfilled event).
create or replace function futbeat_private.player_event_is_stale(ev jsonb)
returns boolean language sql stable set search_path='' as $$
  select case when coalesce(ev->>'minute','')~'^\d{1,3}$' then coalesce((
    select s.minute-(ev->>'minute')::integer>futbeat_private.quota_setting(
        'goal_api','playerAlertMaxLagMinutes',20)
    from futbeat_private.live_match_state s
    where s.canonical_match_id=ev->>'matchId' and s.minute is not null
    order by s.last_seen_at desc limit 1
  ),false) else false end
$$;

-- Player-specific copy for one involved canonical player, or null when the
-- event/role is not a player alert or the player is unknown.
create or replace function futbeat_private.player_event_message(
  ev jsonb,msg jsonb,p_player text,p_role text)
returns jsonb language plpgsql stable set search_path='' as $$
declare v_name text; v_title text;
  v_minute text:=case when ev->>'minute' is not null then ' '||(ev->>'minute')||chr(39) else '' end;
begin
  select nullif(btrim(payload->>'name'),'') into v_name
  from futbeat_private.entities where id=p_player and kind='player';
  if v_name is null then return null; end if;
  v_title:=case
    when ev->>'type'='GOAL' and p_role='primary' then '⚽'||v_minute||' Gol de '||v_name
    when ev->>'type'='GOAL' and p_role='assist' then '🅰️'||v_minute||' Asistencia de '||v_name
    when ev->>'type'='YELLOW_CARD' and p_role='primary' then '🟨'||v_minute||' Amarilla para '||v_name
    when ev->>'type'='RED_CARD' and p_role='primary' then '🟥'||v_minute||' Roja para '||v_name
    -- GOAL substitutionPlayerId is "OUT|IN" (as the detail normalizer's
    -- outPlayerId/inPlayerId): playerId leaves, assistPlayerId enters.
    when ev->>'type'='SUBSTITUTION' and p_role='primary' then '🔄'||v_minute||' Sale '||v_name
    when ev->>'type'='SUBSTITUTION' and p_role='assist' then '🔄'||v_minute||' Entra '||v_name
    when ev->>'type'='MISSED_PENALTY' and p_role='primary' then '❌'||v_minute||' Penal fallado por '||v_name
  end;
  if v_title is null then return null; end if;
  return msg||jsonb_build_object('title',v_title,'playerId',p_player,'playerRole',p_role,
    'subjectRefs',jsonb_build_array(jsonb_build_object('type','player','id',p_player)));
end $$;

-- Copied from 20260926030000; only the player fan-out block is new.
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
-- Pre-send revalidation (copied from 20260919050000; event rows also accept
-- a still-followed subject from subjectRefs).
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
      m.payload as match
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

    if not row.enabled or not coalesce(still_following,false) then
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
-- Official lineups
-- ---------------------------------------------------------------------------
create table if not exists futbeat_private.lineup_player_alerts (
  match_id text not null references futbeat_private.entities(id) on delete cascade,
  player_id text not null,
  role text not null check (role in ('starter','bench')),
  official boolean not null default false,
  notified_roles text[] not null default '{}',
  first_seen_at timestamptz not null,
  updated_at timestamptz not null,
  primary key (match_id,player_id)
);
alter table futbeat_private.lineup_player_alerts enable row level security;
revoke all on futbeat_private.lineup_player_alerts from public,anon,authenticated;

-- Lineup rows with their role (both GOAL lineup shapes, same as lineup_rows).
create or replace function futbeat_private.lineup_player_roles(p_payload jsonb)
returns table(side text,role text,external_id text) language sql immutable set search_path='' as $$
  select nullif(lower(r->>'team'),''),
    case when lower(r->>'type') like 'start%' then 'starter' else 'bench' end,
    coalesce(nullif(btrim(r->>'playerId'),''),nullif(btrim(r->>'playerKey'),''),nullif(btrim(r#>>'{player,id}'),''))
  from jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups')='array'
    then p_payload->'lineups' else '[]'::jsonb end) r
  where lower(coalesce(r->>'type','')) like 'start%' or lower(coalesce(r->>'type','')) like 'sub%'
  union all
  select s.side,case k.key when 'startingLineups' then 'starter' else 'bench' end,
    coalesce(nullif(btrim(r->>'playerId'),''),nullif(btrim(r->>'playerKey'),''),nullif(btrim(r#>>'{player,id}'),''))
  from (values('home'),('away')) s(side)
  cross join (values('startingLineups'),('substitutes')) k(key)
  cross join lateral jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups'->s.side->k.key)='array'
    then p_payload->'lineups'->s.side->k.key else '[]'::jsonb end) r
  where jsonb_typeof(p_payload->'lineups')='object'
$$;

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
      'subjectRefs',jsonb_build_array(jsonb_build_object('type','player','id',v_pid)));
    insert into futbeat_private.notification_outbox(notification_key,device_id,user_id,message)
    select v_key,d.id,d.user_id,v_msg
    from futbeat_private.push_devices d
    left join futbeat_private.user_preferences p on p.user_id=d.user_id
    where d.enabled and d.registered_at<=p_fetched_at
      and coalesce(p.notify_lineups,true)
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

-- Detail storage (copied from 20260922235500): lineup alerts run after the
-- harvest, so the lineup's provider ids already map to canonical players.
create or replace function futbeat_private.store_match_detail(p_match_id text,p_external_match_id text,p_fetched_at timestamptz,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 result:=futbeat_private.store_match_detail_before_media(p_match_id,p_external_match_id,p_fetched_at,p_payload);
 perform futbeat_private.harvest_lineup_players(p_match_id,p_payload,p_fetched_at);
 perform futbeat_private.note_lineup_alerts(p_match_id,p_payload,p_fetched_at);
 return result;
end $$;

do $$ declare fn regprocedure; role_name text; begin
 for fn in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='futbeat_private' and p.proname in
   ('player_event_is_stale','player_event_message','lineup_player_roles','note_lineup_alerts')
 loop
  execute format('revoke all on function %s from public',fn);
  foreach role_name in array array['anon','authenticated'] loop
   if exists(select 1 from pg_roles where rolname=role_name) then
    execute format('revoke all on function %s from %I',fn,role_name);
   end if;
  end loop;
 end loop;
end $$;
