-- Canonical standings cache driven by GOAL API.
-- Standings are stored separately from legacy snapshots so tables can refresh
-- independently without rebuilding the whole football catalog.

create table if not exists futbeat_private.standings_cache(
  competition_id text primary key references futbeat_private.entities(id) on delete cascade,
  provider text not null check(provider='goal_api'),
  external_league_id text not null,
  season text not null default '',
  table_payload jsonb not null check(jsonb_typeof(table_payload)='object'),
  fetched_at timestamptz not null
);

create index if not exists standings_cache_fetched_idx
  on futbeat_private.standings_cache(fetched_at);

alter table futbeat_private.standings_cache enable row level security;
revoke all on futbeat_private.standings_cache from public,anon,authenticated;
grant select,insert,update,delete on futbeat_private.standings_cache to service_role;

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
        row_count+1
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

    if exists(
      select 1
      from jsonb_array_elements(raw_rows) r
      where r->>'teamId'=team_id
    ) then
      raise exception 'Duplicate canonical team in standings';
    end if;

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
    row_count:=row_count+1;
  end loop;

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
  from jsonb_array_elements(raw_rows);

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
    'fetchedAt',p_received_at
  );
end
$$;

create or replace function futbeat_private.futbeat_reserve_goal_standings_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_day_start timestamptz :=
    date_trunc('day',now() at time zone 'UTC') at time zone 'UTC';
  v_remaining integer;
  v_used integer;
  v_competition_id text;
  v_external_league_id text;
  v_name text;
  v_country text;
  v_fetched_at timestamptz;
  v_id bigint;
begin
  if p_trigger_source is null or btrim(p_trigger_source)='' then
    raise exception 'trigger_source is required';
  end if;

  perform pg_advisory_xact_lock(
    hashtext('futbeat-provider-quota:goal_api:'||v_day_start::date::text)
  );

  select provider_remaining
  into v_remaining
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and provider_remaining is not null
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day'
  order by coalesce(completed_at,reserved_at) desc,id desc
  limit 1;

  select count(*)::integer
  into v_used
  from futbeat_private.provider_call_ledger
  where provider='goal_api'
    and call_kind='standings'
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  if v_remaining is not null and v_remaining<=350 then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_remaining,
      'reserve',350,
      'usedToday',v_used
    );
  end if;

  if v_used>=12 then
    return jsonb_build_object(
      'allowed',false,
      'reason','standings_daily_limit',
      'usedToday',v_used,
      'limit',12,
      'providerRemaining',v_remaining
    );
  end if;

  with candidates as (
    select
      pe.canonical_id as competition_id,
      pe.external_id as external_league_id,
      e.payload->>'name' as name,
      e.payload->>'country' as country,
      sc.fetched_at,
      coalesce(ci.priority_score,0) as interest_priority,
      case
        when lower(coalesce(e.payload->>'country',''))='costa rica' then 100000
        else 0
      end as country_priority,
      count(m.id) filter(
        where nullif(m.payload->>'startTime','') is not null
          and (m.payload->>'startTime')::timestamptz
              between now()-interval '45 days' and now()+interval '45 days'
      ) as nearby_matches
    from futbeat_private.provider_entities pe
    join futbeat_private.entities e
      on e.id=pe.canonical_id and e.kind='competition'
    left join futbeat_private.standings_cache sc
      on sc.competition_id=pe.canonical_id
    left join futbeat_private.coverage_interests ci
      on ci.subject_type='competition'
     and ci.subject_id=pe.canonical_id
    left join futbeat_private.entities m
      on m.kind='match'
     and m.payload->>'competitionId'=pe.canonical_id
    where pe.provider='goal_api'
      and pe.kind='competition'
    group by
      pe.canonical_id,pe.external_id,e.payload,sc.fetched_at,ci.priority_score
    having count(m.id) filter(
      where nullif(m.payload->>'startTime','') is not null
        and (m.payload->>'startTime')::timestamptz
            between now()-interval '45 days' and now()+interval '45 days'
    )>0
  )
  select
    competition_id,external_league_id,name,country,fetched_at
  into
    v_competition_id,v_external_league_id,v_name,v_country,v_fetched_at
  from candidates
  where fetched_at is null or fetched_at<now()-interval '6 hours'
  order by
    country_priority desc,
    interest_priority desc,
    nearby_matches desc,
    fetched_at nulls first,
    name,
    competition_id
  limit 1;

  if v_competition_id is null then
    return jsonb_build_object(
      'allowed',false,
      'reason','no_standings_due',
      'usedToday',v_used,
      'providerRemaining',v_remaining
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api','standings',left(p_trigger_source,40),now(),
    jsonb_build_object(
      'competitionId',v_competition_id,
      'externalLeagueId',v_external_league_id
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'competitionId',v_competition_id,
    'externalLeagueId',v_external_league_id,
    'name',v_name,
    'country',v_country,
    'lastFetchedAt',v_fetched_at,
    'providerRemaining',v_remaining,
    'reserve',350,
    'usedToday',v_used+1,
    'limit',12
  );
end
$$;

create or replace function public.futbeat_store_goal_standings(
  p_competition_id text,
  p_external_league_id text,
  p_received_at timestamptz,
  p_season text,
  p_rows jsonb
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_store_goal_standings(
    p_competition_id,p_external_league_id,p_received_at,p_season,p_rows
  )
$$;

create or replace function public.futbeat_reserve_goal_standings_call(
  p_trigger_source text default 'github-actions'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_goal_standings_call(p_trigger_source)
$$;

create or replace function public.futbeat_read_snapshot()
returns jsonb
language sql
stable
set search_path=''
as $$
  with latest as (
    select snapshot,received_at
    from futbeat_private.imports
    order by received_at desc,job_id desc
    limit 1
  ),
  merged_standings as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from latest
      cross join lateral jsonb_array_elements(
        coalesce(latest.snapshot->'standings','[]'::jsonb)
      ) legacy
      where not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select sc.table_payload
      from futbeat_private.standings_cache sc
    ) all_tables
  )
  select
    (snapshot-'standings'-'freshness')
    || jsonb_build_object(
      'standings',merged_standings.value,
      'freshness',jsonb_build_object(
        'stale',
        coalesce((snapshot->>'updatedAt')::timestamptz,received_at)
          < now()-interval '6 hours'
      )
    )
  from latest,merged_standings
$$;

create or replace function public.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with base as (
    select futbeat_private.futbeat_read_entity_detail(p_type,p_id) as snapshot
  ),
  competition_ids as (
    select distinct value->>'competitionId' as id
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'matches','[]'::jsonb)
    )
    where nullif(value->>'competitionId','') is not null

    union

    select distinct value->>'id'
    from base
    cross join lateral jsonb_array_elements(
      coalesce(base.snapshot->'competitions','[]'::jsonb)
    )
    where nullif(value->>'id','') is not null

    union

    select p_id where p_type='competition'
  ),
  tables as (
    select coalesce(jsonb_agg(item),'[]'::jsonb) as value
    from (
      select legacy.value as item
      from base
      cross join lateral jsonb_array_elements(
        coalesce(base.snapshot->'standings','[]'::jsonb)
      ) legacy
      where legacy.value->>'competitionId' in (
        select id from competition_ids where id is not null
      )
      and not exists(
        select 1
        from futbeat_private.standings_cache sc
        where sc.competition_id=legacy.value->>'competitionId'
      )

      union all

      select sc.table_payload
      from futbeat_private.standings_cache sc
      where sc.competition_id in (
        select id from competition_ids where id is not null
      )
    ) selected_tables
  )
  select case
    when base.snapshot is null then null
    else (base.snapshot-'standings')
      || jsonb_build_object('standings',tables.value)
  end
  from base,tables
$$;

revoke all on function
  futbeat_private.futbeat_store_goal_standings(text,text,timestamptz,text,jsonb),
  futbeat_private.futbeat_reserve_goal_standings_call(text),
  public.futbeat_store_goal_standings(text,text,timestamptz,text,jsonb),
  public.futbeat_reserve_goal_standings_call(text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_store_goal_standings(text,text,timestamptz,text,jsonb),
  futbeat_private.futbeat_reserve_goal_standings_call(text),
  public.futbeat_store_goal_standings(text,text,timestamptz,text,jsonb),
  public.futbeat_reserve_goal_standings_call(text)
to service_role;

notify pgrst,'reload schema';
