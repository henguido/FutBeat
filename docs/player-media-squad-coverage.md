# Player media / squad coverage

## Audit before implementation

Base: `8c6afecfb99b09f48cc5a91e567a56a603f45380`. Local audit only; no provider or production calls.

A. Players enter through centralized squad normalization and ID-only lineup discovery in the detail worker.
B. `futbeat_resolve_global_entity` reuses `(provider, kind, external_id)` in `provider_entities`; names are not player identity keys. Existing redirects resolve teams/competitions. New external IDs require trustworthy explicit identity evidence, never name-only merging.
C. The canonical photo already lives in `entities.payload.media`. `player_media_coverage` tracks availability/expiry; `provider_media_cache` is an older provider-oriented cache, not a second player authority.
D. Provider IDs map to canonical players in `provider_entities`; lineup lookup already batches up to 100 IDs, joining canonical entities.
E. The central LIVE worker selects one squad, reserves quota, fetches the entire roster, and sends it to global-ingest. Flutter never fetches provider data.
F. The existing planner uses seven-day freshness, interests plus a hardcoded Costa Rica priority, a 16-squad daily limit and a 350-call reserve. It lacks per-team failure/backoff and in-flight protection. Squad storage replaces the roster and records transfers.
G. Sparse photos are consistent with limited squad hydration, country-biased selection, no photo harvest from stored lineup detail, and ID-only lineup player creation. These are code-level causes, not a claim that the provider has photos for every player. Reported production counts (about 1,589 players / 47 photos / 705 memberships / 20 hydrated teams) are user-supplied and were not remeasured.

Permission failure reproduced locally as `service_role`: `public.futbeat_read_snapshot()` → `permission denied for table team_squad_members`. Its owner is `postgres`, `search_path` is empty, but it is SECURITY INVOKER. The squad read/write RPCs are already SECURITY DEFINER. Fix the snapshot boundary without granting SELECT on private squad tables or changing snapshot/standings logic.

## Implemented data flow

Provider response already requested → centralized ingestion → `provider_entities` mapping → canonical `entities.payload.media` → existing entity/lineup consumers. No new player/media table, individual-photo dispatcher, bucket, downloaded image or rehosting.

`entities.payload.media` remains authoritative. It includes URL, source, external ID, received/verified time, discovery source and the existing `VERIFIED` / `REVIEW_REQUIRED` / `DEVELOPMENT_ONLY` metadata. `VERIFIED` means the accepted provider/media contract; this block does not download or check image HTTP availability. Existing non-GOAL verified media is conservatively retained over GOAL candidates. Null, empty, unverified, older and rejected URLs cannot replace good media. Canonical images remain usable after TTL expiry.

`player_media_coverage` is extended with `external_id`, `last_seen_at`, `verified_at` and `last_error`. It retains existing status names: `AVAILABLE`, `NOT_AVAILABLE` (= confirmed NO_PHOTO), `TEMPORARY_ERROR` (= FETCH_FAILED / invalid media). Identity-only discovery and omitted lineup image fields are not proof of absence. Legacy absence inferred without explicit evidence becomes eligible/unconfirmed, not a fresh 30-day negative result.

### Identity and squads

- Provider identity creation is serialized by provider/player ID. The same external ID always reuses its canonical mapping across teams; names never merge people.
- A verified alternate provider ID already mapped to the same player is reused (tested). An unrelated new ID with no mapping/evidence cannot safely be guessed to be the same person: establish the verified mapping before ingestion. No name-only or country-based heuristic is introduced.
- Team redirects resolve before membership/coverage writes. One full squad response fills mapping, player metadata, photos and memberships. Valid previous metadata survives absent/null/empty fields. Same-time duplicate rows are deduplicated by canonical player.
- Existing roster-change/transfer recording is left unchanged. A positive newer observation at another club moves the membership without making another person. Older responses cannot move it back.
- Omitted members, including a successful empty roster, are retained with their original `updated_at`. Absence alone is not a deletion signal; observed transfers remain authoritative. Coverage records NO_DATA/backoff for empty responses, separately from retained membership counts.

### Source order and TTL

1. Valid canonical photo: reuse, zero photo-specific calls.
2. Existing detail/lineup response: harvest a trusted GOAL CDN URL by player ID, no extra network call.
3. Scheduled/demanded full squad: enrich all returned players at once.
4. Individual lookup: deliberately **not implemented or scheduled**; it remains a future last resort.

Photos: 90 days. Confirmed no photo from a successful squad row: 30 days. Invalid photo candidate: temporary error, one-hour eligibility delay. A metadata-only update does not extend verified-photo TTL. `player_media_refresh_due(id, has_demand)` is eligibility only: false without demand, false while fresh/negative-cached, true when expired and demanded. It does not issue or enqueue calls. Opportunities in detail/squad may refresh media without additional cost.

Stored detail is harvested in chronological order by the new local migration, with no provider request. Runtime detail harvesting wraps the existing store function and uses the incoming response, not a merged old lineup. Match score/status/lifecycle logic is unchanged.

SQL GOAL media validation is centralized in the private `futbeat_valid_goal_player_media_url(url, source)` helper: GOAL origin, HTTPS, exact allowlisted host, nonempty path, no credentials/ports/whitespace/backslashes or malformed percent escapes. Detail harvest, squad storage and canonical GOAL media validation share this policy. Other already verified editorial sources retain their existing broader contract; detail harvest cannot use that exception. The JavaScript provider normalizer also retains its independent ingress guard.

## Central squad planner and quota

P0 LIVE (bounded recent fixtures) → P1 followed teams → P2 scheduled next-seven-day fixtures → P3 followed competitions → P4 authoritative editorial score ≥800 → P5 recently opened teams with unexpired interest. Duplicate mappings produce one team candidate, preserving the existing preference for the provider ID most recently seen in stored observations. No country/name relevance fallback.

P6 on-demand is available **capability, not an active route**: `futbeat_reserve_goal_squad_call` accepts an explicit `team_id`, but no on-demand dispatcher or player/team UI is connected to trigger it. The current worker continues to use the batch planner. Activating on-demand is a later, separately controlled decision; this block adds no dispatcher.

Shared freshness is seven days. Successful empty/404 responses wait 30 days. Failures wait 15 minutes, then 30, 60, etc., capped at one day. HTTP 429 waits one day; the existing quota ledger also retains the 350-call reserve and 16-squad daily cap. A per-team advisory lock and ten-minute in-flight lease suppress concurrent callers across users. An abandoned lease expires; it cannot create an immediate retry loop.

`team_detail_coverage` now exposes last successful response, last attempt, status, retained player count, photo count at squad refresh, next permitted refresh, failures, last error and lease. Runtime metrics compute photos from canonical entities, so opportunistic detail enrichment is visible without waiting for another squad refresh.

Failures are captured when the existing central call ledger completes a squad reservation. Other call kinds are ignored. Only the squad catch block in the existing worker changes: it forwards its HTTP error status for 404/429 classification. No LIVE scheduling, fetch cadence, score lifecycle or result pagination changes.

## Permissions and consumers

`futbeat_read_snapshot()` is owned by `postgres`, SECURITY DEFINER with empty `search_path`, and executable only by the existing service boundary. Its SQL body and standings behavior are unchanged. Private squad/media tables stay inaccessible to anon/authenticated and no SELECT is granted to service_role on squad tables. New metrics are service-only; internal helpers revoke PUBLIC/client execute.

`futbeat_read_lineup_player_media` accepts a `goal_api` batch of at most 100 input entries. Every distinct nonempty requested provider ID appears as a key, including unresolved IDs (null/empty input IDs are excluded). Duplicates collapse into one key. For example, an unresolved ID returns `"123": {"providerId":"123","canonicalId":null,"image":null}` rather than omitting the key. A resolved player without a photo keeps its canonical ID and has `image:null`. Consumers must treat missing images as normal coverage/fallback, not an error. Resolution remains one set-based batch query, with no N+1 queries or per-player requests.

The BFF already prefers canonical image over raw detail image. Entity payloads continue serving team/player/search/favorites consumers with canonical media. Explore/search implementation is untouched.

Flutter keeps the current layout. Avatars prefer verified canonical media, accept safe HTTPS only, then existing lineup fallback. Missing/failed images use initials/dorsal/current neutral fallback without a spinner. Empty names/short names are safe. No provider or photo-enrichment request is added.

Rights remain REVIEW_REQUIRED (or an existing stronger status). Nothing is uploaded to Supabase Storage. Tests use synthetic URLs and local databases.

## Measuring after a separately authorized deployment

Run from an internal service-role SQL context (not from Flutter):

```sql
select public.futbeat_player_coverage_metrics();
```

Returns `canonical_players`, `players_with_photo`, `players_without_photo_known` (unexpired confirmed absence), `squad_members`, `teams_with_squad`, `teams_with_fresh_squad`, `teams_with_stale_squad`, `teams_total`, `canonical_photo_pct`, `squad_mapping_pct`, `squad_photo_pct`, `teams_fresh_pct`. The last percentage uses all canonical teams excluding redirected aliases; player percentages use all canonical players, membership percentages all retained memberships. Zero denominators return null. Per-lineup coverage totals are intentionally omitted to avoid scanning every detail blob for routine metrics.

Measure before rollout, after the local-only stored-detail backfill is separately applied in production, and after normal quota-protected squad cycles. Compare counts, availability and failure/backoff; do not infer actual image coverage improvement from synthetic fixtures. This task never measured or changed production.

## Local validation / delivery

New migration: `20260922041454_player_media_squad_coverage.sql`, generated by Supabase CLI; not applied remotely. Prior migrations are untouched. New tests cover service-role read/write paths and client denials, identity/mapping reuse, transfer/redirect behavior, media retention and harvesting, negative cache, TTL/demand, priority/deduplication, lease/backoff/quota, empty squads, batch lookup, metrics and Flutter fallbacks.

Final local validation after C1–C3: backend **180/180**, Flutter **123/123**, `flutter analyze` clean, `git diff --check` clean (including untracked source files). Two additional tests cover the shared GOAL URL security policy and central-host-change propagation into harvest/canonical batch reads, including explicit unresolved entries. Backend command: `node --test --test-concurrency=2 backend/test/*.test.mjs`; Flutter: `flutter test` and `flutter analyze` in `apps/mobile`.

No commit, push, PR, deploy, remote migration, cron execution, GOAL API call, quota spend, APK, storage upload or media download.
