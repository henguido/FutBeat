-- FutBeat data coverage report. READ-ONLY: a single SELECT, no writes, no
-- provider calls. Run it later against production from the Supabase SQL
-- editor (or psql) as postgres/service role, ideally as:
--   begin transaction read only;  <this file>  rollback;
-- Tested locally against PGlite in backend/test/coverage_report.test.mjs.
--
-- Output: one jsonb row with players, squads, lineups and match detail.
with detail as (
  select c.match_id,c.fetched_at,c.payload,
    (select count(*) from futbeat_private.lineup_rows(c.payload)) lineup_rows,
    -- Same measure as futbeat_private.detail_statistics_count (inlined so the
    -- report also runs before migration 20260923020000 is applied).
    (select count(*) from jsonb_path_query(coalesce(c.payload->'statistics','null'::jsonb),
      'strict $.** ? (@.type() == "number" || @.type() == "string" || @.type() == "boolean")')) statistic_values,
    jsonb_typeof(c.payload->'lineups') lineup_shape,
    jsonb_typeof(c.payload->'statistics') statistics_shape
  from futbeat_private.match_detail_cache c
), appearances as (
  select l.item,e.payload player
  from futbeat_private.match_detail_cache c
  cross join lateral futbeat_private.lineup_rows(c.payload) l
  left join futbeat_private.provider_entities pe on pe.provider='goal_api' and pe.kind='player'
    and pe.external_id=coalesce(nullif(btrim(l.item->>'playerId'),''),nullif(btrim(l.item->>'playerKey'),''),
      nullif(btrim(l.item#>>'{player,id}'),''))
  left join futbeat_private.entities e on e.id=futbeat_private.futbeat_resolve_entity_id('player',pe.canonical_id)
    and e.kind='player'
), terminal as (
  select m.id from futbeat_private.entities m
  where m.kind='match' and m.payload->>'status' in ('VERIFIED','FINISHED_PENDING_VERIFICATION')
)
select jsonb_build_object(
  'generated_at',to_char(now() at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  -- canonical_players, indexed, mapped, with team/position/shirt/country/photo,
  -- lineup appearances resolved/unresolved.
  'players',public.futbeat_player_catalog_metrics(),
  -- squads: members, mapping %, photo %, fresh/stale teams.
  'squads',public.futbeat_player_coverage_metrics(),
  'lineups',jsonb_build_object(
    'appearances',(select count(*) from appearances),
    'appearances_with_canonical_player',(select count(*) from appearances where player is not null),
    'appearances_with_canonical_photo',(select count(*) from appearances
      where futbeat_private.valid_player_media(player->'media'))),
  'match_detail',jsonb_build_object(
    'cached',(select count(*) from detail),
    'with_lineups',(select count(*) from detail where lineup_rows>0),
    'with_statistics',(select count(*) from detail where statistic_values>0),
    'with_events',(select count(*) from detail where jsonb_typeof(payload->'events')='array'
      and jsonb_array_length(payload->'events')>0),
    'lineup_shapes',(select coalesce(jsonb_object_agg(shape,n),'{}') from (
      select coalesce(lineup_shape,'missing') shape,count(*) n from detail group by 1) s),
    'statistics_shapes',(select coalesce(jsonb_object_agg(shape,n),'{}') from (
      select coalesce(statistics_shape,'missing') shape,count(*) n from detail group by 1) s),
    'fetched_last_24h',(select count(*) from detail where fetched_at>now()-interval '24 hours'),
    'terminal_matches',(select count(*) from terminal),
    'terminal_with_detail',(select count(*) from terminal t join detail d on d.match_id=t.id),
    'terminal_with_lineups',(select count(*) from terminal t join detail d on d.match_id=t.id where d.lineup_rows>0),
    'terminal_with_statistics',(select count(*) from terminal t join detail d on d.match_id=t.id
      where d.statistic_values>0))
) as coverage;
