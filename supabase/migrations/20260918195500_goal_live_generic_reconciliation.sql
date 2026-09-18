-- Generic GOAL API LIVE identity reconciliation.
-- Links a live provider fixture to an existing FutBeat match by stable provider
-- identity first, then by home/away teams + kickoff when the match was created
-- before the GOAL mapping existed.

create or replace function futbeat_private.normalize_live_name(value text)
returns text
language sql
immutable
set search_path=''
as $$
  select trim(regexp_replace(
    translate(
      lower(coalesce(value,'')),
      'áàäâãåéèëêíìïîóòöôõúùüûñç',
      'aaaaaaeeeeiiiiooooouuuunc'
    ),
    '[^a-z0-9]+',
    ' ',
    'g'
  ));
$$;

create or replace function futbeat_private.futbeat_link_goal_live_matches(
  p_fixtures jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
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
      from futbeat_private.entities m
      join futbeat_private.entities h
        on h.id=m.payload->>'homeTeamId' and h.kind='team'
      join futbeat_private.entities a
        on a.id=m.payload->>'awayTeamId' and a.kind='team'
      where m.kind='match'
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
    'unmappedCount',jsonb_array_length(v_unmapped),
    'unmapped',v_unmapped
  );
end
$$;

create or replace function public.futbeat_link_goal_live_matches(
  p_fixtures jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_link_goal_live_matches(p_fixtures)
$$;

revoke all on function
  futbeat_private.futbeat_link_goal_live_matches(jsonb),
  public.futbeat_link_goal_live_matches(jsonb)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_link_goal_live_matches(jsonb),
  public.futbeat_link_goal_live_matches(jsonb)
to service_role;

-- Reconcile recent observations immediately so existing SCHEDULED cards do not
-- have to wait for a changed provider payload.
do $$
declare
  v_recent jsonb;
begin
  select jsonb_agg(raw_payload)
  into v_recent
  from (
    select distinct on (external_match_id)
      external_match_id,
      raw_payload
    from futbeat_private.provider_observations
    where provider='goal_api'
      and canonical_match_id is null
      and received_at>=now()-interval '24 hours'
    order by external_match_id,received_at desc
  ) q;

  if v_recent is not null and jsonb_array_length(v_recent)>0 then
    perform futbeat_private.futbeat_link_goal_live_matches(v_recent);
  end if;
end
$$;

notify pgrst,'reload schema';
