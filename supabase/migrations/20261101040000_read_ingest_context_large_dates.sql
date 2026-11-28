-- Turn 244: futbeat_read_ingest_context is the statement that limits a large calendar date.
--
-- Production 2026-10-07/08: 57014 at 8.6 s (1,477 fixtures); 5.1-7.3 s on the other attempts;
-- 1.4 s at 430. Edge v44 chunks the entity writes but this read stays one statement, with no
-- retry. Two costs grow with the date (PG 17, real imports snapshot, scripts/calendar):
--   * the materialized CTE keeps the three parsed arrays of the snapshot (5.4 MB of text) and
--     spills past work_mem (2,447 temp blocks at 3,000 teams);
--   * futbeat_apply_entity_redirects_snapshot joins entities once per team only to read the
--     payload of an alias, and the snapshot holds one alias team and one alias competition.
--
-- Same inputs, same output: the snapshot goes through a variable (one detoast, no tuplestore)
-- and an alias row is the only one that reads entities. The rules of
-- apply_entity_redirects_before_player_scope stay: a canonical row wins over its alias, then
-- the first row by position; an alias alone takes the stored payload of its canonical id.
-- Not applied by db push: production uses the turn 244 kit, guarded by the previous md5
-- (2559d4d664f9f7e0a4b8584086bcb337). Rollback in the kit.

create or replace function public.futbeat_read_ingest_context(
  p_competition_ids text[], p_team_ids text[], p_from timestamptz, p_to timestamptz
) returns jsonb
language plpgsql stable security definer
set search_path to ''
as $function$
declare
  v_snapshot jsonb;
  v_competitions jsonb;
  v_teams jsonb;
  v_matches jsonb;
  v_result jsonb;
begin
  select i.snapshot into v_snapshot
  from futbeat_private.imports i
  order by i.received_at desc,i.job_id desc limit 1;

  v_competitions:=case when jsonb_typeof(v_snapshot->'competitions')='array'
    then v_snapshot->'competitions' else '[]'::jsonb end;
  v_teams:=case when jsonb_typeof(v_snapshot->'teams')='array'
    then v_snapshot->'teams' else '[]'::jsonb end;
  v_matches:=case when jsonb_typeof(v_snapshot->'matches')='array'
    then v_snapshot->'matches' else '[]'::jsonb end;

  with want_competitions as materialized (
    select distinct id from unnest(coalesce(p_competition_ids,'{}'::text[])) id
  ), want_teams as materialized (
    select distinct id from unnest(coalesce(p_team_ids,'{}'::text[])) id
  ), redirects as materialized (
    -- Alias -> canonical (chains resolved) for the two kinds involved.
    select r.kind,r.alias_id,r.canonical_id direct_id,
      futbeat_private.futbeat_resolve_entity_id(r.kind,r.alias_id) canonical_id
    from futbeat_private.entity_redirects r where r.kind in ('team','competition')
  ), competitions as (
    select c.value,c.ordinality,r.direct_id
    from jsonb_array_elements(v_competitions) with ordinality c(value,ordinality)
    left join redirects r on r.kind='competition' and r.alias_id=c.value->>'id'
    join want_competitions w on w.id=coalesce(r.canonical_id,c.value->>'id')
  ), teams as (
    select t.value,t.ordinality,r.direct_id
    from jsonb_array_elements(v_teams) with ordinality t(value,ordinality)
    left join redirects r on r.kind='team' and r.alias_id=t.value->>'id'
    join want_teams w on w.id=coalesce(r.canonical_id,t.value->>'id')
  ), competitions_ranked as (
    select c.ordinality,
      case when c.direct_id is null then c.value else coalesce(
        (select e.payload from futbeat_private.entities e
          where e.id=c.direct_id and e.kind='competition'),
        jsonb_set(c.value,'{id}',to_jsonb(c.direct_id),true)) end payload,
      row_number() over(partition by coalesce(c.direct_id,c.value->>'id')
        order by case when c.direct_id is null then 0 else 1 end,c.ordinality) rn
    from competitions c
  ), teams_ranked as (
    select t.ordinality,
      case when t.direct_id is null then t.value else coalesce(
        (select e.payload from futbeat_private.entities e
          where e.id=t.direct_id and e.kind='team'),
        jsonb_set(t.value,'{id}',to_jsonb(t.direct_id),true)) end payload,
      row_number() over(partition by coalesce(t.direct_id,t.value->>'id')
        order by case when t.direct_id is null then 0 else 1 end,t.ordinality) rn
    from teams t
  ), team_matches as materialized (
    select m.value,m.ordinality,
      coalesce(rc.canonical_id,m.value->>'competitionId') competition_id,
      coalesce(rh.canonical_id,m.value->>'homeTeamId') home_team_id,
      coalesce(ra.canonical_id,m.value->>'awayTeamId') away_team_id
    from jsonb_array_elements(v_matches) with ordinality m(value,ordinality)
    left join redirects rh on rh.kind='team' and rh.alias_id=m.value->>'homeTeamId'
    left join redirects ra on ra.kind='team' and ra.alias_id=m.value->>'awayTeamId'
    left join redirects rc on rc.kind='competition' and rc.alias_id=m.value->>'competitionId'
    join want_teams wh on wh.id=coalesce(rh.canonical_id,m.value->>'homeTeamId')
    join want_teams wa on wa.id=coalesce(ra.canonical_id,m.value->>'awayTeamId')
    where p_from is not null and p_to is not null
  ), matches as (
    -- The rewrite futbeat_apply_entity_redirects_snapshot applies to matches.
    select jsonb_set(jsonb_set(jsonb_set(value,
        '{competitionId}',to_jsonb(competition_id),true),
        '{homeTeamId}',to_jsonb(home_team_id),true),
        '{awayTeamId}',to_jsonb(away_team_id),true) value,
      ordinality
    from team_matches
    where futbeat_private.try_timestamptz(value->>'startTime')
      between p_from-interval '5 minutes' and p_to+interval '5 minutes'
  )
  select jsonb_build_object(
    'competitions',coalesce((select jsonb_agg(payload order by ordinality) from competitions_ranked where rn=1),'[]'::jsonb),
    'teams',coalesce((select jsonb_agg(payload order by ordinality) from teams_ranked where rn=1),'[]'::jsonb),
    'matches',coalesce((select jsonb_agg(value order by ordinality) from matches),'[]'::jsonb))
  into v_result;

  return v_result;
end
$function$;

revoke all on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then
    revoke all on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz) from anon;
  end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then
    revoke all on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz) from authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname='service_role') then
    grant execute on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz) to service_role;
  end if;
end $$;
