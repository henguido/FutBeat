# MOBILE245 — continuation of AUTONOMOUS244

Application/build source: ca59ffefd8c27ab8bd9feea2b4f82645b8d29912, based on MOBILE244 3977bc7.
Branch: codex/mobile-245. Draft: https://github.com/henguido/FutBeat/pull/235 (base codex/autonomous-mobile-244 / Draft234).

## Verified results

- Final full Flutter suite: 1554 PASS / 0 FAIL (91 seconds), including unchanged local golden references.
- Final flutter analyze: no issues (10.5 seconds). Diff-check PASS.
- 68 focused new cases passed; seven passive-contract, two STOP and three notification cases were added subsequently (80 new cases over MOBILE244). No claimed identical before/after test count: first48 cases produced14PASS/34FAIL before corrections.
- Passive404: five attempts before, one after; during refresh five before, two after. No ordinary-route fallback or fabricated availability.
- STOP: four/three post-cancellation blocked attempts before, zero after. Cache remains visible. 42 targeted contract/completeness cases PASS.
- CI YAML structure/read-only permissions and Bash syntax PASS. Existing test exclusions/thresholds/references unchanged.
- No production connections, backend/SQL changes, device installation or QA123 changes.

## Functional changes

1. Validate snapshot freshness and explicit match identity before accepting media, redirects, UI or SQLite writes. Keep legacy missing-ID/unavailable response compatibility.
2. Prevent old account-generation/preference acknowledgements from clearing newer unsynced edits. This is not a transactional CAS guarantee for every arbitrary storage race.
3. Validate complete score pairs and finite nonnegative integral numbers consistently with per-side scorer caps.
4. Follow only bounded explicit canonical redirects for timeline player navigation; preserve raw fallback for missing/cyclic/ambiguous/presentation-only aliases. Never merge by name.
5. Reject contradictory Apertura/Clausura tables hidden by generic stages; accept the narrow exact matching phase contract without accepting final/subgroup ambiguity.
6. Preserve valid LIVE overlays when malformed bootstrap data is not proof of deletion. Same-date selection keeps collapsed groups and avoids redundant calendar reads.
7. Settle exact acknowledged passive-detail404 and stop scheduling cancelled requests without inventing data or changing ordinary error retry policy.

## Local commits

b4867a1b cache/media/detail identity;108eb690 preference races;25621af2 scores/redirects/phases;ed962e98 partial LIVE/date selection;290baae7 test style;e1762198 passive404;2f9002cb test style;87fae54 stacked CI;2439045 initial report;ca59ffef STOP cancellation.
241c08de adds three test-only notification identity/retention/startup cases;46 notification cases PASS, no FCM/source/APK changes. Application-source diff between ca59ffef and that commit is empty.
Original worker commits are identified in integration commit messages. No merge/cherry-pick/rebase was used.

## QA37 offline artifact — NOT INSTALLED

artifacts/245/futbeat-qa-1.0.0+37-local-cache-ca59ffef.apk
SHA256:0F2051A076245074C7D4CFC499B0D8E02480D3B6454412096D411E91B6CF664C
111122920 bytes;com.futbeat.futbeat.qa;version1.0.0/code37;minSDK24/target36.
QA debug certificate SHA256:6533b820f58ee837e6bbedb29f09b26a8384760ee3de13c5cb6185ad114c0362.
Four required arm64 ELF libraries verified;Flutter engine arm64, some plugin JNI additionally packaged for other ABIs.
DEMO=false;local-cache-only=true;API=http://127.0.0.1:9;public token empty;Push/OAuth/Ads off;QA diagnostics on. Native APK manifest/signature independently checked with aapt/apksigner.
Build passed22.2seconds after tests. Initial pre-STOP build log retained separately; final artifact is from ca59ffef. QA35/36 preserved.

## Boundaries and next steps

A32 physical verification is NOT VERIFIED after a bounded ADB read timed out. No new A32 captures/PID-absence claim. Four clearly labelled local-widget fixture previews remain under MOBILE244 artifacts; these are not phone captures.
QA123 read-only final observation22:12:29UTC:DISARMED, heartbeat less than one second old;launcher/failsafe hashes unchanged. No task/controller mutation.
Passive API remains a non-deployed backend candidate;connected adapter remains inactive;no whitelist expansion. Limits15minutes/30requests/8perminute/2concurrent remain tested locally.
CI244 remains FAIL for inherited Linux golden comparisons: exact-base attribution matched36PNG files across18comparisons. First CI235 run41246835429 at2439045:1532PASS/11FAIL, EXACT_RENDER_MATCH on all36PNGs against MOBILE244. Later HEAD must be assessed separately; no remote green is asserted here. contracts skips backend suites because no backend files changed.
Session began20:40UTC31Oct2026;this is a measured session span, not12hours or continuous coding time. No persistent continuation registered: automatic approval review rejected active automation; explicit authorization pending. No future unattended execution claimed.
Next:stable ADB/controller READY for offline device QA;backend operator verification/deployment authorization for passive API;separate owner decision on Linux golden reference policy without masking failures.
