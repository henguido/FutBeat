-- Partidos feed: one canonical fixture is listed exactly once.
--
-- Cause: canonical match identity is per provider external id. The same
-- real fixture can be stored as two match entities when the primary
-- provider re-issues it under a new id (the old entity stays as a
-- scheduled "ghost" that never receives evidence), when a second provider
-- ingests it, or after two team identities are merged. There is no
-- match-level merge, and none is introduced here (nothing is deleted).
--
-- Evidence (read-only production diagnostic, 12 965 calendar matches over
-- 28 days, 5 duplicate pairs): every pair shared the SAME canonical
-- competition; 2 were cross-provider copies (same score, kickoff equal or
-- 1 h apart), 2 were re-issued fixtures 2 h apart, 1 was a re-issued
-- fixture 18 h apart (played twin + scheduled ghost). The ghost always had
-- PROVISIONAL provenance and no provider observation. Re-checked over 134
-- days (27 420 matches): 6 same-competition pairs within 24 h, all real
-- duplicates (3 cross-provider copies, 3 GOAL re-issues 0.5-3 h apart, two
-- of them both still scheduled); no legitimate double-header.
--
-- Rule (generic; canonical ids only, never names, providers or fixtures).
-- Base, always required: same canonical competition, same canonical home
-- team, same canonical away team (redirects resolved), home <> away.
-- Then, by decreasing strength of evidence:
--   exact_kickoff      kickoff within 5 minutes.
--   single_evidence_3h kickoff within 3 hours AND at most one of the two
--                      has its own provider observation trail (two games
--                      that were both really played, e.g. a friendly
--                      double-header, each have one and are never merged).
--   ghost_24h          kickoff within 24 hours AND one is a scheduled
--                      ghost (scheduled status, no played evidence) whose
--                      kickoff is EARLIER than the other one, which is
--                      finished or live (a postponed / re-issued fixture:
--                      the old time passed without any evidence). A ghost
--                      LATER than a played twin may be a second real game
--                      (double-header) and is never hidden by this level.
-- Never: two FINISHED matches with different final scores (two results
-- are two games). Different competitions are NEVER merged (other squads of
-- the same clubs, friendlies); such pairs are only reported for review by
-- duplicate_calendar_fixtures (level cross_competition_review).
--
-- The survivor: finished > live > played evidence > scheduled > called
-- off, then VERIFIED provenance, then the newest canonical evidence, then
-- the id (deterministic).
--
-- Base: build_compact_calendar from
-- 20260924100000_calendar_snapshot_materialization.sql (only the match
-- selection changes). Snapshots are rebuilt by the existing versioning; no
-- provider call, cron, quota or ledger change.

-- Lower is better. Text so that (rank,id) is one total order.
create or replace function futbeat_private.fixture_display_rank(p_item jsonb)
returns text language sql stable set search_path='' as $$
  select case
      when p_item->>'status' in ('VERIFIED','FINISHED_PENDING_VERIFICATION') then '0'
      when p_item->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then '1'
      when p_item->>'status' in ('POSTPONED','CANCELLED','ABANDONED','SUSPENDED') then '4'
      when coalesce(p_item->>'hasPlayedEvidence','')='true' then '2'
      else '3' end
    -- Reconciled / verified evidence before a provisional calendar copy.
    ||case when p_item#>>'{provenance,verificationStatus}'='VERIFIED' then '0' else '1' end
    -- Newest canonical evidence first (inverted epoch, fixed width).
    ||'|'||lpad((9999999999-coalesce(extract(epoch from futbeat_private.try_timestamptz(
      p_item#>>'{provenance,receivedAt}'))::bigint,0))::text,10,'0')
$$;

-- "home-away" of a FINISHED match with a complete score; null otherwise.
create or replace function futbeat_private.fixture_final_score(p_item jsonb)
returns text language sql immutable set search_path='' as $$
  select case when p_item->>'status' in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
      and futbeat_private.safe_result_integer(p_item#>>'{score,home}') is not null
      and futbeat_private.safe_result_integer(p_item#>>'{score,away}') is not null
    then futbeat_private.safe_result_integer(p_item#>>'{score,home}')||'-'
      ||futbeat_private.safe_result_integer(p_item#>>'{score,away}') end
$$;

-- A scheduled entity that never received played evidence.
create or replace function futbeat_private.fixture_is_ghost(p_item jsonb)
returns boolean language sql immutable set search_path='' as $$
  select coalesce(p_item->>'status' in ('DISCOVERED','SCHEDULED','PRE_MATCH'),false)
    and coalesce(p_item->>'hasPlayedEvidence','')<>'true'
$$;

-- The entity has its own provider observation trail (it was really polled).
create or replace function futbeat_private.fixture_has_observations(p_match_id text)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(select 1 from futbeat_private.provider_observations o
    where o.canonical_match_id=p_match_id)
$$;

-- Evidence level at which two calendar matches are the same fixture, or
-- null. Ids are canonical (redirects resolved by the caller).
create or replace function futbeat_private.same_fixture_level(
  a_id text,a_comp text,a_home text,a_away text,a_kickoff timestamptz,a_final text,
  b_id text,b_comp text,b_home text,b_away text,b_kickoff timestamptz,b_final text
) returns text language plpgsql stable security definer set search_path='' as $$
declare v_diff numeric;
begin
  if a_id=b_id or a_comp is null or a_comp is distinct from b_comp
     or a_home is null or a_away is null or a_home=a_away
     or a_home is distinct from b_home or a_away is distinct from b_away
     or a_kickoff is null or b_kickoff is null then
    return null;
  end if;
  -- Two different final results are two different games.
  if a_final is not null and b_final is not null and a_final<>b_final then
    return null;
  end if;
  v_diff:=abs(extract(epoch from (b_kickoff-a_kickoff)));
  if v_diff<=300 then return 'exact_kickoff'; end if;
  if v_diff<=10800 and not (futbeat_private.fixture_has_observations(a_id)
      and futbeat_private.fixture_has_observations(b_id)) then
    return 'single_evidence_3h';
  end if;
  return null;
end $$;

-- For a scheduled ghost: the id of a finished / live match of the same
-- competition and teams kicking off AFTER it, within 24 hours (any calendar
-- day), or null. Never a twin before the ghost: a later scheduled game of
-- the same pairing can be a real second game.
create or replace function futbeat_private.fixture_played_twin(
  p_id text,p_comp text,p_home text,p_away text,p_kickoff timestamptz
) returns text language sql stable security definer set search_path='' as $$
  select x.id from futbeat_private.entities x
  where x.kind='match' and x.id<>p_id and p_home<>p_away and p_comp is not null
    and x.payload->>'homeTeamId'=p_home and x.payload->>'awayTeamId'=p_away
    and futbeat_private.try_timestamptz(x.payload->>'startTime')>p_kickoff
    and futbeat_private.try_timestamptz(x.payload->>'startTime')<=p_kickoff+interval '24 hours'
    and futbeat_private.futbeat_resolve_entity_id('competition',x.payload->>'competitionId')=p_comp
    and futbeat_private.match_read_model_core(x.payload,false)->>'status'
      in ('VERIFIED','FINISHED_PENDING_VERIFICATION','LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
  order by x.id limit 1
$$;

-- Read-only diagnostic for a calendar window: what the projection hides
-- (levels exact_kickoff, single_evidence_3h, ghost_24h) and the pairs it
-- deliberately does NOT merge but a human may want to review
-- (cross_competition_review: same teams within 3 hours, other competition).
create or replace function futbeat_private.duplicate_calendar_fixtures(
  p_from_date date,p_to_date date
) returns table(level text,kept_match_id text,hidden_match_id text,home_team_id text,away_team_id text,
  kept_kickoff timestamptz,hidden_kickoff timestamptz)
language sql stable security definer set search_path='' as $$
  with ranked as materialized (
    select item->>'id' id,nullif(item->>'competitionId','') comp,
      nullif(item->>'homeTeamId','') home,nullif(item->>'awayTeamId','') away,
      futbeat_private.try_timestamptz(item->>'startTime') kickoff,
      futbeat_private.fixture_display_rank(item) rank,
      futbeat_private.fixture_final_score(item) final_score,
      futbeat_private.fixture_is_ghost(item) ghost
    from (
      select futbeat_private.match_read_model_core(e.payload,false) item
      from futbeat_private.calendar_matches c
      join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
      where c.start_time>=p_from_date::timestamp at time zone 'UTC'
        and c.start_time<(p_to_date+1)::timestamp at time zone 'UTC'
    ) projected
  )
  select futbeat_private.same_fixture_level(a.id,a.comp,a.home,a.away,a.kickoff,a.final_score,
      b.id,b.comp,b.home,b.away,b.kickoff,b.final_score),b.id,a.id,a.home,a.away,b.kickoff,a.kickoff
  from ranked a join ranked b on b.comp=a.comp and b.home=a.home and b.away=a.away and b.id<>a.id
    and (b.rank,b.id)<(a.rank,a.id)
    and futbeat_private.same_fixture_level(a.id,a.comp,a.home,a.away,a.kickoff,a.final_score,
      b.id,b.comp,b.home,b.away,b.kickoff,b.final_score) is not null
  union all
  select 'ghost_24h',t.id,a.id,a.home,a.away,
    futbeat_private.try_timestamptz((select x.payload->>'startTime' from futbeat_private.entities x where x.id=t.id)),a.kickoff
  from ranked a cross join lateral (
    select futbeat_private.fixture_played_twin(a.id,a.comp,a.home,a.away,a.kickoff) id) t
  where a.ghost and t.id is not null
    and not exists(select 1 from ranked b where b.comp=a.comp and b.home=a.home and b.away=a.away
      and b.id<>a.id and (b.rank,b.id)<(a.rank,a.id)
      and futbeat_private.same_fixture_level(a.id,a.comp,a.home,a.away,a.kickoff,a.final_score,
        b.id,b.comp,b.home,b.away,b.kickoff,b.final_score) is not null)
  union all
  select 'cross_competition_review',b.id,a.id,a.home,a.away,b.kickoff,a.kickoff
  from ranked a join ranked b on b.home=a.home and b.away=a.away and a.home<>a.away
    and a.id<b.id and a.comp is distinct from b.comp
    and abs(extract(epoch from (b.kickoff-a.kickoff)))<=10800
$$;

create or replace function futbeat_private.build_compact_calendar(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
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
$$;

-- Stored day snapshots were built with the previous selection, and their
-- version only follows the data: a complete past day would keep a duplicate
-- for up to calendarHistoryCompleteDays. Expire them (nothing is deleted):
-- the next read rebuilds a small day inline and serves a big one stale while
-- the snapshot worker rebuilds it.
update futbeat_private.compact_calendar_cache set expires_at=now() where expires_at>now();

revoke all on function
  futbeat_private.fixture_display_rank(jsonb),
  futbeat_private.fixture_final_score(jsonb),
  futbeat_private.fixture_is_ghost(jsonb),
  futbeat_private.fixture_has_observations(text),
  futbeat_private.same_fixture_level(text,text,text,text,timestamptz,text,text,text,text,text,timestamptz,text),
  futbeat_private.fixture_played_twin(text,text,text,text,timestamptz),
  futbeat_private.duplicate_calendar_fixtures(date,date)
from public,anon,authenticated;

notify pgrst,'reload schema';
