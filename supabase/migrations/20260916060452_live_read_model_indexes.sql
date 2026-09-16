create index if not exists live_match_updates_changed_idx
  on public.live_match_updates (changed_at desc, match_id);
create index if not exists live_match_updates_provider_external_idx
  on public.live_match_updates (provider, external_match_id);
