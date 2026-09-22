-- Local incremental planner optimization. No reservations or provider requests.
alter table futbeat_private.provider_entities add column last_seen_at timestamptz;

-- One-time backfill only. The read-only planner never reads observations again.
with recent as (
 select x.external_id,max(o.received_at) last_seen_at
 from futbeat_private.provider_observations o
 cross join lateral (values(coalesce(o.raw_payload#>>'{homeTeam,id}',o.raw_payload->>'homeTeamId')),
  (coalesce(o.raw_payload#>>'{awayTeam,id}',o.raw_payload->>'awayTeamId'))) x(external_id)
 where o.provider='goal_api' and o.received_at>=now()-interval '180 days'
  and nullif(x.external_id,'') is not null group by x.external_id
)
update futbeat_private.provider_entities pe set last_seen_at=r.last_seen_at from recent r
where pe.provider='goal_api' and pe.kind='team' and pe.external_id=r.external_id;

-- Statement-level transition rows only: no history scan and no writes for repeats
-- or out-of-order data. Existing ingestion creates mappings before observations.
create function futbeat_private.track_squad_mapping_seen() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 with recent as (
  select x.external_id,max(o.received_at) last_seen_at from squad_observation_rows o
  cross join lateral (values(coalesce(o.raw_payload#>>'{homeTeam,id}',o.raw_payload->>'homeTeamId')),
   (coalesce(o.raw_payload#>>'{awayTeam,id}',o.raw_payload->>'awayTeamId'))) x(external_id)
  where o.provider='goal_api' and nullif(x.external_id,'') is not null group by x.external_id
 )
 update futbeat_private.provider_entities pe set last_seen_at=r.last_seen_at from recent r
 where pe.provider='goal_api' and pe.kind='team' and pe.external_id=r.external_id
  and (pe.last_seen_at is null or pe.last_seen_at<r.last_seen_at);
 return null;
end $$;
create trigger futbeat_squad_mapping_seen_insert after insert on futbeat_private.provider_observations
 referencing new table as squad_observation_rows for each statement execute function futbeat_private.track_squad_mapping_seen();
create trigger futbeat_squad_mapping_seen_update after update on futbeat_private.provider_observations
 referencing new table as squad_observation_rows for each statement execute function futbeat_private.track_squad_mapping_seen();
revoke all on function futbeat_private.track_squad_mapping_seen() from public,anon,authenticated,service_role;

create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer default 3)
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 with redirects as materialized (
  -- Resolve only actual aliases, once; canonical mappings need no recursive call.
  select alias_id,kind,futbeat_private.futbeat_resolve_entity_id(kind,alias_id) canonical_id
  from futbeat_private.entity_redirects
 ), active_matches as materialized (
  select e.payload,c.start_time from futbeat_private.calendar_matches c
  join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
 ), active_teams as materialized (
  select distinct coalesce(r.canonical_id,x.id) team_id,
   m.payload->>'competitionId' competition_id,m.payload->>'status' status,m.start_time
  from active_matches m cross join lateral (values(m.payload->>'homeTeamId'),(m.payload->>'awayTeamId')) x(id)
  left join redirects r on r.kind='team' and r.alias_id=x.id
  where nullif(x.id,'') is not null
 ), opened as materialized (
  select distinct coalesce(r.canonical_id,t.entity_id) team_id
  from futbeat_private.temporary_interests t left join redirects r on r.kind='team' and r.alias_id=t.entity_id
  where t.entity_type='team' and t.expires_at>now()
 ), activity as materialized (
  -- P3/P4 require calendar activity in the SAME bounded window or a live interest.
  -- Team metadata is fetched by PK only for this bounded universe.
  select distinct a.team_id,coalesce(r.canonical_id,a.competition_id) competition_id from (
   select a.team_id,coalesce(a.competition_id,e.payload->>'competitionId') competition_id
   from active_teams a join futbeat_private.entities e on e.id=a.team_id and e.kind='team'
   union
   select o.team_id,e.payload->>'competitionId' from opened o
   join futbeat_private.entities e on e.id=o.team_id and e.kind='team'
  ) a left join redirects r on r.kind='competition' and r.alias_id=a.competition_id
 ), followed as materialized (
  select distinct coalesce(r.canonical_id,c.subject_id) competition_id
  from futbeat_private.coverage_interests c left join redirects r on r.kind='competition' and r.alias_id=c.subject_id
  where c.subject_type='competition' and c.explicit_followers>0
 ), candidates as (
  select team_id,case when status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') then 0 else 2 end tier
  from active_teams where status in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES') or (start_time>=now() and status='SCHEDULED')
  union all
  select coalesce(r.canonical_id,c.subject_id),1 from futbeat_private.coverage_interests c
  left join redirects r on r.kind='team' and r.alias_id=c.subject_id
  where c.subject_type='team' and c.explicit_followers>0
  union all
  select a.team_id,3 from activity a join followed f using(competition_id)
  union all
  select a.team_id,4 from activity a join futbeat_private.competition_editorial_metadata meta using(competition_id)
  where meta.relevance_score>=800 and meta.source<>'derived'
  union all
  select team_id,5 from opened
 ), ranked as materialized (
  select team_id,min(tier) tier from candidates where team_id is not null group by team_id
 ), eligible as materialized (
  select r.team_id,r.tier,c.fetched_at from ranked r
  join futbeat_private.entities e on e.id=r.team_id and e.kind='team'
  left join futbeat_private.team_detail_coverage c on c.team_id=r.team_id
  where coalesce(c.next_retry_at,c.fetched_at+interval '7 days','-infinity')<=now()
   and coalesce(c.lease_until,'-infinity')<=now()
 ), mapping_targets as materialized (
  select team_id,team_id mapping_id from eligible
  union
  select e.team_id,r.alias_id from eligible e join redirects r on r.kind='team' and r.canonical_id=e.team_id
 ), provider_mapping as materialized (
  -- Indexed, set-based lookup; no per-candidate lateral scan or resolver call.
  select distinct on(t.team_id) t.team_id,pe.external_id from mapping_targets t
  join futbeat_private.provider_entities pe on pe.canonical_id=t.mapping_id
  where pe.provider='goal_api' and pe.kind='team' and nullif(btrim(pe.external_id),'') is not null
  order by t.team_id,case when pe.last_seen_at>=now()-interval '180 days' then pe.last_seen_at end desc nulls last,pe.external_id desc
 ), due as (
  select e.team_id,e.tier,m.external_id,e.fetched_at from eligible e join provider_mapping m using(team_id)
  order by e.tier,e.fetched_at nulls first,e.team_id limit p_limit
 ) select coalesce(jsonb_agg(jsonb_build_object('teamId',team_id,'externalTeamId',external_id,
  'priority',60000-tier*10000,'priorityTier',tier,'reason',
  (array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened'])[tier+1],
  'lastFetchedAt',fetched_at) order by tier,fetched_at nulls first,team_id),'[]') into result from due;
 return result;
end $$;

-- Existing service-only RPC ACL and quota/reservation implementation unchanged.
notify pgrst,'reload schema';
