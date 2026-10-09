# OAuth provider availability

FutBeat separates two different decisions:

1. which providers a binary is allowed to offer;
2. which providers Supabase currently reports as enabled.

The build allowlist is explicit and contains no secrets:

- `FUTBEAT_OAUTH_GOOGLE_ENABLED=true`
- `FUTBEAT_OAUTH_FACEBOOK_ENABLED=true`

Each value defaults to `false`. The legacy global
`FUTBEAT_OAUTH_ENABLED` is not sufficient to enable either provider.

A valid `/auth/v1/settings` response is authoritative. A provider reported
as disabled is hidden even when its build flag is true. A timeout, network,
DNS, TLS or server failure, malformed response, or missing `external` map is
not treated as disabled: FutBeat temporarily falls back to the build
allowlist and offers a retry. Failures are not cached. The last valid response
is cached only in memory for the lifetime of `PushService`.

Example QA build with both providers and Google test ads:

```powershell
flutter build apk --debug `
  --dart-define=FUTBEAT_OAUTH_GOOGLE_ENABLED=true `
  --dart-define=FUTBEAT_OAUTH_FACEBOOK_ENABLED=true `
  --dart-define=FUTBEAT_ADMOB_TEST_ADS=true
```

Production builds must enable only providers that are configured and tested
in Supabase and their respective provider consoles.

## First Internal Testing AAB

The release build command in `android-signing.md` does not currently pass
OAuth flags. With the defaults above, that build would hide both social
providers. Before building the first AAB, pass each decision explicitly:

```powershell
--dart-define=FUTBEAT_OAUTH_GOOGLE_ENABLED=true `
--dart-define=FUTBEAT_OAUTH_FACEBOOK_ENABLED=false
```

Google still needs the final release build verified. Keep Facebook false until
Meta Live and physical QA on that build are confirmed. These flags belong in
the final build command or its define file; the debug QA build above does not
configure the release artifact.
