# Squad planner: local performance audit

## Third optimization: P2 upcoming quality (local, not deployed)

Base `c8e13a944366694c05ba15d6b9674c392dc645d9`, branch `perf/squad-upcoming-ranking`. The supplied production report describes a fast planner (~25 ms warm for 20) but low-value nearest-kickoff P2 candidates filling the limited 16-squad daily budget. These production observations were not remeasured. This block changes only ranking **inside P2**, not the global P0 LIVE → P1 favorite → P2 upcoming → P3 followed competition → P4 editorial → P5 recently opened hierarchy.

### Signal audit and exact order

| Signal | Existing source | Use / limitation |
| --- | --- | --- |
| Followed competition | `coverage_interests`, competition with `explicit_followers>0` | Boolean central aggregate; canonicalize aliases. Same mechanism as P3; no new follower counter. |
| Editorial relevance | `competition_editorial_metadata.relevance_score` | Use exact score only with `source='editorial'`. Derived/provider/missing metadata falls back to 100, including an accidentally high derived score. No name-based inference. |
| Temporary team demand | `temporary_interests`, team rows with `expires_at>now()` | Distinct canonical team IDs, boolean existence across all users. No user identity/count influences rank; stale `coverage_interests.temporary_users` is not trusted for expiry. |
| Kickoff | `calendar_matches.start_time` | Existing canonical calendar time. |
| Stable tie | Canonical team ID | No country, invented team popularity, media completeness or extra fetched-at ranking signal. |

Exact lexicographic P2 order: **time bucket ASC → followed competition DESC → editorial relevance DESC → temporary demand DESC → kickoff ASC → canonical team ID ASC**. Buckets use rolling instants: `[now, now+24h]`, `(now+24h, now+72h]`, `(now+72h, now+7d]`. This is not a weighted formula. A followed competition wins within its bucket even at a lower relevance score; temporary interest only wins after equal followed/relevance signals. Repeated user touches cannot multiply a score.

Window audit: deployed P2 already selected only future `SCHEDULED` matches from **now through +7d**. It still does. P0/P3/P4 retain their wider **−6h through +7d** activity window. This block does not broaden past scheduled matches into P2 or change any window. Missing match competition identity gets conservative metadata, not a guessed league from team name/country.

### A versus B, compared before selection

The 20-team realistic synthetic fixture mixes Champions 970, Libertadores 950, Premier 930, LaLiga 920, Serie A 910, editorial 500, low/derived 100, an incorrectly high derived/provider 999, missing metadata, a followed competition, real temporary demand, high/low editorial women's and U23 competitions and varied kickoffs. Labels occur only in fixture code, never in production ranking SQL.

- **A: no time bucket**, followed → relevance → demand → kickoff → team ID. Champions at +6d ranks alongside today's Champions, and editorial 940 at +6d displaces Premier 930 today. This is valid relevance ordering but a poor use of a small daily hydration budget when the score difference is tiny.
- **B: time bucket first**, followed by the same signals. Today's Premier stays ahead of +6d Champions/940, while today's Champions +40min and Premier +1h still beat low relevance +10min. Selected B for its explicit time horizon and simpler operational explanation.
- B deliberately has step boundaries: a lower-relevance match at +23h can precede a high-relevance one at +25h. Continuous first-bucket demand can defer later buckets until those matches approach; there is no claimed fairness guarantee across quality scores. Buckets protect near-term opportunities rather than excluding any competition type. An editorially high women's/U23 competition rises exactly like any other.

Final repeated full-source A/B ranking-only measurements on 10000 candidate teams: **71.626 / 65.799 ms** (realistic 20-team fixture: **1.832 / 2.083 ms**). These compare sorting all candidates, **not** the full planner or GOAL mapping. The selected implementation evaluates B buckets lazily to avoid sorting the full week when the first bucket fills the result.

Realistic top-five before (nearest kickoff): derived 999 (effective fallback 100), provider 999 (100), missing metadata (100), low competition (100), U23 low (100). After: followed competition (500), Champions (970), women's high editorial (960), Libertadores (950), U23 high editorial (940). If no competition is followed, Champions leads this fixture. Premier +20min stays ahead of Premier +2h when other signals match; a genuinely demanded Premier team can lead both because demand precedes kickoff within equal relevance.

### Candidate pools, dedupe and performance

`squad_upcoming_candidates(bucket)` first bounds calendar activity and reads matches by primary key. It resolves competition metadata once per distinct match competition before home/away expansion. Team redirects are joined set-wise; recursive resolution runs only for actual aliases, preserving the existing depth/cycle protection. Within each bucket, DISTINCT ON chooses the canonical team's best representation by the complete ranking tuple, not simply its earliest match. Across buckets, selected canonical IDs are excluded; a team with several matches has one returned position. Unavailable teams may be checked again in a later bucket, but cannot be returned twice.

`squad_upcoming_due` opens bucket 0 first and opens 1/2 only when needed. It consumes ranked unique IDs in batches no larger than the remaining slots (at most 25), reuses the **unchanged** `squad_pool_due` for freshness/backoff/lease/entity validity and provider mappings, then restores P2's rank within the mapped batch. It does not let the shared helper's fetched-at ordering choose P2 winners. Missing mappings trigger progressive refill without a fixed oversampling cutoff. Higher-tier canonical favorites are excluded and remain P1. P0/P1/P3/P4/P5 code is checked unchanged by regression tests.

The complete bucket is ranked before its first rows can be emitted. Ranking within a bucket is **not incremental**; only bucket opening and eligibility/mapping batches are progressive.

Large fixture: **5000 upcoming matches / 10000 raw team appearances**, varied competition metadata and demand. Bucket 0 contains **1380 matches / 2760 appearances**; only **20 candidate IDs reach eligibility and 20 mapping evaluations** for planner(20). Distinguish these levels: the cheap calendar/source scan and metadata sort do inspect more than 20 rows. The planner never resolves all 10000 provider mappings just to sort them. P0's existing exhaustive LIVE behavior is deliberately unchanged.

Final warm local PGlite medians (three samples after warmup, milliseconds):

| 10000-team mixed fixture | planner(1) | planner(5) | planner(20) |
| --- | ---: | ---: | ---: |
| CURRENT nearest-kickoff P2 | 3.499 | 4.438 | 9.135 |
| NEW quality-ranked P2, lazy buckets | 22.470 | 22.839 | 22.940 |
| CURRENT mapping evaluations | 2 | 6 | 20 |
| NEW candidate IDs inspected / mappings | 1 / 1 | 5 / 5 | 20 / 20 |

Ranking is not free: NEW spends more CPU on cheap metadata than CURRENT but remains in local tens of milliseconds and keeps mapping work bounded. Do not equate this synthetic baseline with the user-reported ~25 ms production timing or infer a production SLA. When all fixtures occupy the first bucket, all of that bucket's metadata must be ranked. If many candidates lack mappings or are fresh/backed-off/leased, more batches are necessarily inspected. A test exhausts all first-bucket mappings and still fills from the second bucket. No artificial guarantee of constant work is claimed for an exhausted universe.

EXPLAIN ANALYZE confirms match primary-key probes, 1380 matching rows before expansion, 2760-row metadata sorts, no provider/observation access in the ranking source and no temp spill. No new index is justified by this fixture. Existing calendar start-time, entity PK, competition metadata PK, redirect and mapping indexes are reused. Production cardinality/distribution still needs separately authorized validation.

Reproduce locally with `node backend/bench/squad_upcoming_ranking.mjs`. It prints A/B orderings, CURRENT/NEW planner timings, raw universe, candidate-pool rows, mapping evaluations and EXPLAIN nodes. CURRENT is the previous candidate-pool planner installed only into a disposable database; functions/instrumentation are restored between comparisons. No migration history, deployed migration, remote database or provider is modified by the benchmark.

### Contract, diagnosis and safety

The public planner still returns only `teamId`, `externalTeamId`, `priority`, `priorityTier`, `reason`, `lastFetchedAt`. Both new helpers are private, STABLE, empty-search-path and revoked from PUBLIC/anon/authenticated/service_role. The existing service-only SECURITY DEFINER planner boundary is retained. In an authorized database-owner/admin SQL session, `select * from futbeat_private.squad_upcoming_candidates();` provides ranking signals for diagnosis; a bucket argument limits its scope. It deliberately shows ranking candidates before eligibility/mapping, not a promise that they will be returned by the public planner. No new public RPC is exposed.

New incremental migration: `20260922154959_rank_upcoming_squad_candidates.sql`, generated by the local Supabase CLI with telemetry/update checks disabled. Prior migrations remain untouched. No changes to squad-only/worker, reservation, quota values, daily limit 16, protected reserve, last_seen, media/ingest, cron, calendar implementation, Explore or Flutter. Expected quota impact is better choice per available squad slot, **not** a quota increase or a guaranteed number of photos.

Final validation: **backend 224/224** (10 new ranking tests), **Flutter 123/123**, `flutter analyze --no-pub` clean, diff-check clean including untracked source files. Tests cover A/B, metadata provenance, temporary expiry, all tier regressions, canonical best representation, window boundaries, missing-mapping refill across buckets, bounded mapping work, private permissions and READ ONLY execution. No commit, push, PR, deploy, remote migration, manual cron, production query or GOAL call was performed.

---

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
