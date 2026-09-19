-- Provisional live standings overlay.
-- Official GOAL standings remain the baseline. We only add matches whose kickoff
-- is newer than the cached baseline, which prevents double counting.
-- Official refresh planning pauses while a competition is inside an active match
-- window so the baseline cannot jump forward mid-match.

create or replace function futbeat_private.futbeat_apply_provisional_standings(
  p_table jsonb,
  p_fetched_at timestamptz
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with input as (
    select
      p_table as table_payload,
      nullif(p_table->>'competitionId','') as competition_id
  ),
  base_rows as (
    select
      row.value as payload,
      row.ordinality::integer as base_position,
      row.value->>'teamId' as team_id,
      (row.value->>'played')::integer as played,
      (row.value->>'won')::integer as won,
      (row.value->>'drawn')::integer as drawn,
      (row.value->>'lost')::integer as lost,
      (row.value->>'gf')::integer as gf,
      (row.value->>'ga')::integer as ga,
      (row.value->>'points')::integer as points
    from input
    cross join lateral jsonb_array_elements(
      coalesce(input.table_payload->'rows','[]'::jsonb)
    ) with ordinality row(value,ordinality)
  ),
  states as (
    select
      m.id as match_id,
      m.payload->>'homeTeamId' as home_team_id,
      m.payload->>'awayTeamId' as away_team_id,
      (m.payload->>'startTime')::timestamptz as start_time,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED',
          'POSTPONED','ABANDONED','CANCELLED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then m.payload->>'status'
        else coalesce(l.status,m.payload->>'status')
      end as effective_status,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then nullif(m.payload#>>'{score,home}','')::integer
        else coalesce(
          l.home_score,
          nullif(m.payload#>>'{score,home}','')::integer
        )
      end as home_score,
      case
        when coalesce(m.payload->>'status','') in (
          'FINISHED_PENDING_VERIFICATION','VERIFIED'
        )
        and coalesce(
          nullif(m.payload#>>'{provenance,receivedAt}','')::timestamptz,
          '-infinity'::timestamptz
        ) >= coalesce(l.changed_at,'-infinity'::timestamptz)
          then nullif(m.payload#>>'{score,away}','')::integer
        else coalesce(
          l.away_score,
          nullif(m.payload#>>'{score,away}','')::integer
        )
      end as away_score
    from input
    join futbeat_private.entities m
      on m.kind='match'
     and m.payload->>'competitionId'=input.competition_id
     and nullif(m.payload->>'startTime','') is not null
    left join public.live_match_updates l
      on l.match_id=m.id
    where p_fetched_at is not null
      and (m.payload->>'startTime')::timestamptz>p_fetched_at
      and (m.payload->>'startTime')::timestamptz<=now()
  ),
  eligible_matches as (
    select s.*
    from states s
    where s.effective_status in (
      'LIVE','HALFTIME','EXTRA_TIME','PENALTIES',
      'FINISHED_PENDING_VERIFICATION','VERIFIED'
    )
      and s.home_score is not null
      and s.away_score is not null
      and exists(select 1 from base_rows b where b.team_id=s.home_team_id)
      and exists(select 1 from base_rows b where b.team_id=s.away_team_id)
  ),
  deltas as (
    select
      home_team_id as team_id,
      1 as played,
      case when home_score>away_score then 1 else 0 end as won,
      case when home_score=away_score then 1 else 0 end as drawn,
      case when home_score<away_score then 1 else 0 end as lost,
      home_score as gf,
      away_score as ga,
      case
        when home_score>away_score then 3
        when home_score=away_score then 1
        else 0
      end as points
    from eligible_matches

    union all

    select
      away_team_id,
      1,
      case when away_score>home_score then 1 else 0 end,
      case when away_score=home_score then 1 else 0 end,
      case when away_score<home_score then 1 else 0 end,
      away_score,
      home_score,
      case
        when away_score>home_score then 3
        when away_score=home_score then 1
        else 0
      end
    from eligible_matches
  ),
  aggregated as (
    select
      team_id,
      sum(played)::integer as played,
      sum(won)::integer as won,
      sum(drawn)::integer as drawn,
      sum(lost)::integer as lost,
      sum(gf)::integer as gf,
      sum(ga)::integer as ga,
      sum(points)::integer as points
    from deltas
    group by team_id
  ),
  adjusted as (
    select
      b.team_id,
      b.base_position,
      b.played+coalesce(a.played,0) as played,
      b.won+coalesce(a.won,0) as won,
      b.drawn+coalesce(a.drawn,0) as drawn,
      b.lost+coalesce(a.lost,0) as lost,
      b.gf+coalesce(a.gf,0) as gf,
      b.ga+coalesce(a.ga,0) as ga,
      b.points+coalesce(a.points,0) as points
    from base_rows b
    left join aggregated a on a.team_id=b.team_id
  ),
  ordered as (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'teamId',team_id,
          'played',played,
          'won',won,
          'drawn',drawn,
          'lost',lost,
          'gf',gf,
          'ga',ga,
          'points',points
        )
        order by
          points desc,
          (gf-ga) desc,
          gf desc,
          base_position
      ),
      '[]'::jsonb
    ) as rows
    from adjusted
  ),
  meta as (
    select
      count(*)::integer as overlay_matches,
      count(*) filter(
        where effective_status in (
          'LIVE','HALFTIME','EXTRA_TIME','PENALTIES'
        )
      )::integer as active_matches
    from eligible_matches
  )
  select case
    when input.competition_id is null
      or jsonb_typeof(input.table_payload)<>'object'
      or meta.overlay_matches=0
      then input.table_payload
    else
      (input.table_payload-'rows'-'provisional'-'updatedAt')
      || jsonb_build_object(
        'rows',ordered.rows,
        'provisional',true,
        'baselineUpdatedAt',input.table_payload->'updatedAt',
        'updatedAt',now(),
        'provisionalMatches',meta.overlay_matches,
        'activeMatches',meta.active_matches
      )
  end
  from input,ordered,meta
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
      and not exists(
        select 1
        from futbeat_private.entities active_match
        where active_match.kind='match'
          and active_match.payload->>'competitionId'=pe.canonical_id
          and nullif(active_match.payload->>'startTime','') is not null
          and coalesce(active_match.payload->>'status','') not in (
            'FINISHED_PENDING_VERIFICATION','VERIFIED',
            'POSTPONED','ABANDONED','CANCELLED'
          )
          and now() between
            (active_match.payload->>'startTime')::timestamptz-interval '5 minutes'
            and (active_match.payload->>'startTime')::timestamptz+interval '135 minutes'
      )
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

      select futbeat_private.futbeat_apply_provisional_standings(
        sc.table_payload,
        sc.fetched_at
      )
      from futbeat_private.standings_cache sc
      where sc.competition_id in (
        select id from competition_ids where id is not null
      )
    ) selected_tables(item)
  )
  select case
    when base.snapshot is null then null
    else (base.snapshot-'standings')
      || jsonb_build_object('standings',tables.value)
  end
  from base,tables
$$;

revoke all on function
  futbeat_private.futbeat_apply_provisional_standings(jsonb,timestamptz)
from public,anon,authenticated;

grant execute on function
  futbeat_private.futbeat_apply_provisional_standings(jsonb,timestamptz)
to service_role;

notify pgrst,'reload schema';
