# Match-detail backlog control (Issue #97)

Generic: every rule depends on match status, kickoff distance, section
coverage and the central quota policy. No league, team, country or date is
special-cased.

## Root cause of the 684 calls

Measured with `backend/bench/detail_backlog_sim.mjs` (local PGlite, simulated
provider, stationary mix: 25 live, 30 pre-match, 80 upcoming, 60 finished
< 6 h, 250 finished < 36 h, 900 history; the worker runs the planner before
each reservation and serves up to 4 per minute, as in production).

Finished GOAL matches stay `FINISHED_PENDING_VERIFICATION` (nothing sets
`VERIFIED`); the simulation mirrors that. Before (main), ample quota, 2
simulated hours:

- 480 calls (the drain limit), 156 useful (a new lineup, statistics or
  events): **0.33 useful per call**;
- **341 calls re-fetched finished matches every 30 minutes**: the "results"
  cadence applied to every pending-verification final in the 36 h / 7 d
  window, uncapped (GOAL never verifies them);
- **138 calls were planner LIVE refreshes** (every mapped live match on the
  5-minute user cadence), only 13 useful;
- the planner ran before every reservation (4x per minute) and queued up to
  4 rows each time: the queue grew to ~160 rows (105 `recent`, 30
  `prematch` never served); user opens waited up to 26 minutes.

This matches production: 684 calls vs 279 matches with any detail (repeat
refreshes), a `recent` backlog of 60, and user opens competing with it.

## Policy

All values live in `provider_quota_policy.freshness`.

| Bucket | Background need (`match_detail_planner_due`) |
|---|---|
| live | lineup missing: every `liveRetryMinutes` (5); otherwise every `plannerLiveRefreshMinutes` (30), only in abundant/normal bands |
| results (pending verification, < `resultsWindowHours` 4 h after kickoff) | results cadence (30 min), at most `plannerMaxResultFetches` (2); afterwards the finished rules apply |
| prematch (< `prematchMinutes`) | lineup missing, every `prematchRetryMinutes` (20), at most `plannerMaxPrematchFetches` (3) |
| upcoming (< 24 h) | first fetch only |
| recent_hot (< 6 h) / recent (< 36 h) / history (< 7 d) | one post-match fetch (`finalFetchAfterMinutes`), then only while a wanted section is UNKNOWN (retry gap by age) or a NO_DATA recheck is due |
| old (> 7 d) | user opens only |

- Per match and phase, background calls per 24 h: pre-match
  `plannerMaxPrematchFetches` (3), LIVE `plannerMaxLiveFetches` (6), finished
  `plannerMaxFetchesPerMatchDay` (4). Phases never eat each other's budget.
- Result verification is a short window with its own phase cap and a 15 %
  budget; planner rows for older pending-verification finals are ordinary
  background work (`coverage` class, shares apply). User opens of such
  matches keep the `results` class.
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
  Planner rows live `plannerRowTtlMinutes` (60) so fairness aging can act.
  Settled matches are excluded in SQL before the candidate limit.
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
- Ledger completion now merges its (non-null) metadata into the
  reservation's, so the bucket/source/class attribution survives completion.
- All single-row state updates carry a WHERE (pg_safeupdate); the detail and
  calendar RPC paths are in the safeupdate checker's call graph.

## After (same simulation, main vs branch)

| Remaining | Build | Calls | Useful | Useful/call | User wait avg/max | Queue |
|---|---|---|---|---|---|---|
| ample | main | 480 | 156 | 0.33 | 2.4 / 26 min | ~160 |
| ample | branch | 480 | 258 | 0.54 | 0.1 / 1 min | 12 |
| 500 | main | 480 | 150 | 0.31 | 1.2 / 17 min | ~160 |
| 500 | branch | 151 | 82 | 0.54 | 0.1 / 1 min | 4 |
| unknown | main | 177 | 130 | 0.73 | 0.2 / 1 min | 4 |
| unknown | branch | 119 | 88 | 0.74 | 0.1 / 1 min | 4 |

(`node backend/bench/detail_backlog_sim.mjs 120 <remaining>`; "main" runs the
same bench against the main migrations. With ample quota both runs are
drain-limited, so calls are equal and usefulness is the difference.)

Expected production volume: background is bounded by the per-bucket budgets
and the central 60 % background share (at most ~540 of the 900 cap on an
abundant day; planner LIVE within its own 225-call bucket; nothing below
`plannerMinRemaining`), instead of saturating the drain with LIVE
refreshes. At the simulated usefulness (≈ 0.5 vs 0.12), the same number of
calls buys about 4x more coverage; on a normal/tight day far fewer calls are
spent.

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
