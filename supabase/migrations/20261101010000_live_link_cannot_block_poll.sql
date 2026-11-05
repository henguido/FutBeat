-- BE-237: a live poll must survive fixtures the catalogue does not know.
--
-- Production 2026-10-31: every fixture that missed the team lookup scanned all
-- 46,933 match entities by name, 1.17 s each. About seven new fixtures passed the
-- 8 s statement limit; the rollback linked none of them, so every later poll
-- repeated the same work and the live feed stayed down from 13:05 UTC. The name
-- lookup now starts from calendar_matches (9 ms in production), and both
-- functions stop early so what was already linked commits.

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

CREATE OR REPLACE FUNCTION futbeat_private.link_and_discover_goal_live_matches(p_fixtures jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_result jsonb; v_fixture jsonb; v_out jsonb; v_ext text; v_match text;
  v_relinked integer:=0; v_created integer:=0; v_still jsonb:='[]'::jsonb; v_unmapped jsonb;
  v_reported text[];
  -- BE-237: discovery stops with room to commit, see the linker.
  v_deadline timestamptz:=clock_timestamp()+interval '6 seconds';
begin
  v_result:=futbeat_private.futbeat_link_goal_live_matches(p_fixtures);
  v_unmapped:=coalesce(v_result->'unmapped','[]'::jsonb);
  if jsonb_array_length(v_unmapped)=0 then
    return v_result||jsonb_build_object('relinked',0,'created',0);
  end if;
  select coalesce(array_agg(distinct nullif(coalesce(value->>'apiId',value->>'id'),'')),'{}')
    into v_reported from jsonb_array_elements(p_fixtures);
  -- Ascending provider id: identity locks are always taken in the same
  -- order as the catalogue resolver takes them (no lock-order deadlock).
  for v_fixture in select value from jsonb_array_elements(p_fixtures)
      order by nullif(coalesce(value->>'apiId',value->>'id'),'') loop
    v_ext:=nullif(coalesce(v_fixture->>'apiId',v_fixture->>'id'),'');
    if v_ext is null or not exists(select 1 from jsonb_array_elements(v_unmapped) u
        where u->>'externalMatchId'=v_ext) then
      continue;
    end if;
    if clock_timestamp()>v_deadline then
      v_still:=v_still||(select jsonb_agg(u||jsonb_build_object('discovery','deadline'))
        from jsonb_array_elements(v_unmapped) u where u->>'externalMatchId'=v_ext);
      continue;
    end if;
    v_out:=futbeat_private.discover_goal_live_match(v_fixture,v_reported);
    if v_out->>'outcome' in ('relinked','created','already_linked') then
      v_match:=v_out->>'matchId';
      if v_out->>'outcome'='relinked' then v_relinked:=v_relinked+1;
      elsif v_out->>'outcome'='created' then v_created:=v_created+1; end if;
      -- Evidence stored while the fixture was unmapped now belongs to it.
      update futbeat_private.live_match_state set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.provider_observations set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      update futbeat_private.live_events set canonical_match_id=v_match
       where provider='goal_api' and external_match_id=v_ext and canonical_match_id is null;
      if exists(select 1 from futbeat_private.live_match_state
          where provider='goal_api' and external_match_id=v_ext and canonical_match_id=v_match) then
        perform public.futbeat_publish_live_state('goal_api',v_ext);
      end if;
    else
      v_still:=v_still||(select jsonb_agg(u||jsonb_build_object('discovery',v_out->>'reason'))
        from jsonb_array_elements(v_unmapped) u where u->>'externalMatchId'=v_ext);
    end if;
  end loop;
  return v_result||jsonb_build_object(
    'linked',coalesce((v_result->>'linked')::integer,0)+v_relinked+v_created,
    'relinked',v_relinked,'created',v_created,
    'unmappedCount',jsonb_array_length(v_still),'unmapped',v_still);
end $function$;
