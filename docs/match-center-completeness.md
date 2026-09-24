# Match Center completeness and on-demand hydration

Generic for any match, competition, season, team, player or country. There
are no special cases: a guard test (`backend/test/no_hardcode_guard.test.mjs`)
forbids QA-specific names or canonical ids in runtime code and in the new
migrations.

## Root causes (before)

1. **"A cached row exists" meant "the detail is complete"** in SQL
   (`detailLevel='full'`), in the API and in the client (it never asked again
   once `available`). VERIFIED matches were never due, so a detail with events
   but no lineup or statistics stayed incomplete forever.
2. **No per-section state.** Nothing recorded "the provider has no lineup/stats
   for this match", and failed fetches had no backoff.
3. **Standings keyed by `competition_id` only.** A new season overwrote the
   old one, and every reader attached "the" competition table to any match,
   whatever its season. Standings were fetched only by a 6-hourly workflow
   under a fixed 12/day guard, with a hardcoded country priority.
4. **Client:**
   - every refresh restarted from an empty "loading" state, so data flickered
     and a failed refresh could erase a visible lineup;
   - polling died after about 15 s;
   - incomplete detail was kept cached for 60 s;
   - the context (where standings live) was never refreshed while the screen
     was open.

## Flow (after)

```
open match ─► /v1/match-context ─► futbeat_request_match_standings (exact competition+season)
          │                        futbeat_read_match_context  → coverage.standings / standingsPending
          └► /v1/match-detail  ─► futbeat_request_match_detail → coverage.detail/lineup/statistics, pending
                                    │ (cache hit, or one deduplicated demand per match / per competition+season)
                                    ▼
                             wake_provider_worker('demand')  (+ per-minute cron fallback)
                                    ▼
             worker demand lane: match detail → players → standings  (central quota manager)
                                    ▼
                    store (merge, never erase) → archive → sections/demands updated
                                    ▼
             app: bounded refreshes update the open screen in place (tab + scroll kept)
```

## Completeness model (per match, `match_detail_coverage`)

| Field | Meaning |
| --- | --- |
| `lineup_state` / `statistics_state` | `AVAILABLE` if the stored detail has the section. `NO_DATA` once a finished match was fetched twice without it (the provider has none, so no more polling). `UNKNOWN` otherwise. |
| `failure_count`, `next_retry_at` | Failed fetches back off 2 min·2ⁿ, up to 6 h. |

- **When a section is "wanted":** lineups from 60 minutes before kickoff;
  statistics after kickoff; never for cancelled or postponed matches.
- **`match_detail_needs_fetch`:** true when the match is not in backoff and
  either:
  - the existing freshness rule says it is due, or
  - a wanted section is still `UNKNOWN` and the last fetch is older than the
    retry gap: 5 min live, 15 min within 6 h of kickoff, otherwise 6 h.
- **Where the rule is used:** it replaces the old rule in both
  `request_match_detail` and `reserve_match_detail_call`, so priorities and
  dedupe are unchanged.

## Client contract (`schemaVersion` 1 unchanged)

- **`/v1/match-detail`:** `coverage.detail` is `available|pending|missing`.
  `coverage.lineup` and `coverage.statistics` are one of:
  - `available`: stored;
  - `pending`: being fetched;
  - `unavailable`: the provider has none;
  - `missing`: not stored and not being fetched.

  It also returns `coverage.stale` (stored but past its window) and `pending`,
  which is true when any section is pending.
- **`/v1/match-context`:** `coverage.standings` is
  `available|pending|unavailable|missing`, plus `coverage.standingsPending`
  and `coverage.standingsStale`. The response is sent with no-store while
  pending.

## Standings identity

- **`standings_snapshots(competition_id, season_key)`:** the exact identity.
  - Every `standings_cache` write is archived there by trigger.
  - `season_key = normalize_season(row season)`, or the competition's current
    season when the rows carry none.
  - `normalize_season` only normalizes format: `2026/27` and `2026-2027`
    become `2026-2027`, while `2026` stays distinct from `2026-2027`.
- **Match Center shows only** the table for the match's competition and
  normalized season.
  - Never by name, country, editorial fallback or another season.
  - No match season means no table.
  - The provisional live overlay applies only to the current season.
- **`standings_cache`** stays as "latest table per competition" for the
  existing profile readers and redirect merges.
- **`standings_demands`:** one row per (competition, season). A table can
  only be fetched for the competition's current season, because the GOAL
  endpoint returns the current table. Past seasons are available only if they
  were archived while they were current.
- **Negative cache:** an answer without that exact season is `NO_DATA` for
  3 days.
- **Reservation (`futbeat_reserve_goal_standings_call`):**
  - user demand comes first (class `user_high`), then coverage refresh (class
    `coverage`);
  - it goes through the central quota manager (kind `standings`, cap 120/day);
  - the old 12/day, remaining ≤ 350 and country priority are removed;
  - LIVE and results keep their protected floors.

## Freshness (cache-first, stale-while-revalidate)

| Data | Rule |
| --- | --- |
| Match detail | Existing windows (LIVE 5 min, non-terminal 30 min, terminal never), plus missing wanted sections on the retry gap |
| Standings | Fresh for 6 h, or 30 min while a match of that competition is live; stale tables are shown while revalidating |
| Player profile / stats / photo / squad | Unchanged (see `docs/real-data-on-demand.md`) |

## App behavior

- **Detail:**
  - It starts from the last good detail of the session, so there is no
    loading flash and a failed refresh never erases data.
  - It re-reads at 5, 10, 20 and 40 s while pending, then stops.
  - Incomplete detail is not retained.
- **Sections:**
  - "Cargando alineaciones…" and "Cargando estadísticas…" only while that
    section is pending.
  - Otherwise "Sin alineaciones" or "Sin estadísticas".
  - A pending section never outlives the global pending flag.
- **Standings:**
  - Up to 3 context refreshes (8, 20, 40 s) while pending.
  - The Tabla tab appears in place and the selected tab is kept.
- **Refresh signal:** a discreet 2 px progress line under the tab bar.
- **Players:** a lineup player is tappable to `/player/<canonicalId>` only
  when the canonical id is known (existing behavior, tested).

## Deploy order (not done)

1. Apply `20260923170000_match_detail_completeness.sql`, then
   `20260923180000_standings_season_identity.sql`.
2. Deploy `futbeat-goal-live-sync` (demand lane: standings), then
   `futbeat-api`.
3. Verify with `futbeat_demand_metrics(1)`: `standings_user_demands`,
   `standings_cache_hits`, `match_detail_*`.
4. Capture a real GOAL `/standings/{id}` response to confirm the row season
   field (unverified).
