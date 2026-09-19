-- Publish recently hydrated, relevant players in the main FutBeat snapshot.
-- Team/entity detail already reads canonical players directly; this overlay makes
-- those players discoverable by global search without allowing the catalog to
-- grow without bound.

create or replace function public.futbeat_read_snapshot()
returns jsonb
language sql
stable
set search_path=''
as $$
  with latest as (
    select
      futbeat_private.futbeat_apply_entity_redirects_snapshot(snapshot)
        as snapshot,
      received_at
    from futbeat_private.imports
    order by received_at desc,job_id desc
    limit 1
  ),
  relevant_teams as (
    select distinct cov.team_id
    from futbeat_private.team_detail_coverage cov
    join futbeat_private.entities t
      on t.id=cov.team_id
     and t.kind='team'
    left join futbeat_private.coverage_interests ci
      on ci.subject_type='team'
     and ci.subject_id=cov.team_id
    where cov.fetched_at>=now()-interval '8 days'
      and exists(
        select 1
        from latest
        cross join lateral jsonb_array_elements(
          coalesce(latest.snapshot->'teams','[]'::jsonb)
        ) visible_team
        where visible_team.value->>'id'=cov.team_id
      )
      and (
        lower(coalesce(t.payload->>'country','')) in ('costa rica','cr')
        or coalesce(ci.explicit_followers,0)>0
        or coalesce(ci.temporary_users,0)>0
        or coalesce(ci.selected_country_users,0)>0
        or coalesce(ci.detected_country_users,0)>0
      )
  ),
  current_players as (
    select
      p.id,
      p.payload
    from relevant_teams rt
    join futbeat_private.team_squad_members sm
      on sm.team_id=rt.team_id
    join futbeat_private.entities p
      on p.id=sm.player_id
     and p.kind='player'
  ),
  player_candidates as (
    select
      legacy.ordinality::bigint as ord,
      1 as priority,
      legacy.value->>'id' as id,
      legacy.value as payload
    from latest
    cross join lateral jsonb_array_elements(
      coalesce(latest.snapshot->'players','[]'::jsonb)
    ) with ordinality legacy(value,ordinality)
    where nullif(legacy.value->>'id','') is not null

    union all

    select
      1000000::bigint
        + row_number() over(order by p.id) as ord,
      0 as priority,
      p.id,
      p.payload
    from current_players p
  ),
  ranked_players as (
    select
      ord,
      payload,
      row_number() over(
        partition by id
        order by priority,ord
      ) as rn
    from player_candidates
  ),
  merged_players as (
    select coalesce(
      jsonb_agg(payload order by ord),
      '[]'::jsonb
    ) as value
    from ranked_players
    where rn=1
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

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where exists(
        select 1
        from latest
        cross join lateral jsonb_array_elements(
          coalesce(latest.snapshot->'competitions','[]'::jsonb)
        ) competition
        where competition.value->>'id'=sc.competition_id
      )
    ) all_tables(item)
  )
  select
    (snapshot-'players'-'standings'-'freshness')
    || jsonb_build_object(
      'players',merged_players.value,
      'standings',merged_standings.value,
      'freshness',jsonb_build_object(
        'stale',
        coalesce((snapshot->>'updatedAt')::timestamptz,received_at)
          < now()-interval '6 hours'
      )
    )
  from latest,merged_players,merged_standings
$$;

notify pgrst,'reload schema';
