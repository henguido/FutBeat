-- RECORD OF PRODUCTION (read 2026-11-27): futbeat_private.team_squad_hidden_twins as it runs in production.
-- Production never applied BE10 P0.3 (20261107180000); it runs the 20261001130000 version (prosrc without CR:
-- md5 6ebd8dca53bb117fa83abddca2de8aa4). This record makes a rebuild from Git equal production again.
-- BE10 P0.3 stays in Git as an UNDEPLOYED follow-up: its migration file is unchanged and the tests re-apply it
-- on top of this state (backend/test/helpers/undeployed_sql.mjs, pinned in scripts/release/backend1.undeployed-sources.json).
-- player_identity_richness needs no record: production differs from main only by CRLF line endings
-- inside the stored body (CR-insensitive md5 df79415008fabd4dd68eff48b579ad99 on both).
-- No data is changed; production ACL is owner-only (postgres=X), the same as main's.

CREATE OR REPLACE FUNCTION futbeat_private.team_squad_hidden_twins(p_team_id text)
 RETURNS TABLE(alias_id text, canonical_id text)
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
  select t.alias_id,t.canonical_id
  from futbeat_private.team_squad_twins t
  join futbeat_private.team_squad_members alias_sm
    on alias_sm.team_id=p_team_id and alias_sm.player_id=t.alias_id
  join futbeat_private.team_squad_members partner_sm
    on partner_sm.team_id=p_team_id and partner_sm.player_id=t.canonical_id
  join futbeat_private.entities e on e.id=t.alias_id and e.kind='player'
  where t.team_id=any(futbeat_private.team_identity_ids(p_team_id))
    and futbeat_private.squad_player_sparse(e.payload)
    and not exists(select 1 from futbeat_private.entity_redirects r
      where r.kind='player' and r.alias_id in (t.alias_id,t.canonical_id))
$function$
;
