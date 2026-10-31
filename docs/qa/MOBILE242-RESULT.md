# MOBILE 242 — bounded ADB recovery and connected readiness

Base: `codex/recovery-241` at `8a1fdb4d3a1581ebdc37e0d90e059f898a276a0d`.
Branch: `codex/mobile-242`. Evidence captured 2026-10-31 UTC.

## Result

NO-GO connected. ADB is accessible intermittently, not demonstrably stable within existing safety deadlines. No application opened, APK installed, production queried, controller modified or shared ADB server restarted.

## ADB evidence

- Shared server PID 13360, owner EMANUEL-PC\hen_g, official Android SDK platform-tools, listening on 127.0.0.1:5037. A QA123 client also used this server; it was left intact.
- Client platform-tools 37.0.1; client/server protocol both 41. No active competing SDK version demonstrated. ADB absent from PATH; explicit SDK executable works.
- Samsung composite USB and Android ADB interfaces reported OK. Raw server metadata identified RF8R32GQWGL, device, SM_A325M.
- Native bounded get-state returned device in 7462 ms. Model shell query timed out. Package query returned versionCode 35, UID 10319 and existing first-install time 2026-10-30 00:42:17 in 3046 ms. pidof returned exit 1 with empty output in 3285 ms: no QA process at that observation.
- Several independent metadata queries timed out. TCP listening/USB OK alone does not establish responsive shell access. Exact internal cause of delay remains UNKNOWN; no evidence establishes a hardware, permission or SDK mismatch cause.
- Eight seconds was used solely as a diagnostic ceiling. Existing five-second aggregate readiness budget and watchdog deadlines were not relaxed. Only owned temporary clients/sockets were closed on timeout; shared server and controller processes were untouched.
- Initial diagnostic host:version recorded complete data at 8003 ms. Final helper explicitly rejects responses delivered after the deadline; this initial observation is not READY evidence.

## Local changes and validation

Added a dependency-free loopback smart-socket diagnostic allowing only host:version and host:devices-l. No shell, transport selection, server restart or device writes. Fragmented/incomplete/late/oversized replies fail closed.

- Diagnostic regressions: 7 PASS.
- Flutter connected loopback contracts: 11 PASS; fifteen-minute expiry, 30 requests, eight per rolling minute, two concurrent, STOP, reconnect, stale LIVE, redirects/writes/fallback rejection.
- Existing synthetic controller policy: 42 PASS; heartbeat ownership: 8 PASS; trial ownership: 9 PASS.
- Flutter analyze: no issues found.

These are local/synthetic validations, not physical navigation or current backend health measurements. Logs are in artifacts/mobile242 and apps/mobile/artifacts/mobile242 (untracked local evidence).

## Controller integrity

At 19:35:05 UTC QA123 task Running, launcher PID 13888, DISARMED; heartbeat age 4.4 seconds. No active-window, development approval or failsafe READY file. Task XML matches the MOBILE239 backup. Launcher SHA256 3678C9BFE26EBA0FE664C96BC29522883B7EF30B682046DE70F350CBB9D54258; failsafe SHA256 FF77E7029905A67F2FC59DD69B58CE09B2C29A5124B68F15DDAF83D7E140844A. No runtime changes required restoration. Restoration regressions are synthetic; no live suspension/restoration exercised here.

## One connected session prepared, not activated

Reuse `RECOVERY241-CONNECTED-READINESS.md` and its route matrix: one supervised session, 15 minutes / 30 central API queries / 8 per rolling minute / 2 concurrent. Only the three stored-read routes; no ordinary-route fallback. Image/CDN and Realtime traffic are outside this counter and must remain disabled/cache-only or separately bounded. Missing data remains NOT VERIFIED.

Remaining prerequisites:
1. Stable ADB satisfying existing readiness/closure deadlines; a live launcher alone is not watchdog READY.
2. Backend operator confirms deployed passive stored-read contract, current health and no active STOP. Historical backend evidence is not current GREEN. No production verification performed.
3. Authorized connected artifact and reversible controller activation: installed +35 is compile-time offline and connected mode currently fails closed. JSON approval cannot convert it to a connected build.

No gate, authorization, READY or connected session was fabricated. Offline APK and device data were preserved. Next action: obtain backend contract confirmation while resolving host/USB latency using isolated diagnostics, then perform the existing single-session preflight; do not create gates per screen.
