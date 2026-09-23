# Coverage diagnostics (read-only)

`backend/diagnostics/coverage_report.sql` measures player, squad, lineup and
match-detail coverage in one query. It only reads: no writes, no provider
calls, no quota use.

## Run it (production, later)

From the Supabase SQL editor or `psql` as the postgres/service role:

```sql
begin transaction read only;
-- paste backend/diagnostics/coverage_report.sql
rollback;
```

Requires migrations up to `20260922235500_player_search_coverage.sql`
(`lineup_rows`, `futbeat_player_catalog_metrics`). It does not depend on
`20260923020000`.

## What it reports

| Key | Meaning |
| --- | --- |
| `players.canonical_players` | Canonical players (redirect aliases excluded) |
| `players.indexed_players` / `mapped_players` | In the search index / with a provider mapping |
| `players.with_team`, `with_position`, `with_shirt_number`, `with_country`, `with_photo` | Players with each fact |
| `players.lineup_appearances_resolved` / `_unresolved` | Stored lineup rows with / without a canonical player |
| `squads.*` | Squad members, mapping %, photo %, teams with fresh / stale squads |
| `lineups.appearances_with_canonical_photo` | Lineup rows whose player has a verified photo |
| `match_detail.cached`, `with_lineups`, `with_statistics`, `with_events` | Stored detail coverage (both GOAL lineup shapes counted) |
| `match_detail.lineup_shapes` / `statistics_shapes` | Shape mix of stored payloads (array/object/missing) |
| `match_detail.terminal_*` | Finished matches with detail / lineups / statistics |

Quick reading: a high `lineup_appearances_unresolved` means the lineup harvest
did not run on stored detail; a low `terminal_with_lineups` against
`terminal_with_detail` means the provider sent no lineups (not a mobile bug).

The query is verified locally by `backend/test/coverage_report.test.mjs`.
