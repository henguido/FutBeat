-- BE-239: a mapped match with an empty payload joins the feed with its teams.
--
-- 7,311 match entities hold only id and empty names: the global resolver maps
-- the provider id first, so an ingest that fails later leaves the mapping behind
-- an entity nobody fills. The linker counted them as linked and stopped, so such a
-- match showed no teams and had no calendar row (GOAL 835432, 2026-10-31).
--
-- Same strong identity as discover_goal_live_match: both teams and the competition
-- mapped by provider id, never by name. A real match of the same teams within
-- 3 hours keeps the entity empty: merging twins is not decided here.

create or replace function futbeat_private.hydrate_goal_anonymous_match(p_fixture jsonb, p_match text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_ext text:=nullif(coalesce(p_fixture->>'apiId',p_fixture->>'id'),'');
  v_home_ext text:=nullif(coalesce(p_fixture#>>'{homeTeam,id}',p_fixture->>'homeTeamId'),'');
  v_away_ext text:=nullif(coalesce(p_fixture#>>'{awayTeam,id}',p_fixture->>'awayTeamId'),'');
  v_comp_ext text:=nullif(coalesce(p_fixture#>>'{league,id}',p_fixture->>'leagueId'),'');
  v_kickoff timestamptz:=futbeat_private.try_timestamptz(p_fixture->>'kickoffUtc');
  v_home text; v_away text; v_comp text;
begin
  if not exists(select 1 from futbeat_private.entities e
      where e.id=p_match and e.kind='match' and coalesce(e.payload->>'homeTeamId','')='') then
    return 'not_anonymous';
  end if;
  select futbeat_private.futbeat_resolve_entity_id('team',canonical_id) into v_home
    from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=v_home_ext;
  select futbeat_private.futbeat_resolve_entity_id('team',canonical_id) into v_away
    from futbeat_private.provider_entities where provider='goal_api' and kind='team' and external_id=v_away_ext;
  select futbeat_private.futbeat_resolve_entity_id('competition',canonical_id) into v_comp
    from futbeat_private.provider_entities where provider='goal_api' and kind='competition' and external_id=v_comp_ext;
  if v_home is null or v_away is null or v_home=v_away then return 'team_unmapped'; end if;
  if v_comp is null then return 'competition_unmapped'; end if;
  if v_kickoff is null then return 'no_kickoff'; end if;

  perform futbeat_private.goal_match_identity_lock(v_ext);
  if exists(select 1 from futbeat_private.calendar_matches c
      join futbeat_private.entities x on x.id=c.match_id
      where c.start_time between v_kickoff-interval '3 hours' and v_kickoff+interval '3 hours'
        and x.id<>p_match and x.payload->>'homeTeamId'=v_home and x.payload->>'awayTeamId'=v_away) then
    return 'twin_exists';
  end if;

  update futbeat_private.entities e set payload=(e.payload-'name'-'country'-'shortName')||jsonb_strip_nulls(jsonb_build_object(
      'competitionId',v_comp,'homeTeamId',v_home,'awayTeamId',v_away,
      'startTime',to_jsonb(v_kickoff),
      -- Never a provider status: LIVE / final comes from the observations.
      'status','SCHEDULED','events','[]'::jsonb,'statistics','[]'::jsonb,
      'season',nullif(p_fixture->>'leagueYear',''),
      'provenance',jsonb_build_object('source','GOAL API','externalId',v_ext,'receivedAt',now(),
        'verificationStatus','PROVISIONAL','discoveredVia','live-feed')))
    where e.id=p_match and e.kind='match' and coalesce(e.payload->>'homeTeamId','')='';
  if exists(select 1 from futbeat_private.live_match_state
      where provider='goal_api' and external_match_id=v_ext and canonical_match_id=p_match) then
    perform public.futbeat_publish_live_state('goal_api',v_ext);
  end if;
  return 'hydrated';
end $function$;

revoke all on function futbeat_private.hydrate_goal_anonymous_match(jsonb,text) from public,anon,authenticated;

CREATE OR REPLACE FUNCTION futbeat_private.futbeat_link_goal_live_matches(p_fixtures jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  fixture jsonb;
  v_external text;
  v_home_external text;
  v_away_external text;
  v_home_name text;
  v_away_name text;
  v_start timestamptz;
  v_match text;
  v_home_canonical text;
  v_away_canonical text;
  v_candidates integer;
  v_linked integer := 0;
  v_already_linked integer := 0;
  v_unmapped jsonb := '[]'::jsonb;
  v_deferred integer := 0;
  -- BE-237: inside the 8 s statement limit, so what was linked commits.
  v_deadline timestamptz := clock_timestamp() + interval '4 seconds';
begin
  if p_fixtures is null or jsonb_typeof(p_fixtures) <> 'array' then
    raise exception 'fixtures must be an array';
  end if;

  for fixture in select value from jsonb_array_elements(p_fixtures)
  loop
    v_external := nullif(coalesce(fixture->>'apiId', fixture->>'id'), '');
    v_home_external := nullif(coalesce(
      fixture#>>'{homeTeam,id}',
      fixture->>'homeTeamId'
    ), '');
    v_away_external := nullif(coalesce(
      fixture#>>'{awayTeam,id}',
      fixture->>'awayTeamId'
    ), '');
    v_home_name := nullif(coalesce(
      fixture#>>'{homeTeam,name}',
      fixture->>'homeTeamName'
    ), '');
    v_away_name := nullif(coalesce(
      fixture#>>'{awayTeam,name}',
      fixture->>'awayTeamName'
    ), '');
    v_start := case
      when nullif(fixture->>'kickoffUtc','') is null then null
      else (fixture->>'kickoffUtc')::timestamptz
    end;
    v_match := null;
    v_home_canonical := null;
    v_away_canonical := null;
    v_candidates := 0;

    if v_external is null then
      continue;
    end if;

    select canonical_id
    into v_match
    from futbeat_private.provider_entities
    where provider='goal_api'
      and kind='match'
      and external_id=v_external;

    if v_match is not null then
      v_already_linked := v_already_linked + 1;
      if clock_timestamp() <= v_deadline then
        perform futbeat_private.hydrate_goal_anonymous_match(fixture, v_match);
      end if;
      continue;
    end if;

    -- BE-237: a rolled back call links nothing, so the next poll hits the same
    -- fixtures. The observation is stored unlinked and links on a later poll.
    if clock_timestamp() > v_deadline then
      v_deferred := v_deferred + 1;
      continue;
    end if;

    if v_home_external is not null then
      select canonical_id
      into v_home_canonical
      from futbeat_private.provider_entities
      where provider='goal_api'
        and kind='team'
        and external_id=v_home_external;
    end if;

    if v_away_external is not null then
      select canonical_id
      into v_away_canonical
      from futbeat_private.provider_entities
      where provider='goal_api'
        and kind='team'
        and external_id=v_away_external;
    end if;

    if v_start is not null
       and v_home_canonical is not null
       and v_away_canonical is not null then
      select count(*)::integer, min(e.id)
      into v_candidates, v_match
      from futbeat_private.entities e
      where e.kind='match'
        and e.payload->>'homeTeamId'=v_home_canonical
        and e.payload->>'awayTeamId'=v_away_canonical
        and nullif(e.payload->>'startTime','') is not null
        and abs(extract(epoch from (
          (e.payload->>'startTime')::timestamptz - v_start
        ))) <= 10800;

      if v_candidates <> 1 then
        v_match := null;
      end if;
    end if;

    if v_match is null
       and v_start is not null
       and v_home_name is not null
       and v_away_name is not null then
      select count(*)::integer, min(m.id)
      into v_candidates, v_match
      from futbeat_private.calendar_matches c
      join futbeat_private.entities m
        on m.id=c.match_id
      join futbeat_private.entities h
        on h.id=m.payload->>'homeTeamId' and h.kind='team'
      join futbeat_private.entities a
        on a.id=m.payload->>'awayTeamId' and a.kind='team'
      where c.start_time between v_start-interval '3 hours' and v_start+interval '3 hours'
        and m.kind='match'
        and nullif(m.payload->>'startTime','') is not null
        and futbeat_private.normalize_live_name(h.payload->>'name')
          = futbeat_private.normalize_live_name(v_home_name)
        and futbeat_private.normalize_live_name(a.payload->>'name')
          = futbeat_private.normalize_live_name(v_away_name)
        and abs(extract(epoch from (
          (m.payload->>'startTime')::timestamptz - v_start
        ))) <= 10800;

      if v_candidates <> 1 then
        v_match := null;
      end if;
    end if;

    if v_match is null then
      v_unmapped := v_unmapped || jsonb_build_array(jsonb_build_object(
        'externalMatchId',v_external,
        'home',v_home_name,
        'away',v_away_name,
        'kickoffUtc',v_start,
        'candidates',v_candidates
      ));
      continue;
    end if;

    select
      payload->>'homeTeamId',
      payload->>'awayTeamId'
    into v_home_canonical,v_away_canonical
    from futbeat_private.entities
    where id=v_match and kind='match';

    insert into futbeat_private.provider_entities(
      provider,kind,external_id,canonical_id
    )
    values('goal_api','match',v_external,v_match)
    on conflict(provider,kind,external_id)
    do update set canonical_id=excluded.canonical_id;

    if v_home_external is not null and v_home_canonical is not null then
      insert into futbeat_private.provider_entities(
        provider,kind,external_id,canonical_id
      )
      values('goal_api','team',v_home_external,v_home_canonical)
      on conflict(provider,kind,external_id)
      do update set canonical_id=excluded.canonical_id;
    end if;

    if v_away_external is not null and v_away_canonical is not null then
      insert into futbeat_private.provider_entities(
        provider,kind,external_id,canonical_id
      )
      values('goal_api','team',v_away_external,v_away_canonical)
      on conflict(provider,kind,external_id)
      do update set canonical_id=excluded.canonical_id;
    end if;

    update futbeat_private.live_match_state
    set canonical_match_id=v_match
    where provider='goal_api'
      and external_match_id=v_external
      and canonical_match_id is null;

    update futbeat_private.provider_observations
    set canonical_match_id=v_match
    where provider='goal_api'
      and external_match_id=v_external
      and canonical_match_id is null;

    update futbeat_private.live_events
    set canonical_match_id=v_match
    where provider='goal_api'
      and external_match_id=v_external
      and canonical_match_id is null;

    if exists(
      select 1
      from futbeat_private.live_match_state
      where provider='goal_api'
        and external_match_id=v_external
        and canonical_match_id=v_match
    ) then
      perform public.futbeat_publish_live_state('goal_api',v_external);
    end if;

    v_linked := v_linked + 1;
  end loop;

  return jsonb_build_object(
    'linked',v_linked,
    'alreadyLinked',v_already_linked,
    'deferredCount',v_deferred,
    'unmappedCount',jsonb_array_length(v_unmapped),
    'unmapped',v_unmapped
  );
end
$function$;
