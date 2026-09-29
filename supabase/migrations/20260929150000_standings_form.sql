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
--   * Effective lifecycle: only FINISHED_PENDING_VERIFICATION / VERIFIED
--     with a complete integer score counts. Scheduled, live, postponed and a
--     past kickoff still reported as SCHEDULED without terminal evidence are
--     excluded. A payload that is already terminal with an integer score is
--     used as stored: match_read_model_core keeps a terminal status and its
--     own score unchanged (terminal is absorbing, no evidence lookup), so
--     only non-terminal rows pay for the model.
--   * Team ids are resolved canonically (futbeat_resolve_entity_id) before
--     the result is computed, so a history stored under an alias or with
--     home/away reversed counts for the right team.
--   * Same rule as the provisional overlay: a match counts only when both
--     teams are rows of the SAME group of that competition+season table
--     (standings_snapshots). A knockout or cross-group match never enters a
--     group's form. Without a stored table there is no group filter
--     (`groupFilter` false).
--   * p_until (the published table's updatedAt): only matches kicked off at
--     least 3 hours before it count, so the chips never show a result that
--     the table's J/Pts do not include yet (conservative: a match finished
--     just before the table was fetched may be left out, never added).
--   * The result is the score stored for the match: a game decided on
--     penalties after a draw counts as DRAW (E), like in the table.
--   * Per team: up to p_limit (1..10, default 5) results, newest first,
--     WIN | DRAW | LOSS, with the match ids in the same order. A team with
--     no counted match is simply absent (the app shows a dash).

create or replace function public.futbeat_read_standings_form(
  p_competition_id text,
  p_season_key text,
  p_limit integer default 5,
  p_until timestamptz default null
) returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  comp text;
  v_season text:=futbeat_private.normalize_season(p_season_key);
  lim integer:=least(greatest(coalesce(p_limit,5),1),10);
  cutoff timestamptz:=least(now(),coalesce(p_until-interval '3 hours',now()));
  comp_ids text[];
  table_rows jsonb;
  result jsonb;
begin
  if nullif(btrim(coalesce(p_competition_id,'')),'') is null or v_season='' then
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

  select s.table_payload->'rows' into table_rows
  from futbeat_private.standings_snapshots s
  where s.competition_id=comp and s.season_key=v_season;

  with members as (
    select distinct futbeat_private.futbeat_resolve_entity_id('team',r.value->>'teamId') team_id,
      coalesce(r.value->>'group','') group_key
    from jsonb_array_elements(case when jsonb_typeof(table_rows)='array' then table_rows else '[]'::jsonb end) r(value)
    where nullif(r.value->>'teamId','') is not null
  ), candidates as (
    select e.id,e.payload from futbeat_private.entities e
    where e.kind='match' and e.payload->>'competitionId'=any(comp_ids)
      and futbeat_private.normalize_season(e.payload->>'season')=v_season
      and nullif(e.payload->>'startTime','') is not null
      and (e.payload->>'startTime')::timestamptz<=cutoff
  ), modeled as (
    select c.id,case
      when c.payload->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and futbeat_private.safe_result_integer(c.payload#>>'{score,home}') is not null
        and futbeat_private.safe_result_integer(c.payload#>>'{score,away}') is not null
        then c.payload
      else futbeat_private.match_read_model_core(c.payload,false) end m
    from candidates c
  ), finals as (
    select x.id,x.st,x.m from (
      select id,(m->>'startTime')::timestamptz st,
        m||jsonb_build_object(
          'homeTeamId',futbeat_private.futbeat_resolve_entity_id('team',m->>'homeTeamId'),
          'awayTeamId',futbeat_private.futbeat_resolve_entity_id('team',m->>'awayTeamId')) m
      from modeled
      where m->>'status' in ('FINISHED_PENDING_VERIFICATION','VERIFIED')
        and futbeat_private.safe_result_integer(m#>>'{score,home}') is not null
        and futbeat_private.safe_result_integer(m#>>'{score,away}') is not null
        and nullif(m->>'homeTeamId','') is not null and nullif(m->>'awayTeamId','') is not null
    ) x
    where x.m->>'homeTeamId'<>x.m->>'awayTeamId'
      and (not exists(select 1 from members)
        or exists(select 1 from members h join members a on a.group_key=h.group_key
          where h.team_id=x.m->>'homeTeamId' and a.team_id=x.m->>'awayTeamId'))
  ), sides as (
    select f.id,f.st,t.team_id,futbeat_private.team_match_result(f.m,t.team_id) r
    from finals f
    cross join lateral (values (f.m->>'homeTeamId'),(f.m->>'awayTeamId')) t(team_id)
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
    'seasonKey',v_season,
    'limit',lim,
    'until',p_until,
    'groupFilter',exists(select 1 from members),
    'teams',coalesce((select jsonb_object_agg(p.team_id,jsonb_build_object(
        'results',p.results,'matchIds',p.match_ids)) from per_team p),'{}'::jsonb),
    'matchesConsidered',(select count(*)::integer from finals))
  into result;
  return result;
end $$;

revoke all on function public.futbeat_read_standings_form(text,text,integer,timestamptz) from public,anon,authenticated;
grant execute on function public.futbeat_read_standings_form(text,text,integer,timestamptz) to service_role;
