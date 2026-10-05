-- Squad planner LIVE tier: window first, never a full walk of entities.
--
-- Evidence (read-only production, 2026-10-05, EXPLAIN ANALYZE):
-- futbeat_team_squad_plan runs ~10 times an hour (squad lane of
-- futbeat-goal-live-sync) at 4.8-6.4 s per call in production. Of its
-- ~102,700 buffers per call, ~100,000 come from tier 0 (teams of LIVE
-- matches): the planner merge-joined a full index walk of entities (96,181
-- rows removed by the status filter) instead of probing the 3,258 matches
-- of the 7-day window. Same query with one probe per window match:
-- 0.9-1.5 s / 100,004 buffers -> 18 ms / 13,222 buffers, same rows.
-- Only that query changes (same window, same filter, same result).
-- Rollback: re-create the function from its production definition
-- (supabase/manual/20261005100000_squad_plan_live_tier_rollback.sql).

create or replace function futbeat_private.futbeat_team_squad_plan(p_limit integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare result jsonb:='[]'; part jsonb; ids text[]; comps text[]; chosen text[]:=array[]::text[];
 tier integer; remaining integer;
begin
 if p_limit is null or p_limit<1 or p_limit>25 then raise exception 'Invalid squad plan limit'; end if;
 foreach tier in array array[0,1,6,2,3,4,5] loop
  remaining:=p_limit-jsonb_array_length(result);
  exit when remaining<=0;
  part:='[]'; ids:=array[]::text[];
  if tier=0 then
   -- Exhaustive LIVE source, no match pre-limit. Global result limit follows.
   -- Window first, one primary-key probe per window match (OFFSET 0 keeps it
   -- a probe): the planner otherwise merge-joined a full walk of entities.
   select array_agg(distinct x.id) into ids from futbeat_private.calendar_matches c
   cross join lateral(select e.payload from futbeat_private.entities e
     where e.id=c.match_id and e.kind='match' offset 0) e
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
  elsif tier=6 then
   select array_agg(d.team_id order by d.requested_at desc,d.team_id) into ids
   from futbeat_private.team_squad_demands d
   left join futbeat_private.team_detail_coverage c on c.team_id=d.team_id
   where d.requested_at>now()-interval '7 days'
     and d.requested_at>coalesce(c.last_attempt_at,'-infinity');
   part:=futbeat_private.squad_pool_due(ids,chosen,remaining);
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
  select result||coalesce(jsonb_agg(value||jsonb_build_object(
   'priority',case when tier=6 then 45000 else 60000-tier*10000 end,'priorityTier',tier,
   'reason',(array['live','favorite','upcoming','followed_competition','editorial_relevance','recently_opened','requested'])[tier+1]) order by ord),'[]'),
   chosen||coalesce(array_agg(value->>'teamId' order by ord),array[]::text[])
  into result,chosen from jsonb_array_elements(part) with ordinality x(value,ord);
 end loop;
 return result;
end $function$;
