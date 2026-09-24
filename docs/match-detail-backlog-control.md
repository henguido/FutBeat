# Match-detail backlog control (Issue #97)

Generic: every rule depends on match status, kickoff distance, section
coverage and the central quota policy. No league, team, country or date is
special-cased.

## Root cause of the 684 calls

Measured with `backend/bench/detail_backlog_sim.mjs` (local PGlite, simulated
provider, stationary mix: 25 live, 30 pre-match, 80 upcoming, 60 finished
< 6 h, 250 finished < 36 h, 900 history; the worker runs the planner before
each reservation and serves up to 4 per minute, as in production).

Before, with ample quota, over 2 simulated hours:

- 480 calls, 57 useful (a new lineup, statistics or events): **0.12 useful
  per call**;
- **446 of 480 calls (93 %) were planner LIVE refreshes** (every mapped live
  match on the 5-minute user cadence); only 24 added anything;
- the planner ran before every reservation (4x per minute) and queued up to
  4 rows each time, while at most 4 were drained: the queue grew to 105
  `recent` + 30 `prematch` rows that were never served (LIVE outranked them);
- with an unknown remaining the blind budget ran out and user opens waited.

This matches production: calls concentrate on repeated refreshes of the same
matches (684 calls vs 279 matches with any detail), and a `recent` backlog
builds up that the drain never reaches.

## Policy

All values live in `provider_quota_policy.freshness`.

| Bucket | Background need (`match_detail_planner_due`) |
|---|---|
| live | lineup missing: every `liveRetryMinutes` (5); otherwise every `plannerLiveRefreshMinutes` (30), only in abundant/normal bands |
| results (pending verification) | results cadence (30 min) |
| prematch (< `prematchMinutes`) | lineup missing, every `prematchRetryMinutes` (20), at most `plannerMaxPrematchFetches` (3) |
| upcoming (< 24 h) | first fetch only |
| recent_hot (< 6 h) / recent (< 36 h) / history (< 7 d) | one post-match fetch (`finalFetchAfterMinutes`), then only while a wanted section is UNKNOWN (retry gap by age) or a NO_DATA recheck is due |
| old (> 7 d) | user opens only |

- Per match and phase: at most `plannerMaxFetchesPerMatchDay` (4) background
  calls per 24 h.
- Complete matches (both sections AVAILABLE or NO_DATA) cost 0 calls.
- User opens keep the full freshness rules (`match_detail_needs_fetch`) and
  promote a queued planner row in place (one row, no parallel work).

### Admission control

- The planner runs at most once per `plannerMinIntervalSeconds` (50) from the
  worker entry.
- Background depth ≥ `plannerQueueHighWater` (12) pauses background
  admission until it falls to `plannerQueueLowWater` (4). LIVE and results
  are always admitted; user opens never pass through the planner.
- Stale rows (expired, no longer due, unmapped) are dropped before planning.
  A served planner row leaves the queue once its detail is stored; a failed
  call keeps it for its retry (with backoff).

### Adaptive batch and quota

| Provider band (quota manager) | Background batch | History | Recent/upcoming |
|---|---|---|---|
| abundant (> 600) | 4 | yes | yes |
| normal (> 300) | 2 | no | yes |
| tight (> 150) | 1 | no | no |
| critical | 0 | no | no |
| unknown | 1 | no | yes |

- All background work except result verification stops at
  `plannerMinRemaining` (400), above the `user` floor (300), so user opens
  keep a reserve of their own.
- Per-bucket daily budgets (`detailShare*`, fractions of the blind-aware
  match-detail cap): live 25 %, recent 25 %, prematch 15 %, results 15 %,
  history 8 %, upcoming 3 %. The central shares (background ≤ 60 %,
  planner LIVE ≤ 85 %) and the 900 cap still apply.
- Drain order: aged user opens, LIVE, results, pre-match, user, then
  background with fairness aging (`fairnessAgingMinutes`), never above a
  user open; equal ranks drain oldest first.

### Negative cache

`match_detail_coverage` now keeps, per section: `*_empty_first_at`,
`*_empty_last_at`, `*_recheck_at`, `*_no_data_reason`, plus `last_bucket`
(provenance). NO_DATA needs two spaced empty answers after the match
finished (pre-match/LIVE emptiness never becomes NO_DATA). Recheck after
`noDataRecheckRecentHours` (12 h) for matches < 36 h old, else
`noDataRecheckHistoryDays` (30 d). States: UNKNOWN, AVAILABLE, NO_DATA;
PENDING is derived (open request or in-flight call), as Match Center reports.

## Metrics and audit

- `md_calls_<bucket>`, `md_useful_<bucket>`, `md_empty_<bucket>`,
  `md_lineup_gained`, `md_statistics_gained`, `md_events_gained`,
  `md_no_data_transitions` (demand_metrics, daily).
- `match_detail_queue_log` (enqueued / dropped / reserved / useful / empty),
  pruned after 2 days.
- `public.futbeat_match_detail_backlog_audit()` (service role): queue by
  source and bucket, eligible vs no longer needed, AVAILABLE/NO_DATA,
  backoff, detail, unmapped, in-flight, oldest age by source; calls today by
  bucket and source, distinct matches and repeat calls (answers the 684
  question on real data); useful coverage per call; enqueue/reserve/drop
  rates for the last hour and `backlogGrowing`.
- Ledger completion now merges its metadata into the reservation's, so the
  bucket/source/class attribution survives completion.

## After (same simulation)

| Remaining | Calls | Useful | Useful/call | User opens waiting |
|---|---|---|---|---|
| ample, before | 480 | 57 | 0.12 | 0 |
| ample, after | 457 | 233 | 0.51 | 4 (served next minute) |
| 500, after | 130 | 66 | 0.51 | 0 |
| unknown, before | 150 | 51 | 0.34 | 4 |
| unknown, after | 113 | 82 | 0.73 | 0 |

Queue: before ~160 background rows after 2 h (growing); after 2-10.

Expected production volume: background is bounded by the per-bucket budgets
(≈ 90 % of 900 at most on an abundant day, much less in normal/tight bands)
instead of saturating the drain with LIVE refreshes; at the simulated
usefulness (≈ 0.5), a full day yields roughly 3-4x more useful coverage per
call than before.

## Risks

- Below the existing `user` floor (300) historical user opens wait by the
  quota manager's design (not changed here); LIVE opens are still served.
- The usefulness metric counts section availability and more events, not
  changing live statistic values (live refresh value is only for viewers,
  who use the user cadence).
- Simulation mix and provider truth are synthetic; the audit function gives
  the real breakdown after deploy.

## Deploy order

Migration `20260924200000_match_detail_backlog_control.sql` only (the worker
already calls the same RPCs).
