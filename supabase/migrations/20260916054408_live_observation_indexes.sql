create index provider_entities_canonical_id_idx
  on futbeat_private.provider_entities (canonical_id);
create index provider_observations_canonical_match_id_idx
  on futbeat_private.provider_observations (canonical_match_id)
  where canonical_match_id is not null;
create index live_events_canonical_match_id_idx
  on futbeat_private.live_events (canonical_match_id)
  where canonical_match_id is not null;
create index live_match_state_canonical_match_id_idx
  on futbeat_private.live_match_state (canonical_match_id)
  where canonical_match_id is not null;
