-- Issue #158: Tabla v2 "Forma" (last results per team of one table).
--
-- A separate DB-only read, loaded lazily by the app when the user opens the
-- Forma view: never inside futbeat_read_match_context or the entity detail,
-- never a demand, a worker wake-up or a provider call.
--
-- Rules (generic, canonical ids only, never names):
--   * Scope: exactly one canonical competition (plus every alias redirected
--     to it) and one normalized season (normalize_season); the table's own
--     identity (standings_snapshots competition_id + season_key).
--   * Candidates are found through entities_match_competition_idx
--     (payload->>'competitionId'=any(aliases)), never a scan of every match.
--     Only kickoffs already passed can be final.
--   * Every candidate goes through match_read_model_core (effective
--     lifecycle): only FINISHED_PENDING_VERIFICATION / VERIFIED with a
--     numeric score counts. Scheduled, live, postponed and a past kickoff
--     still reported as SCHEDULED without terminal evidence are excluded.
--   * Team ids are resolved canonically (futbeat_resolve_entity_id) before
--     the result is computed, so a history stored under an alias or with
--     home/away reversed counts for the right team.
--   * Per team: up to p_limit (1..10, default 5) results, newest first,
--     WIN | DRAW | LOSS, with the match ids in the same order. A team with
--     no counted match is simply absent (the app shows a dash).

create or replace function public.futbeat_read_standings_form(
  p_competition_id text,
  p_season_key text,
  p_limit integer default 5
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  comp text;
  season text:=futbeat_private.normalize_season(p_season_key);
  lim integer:=least(greatest(coalesce(p_limit,5),1),10);
  comp_ids text[];
  result jsonb;
begin
  if nullif(btrim(coalesce(p_competition_id,'')),'') is null or season='' then
    return null;
  end if;
  comp:=futbeat_private.futbeat_resolve_entity_id('competition',p_competition_id);
  if not exists(select 1 from futbeat_private.entities e where e.id=comp and e.kind='competition') then
    return null;
  end if;

  -- Canonical competition plus every alias redirected to it (bounded).
  with recursive ids(id,depth,path) as (
    select comp,0,array[comp]
    union all
    select r.alias_id,i.depth+1,i.path||r.alias_id
    from ids i join futbeat_private.entity_redirects r
      on r.kind='competition' and r.canonical_id=i.id
    where i.depth<8 and not r.alias_id=any(i.path)
  ) select array_agg(distinct id) into comp_ids from ids;

  with candidates as (
    select e.id,e.payload from futbeat_private.entities e
    where e.kind='match' and e.payload->>'competitionId'=any(comp_ids)
      and futbeat_private.normalize_season(e.payload->>'season')=season
      and nullif(e.payload->>'startTime','') is not null
      and (e.payload->>'startTime')::timestamptz<=now()
  ), modeled as (
    select c.id,futbeat_private.match_read_model_core(c.payload,false) m from candidates c
  ), finals as (
    select id,(m->>'startTime')::timestamptz st,
      m||jsonb_build_object(
        'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',m->>'homeTeamId'),
        'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',m->>'awayTeamId')) m
    from modeled
    where m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
      and jsonb_typeof(m->'score'->'home')='number' and jsonb_typeof(m->'score'->'away')='number'
      and nullif(m->>'homeTeamId','') is not null and nullif(m->>'awayTeamId','') is not null
  ), sides as (
    select f.id,f.st,t.team_id,futbeat_private.team_match_result(f.m,t.team_id) r
    from finals f
    cross join lateral (values (f.m->>'homeTeamId'),(f.m->>'awayTeamId')) t(team_id)
    where f.m->>'homeTeamId'<>f.m->>'awayTeamId'
  ), ranked as (
    select s.*,row_number() over(partition by s.team_id order by s.st desc,s.id desc) n
    from sides s where s.r is not null
  ), per_team as (
    select team_id,
      jsonb_agg(r order by n) results,
      jsonb_agg(id order by n) match_ids
    from ranked where n<=lim group by team_id
  )
  select jsonb_build_object(
    'schemaVersion',1,
    'competitionId',comp,
    'seasonKey',season,
    'limit',lim,
    'teams',coalesce((select jsonb_object_agg(p.team_id,jsonb_build_object(
        'results',p.results,'matchIds',p.match_ids)) from per_team p),'{}'::jsonb),
    'matchesConsidered',(select count(*)::integer from finals f
      where f.m->>'homeTeamId'<>f.m->>'awayTeamId'))
  into result;
  return result;
end $$;

revoke all on function public.futbeat_read_standings_form(text,text,integer) from public,anon,authenticated;
grant execute on function public.futbeat_read_standings_form(text,text,integer) to service_role;
