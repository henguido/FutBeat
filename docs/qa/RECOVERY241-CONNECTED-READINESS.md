# RECOVERY241 / MOBILE240 — recovery and connected QA preparation

Base `codex/mobile-239 @ bfbfe27`, isolated branch `codex/recovery-241`.
No APK built/installed, app opened, provider call, production query, process
termination, controller change, deployment or gate creation.

## Windows recovery

Fresh terminals with explicit repository working directory and no profile
successfully execute Windows PowerShell, PowerShell 7, CMD and Git. The prior
global tool-session stall did not recur; its original cause is not proven.
The old default working directory still exists, so it is not established as
the cause. No reboot, global cleanup or shared-process kill was needed.

Bash through the tool shell selector returned WSL E_ACCESSDENIED. A separate
direct invocation of Git's actual usr/bin/bash.exe exited with 0xC0000142
(DLL initialization failure); the responsible DLL/resource is not identified.
Neither issue prevents PowerShell-based work. Other agents' existing Bash,
Claude, Codex and ADB processes were observed and left alone.

ADB client get-state timed out at 3 seconds. An independent, read-only ADB
host:devices-l query connected to localhost:5037 but timed out reading its
reply at 1 second. This does not prove a phone/cable fault. No kill-server or
server restart was attempted: the ADB server is shared. Current device/PID
state remains UNKNOWN; this task never opened the app. QA123 is Running,
DISARMED, with a recent heartbeat. Android physical readiness is NOT established.

## Evidence scope and deployed contracts

Claude's local inputs:

- recovery-03/night230/agent-e/MATRIX.md and HANDOFF-CODEX.md;
- recovery-03/night230/agent-e/verify_readonly.sql (prepared, NOT executed here);
- recovery-03/FUTBEAT-NIGHT-BACKEND-230.md;
- recovery-03/FUTBEAT-BE-238.md.

Night230 reviewed +33, not +35. It infers futbeat-api v43/99ad5aa5 from older
deployment evidence; that is not a current verified fingerprint. BE-238 records
L237 applied at 18:04:33 UTC and health at 18:17 UTC, with quota 96 at that
snapshot. None is a current health/GO assertion. The old Q229-pending statement
is superseded by MOBILE239 context (Q229 v2 applied); do not replay its kit.
Global-ingest v44 and futbeat-api v43 are different functions/versions.

## Route matrix

All production status below needs Claude's current confirmation. Local source
and mock/read-only SQL tests are evidence of candidate behavior, not deployment.

| Routes | Classification | First strict stored-read session |
|---|---|---|
| /v1/qa-stored/calendar | Candidate stored-cache reader; no materialization/request RPC | Only after deployment/function-chain/flag/header verification; miss is not a hydration request |
| /v1/qa-stored/match-context | Candidate stored context/standings | Same condition; no request_terminal_result or request_match_standings |
| /v1/qa-stored/match-detail | Candidate stored detail/media/videos | Same condition; no request_lineup_hydration or profile demand |
| /v1/calendar | Materializes cache; partial coverage can register calendar demand | Excluded as ordinary route |
| /v1/match-context | Requests results and standings | Excluded as ordinary route |
| /v1/match-detail, including request=0 | Can request lineup/media hydration | Excluded as ordinary route; request=0 is NOT a passive guarantee |
| match-preview, search, team/player entity | H2H, search, squad/profile demands | Excluded |
| team-matches | Can request backfill on last results page | Excluded |
| match-h2h without extend, team-context, standings-form, favorites, competition entity | Passive according to reviewed historical source | Not in stored adapter allowlist; no implicit expansion without contract review |
| explore | Own-cache writes, no direct provider demand in reviewed source | Not strictly read-only; excluded |
| snapshot | Read-only according to source, but heavy | Excluded |
| live_match_updates SELECT / filtered Realtime | Passive according to reviewed source | Separate channel/REST budget and SQL/RLS verification needed before enabling |
| auth, push registration, follows sync, history extension | Writes/demands | Excluded |
| news / player suggestions | Historically absent in v43; current state unverified | Excluded from first walk; no inference from newer Git code |
| Image/CDN downloads | Outside the central Dio adapter budget | Separate verified-host/rights/traffic decision; do not claim these are covered by the API counter |

The local stored handler has a disabled-by-default feature flag and no normal
route fallback. Its allowed RPC chain is: futbeat_read_qa_stored_calendar,
futbeat_read_match_context, futbeat_read_match_detail,
futbeat_read_lineup_player_media and futbeat_read_match_videos. Claude must
verify the deployed definitions and transitive effects, not just STABLE labels.
The current local normalizer emits videos but omits coverage.videos; the stored
snapshot path does not perform the normal API nationalTeamCode decoration.
These parity limitations remain for backend review; they were not silently fixed.

## Proposed single-session budget and walk — NOT activated

15 minutes absolute, at most 30 central HTTP requests, 8 per sliding minute,
2 simultaneous; limits also count failed attempts. No automatic retry after
loss of connection, no budget reset on resume, no ordinary-route fallback or
redirect. Existing interceptor maximum remains 60 / 12 / 2 / 3 hours; the
stricter proposed values are explicitly tested. They are not wired into an APK.
The transport test proves no retry introduced by the interceptor. The app's
existing bounded repository revalidations are separate: a future session
integration must pause/cancel them when health/connectivity becomes unknown.
This document does not claim that operational pause has been activated.

Budget allocation: 6 feed/calendar, 12 context/detail, 4 controlled recovery/
resume, 8 reserve. Stop at the global cap even if a step remains NOT VERIFIED.
Budget does not include independently monitored Realtime or image transports;
those must stay disabled/cache-only or get a separate reviewed bound.

One identity-bound session approval (window, nonce, exact connected-artifact
SHA, expiry, budgets) covers the entire walk, not one gate per screen:

1. Claude supplies fresh scoped health and exact deployed read-contract proof.
2. Verify device, APK, no competing session, QA123 backup and independently
   READY watchdog before any launch. A process PID alone is insufficient.
3. Open feed once, select at most one second stored date; no date sweep/refresh.
4. Open one preconfirmed fully stored canonical match; inspect facts,
   chronology, lineup and table. Missing data is NOT VERIFIED, never hydration.
5. Pause/resume once. If connection is lost, pause navigation; require fresh
   health/unchanged approval before explicit continuation under the SAME budget.
6. STOP/expiry/lost supervision/unknown health: cancel owned requests, force-stop
   QA, confirm PID absent. If ADB fails, closure is NOT CONFIRMED. Restore
   original QA123 XML/files/ACL/heartbeat and original connectivity only after
   confirmed closure, using the existing reversible procedure.

The operational entry point Get-QaDevelopmentDecision explicitly rejects
stored_only as connected_mode_not_activated, even though the pure lease validator
has stored_only health checks. Changing approval JSON is NOT sufficient and
must not be used to bypass that block. A reviewed, separately authorized
integration is needed; no controller or approval was changed here.

## Validation and concrete requirements

- Flutter focal transport/freshness tests: 24 PASS, including the three new
  regressions for disconnect/reconnect with unchanged budget, 30/8/15 limits,
  and old LIVE observation despite a newly acknowledged stored response.
- Backend candidate: 5 PASS (handler allowlist, loopback, calendar SQL in a
  local PGlite read-only transaction). No remote SQL was run.
- Existing QA policy: 42 PASS, synthetic decisions only; no task/ADB changes.
- flutter analyze clean; no broad Flutter suite or physical offline QA repeated.
- Test-only HTTPS-to-loopback translator now preserves original RequestOptions
  identity when forwarding network errors. Otherwise the harness itself falsely
  retains a concurrency slot. Production transport code is unchanged. TLS was
  not tested against production; loopback is explicitly test-only.

Claude pending: current API/source fingerprints; actual stored-reader availability
and flag; RPC-chain/side-effect evidence; coverage/selection/video parity; current
health and incompatible operations; attribution of demand/GOAL changes. Strict
stored-read mode expects zero QA-originated provider demand, including deferred
work. If attribution is unavailable, report UNKNOWN, not measured zero. Legacy
45-minute/40-GOAL guidance is a different demand-generating mode, not permission
for this session. Its historical quota threshold is not a fresh preflight.

The original +35 APK remains offline-only with loopback API origin and blocked
HTTP. Its SHA is unchanged:
62033802724A935BB3325C20ACED42823EB70355E3110ACB009F8BCAC6D6E4A8.
No existing connected +35 artifact was verified. Variant/build/installation
authorization must be resolved separately; no new APK was generated here.

**GO for continued local work; NO-GO for connected execution now.** Remaining
requirements are ADB responsiveness, verified/approved stored backend and
controller integration, and an explicitly authorized connected artifact/session.
