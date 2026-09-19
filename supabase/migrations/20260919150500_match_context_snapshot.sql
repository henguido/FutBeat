-- Lightweight canonical Match Center context.
-- Returns only one match plus the entities needed to render it, avoiding the
-- multi-megabyte global snapshot for direct/deep-link navigation.

create or replace function public.futbeat_read_match_context(
  p_match_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with target as (
    select payload
    from futbeat_private.entities
    where id=p_match_id and kind='match'
    limit 1
  ),
  standing as (
    select futbeat_private.futbeat_apply_provisional_standings(
      sc.table_payload,
      sc.fetched_at
    ) as payload
    from futbeat_private.standings_cache sc
    join target t
      on sc.competition_id=t.payload->>'competitionId'
    limit 1
  ),
  relevant_team_ids as (
    select t.payload->>'homeTeamId' as id from target t
    union
    select t.payload->>'awayTeamId' as id from target t
    union
    select row.value->>'teamId' as id
    from standing s
    cross join lateral jsonb_array_elements(
      coalesce(s.payload->'rows','[]'::jsonb)
    ) row(value)
    where nullif(row.value->>'teamId','') is not null
  ),
  teams as (
    select coalesce(jsonb_agg(e.payload order by e.id),'[]'::jsonb) as value
    from futbeat_private.entities e
    where e.kind='team'
      and e.id in (select id from relevant_team_ids where id is not null)
  ),
  player_ids as (
    select sm.player_id as id
    from futbeat_private.team_squad_members sm
    join target t
      on sm.team_id in (
        t.payload->>'homeTeamId',
        t.payload->>'awayTeamId'
      )
    union
    select event.value->>'playerId' as id
    from target t
    cross join lateral jsonb_array_elements(
      coalesce(t.payload->'events','[]'::jsonb)
    ) event(value)
    where nullif(event.value->>'playerId','') is not null
  ),
  players as (
    select coalesce(jsonb_agg(e.payload order by e.id),'[]'::jsonb) as value
    from futbeat_private.entities e
    where e.kind='player'
      and e.id in (select id from player_ids where id is not null)
  ),
  competition as (
    select coalesce(jsonb_agg(e.payload),'[]'::jsonb) as value
    from futbeat_private.entities e
    join target t
      on e.id=t.payload->>'competitionId'
    where e.kind='competition'
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'demo',false,
    'updatedAt',coalesce(
      nullif(t.payload#>>'{provenance,receivedAt}',''),
      now()::text
    ),
    'coverage',jsonb_build_object('partial',false),
    'freshness',jsonb_build_object('stale',false),
    'entityRedirects','{}'::jsonb,
    'competitions',competition.value,
    'teams',teams.value,
    'players',players.value,
    'matches',jsonb_build_array(t.payload),
    'standings',case
      when standing.payload is null then '[]'::jsonb
      else jsonb_build_array(standing.payload)
    end,
    'news','[]'::jsonb,
    'transfers','[]'::jsonb
  )
  from target t
  cross join teams
  cross join players
  cross join competition
  left join standing on true
$$;

revoke all on function public.futbeat_read_match_context(text)
from public,anon,authenticated;

grant execute on function public.futbeat_read_match_context(text)
to service_role;

notify pgrst,'reload schema';
