# Standings coverage NO_DATA (Issue #116)

## Root cause

- `.github/workflows/standings.yml` fetched GOAL with `Invoke-RestMethod`,
  which throws on a 4xx before the body can be read. A league without a table
  (`404 {"success":false,"code":"STANDINGS_NOT_FOUND"}`) was recorded as
  `GOAL_STANDINGS_FETCH_FAILED` with `httpStatus = null` and the run failed.
- The coverage planner decides freshness from `standings_cache`, which is
  never written for such a league, so it was selected again on every run.

## Classification (`classifyGoalStandingsResponse`, mirrored in the workflow)

| Answer | Outcome |
|---|---|
| provider code `STANDINGS_NOT_FOUND` (`code`, `errorCode` or `error.code`) with HTTP 404 or 2xx | NO_DATA |
| 2xx, `success: true`, `data` array with < 2 rows | NO_DATA (`EMPTY_STANDINGS`) |
| 2xx, `success: true`, `data` array with ≥ 2 rows | rows → `standings-ingest` |
| no HTTP response (network, timeout) | FAILED `GOAL_STANDINGS_NETWORK` |
| 401 / 403 | FAILED `GOAL_STANDINGS_AUTH` |
| 429 | FAILED `GOAL_STANDINGS_RATE_LIMITED` |
| 5xx (even with the not-found code) | FAILED `GOAL_STANDINGS_HTTP_5XX` |
| any other 404 / status | FAILED `GOAL_STANDINGS_HTTP_<status>` |
| malformed 2xx (no `success: true`, `data` not an array, not JSON) | FAILED `GOAL_STANDINGS_INVALID_PAYLOAD` |

The workflow uses `Invoke-WebRequest -SkipHttpErrorCheck` so status, JSON
body and `X-RateLimit-Remaining` survive 4xx/5xx answers. NO_DATA →
`standings-no-data`, `STANDINGS_NO_DATA ...`, exit 0. Failures →
`standings-fail` with the real status/code, red run. The server re-checks a
reported NO_DATA (`isGoalStandingsNoData`) and refuses anything else.

## Negative cache (migration `20260925050000_standings_coverage_no_data.sql`)

- `futbeat_private.standings_coverage_state(competition_id)` (canonical id,
  never a name): `NO_DATA`, the external league id that answered, provider
  code, HTTP status, `next_retry_at = now + standingsNoDataDays` (central
  setting, default 3 days; same TTL as #98 user-demand NO_DATA).
- `futbeat_record_standings_no_data`: completes the coverage reservation as
  `SUCCEEDED` (real HTTP status, `metadata.outcome = NO_DATA`,
  `metadata.providerCode`), identity taken from the reservation.
- Coverage planner skips the competition while the NO_DATA is valid **for its
  current mapping**; a new external league id retries at once.
- Any `standings_cache` write for the competition clears the state.
- #98 user demand (`standings_demands`, exact season) is untouched: the
  coverage state never blocks or marks it, and a user reservation cannot be
  completed through the coverage no-data path.
