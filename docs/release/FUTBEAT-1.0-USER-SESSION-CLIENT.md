# Android 1.0: shared public configuration and user sessions

## Provenance and scope

Existing branch: `codex/android-1-release-candidate`, based on `f255404d` and `1b372c92`.
Backend contract: `henguido/FutBeat@b46d83b62b0aa3cc8019ed88ebb0bd630f339850`,
`packages/contracts/public-api-access-v1.md` and
`docs/release/FUTBEAT-1.0-PUBLIC-ACCESS-ROLLOUT.md`, retrieved from GitHub.
No backend code, migration, signing identity or Preview credential is imported.

## Common build configuration

The same configuration applies to every installation; users never provision a key.

| Setting | Value / requirement |
| --- | --- |
| `FUTBEAT_USER_SESSION_ACCESS` | `true` (explicit rollout switch) |
| `FUTBEAT_SUPABASE_URL` | Approved HTTPS project origin |
| `FUTBEAT_SUPABASE_PUBLISHABLE_KEY` | That project's public `sb_publishable_…` key |
| `FUTBEAT_API_URL` | Same origin plus `/functions/v1/futbeat-api` |
| `FUTBEAT_API_PUBLIC_TOKEN` | Empty |
| `FUTBEAT_PASSIVE_CLIENT_KEY` | Empty |
| Preview, DEMO and QA flags | False |
| Test candidate ads / push | Ads disabled, FCM disabled; no notification delivery claim |

The rollout flag reuses the existing PushService, Dio transport, repositories and
SQLite cache. It is not a device credential or a new product variant. Official
release validation rejects fixed API tokens, missing public configuration and
mismatched API/Auth projects. Legacy and installed Preview builds remain intact.

## Implemented behavior

- Startup restores secure storage and creates one anonymous Auth session in the
  background. Offline startup can continue with SQLite. Transient refresh failure
  retains identity; only the two contract-defined invalid refresh codes permit
  replacement. Failed secure persistence retries the same session.
- Stored sports GETs send the publishable key and individual user JWT. One 401
  refresh/retry is allowed, with single-flight refresh, account-scope checks and
  cancellation. Existing read allowlist, 30/15-minute budget, 8/minute, two active
  requests and bounded cache remain. Retries consume the budget.
- Email and OAuth account creation link the anonymous UID. Existing-account login
  uses an in-memory, single-use merge ticket. Failed redemption preserves login
  and local favorite union; account preferences take precedence. Logout clears
  account-owned local preferences and schedules a new anonymous session.
- Account presentation distinguishes anonymous sessions from registered users;
  guests still synchronize preferences and can configure free alerts.
- Direct legacy Realtime/REST sports access is disabled in this rollout because
  the supplied contract covers central reads, not direct subscription permissions.
  Stored LIVE scores still use the approved central calendar path. News remains
  hidden until its independent read contract is available.

## Evidence and acceptance

Local evidence is retained under `artifacts/android-1-rc/`:

- `public-model-full-tests-2.log`: complete Flutter suite including existing goldens.
- `public-model-final-analyze-2.log`: static analysis.
- `public-model-native-guard.log`: four safe/unsafe synthetic Gradle cases, no build.
- `public-model-wiring-final.log`: actual rollout flag with simulated common config.
- `public-stale-owner-regression-2.log`: existing race regression, expectations unchanged.

The first full run detected two legacy account-race failures caused by an added
no-op asynchronous boundary. The call is now conditional on the rollout mode;
the original assertions were preserved. No golden reference was changed.

Final safety regression: a late definitive refresh rejection from the previous
guest could invalidate the newly signed-in account. Both the proactive and 401
refresh paths now bind invalidation to the original session generation, including
checks after asynchronous local snapshots. Two new tests failed before the fix
and passed afterward (`public-late-refresh-before.log` and
`public-late-refresh-after-final.log`). Static analysis passed. The subsequent
complete suite is recorded in `public-model-full-tests-verified.log`; the final
rollout-config tests are in `public-model-wiring-verified.log`. An interim local
run exhausted host worker threads; only its own failed test process tree was
stopped and validation was repeated with reduced concurrency. The preliminary
`c14c9090` test APK is superseded and must not be installed.

Auth, merge, rate-limit and two-installation tests use local doubles. They do not
prove production OAuth, backend activation, notification delivery, or two physical
devices. Linux CI must be associated with the new exact published HEAD; the old
green result belongs to `f255404d` only.

## Activation and remaining NO-GO conditions

Do not install or activate the test candidate until Claude supplies evidence for
the exact contract: Auth anonymous/manual linking settings, JWT/JWKS verification,
applied merge migrations, `dual`/`user` access mode, demand-off behavior, global
limits, multi-user smoke, rollback and health GREEN. Codex has not changed Supabase.

After approval, inventory packages/signatures/data, install the same candidate on
two compatible phones without replacing an incompatible signature, and verify
distinct guest UIDs, real calendar/final/LIVE data, favorites isolation, linking,
Match Center, available media/detail, process restart and offline SQLite. Missing
provider data is a coverage limitation. Preserve existing Preview/QA installations.

Official AAB remains NO-GO: authoritative Play Upload Key certificate comparison,
approved release configuration/versionCode, real OAuth/provider acceptance, durable
R05 backend receipt/status, privacy/deletion requirements, notification/ads policy,
and acceptance of the exact final artifact remain separate controls. Do not replay
uncertain account deletion or claim success without backend confirmation.
