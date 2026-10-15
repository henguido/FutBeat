# Android 1.0.0+4 — signed-build readiness (local only)

Updated 2026-10-14. Current candidate: `codex/player-identity-integration-16`
at `ae9f2db`; parent `6dda155`. This record does not authorize a build,
upload, installation, deployment, or production change.

## Verified in this candidate

- R8 `e13cbac`, LIVE hardening `f36a2d6`, offline cache `bd178a2`,
  suspended-state fix `361bd48`, standings-phase fix `8546b78`, and player
  redirect read fix `ae9f2db` are present. Relative to `6dda155`, only four
  Flutter implementation/test files differ; no Android build configuration
  or backend contract changed.
- `apps/mobile/pubspec.yaml` specifies `1.0.0+4`; Android application ID is
  `com.futbeat.futbeat`. The Room R8 keep rule and release Gradle fail-closed
  checks remain present. Release rejects absent signing inputs, missing or
  test AdMob IDs, publisher mismatch, and `FUTBEAT_ADMOB_TEST_ADS=true`.
- Source Android intent filters cover `https://futbeat.com/auth/reset`,
  `com.futbeat.futbeat://password-reset`, and the separate OAuth callback.
  Installed Play App Links have not been retested for this candidate.
- 86 affected, 254 release-focused, and 1,215 full-suite Flutter tests passed
  in this worktree; `flutter analyze` reported no issues. No AAB/APK was
  generated.

## Historical release evidence, not rechecked remotely

- The earlier audit matched the local upload keystore and AAB 1.0.0+3 to the
  Play **upload** certificate. Play App Signing uses a separate certificate;
  the earlier published `assetlinks.json` check matched that Play certificate
  and package. Neither Play nor the website was queried for this update.
- The prior AAB 1.0.0+3 contained production AdMob App ID and match-feed
  banner unit from one publisher. The earlier worktree prepared those values
  in an ignored local file; this does not prove a future AAB's effective IDs.

## Controlled build inputs — prepared locally, not used in a build

The previous candidate worktree has ignored local
`apps/mobile/android/key.properties` and
`apps/mobile/.env.android-release.local`. Both were copied without overwrite
to the current candidate and verified byte-identical by SHA-256. The keystore
path in the local signing configuration is absolute and resolves; the
certificate was checked with `keytool` and matches the preserved AAB
`1.0.0+3` (SHA-256
`D11958185D1AF8F1874A0AF5A2855A5AFA2BB1E76A1F118FA89ECDBE027FDC0C`).
Its public certificate SHA-256 also matches the historically recorded Play
**upload** certificate; Play was not rechecked in this task. The App ID and
feed banner are non-test, correctly formatted, and share one publisher. The
local Google/Facebook/Push/test-ads flags match the approved values. Both
private input files remain ignored by Git and have no broad read ACL entries.

No passwords, private keys or AdMob IDs are recorded in Git or this document.
Before a separately authorized build, recheck the exact files and effective
environment. Do not create a new key or use Google test IDs. The ignored
AdMob file is **not** loaded automatically by Flutter.

| Release flag | Required value |
| --- | --- |
| `FUTBEAT_OAUTH_GOOGLE_ENABLED` | `true` |
| `FUTBEAT_OAUTH_FACEBOOK_ENABLED` | `false` |
| `FUTBEAT_PUSH_ENABLED` | `false` |
| `FUTBEAT_ADMOB_TEST_ADS` | `false` |
| `FUTBEAT_ADMOB_MATCHES_FEED_ID` | Approved production banner unit |
| `FUTBEAT_PREMIUM_MONTHLY_ID`, `FUTBEAT_PREMIUM_YEARLY_ID` | Omit |

`FUTBEAT_ADMOB_APP_ID` must come from the approved build environment, not a
Dart define. Keep the same publisher for App ID and banner unit. Confirm
that Play still permits versionCode 4 immediately before upload.

After a future authorized build, verify AAB SHA-256, package/version,
effective flags and AdMob values, R8, intent filters, and the JAR signer
against the **upload** certificate. A locally signed AAB does not prove
Play-distributed App Links; test those on both physical devices.

## Blocking gates

1. The deployed `live_match_updates` columns, index, `anon` read policy and
   250-row pagination remain unverified. Do not query Supabase while Claude
   is intervening; perform only the separately authorized bounded check
   after the instance is stable.
2. Signing and AdMob inputs are prepared locally, but no release task was
   run. Recheck file availability and effective environment immediately
   before a separately authorized build; inspect the eventual artifact.
3. Galaxy A32 and S25 Ultra physical QA has not been executed. It gates
   tester distribution after a separately authorized, verified AAB and
   controlled Play installation.

**Decision: NO-GO to generate an AAB now.** The player-identity patch is
locally validated and can remain in the candidate, but it does not close
issue #217 or any of the release gates above.
