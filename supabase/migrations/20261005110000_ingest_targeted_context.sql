-- Global ingest: read only the existing entities a batch needs.
--
-- Evidence (production, 2026-10-06): the GOAL hot ingest called
-- public.futbeat_read_snapshot() first ("read-current"): ~3.77 MB of JSON,
-- ~118k buffers, 5.6 s average / 7.8 s max over 21 calls, against the API
-- role's 8 s statement timeout. Run 37411216092 failed there (57014).
-- The ingest uses only three parts of that snapshot (normalizeGoalApiFixtures):
--   * competitions[] (full item, merged into the new one, by canonical id);
--   * teams[] (full item, merged likewise, by canonical id);
--   * matches[] id/homeTeamId/awayTeamId/startTime, to reuse an existing
--     match id for the same pairing in the same 5-minute kickoff bucket.
-- Players, news, standings... are never read by the ingest.
--
-- futbeat_read_ingest_context reads the SAME source as futbeat_read_snapshot
-- (the latest futbeat_private.imports snapshot), keeps only the requested
-- canonical competitions/teams and the matches of requested teams inside
-- [p_from - 5 min, p_to + 5 min], then applies the SAME redirect function to
-- that subset: each returned item equals the corresponding item of the full
-- snapshot. Read-only (stable, no writes, no version bump).
-- Rollback: drop function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz).

create or replace function public.futbeat_read_ingest_context(
  p_competition_ids text[],p_team_ids text[],p_from timestamptz,p_to timestamptz
) returns jsonb language sql stable security definer set search_path='' as $$
  with latest as (
    select snapshot from futbeat_private.imports
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
    cross join lateral jsonb_array_elements(case when jsonb_typeof(latest.snapshot->'competitions')='array'
      then latest.snapshot->'competitions' else '[]'::jsonb end) with ordinality c(value,ordinality)
    left join redirects r on r.kind='competition' and r.alias_id=c.value->>'id'
    join want_competitions w on w.id=coalesce(r.canonical_id,c.value->>'id')
  ), teams as (
    select t.value,t.ordinality from latest
    cross join lateral jsonb_array_elements(case when jsonb_typeof(latest.snapshot->'teams')='array'
      then latest.snapshot->'teams' else '[]'::jsonb end) with ordinality t(value,ordinality)
    left join redirects r on r.kind='team' and r.alias_id=t.value->>'id'
    join want_teams w on w.id=coalesce(r.canonical_id,t.value->>'id')
  ), matches as (
    select m.value,m.ordinality from latest
    cross join lateral jsonb_array_elements(case when jsonb_typeof(latest.snapshot->'matches')='array'
      then latest.snapshot->'matches' else '[]'::jsonb end) with ordinality m(value,ordinality)
    left join redirects rh on rh.kind='team' and rh.alias_id=m.value->>'homeTeamId'
    left join redirects ra on ra.kind='team' and ra.alias_id=m.value->>'awayTeamId'
    join want_teams wh on wh.id=coalesce(rh.canonical_id,m.value->>'homeTeamId')
    join want_teams wa on wa.id=coalesce(ra.canonical_id,m.value->>'awayTeamId')
    where p_from is not null and p_to is not null
      and futbeat_private.try_timestamptz(m.value->>'startTime')
        between p_from-interval '5 minutes' and p_to+interval '5 minutes'
  ), subset as (
    select jsonb_build_object(
      'schemaVersion',1,'demo',false,
      'competitions',coalesce((select jsonb_agg(value order by ordinality) from competitions),'[]'::jsonb),
      'teams',coalesce((select jsonb_agg(value order by ordinality) from teams),'[]'::jsonb),
      'players','[]'::jsonb,
      'matches',coalesce((select jsonb_agg(value order by ordinality) from matches),'[]'::jsonb)) s
  )
  select jsonb_build_object(
    'competitions',coalesce(r.s->'competitions','[]'::jsonb),
    'teams',coalesce(r.s->'teams','[]'::jsonb),
    'matches',coalesce(r.s->'matches','[]'::jsonb))
  from subset,lateral (select futbeat_private.futbeat_apply_entity_redirects_snapshot(subset.s) s) r
$$;

revoke all on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)
  from public,anon,authenticated;
grant execute on function public.futbeat_read_ingest_context(text[],text[],timestamptz,timestamptz)
  to service_role;

notify pgrst,'reload schema';
