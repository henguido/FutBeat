-- ONE-OFF cleanup after 20261001110000_shootout_kicks.sql (NOT a migration;
-- run manually, once, after that migration is applied).
--
-- Retracts (never deletes) the active canonical GOAL rows derived from a
-- penalty shoot-out kick. Same selection as the dry run
-- (20261001110000_shootout_kicks_dry_run.sql): rows a shoot-out live row
-- produced (upstream key or record_live_events id formula), never a row an
-- in-game live row of the same match produces as well, never a synthetic
-- row. Each retraction goes through retract_canonical_event (audited in
-- canonical_event_revisions, reason 'shootout_kick': never a correction twin,
-- never pushed). Realtime rows of the affected matches are republished.
--
-- Usage (one transaction):
--   begin;
--   set local futbeat.expected_shootout_rows = '<sum of dry-run candidates>';
--   \i 20261001110000_shootout_kicks_cleanup.sql
--   commit;
--
-- Guards:
--   * aborts unless 20261001110000 is applied (an older record_live_events
--     would store the kicks again);
--   * aborts unless futbeat.expected_shootout_rows is set and equals the
--     number of rows selected now (bounded: run the dry run first);
--   * one statement: all or nothing; holds the per-match ingestion advisory
--     locks of the affected matches while it runs;
--   * idempotent: retracted rows are never selected again (a second run with
--     expected 0 retracts 0).
do $$
declare
  v_expected integer := nullif(current_setting('futbeat.expected_shootout_rows', true), '')::integer;
  v_now timestamptz := now();
  v_total integer;
  v_done integer := 0;
  v_ids text[];
  v_matches text[];
  v_id text;
  r record;
begin
  if to_regprocedure('futbeat_private.is_shootout_kick_row(jsonb)') is null
     or position('is_shootout_kick_row' in pg_get_functiondef(
       'futbeat_private.record_live_events(text,timestamptz,jsonb)'::regprocedure)) = 0 then
    raise exception 'shoot-out cleanup: apply migration 20261001110000_shootout_kicks first';
  end if;
  if v_expected is null then
    raise exception 'shoot-out cleanup: set futbeat.expected_shootout_rows to the dry-run count first';
  end if;

  -- Serialize with live ingestion (same per-match advisory lock as
  -- record_live_batch_core), stable order, then select under those locks.
  for r in
    select distinct le.provider, le.external_match_id
    from futbeat_private.live_events le
    where le.provider='goal_api' and le.event_type='GOAL'
      and futbeat_private.is_shootout_kick_row(le.payload->'payload')
    order by le.provider, le.external_match_id
  loop
    perform pg_advisory_xact_lock(hashtext(r.provider || ':' || r.external_match_id));
  end loop;

  with lm as (
    select le.event_key, le.event_type, le.minute, le.team_external_id, le.player_external_id, le.payload,
      pe.canonical_id mid, futbeat_private.is_shootout_kick_row(le.payload->'payload') is_kick
    from futbeat_private.live_events le
    join futbeat_private.provider_entities pe
      on pe.provider='goal_api' and pe.kind='match' and pe.external_id=le.external_match_id
    where le.provider='goal_api' and le.event_type='GOAL'
      and le.external_match_id in (select x.external_match_id from futbeat_private.live_events x
        where x.provider='goal_api' and x.event_type='GOAL'
          and futbeat_private.is_shootout_kick_row(x.payload->'payload'))
  ), ids as (
    select lm.mid, lm.is_kick, lm.event_key,
      'fb_event_'||md5(concat_ws('|',lm.mid,'goal_api',lm.event_type,lm.minute,
        coalesce(lm.payload->>'extraMinute',lm.payload#>>'{payload,time,extra}'),
        lm.team_external_id,lm.player_external_id,'')) content_id
    from lm
  ), produced as (
    select c.id, c.match_id, i.is_kick
    from futbeat_private.canonical_events c
    join ids i on i.mid=c.match_id
     and (c.id=i.content_id or c.id='fb_event_'||md5(i.content_id||'|'||i.event_key)
       or c.payload->>'providerEventKey'=i.event_key)
    where c.provider='goal_api' and c.event_type='GOAL' and c.retracted_at is null
      and not futbeat_private.is_synthetic_event(c.payload)
  ), per_row as (
    select id, match_id from produced group by id, match_id having bool_and(is_kick)
  )
  select coalesce(array_agg(id order by match_id, id), '{}'),
         coalesce(array_agg(distinct match_id), '{}')
    into v_ids, v_matches
    from per_row;

  v_total := cardinality(v_ids);
  if v_total <> v_expected then
    raise exception 'shoot-out cleanup: % rows selected, % expected (re-run the dry run)', v_total, v_expected;
  end if;

  foreach v_id in array v_ids loop
    if futbeat_private.retract_canonical_event(v_id, v_now, 'shootout_kick') then
      v_done := v_done + 1;
    end if;
  end loop;

  for r in
    select distinct s.provider, s.external_match_id
    from futbeat_private.live_match_state s
    where s.canonical_match_id = any(v_matches)
  loop
    perform public.futbeat_publish_live_state(r.provider, r.external_match_id);
  end loop;

  raise notice 'shoot-out cleanup: % of % candidate rows retracted', v_done, v_total;
end $$;
