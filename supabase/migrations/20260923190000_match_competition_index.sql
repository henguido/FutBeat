-- Match Center hot path: find a competition's matches without scanning the
-- whole catalog.
--
-- Generic partial expression index on match entities by competitionId. It
-- serves, per Match Center open / standings read:
--   * match_standings_state: "is a match of this competition live?"
--   * futbeat_apply_provisional_standings (read_match_context): matches of
--     the table's competition played after the snapshot
--   * standings_season_key (archive trigger): "has the current season started?"
--   * futbeat_reserve_goal_standings_call coverage candidates (nearby/active
--     matches per mapped competition)
-- All previously did a sequential scan of futbeat_private.entities. No
-- equivalent index exists (entities only had its primary key on id).
-- Not tied to any competition, season or country.

create index if not exists entities_match_competition_idx
  on futbeat_private.entities ((payload->>'competitionId'))
  where kind='match';
