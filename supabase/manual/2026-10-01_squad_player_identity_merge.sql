-- MANUAL, ONE-OFF MERGE (not a migration; never run by `supabase db push`).
-- Optional operator tool: squad players stored twice for one real person.
--
-- Background: GOAL's /teams/:id/players answer can list one person twice
-- under two catalog ids (a complete record and a sparse twin whose name
-- tokens are in another order, same shirt number). Migration 20261001130000
-- already HIDES the sparse twin in every team profile (read side). Nothing
-- merges automatically. This script merges exactly the pairs the read side
-- hides, so search, profiles and lineups also converge on one identity.
--
-- Candidates = futbeat_private.team_squad_hidden_twins: EXACTLY what the read
-- side hides now. Twins were found when a squad answer was stored (same
-- team AND same answer AND same known shirt number AND identical, safely
-- folded name-token multisets (>= 2 tokens) AND exactly two such rows, one
-- sparse (no photo/birth date/age), one rich (photo or birth date)), and the
-- evidence still holds live (rich partner still a member of the team, hidden
-- row still sparse). The alias (sparse) is redirected to the rich one
--   through futbeat_private.futbeat_merge_player_identity, which refuses
--   conflicting birth dates and never deletes an entity.
--
-- PROCEDURE (production, explicit operator decision only):
--   0. Migration 20261001130000 applied (both sections check it and refuse
--      otherwise).
--   1. Run section [dry-run]; review the rows; note candidate_count N.
--      (Read-only estimate on 2026-10-01 with this rule: 330 twins in 159
--      teams; re-measure, squads keep refreshing.)
--   2. Replace __EXPECTED_COUNT__ in section [apply] with N and run it. The DO
--      block is atomic: if the candidate or merged count differs from N it
--      raises and nothing is written.
--   3. Re-run [dry-run]: it must return 0 rows.
--
-- UNDO one merge (all data is in futbeat_private.player_identity_merges, one
-- row per merge, latest first; undo in reverse merged_at order):
--   a. delete from entity_redirects where alias_id=<alias_id> and kind='player';
--      update entity_redirects set canonical_id=<alias_id>
--        where alias_id = any(<redirected_aliases>);
--   b. update provider_entities set canonical_id=<alias_id>
--        where provider='goal_api' and kind='player'
--          and external_id = any(<moved_provider_ids>);
--      update provider_media_cache set canonical_id=<alias_id>
--        where kind='player' and provider||':'||external_id = any(<moved_media_cache>);
--   c. re-insert every <moved_memberships> row (team_id,player_id,provider,
--      updated_at) into team_squad_members; delete the kept player's row for
--      that team only where keptHadMembership=false;
--   d. re-insert <moved_follows> into push_follows and <moved_interests> into
--      temporary_interests; delete the kept player's copy only where
--      keptHadFollow / keptHadInterest = false; then
--      perform futbeat_private.refresh_interest_aggregates();
--   e. update entities set payload=<canonical_payload_before> where
--      id=<canonical_id> (restores name, aliases, filled facts and media),
--      unless the kept player was refreshed since (then remove only the alias
--      name from payload.aliases and the facts the merge filled).
-- Keep the candidate query in both sections identical.

-- [dry-run] ------------------------------------------------------------------
with installed as (
  select to_regprocedure('futbeat_private.futbeat_merge_player_identity(text,text,text)') is not null
    and to_regprocedure('futbeat_private.team_squad_hidden_twins(text)') is not null ok
), candidates as (
  select distinct on (d.alias_id) t.team_id,d.alias_id,d.canonical_id
  from (select distinct team_id from futbeat_private.team_squad_members) t
  cross join lateral futbeat_private.team_squad_hidden_twins(t.team_id) d
  where not exists(
    select 1 from futbeat_private.entity_redirects r where r.alias_id=d.alias_id)
  order by d.alias_id,t.team_id
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
     or to_regprocedure('futbeat_private.team_squad_hidden_twins(text)') is null then
    raise exception 'Squad identity merge refused: migration 20261001130000 is not installed';
  end if;

  with candidates as (
    select distinct on (d.alias_id) t.team_id,d.alias_id,d.canonical_id
    from (select distinct team_id from futbeat_private.team_squad_members) t
    cross join lateral futbeat_private.team_squad_hidden_twins(t.team_id) d
    where not exists(
      select 1 from futbeat_private.entity_redirects r where r.alias_id=d.alias_id)
    order by d.alias_id,t.team_id
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
      'manual 2026-10-01: GOAL squad listed one person twice (same answer, shirt number and name tokens)');
    if v_result->>'status'='merged' then v_merged:=v_merged+1; end if;
  end loop;

  if v_merged<>v_expected then
    raise exception 'Squad identity merge aborted: % merged, dry-run expected %; nothing written',
      v_merged,v_expected;
  end if;
  raise notice 'Squad identity merge: % duplicate player identities redirected',v_merged;
end $$;
