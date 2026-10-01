-- MANUAL, ONE-OFF MERGE (not a migration; never run by `supabase db push`).
-- Squad players stored twice for one real person (GOAL squad duplicates).
--
-- Background: GOAL's /teams/:id/players answer lists some people twice under
-- two catalog ids (a complete record and a sparse one whose name is reversed
-- or shortened, same shirt number). Migration 20261001130000 already hides
-- the duplicate in every team profile (read side) and merges it on that
-- team's next squad refresh (ingestion). This script merges the duplicates
-- that are stored today so search, profiles and lineups converge NOW instead
-- of over the next 7-day squad refresh cycle. Optional; safe to skip.
--
-- A pair is a candidate only when ALL hold:
--   * futbeat_private.team_squad_duplicate_pairs (the same rule the read side
--     and ingestion use: same team; same known shirt number and compatible
--     names, or identical full names when a number is unknown; ambiguous
--     groups excluded; richest identity kept);
--   * both rows were written by the SAME squad fetch (equal updated_at), i.e.
--     one GOAL answer listed both;
--   * the alias is not redirected yet.
-- Each merge goes through futbeat_private.futbeat_merge_player_identity: a
-- kind='player' row in entity_redirects; provider ids, squad memberships,
-- follows and interests move to the kept player; the kept player only gains
-- facts it lacks (its name stays; the alias name joins payload.aliases). NO
-- entity row is deleted.
--
-- PROCEDURE (production, explicit operator decision only):
--   0. Migration 20261001130000 applied (both sections check it and refuse
--      otherwise).
--   1. Run section [dry-run]; review the rows; note candidate_count N.
--      (Read-only estimate on 2026-10-01 with the same rule: ~716 duplicate
--      identities in ~270 teams; 2 more are cross-fetch and excluded. The
--      number shrinks as squads refresh and merge on ingestion: re-measure.)
--   2. Replace __EXPECTED_COUNT__ in section [apply] with N and run it. The DO
--      block is atomic: if the merged count differs from N it raises and
--      nothing is written.
--   3. Re-run [dry-run]: it must return 0 rows.
--   Revert one merge: delete its entity_redirects row (kind='player',
--   reason starting 'manual 2026-10-01') and point the alias's provider id
--   back (provider_entities.external_id = alias payload.provenance.externalId).
-- Keep the candidate query in both sections identical.

-- [dry-run] ------------------------------------------------------------------
with installed as (
  select to_regprocedure('futbeat_private.futbeat_merge_player_identity(text,text,text)') is not null
    and to_regprocedure('futbeat_private.team_squad_duplicate_pairs(text)') is not null ok
), teams as (
  select distinct team_id from futbeat_private.team_squad_members
), pairs as (
  select t.team_id,d.alias_id,d.canonical_id
  from teams t
  cross join lateral futbeat_private.team_squad_duplicate_pairs(t.team_id) d
), candidates as (
  select distinct on (p.alias_id) p.*
  from pairs p
  where exists(
      select 1
      from futbeat_private.team_squad_members a
      join futbeat_private.team_squad_members b
        on b.team_id=a.team_id and b.updated_at=a.updated_at
      where a.team_id=p.team_id and a.player_id=p.alias_id and b.player_id=p.canonical_id)
    and not exists(
      select 1 from futbeat_private.entity_redirects r where r.alias_id=p.alias_id)
  order by p.alias_id,p.team_id
)
select count(*) over () candidate_count,c.team_id,t.payload->>'name' team,
  c.alias_id,a.payload->>'name' alias_name,a.payload->'shirtNumber' alias_shirt,
  c.canonical_id,k.payload->>'name' kept_name,k.payload->'shirtNumber' kept_shirt
from candidates c
join futbeat_private.entities a on a.id=c.alias_id
join futbeat_private.entities k on k.id=c.canonical_id
left join futbeat_private.entities t on t.id=c.team_id
where (select ok from installed)
order by c.team_id,kept_name;

-- [apply] --------------------------------------------------------------------
do $$
declare
  v_expected integer:=__EXPECTED_COUNT__;
  v_pairs jsonb;
  v_pair jsonb;
  v_result jsonb;
  v_merged integer:=0;
begin
  if to_regprocedure('futbeat_private.futbeat_merge_player_identity(text,text,text)') is null
     or to_regprocedure('futbeat_private.team_squad_duplicate_pairs(text)') is null then
    raise exception 'Squad identity merge refused: migration 20261001130000 is not installed';
  end if;

  with teams as (
    select distinct team_id from futbeat_private.team_squad_members
  ), pairs as (
    select t.team_id,d.alias_id,d.canonical_id
    from teams t
    cross join lateral futbeat_private.team_squad_duplicate_pairs(t.team_id) d
  ), candidates as (
    select distinct on (p.alias_id) p.*
    from pairs p
    where exists(
        select 1
        from futbeat_private.team_squad_members a
        join futbeat_private.team_squad_members b
          on b.team_id=a.team_id and b.updated_at=a.updated_at
        where a.team_id=p.team_id and a.player_id=p.alias_id and b.player_id=p.canonical_id)
      and not exists(
        select 1 from futbeat_private.entity_redirects r where r.alias_id=p.alias_id)
    order by p.alias_id,p.team_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('alias',alias_id,'canonical',canonical_id)
    order by team_id,alias_id),'[]'::jsonb)
  into v_pairs
  from candidates;

  if jsonb_array_length(v_pairs)<>v_expected then
    raise exception 'Squad identity merge aborted: % candidates, dry-run expected %; nothing written',
      jsonb_array_length(v_pairs),v_expected;
  end if;

  for v_pair in select value from jsonb_array_elements(v_pairs) loop
    v_result:=futbeat_private.futbeat_merge_player_identity(
      v_pair->>'alias',v_pair->>'canonical',
      'manual 2026-10-01: GOAL squad listed one person twice (same team and shirt number or full name)');
    if v_result->>'status'='merged' then v_merged:=v_merged+1; end if;
  end loop;

  if v_merged<>v_expected then
    raise exception 'Squad identity merge aborted: % merged, dry-run expected %; nothing written',
      v_merged,v_expected;
  end if;
  raise notice 'Squad identity merge: % duplicate player identities redirected',v_merged;
end $$;
