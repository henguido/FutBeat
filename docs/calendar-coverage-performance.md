# Calendar performance, background prefetch and lineup coverage

Generic by construction: every rule depends on the distance of a match or a
date to "now", on data state (lineup/statistics coverage, cache version) and
on the central quota policy. No league, team, player, country or date is
special-cased.

## Request path (never the provider)

```
mobile memory (LRU 64) -> mobile disk (Drift) -> /v1/calendar
  -> futbeat_read_calendar_range: compact_calendar_cache (version + TTL)
  -> build_compact_calendar only on a miss (one build per date/timezone, lock)
```

Background work keeps the snapshots ready:

- `futbeat_warm_calendar_window` (worker demand lane, every minute): today,
  +1, -1, +2, -2, ... inside `calendarWarmBackDays`/`calendarWarmForwardDays`,
  at most `calendarWarmBatch` builds per call, for the timezones readers used
  in the last day. DB-only.
- `global-fixtures` workflow: provider fixtures for today +2..+7 on every run
  (bounded), on top of the existing ±1 hot pass and the 09 UTC expansion.

## Temporal policy (all TTLs in `provider_quota_policy.freshness`)

| Profile | Calendar snapshot | Lineup/detail planner |
|---|---|---|
| LIVE / imminent (±kickoff window) | `calendarLiveSeconds` (15 s) + version bump on any change | bucket 1, retry `liveRetryMinutes` |
| Pre-match (`prematchMinutes`, 90) | today rules | bucket 2 (`prematch` source, user_high class) |
| Today (touching UTC today) | `calendarTodaySeconds` (60 s), versioned | — |
| Recent finished (`recentFinishedHours`, 36) | past rules | bucket 4 (`recent`, coverage class) |
| Upcoming (`upcomingDetailHours`, 24) | `calendarFutureHours` (6 h), versioned | bucket 5, one first fetch only |
| History (`historyCoverageDays`, 7) | 1 day if complete, else `calendarHistoryIncompleteMinutes` | bucket 7, `historyRetryHours`; empty twice -> NO_DATA |
| Far future | 6 h, versioned | never polled |

Data changes bump the per-UTC-date revision (`calendar_cache_versions`), so a
TTL only covers clock-driven transitions. Frozen history (lineup and
statistics AVAILABLE/NO_DATA) costs 0 calls.

## Mobile

`CalendarCachePolicy` (providers.dart) centralizes client TTLs (today 20 s,
past 5 min, future 10 min, partial/stale 20 s), the prefetch radius (2) and the
window (today -2..+7).

- Cached day painted first (memory peek in the same frame, then disk).
- Network response shown before the disk write finishes.
- Neighbours prefetched sequentially D+1, D-1, D+2, D-2 after the visible day
  resolves; a newer visible date supersedes the chain; expired days are
  refetched, not only missing ones; no cascade outside the window.
- One shared request per date; a closed screen stops waiting but only cancels
  the request when no other waiter (e.g. a prefetch) remains.
- Loading only without any snapshot, or while an empty cached day
  revalidates (no false "Sin partidos").

## Measurements (local PGlite, 12 000 matches, `node backend/bench/calendar_latency.mjs`)

| Path | Median |
|---|---|
| Before: today/yesterday rebuilt on every request | 115 ms / 99 ms (≈300 ms on the richer fixture) |
| After: first read of a day (build + store) | 132 ms, once per version |
| After: cached read (today, yesterday, past, future) | 15.5–15.8 ms |
| Warmer, 3 missing days / window already warm | 389 ms / 15 ms |
| Future day TTL | before 10 s, after up to 6 h (bounded by day start) |

Cached lookup plan: index scan on `compact_calendar_cache_pkey`, execution
0.2 ms. Remote latency is dominated by the edge function and network; not
measured here (no production access in this block).

## Quota

Match detail runs under the class floors of the central quota manager
(`live` > `user_high` > `coverage` > `bootstrap`), daily kind cap 900. With an
unknown provider remaining, background classes are limited to a share of the
blind budget; LIVE and results are not. Dev limits (24 detail / 16 squad) are
not used.

## Deploy order

1. Migrations `20260923200000_match_detail_coverage_planner.sql`,
   `20260923210000_calendar_snapshot_cache.sql`.
2. Worker `futbeat-goal-live-sync` (calendar warm lane).
3. Workflow change is picked up on merge.
4. Mobile build.

## Risks

- A team/competition change bumps the global catalog version: every day is
  rebuilt lazily on next read/warm (not eagerly).
- Whether GOAL bulk live/results payloads carry lineups is unverified; the
  promotion trigger is a no-op when they do not.
- Warm timezones are inferred from recent readers; a new timezone gets its
  first day built on demand.
