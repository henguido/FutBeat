-- Read-only field reconciliation. No lifecycle writes, provider work or seed changes.
-- Scores are stored evidence, never inferred by counting events.
create index if not exists observations_match_score_received_idx
 on futbeat_private.provider_observations(canonical_match_id,received_at desc,id desc)
 where home_score is not null and away_score is not null;

create or replace function futbeat_private.match_read_model(p_match jsonb)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
 v_score jsonb; v_status text:=p_match->>'status'; v_events jsonb;
 v_start timestamptz:=(p_match->>'startTime')::timestamptz;
 v_received timestamptz:=coalesce(nullif(p_match#>>'{provenance,receivedAt}','')::timestamptz,'-infinity');
 v_evidence record;
begin
 if futbeat_private.safe_result_integer(p_match#>>'{score,home}') is null
   or futbeat_private.safe_result_integer(p_match#>>'{score,away}') is null then
   p_match:=p_match-'score';
 end if;
 -- Expire stale LIVE presentation, but retain its real score independently.
 if v_status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES')
   and v_received<now()-interval '15 minutes' then v_status:='SCHEDULED'; end if;
 -- Terminal canonical scores are authoritative. Otherwise choose the newest
 -- complete score field, not the newest status-only observation.
 if v_status in ('VERIFIED','FINISHED_PENDING_VERIFICATION') then
   v_score:=nullif(p_match->'score','null'::jsonb);
 end if;
 if v_score is null then
   select score into v_score from (
     select nullif(p_match->'score','null'::jsonb) score,v_received seen,0 priority
     union all
     select jsonb_build_object('home',o.home_score,'away',o.away_score),o.received_at,1
       from (select * from futbeat_private.provider_observations
         where canonical_match_id=p_match->>'id' and home_score is not null and away_score is not null
           and received_at>=v_start
           and status not in ('POSTPONED','CANCELLED')
         order by received_at desc,id desc limit 1) o
     union all
     select jsonb_build_object('home',l.home_score,'away',l.away_score),l.last_seen_at,2
       from futbeat_private.live_match_state l where l.canonical_match_id=p_match->>'id'
         and l.home_score is not null and l.away_score is not null and l.last_seen_at>=v_start
         and l.status not in ('POSTPONED','CANCELLED')
     union all
     select jsonb_build_object('home',(c.payload->>'homeTeamScore')::integer,
       'away',(c.payload->>'awayTeamScore')::integer),c.fetched_at,3
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
       and c.fetched_at>=v_start and now()>=v_start
       and coalesce(c.payload->>'homeTeamScore','')~'^\d+$'
       and coalesce(c.payload->>'awayTeamScore','')~'^\d+$'
   ) candidates where score is not null order by seen desc,priority limit 1;
 end if;
 -- Never infer FINISHED from the clock, goals or the presence of a score.
 if v_status not in ('VERIFIED','FINISHED_PENDING_VERIFICATION','CANCELLED','POSTPONED') then
   select status,received_at,minute into v_evidence from (
     select status,received_at,minute,id from futbeat_private.provider_observations
       where canonical_match_id=p_match->>'id'
     union all
     select status,last_seen_at,minute,0 from futbeat_private.live_match_state
       where canonical_match_id=p_match->>'id'
     union all
     select case upper(c.payload->>'matchStatus')
       when 'FINISHED' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_ET' then 'FINISHED_PENDING_VERIFICATION'
       when 'AFTER_PEN' then 'FINISHED_PENDING_VERIFICATION'
       when 'AWARDED' then 'FINISHED_PENDING_VERIFICATION'
       when 'HALF_TIME' then 'HALFTIME'
       when 'LIVE' then case upper(c.payload->>'matchPeriod')
         when 'EXTRA_TIME' then 'EXTRA_TIME' when 'PENALTIES' then 'PENALTIES'
         when 'HALF_TIME' then 'HALFTIME' else 'LIVE' end
       else upper(c.payload->>'matchStatus') end,
       c.fetched_at,futbeat_private.safe_result_integer(coalesce(c.payload->>'matchElapsed',c.payload->>'matchMinute')),0
       from futbeat_private.match_detail_cache c where c.match_id=p_match->>'id'
   ) evidence
    where received_at>=v_start and received_at>=v_received
      and (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
        or (status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') and received_at>=now()-interval '15 minutes'))
    order by (status in ('VERIFIED','FINISHED_PENDING_VERIFICATION')) desc,received_at desc,id desc limit 1;
   if found then
     v_status:=v_evidence.status;
     p_match:=p_match||jsonb_strip_nulls(jsonb_build_object('minute',v_evidence.minute,
       'liveChangedAt',v_evidence.received_at));
   end if;
 end if;
 select futbeat_private.normalize_event_array(coalesce(jsonb_agg(event order by
   futbeat_private.safe_result_integer(event->>'minute'),event->>'id'),'[]'::jsonb))
 into v_events from (
   select distinct on (coalesce(event->>'id',event::text)) event from (
     select value event from jsonb_array_elements(coalesce(p_match->'events','[]'::jsonb))
     union all select payload||jsonb_build_object('id',id,'type',event_type)
       from futbeat_private.canonical_events where match_id=p_match->>'id'
   ) all_events order by coalesce(event->>'id',event::text)
 ) unique_events;
 return p_match||jsonb_build_object('score',v_score,'status',v_status,'events',v_events,
   'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'homeTeamId'),
   'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',p_match->>'awayTeamId'),
   'competitionId',futbeat_private.futbeat_resolve_entity_id('competition',p_match->>'competitionId'),
   'hasPlayedEvidence',now()>v_start+interval '15 minutes'
     and (v_score is not null or jsonb_array_length(v_events)>0
       or exists(select 1 from futbeat_private.match_detail_cache c
         where c.match_id=p_match->>'id' and c.fetched_at>=v_start
         and (jsonb_array_length(case when jsonb_typeof(c.payload->'events')='array'
           then c.payload->'events' else '[]'::jsonb end)>0
           or jsonb_array_length(case when jsonb_typeof(c.payload->'incidents')='array'
           then c.payload->'incidents' else '[]'::jsonb end)>0))));
end $$;
revoke all on function futbeat_private.match_read_model(jsonb) from public,anon,authenticated;

create or replace function public.futbeat_read_calendar_range(
  p_from_date date,p_to_date date,
  p_timezone text default 'America/Costa_Rica'
) returns jsonb language sql stable security definer set search_path='' as $$
  with source as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(
      futbeat_private.futbeat_read_calendar_range(p_from_date,p_to_date,p_timezone)
    ) value
  ), reconciled as materialized (
    select futbeat_private.match_read_model(e.payload) item
    from source cross join lateral jsonb_array_elements(source.value->'matches') m
    join futbeat_private.entities e on e.id=m->>'id' and e.kind='match'
  ), team_items as (
    -- Match references and entity collections must share the same final IDs,
    -- including chained redirects; no redirect catalog is sent to the phone.
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
    -- Sanitize optional fields, then append the required nullable contract.
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
revoke all on function public.futbeat_read_calendar_range(date,date,text)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_calendar_range(date,date,text) to service_role;


create or replace function public.futbeat_read_match_context(
  p_match_id text
) returns jsonb
language sql
stable
security definer
set search_path=''
as $$
  with target as (
    select futbeat_private.match_read_model(payload) payload
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
