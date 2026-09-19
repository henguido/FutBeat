-- Players / squads v2.
-- Squad calls reserve their own quota before hitting GOAL API and the squad
-- planner selects one current provider identity per canonical team.

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

  perform futbeat_private.refresh_interest_aggregates();

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

create or replace function futbeat_private.futbeat_reserve_goal_squad_call(
  p_team_id text,
  p_external_team_id text,
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
  v_id bigint;
begin
  if nullif(p_team_id,'') is null
     or nullif(p_external_team_id,'') is null
     or nullif(btrim(p_trigger_source),'') is null
     or not exists(
       select 1
       from futbeat_private.provider_entities pe
       where pe.provider='goal_api'
         and pe.kind='team'
         and pe.external_id=p_external_team_id
         and pe.canonical_id=p_team_id
     )
  then
    raise exception 'Invalid GOAL squad reservation';
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
    and call_kind in ('team-squad','team-squad-ingest')
    and reserved_at>=v_day_start
    and reserved_at<v_day_start+interval '1 day';

  if v_remaining is not null and v_remaining<=350 then
    return jsonb_build_object(
      'allowed',false,
      'reason','provider_remaining_reserve',
      'providerRemaining',v_remaining,
      'reserve',350,
      'usedToday',v_used,
      'limit',16
    );
  end if;

  if v_used>=16 then
    return jsonb_build_object(
      'allowed',false,
      'reason','squad_daily_limit',
      'providerRemaining',v_remaining,
      'reserve',350,
      'usedToday',v_used,
      'limit',16
    );
  end if;

  insert into futbeat_private.provider_call_ledger(
    provider,call_kind,trigger_source,reserved_at,metadata
  )
  values(
    'goal_api',
    'team-squad',
    left(p_trigger_source,40),
    now(),
    jsonb_build_object(
      'teamId',p_team_id,
      'externalTeamId',p_external_team_id
    )
  )
  returning id into v_id;

  return jsonb_build_object(
    'allowed',true,
    'reservationId',v_id,
    'providerRemaining',v_remaining,
    'reserve',350,
    'usedToday',v_used+1,
    'limit',16,
    'teamId',p_team_id,
    'externalTeamId',p_external_team_id
  );
end
$$;

create or replace function public.futbeat_reserve_goal_squad_call(
  p_team_id text,
  p_external_team_id text,
  p_trigger_source text default 'github-actions'
) returns jsonb
language sql
security definer
set search_path=''
as $$
  select futbeat_private.futbeat_reserve_goal_squad_call(
    p_team_id,p_external_team_id,p_trigger_source
  )
$$;

revoke all on function
  futbeat_private.futbeat_reserve_goal_squad_call(text,text,text),
  public.futbeat_reserve_goal_squad_call(text,text,text)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_reserve_goal_squad_call(text,text,text),
  public.futbeat_reserve_goal_squad_call(text,text,text)
to service_role;

notify pgrst,'reload schema';
