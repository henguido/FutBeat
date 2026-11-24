begin;
set local lock_timeout = '2s';
do $guard$
begin
  if md5(rtrim(pg_get_functiondef('futbeat_private.build_compact_calendar(date,date,text)'::regprocedure), E'\n')) <> '201d1f20cdb9eed211ae4ac8a4d15d45' then
    raise exception 'Unexpected definition for futbeat_private.build_compact_calendar(date,date,text)';
  end if;
end
$guard$;

CREATE OR REPLACE FUNCTION futbeat_private.build_compact_calendar(p_from_date date, p_to_date date, p_timezone text DEFAULT 'America/Costa_Rica'::text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  with bounds as (
    select p_from_date::timestamp at time zone p_timezone lo,
      (p_to_date+1)::timestamp at time zone p_timezone hi
  ), projected as materialized (
    -- The list projection resolves team/competition redirects (chained
    -- included) exactly once; events are only built for live matches.
    select futbeat_private.match_read_model_core(e.payload,false) item,c.updated_at
    from bounds b join futbeat_private.calendar_matches c
      on c.start_time>=b.lo and c.start_time<b.hi
    join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  ), ranked as materialized (
    select item,updated_at,item->>'id' id,
      nullif(item->>'competitionId','') comp,
      nullif(item->>'homeTeamId','') home,nullif(item->>'awayTeamId','') away,
      futbeat_private.try_timestamptz(item->>'startTime') kickoff,
      futbeat_private.fixture_display_rank(item) rank,
      futbeat_private.fixture_final_score(item) final_score,
      futbeat_private.fixture_is_ghost(item) ghost
    from projected
  ), reconciled as materialized (
    -- One canonical fixture is listed once (see the header for the evidence
    -- levels). Nothing is deleted; the hidden twin stays reachable by id.
    select a.item,a.updated_at from ranked a
    where not exists(
        -- The equalities are restated outside same_fixture_level so the
        -- planner hashes on them (a day is one pass, not a pairwise scan).
        select 1 from ranked b
        where b.comp=a.comp and b.home=a.home and b.away=a.away
          and b.id<>a.id and (b.rank,b.id)<(a.rank,a.id)
          and futbeat_private.same_fixture_level(a.id,a.comp,a.home,a.away,a.kickoff,a.final_score,
            b.id,b.comp,b.home,b.away,b.kickoff,b.final_score) is not null)
      -- A scheduled ghost whose real twin (played or playing, kicking off
      -- after it) may be on another calendar day. Far-future days never
      -- have such a twin.
      and not (a.ghost and a.kickoff<now()+interval '24 hours'
        and futbeat_private.fixture_played_twin(a.id,a.comp,a.home,a.away,a.kickoff) is not null)
  ), source as (
    select jsonb_build_object(
      'updatedAt',coalesce((select max(greatest(
        nullif(item#>>'{provenance,receivedAt}','')::timestamptz,
        nullif(item->>'liveChangedAt','')::timestamptz,updated_at)) from reconciled),now()),
      'freshness',jsonb_build_object('stale',false),
      'coverage',jsonb_build_object('source','FutBeat','partial',not complete,
        'live',false,'developmentOnly',false,'sources',jsonb_build_array('GOAL API'),
        'calendar',jsonb_build_object('from',p_from_date,'to',p_to_date,
          'timezone',p_timezone,'complete',complete))) value
    from (
      select count(*)=(select ((hi-interval '1 microsecond') at time zone 'UTC')::date
        -(lo at time zone 'UTC')::date+1 from bounds) complete
      from futbeat_private.calendar_coverage,bounds
      where provider='goal_api' and provider_date between (lo at time zone 'UTC')::date
        and ((hi-interval '1 microsecond') at time zone 'UTC')::date
    ) coverage
  ), team_items as (
    select e.payload item from futbeat_private.entities e where e.kind='team'
      and e.id in (select item->>'homeTeamId' from reconciled
                   union select item->>'awayTeamId' from reconciled)
  ), competition_items as (
    select e.payload item from futbeat_private.entities e where e.kind='competition'
      and e.id in (select item->>'competitionId' from reconciled)
  ), compact_teams as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','shortName',item->'shortName',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    )) order by item->>'name',item->>'id'),'[]'::jsonb) value
    from team_items
  ), compact_competitions as (
    select coalesce(jsonb_agg((jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','name',item->'name','country',item->'country',
      'media',case when item->'media' is null then null else jsonb_strip_nulls(
        jsonb_build_object('url',item#>'{media,url}','verificationStatus',
          item#>'{media,verificationStatus}')) end
    ))||jsonb_build_object(
      'countryCode',meta.country_code,
      'relevanceScore',coalesce(meta.relevance_score,
        futbeat_private.derived_competition_relevance(item->>'competitionClass',item->>'audienceClass')),
      'competitionClass',coalesce(meta.competition_class,'other'),
      'domesticTier',meta.domestic_tier,
      'isPrimaryDomestic',coalesce(meta.is_primary_domestic,false),
      'isGlobalRelevant',coalesce(meta.is_global_relevant,false),
      'audienceClass',coalesce(meta.audience_class,'unknown'),
      'relevanceSource',coalesce(meta.source,'derived')
    )) order by item->>'country',item->>'name',item->>'id'),'[]'::jsonb) value
    from competition_items
    left join futbeat_private.competition_editorial_metadata meta
      on meta.competition_id=item->>'id'
  ), compact_matches as (
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
      'id',item->'id','competitionId',item->'competitionId',
      'homeTeamId',item->'homeTeamId','awayTeamId',item->'awayTeamId',
      'startTime',item->'startTime','status',item->'status',
      'score',item->'score','minute',item->'minute',
      'hasPlayedEvidence',item->'hasPlayedEvidence',
      'latestEvent',case when item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
        then (select event from jsonb_array_elements(item->'events') event
          order by (event->>'minute')::integer desc nulls last,
            (event->>'extraMinute')::integer desc nulls last,event->>'id' desc limit 1) end
    )) order by item->>'startTime',item->>'id'),'[]'::jsonb) value
    from reconciled
  )
  select jsonb_build_object(
    'schemaVersion',1,'demo',false,'updatedAt',source.value->'updatedAt',
    'coverage',source.value->'coverage','freshness',source.value->'freshness',
    'teams',compact_teams.value,'competitions',compact_competitions.value,
    'matches',compact_matches.value,'players','[]'::jsonb,'standings','[]'::jsonb)
  from source,compact_teams,compact_competitions,compact_matches
$function$;

commit;
