# Match Center standings lifecycle (Issue #98)

## Root cause

- The standings demand lane (`futbeat_reserve_goal_standings_call`, demand
  mode) only selected `QUEUED` demands with
  `requested_at > now() - demandWindowMinutes` (30 min). A demand recorded
  while GOAL was below the `user_high` floor aged out of that window: once
  quota came back nothing reserved it, and `match_standings_state()` kept
  reporting it as pending (seen on 24-sep after the quota exhaustion).
- `MatchScreen` only created the **Tabla** tab when rows already existed, so
  pending / NO_DATA / missing tables had no tab and no explanation.

## Queue (migration `20260925030000_standings_demand_lifecycle.sql`)

- Identity stays exactly `(competition_id, season_key)`; `normalize_season`
  is format-only. Never another season, a same-name competition, the latest
  table or an editorial fallback.
- Durable: a `QUEUED` demand is eligible whatever its age while its lease
  expired, `next_retry_at` allows it, its season is the competition's current
  one and `quota_decision('goal_api','standings','user_high')` allows.
- `queued_at` = when the demand (re)entered `QUEUED`; deduplicated opens bump
  `requested_at` and `request_count` only.
- Fairness: lane `recent` (queued < `standingsDemandAgingMinutes`, newest
  request first) and lane `aged` (oldest `queued_at` first). Consecutive user
  reservations alternate lanes when both have work (lane stored on the ledger
  row), so fresh opens stay responsive and aged demands progress FIFO.
- Before any spend, `reconcile_standings_demands()` marks `AVAILABLE` the
  demands already answered by a **fresh** exact snapshot (a stale snapshot
  never satisfies its own revalidation) and closes as `NO_DATA` the demands
  whose season is no longer current (never fetchable).
- Provider mapping is revalidated at reservation time through
  `standings_provider_league_id` (canonical competition + aliases redirected
  to it, never by name). A changed mapping updates the same demand and the
  reservation uses the current id; a removed mapping closes the demand as
  `NO_DATA` (`provider mapping unavailable`, retry after
  `standingsUnmappedRetryMinutes`) with no provider call and no pending.
- Completion: exact season stored → `AVAILABLE`; answered without that season
  or 404 → `NO_DATA` for `standingsNoDataDays`; transient failure → back to
  `QUEUED` with exponential backoff, `FETCH_FAILED` after
  `standingsMaxAutoRetries`. Reopening never requeues before `next_retry_at`.

## State (`coverage` in `futbeat_read_match_context`, schemaVersion 1)

| `standings`   | meaning                                             |
|---------------|-----------------------------------------------------|
| `available`   | exact table sent (may be `standingsStale`, and `standingsPending` while revalidating) |
| `pending`     | no table yet, fetchable demand queued/leased         |
| `unavailable` | provider has no table (NO_DATA / FETCH_FAILED backoff) |
| `missing`     | no season/competition, not mapped or historical season |

## Mobile

- Tabla is always the 4th tab (one TabController, no tab jumps).
- Rows → table (a stale table stays, with "Actualizando tabla…" while the
  bounded refresh runs). Pending → "Cargando tabla…" during the 8/20/40 s
  refreshes, then "Tabla aún no disponible" + **Reintentar** (one in-place
  read, deduplicated server-side), plus two silent revalidations at +90 s
  and +180 s so a durable demand answered later still appears in place.
  Finite: 5 automatic reads at most; stops as soon as nothing is pending.
- Unavailable (NO_DATA negative cache) / missing → "Sin tabla disponible",
  no polling and no retry action.

## Production checks

- `select status,count(*),min(queued_at) from futbeat_private.standings_demands group by 1;`
  → no `QUEUED` row older than a few cron cycles while quota allows.
- `demand_metrics`: `standings_demands_reconciled`,
  `standings_demands_season_closed`, `standings_season_mismatch`.
