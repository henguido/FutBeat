# Provider Hub — Phase 1B (#102)

Selective secondary worker, **activation-ready but disabled**. API-Football's
account is currently suspended (`errors.access`: "Your account is suspended…")
so nothing here enables it, calls it or schedules it.

**Activation is NOT part of this PR.**

## Roles

- GOAL is the PRIMARY LIVE provider through `futbeat-goal-live-sync` and the
  central quota manager — unchanged.
- API-Football is SECONDARY and **disabled** (`provider_hub_config.enabled=false`).
- Sportmonks is INTEGRATION-only and never executable by the worker.

## Worker: `futbeat-provider-hub-sync`

The only secondary-provider execution path. It supersedes the legacy,
unscheduled `futbeat-live-sync` / `futbeat-fixtures-sync` (marked DEPRECATED;
removal is a separate cleanup).

- Internal only: `verify_jwt = false` (same pattern as
  `futbeat-goal-live-sync`, invoked without a user JWT) and every request must
  carry the stored `x-futbeat-cron-token` (constant-time comparison). POST
  only, ≤ 2 KB body, strict fields:

  ```json
  {"provider":"api_football","reason":"CONTROLLED_COMPARISON",
   "dataType":"live|events|fixtures|match_detail","matchId":"fb_match_…","dryRun":true}
  ```

  Only `api_football` is executable. No force mode, no cron, no workflow.
- Logic lives in `backend/providers/hub_worker.mjs` (tested in node); the
  Edge Function is a thin wrapper.

### Order of operations

1. Validate the body.
2. Read-only `futbeat_provider_hub_status` + `futbeat_provider_hub_preview`
   (config, hub quota decision, canonical match, strict mapping).
3. `routeWork` (`backend/providers/core/routing.mjs`): accepted reasons
   `HIGH_INTEREST_LIVE`, `PRIMARY_STALE`, `PRIMARY_INCOMPLETE`,
   `FINAL_RECONCILIATION`, `COVERAGE_GAP`, `CONTROLLED_COMPARISON`.
   `BASE_LIVE` never selects API-Football. Disabled, unhealthy
   (UNAVAILABLE/DEGRADED) or out-of-quota → skipped.
4. Identity: the canonical match must have an `api_football/match` mapping
   (`futbeat_bind_provider_entity` EXPLICIT_VERIFIED, or a unique
   `futbeat_match_provider_fixture` MATCHED). UNMAPPED / AMBIGUOUS → no call.
   Never searches by display names.
5. **dryRun (default)** stops here: returns the plan
   (`/fixtures?id=<external>`, 1 unit). Zero provider HTTP, zero ledger, zero
   writes. It works with the real config (`enabled=false`): routing is also
   evaluated read-only *as if enabled* (`routing.ifEnabled`, using
   `healthIfEnabled` and the quota counters), and the response says
   `providerEnabled:false`, `executionBlockedBy:"DISABLED"`. Every other gate
   (reason, health, quota, mapping) still applies. `dryRun:false` stays
   refused (`skipped`/`DISABLED`) while disabled.
6. Execution (`dryRun:false`): secret present (existing backend secret
   `FUTBEAT_API_FOOTBALL_KEY`, never returned) → **persistent reservation**
   `futbeat_reserve_provider_hub_call` (100/day, 10/min total; still refused
   while disabled) → **one** exact call `fetchFixture({fixtureId})` →
   normalization → player resolution → event dedup → secondary observation
   → ledger completion.

The ledger row becomes `SUCCEEDED` only after the secondary observation is
recorded. A failure after the fetch completes it `FAILED` with a
deterministic code (`API_FOOTBALL_INVALID_PAYLOAD` for normalization,
`PROVIDER_HUB_INGEST_FAILED` with `metadata.stage` =
`resolve_players|reconcile_events|record_observation` otherwise), keeping HTTP
status, `x-ratelimit-requests-remaining` and duration; never raw error text,
never left `RESERVED`, never retried.

No retries and no loops: every invocation makes at most one provider request.

### Exact-fixture strategy

`GET /fixtures?id=<id>` returns the fixture with its events in one request.
No `fixtures?live=all`, no date sweeps: with 100 requests/day, only exact,
mapped fixtures are worth a call.

### Error classification (`classifyApiFootballError`)

| Case | Code | Health effect |
|---|---|---|
| `errors.access` mentions a suspended account (HTTP 200) | `API_FOOTBALL_ACCOUNT_SUSPENDED` | UNAVAILABLE |
| 401 / 403 / `errors.token` / other `errors.access` | `API_FOOTBALL_AUTH` | UNAVAILABLE |
| 429 / `errors.requests` / `errors.rateLimit` | `API_FOOTBALL_RATE_LIMITED` | counts as failure |
| 5xx | `API_FOOTBALL_HTTP_5XX` | counts as failure |
| timeout / network | `API_FOOTBALL_TIMEOUT` / `API_FOOTBALL_NETWORK` | counts as failure |
| wrong/missing fixture in a 2xx | `API_FOOTBALL_INVALID_PAYLOAD` | counts as failure |

The ledger row is completed `FAILED` with the HTTP status, the code, the
latency and `x-ratelimit-requests-remaining` when known; never the key. An
UNAVAILABLE provider is rejected by routing, so the next invocation makes no
call until a human fixes the account and a new successful probe is recorded.

### Reconciliation precedence (`futbeat_record_secondary_observation`)

Secondary observations go to `provider_secondary_observations`, which the
read model never reads (it reads `provider_observations` of any provider, so
writing there directly would let a secondary override GOAL).

1. The observation must belong to the strictly mapped canonical match.
2. Only a terminal secondary status with a complete score can be applied;
   LIVE/scheduled/partial evidence is stored only (no LIVE reconciliation in
   1B; never final by clock).
3. GOAL terminal evidence with a complete score is authoritative: equal →
   `CONFIRMED`, different → `CONFLICT` (nothing written).
4. GOAL evidence newer than the secondary observation → `SUPERSEDED`.
5. Otherwise → `APPLIED_FINAL`: one `provider_observations` row carries the
   terminal evidence; the existing read-model rules decide the display.

### Events

API-Football events are mapped to canonical ids (team by fixture side;
player only through a verified `api_football/player` mapping, otherwise
null — never created by name) and deduplicated against GOAL's canonical
events with `dedupeCanonicalEvents`. Provider event ids are provenance. The
result (confirmed-by-both, secondary-only) is stored with the observation;
nothing is written to `canonical_events` in 1B (that table feeds push).

## Activation checklist (later, not in this PR)

1. API-Football account no longer suspended.
2. Valid backend secret `FUTBEAT_API_FOOTBALL_KEY` present (Supabase secrets).
3. One controlled account probe succeeds (manual, one request).
4. `x-ratelimit-requests-remaining` captured in the ledger.
5. Verified competition/team mappings (`futbeat_bind_provider_entity`).
6. A controlled fixture `MATCHED` (`futbeat_match_provider_fixture`).
7. A controlled comparison run (`dryRun:false`, `CONTROLLED_COMPARISON`)
   succeeds and its reconciliation is reviewed.
8. Only then `enabled=true` for `api_football` (reviewed migration or ops
   change), still without any cron.
