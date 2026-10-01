-- Team profile first paint: the entity detail read must not scan the catalog.
--
-- Evidence (production, read-only, 01-oct-2026, Deportivo Saprissa):
--   * pg_stat_statements: the /v1/entity RPC (futbeat_read_entity_detail)
--     averages 989 ms over 122 calls, max 5.45 s, and the app showed nothing
--     but a spinner until it answered.
--   * The private read (plpgsql) runs its "teams" query as a cached generic
--     plan. Its predicate
--       e.kind='team' and (e.id in (...) or (p_type='competition' and
--       e.payload->>'competitionId'=competition_id))
--     cannot use the primary key under a generic plan: EXPLAIN ANALYZE of the
--     same statement with plan_cache_mode=force_generic_plan is a Parallel Seq
--     Scan over every entity (86k rows, 2,214 blocks read from disk, 227 ms;
--     the whole private read measured 222-1,275 ms) to return one team.
--
-- Fix: the same rows, as two index-served branches (team ids by primary key;
-- a competition's teams through a new partial index on the team's
-- competitionId). Everything else is copied from 20260918141000 unchanged.
-- Read-only function; no provider call, quota, cron or secret changes.

create index if not exists entities_team_competition_idx
  on futbeat_private.entities ((payload->>'competitionId'))
  where kind='team';

create or replace function futbeat_private.futbeat_read_entity_detail(
  p_type text,
  p_id text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  entity_row futbeat_private.entities;
  team_id text;
  competition_id text;
  matches_json jsonb;
  teams_json jsonb;
  competitions_json jsonb;
  players_json jsonb;
  detail_updated_at timestamptz;
begin
  if p_type not in ('team','player','competition')
     or nullif(p_id,'') is null
  then
    raise exception 'Invalid entity detail request';
  end if;

  select * into entity_row
  from futbeat_private.entities
  where id=p_id and kind=p_type;

  if not found then
    return null;
  end if;

  if p_type='competition' then
    competition_id:=p_id;
  elsif p_type='team' then
    team_id:=p_id;
    competition_id:=nullif(entity_row.payload->>'competitionId','');
  else
    team_id:=nullif(entity_row.payload->>'teamId','');
    if team_id is not null then
      select nullif(payload->>'competitionId','')
      into competition_id
      from futbeat_private.entities
      where id=team_id and kind='team';
    end if;
  end if;

  with relevant as (
    select e.payload,cm.start_time,cm.updated_at
    from futbeat_private.calendar_matches cm
    join futbeat_private.entities e
      on e.id=cm.match_id and e.kind='match'
    where (
      p_type='competition'
      and e.payload->>'competitionId'=competition_id
    ) or (
      p_type in ('team','player')
      and team_id is not null
      and (
        e.payload->>'homeTeamId'=team_id
        or e.payload->>'awayTeamId'=team_id
      )
    )
    order by abs(extract(epoch from (cm.start_time-now())))
    limit 100
  )
  select
    coalesce(jsonb_agg(payload order by start_time),'[]'::jsonb),
    max(updated_at)
  into matches_json,detail_updated_at
  from relevant;

  -- Two index-served branches (primary key; entities_team_competition_idx)
  -- instead of one OR that a generic plan answers with a catalog scan.
  with ids as (
    select distinct value->>'homeTeamId' as id
    from jsonb_array_elements(matches_json)
    union
    select distinct value->>'awayTeamId'
    from jsonb_array_elements(matches_json)
    union
    select team_id where team_id is not null
  ),
  selected as (
    select e.id,e.payload
    from futbeat_private.entities e
    where e.kind='team'
      and e.id in (select id from ids where id is not null)
    union
    select e.id,e.payload
    from futbeat_private.entities e
    where p_type='competition'
      and e.kind='team'
      and e.payload->>'competitionId'=competition_id
  )
  select coalesce(
    jsonb_agg(s.payload order by s.payload->>'name',s.id),
    '[]'::jsonb
  )
  into teams_json
  from selected s;

  with ids as (
    select distinct value->>'competitionId' as id
    from jsonb_array_elements(matches_json)
    union
    select competition_id where competition_id is not null
  )
  select coalesce(
    jsonb_agg(e.payload order by e.payload->>'country',e.payload->>'name',e.id),
    '[]'::jsonb
  )
  into competitions_json
  from futbeat_private.entities e
  where e.kind='competition'
    and e.id in (select id from ids where id is not null);

  if p_type='team' then
    select coalesce(
      jsonb_agg(e.payload order by e.payload->>'position',e.payload->>'name',e.id),
      '[]'::jsonb
    )
    into players_json
    from futbeat_private.team_squad_members sm
    join futbeat_private.entities e
      on e.id=sm.player_id and e.kind='player'
    where sm.team_id=p_id;
  elsif p_type='player' then
    players_json:=jsonb_build_array(entity_row.payload);
  else
    players_json:='[]'::jsonb;
  end if;

  if p_type='team' then
    select greatest(
      coalesce(detail_updated_at,'epoch'::timestamptz),
      coalesce(fetched_at,'epoch'::timestamptz)
    )
    into detail_updated_at
    from futbeat_private.team_detail_coverage cov
    where cov.team_id=p_id;
  end if;

  return jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',coalesce(detail_updated_at,now()),
    'freshness',jsonb_build_object('stale',false),
    'coverage',jsonb_build_object(
      'source','FutBeat',
      'partial',false,
      'live',false,
      'developmentOnly',false,
      'sources',jsonb_build_array('GOAL API')
    ),
    'competitions',competitions_json,
    'teams',teams_json,
    'players',players_json,
    'matches',matches_json,
    'standings','[]'::jsonb
  );
end;
$$;

revoke all on function futbeat_private.futbeat_read_entity_detail(text,text)
  from public,anon,authenticated;
grant execute on function futbeat_private.futbeat_read_entity_detail(text,text)
  to service_role;

notify pgrst,'reload schema';
