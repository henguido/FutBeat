# Team match coverage (#150, part 2)

#152 made the team profile read model correct, but it can only page matches
that FutBeat already stored. This adds **central, per-team coverage** so a
club or national team with few stored matches gets its schedule and recent
history. Migration: `supabase/migrations/20260929110000_team_match_coverage.sql`
(versioned only — not applied; no cron).

## Provider capability (audit)

- No adapter in the repo fetched fixtures by team. The only team-level call
  was GOAL `/teams/{id}/players` (squads).
- The official GOAL SDK (`goal-api-js`, `ENDPOINTS.md`) documents
  `GET /teams/{id}/fixtures` with `status`, `from`, `to`, `limit` (≤100) and
  `offset`, in the standard `{success, data, pagination}` envelope with the
  `X-RateLimit-*` headers. `/teams/{id}/results` and `/teams/{id}/upcoming`
  exist too; one ranged `fixtures` call covers both past and future.
- **Not verified yet:** the item shape of that endpoint is not published.
  Items go through the existing `normalizeGoalApiFixtures` (same shape as
  `/fixtures/date/{date}`); an item that does not normalize is skipped, never
  invented. The first controlled run must confirm the shape.
- API-Football has no by-team route in the adapter and the account is
  disabled; Provider Hub refuses GOAL (PRIMARY). Neither is used.

## Flow

1. `/v1/entity?type=team` calls `futbeat_request_team_matches(team)`.
   `/v1/team-matches` (bucket `results`, last page) calls it with
   `p_before` = oldest stored result date (history backfill).
2. Missing/stale coverage (or an older window asked for) upserts **one** row
   per canonical team in `team_match_demands` (writes throttled to one a
   minute). Metrics `team_match_demand_created` / `_deduped`.
3. Worker `futbeat-goal-live-sync`, trigger **`team-fixtures-only`** (manual
   only; not in any cron run; no overrides accepted):
   `futbeat_team_fixtures_plan(1)` → for each GOAL identity of the team
   (≤3, most recently seen first) → per page
   `futbeat_reserve_goal_team_fixtures_call` → `GET /teams/{ext}/fixtures`
   (`from`, `to`, `limit=100`, `offset`, ≤3 pages) → global ingest action
   `team-fixtures-ingest`.
4. Ingest reuses the calendar identity path (resolve → discover → normalize)
   and stores through `futbeat_store_calendar_range` with **empty coverage**:
   no calendar day is marked as covered and nothing outside the answer is
   removed. Then `futbeat_complete_team_fixtures` updates the coverage row.
5. `futbeat_read_team_matches` (#152) lists the new matches with no extra
   step; the lifecycle stays `match_read_model`.

## Coverage state (`futbeat_private.team_match_coverage_state`)

| State | Meaning |
|---|---|
| AVAILABLE | fully paged window, fresh (3 days), covering today−180d … today+120d |
| STALE | known window but old, partial or narrower than the target |
| PENDING | a GOAL mapping exists, no usable answer yet (never, in flight, retrying) |
| NO_DATA | GOAL validly answered no fixtures (negative cache, 14 days) |
| UNAVAILABLE | no GOAL mapping: nothing to ask |

The row stores the **exact** window known (`covered_from`, `covered_to`) and
whether it was fully paged (`window_complete`). A page cap reached with more
pages left never marks the window complete and never extends it.

### Failures, partial answers and NO_DATA

- A failed page (404, 500, timeout) closes **only its ledger row**. It never
  changes the team coverage and never releases the batch lease: the worker
  keeps trying the team's other GOAL identities.
- The team outcome is reported once, after every planned identity was
  tried:
  - no successful page → `futbeat_fail_team_fixtures` (backoff: every
    identity 404 → 7 days, 429 → 1 day, else 15 min × 2ⁿ ≤ 1 day). The
    status becomes `FETCH_FAILED` only if nothing was ever known; it is
    never `NO_DATA`.
  - raw items > 0 but none normalized → schema/normalization failure
    (`NORMALIZATION_FAILED`): same backoff path, never `NO_DATA`, never a
    complete window, stored matches untouched.
  - fewer accepted than distinct raw items, a failed identity, a quota stop
    or the page cap → the fixtures are stored, the window is **not**
    complete, retry in 30 minutes.
- **NO_DATA** only when every planned identity answered 200, no pagination
  was cut, there was no normalization failure and the combined answer had
  zero raw items.
- Metrics count canonical matches: `team_match_fixtures_existing` includes
  matches stored before without a GOAL mapping (reused by teams + kickoff).

## Identity and duplicates

- Match identity is the GOAL fixture id (`provider_entities` kind `match`):
  the same fixture from date-ingest and team-ingest, or from two GOAL ids of
  one team, is one canonical match. A known fixture without a GOAL mapping
  (same teams, same kickoff) keeps its id (`fixtureKey`).
- A reschedule updates the same match (same provider id); the calendar merge
  keeps a stored final unless the kickoff moved later.
- Teams/competitions resolve through `futbeat_resolve_global_entities` and
  redirects: aliases converge on the canonical team. Never by name alone.
- Cross-provider linking stays with the existing reconciliation.

## Quota

- Kind `team-fixtures`, class `coverage` (floor 300 vs LIVE 20, results 20,
  user_high 150), own daily cap **60** request units.
- One reservation per provider page, under `lock_provider_quota`; a denial
  stops the run before any call. Failures back the team off (see above) and
  never delete data.

### Estimate

| | Initial window | Refresh |
|---|---|---|
| Per GOAL identity | 1 request (≤100 fixtures ≈ a club's 300 days); max 3 | only when reopened after 3 days |
| 1 team (1–2 identities) | 1–2 requests (max 9) | ≤ 1–2 per 3 days |
| 10 teams | ~10–20 | ≤ ~7/day |
| 100 teams | ~100–200 → the 60/day cap spreads it over 2–4 days | ≤ ~50/day, still under the cap |

History backfill: +1 request per identity per 180-day step, only when a user
reaches the end of Resultados (floor: 3 years back).

## Not included

- No cron (first: merge, controlled deploy, manual `team-fixtures-only`
  run, quota review).
- Priority for the user's national team is not a separate signal yet;
  followed teams and teams with a match in the next 7 days rank first.
