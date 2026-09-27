# Android release signing

FutBeat release builds are fail-closed: they never fall back to the Android debug key. Debug builds do not require release credentials.

## Create and protect the upload key

1. Generate an Android upload keystore locally with `keytool`, using a strong password and a dedicated alias such as `futbeat-upload`.
2. Store the keystore outside the repository in an encrypted, backed-up location.
3. Copy `apps/mobile/android/key.properties.example` to `apps/mobile/android/key.properties`.
4. Fill in `storeFile`, `storePassword`, `keyAlias`, and `keyPassword`. The real file and `*.jks`/`*.keystore` files are ignored by Git and must never be shared or committed.
5. From `apps/mobile`, run `flutter build appbundle --release`.
6. Enrol the app in Google Play App Signing. The local upload key signs uploads; Google manages the separate app-signing key used for distribution.
7. Keep a tested, encrypted backup of the upload key and its credentials. Losing it requires Play's upload-key reset process.

Without all four local properties, any release task stops with `Release signing credentials are not configured` and produces no unsigned or debug-signed distribution artifact.

## Current version decision

The repository contains no evidence that version code `1` has been uploaded. `version: 0.1.0+1` is therefore retained for the first Internal Testing upload. Confirm this against Play Console before uploading; if code 1 already exists there, increment only the build number.

## Local PKIX diagnosis

The affected Windows host can reach Google Maven, Maven Central, and Flutter Storage with `curl`, but Gradle cannot validate their TLS certificates. Gradle uses Android Studio's JetBrains Runtime at `C:\Program Files\Android\Android Studio\jbr` (Java 25) and its truststore at `jbr\lib\security\cacerts`. AVG Web/Mail Shield presents a locally issued certificate whose root is not in that truststore.

Resolve this at the workstation boundary: export the AVG Web/Mail Shield root certificate from the local trusted Windows certificate store, verify its fingerprint with the installed security product or administrator, and import that verified root only into the JBR truststore used by Gradle; alternatively follow organizational policy to disable HTTPS scanning for the affected developer endpoints. Back up the truststore first. Never disable TLS verification, use `trustAll`, or import a certificate downloaded from an untrusted source.

The repository intentionally contains no proxy, CA, truststore, or secret configuration.

## Audited Android release baseline

- Application ID: `com.futbeat.futbeat` (frozen for this launch).
- Version: `0.1.0+1` (`versionName` 0.1.0, `versionCode` 1).
- Flutter 3.47.4 supplies compile SDK 36, target SDK 36, and minimum SDK 24; the Gradle file deliberately keeps the Flutter-managed values rather than duplicating them.
- The source manifest requests `INTERNET` and `POST_NOTIFICATIONS`.
- The merged manifest also contains `WAKE_LOCK`, `ACCESS_NETWORK_STATE`, and `com.google.android.c2dm.permission.RECEIVE` from Firebase Messaging, plus AndroidX's app-scoped `DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`. These support push delivery, network state, and safe dynamic receivers.
- `firebase_core` 4.15.0 and `firebase_messaging` 16.7.0 remain unchanged. Flutter currently warns that `firebase_core` still applies the Kotlin Gradle Plugin and will need Built-in Kotlin support in a future Flutter release; this is a future compatibility action, not a current build failure.
- No `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` environment variable was configured during the diagnosis.
