# FutBeat — Autonomous Mobile 244

Base: `codex/mobile-243 @ d9fe682`. Integration branch:
`codex/autonomous-mobile-244`. Application source: `546615f2`.
Started 2026-10-31 20:40 UTC. Actual end/time and artifact result are recorded below;
this is not a claim of 12–24 hours of execution or future unattended work.

## Delivered behavior

| Area | Verified local improvement |
|---|---|
| LIVE | Realtime uses the HTTP Date-derived server offset. Fresh frames remain fresh on a phone clock skewed ±2h; replayed observations remain stale; old revisions cannot restore a corrected goal. |
| Match Center | A failed empty timeline shows a connection error instead of a verified absence of events. Canonical timeline-player taps reuse the local lineup panel when one exact roster row exists; ambiguous/missing rows retain profile fallback. |
| Feed | Equal kickoffs use a canonical-ID tie-break. Fixture dedup compares only matching competition/home/away buckets, preserving evidence precedence, real second matches and survivor positions. |
| Tables | Missing/malformed position is unknown, never array index + 1. Duplicate canonical teams within a group fail closed; legitimate phases and homonyms remain distinct. |
| Personalization | Hour-format loading/error no longer blocks local country, favorites, team, player and alert navigation. Both settings and preferences have scoped retry. |
| Photos | Rejected/redirect bodies are cancelled rather than drained forever. A 15-second total deadline bounds the owned HTTP fetch, retaining byte, redirect, idle, HTTPS, canonical identity and disk-cache bounds. |
| Notification dry-run | Explicit outbox ID deduplicates delivery retries with separate bounded shown/opened sets. A banner can still be tapped; a distinct correction notification is not suppressed. No Firebase/FCM enabled. |

There is no new backend, player store, provider, auth mechanism, controller or
tracking system. The speculative queued-prefetch generation change was omitted:
the corrected race test passed before that change. The regression is retained as
coverage of existing cancellation, not represented as a new fix.

## Evidence and measurements

- Full Flutter suite: **1,474 PASS / 0 FAIL**, 2:40, including golden comparisons.
- `flutter analyze`: **no issues**, 14.9 seconds. No golden reference changed.
- Before the fixes: both skewed-clock assertions failed; three new timeline/panel
  assertions failed; five rejected/redirect image-body cases timed out. These
  assertion failures are retained in `artifacts/244/before*.log`.
- Initial integration exposed a missing test import, a leaked semantics handle
  and an invalid synthetic drag velocity; fixtures were corrected without
  weakening assertions. Subsequent full suite passed.
- Same synthetic feed input: 3,300 rows -> 3,000 retained. Baseline dedup sample
  307,738 µs; revised samples 53,167 and 44,882 µs. Local Windows host measurements,
  not A32 latency or a universal complexity guarantee. A single pathological
  bucket can still require quadratic comparisons.
- Retained file-backed cache end-to-end test: 3 stored HTTP calls, 2 shared
  flights, maximum 2 concurrent, 0 HTTP attempts on offline SQLite restart;
  61,440-byte test database. Canonical timeline remains 25 merged events / 22
  detail incidents. The distinction was already established, not reconstructed.
- Session limits remain 15 minutes / 30 central API calls / 8 rolling-minute /
  2 simultaneous. Loopback tests cover STOP, expiry, reconnect, rejection of
  redirects/writes/missing acknowledgment and no ordinary-route fallback.

Source commits: `bfab067a`, `42fc20d2`, `51ce8ee0`, `f88d6555`, `cd92cf19`,
`7ec817b0`, `0c90395f`, `546615f2`. Worker implementation commits remain in their
isolated branches; integration used scoped file patches after review.

## Operational boundaries

QA123 was not changed or suspended. Read-only check: task Running, DISARMED,
heartbeat recent, original launcher/failsafe hashes preserved, no active window
or failsafe READY. One bounded ADB metadata check identified RF8R32GQWGL,
SM_A325M; device-list response took 2,490 ms. This does not prove reliable shell
access or closure performance. No application was opened and no device data was
modified. No physical screenshots, screen latency, cold-start memory measurements
or physical verification of these new changes are claimed.

Connected mode stays disabled. Claude's API-CONTRACTS/BACKEND-HANDOFF files were
still preparatory when read. Historical health is not current GREEN. No Supabase
query, GOAL call, deployment, migration, cron change or real notification occurred.

Remaining backend prerequisites: actual deployed passive reader and ACK,
canonical/coverage parity, absence of deferred hydration, current health and
incompatible-operation confirmation. Image CDN and Realtime are outside the
central API counter and need their own authorized bounds before connected QA.

Notification dedup is router-lifetime only, bounded to 128 IDs per channel;
corrections require distinct outbox identity. No ID is inferred from message
text, match names or player names. Disk-cache revocation still requires callers
to stop supplying revoked URLs, as before.

## Release result

Offline QA +36: build PASS (367.0 seconds). Artifact:
`artifacts/244/futbeat-qa-1.0.0+36-local-cache-546615f2.apk`.
SHA-256: `81B1C4EF5B09C1C39570B0837E18D73F14BAFA6A0B747FC650B140897CA9A5E4`.
111,117,388 bytes; package com.futbeat.futbeat.qa; versionName 1.0.0; versionCode 36.
Debug certificate SHA-256: `6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362`.
Manifest and all four arm64 ELF libraries verified. DEMO=false, local-cache-only,
API http://127.0.0.1:9, empty API token, OAuth/Push/Ads off, QA diagnostics on.
The Kotlin daemon connection warning recovered without changing dependencies
or stopping any shared service. Native-access/KGP future-upgrade warnings remain.

Physical precheck at 21:04:49 UTC: get-state returned device in 1,012 ms; model
read exceeded the existing 3-second deadline. Whole pass stopped at 4,166 ms,
without arming, installing or opening the app. No shared ADB restart. The
owned timed-out client alone was terminated by the existing bounded helper.
Thus physical QA is NOT VERIFIED, not PASS; no physical captures exist this shift.

Publication: MOBILE243 baseline published as its own branch, never main;
SHIFT244 Draft is dependent on that base. The existing CI filter now also accepts codex/mobile-243 (one-line change);
YAML, exact base list, unchanged jobs and read-only permissions validated with
the already installed Dart YAML parser. Real CI remains pending until observed;
local success is not real CI success.
No connected artifact is authorized, generated or installed. Original +35 stays
intact. A review Draft must depend on MOBILE243; a direct PR against main would
include hundreds of unrelated historical files. No merge is authorized.

**GO local development; NO-GO connected activation.** Next priority after offline
artifact verification is physical offline confirmation with genuine watchdog
READY, then separately authorized passive connected QA after backend handoff.

CI preparation commit: `07e9443`; no job, deployment or permission change.
Physical data and +35 preserved; QA123 remains untouched and DISARMED.

## Checkpoint and continuation 2026-10-31T21:36:04.231Z

MOBILE244 did not stop at 21:06 UTC; work continued on real CI and then MOBILE245.
PR Draft: https://github.com/henguido/FutBeat/pull/234. Initial real CI run
41242084480: contracts SUCCESS (backend unchanged; npm suite skipped), mobile
1457 PASS / 11 FAIL. All eleven failures are golden comparisons across 18 PNGs.
Three inspected pairs differ along glyph/icon edges with unchanged visible
content; this does not prove the OS/font cause. No references, thresholds or
existing test exclusions were changed.

A same-runner exact-base diagnostic is now prepared: fresh pinned baseline,
actual tested merge SHA separately from PR head, Flutter/lock/font metadata,
byte-for-byte comparison of actual and master PNGs with nonempty complete
relative-path sets. Original golden check stays failed even when attribution
matches. Eight comparator regressions PASS, YAML structural validation PASS,
native Git Bash syntax PASS. Real baseline comparison is not yet asserted.

Four inspected local fixture PNGs are in artifacts/244/previews/: timeline,
canonical player panel, timeline network error, and unknown table rank. The
preview runner passed; these are not A32 screenshots or golden replacements.

Execution recovery: plain CMD and direct installed Python/Dart executables work;
WindowsApps Python alias and default app-container temp caused access errors.
The same eight assertions passed with stdlib Python and workspace-owned temp.
No system security, antivirus, shared process or SDK configuration changed.

MOBILE245 continuation is active in this session with three isolated agents.
A requested persistent heartbeat was rejected by automatic approval review:
explicit user approval is pending; no scheduler was created and no future
12-hour execution is promised. Operational checkpoints are separate from QA
gates and cannot authorize connected activity.
