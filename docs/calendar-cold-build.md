# Calendar cold build, materialization and terminal loading states

Generic: every rule depends on date distance, data state and central policy
(`provider_quota_policy.freshness`). No date, month, competition, country or
team is special-cased.

## Measured bottleneck

`backend/bench/calendar_cold_build.mjs` seeds one day per size with realistic
child rows (30 observations with raw payloads, 10 canonical events, a ~30 KB
stored detail for 70 % of matches, live state, team redirects) in a fresh
PGlite database, and times the previous builder (verbatim from its migration)
against the current one on the same data.

| Matches | Before | After | Same payload | JSON | Cached read |
|---|---|---|---|---|---|
| 50 | 42 ms | 16 ms | yes | 17 KB | ~21 ms |
| 200 | 140 ms | 50 ms | yes | 68 KB | ~18 ms |
| 1 000 | 785 ms | 323 ms | yes | 349 KB | ~23 ms |
| 1 500 | 1 312 ms | 494 ms | yes | 526 KB | ~26 ms |
| 1 000, 40 events/match | 1 611 ms | 306 ms | yes | 349 KB | ~26 ms |

Stage breakdown (1 000 matches): raw rows 2 ms; redirect resolution
~150 ms (run twice before); `match_read_model` ~600 ms, dominated by building
and normalizing the full events array of every match (payload events +
canonical events, `normalize_event_minutes` per event). Observations and
detail size barely move the cost; events per match do (10 -> 40 events:
0.87 s -> 1.54 s before, flat after). The list only needs `latestEvent` for
live matches and "has any event".

Fix: `match_read_model_core(p_match, p_events)` is the single source of
truth; the list build skips the events aggregation except for live matches
and answers "has any event" with an EXISTS; redirects are resolved once. The
Match Center keeps `match_read_model` (full). The payload is byte-identical
(benchmark and tests compare against the previous builder).

Production measured 12.3 s for 1 084 matches; local PGlite is faster in
absolute terms, so the ratio (2.4-5.3x) is the portable result. Either way
the visible request no longer waits for a heavy build (below).

Payload: 1 084 matches parse in ~21 ms in Dart (232 KB synthetic); the list
JSON already carries only the fields the Partidos screen uses.

## Materialization

```
fixture/result/detail/redirect ingest
  -> invalidate trigger -> bump_calendar_date(utc date)
  -> mark_calendar_dirty: local dates (reader timezones) intersecting it
  -> calendar_snapshot_queue (date, timezone) pending, priority 5
worker lane each minute (futbeat_warm_calendar_window, DB-only):
  enqueue hot window (2 today, 3 +/-1, 4 window), seed known dates
  without a snapshot (6, -90..+120 days), drain queue within
  calendarBuildBatch / calendarBuildBudgetMs
```

Queue: one row per (date, timezone); an enqueue only writes on a
state/priority transition, so 100 changes of a date are one row and one
build. `for update skip locked`, lease, attempts and exponential backoff (max
1 h, `failed` after 5). No provider calls.

Read path (`futbeat_read_calendar_range`):

- valid snapshot -> returned (~0.2 ms lookup);
- day with at most `calendarSyncBuildMaxMatches` (150) -> built inline (fast);
- large day with a stale snapshot -> stale payload now (`revalidating`) +
  priority-1 rebuild + worker wake;
- large day without a snapshot -> `coverage.pending=true` with
  `retryAfterSeconds` + priority-1 build + worker wake (debounced). The
  request returns in milliseconds.

TTLs: complete history `calendarHistoryCompleteDays` (30 d, versioned by new
evidence), incomplete history 10 min, future `calendarFutureHours` (24 h,
versioned by fixture changes, re-evaluated when the day reaches UTC today),
UTC-today days 60 s / 15 s live (unversioned by design).

## Flutter terminal states

`CalendarCachePolicy`: `visibleDeadline` 25 s, `maxAttempts` 3, pending poll
2-8 s (server hint, doubled), revalidation 30 s doubled per failure up to
5 min.

- cache -> shown at once; refresh failures keep it (marked stale);
- no cache -> loading -> data, or an error with Retry at the deadline;
- server "pending" -> "Preparando los partidos…", polled within the deadline;
  never cached;
- a date that never got data is not restarted on a timer, and Riverpod's
  automatic provider retry is disabled for the calendar (it restarted failed
  dates forever);
- leaving a date cancels its wait; the shared request survives for others.

## Deploy order

1. Migration `20260924100000_calendar_snapshot_materialization.sql`.
2. No edge-function change is required (the worker already calls the lane;
   the API passes `coverage.pending` through).
3. Mobile build.

## Risks

- Production absolute timings can differ from PGlite; watch
  `futbeat_calendar_snapshot_status()` and the metrics
  `calendar_snapshot_builds`, `calendar_pending_responses`,
  `calendar_stale_served`, `calendar_snapshot_build_failures`.
- The worker lane runs its builds in one transaction; date locks are held
  until it commits (bounded by batch and time budget).
- UTC-date granularity: a change dirties the (usually two) local dates that
  intersect its UTC date.
