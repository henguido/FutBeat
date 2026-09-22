-- P2 ranking only. No quota, reservation, last_seen, ingestion or tier changes.
-- Private diagnostic source: metadata ranking is separated from provider mapping.
create function futbeat_private.squad_upcoming_candidates(p_bucket integer default null)
returns table(team_id text,competition_id text,followed_competition boolean,
 relevance_score integer,temporary_demand boolean,kickoff timestamptz,time_bucket integer)
language sql stable set search_path='' as $$
 with matches as materialized (
  select c.match_id,c.start_time,e.payload->>'competitionId' raw_competition,
   e.payload->>'homeTeamId' home_id,e.payload->>'awayTeamId' away_id
  from futbeat_private.calendar_matches c
  join lateral (select payload from futbeat_private.entities
   where id=c.match_id and kind='match' and payload->>'status'='SCHEDULED' offset 0) e on true
  -- Preserve P2's existing future-SCHEDULED subset, not the P0/P3/P4 -6h window.
  where c.start_time between now() and now()+interval '7 days'
   and (p_bucket is null
    or (p_bucket=0 and c.start_time<=now()+interval '24 hours')
    or (p_bucket=1 and c.start_time>now()+interval '24 hours' and c.start_time<=now()+interval '72 hours')
    or (p_bucket=2 and c.start_time>now()+interval '72 hours'))
 ), followed as materialized (
  select distinct futbeat_private.squad_candidate_id('competition',subject_id) id
  from futbeat_private.coverage_interests where subject_type='competition' and explicit_followers>0
 ), recent as materialized (
  -- Boolean central demand, not per-user counts, identity or an artificial score.
  select distinct futbeat_private.squad_candidate_id('team',entity_id) id
  from futbeat_private.temporary_interests where entity_type='team' and expires_at>now()
 ), competitions as materialized (
  select x.raw_competition,futbeat_private.squad_candidate_id('competition',x.raw_competition) id
  from (select distinct raw_competition from matches where raw_competition is not null) x
 ), signals as materialized (
  select c.raw_competition,c.id,f.id is not null followed,
   case when m.source='editorial' then coalesce(m.relevance_score,100) else 100 end relevance
  from competitions c
  left join futbeat_private.competition_editorial_metadata m on m.competition_id=c.id
  left join followed f on f.id=c.id
 ), appearances as (
  select case when r.alias_id is null then x.id else futbeat_private.futbeat_resolve_entity_id('team',x.id) end team_id,
   s.id competition_id,coalesce(s.followed,false) followed_competition,coalesce(s.relevance,100) relevance_score,
   m.start_time kickoff,
   case when m.start_time<=now()+interval '24 hours' then 0 when m.start_time<=now()+interval '72 hours' then 1 else 2 end time_bucket
  from matches m left join signals s on s.raw_competition=m.raw_competition
  cross join lateral(values(m.home_id),(m.away_id)) x(id)
  left join futbeat_private.entity_redirects r on r.kind='team' and r.alias_id=x.id
  where x.id is not null
 ), demanded as (
  select a.*,r.id is not null temporary_demand from appearances a left join recent r on r.id=a.team_id
 ), best as (
  -- One canonical team, represented by its best match under the same final order.
  select distinct on(team_id) * from demanded
  order by team_id,time_bucket,followed_competition desc,relevance_score desc,temporary_demand desc,kickoff,competition_id
 ) select team_id,competition_id,followed_competition,relevance_score,temporary_demand,kickoff,time_bucket from best
 order by time_bucket,followed_competition desc,relevance_score desc,temporary_demand desc,kickoff,team_id
$$;

create function futbeat_private.squad_upcoming_due(p_excluded text[],p_limit integer)
returns jsonb language plpgsql stable set search_path='' as $$
declare result jsonb:='[]'; part jsonb; pending text[]; candidate record; bucket integer;
 excluded text[]:=p_excluded;
begin
 if p_limit<1 then return result; end if;
 for bucket in 0..2 loop
 pending:=array[]::text[];
 for candidate in
  select team_id from futbeat_private.squad_upcoming_candidates(bucket)
  where not team_id=any(excluded)
  order by time_bucket,followed_competition desc,relevance_score desc,temporary_demand desc,kickoff,team_id
 loop
  pending:=array_append(pending,candidate.team_id);
  if cardinality(pending)>=p_limit-jsonb_array_length(result) then
   -- Reuse all existing eligibility/mapping rules. Resolve this whole small batch,
   -- then restore P2 rank (the shared helper orders other tiers by fetched_at).
   part:=futbeat_private.squad_pool_due(pending,excluded,cardinality(pending));
   select result||coalesce(jsonb_agg(value order by array_position(pending,value->>'teamId')),'[]')
    into result from jsonb_array_elements(part);
   if jsonb_array_length(result)>=p_limit then return result; end if;
   pending:=array[]::text[];
  end if;
 end loop;
 if jsonb_array_length(result)<p_limit and cardinality(pending)>0 then
  part:=futbeat_private.squad_pool_due(pending,excluded,cardinality(pending));
  select result||coalesce(jsonb_agg(value order by array_position(pending,value->>'teamId')),'[]')
   into result from jsonb_array_elements(part);
 end if;
 if jsonb_array_length(result)>=p_limit then return result; end if;
 select p_excluded||coalesce(array_agg(value->>'teamId'),array[]::text[]) into excluded from jsonb_array_elements(result);
 end loop;
 return result;
end $$;

create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer default 3)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb:='[]'; part jsonb; ids text[]; comps text[]; chosen text[]:=array[]::text[];
 tier integer; remaining integer;
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 for tier in 0..5 loop
  remaining:=p_limit-jsonb_array_length(result);
  exit when remaining<=0;
  part:='[]'; ids:=array[]::text[];
  if tier=0 then
   -- Exhaustive LIVE source, no match pre-limit. Global result limit follows.
   select array_agg(distinct x.id) into ids from futbeat_private.calendar_matches c
   join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
   cross join lateral(values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) x(id)
   where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
    and e.payload->>'status' in ('LIVE','HALFTIME','EXTRA_TIME','PENALTIES');
   part:=futbeat_private.squad_pool_due(ids,chosen,coalesce(cardinality(ids),0));
   select coalesce(jsonb_agg(value order by ord),'[]') into part from
    (select value,ord from jsonb_array_elements(part) with ordinality x(value,ord) order by ord limit remaining) q;
  elsif tier=1 then
   select array_agg(subject_id) into ids from futbeat_private.coverage_interests where subject_type='team' and explicit_followers>0;
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  elsif tier=2 then
   part:=futbeat_private.squad_upcoming_due(chosen,remaining);
  elsif tier in (3,4) then
   if tier=3 then
    select array_agg(distinct futbeat_private.squad_candidate_id('competition',subject_id)) into comps
    from futbeat_private.coverage_interests where subject_type='competition' and explicit_followers>0;
   else
    select array_agg(competition_id) into comps from futbeat_private.competition_editorial_metadata where relevance_score>=800 and source<>'derived';
   end if;
   if coalesce(cardinality(comps),0)>0 then
    ids:=futbeat_private.squad_competition_pool(comps);
    part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
   end if;
  else
   select array_agg(distinct entity_id) into ids from futbeat_private.temporary_interests where entity_type='team' and expires_at>now();
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
  end if;
  select result||coalesce(jsonb_agg(value||jsonb_build_object('priority',60000-tier*10000,'priorityTier',tier,
   'reason',(array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened'])[tier+1]) order by ord),'[]'),
   chosen||coalesce(array_agg(value->>'teamId' order by ord),array[]::text[])
  into result,chosen from jsonb_array_elements(part) with ordinality x(value,ord);
 end loop;
 return result;
end $$;

revoke all on function futbeat_private.squad_upcoming_candidates(integer),futbeat_private.squad_upcoming_due(text[],integer)
 from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
