# Real data on demand

FutBeat no longer depends only on what was stored beforehand. When a user
searches for a player, opens a player or opens a match, that demand can
enrich the central catalog. Enrichment is safe, cached and deduplicated.

The mobile app **never** calls GOAL. Every provider call runs server-side in
the GOAL worker (`futbeat-goal-live-sync`). The central quota manager decides
each call.

## Flow

```
app ── GET /v1/search | /v1/entity?type=player | /v1/match-detail ──► futbeat-api (service role)
          │ local/cached answer immediately (+ pendingRemote / enrichmentPending / pending)
          ▼
   demand row (deduplicated) ──► wake_provider_worker('demand')  [pg_net, debounced 15 s, token from Vault]
                                          │
                                          ▼
   GOAL worker trigger "demand" (also every minute via the existing detail cron)
     1. match detail   reserve_match_detail_call  → /fixtures/:id          → store_match_detail
     2. players        futbeat_reserve_player_call → /players/search?q=     → store_player_search_result
                                                     /players/:id            → store_player_profile
                                                     /players/:id/statistics → store_player_stats
```

## Player search

- The local search always runs first.
- A demand is recorded only when no player matches the query as a whole word
  (or through a multi-word typo match), no team or competition matches it well,
  and the query has at least 3 useful characters.
- There is one row per normalized query (`player_search_demands.query_key`),
  so 1000 users searching the same name cost at most one call.
- States: `QUEUED` (lease 10 min), then `AVAILABLE` (cached 7 days) or
  `NO_DATA` (negative cache 3 days, also used for HTTP 404) or `FETCH_FAILED`
  (backoff 15 min·2ⁿ up to 1 day; 429 waits 1 h).
- Found players are canonicalized by provider id (never by name) and become
  searchable through the existing index trigger. Only received fields are
  stored.

## Player profile

- `futbeat_request_player_profile` is called when a player is opened. It is
  deduplicated: repeat opens within 1 minute, or while a lease is active,
  count as deduped.
- The profile is due when it has never been hydrated and is poor (missing
  birth date, country, position, height or photo), or when it is older than
  30 days.
- Season statistics are due every 12 h. They are skipped while a fresh squad
  already carries this season's numbers.
- Partial responses never erase valid data. Squads keep ownership of team,
  position and shirt number. Season statistics are stored under
  `seasonStats`.

## Match detail

- A fresh cached detail is a cache hit and makes no call.
- A missing or stale detail creates one user demand per match (`source='user'`)
  and wakes the worker. A match already queued or in flight is only counted as
  deduped.
- Reservation order:

  | Order | Case | Quota class |
  | --- | --- | --- |
  | 1 | LIVE match opened by a user | live |
  | 2 | LIVE match queued by the system, or results | live / results |
  | 3 | Upcoming match opened by a user | user_high |
  | 4 | Historical match opened by a user (no detail) | user |
  | 5 | Editorial prefetch | coverage |
  | 6 | Background / bootstrap | bootstrap |

- Pre-kickoff prefetch (the enqueuer) is unchanged.

## Quota manager (`futbeat_private.provider_quota_policy`, one row per provider)

| remaining (x-ratelimit-remaining) | allowed classes |
| --- | --- |
| > 600 | everything, including bootstrap |
| 300–600 | user demand + priority coverage |
| 150–300 | high-priority user demand + LIVE/results |
| ≤ 150 | LIVE/results only |
| ≤ 20 | nothing (hard reserve) |

- Floors, per-kind safety caps and TTLs are all in that one row:
  `class_floors`, `kind_daily_caps`, `kind_groups` and `freshness`.
- Unknown remaining (no reading yet today) allows every class; the safety caps
  still apply.
- Safety caps per day:

  | Call kind | Cap |
  | --- | --- |
  | match-detail | 400 |
  | team-squad | 150 |
  | player-search | 150 |
  | player-profile | 250 |
  | player-stats | 250 |

- The old development limits (24 detail and 16 squad calls per day) are gone.
- LIVE, results and standings keep their own existing guards.

Diagnostics (service role only):

- `futbeat_provider_quota_status()`
- `futbeat_demand_metrics(p_days)` returns counters plus `providerRemaining`,
  `callsByKind` and `coverageGainedPerProviderCall`. The counters are:
  - player_search_demands, player_search_provider_calls,
    player_search_cache_hits, players_discovered;
  - player_profile_demands, player_profile_cache_hits,
    player_profiles_hydrated;
  - match_detail_user_demands, match_detail_cache_hits;
  - deduped_requests, coverage_gained.

## App contract (schemaVersion 1 unchanged)

- **Search:** `coverage.pendingRemote=true` means discovery was launched. The
  response is sent with no-store and never served from the client cache. The
  app shows "Buscando más jugadores…" and re-queries at 3, 5 and 8 s, then
  stops.
- **Player:** `coverage.enrichmentPending=true` means the profile is being
  hydrated. The response is sent with no-store. The app shows the partial
  profile with "Actualizando datos del jugador…" and refreshes at 6 and 12 s,
  then stops.
- **Match detail:** `pending` works as before (bounded polling in a 15 s
  window). With the wake-up, the fetch usually lands inside that window.

## Security

- All demand, reserve, store, fail and metrics functions are service-role
  only. Helpers are private (revoked from every API role).
- The worker requires the cron token. The token is read from Vault inside the
  database and posted only to the worker URL in `runtime_settings`.
- The GOAL key is read from Vault by the worker and never logged or returned
  (this is tested).

## Deploy order (not done)

1. Apply the migrations in order: `20260923100000_provider_quota_manager`,
   `20260923110000_match_detail_user_demand`, `20260923120000_player_on_demand`.
2. Deploy the `futbeat-goal-live-sync` worker first, then `futbeat-api`.
3. Check that `runtime_settings.goal_worker_url` is right and that pg_net and
   Vault are enabled. Without them the wake-up is skipped and the per-minute
   cron still drains demand.
4. Watch `futbeat_demand_metrics(1)` and `futbeat_provider_quota_status()`.
5. Capture a real GOAL `/players/search`, `/players/:id` and
   `/players/:id/statistics` response and pin it as a fixture. The normalizers
   are tolerant, but no real sample has been verified.
6. Ship the app.
