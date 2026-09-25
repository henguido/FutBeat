# GOAL LIVE quota and lifecycle (Issue #111)

## Root cause in code

`futbeat_private.futbeat_reserve_goal_live_call` (last defined in
`20260919174500`) predated the central quota manager: its own reserve
(`remaining <= 20`), a blind fallback (950 total calls when remaining is
unknown) and a fixed LIVE window (kickoff −5 min … +135 min) read from the raw
entity status. LIVE was not part of the central class policy (no `live-goal`
safety cap) and a SCHEDULED match more than 135 minutes past kickoff (late
start, slow provider status, missed ingest, recovery after a quota outage)
stopped driving the LIVE poll even inside `liveMaxHours`. On 24-sep the
effective trigger was the match-detail spend (fixed in #112), which exhausted
the shared budget ~10 h before the reported kickoffs.

## Policy (migration `20260925015446_live_quota_lifecycle.sql`)

- Quota: `quota_decision('goal_api','live-goal','live')`.
  - Reserve = `class_floors.live` (20), the single source of truth.
  - Safety cap `kind_daily_caps['live-goal']` = 400 request units,
    independent of match-detail and background kinds (max cadence is one poll
    per `liveMinIntervalSeconds` = 240 s, i.e. 360 polls/day of usually one
    page each).
  - Unknown remaining: no blind cutoff for LIVE (class `live` is exempt from
    the unknown-budget caps); only its safety cap applies.
- Priority as the budget falls (unchanged floors, one policy row):
  bootstrap/history 600, background planner 400 (`plannerMinRemaining`),
  coverage/user 300, fixtures workflow reserve 350, user_high 150,
  LIVE/results 20.
- Need (`futbeat_private.live_poll_need`): mapped matches with kickoff in
  `[now − liveMaxHours, now + liveWindowLeadMinutes]` and a non-terminal
  canonical status, classified as `live`, `upcoming` or `overdueScheduled`.
  No active match → no reservation.

## Provider request units

A reservation can cover several real requests (pagination). Quota counts
units, not rows:

- The worker records `metadata.providerRequests`: every attempted request,
  the failed one included (LIVE and results-date). Non-paginated kinds and
  old rows have no value and count as 1 (`provider_call_units`; invalid
  values → 1, bounded to 1000, clamped as numeric before the integer cast so
  a huge value never overflows).
- In flight, a LIVE reservation is stored with `providerRequests = pageBudget`:
  every other reserver sees the whole committed budget, not 1. Completion
  merges the real count over it (completion values win), releasing unused
  pages; a failure records the requests spent (≥ 1). No double counting.
- `quota_decision` sums units for kind caps and for the blind (unknown
  remaining) total; the results-date background guard does too (thresholds
  unchanged). `x-ratelimit-remaining` stays the primary truth; units are the
  defence for unknown remaining, safety caps and observability.
- A failed page keeps the `remaining` reported by the provider.

## Paging near the LIVE reserve

- The reservation returns `pageBudget = min(livePageLimit 10, remaining −
  live floor, live-goal cap − units used)` (≥ 1 when allowed).
- The worker also stops as soon as the observed remaining reaches the floor.
- A truncated batch records `paginationTruncated`, `resumeOffset` and the
  requests made; the next poll starts at `resumeOffset` (restarting at 0 once
  if that page is empty). Matches on unread pages are left untouched: nothing
  interprets absence as evidence (stale-overlay pruning is time based).
- results-date is not truncated (a partial date would go through date
  finalization); it only counts real units.

`futbeat_provider_quota_status()` adds `requestUnitsByKind` and
`live.{pollCyclesToday, providerRequestsToday, averagePagesPerPoll,
paginationTruncatedToday, lastProviderRequests}`.

## Overdue SCHEDULED

A SCHEDULED (or PRE_MATCH, DISCOVERED, SUSPENDED, stale LIVE, no status)
match whose kickoff passed and is still inside `liveMaxHours` is
`overdueScheduled`: it keeps the single global `/fixtures/live` poll running
(one call covers every match; never one call per match). The count is stored
on the ledger row and in the metric `live_polls_with_overdue_scheduled`.

## No false LIVE, no stale LIVE

- The clock never changes a status: LIVE/HALFTIME/EXTRA_TIME/PENALTIES/
  terminal states come only from provider evidence (`futbeat_record_live_batch`
  and the read model).
- A batch older than the latest is rejected (`Stale live batch`); an old LIVE
  observation never overrides a stored final in the read model.
- LIVE presentation expires after 15 minutes without fresh evidence; a LIVE
  status past `liveMaxHours` is not live evidence (`match_detail_status`), so
  it leaves the window.
- Multi-provider ready: the need uses the canonical status, so a match LIVE
  via another provider keeps the GOAL poll active and is reconciled
  canonically.

## Production checks after deploy

- `select public.futbeat_live_poll_status();` → `need` (active, live,
  upcoming, overdueScheduled), `quota` (band, floor 20, live-goal cap),
  `lastLiveCall`.
- `select public.futbeat_provider_quota_status();` → `live-goal` calls spread
  over the day, not stopping in the morning.
- `live_polls_with_overdue_scheduled` metric grows when kickoffs are overdue.
- Around kickoff of tracked matches, `live_match_state` gets rows within one
  poll after the provider reports LIVE.
