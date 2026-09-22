# Calendar cache / Explore — local implementation and measurements

Branch: `perf/calendar-cache-explore`
Base: `360d83a6db38612a436dbd4efdde5a28df634432`

## Calendar architecture

- A direct compact builder reads the indexed calendar date range and reconciles each match once. It no longer builds the old full calendar/redirect snapshot only to discard its payload.
- Persistent private cache keyed by civil date and timezone. Domain writes increment UTC-date dependency versions; catalog/redirect/editorial changes increment a catalog version.
- The version is captured before reconstruction and stored with the result. A concurrent dependency change cannot be overwritten by a cache upsert: the next read observes a different version. Rebuilds for the same key use a transaction advisory lock.
- Match entity, calendar index/coverage, observations, LIVE state, detail cache, canonical events, redirects and editorial metadata participate in invalidation. Both old and new dates are invalidated on rescheduling.
- Complete historical coverage with completed results: up to 24 hours. Partial history: 30 seconds. Clock-sensitive LIVE/future/grace-window rows: at most 10 seconds.
- Local today and multi-day ranges bypass the persistent payload cache and use the direct builder. Realtime contracts are unchanged.
- B1: invalidation skips the current **UTC** date, independently of the session timezone. To make that safe, every civil date intersecting that UTC bucket also bypasses the persistent cache, even when it is yesterday/tomorrow locally. Historical buckets still increment revisions; future buckets outside that window retain versioned caching. Future cache entries expire no later than the first dependency's UTC midnight, so a pre-today entry cannot survive the unversioned day and reappear stale as history. This deliberately trades adjacent-day cache hits for correctness. Clock semantics follow [PostgreSQL AT TIME ZONE](https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-ZONECONVERT).
- B2: the compact builder explicitly resolves home, away and competition references before joining canonical entity collections. The existing reconciler also resolves them; the new boundary does not rely on that implementation detail. No redirect catalog or extra fields are sent to the phone.
- Cache payload retention: 30 days, cleaned opportunistically on rebuild; no cron or provider requests.
- The invalidation is conservative for catalog changes: a team/competition/redirect change can invalidate more than one date. This trades some cache hit rate for correctness.
- Reconciliation logic, terminal authority, editorial ranking values, provider pagination and quota remain unchanged.
- New cache/index tables are private with RLS enabled. Client roles cannot read them or execute the RPCs; only the existing service-role boundary can call the public RPCs.

## Mobile refresh

Drift/memory cache is emitted immediately. Revalidation uses a discrete progress indicator, not a stale warning. Failed requests retain content and display the warning. Retries are bounded to three attempts per cycle with 3/6-second delays. While the date remains observed, a new cycle can start 30 seconds after the prior one completes; disposal cancels network work and the refresh timer. A successful response replaces memory and Drift data.

Local freshness is 20 seconds for today/recovery, 30 seconds for other dates. Pull refresh bypasses local freshness and requests the backend without a `Cache-Control` request header (C1: the backend never interpreted it). SQL decides whether the server cache is valid or needs a version-driven rebuild. HTTP calendar **response** headers still require revalidation instead of independently serving stale snapshots for 15 minutes; that separate policy remains meaningful and unchanged.

Future scheduled cards continue to show kickoff time. Stored historical non-terminal scores show “Marcador parcial”; terminal scores show “Finalizado”.

## Explore / search

- `/v1/explore` calls a dedicated five-minute server cache; it never downloads the global snapshot.
- Up to 12 competitions ranked by authoritative editorial score, then global flag/name/id. High-scoring domestic leagues are not excluded.
- Up to 16 real teams selected using ±7-day match activity and the competition's editorial score, then distance to kickoff. No invented popularity or player section.
- Existing logos/country labels and follow controls are shown. No fixed Costa Rica hero or country preference dependency.
- `entity_search_index` stores normalized name, short name and aliases, maintained on entity writes. GIN `pg_trgm` supports substring/similarity; a prefix B-tree handles short queries.
- Search ranks exact, prefix, substring/similarity, canonical competition relevance, name/id; no league-name hardcoding or country bonus. Aliases resolve to canonical IDs.
- Minimum two characters, 275 ms debounce, cancellation when switching query, previous results retained during loading, one-minute bounded memory cache. Empty/one-character UI uses suggestions, not a broad search.
- No photo hydration, player profile, provider coverage, squad planner or permission changes.

## Measurements

B1/B2/C1 payload check, same synthetic fixtures immediately before and after this correction; UTF-8 bytes of `JSON.stringify` RPC payload (not gzip or production):

| Fixture | Before correction | After correction | Change |
|---|---:|---:|---:|
| 20 September — 1,084 matches | 400,334 bytes | 400,334 bytes | 0% |
| 23 September — 171 matches | 65,436 bytes | 65,436 bytes | 0% |

Alias tests cover home redirects, chained away redirects, competition redirects, shared canonical deduplication and unchanged match count. A disposable database fixture relaxes redirect FKs solely to remove physical alias rows; production constraints remain unchanged. Another fixture replaces reconciliation with an identity function to independently exercise the explicit builder boundary. UTC offset and simulated midnight rollover tests cover the unversioned day and subsequent historical reads. Mobile tests cover header absence, actual forced requests, Drift replacement and single-flight.

These are single-run diagnostics, not service-level guarantees. Local measurements use PGlite with the same new migration, 13,789 synthetic entities, and date volumes observed in production (1,084 and 171 matches). They do **not** reproduce all production observations/history or hardware. Compare before/after only within the same local fixture.

Final local EXPLAIN ANALYZE run during the full suite (test concurrency: 2):

| Query | Before (ms) | New cold/build (ms) | New cache hit (ms) |
|---|---:|---:|---:|
| 20 September — 1,084 matches | 561.456 | 430.857 | 19.409 |
| 23 September — 171 matches | 110.308 | 97.993 | 19.547 |
| Empty Explore | 55.142 | 109.116 | 0.191 |
| Search Manchester | 76.961 | 4.772 | — |

The new **cold** Explore is not faster than the old empty query in this fixture: it computes real activity-based suggestions. Reuse of the cached result is the principal improvement. Manchester used a Bitmap Index Scan on `entity_search_term_trgm`; the index scan itself was below 1 ms in this run.

Production baseline, read-only `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` in read-only transactions:

| Existing RPC | Measured execution (ms) |
|---|---:|
| Calendar 20 September | 12,858.655 |
| Calendar 23 September | 819.453 |
| Empty search | 162.289 |
| Manchester search | 2,428.252 |

The 20 September baseline reported 87,872 shared-hit blocks and 4,562/3,984 temporary blocks read/written. Its duration varies from the earlier QA ~5.8 seconds. No new migration was applied in production; therefore **no production “after” timing is available**.

Reproduce locally:

```powershell
node --test backend/test/calendar_cache_explore.test.mjs
node --test --test-concurrency=2 backend/test/*.test.mjs
cd apps/mobile
flutter test
flutter analyze
```

Tests assert that a historical cache hit still succeeds when the heavy builder is replaced locally with a function that throws; score/reschedule/redirect/metadata/event/detail/coverage changes invalidate the cache; partial/complete TTLs differ; today's LIVE changes are visible; search indexes maintain aliases; and Flutter refresh replaces null-score cache with 1–1 in Drift and UI. Golden Explore was intentionally updated and visually inspected.

## Delivery boundary

Final validation after B1/B2/C1: backend 169/169; Flutter 120/120; flutter analyze clean;
git diff --check clean, including untracked source files.

Only new local migration `20260922002909_calendar_cache_explore.sql`. It creates `pg_trgm` in the extensions schema (the production baseline did not have that extension installed). No remote DDL, deploy, GOAL requests, cron execution, APK, commit, push or PR.

Reference for index behavior: [PostgreSQL pg_trgm](https://www.postgresql.org/docs/current/pgtrgm.html).
