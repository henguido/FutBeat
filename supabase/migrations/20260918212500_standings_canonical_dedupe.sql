-- Collapse multiple provider team identities that resolve to the same canonical
-- FutBeat club instead of rejecting the whole standings table.

create or replace function futbeat_private.futbeat_store_goal_standings(
  p_competition_id text,
  p_external_league_id text,
  p_received_at timestamptz,
  p_season text,
  p_rows jsonb
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  item jsonb;
  external_team text;
  team_name text;
  team_country text;
  team_id text;
  position_value integer;
  played_value integer;
  won_value integer;
  drawn_value integer;
  lost_value integer;
  gf_value integer;
  ga_value integer;
  points_value integer;
  raw_rows jsonb := '[]'::jsonb;
  sorted_rows jsonb := '[]'::jsonb;
  table_json jsonb;
  raw_row_count integer := 0;
  row_count integer := 0;
begin
  if p_competition_id is null
     or p_external_league_id is null
     or p_received_at is null
     or jsonb_typeof(p_rows)<>'array'
     or jsonb_array_length(p_rows)<2
     or jsonb_array_length(p_rows)>100
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind='competition'
         and pe.external_id=p_external_league_id
         and pe.canonical_id=p_competition_id
     )
  then
    raise exception 'Invalid GOAL standings payload';
  end if;

  for item in select value from jsonb_array_elements(p_rows)
  loop
    external_team:=nullif(coalesce(
      item#>>'{team,id}',
      item->>'teamId',
      item->>'team_id',
      item->>'teamKey'
    ),'');
    team_name:=nullif(coalesce(
      item#>>'{team,name}',
      item->>'teamName',
      item->>'team_name'
    ),'');
    team_country:=coalesce(
      item#>>'{team,country,name}',
      item#>>'{team,country}',
      ''
    );

    if external_team is null or team_name is null then
      raise exception 'Invalid GOAL standings team';
    end if;

    begin
      position_value:=coalesce(
        nullif(item->>'overallLeaguePosition','')::integer,
        nullif(item->>'position','')::integer,
        nullif(item->>'rank','')::integer,
        raw_row_count+1
      );
      played_value:=coalesce(
        nullif(item->>'overallLeaguePlayed','')::integer,
        nullif(item->>'played','')::integer,
        0
      );
      won_value:=coalesce(
        nullif(item->>'overallLeagueW','')::integer,
        nullif(item->>'won','')::integer,
        nullif(item->>'win','')::integer,
        0
      );
      drawn_value:=coalesce(
        nullif(item->>'overallLeagueD','')::integer,
        nullif(item->>'drawn','')::integer,
        nullif(item->>'draw','')::integer,
        0
      );
      lost_value:=coalesce(
        nullif(item->>'overallLeagueL','')::integer,
        nullif(item->>'lost','')::integer,
        nullif(item->>'loss','')::integer,
        0
      );
      gf_value:=coalesce(
        nullif(item->>'overallLeagueGF','')::integer,
        nullif(item->>'goalsFor','')::integer,
        nullif(item->>'gf','')::integer,
        0
      );
      ga_value:=coalesce(
        nullif(item->>'overallLeagueGA','')::integer,
        nullif(item->>'goalsAgainst','')::integer,
        nullif(item->>'ga','')::integer,
        0
      );
      points_value:=coalesce(
        nullif(item->>'overallLeaguePTS','')::integer,
        nullif(item->>'points','')::integer,
        nullif(item->>'pts','')::integer,
        0
      );
    exception when others then
      raise exception 'Invalid GOAL standings numeric data';
    end;

    if position_value<1
       or played_value<0
       or won_value<0
       or drawn_value<0
       or lost_value<0
       or gf_value<0
       or ga_value<0
       or points_value<0
    then
      raise exception 'Invalid GOAL standings values';
    end if;

    team_id:=futbeat_private.futbeat_resolve_global_entity(
      'goal_api','team',external_team,team_name,team_country,''
    );

    raw_rows:=raw_rows || jsonb_build_array(jsonb_build_object(
      'position',position_value,
      'teamId',team_id,
      'played',played_value,
      'won',won_value,
      'drawn',drawn_value,
      'lost',lost_value,
      'gf',gf_value,
      'ga',ga_value,
      'points',points_value
    ));
    raw_row_count:=raw_row_count+1;
  end loop;

  with ranked as (
    select
      value,
      row_number() over(
        partition by value->>'teamId'
        order by
          (value->>'played')::integer desc,
          (value->>'points')::integer desc,
          (value->>'position')::integer,
          ((value->>'gf')::integer-(value->>'ga')::integer) desc,
          (value->>'gf')::integer desc
      ) as rn
    from jsonb_array_elements(raw_rows)
  )
  select coalesce(
    jsonb_agg(
      value-'position'
      order by
        (value->>'position')::integer,
        (value->>'points')::integer desc,
        ((value->>'gf')::integer-(value->>'ga')::integer) desc,
        (value->>'gf')::integer desc,
        value->>'teamId'
    ),
    '[]'::jsonb
  )
  into sorted_rows
  from ranked
  where rn=1;

  row_count:=jsonb_array_length(sorted_rows);
  if row_count<2 then
    raise exception 'Insufficient canonical teams in standings';
  end if;

  table_json:=jsonb_build_object(
    'competitionId',p_competition_id,
    'season',coalesce(p_season,''),
    'provisional',false,
    'source','GOAL API',
    'updatedAt',p_received_at,
    'rows',sorted_rows
  );

  insert into futbeat_private.standings_cache(
    competition_id,provider,external_league_id,season,table_payload,fetched_at
  )
  values(
    p_competition_id,'goal_api',p_external_league_id,
    coalesce(p_season,''),table_json,p_received_at
  )
  on conflict(competition_id) do update set
    provider=excluded.provider,
    external_league_id=excluded.external_league_id,
    season=excluded.season,
    table_payload=excluded.table_payload,
    fetched_at=excluded.fetched_at;

  return jsonb_build_object(
    'competitionId',p_competition_id,
    'rows',row_count,
    'rawRows',raw_row_count,
    'duplicatesCollapsed',raw_row_count-row_count,
    'fetchedAt',p_received_at
  );
end
$$;

notify pgrst,'reload schema';
