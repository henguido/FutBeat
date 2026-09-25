# Provider Hub — Phase 1A (#102)

Foundation only. **No secondary provider is active**: nothing schedules
API-Football or Sportmonks, and every hub reservation for them is refused.

| Provider | Role | Enabled | Daily budget | Notes |
|---|---|---|---|---|
| `goal_api` | PRIMARY | yes | — (central quota manager) | LIVE base, unchanged worker |
| `api_football` | SECONDARY | no | 100 (+10/min) | `developmentOnly=true` |
| `sportmonks` | INTEGRATION | no | none | cannot be enabled without a budget |

## Pieces

- **Config**: `futbeat_private.provider_hub_config` (migration
  `20260925070000_provider_hub_phase1a.sql`). A non-primary provider cannot be
  enabled without `daily_budget` (CHECK constraint).
- **Quota**: one ledger (`provider_call_ledger`), one lock
  (`lock_provider_quota`). `futbeat_reserve_provider_hub_call` enforces the
  provider's **total** daily budget in request units across every call kind
  (and the minute budget), so per-kind caps can never add up past 100. GOAL
  keeps `provider_quota_policy` / `quota_decision` untouched; the hub refuses
  to reserve for a PRIMARY provider. `RequestBudget` stays as the adapter's
  local defence (it resets with the process, so it is never the only guard).
- **Health** (`futbeat_provider_hub_status()`, service-only; mirrored by
  `providerHealth()` in `backend/providers/core/hub.mjs`), last 24 h of the
  ledger:
  - `DISABLED`: enabled=false
  - `UNSEEN`: no completed call
  - `UNAVAILABLE`: last completion failed with 401/403, or last 3 failed
  - `DEGRADED`: failures ≥ 20 %, or p95 latency ≥ 10 s
  - `HEALTHY`: otherwise
  Latency = `completed_at − reserved_at`. The status never returns keys,
  tokens or headers.
- **Routing** (`backend/providers/core/routing.mjs`, pure): reasons
  `BASE_LIVE`, `HIGH_INTEREST_LIVE`, `PRIMARY_STALE`, `PRIMARY_INCOMPLETE`,
  `FINAL_RECONCILIATION`, `COVERAGE_GAP`, `CONTROLLED_COMPARISON`. GOAL is
  always first and the only candidate for `BASE_LIVE` (never dropped for
  health). A SECONDARY is only an extra candidate for the other reasons, and
  only when enabled, capable, HEALTHY/UNSEEN and within quota. INTEGRATION is
  never operational. Interest comes from `backend/interest/strategy.mjs`
  (`dataPriority`): temporary Match Center interest raises
  match_detail/lineups/statistics/events; it never removes base LIVE coverage.
- **Identity** (strict, new providers only): a provider external id maps to a
  canonical id through an existing mapping, `futbeat_bind_provider_entity`
  with `EXPLICIT_VERIFIED` evidence (verifier required), or — matches only —
  `futbeat_match_provider_fixture`. Names are never sufficient; mappings are
  never overwritten (`CONFLICT`). The legacy name-matching
  `futbeat_resolve_global_entity` is not extended to these providers.
- **Fixture matching** (`matchFixture` / `futbeat_match_provider_fixture`):
  same canonical competition + home + away (no swap unless the provider gives
  evidence), kickoff within `kickoff_tolerance_minutes` (10), season/round
  reject only on a clear contradiction. `MATCHED` binds the provider match
  id; `AMBIGUOUS`/`UNMAPPED` publish nothing and leave a private diagnostic
  (`provider_fixture_diagnostics`). No duplicate fixture is ever created.
- **Event dedup** (`matchCanonicalEvent` / `dedupeCanonicalEvents`): same
  canonical match and type, effective minute (`minute + extra`) within 1, no
  contradiction on team / players (in/out for substitutions) / score after a
  goal, and at least one positive corroboration (same team, player(s) or
  score-after). Provider event ids are provenance only. Observations of the
  same provider are never merged.
- **Sportmonks adapter** (`backend/providers/sportmonks.mjs`): API v3,
  token in the `Authorization` header (never in the URL), injected budget
  (no invented limit), timeout, sanitized errors. Methods:
  `fetchFixturesByDate`, `fetchLivescores` (in-play), `fetchFixture` with an
  include allow-list. Capabilities declared: fixtures, liveScores, events.
  Normalization: fixture/competition/season/stage/round ids, kickoff, state →
  FutBeat status (unknown states rejected, never guessed), participants,
  current score (both sides only), ticking minute, venue, basic events with
  provenance and score-after. Event type ids and substitution roles are
  UNVERIFIED against a real response.

## What Phase 1B needs to activate API-Football

1. Real key as a Supabase secret (never in the repo or the app).
2. A worker path that: routes with `routeWork`, reserves with
   `futbeat_reserve_provider_hub_call`, calls the adapter, completes the
   ledger row (`futbeat_complete_provider_call`, with the provider remaining
   header), and ingests through strict identity + `futbeat_match_provider_fixture`.
3. Explicit verified bindings for the competitions/teams to cover.
4. Event ingestion through `dedupeCanonicalEvents` before `canonical_events`.
5. Only then `enabled=true` for `api_football` (reviewed), plus a quota
   policy row if its own floors are wanted.
6. Decide the fate of the legacy, unscheduled `futbeat-live-sync` /
   `futbeat-fixtures-sync` edge functions.
