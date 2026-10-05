-- GOAL's placeholder player id "0" is not an identity.
--
-- Evidence (read-only production, 2026-10-05): in 10 days of stored match
-- detail, 530 lineup rows of 101 matches carry playerKey "0" -- all
-- different players GOAL has no id for. The lineup harvest resolved "0" like
-- any provider id: provider_entities(goal_api, player, '0') points to ONE
-- canonical player, so every such row linked to that player's profile and
-- photo. Events and substitutions carry no "0" ids (checked).
--
-- Fix: lineup_rows (the single reader every SQL lineup harvest uses) drops a
-- placeholder id (all zeros) from playerId / playerKey / player.id before the
-- row reaches a harvest; the row keeps its name, number and position, so it
-- is still counted and rendered, just never resolved to an identity. The
-- worker and the API normalizers apply the same rule (goalPlayerId).
-- The existing '0' mapping is left in place (a data repair needs
-- authorization): `delete from futbeat_private.provider_entities where
-- provider='goal_api' and kind='player' and external_id ~ '^0+$'` once
-- this migration is live; nothing else references the placeholder id.
-- Rollback: re-create lineup_rows from 20260922235500_player_search_coverage.sql.

create or replace function futbeat_private.lineup_item_without_placeholder(p_item jsonb)
returns jsonb language sql immutable set search_path='' as $$
 select case when jsonb_typeof(p_item)<>'object' then p_item else
   (p_item
     - (case when btrim(coalesce(p_item->>'playerId','')) ~ '^0+$' then 'playerId' else '' end)
     - (case when btrim(coalesce(p_item->>'playerKey','')) ~ '^0+$' then 'playerKey' else '' end))
   || case when jsonb_typeof(p_item->'player')='object'
          and btrim(coalesce(p_item#>>'{player,id}','')) ~ '^0+$'
        then jsonb_build_object('player',(p_item->'player')-'id') else '{}'::jsonb end
 end
$$;

create or replace function futbeat_private.lineup_rows(p_payload jsonb)
returns table(side text,item jsonb) language sql immutable set search_path='' as $$
 select nullif(lower(r->>'team'),''),futbeat_private.lineup_item_without_placeholder(r)
 from jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups')='array'
   then p_payload->'lineups' else '[]'::jsonb end) r
 where lower(coalesce(r->>'type','')) like 'start%' or lower(coalesce(r->>'type','')) like 'sub%'
 union all
 select s.side,futbeat_private.lineup_item_without_placeholder(r)
 from (values('home'),('away')) s(side)
 cross join (values('startingLineups'),('substitutes')) k(key)
 cross join lateral jsonb_array_elements(case when jsonb_typeof(p_payload->'lineups'->s.side->k.key)='array'
   then p_payload->'lineups'->s.side->k.key else '[]'::jsonb end) r
 where jsonb_typeof(p_payload->'lineups')='object'
$$;

revoke all on function futbeat_private.lineup_item_without_placeholder(jsonb),
  futbeat_private.lineup_rows(jsonb) from public,anon,authenticated;
