# MOBILE239

Base: `codex/night-mobile-230` at `2abf911`. Isolated worktree:
`F:\FutBeat\FutBeat\.codex-worktrees\mobile-239`, branch `codex/mobile-239`.

## Functional changes

- `36cd271`: retain the last LIVE score, preserve observation age, reject
  republishing/receipt time as renewed evidence; warning expires locally and
  rechecks on resume. Terminal and revision guards preserved.
- `a13c142`: distinguish pending, missing, temporary error, confirmed absence
  and stored standings; retain phase/group/season selection.
- `cfcd5ba`: one visible owner per canonical favorite fixture, with all other
  matches retained in their leagues. This intentionally replaces the older
  duplicate-in-favorite-and-league rule, as requested by MOBILE239. Existing
  country/competition priorities and date/LIVE reset reused.
- `4628d0d`: unknown LIVE observation does not introduce context polling:
  regression failed with 4 reads, then passed with 1 over two synthetic minutes.
- `827c6b7`: show freshness on the initial Match Center facts tab and all other
  tabs, not just the LIVE tab.

No lineup redesign, new providers or invented data. Photos, canonical identity,
cache/preload budgets and existing timeline were retained.

## Validation

Final Flutter suite: **1,429 PASS, 0 FAIL**, including goldens. `flutter analyze`
clean. No golden PNG reference changed. The old fresh-LIVE visual fixture now
states its freshness explicitly; stale/unknown cases have separate tests and
a saved rendered preview. SQLite close/reopen, score correction, out-of-order
revision, terminal after disconnection, expiry and resume covered locally.

Source logs: `apps/mobile/artifacts/mobile239/suite-delivery.log`,
`analyze-delivery.log`, `no-poll-before.log`, `no-poll-after.log`.

Controller regressions: heartbeat 8 PASS, probe budget 3 PASS, actual bounded
process wrapper 6 PASS. A Windows fixture cleanup failure was fixed with a
bounded retry after the verified child exits; no safety checks were removed.

## APK

Final app source **827c6b7**; host/test/documentation commits may follow.
`artifacts/mobile239/futbeat-qa-1.0.0+35-local-cache-827c6b7.apk`.

- Package `com.futbeat.futbeat.qa`, version 1.0.0+35, arm64, debug signature.
- SHA-256 `62033802724A935BB3325C20ACED42823EB70355E3110ACB009F8BCAC6D6E4A8`.
- 111,110,004 bytes. Signer SHA-256
  `6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362`.
- Required Flutter, Dart JNI and SQLite ELF libraries verified.
- DEMO=false, local-cache-only=true, diagnostics=true; Ads/OAuth/Push disabled.
  QA API origin is `http://127.0.0.1:9`; HTTP creation is blocked by the existing
  fail-closed offline policy. QA App Links remain isolated.
- Earlier +34 and intermediate +35 artifacts retained, not overwritten.

## Performance and limits

Host-only single-run microbenchmark, same probe before/after: 50,000 freshness
checks 76,548 → 85,452 microseconds; SQLite median 224 → 231 microseconds,
p95 391 → 458 microseconds. Process RSS 147,738,624 → 140,980,224 bytes.
These are noisy desktop samples, not Android latency/RAM or a speedup claim.
The new parsing adds measurable host CPU overhead but no I/O.

Physical captures/diagnostics and restoration evidence are in
`artifacts/mobile239/physical` and `artifacts/qa239`. Earlier attempts are
preserved separately. Only physically visible screens may be marked PASS.
The supervised 15-second waiting interval in the runner is NOT startup latency.

### Galaxy A32 — final APK 827c6b7, exclusively offline

Final run: 31 October 2026, approximately 12:38–12:39 Costa Rica (18:38–18:39
UTC). Existing QA228 procedure, genuine READY, independent watchdog and
bounded supervisor pulses; no new Windows task. Earlier runner errors (wrong
activity shorthand, multiline Android resolver output, synchronous start wait,
and the accessibility tab suffix) were corrected locally, not attributed to
Flutter. Their evidence was preserved; they are not PASS navigation.

| Check | Result / evidence |
|---|---|
| Installed artifact and preserved data | PASS: versionCode 35, UID 10319 and firstInstallTime 2026-10-30 00:42:17 unchanged |
| Feed from saved data | PASS: `physical/01-feed.png` |
| Everton–Newcastle 3–1, header/scorers, saved statistics and crests | PASS: `physical/02-match.png` |
| Table tab / absence message | PASS presentation: `physical/03-table.png`; actual standings positions NOT VERIFIED (none available in this saved context) |
| Background / resume on the same table | PASS: `physical/04-resumed.png` |
| Fresh/revoked-age LIVE observations, correction and offline final | Automated regression PASS; live physical updates NOT VERIFIED (finished cached fixture) |
| Lineups/player panel/complete timeline | Not repeated: no changes to those views; not claimed as new physical coverage |
| Final closure/restoration | PASS: PID absent, original XML/files/ACL verified by existing restoration, owned fresh DISARMED heartbeat; Wi-Fi restored to 1, mobile data to 0 |

Actual match process PID 20343: one SQLite detail hit at **1,649 ms**, three
memory hits, seven blocked HTTP-client creations, zero observed httpSuccess
or overflow messages in the bounded diagnostic sample. This is not a packet
capture or a complete feed request count. Network absence was checked before
each capture; blocked attempts are not completed requests.

Android reported the match process first display as **5.439 s**. Match Center
debug memory sample: PSS **464,197 KiB (~453 MiB)**, RSS 556,089 KiB. No
controlled +34 device baseline was repeated; do not claim a speedup or release
memory performance. Precise feed, image-load and timeline latency remain
NOT VERIFIED in this run. Profile-mode memory/latency is a concrete next task.

**GO for local offline review. Connected QA remains unauthorized.** The final
APK is installed but closed. QA123 is Running/DISARMED, configuration restored;
no offline approval or active session was left armed.

No connected QA, Supabase access, provider consumption, push, merge or
deployment. Backend timestamp limitations: `docs/integration/MOBILE239-LIVE-OBSERVATION.md`.
