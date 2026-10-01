-- ONE-OFF cleanup after 20260930140000_event_key_duplicates.sql (NOT a
-- migration; run manually, once, after that migration is applied).
--
-- Retracts (never deletes) the canonical rows record_live_events of
-- 20260930100000 stored as re-keyed copies of another row (payload
-- duplicateOf) when GOAL re-issued an event id. Same selection as the dry
-- run (20260930140000_event_key_duplicates_dry_run.sql): per (match, copied
-- row), every copy when the copied row is active, otherwise every copy but
-- the oldest. Each retraction goes through retract_canonical_event (audited
-- in canonical_event_revisions, reason 'duplicate_upstream_key_cleanup',
-- never a correction twin, never pushed). Realtime rows of the affected
-- matches are republished.
--
-- Guards:
--   * aborts unless 20260930140000 is applied (copies would be re-created
--     and the read model would not collapse the remaining ones);
--   * aborts when more rows than v_max would be touched (bounded: run the dry
--     run first; raise v_max deliberately if the count is expected);
--   * one statement, one transaction: all or nothing;
--   * idempotent: retracted rows are never selected again (a second run
--     retracts 0).
do $$
declare
  v_max constant integer := 2000;
  v_now timestamptz := now();
  v_total integer;
  v_done integer := 0;
  v_ids text[];
  v_matches text[];
  v_id text;
  r record;
begin
  if position('duplicate_upstream_key' in pg_get_functiondef(
      'futbeat_private.record_live_events(text,timestamptz,jsonb)'::regprocedure)) = 0 then
    raise exception 'event key cleanup: apply migration 20260930140000_event_key_duplicates first';
  end if;

  with copies as (
    select c.id, c.match_id, c.first_seen_at, c.payload->>'duplicateOf' root,
      exists(select 1 from futbeat_private.canonical_events o
        where o.id=c.payload->>'duplicateOf' and o.retracted_at is null) root_active
    from futbeat_private.canonical_events c
    where c.retracted_at is null
      and nullif(c.payload->>'duplicateOf','') is not null
      and not futbeat_private.is_phase_event(c.event_type)
      and not futbeat_private.is_synthetic_event(c.payload)
  ), ranked as (
    select *, row_number() over(partition by match_id, root order by first_seen_at, id) rn from copies
  )
  select coalesce(array_agg(id order by match_id, id), '{}'),
         coalesce(array_agg(distinct match_id), '{}')
    into v_ids, v_matches
    from ranked where root_active or rn > 1;

  v_total := cardinality(v_ids);
  if v_total > v_max then
    raise exception 'event key cleanup: % rows exceed the bound % (run the dry run, then raise v_max deliberately)', v_total, v_max;
  end if;

  foreach v_id in array v_ids loop
    if futbeat_private.retract_canonical_event(v_id, v_now, 'duplicate_upstream_key_cleanup') then
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

  raise notice 'event key cleanup: % of % candidate rows retracted', v_done, v_total;
end $$;
