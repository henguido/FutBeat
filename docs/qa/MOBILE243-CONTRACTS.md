# MOBILE243 — local central API simulation

Base: MOBILE242 5b469b7. Branch codex/mobile-243.

## Executable preparation

`apps/mobile/test/support/stored_fixture_server.dart` starts an ephemeral IPv4 loopback server with configurable route payloads/status, request paths, response bytes and handler timings. It rejects writes/unknown routes. Its test wire permits only the allocated loopback port. Logical HTTPS remains enforced by the real stored-read interceptor; loopback HTTP does NOT validate TLS or deployment. No production credentials or provider client are used. This server is test-only and never bundled into the mobile app.

Run from apps/mobile:
`flutter test --no-pub test/mobile243_stored_contract_test.dart test/qa_stored_read_loopback_test.dart test/night230_passive_real_cache_e2e_test.dart --reporter expanded`

## Contract matrix

| Consumer | Proposed stored route | Local verification | Remote status |
|---|---|---|---|
| Date feed | /v1/qa-stored/calendar | Query date, snapshot v1/demo=false, deduplication, SQLite restart | Unconfirmed |
| Match context / standings | /v1/qa-stored/match-context | Canonical id, coverage, available/unavailable table persisted; old LIVE stays stale; score corrections | Unconfirmed |
| Lineups / stats / timeline | /v1/qa-stored/match-detail | Canonical id, object DTO, cached restart; merged canonical incidents | Unconfirmed |
| LIVE | Snapshot observations + existing scoped Realtime | Local freshness, deletion/reconnection/lifecycle regression suites | Realtime outside session HTTP counter; keep disabled until separately authorized |
| Photos / crests | Existing verified entity media + disk cache | Existing persistent cache/eviction/invalid-photo regressions | CDN outside central API counter; cache-only until bounded separately |

Central API policy: 15 minutes / 30 total / 8 rolling minute / 2 simultaneous. STOP/expiry seal navigation, missing acknowledgment fails closed, no redirect or ordinary-route fallback. Existing loopback tests exercise all limits. The adapter is NOT registered in repositoryProvider; connected execution remains disabled. The existing offline +35 APK is unchanged and cannot be converted through a JSON file.

Synchronization uses current scoped snapshot/revalidation and Realtime semantics; no invented server delta/cursor contract was introduced. Existing cache regressions cover old replies versus newer persisted data, shared flights, cache-first emission, restart and background suspension. Request counts are test-observed, never attributed to production or GOAL.

## Measured local evidence

Initial new LIVE socket run: four requests, 2032 serialized response bytes including the 503 body; server handler times 18180/1113/1184/1412 microseconds. These are local handler times, not screen, Android, Internet or TLS latency. The failed request is counted and there is no automatic retry. Correction 2–1 → 1–1 accepted with a fresh observation; a 20-minute-old observation stays stale despite a new response envelope.

Existing end-to-end cache test measures three stored HTTP requests, two shared flights, maximum two concurrent and zero HTTP attempts on offline repository/SQLite restart. Its counters and file size are emitted by the test; see run log for this execution.

## Operational boundaries

No ADB diagnostics, controller changes, device installation/opening, backend queries, provider requests, APK generation or production changes. No product bug demonstrated by the new LIVE scenario, so no speculative Flutter fix. This change supplies reusable local verification rather than claiming physical QA.

GO for local development. NO-GO connected until Claude confirms actual passive stored-reader deployment/side effects and current health, controller activation is authorized and ready, and a connected artifact is approved. One session covers the route set; no per-screen gates.

## Regression evidence map

- LIVE freshness and recovery: mobile243_stored_contract_test, qa_stored_read_loopback_test, mobile229_live_transition_test, night230_live_delete_race_test, live_realtime_test.
- Available/missing/unavailable/pending/error standings: mobile243_stored_contract_test, mobile239_standings_test, standings_overall_table_test, standings_current_phase_test.
- Scoped cache reconciliation and lifecycle: public_offline_cache_test, night230_passive_real_cache_e2e_test, calendar_prefetch_test, match_prefetch_local_only_test.
- Match Center navigation/errors: flow_test, historical_match_center_test, mobile_history_performance_test.
- Persistent photos: sports_image_cache_test and entity_avatar_canonical_cache_test (restart, invalid/corrupt media, canonical isolation, expiry and eviction).
- Full suite includes golden comparisons; no reference image updated.

Test-development failures were confined to the two new table fixtures: incomplete match/team/competition references were correctly excluded from the public cache. Fixtures were repaired, never the production guard. One overlapping Flutter invocation hit a Windows sqlite3.dll lock; subsequent Flutter runs were serialized. Initial failing logs remain retained rather than overwritten.

Connected variant preparation is source-only: the existing interceptor and tested loopback DTO path are retained, but repository wiring and connected controller mode deliberately stay inactive pending backend confirmation. No production origin, credential, approval file or runnable connected APK was created. This is not a claim that connected +35 is ready to install.

Validation so far: the three new regressions pass together after fixture completion; analyze exits 0. Full-suite earlier executions exposed only the new incomplete fixtures (1433 passed, two fixture failures); the final complete-fixture suite is recorded separately in apps/mobile/artifacts/mobile243/suite-verified.log with its explicit exit file. Do not interpret an initial failing log as a product regression or silently discard it. Final measured LIVE handler sample: 10716/3238/3634/3474 microseconds, four requests and 2032 bytes. Existing file-backed end-to-end sample: sqliteBytes=61440, storedHTTP=3, sharedFlights=2, maxConcurrent=2, offlineHTTP=0.

## Final validation

- Full Flutter suite including goldens: 1434 PASS / 1 FAIL in 16:06. Sole failure: existing historical-cache test assumed the request interceptor had run after a fixed 50 ms; under load it had not. No golden failed and no baseline was updated.
- Repaired that test using bounded explicit local-emission and request-start signals, retaining assertions and adding finally cleanup. Subsequent focal run (historical performance + new stored contracts + session loopback limits): **29 PASS, 0 FAIL** in 1:09. This includes the exact previously failing test. Full suite was not rerun again after this isolated test-only repair; do not label that full run green.
- No app/runtime behavior changed or APK generated. New deliverable is the reusable fixture server and executable integration regressions. No functional app defect was reproduced in this cycle.
- Exact retained logs: apps/mobile/artifacts/mobile243/suite-verified.log, focal-final.log, analyze-verified.log, and corresponding .exit files. Local artifacts remain untracked.

Final flutter analyze: no issues found (21.6 seconds), exit 0. git diff --check clean.
