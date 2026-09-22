# Squad planner: local performance audit

## Second optimization: candidate pools (2026-09-22)

Base `62ee8c6faa90aa10ef9239dc8d104b0154896fe7`, branch `perf/squad-planner-candidate-pool`. PR81 is now applied in production **according to the supplied report**, with about 2050 ms warm / 3075 ms cold and 2667 matches / 5334 appearances / 4670 distinct active teams. About 92 are editorially relevant. No production measurements or provider calls were performed here.

### Confirmed locally before changing the planner

The new adversarial fixture has 10000 teams, 5000 upcoming matches, 10000 mappings, two favorites, zero followed competitions and zero temporary interests. One editorial competition accounts for 100 teams. Kickoffs are a minute apart within the unchanged seven-day window. Unlike the original fixture below, all matches are active: the original fixture's 20 active matches concealed this scaling cost.

| Tier | Raw appearances/signals | Distinct within tier | After min-tier dedupe |
| --- | ---: | ---: | ---: |
| P0 | 0 | 0 | 0 |
| P1 | 2 | 2 | 2 |
| P2 | 10000 | 10000 | 9998 |
| P3 | 0 | 0 | 0 |
| P4 | 100 | 100 | 0 |
| P5 | 0 | 0 | 0 |

The CURRENT PR81 planner evaluates 10000 canonical eligibility checks and 10000 mapping lookups before LIMIT. Its provider_mapping node accumulates most of the query time, but this is **not exclusive mapping time**: broad active_teams/activity/ranked construction is also material. P2 dominates the universe; the cost scarcely depends on p_limit.

Extracted internal SELECT, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` on the local adversarial fixture:

| CTE probe | Returned CTE rows | CTE loops | Total probe ms | CTE node ms | Shared hits | Read / temp read / temp written |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| active_matches | 5000 | 1 | 16.910 | 12.075 | 342 | 0 / 0 / 0 |
| active_teams | 10000 | 1 | 50.793 | 43.013 | 342 | 0 / 0 / 0 |
| ranked | 10000 | 1 | 123.518 | 115.346 | 640 | 0 / 0 / 0 |
| eligible | 10000 | 1 | 171.633 | 161.797 | 30640 | 0 / 0 / 0 |
| mapping_targets | 10000 | 1 | 184.523 | 176.600 | 30640 | 0 / 0 / 0 |
| provider_mapping | 10000 | 1 | 238.930 | 231.380 | 60640 | 0 / 0 / 0 |
| due | 20 | 1 | 250.222 | final LIMIT, inlined | 60640 | 0 / 0 / 0 |

These are separate cumulative CTE probes, not additive exclusive times. Relevant nested nodes: entities PK lookup 10000 loops / one row each, provider_entities canonical-ID index 10000 loops / one row each; mapping quicksort 10000 rows / 724 KB; final top-N heapsort 20 rows / 18 KB. No temp spill in this fixture. The benchmark prints every node (rows, loops, buffers, sort method/space, temp, time) with `--plans` so these measurements are not just an opaque PL/pgSQL RPC timing.

### New flow and ordering

- Execute tiers in priority order and stop when the plan is full. P0 enumerates **all** LIVE candidates and evaluates all due LIVE mappings before the global limit. P1 reads explicit team interests directly. No team catalog scan.
- P2 uses a cursor over calendar start_time, with indexed match-PK probes. The match probe intentionally uses a non-flattened lateral subquery: this is not the removed full mapping-catalog lateral scan. It keeps calendar as the ordered driving relation instead of sorting a full entity scan. Matches are processed in ascending kickoff order, one complete same-kickoff group at a time.
- Within a kickoff group: canonicalize only supplied IDs, dedupe, exclude already selected/visited teams, check existence/kind, freshness/backoff/lease, then sort by fetched_at NULLS FIRST and team_id. Query GOAL mappings set-wise in small batches (16–25 eligible IDs), continuing with further batches/groups until enough usable teams exist or the source is exhausted. **No fixed total oversampling cap.** A missing mapping, a fresh team or an alias cannot starve later candidates.
- Changed P2 tie-break: earliest upcoming kickoff now precedes fetched_at NULLS FIRST / team_id. Other tiers retain fetched_at / team_id. Chained aliases across different kickoffs keep the earliest canonical occurrence. Contract fields/reason strings/priority scores remain unchanged.
- P3 first reads followed competitions; with none it never invokes the activity query. P4 first reads authoritative editorial competitions, then filters match competitionId **before** home/away expansion. In the fixture, matching emits 50 matches / 100 teams, not 5000 / 10000. Both preserve the unexpired opened-team demand path from PR81. Only missing match competitionId uses per-team metadata fallback.
- P5 reads temporary team interests directly; no rows means no eligibility or mapping query. Lower tiers are not queried at all when higher tiers fill the plan.
- Redirect resolution is limited to pool IDs; reverse alias mapping traversal starts from the current eligible batch, not a globally materialized redirect catalog. Existing cycle/depth guard and the 180-day last-seen preference are preserved. Last-seen triggers, ingestion, quota and public access rules are unchanged.

Normal adversarial planner(20): P1 pool 2 + P2 pools 18 = **20 raw pool IDs / 20 mapping candidates**, versus CURRENT 10000. P3/P4/P5 are unnecessary after P2 fills the remaining slots. Physical match cursor prefetch and incremental sort can inspect additional raw matches; the bound refers to canonical/coverage/mapping pools, not zero-cost source reading.

Important tie/adversarial limit: 5000 matches sharing the same kickoff require a 10000-ID tie group to preserve globally deterministic fetched_at/team_id order. Eligibility/dedupe for that group is not constant-time. Mapping work still stops early: a test with 100 missing mappings examines 120 eligible IDs to return 20, not all 10000. If every team is unavailable, exhausting the window is necessary for correctness; there is no false promise of constant work in that case.

New internal query examples: two-ID eligibility 0.158 ms / 6 shared hits; two-ID mapping 0.149 ms / 6 shared hits / two indexed probes; competition pool 41.157 ms / 4525 shared hits, expanding only 50 matching matches. No temp reads/writes. Fully consuming the P2 source is about 21.956 ms for 5000 matches, whereas the planner cursor stops early after enough kickoff groups. A separately explained 50-row cursor-sized fetch takes **0.360 ms**, uses incremental sort and reads 51 calendar entries plus 51 entity PK probes (156 shared hits, zero reads/temp writes).

### Index decision

No index added. After bounding pools, the existing canonical-ID index performs two point probes in the sample. The suggested `(provider,kind,canonical_id,last_seen_at DESC) INCLUDE(external_id)` was created **only inside a rolled-back disposable benchmark transaction**. It changed the plan to index-only probes but measured 0.205 ms versus 0.149 ms without it (tiny timings, with cold index pages; not statistical proof of a slowdown). There is no demonstrated material gain to justify extra index/write cost. Calendar start_time and entity PK indexes support the ordered source.

### Comparable local RPC benchmarks

All units below are milliseconds, decimal point, no thousands separators. PGlite only; no production SLA claim.

| Adversarial 10000-team fixture | planner(1) | planner(5) | planner(20) |
| --- | ---: | ---: | ---: |
| CURRENT PR81 | 133.605 | 122.043 | 122.394 |
| NEW warm | 4.216 | 5.098 | 11.513 |

The original 8000-team / 20000-player / 4000-match / 30000-observation fixture was also rerun unchanged, with only 20 active matches: OLD pre-PR81 planner(20) **21190.463 ms**; CURRENT(1/5/20) **3.441 / 2.750 / 3.160 ms**; NEW(1/5/20) **2.385 / 1.912 / 1.740 ms**. This separate comparison explains why the first benchmark was optimistic; do not compare its times as if it contained 5000 active upcoming matches.

Reproduce: `node backend/bench/squad_candidate_pool.mjs --plans`; use `--legacy-fixture` for the three-version original-fixture comparison. Pool counters are injected only into a disposable database's helper using session-local diagnostic settings and then the exact helper definition is restored before timing or READ ONLY tests. No instrumentation or settings writes are in the migration.

New migration: `20260922141448_optimize_squad_candidate_pool.sql`. Applied PR81/previous migrations remain untouched. Five additional adversarial tests cover nearest selection, bounded mappings, read-only execution, progressive fallback, same-kickoff ties, no-interest skipping, competition-first filtering and upcoming chained redirects. Partial matches with a missing team cannot insert NULL into the visited array and suppress subsequent candidates. Final validation after that edge-case fix: **backend 191/191**, **Flutter 123/123**, `flutter analyze --no-pub` clean and diff-check clean including new files. No commit, push, PR, remote migration, deploy, cron, GOAL, worker or Flutter changes in this block.

---

## First optimization audit (historical)

Base: `01c3935db68ced73d0cefb2e5a85cda418aad935`; branch `perf/squad-planner`.
Production timeouts were reported by the user. No production query or provider request was made in this block.

## Dominant cost reproduced locally

The old planner's `due` CTE runs a correlated lateral mapping query for every ranked team. Its predicate applies `futbeat_resolve_entity_id` to each provider mapping, preventing a direct canonical-ID index lookup. The final LIMIT 20 does not prevent these scans because candidates must first be mapped and sorted.

Synthetic fixture: 8,000 teams, 20,000 players, 4,000 matches, 100 competitions, 28,000 provider mappings and 30,000 observations spread over 170 days. Twenty matches / 40 teams are within the unchanged window. One competition is followed and another is editorially relevant, yielding 198 ranked teams before optimization. Entity triggers are disabled only while constructing the disposable benchmark catalog; calendar and editorial rows are explicitly seeded. All production triggers are enabled during measurements.

The full old EXPLAIN ANALYZE showed:

```text
Limit 20 -> Sort -> Nested Loop (198 ranked teams)
  provider lookup Limit: 198 loops, 105.451 ms/loop
    Bitmap Index Scan provider_entities_pkey: 8,000 rows x 198
    Bitmap Heap Scan: resolver predicate over those mappings
    CTE Scan recent_provider_teams: 8,000 rows x 198
P3/P4: two entities Seq Scans, each filtering 8,000 teams
recent_provider_teams: 30,000 observations -> 60,000 ID occurrences -> 8,000 groups
active_matches: calendar_matches_start_time_idx -> entities_pkey, 20 matches
```

The provider lookup accounts for approximately 20.88 s of the 21.33 s full SQL execution (~98%). The mapping filter alone evaluates the resolver for 1,584,000 mapping rows (8,000 × 198); competition/team candidate resolution adds more. This is the dominant **locally reproduced** cause, not a claimed measurement of the production timeout. Production cardinalities, plans, hardware and statement timeout were not inspected.

## Before / after measurements

Each CTE measurement executes the same WITH prefix followed by `count(*)` on that CTE. They are cumulative dependency measurements, not additive exclusive times; PostgreSQL can prune unused CTEs and change plans. Full SQL and RPC measurements run separately on warm local PGlite.

| Measurement | Before ms | After ms |
| --- | ---: | ---: |
| recent_provider_teams | 154.654 | removed |
| active_matches | 0.201 | 0.734 |
| candidates | 264.874 | 2.107 |
| ranked | 458.228 | 1.416 |
| provider_mapping | ~20,879 (198 lateral loops in full plan) | 2.149 (standalone dependency measurement) |
| due | 21,346.326 | 6.237 |
| Full inner SQL | 21,326.521 | 2.906 |
| `futbeat_team_squad_plan(20)` | 20,524.059 | 5.153 |

These are synthetic **PGlite** measurements, not native production PostgreSQL results or an SLA guarantee. They meet the <300 ms local target. Production <300 ms / <1 s must be verified separately after an authorized rollout. The regression test checks the structural plan and a generous 1 s local threshold.

Reproduce without network:

```powershell
node backend/bench/squad_planner.mjs --before
node backend/bench/squad_planner.mjs
# Add --plans for all EXPLAIN nodes, including per-CTE details.
```

The `--before` option installs only the old function body into a disposable in-memory database; it never changes migration files or any remote database.

## New architecture

- Read `calendar_matches` through its existing start-time index over **now −6 hours through now +7 days**. P0 remains LIVE/HALFTIME/EXTRA_TIME/PENALTIES; P2 remains future SCHEDULED.
- P1 remains explicit team followers. P5 remains unexpired team interests.
- P3 and P4 now require a team in that bounded calendar window (including recent completed matches), or an unexpired opened-team interest. P3 matches a followed competition; P4 requires authoritative non-derived relevance >=800. No scan of all clubs in a followed or major league. No country/name priority.
- Match competition identity is preferred; team competition metadata is a fallback and is fetched by primary key for active/opened teams only.
- Materialize redirects once; run the existing depth/cycle-protected resolver only for actual aliases. The fixture has no redirects, so the new plan makes zero resolver calls. Chained team and competition aliases are covered separately by functional tests. Canonical entities/mappings need no recursive call.
- Group by canonical team with min(tier). Apply unchanged `next_retry_at`, seven-day fallback freshness and `lease_until` rules before mapping.
- Build mapping targets from eligible canonical IDs plus their aliases. Join `provider_entities` set-wise by its existing canonical-ID index. Choose one external ID per canonical team with DISTINCT ON: most recently seen within 180 days, then external ID descending. Missing/blank GOAL mappings are excluded, never invented.
- Keep the exact fields, reason strings, priority scores, deterministic ordering and limit validation. Reservation/quota code and limits are unchanged.

New full plan: 40 ranked teams, 40 targeted `provider_entities_canonical_id_idx` probes returning one row each, no lateral mapping subquery, no observations node and no entities sequential scan. A physical indexed nested loop is still a valid PostgreSQL join strategy; it is not the old repeated full mapping scan.

## Incremental last-seen

The new nullable `provider_entities.last_seen_at` column avoids a new table. One migration-time backfill aggregates the retained 180-day observations once. Runtime statement-level INSERT/UPDATE triggers aggregate only the newly written transition rows, extract flat/nested home and away provider IDs and update existing GOAL team mappings only when the timestamp increases. Repeats and older observations produce no mapping writes. No identity is invented; normal ingestion establishes mappings before observations. Unknown/unmapped IDs are ignored until a mapped observation arrives; without a last-seen signal, existing deterministic lexical fallback applies. Deleting observations does not erase this monotonic last-seen signal; values older than 180 days lose ranking preference.

The helper is internal, has an empty search_path and no PUBLIC/anon/authenticated/service_role EXECUTE grant. Existing service-only planner RPC access is preserved. No new public endpoint or table grant.

## Index audit

**No new indexes:** EXPLAIN demonstrated the existing indexes serve the bounded query.

| Relation | Existing useful index / decision |
| --- | --- |
| provider_entities | `(provider,kind,external_id)` PK for incremental updates; `canonical_id` index for targeted planner joins. No redundant composite index added. |
| calendar_matches | `start_time` index for range; `match_id` PK for identity. |
| entities | `id` PK for bounded match/team reads; no player/catalog scan. |
| coverage_interests | `(subject_type,subject_id)` PK; small fixture uses a cheap seq scan. No speculative followers index. |
| temporary_interests | existing `expires_at` and `entity_id` indexes. No speculative composite index. |
| team_detail_coverage | `team_id` PK; evaluate retry/freshness/lease for candidates, not a global due scan. |
| competition_editorial_metadata | `competition_id` PK; bounded activity joins. No relevance-only index. |
| entity_redirects | alias PK / `(kind,canonical_id)` index already exist. |
| provider_observations | no planner access; existing received-time indexes remain for other consumers / one-time backfill. |

## Safety and validation

The planner runs successfully inside a READ ONLY transaction. Tests compare ledger, coverage/leases and mappings before/after repeated reads: no writes, reservations or provider calls. Additional tests cover all six priority tiers, multiple signals, chained redirects, fresh/backoff/lease exclusions, mapping absence, monotonic timestamps, one-time backfill, expired last-seen fallback, country independence and 8,000 inactive followed/editorial clubs not expanding the queue.

Migration: `20260922054858_optimize_squad_planner.sql`. The deployed `20260922041454_player_media_squad_coverage.sql` is unchanged. No photos/media policy, calendar implementation, Explore, pagination, polling, standings, news, transfers, quota or worker changes.

Final local validation: backend **186/186** (six new tests), Flutter **123/123**, `flutter analyze --no-pub` clean and diff-check clean including new files. Full-suite benchmark inner SQL: **4.170 ms**. Commands: `node --test --test-concurrency=2 backend/test/*.test.mjs`, `flutter test --no-pub`, `flutter analyze --no-pub`. No dependency downloads or remote database validation were requested. No commit, push, PR, deploy, remote migration, manual cron or GOAL call was performed.
