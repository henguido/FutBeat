# Android 1.0.0+4 — preparation gates

Base: `bd178a2` (R8, LIVE bootstrap/hardening and offline public cache).
This document authorizes no build, upload, deployment or production change.

## Verified gates (2026-10-13)

- Git source `bd178a2` is clean; this isolated branch preserves R8, LIVE and
  offline-cache commits. No newer approved mobile commit was found locally.
- Play Console's **all app bundles** page lists only version codes `1` and `2`;
  code `4` was unused when checked. Recheck immediately before upload.
- Play App Signing SHA-256 is
  `D3:07:B7:E2:F9:D3:99:FA:3C:6C:C3:14:B6:DE:B0:01:39:B3:F6:09:A9:6B:87:EB:FB:76:48:12:D1:0D:CD:E4`.
  Its separate upload-certificate SHA-256 is
  `C9:D4:5B:74:C4:7F:2B:8F:81:6B:A6:1F:14:76:F3:BC:C1:76:D9:6C:54:20:4E:A9:B3:E6:79:F8:0D:9E:4F:4F`.
  The upload certificate matches both the local keystore and signed AAB
  `1.0.0+3` (SHA-256 `D11958185D1AF8F1874A0AF5A2855A5AFA2BB1E76A1F118FA89ECDBE027FDC0C`).
- The published `https://futbeat.com/.well-known/assetlinks.json` returned
  HTTP 200 with `com.futbeat.futbeat` and both certificates above. Play's
  Digital Asset Links snippet contains the same package and App Signing SHA.
- The AAB `1.0.0+3` contains a non-test AdMob App ID and one non-test banner
  unit from the same publisher. This proves the prior artifact's IDs, not
  the future build environment's values. The R8 rule and fail-closed release
  signing/AdMob checks remain unchanged.

## Approved candidate configuration

- Package: `com.futbeat.futbeat`; version name/code: `1.0.0` / `4`.
- Keep the Room constructor R8 rule in `android/app/proguard-rules.pro`.
- Do not store upload keys or passwords in Git. The existing upload certificate
  must match the signed 1.0.0+3 AAB; configure ignored `android/key.properties`
  only in the controlled signing environment when a build is authorized.
- Set `FUTBEAT_OAUTH_GOOGLE_ENABLED=true` for the candidate, based on the
  documented 2026-10-04 Auth QA; Google still requires Play-release device QA.
- Set `FUTBEAT_OAUTH_FACEBOOK_ENABLED=false` (Meta Live/QA not approved).
- Set `FUTBEAT_PUSH_ENABLED=false`; do not pass production Firebase defines.
- Omit `FUTBEAT_PREMIUM_MONTHLY_ID` and `FUTBEAT_PREMIUM_YEARLY_ID`, leaving
  the purchase UI disabled until a separate product decision and Play QA.
- Release AdMob needs a real App ID in `FUTBEAT_ADMOB_APP_ID` and a real match
  feed unit in `FUTBEAT_ADMOB_MATCHES_FEED_ID`, from the same account. Never
  enable `FUTBEAT_ADMOB_TEST_ADS` or use Google's test publisher in release.
- Recheck version code 4 in Play Console immediately before upload.

## Pending gates and risks

### LIVE contract audit — 2026-10-13: BLOCKED

The owner confirmed that Claude is still working on Supabase production.
Therefore the entry condition for remote verification is not met. No SQL,
REST request, migration, policy change or index change was run in this audit.
The production table, columns, index, `anon` grant/RLS policy and pagination
remain **unverified**, not failed. Do not infer deployment from migration files.

Local evidence only: Flutter selects `match_id`, `provider`,
`external_match_id`, `status`, `minute`, `home_score`, `away_score`, `revision`,
`event_count`, `latest_events`, `changed_at` and `updated_at`. Its bootstrap
filters `changed_at >= <UTC cursor>`, orders by `match_id.asc`, pages by
`match_id > <last key>` and requests 250 rows per page. The repository migration
creates those columns, grants `SELECT` to `anon`, enables RLS with a public
read policy, and defines `live_match_updates_changed_idx`. There is no proven
local-contract difference; equivalence to production cannot yet be asserted.

When Claude confirms production work has ended and the instance is stable,
run the bounded metadata and one-row REST checks below. Stop after a timeout
or degradation signal. Until then, the LIVE gate is open and the release
recommendation remains **NO-GO for an AAB**.

1. Confirm the production LIVE table, columns, index, grants and policy with
   the metadata-only queries below. Run only while Supabase is healthy; stop
   after a timeout or signs of saturation. Do not use a table-wide count.
2. With the app's publishable key, perform at most one REST page of 1 row:
   `select=match_id,provider,external_match_id,status,minute,home_score,away_score,revision,event_count,latest_events,changed_at,updated_at`,
   `changed_at=gte.<recent UTC instant>`, `order=match_id.asc`, `limit=1`.
   An empty but successful response validates the request shape, not data
   freshness. Repeat with a second keyset page only if a first row exists and
   the service remains healthy.
3. Before any authorized build, provide the existing ignored signing
   configuration and the same non-test AdMob App ID/banner unit in the
   controlled environment. Their values are deliberately absent here; do not
   copy passwords, keystores or service keys into Git. Verify the final build
   flags, version code and signer from the resulting artifact.
4. Physical QA on both devices remains mandatory. App Links JSON and source
   filters match, but actual Play-installed link handling has not been proven.

**Decision:** GO for local release preparation, **NO-GO for a signed AAB**
until LIVE production compatibility and controlled build configuration are
verified. The physical-QA plan is prepared in
`ANDROID-1.0.0-4-PHYSICAL-QA.md`, but no device test has been executed. No
production SQL or REST check was run while Claude
was intervening in Supabase.

Metadata SQL (read only; no row scan):

```sql
select a.attname
from pg_catalog.pg_attribute a
join pg_catalog.pg_class c on c.oid = a.attrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relname = 'live_match_updates'
  and a.attnum > 0 and not a.attisdropped
order by a.attnum;

select indexname, indexdef
from pg_catalog.pg_indexes
where schemaname = 'public' and tablename = 'live_match_updates'
  and indexname = 'live_match_updates_changed_idx';

select policyname, roles, cmd, qual
from pg_catalog.pg_policies
where schemaname = 'public' and tablename = 'live_match_updates';

select grantee, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and table_name = 'live_match_updates'
  and grantee = 'anon';
```

## Physical QA after a separately authorized build

On both Galaxy A32 and S25 Ultra, install the **Play-distributed** candidate
and verify cold start (R8), Google login, password reset App Link, app-open
reset fallback, notification permission/Push if enabled, Premium if enabled,
and production ads without test banners. Exercise a LIVE match across a
disconnect/reconnect and score correction. Reopen Match Center and profiles
offline, then reconnect and confirm stale data is replaced only by newer valid
responses. Change account, country and date; verify no private data or wrong
match/entity is shown. Test slow network and HTTP 503 behavior where possible.

Do not mark the release ready until the external gates and both devices pass.
