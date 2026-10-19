-- A player can belong to a club AND to national teams at the same time.
--
-- Evidence (QA81, #222; #217): the profile of a club goalscorer listed only
-- national-team matches. Reproduced locally (PGlite, generic fixtures):
--   * the squad writer of 20260919042500 assumes "one current GOAL squad per
--     player": storing the national-team squad DELETES the club membership
--     and records a ROSTER_CHANGE transfer club -> national team;
--   * the wrapper of 20260922041454 overwrites payload.teamId with the squad
--     being stored, so the player's "team" flips on every refresh
--     (club, national, club, ...);
--   * the profile read (20261001125000) lists the matches of payload.teamId
--     only, and the app filters the same way.
--
-- Fix (no merge, no name matching between players, no provider call):
--   1. Squad writes. When the stored team or the player's previous team is a
--      national team, the pair is a CONTEXT, not a move: the other
--      membership is kept, the transfer row recorded by this very call is
--      withdrawn, the club stays payload.teamId (with its own shirt number
--      and season numbers) and payload.nationalTeamId names the national
--      team. Club -> club keeps the existing transfer behaviour, and a
--      national membership survives a club move.
--   2. Profile read. The player's teams are payload.teamId,
--      payload.nationalTeamId and every squad membership (aliases resolved);
--      the matches are those of any of these teams, plus matches where the
--      player has a canonical (non-retracted) event. The player row carries
--      the resolved `teamIds` so the app can filter the same way.
--
-- National team test: the cached national-team map (20261002100000), or a
-- team name that is a catalogued country (optionally "U23", "W"). A club
-- named exactly like a country would be treated as national: documented
-- and accepted (the effect is only that no transfer is recorded).
--
-- Existing data is NOT rewritten: memberships already erased come back with
-- the next squad refresh of that club; until then the event evidence lists
-- the matches the player took part in.
--
-- Operational note: creates one partial expression index on
-- canonical_events (players with events). Builds under a write lock on that
-- table; apply outside a live-match window.

create or replace function futbeat_private.team_is_national(p_team_id text)
returns boolean language sql stable set search_path='' as $$
  with t as (
    select e.id,e.payload from futbeat_private.entities e
    where e.id=futbeat_private.futbeat_resolve_entity_id('team',p_team_id) and e.kind='team'
  ), parsed as (
    select (regexp_match(lower(btrim(t.payload->>'name')),
      '^(.+?)(?:\s+(u\d{2}))?(?:\s+(w|women))?$'))[1] base
    from t
  )
  select exists(
    select 1 from futbeat_private.national_team_cache c, t
    where c.payload->'teams' ? t.id
  ) or exists(
    select 1 from parsed p
    join futbeat_private.country_catalog c on not c.is_supranational
      and (lower(c.canonical_name)=p.base or c.aliases ? p.base)
  )
$$;

alter function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb)
  rename to store_team_squad_before_national_context;

create function futbeat_private.futbeat_store_team_squad(
  p_team_id text,p_provider text,p_received_at timestamptz,p_players jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  tid text:=futbeat_private.futbeat_resolve_entity_id('team',p_team_id);
  t_national boolean:=futbeat_private.team_is_national(p_team_id);
  prior jsonb; members jsonb; max_transfer bigint; result jsonb;
  r record; m jsonb; old_payload jsonb; next_payload jsonb; old_team text;
  field text; touched text[]:=array[]::text[];
begin
  -- State of the already-known players of this answer, before the write.
  select coalesce(jsonb_object_agg(e.id,e.payload),'{}')
  into prior
  from jsonb_array_elements(case when jsonb_typeof(p_players)='array' then p_players else '[]'::jsonb end) x(item)
  join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='player'
    and pe.external_id=x.item#>>'{provenance,externalId}'
  join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)
    and e.kind='player';
  select coalesce(jsonb_agg(to_jsonb(sm)),'[]')
  into members
  from futbeat_private.team_squad_members sm
  where sm.player_id in (select jsonb_object_keys(prior)) and sm.team_id<>tid;
  select coalesce(max(id),0) into max_transfer from futbeat_private.transfer_events;

  result:=futbeat_private.store_team_squad_before_national_context(p_team_id,p_provider,p_received_at,p_players);
  if result->>'status' in ('ignored_older','ignored_older_players') then
    return result;
  end if;

  for r in select key pid,value from jsonb_each(prior) loop
    old_payload:=r.value;
    select payload into next_payload from futbeat_private.entities
      where id=r.pid and kind='player' for update;
    -- Only players this answer really applied (same checks as the wrappers
    -- of 20260922235500 and 20260923020000).
    if next_payload is null or next_payload->>'teamId' is distinct from tid
       or futbeat_private.try_timestamptz(next_payload#>>'{provenance,receivedAt}') is distinct from p_received_at
       or not exists(select 1 from futbeat_private.team_squad_members sm
         where sm.team_id=tid and sm.player_id=r.pid) then
      continue;
    end if;

    -- Memberships erased by this call that involve a national team.
    for m in select value from jsonb_array_elements(members) where value->>'player_id'=r.pid loop
      if t_national or futbeat_private.team_is_national(m->>'team_id') then
        insert into futbeat_private.team_squad_members(team_id,player_id,provider,updated_at)
        values(m->>'team_id',r.pid,m->>'provider',(m->>'updated_at')::timestamptz)
        on conflict(team_id,player_id) do nothing;
        if found then touched:=array_append(touched,m->>'team_id'); end if;
      end if;
    end loop;

    -- A club <-> national pair is never a transfer.
    delete from futbeat_private.transfer_events te
    where te.id>max_transfer and te.player_id=r.pid and te.to_team_id=tid
      and (t_national or futbeat_private.team_is_national(te.from_team_id));

    old_team:=futbeat_private.futbeat_resolve_entity_id('team',nullif(old_payload->>'teamId',''));
    if t_national and old_team is not null and old_team<>tid
       and not futbeat_private.team_is_national(old_team) then
      -- National call-up: the club and its context stay the player's own.
      foreach field in array array['teamId','shirtNumber','position','matchesPlayed','appearances',
        'starts','minutesPlayed','goals','assists','yellowCards','redCards','rating','seasonStats'] loop
        if old_payload ? field then
          next_payload:=jsonb_set(next_payload,array[field],old_payload->field);
        else
          next_payload:=next_payload-field;
        end if;
      end loop;
      next_payload:=next_payload||jsonb_build_object('nationalTeamId',tid);
    elsif t_national then
      next_payload:=next_payload||jsonb_build_object('nationalTeamId',tid);
    elsif old_team is not null and old_team<>tid and futbeat_private.team_is_national(old_team) then
      next_payload:=next_payload||jsonb_build_object('nationalTeamId',old_team);
    end if;
    update futbeat_private.entities set payload=next_payload
      where id=r.pid and kind='player' and payload is distinct from next_payload;
  end loop;

  -- Restored memberships count again for their team (same rule as 20261001130000).
  update futbeat_private.team_detail_coverage c set
    player_count=(select count(*) from futbeat_private.team_squad_player_ids(c.team_id)),
    media_count=(select count(*) from futbeat_private.team_squad_player_ids(c.team_id) s(id)
      join futbeat_private.entities e on e.id=s.id
      where futbeat_private.valid_player_media(e.payload->'media'))
  where c.team_id=any(touched);

  return result;
end $$;

create index if not exists canonical_events_player_idx
  on futbeat_private.canonical_events((payload->>'playerId'))
  where payload->>'playerId' is not null;

-- Every team of a player: club, national team, squad memberships.
create or replace function futbeat_private.player_team_ids(p_player_id text)
returns text[] language sql stable set search_path='' as $$
  with ids as (
    select futbeat_private.futbeat_resolve_entity_id('player',p_player_id) pid
  ), aliases as (
    select pid id from ids
    union
    select r.alias_id from futbeat_private.entity_redirects r, ids
    where r.kind='player' and r.canonical_id=ids.pid
  ), teams as (
    select nullif(e.payload->>'teamId','') team_id,0 rank from futbeat_private.entities e, ids
      where e.id=ids.pid and e.kind='player'
    union all
    select nullif(e.payload->>'nationalTeamId',''),1 from futbeat_private.entities e, ids
      where e.id=ids.pid and e.kind='player'
    union all
    select sm.team_id,2 from futbeat_private.team_squad_members sm
      where sm.player_id in (select id from aliases)
  ), resolved as (
    select futbeat_private.futbeat_resolve_entity_id('team',team_id) id,min(rank) rank
    from teams where team_id is not null
    group by 1
  )
  select coalesce(array_agg(r.id order by r.rank,r.id),array[]::text[])
  from resolved r
  join futbeat_private.entities e on e.id=r.id and e.kind='team'
$$;

alter function futbeat_private.futbeat_read_entity_detail(text,text)
  rename to read_entity_detail_before_player_teams;

create function futbeat_private.futbeat_read_entity_detail(p_type text,p_id text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  snap jsonb; pid text; team_ids text[]; matches_json jsonb; updated timestamptz;
begin
  snap:=futbeat_private.read_entity_detail_before_player_teams(p_type,p_id);
  if snap is null or p_type<>'player' then return snap; end if;
  pid:=snap#>>'{players,0,id}';
  team_ids:=futbeat_private.player_team_ids(coalesce(pid,p_id));

  -- Same window and order as the base read (100 nearest to now).
  with relevant as (
    select distinct on (e.id) e.payload,cm.start_time,cm.updated_at
    from futbeat_private.calendar_matches cm
    join futbeat_private.entities e on e.id=cm.match_id and e.kind='match'
    where e.payload->>'homeTeamId'=any(team_ids) or e.payload->>'awayTeamId'=any(team_ids)
       or e.id in (
         select ce.match_id from futbeat_private.canonical_events ce
         where ce.payload->>'playerId'=coalesce(pid,p_id) and ce.retracted_at is null)
  ), nearest as (
    select * from relevant
    order by abs(extract(epoch from (start_time-now())))
    limit 100
  )
  select coalesce(jsonb_agg(payload order by start_time),'[]'::jsonb),max(updated_at)
  into matches_json,updated
  from nearest;

  return snap||jsonb_build_object(
    'matches',matches_json,
    'updatedAt',greatest(coalesce(updated,'epoch'::timestamptz),(snap->>'updatedAt')::timestamptz),
    'players',jsonb_build_array((snap#>'{players,0}')||jsonb_build_object('teamIds',to_jsonb(team_ids))),
    'teams',coalesce((
      select jsonb_agg(e.payload order by e.payload->>'name',e.id)
      from futbeat_private.entities e
      where e.kind='team' and e.id in (
        select value->>'homeTeamId' from jsonb_array_elements(matches_json)
        union select value->>'awayTeamId' from jsonb_array_elements(matches_json)
        union select unnest(team_ids))),'[]'::jsonb),
    'competitions',coalesce((
      select jsonb_agg(e.payload order by e.payload->>'country',e.payload->>'name',e.id)
      from futbeat_private.entities e
      where e.kind='competition' and e.id in (
        select value->>'competitionId' from jsonb_array_elements(matches_json)
        union select e2.payload->>'competitionId' from futbeat_private.entities e2
          where e2.kind='team' and e2.id=any(team_ids))),'[]'::jsonb));
end $$;

revoke all on function futbeat_private.team_is_national(text),
  futbeat_private.player_team_ids(text),
  futbeat_private.store_team_squad_before_national_context(text,text,timestamptz,jsonb),
  futbeat_private.read_entity_detail_before_player_teams(text,text)
  from public,anon,authenticated,service_role;
revoke all on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text)
  from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_store_team_squad(text,text,timestamptz,jsonb),
  futbeat_private.futbeat_read_entity_detail(text,text)
  to service_role;

notify pgrst,'reload schema';
