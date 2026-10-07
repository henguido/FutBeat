-- futbeat_read_ingest_context: one pass, same output.
--
-- Evidence (production, 2026-10-07, read-only EXPLAIN ANALYZE): the calendar
-- batches failed at read-current with 57014 (8.9 s and 13.1 s; runs
-- 37551317220 and 37553148556); one calendar day (2026-09-18, 425 matches of
-- the requested teams) took 5.1 s, three days did not finish in 2 min.
-- The function body of 20261005110000 evaluated its work three times and the
-- per-match redirect step row by row:
--   * the final select read r.s three times (competitions/teams/matches) from
--     LATERAL (select futbeat_apply_entity_redirects_snapshot(subset.s) s);
--     the planner flattens that LATERAL, so the redirect function ran three
--     times and the subset (InitPlans) was built three times;
--   * each latest.snapshot->'x' detoasted and parsed the whole 1.1 MB import
--     again (9 times per call, 30-150 ms each);
--   * the redirect function rewrites every match's competitionId/homeTeamId/
--     awayTeamId through futbeat_resolve_entity_id(), a SECURITY DEFINER
--     function with SET search_path (not inlined): 3 calls per match.
-- This version:
--   * extracts the three arrays of the latest import once (materialized);
--   * builds the subset once and applies the redirects once (materialized);
--   * rewrites the matches' ids with the redirect map it already computes
--     (redirects CTE: alias -> futbeat_resolve_entity_id(kind,alias), the same
--     function; an id without redirect resolves to itself, null stays null,
--     so jsonb_set still yields null exactly as before);
--   * evaluates the kickoff filter (try_timestamptz) only on the matches of
--     two requested teams.
-- Output is identical (backend/test/global_ingest_context_single_pass.test.mjs
-- compares it with the 20261005110000 body). Same signature, STABLE, SECURITY
-- DEFINER, search_path, grants. Read-only.
-- Rollback: supabase/manual/20261007010000_ingest_context_single_pass_rollback.sql.

create or replace function public.futbeat_read_ingest_context(
  p_competition_ids text[],p_team_ids text[],p_from timestamptz,p_to timestamptz
) returns jsonb language sql stable security definer set search_path='' as $$
  with latest as materialized (
    select
      case when jsonb_typeof(snapshot->'competitions')='array'
        then snapshot->'competitions' else '[]'::jsonb end competitions,
      case when jsonb_typeof(snapshot->'teams')='array'
        then snapshot->'teams' else '[]'::jsonb end teams,
      case when jsonb_typeof(snapshot->'matches')='array'
        then snapshot->'matches' else '[]'::jsonb end matches
    from futbeat_private.imports
    order by received_at desc,job_id desc limit 1
  ), want_competitions as materialized (
    select distinct id from unnest(coalesce(p_competition_ids,'{}'::text[])) id
  ), want_teams as materialized (
    select distinct id from unnest(coalesce(p_team_ids,'{}'::text[])) id
  ), redirects as materialized (
    -- Alias -> canonical (chains resolved) for the two kinds involved.
    select r.kind,r.alias_id,futbeat_private.futbeat_resolve_entity_id(r.kind,r.alias_id) canonical_id
    from futbeat_private.entity_redirects r where r.kind in ('team','competition')
  ), competitions as (
    select c.value,c.ordinality from latest
    cross join lateral jsonb_array_elements(latest.competitions) with ordinality c(value,ordinality)
    left join redirects r on r.kind='competition' and r.alias_id=c.value->>'id'
    join want_competitions w on w.id=coalesce(r.canonical_id,c.value->>'id')
  ), teams as (
    select t.value,t.ordinality from latest
    cross join lateral jsonb_array_elements(latest.teams) with ordinality t(value,ordinality)
    left join redirects r on r.kind='team' and r.alias_id=t.value->>'id'
    join want_teams w on w.id=coalesce(r.canonical_id,t.value->>'id')
  ), team_matches as materialized (
    select m.value,m.ordinality,
      coalesce(rc.canonical_id,m.value->>'competitionId') competition_id,
      coalesce(rh.canonical_id,m.value->>'homeTeamId') home_team_id,
      coalesce(ra.canonical_id,m.value->>'awayTeamId') away_team_id
    from latest
    cross join lateral jsonb_array_elements(latest.matches) with ordinality m(value,ordinality)
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
  ), applied as materialized (
    select futbeat_private.futbeat_apply_entity_redirects_snapshot(jsonb_build_object(
      'schemaVersion',1,'demo',false,
      'competitions',coalesce((select jsonb_agg(value order by ordinality) from competitions),'[]'::jsonb),
      'teams',coalesce((select jsonb_agg(value order by ordinality) from teams),'[]'::jsonb),
      'players','[]'::jsonb,
      'matches','[]'::jsonb)) s
  )
  select jsonb_build_object(
    'competitions',coalesce(applied.s->'competitions','[]'::jsonb),
    'teams',coalesce(applied.s->'teams','[]'::jsonb),
    'matches',coalesce((select jsonb_agg(value order by ordinality) from matches),'[]'::jsonb))
  from applied
$$;

revoke all on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)
  to service_role;

notify pgrst,'reload schema';
