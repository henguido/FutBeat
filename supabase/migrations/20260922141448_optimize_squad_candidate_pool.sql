-- Read-only candidate pools. Existing ingestion, last_seen maintenance and quota
-- are intentionally unchanged. No global redirect/mapping materialization.
create function futbeat_private.squad_candidate_id(p_kind text,p_id text)
returns text language sql stable set search_path='' as $$
 select case when exists(select 1 from futbeat_private.entity_redirects where kind=p_kind and alias_id=p_id)
  then futbeat_private.futbeat_resolve_entity_id(p_kind,p_id) else p_id end
$$;

create function futbeat_private.squad_pool_due(p_ids text[],p_excluded text[],p_limit integer)
returns jsonb language plpgsql stable set search_path='' as $$
declare eligible_ids text[]; batch_ids text[]; result jsonb:='[]'; part jsonb; pos integer:=1; batch_size integer;
begin
 if p_limit<1 or coalesce(cardinality(p_ids),0)=0 then return result; end if;
 -- Eligibility precedes the bounded mapping batches. Same-kickoff ties remain
 -- deterministic even if thousands of matches share one kickoff.
 with canonical as materialized (
  select distinct futbeat_private.squad_candidate_id('team',id) team_id from (select distinct unnest(p_ids) id) x
 ), eligible as (
  select c.team_id,d.fetched_at from canonical c
  join futbeat_private.entities e on e.id=c.team_id and e.kind='team'
  left join futbeat_private.team_detail_coverage d on d.team_id=c.team_id
  where not c.team_id=any(p_excluded)
   and coalesce(d.next_retry_at,d.fetched_at+interval '7 days','-infinity')<=now()
   and coalesce(d.lease_until,'-infinity')<=now()
 ) select array_agg(team_id order by fetched_at nulls first,team_id) into eligible_ids from eligible;
 batch_size:=greatest(16,least(p_limit,25));
 while pos<=coalesce(cardinality(eligible_ids),0) and jsonb_array_length(result)<p_limit loop
  batch_ids:=eligible_ids[pos:pos+batch_size-1];
  -- Bounded set-based mapping query; refill until enough valid mappings exist.
  -- Reverse redirect traversal starts ONLY from this eligible batch.
  with recursive mapping_targets(team_id,mapping_id,depth,path) as (
   select id,id,0,array[id] from unnest(batch_ids) id
   union all
   select t.team_id,r.alias_id,t.depth+1,t.path||r.alias_id from mapping_targets t
   join futbeat_private.entity_redirects r on r.kind='team' and r.canonical_id=t.mapping_id
   where t.depth<8 and not r.alias_id=any(t.path)
  ), provider_mapping as (
   select distinct on(t.team_id) t.team_id,pe.external_id from mapping_targets t
   join futbeat_private.provider_entities pe on pe.canonical_id=t.mapping_id
   where pe.provider='goal_api' and pe.kind='team' and nullif(btrim(pe.external_id),'') is not null
   order by t.team_id,case when pe.last_seen_at>=now()-interval '180 days' then pe.last_seen_at end desc nulls last,pe.external_id desc
  ), selected as (
   select m.team_id,m.external_id,d.fetched_at from provider_mapping m
   left join futbeat_private.team_detail_coverage d on d.team_id=m.team_id
   order by array_position(batch_ids,m.team_id) limit p_limit-jsonb_array_length(result)
  ) select coalesce(jsonb_agg(jsonb_build_object('teamId',team_id,'externalTeamId',external_id,'lastFetchedAt',fetched_at)
    order by array_position(batch_ids,team_id)),'[]') into part from selected;
  result:=result||part;
  pos:=pos+batch_size;
 end loop;
 return result;
end $$;

create function futbeat_private.squad_competition_pool(p_competitions text[])
returns text[] language plpgsql stable set search_path='' as $$
declare result text[];
begin
 if coalesce(cardinality(p_competitions),0)=0 then return array[]::text[]; end if;
 with matching as materialized (
  -- Filter competition BEFORE expanding home/away; never join the team catalog
  -- when competitionId is already present on the match.
  select e.payload from futbeat_private.calendar_matches c
  join futbeat_private.entities e on e.id=c.match_id and e.kind='match'
  where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
   and futbeat_private.squad_candidate_id('competition',e.payload->>'competitionId')=any(p_competitions)
 ), team_ids as (
  select x.id from matching m cross join lateral(values(m.payload->>'homeTeamId'),(m.payload->>'awayTeamId')) x(id)
  union
  -- Compatibility for incomplete stored matches only; each team's own league.
  select x.id from futbeat_private.calendar_matches c
  join futbeat_private.entities e on e.id=c.match_id and e.kind='match' and e.payload->>'competitionId' is null
  cross join lateral(values(e.payload->>'homeTeamId'),(e.payload->>'awayTeamId')) x(id)
  join futbeat_private.entities t on t.id=futbeat_private.squad_candidate_id('team',x.id) and t.kind='team'
  where c.start_time between now()-interval '6 hours' and now()+interval '7 days'
   and futbeat_private.squad_candidate_id('competition',t.payload->>'competitionId')=any(p_competitions)
  union
  select t.id from futbeat_private.temporary_interests i
  join futbeat_private.entities t on t.id=futbeat_private.squad_candidate_id('team',i.entity_id) and t.kind='team'
  where i.entity_type='team' and i.expires_at>now()
   and futbeat_private.squad_candidate_id('competition',t.payload->>'competitionId')=any(p_competitions)
 ) select array_agg(distinct id) into result from team_ids where id is not null;
 return coalesce(result,array[]::text[]);
end $$;

create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer default 3)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb:='[]'; part jsonb; ids text[]; comps text[]; chosen text[]:=array[]::text[];
 tier integer; remaining integer; m record; kickoff timestamptz; pending text[]; visited text[];
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
   -- Ordered cursor: read the nearest matches first. Process a complete kickoff
   -- group for fetched_at/team_id ties; continue indefinitely if it cannot fill.
   pending:=array[]::text[]; visited:=chosen; kickoff:=null;
   for m in
    select c.start_time,e.payload from futbeat_private.calendar_matches c
    -- Keep calendar as the driving ordered relation. OFFSET 0 prevents flattening
    -- into a full entity scan/sort; this is a single indexed match-PK probe, not
    -- the old per-team mapping catalog scan.
    join lateral (select payload from futbeat_private.entities
     where id=c.match_id and kind='match' and payload->>'status'='SCHEDULED' offset 0) e on true
    where c.start_time between now() and now()+interval '7 days'
    order by c.start_time,c.match_id
   loop
    if kickoff is not null and m.start_time<>kickoff then
     part:=part||futbeat_private.squad_pool_due(pending,visited,remaining-jsonb_array_length(part));
     exit when jsonb_array_length(part)>=remaining;
     select visited||coalesce(array_agg(distinct futbeat_private.squad_candidate_id('team',id)),array[]::text[])
      into visited from unnest(pending) id where id is not null;
     pending:=array[]::text[];
    end if;
    kickoff:=m.start_time;
    pending:=pending||array[m.payload->>'homeTeamId',m.payload->>'awayTeamId'];
   end loop;
   if jsonb_array_length(part)<remaining then
    part:=part||futbeat_private.squad_pool_due(pending,visited,remaining-jsonb_array_length(part));
   end if;
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

revoke all on function futbeat_private.squad_candidate_id(text,text),
 futbeat_private.squad_pool_due(text[],text[],integer),futbeat_private.squad_competition_pool(text[])
 from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
