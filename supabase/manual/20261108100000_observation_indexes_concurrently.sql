-- Run BEFORE 20261108100000_disk_io_hot_paths.sql on a large database
-- (manual, NOT a migration). CONCURRENTLY never blocks LIVE ingestion; run
-- each statement on its own, outside a transaction block (autocommit). Each
-- reads provider_observations once: run off-peak, with Disk IO budget left
-- (not while the budget is depleted). If one fails, drop the INVALID index
-- and retry later:
--   drop index concurrently if exists futbeat_private.<name>;
-- Check validity afterwards:
--   select indexrelid::regclass,indisvalid from pg_index
--   where indrelid='futbeat_private.provider_observations'::regclass;

create index concurrently if not exists provider_observations_match_received_all_idx
  on futbeat_private.provider_observations(canonical_match_id,received_at desc,id desc)
  where canonical_match_id is not null;

create index concurrently if not exists provider_observations_final_states_idx
  on futbeat_private.provider_observations(canonical_match_id,received_at desc,id desc)
  where status in ('VERIFIED','FINISHED_PENDING_VERIFICATION','ABANDONED','SUSPENDED');
