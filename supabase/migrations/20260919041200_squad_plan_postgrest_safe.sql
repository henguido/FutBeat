-- Make squad planning safe for PostgREST/service_role execution.
-- Interest aggregation is refreshed by preference/follow/global planning flows;
-- the five-minute squad planner only reads the latest aggregate state.

create or replace function futbeat_private.futbeat_team_squad_plan(
  p_limit integer default 3
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  result jsonb;
begin
  if p_limit<1 or p_limit>25 then
    raise exception 'Invalid squad plan limit';
  end if;

  with recent_team_ids as (
    select external_id,max(received_at) as last_seen_at
    from (
      select
        coalesce(
          raw_payload#>>'{homeTeam,id}',
          raw_payload->>'homeTeamId'
        ) as external_id,
        received_at
      from futbeat_private.provider_observations
      where provider='goal_api'
        and received_at>=now()-interval '180 days'

      union all

      select
        coalesce(
          raw_payload#>>'{awayTeam,id}',
          raw_payload->>'awayTeamId'
        ) as external_id,
        received_at
      from futbeat_private.provider_observations
      where provider='goal_api'
        and received_at>=now()-interval '180 days'
    ) observed
    where nullif(external_id,'') is not null
    group by external_id
  ),
  candidates as (
    select
      futbeat_private.futbeat_resolve_entity_id(
        'team',ci.subject_id
      ) as team_id,
      ci.priority_score,
      case
        when ci.explicit_followers>0 then 'follow'
        else 'temporary'
      end as reason
    from futbeat_private.coverage_interests ci
    where ci.subject_type='team'

    union all

    select
      futbeat_private.futbeat_resolve_entity_id('team',t.id),
      50000 as priority_score,
      'costa_rica' as reason
    from futbeat_private.entities t
    join futbeat_private.entities c
      on c.id=t.payload->>'competitionId'
     and c.kind='competition'
    where t.kind='team'
      and lower(coalesce(c.payload->>'country','')) in ('costa rica','cr')
  ),
  ranked as (
    select
      team_id,
      max(priority_score) as priority_score,
      min(reason) filter(where priority_score=(
        select max(c2.priority_score)
        from candidates c2
        where c2.team_id=candidates.team_id
      )) as reason
    from candidates
    group by team_id
  ),
  due_teams as (
    select
      r.team_id,
      r.priority_score,
      coalesce(r.reason,'interest') as reason,
      cov.fetched_at
    from ranked r
    left join futbeat_private.team_detail_coverage cov
      on cov.team_id=r.team_id
    where cov.fetched_at is null
       or cov.fetched_at<now()-interval '7 days'
  ),
  due as (
    select
      d.team_id,
      selected.external_id,
      d.priority_score,
      d.reason,
      d.fetched_at
    from due_teams d
    join lateral (
      select pe.external_id
      from futbeat_private.provider_entities pe
      left join recent_team_ids recent
        on recent.external_id=pe.external_id
      where pe.canonical_id=d.team_id
        and pe.provider='goal_api'
        and pe.kind='team'
      order by
        recent.last_seen_at desc nulls last,
        pe.external_id desc
      limit 1
    ) selected on true
    order by
      d.priority_score desc,
      d.fetched_at nulls first,
      d.team_id
    limit p_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'teamId',team_id,
        'externalTeamId',external_id,
        'priority',priority_score,
        'reason',reason,
        'lastFetchedAt',fetched_at
      )
      order by priority_score desc,fetched_at nulls first,team_id
    ),
    '[]'::jsonb
  )
  into result
  from due;

  return result;
end
$$;

notify pgrst,'reload schema';
