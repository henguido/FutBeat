# Historical Match Center loading (Issue #101)

Reads are already fast (9–18 ms in production) and GOAL answers in ~1 s once
reserved. The latency came from the phone never asking, asking twice, or
rechecking late, and from settled history not staying frozen.

## Semantics

- `available` = something persisted is displayable (detail cache row **or** a
  provider observation). It is not "complete".
- `hydrationNeeded` (top level and `coverage.hydrationNeeded`, from
  `match_detail_completeness`) = fetchable (GOAL-mapped, within
  `historyHorizonDays`, default 90) **and** `match_detail_needs_fetch` **and**
  nothing queued or in flight. Single server-side source of truth.
- `pending` = a fetch is queued or in flight.

## Flow

- Before: `readMatchDetail(request=0)` → if `available` stop (partial history
  never hydrated) → else `/v1/match-detail` (second round trip).
- After: first open in the session = **one** request-aware
  `/v1/match-detail?id=` (server returns persisted data at once, enqueues a
  deduplicated demand only if needed, never waits for GOAL). Re-entries are
  read-only unless the server says `hydrationNeeded`.
- Rechecks (read-only, never a provider call): 2, 4, 8, 15, 30 s (was 5, 10,
  20, 40 s), then a stable state. The session memory still paints first.

## Frozen history

- GOAL finals stay `FINISHED_PENDING_VERIFICATION`; the 30-minute FPV clock
  cadence now only applies inside `resultsWindowHours` after kickoff. After
  that, lineup/statistics `AVAILABLE` or `NO_DATA` = frozen (0 calls).
- A user open of an older FPV final is `user` demand (it borrowed the
  protected `results` class before). Planner logic is unchanged; nothing
  pre-fetches history; >90 days never calls the provider.

## Measuring

- `select public.futbeat_historical_match_center_metrics();` (service only):
  `coverageByAge` (matches / withScore / withEvents / withObservation /
  withDetail / settled per 1-3d, 3-7d, 7-30d, 30-90d, >90d),
  `historyOpensToday` (warm, refresh, partial, cold, backoff,
  out_of_horizon; sharded `demand_metrics` counters),
  `hydrationSecondsToday` (avg / p95 / max per history vs recent, from
  `provider_call_ledger`).
- Local benchmark: `node --test backend/test/historical_match_center.test.mjs`
  prints warm read, cold persisted read, request/enqueue and simulated
  provider completion timings.
