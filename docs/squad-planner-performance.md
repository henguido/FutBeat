# Squad planner: local performance audit

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
