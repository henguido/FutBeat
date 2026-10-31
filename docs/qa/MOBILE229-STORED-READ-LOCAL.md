# MOBILE 229 — stored-read transport validation (local only)

Status: GO for local contract review/tests; NOT activated or approved for production.

## Candidate API and dependencies

The staged mobile interceptor rewrites only GET /v1/calendar, /v1/match-context and /v1/match-detail into the /v1/qa-stored namespace. Unknown paths, ordinary retries, writes, other origins and redirects are blocked. It is deliberately not installed in repositoryProvider. QA123 still accepts only cache_only approvals; this work changes no tasks or approval files.

The central API delegates this namespace before normal demand-aware processing, guarded by FUTBEAT_QA_STORED_READS_ENABLED (disabled by default). The candidate handler calls only:

- futbeat_read_qa_stored_calendar (candidate SQL file, not a migration)
- futbeat_read_match_context
- futbeat_read_match_detail
- futbeat_read_lineup_player_media (one bounded set lookup)
- futbeat_read_match_videos

Repository SQL definitions of these readers use stored payloads and stable read functions. The calendar candidate intentionally avoids futbeat_read_calendar_range, which may register materialization demand. The existing PGlite test executes the candidate calendar in a read-only transaction, including expired and missing payloads, and verifies no cache rows added/removed.

This is evidence about this Git source, not a claim about deployed definitions. Claude must verify the exact deployed function chain and reviewed candidate endpoint before enabling connected QA. No remote queries, migrations, activation, provider requests or controller deployment occurred.

## Demonstrated client corrections

1. Missing stored-contract acknowledgment previously only set _closed and left another request running. It now calls close(), cancelling all owned requests. The regression run with the previous behavior failed after 8 seconds with receiveTimeout instead of cancellation; the correction passes.
2. The client previously had no session expiry. It now rejects durations outside (0, 3 hours], seals requests/payloads at expiry, and uses a timer to cancel pending sockets even when the server never responds. The timer is released when no requests remain and on close.

## Actual local validation

- Flutter: 15 PASS (8 new socket tests + 7 existing QA policy/SQLite tests).
- Backend: 5 PASS (4 existing handler/PGlite + 1 new loopback HTTP test).
- New socket tests: 60 session requests, 12 per sliding minute, at most 2 simultaneous; third concurrent request never reaches server; STOP cancels both; missing ACK cancels pending; expired payload rejected; pending request cancelled by a 300 ms session expiry; redirect never reaches ordinary route; writes and hydration paths blocked.
- The backend loopback test records exactly seven HTTP requests, only four allowed stored RPC calls, and zero RPC calls for rejected requests.

Socket tests bind only 127.0.0.1 on an ephemeral port. A test-only wire adapter translates the production HTTPS request to that local HTTP listener after interceptor validation; it cannot reach another host/port. Production HTTPS policy is unchanged. Actual TLS is NOT VERIFIED by this test: the local TLS certificate could not be pinned/verified in this environment, so the experiment refused it. The reason for the certificate discrepancy was not independently established. No certificate bypass or test private key is committed.

## Activation checklist for Claude

Verify deployed reader definitions and dependencies are read-only; inspect candidate SQL grants (service_role only); review central API dispatch and disabled default; approve explicit host/route namespace and three-hour session limit. Keep the independent watchdog, restoration and expiry. Review image network access separately: this interceptor counts the three API reads only and is not a global image traffic limiter. Do not treat local handler tests as authorization to enable production.
## Follow-up: guard startup is not guard readiness

The subsequent offline trial reported QADEV_STARTED before there was any evidence that the independent child had entered its guard loop. The app later required manual closure. A live child PID alone cannot establish protection. The archived pending-close record lacked the exception detail, so the exact original close failure cannot be reconstructed from that generic record.

The staged launcher now waits for an identity-bound READY record (session, nonce, child PID and timestamp) emitted only after the guard passes its full policy/heartbeat checks. Startup may wait at most 180 seconds with the app still closed and controller heartbeat maintained. Normal readiness freshness stays 15 seconds; neither the 8-second failsafe heartbeat limit nor the normal policy TTL is enlarged. Missing/stale/wrong readiness blocks opening and ends an existing exemption. The failsafe refreshes its time after slow policy probes before comparing the current heartbeat; this avoids comparing a newly written beat against time captured before those probes. Pending-close records now include the actual exception/reason, and the candidate close probes use 1500 ms bounds.

Validation: 11 pure readiness tests PASS, 42 existing policy tests PASS, four staged mock-ADB DryRun tests PASS including readiness emitted only for valid guard state. Generated scripts parse successfully. These changes are candidates only and are not a claim of physical closure or a permanent QA123 update.
A second timing regression was reproduced synthetically: a valid heartbeat written during slow probes can be newer than the time sampled before those probes. Staged callers now inject a real clock sampled after re-reading approval, STOP/state and the latest heartbeat; existing explicit-Now tests remain deterministic. Guard-readiness also samples the injected clock after reading its record. No future or stale tolerance was added. Seven clock/probe tests and thirteen readiness tests pass; STOP, revocation and mode changes during a probe remain denied.