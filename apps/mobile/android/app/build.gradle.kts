import java.net.URI
import java.util.Base64
import java.util.Properties
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file(
    System.getenv("FUTBEAT_SIGNING_PROPERTIES") ?: "key.properties",
)
val releaseSigningProperties = Properties()
if (releaseSigningPropertiesFile.exists()) {
    releaseSigningPropertiesFile.inputStream().use(releaseSigningProperties::load)
}
System.getenv("FUTBEAT_SIGNING_STORE_FILE")?.let { store ->
    check(System.getenv("FUTBEAT_SIGNING_PROPERTIES") == null) {
        "Choose one release signing configuration."
    }
    releaseSigningProperties.clear()
    releaseSigningProperties.setProperty("storeFile", store)
    releaseSigningProperties.setProperty("keyAlias", System.getenv("FUTBEAT_SIGNING_ALIAS").orEmpty())
    val password = System.getenv("FUTBEAT_SIGNING_PASSWORD").orEmpty()
    releaseSigningProperties.setProperty("storePassword", password)
    releaseSigningProperties.setProperty("keyPassword", password)
}

val requiredReleaseSigningProperties =
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingReleaseSigningProperties =
    requiredReleaseSigningProperties.filter { releaseSigningProperties.getProperty(it).isNullOrBlank() }
val releaseArtifactTaskPrefixes =
    listOf("assemble", "bundle", "package", "sign", "validateSigning")
val appProjectPath = project.path
val offlinePreview = System.getenv("FUTBEAT_OFFLINE_PREVIEW") == "true"
val passivePreview = System.getenv("FUTBEAT_PASSIVE_PREVIEW") == "true"
val r05TestPackage = System.getenv("FUTBEAT_R05_TEST_PACKAGE") == "true"
val commercialQaPackage = System.getenv("FUTBEAT_COMMERCIAL_QA") == "true"
val integralQaPackage = System.getenv("FUTBEAT_INTEGRAL_QA") == "true"
val billingQaPackage = System.getenv("FUTBEAT_BILLING_QA") == "true"
val commercialUmpAppId = System.getenv("FUTBEAT_COMMERCIAL_UMP_APP_ID")?.trim().orEmpty()
check(!(offlinePreview && passivePreview)) { "Preview modes are mutually exclusive." }

// --- Release ads configuration (fail closed) ------------------------------
// A release (Play) build must carry FutBeat's production AdMob App ID and ad
// units, never Google's test ones. Debug/profile builds are not checked.
val googleTestAdPublisher = "ca-app-pub-3940256099942544"
val admobAppIdPattern = Regex("^ca-app-pub-\\d{16}~\\d{10}$")
val admobUnitPattern = Regex("^ca-app-pub-\\d{16}/\\d{10}$")

/** Flutter passes --dart-define values as base64, comma separated. */
fun dartDefines(): Map<String, String> {
    val raw = project.findProperty("dart-defines") as String? ?: return emptyMap()
    val result = mutableMapOf<String, String>()
    for (encoded in raw.split(",")) {
        val pair = runCatching { String(Base64.getDecoder().decode(encoded)) }.getOrNull() ?: continue
        val separator = pair.indexOf('=')
        if (separator > 0) result[pair.substring(0, separator)] = pair.substring(separator + 1)
    }
    return result
}

// This is an accidental-credential-exposure check, not JWT authentication.
// A key's project, signature and permissions still need operational approval.
fun isPublicClientKey(value: String): Boolean {
    val token = value.trim()
    if (token.isEmpty()) return true // Existing optional/default configuration.
    if (token.startsWith("sb_secret_")) return false
    if (token.startsWith("sb_publishable_") && token.length > "sb_publishable_".length) {
        return true
    }
    val parts = token.split('.')
    if (parts.size != 3) return false
    return runCatching {
        val payload = String(Base64.getUrlDecoder().decode(parts[1]), Charsets.UTF_8)
        val claims = JsonSlurper().parseText(payload) as? Map<*, *>
        claims?.get("role") == "anon"
    }.getOrDefault(false)
}

// Release must never ship fixture data or a QA-only network blocker.
fun releaseRuntimeProblems(defines: Map<String, String> = dartDefines()): List<String> {
    val problems = mutableListOf<String>()
    if (listOf("FUTBEAT_PREMIUM_MONTHLY_ID", "FUTBEAT_PREMIUM_YEARLY_ID")
            .any { !defines[it].isNullOrBlank() }) {
        problems += "Premium release products require server-side purchase verification."
    }
    for (key in listOf("FUTBEAT_API_PUBLIC_TOKEN", "FUTBEAT_SUPABASE_PUBLISHABLE_KEY")) {
        if (!isPublicClientKey(defines[key].orEmpty())) {
            // Never include the rejected value, its payload or part of it.
            problems += "$key must be a publishable or legacy anon key"
        }
    }
    for (flag in listOf("FUTBEAT_USE_DEMO", "FUTBEAT_QA_LOCAL_CACHE_ONLY", "FUTBEAT_QA_DIAGNOSTICS", "FUTBEAT_PASSIVE_PREVIEW", "FUTBEAT_PASSIVE_PREVIEW_ENABLED", "FUTBEAT_OFFLINE_PREVIEW", "FUTBEAT_PREMIUM_PLAY_QA", "FUTBEAT_INTEGRAL_QA")) {
        if (defines[flag]?.trim()?.lowercase() == "true") {
            problems += "$flag is QA-only and must be false in a release"
        }
    }
    val premiumServer = defines["FUTBEAT_PREMIUM_SERVER_ENABLED"]?.trim()?.lowercase() == "true"
    if (premiumServer) {
        val productionAuth = "https://izlmruqawgagwdcsjhte.supabase.co"
        if (defines["BILLING_BASE"] != "$productionAuth/functions/v1/futbeat-billing" ||
            defines["FUTBEAT_SUPABASE_URL"]?.trimEnd('/') != productionAuth ||
            defines["FUTBEAT_USER_SESSION_ACCESS"]?.trim()?.lowercase() != "true") {
            problems += "Premium server requires the matching production Auth and Billing origins with user-session access."
        }
    } else if (!defines["BILLING_BASE"].isNullOrBlank()) {
        problems += "BILLING_BASE requires explicit production server verification."
    }
    if (!defines["FUTBEAT_PASSIVE_CLIENT_KEY"].isNullOrBlank()) {
        problems += "Preview client keys are not allowed in the official release"
    }
    if (defines["FUTBEAT_USER_SESSION_ACCESS"]?.trim()?.lowercase() == "true") {
        if (!defines["FUTBEAT_API_PUBLIC_TOKEN"].isNullOrBlank()) {
            problems += "User-session access must not contain a fixed API token"
        }
        val key = defines["FUTBEAT_SUPABASE_PUBLISHABLE_KEY"].orEmpty()
        if (!Regex("^sb_publishable_[A-Za-z0-9_-]+$").matches(key)) {
            problems += "User-session access requires an explicit publishable key"
        }
        val origin = defines["FUTBEAT_SUPABASE_URL"].orEmpty().trimEnd('/')
        val uri = runCatching { URI(origin) }.getOrNull()
        if (uri == null || uri.scheme != "https" || uri.host.isNullOrBlank() ||
            uri.userInfo != null || uri.query != null || uri.fragment != null ||
            uri.port !in listOf(-1, 443) || uri.rawPath !in listOf("", "/")) {
            problems += "User-session access requires an explicit HTTPS Auth origin"
        }
        if (origin.isBlank() || defines["FUTBEAT_API_URL"] != "$origin/functions/v1/futbeat-api") {
            problems += "User-session API must match its Auth project and central endpoint"
        }
    }
    // An omitted override keeps the application's existing HTTPS default.
    // If explicitly supplied, never silently fall back from an invalid value.
    for ((key, originOnly) in listOf("FUTBEAT_API_URL" to false, "FUTBEAT_SUPABASE_URL" to true)) {
        val value = defines[key] ?: continue
        val uri = runCatching { URI(value) }.getOrNull()
        val host = uri?.host?.trimEnd('.')?.lowercase()
        if (uri == null || uri.scheme != "https" || host.isNullOrBlank() ||
            uri.userInfo != null || uri.fragment != null || uri.query != null ||
            host == "localhost" || host.startsWith("127.") ||
            host == "[::1]" || host == "::1" ||
            (originOnly && uri.rawPath !in listOf("", "/"))) {
            val target = if (originOnly) "origin" else "base URL"
            problems += "$key must be a non-loopback HTTPS $target without credentials, query or fragment"
        }
    }
    return problems
}

tasks.register("validateReleaseRuntimeConfig") {
    description = "Rejects DEMO, QA-only modes and unsafe API overrides without building an artifact."
    doLast {
        val problems = releaseRuntimeProblems()
        if (problems.isNotEmpty()) {
            throw GradleException("Release runtime configuration:\n - " + problems.joinToString("\n - "))
        }
        println("Release runtime configuration OK")
    }
}

fun releaseAdsProblems(): List<String> {
    val problems = mutableListOf<String>()
    val defines = dartDefines()
    val adsDisabled = defines["FUTBEAT_ADS_DISABLED"]?.trim()?.lowercase() == "true"
    if (adsDisabled) {
        if (defines["FUTBEAT_ADMOB_TEST_ADS"]?.trim()?.lowercase() == "true") {
            problems += "FUTBEAT_ADMOB_TEST_ADS conflicts with FUTBEAT_ADS_DISABLED"
        }
        return problems
    }
    val appId = System.getenv("FUTBEAT_ADMOB_APP_ID")?.trim().orEmpty()
    when {
        appId.isEmpty() -> problems += "FUTBEAT_ADMOB_APP_ID (environment) is missing"
        appId.startsWith(googleTestAdPublisher) -> problems += "FUTBEAT_ADMOB_APP_ID is Google's test App ID"
        !admobAppIdPattern.matches(appId) -> problems += "FUTBEAT_ADMOB_APP_ID is not an AdMob App ID (ca-app-pub-…~…)"
    }
    if (defines["FUTBEAT_ADMOB_TEST_ADS"]?.trim()?.lowercase() == "true") {
        problems += "--dart-define=FUTBEAT_ADMOB_TEST_ADS=true is not allowed in a release"
    }
    val feed = defines["FUTBEAT_ADMOB_MATCHES_FEED_ID"]?.trim().orEmpty()
    when {
        feed.isEmpty() -> problems += "--dart-define=FUTBEAT_ADMOB_MATCHES_FEED_ID is missing"
        feed.startsWith(googleTestAdPublisher) -> problems += "FUTBEAT_ADMOB_MATCHES_FEED_ID is a Google test ad unit"
        !admobUnitPattern.matches(feed) -> problems += "FUTBEAT_ADMOB_MATCHES_FEED_ID is not an AdMob ad unit (ca-app-pub-…/…)"
    }
    if (appId.isNotEmpty() && feed.isNotEmpty() &&
        appId.substringBefore('~') != feed.substringBefore('/')
    ) {
        problems += "App ID and ad unit belong to different AdMob accounts"
    }
    return problems
}

tasks.register("validateReleaseAdsConfig") {
    description = "Fails unless production AdMob ids are configured (release builds)."
    doLast {
        val problems = releaseAdsProblems()
        if (problems.isNotEmpty()) {
            throw GradleException("Release ads configuration:\n - " + problems.joinToString("\n - "))
        }
        println("Release ads configuration OK")
    }
}

android {
    namespace = "com.futbeat.futbeat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.futbeat.futbeat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // AdMob App ID: real one only from the build environment, never
        // committed. Fallback = Google's documented test App ID.
        manifestPlaceholders["admobAppId"] =
            System.getenv("FUTBEAT_ADMOB_APP_ID")?.takeIf { it.isNotBlank() }
                ?: "ca-app-pub-3940256099942544~3347511713"
        manifestPlaceholders["futbeatAppLabel"] = "FutBeat"
        manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat"
        manifestPlaceholders["futbeatAppLinkHost"] = "futbeat.com"
        manifestPlaceholders["futbeatAllowBackup"] = "true"
    }

    signingConfigs {
        if (missingReleaseSigningProperties.isEmpty()) {
            create("release") {
                storeFile = releaseSigningPropertiesFile.parentFile.resolve(
                    releaseSigningProperties.getProperty("storeFile"),
                )
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    if (offlinePreview) {
        sourceSets.getByName("debug").manifest.srcFile("src/preview/AndroidManifest.xml")
    } else if (passivePreview) {
        sourceSets.getByName("debug").manifest.srcFile("src/passivePreview/AndroidManifest.xml")
    }

    buildTypes {
        debug {
            if (integralQaPackage || billingQaPackage) {
                manifestPlaceholders["futbeatAppLabel"] = "FutBeat Diagnóstico"
                manifestPlaceholders["admobAppId"] = commercialUmpAppId
            }
            // Opt-in QA install alongside the Play-signed app. Never changes
            // the normal debug or release package when the flag is absent.
            if (commercialQaPackage) {
                applicationIdSuffix = ".commercialqa"
                manifestPlaceholders["futbeatAppLabel"] = "FutBeat Comercial QA"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.commercialqa"
                manifestPlaceholders["futbeatAppLinkHost"] = "commercialqa.invalid"
                manifestPlaceholders["futbeatAllowBackup"] = "false"
                manifestPlaceholders["admobAppId"] =
                    commercialUmpAppId.ifEmpty { "ca-app-pub-3940256099942544~3347511713" }
            } else if (r05TestPackage) {
                applicationIdSuffix = ".r05test"
                manifestPlaceholders["futbeatAppLabel"] = "FutBeat R05 Test"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.r05test"
                manifestPlaceholders["futbeatAppLinkHost"] = "r05test.invalid"
                manifestPlaceholders["futbeatAllowBackup"] = "false"
            } else if (passivePreview) {
                applicationIdSuffix = ".preview.connected"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.preview.connected"
                manifestPlaceholders["futbeatAppLinkHost"] = "preview.invalid"
            } else if (offlinePreview) {
                applicationIdSuffix = ".preview"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.preview"
                manifestPlaceholders["futbeatAppLinkHost"] = "preview.invalid"
            } else if (System.getenv("FUTBEAT_QA_ISOLATED_PACKAGE") == "true") {
                applicationIdSuffix = ".qa"
                manifestPlaceholders["futbeatAppLabel"] = "FutBeat QA"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.qa"
                manifestPlaceholders["futbeatAppLinkHost"] = "qa.invalid"
                if (commercialUmpAppId.isNotEmpty()) {
                    manifestPlaceholders["admobAppId"] = commercialUmpAppId
                }
            }
        }
        // The profile type is created by Flutter before this debug package
        // is configured. Copy its final QA identity for an optimized local
        // acceptance build; never change release or another install variant.
        getByName("profile") {
            if (System.getenv("FUTBEAT_QA_ISOLATED_PACKAGE") == "true") {
                initWith(getByName("debug"))
                isDebuggable = true
                matchingFallbacks.clear()
                matchingFallbacks.addAll(listOf("debug", "release"))
            }
        }
        release {
            if (missingReleaseSigningProperties.isEmpty()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

gradle.taskGraph.whenReady(
    object : org.gradle.api.Action<org.gradle.api.execution.TaskExecutionGraph> {
        override fun execute(taskGraph: org.gradle.api.execution.TaskExecutionGraph) {
            val releaseArtifactRequested =
                taskGraph.allTasks.any { task ->
                    task.project.path == appProjectPath &&
                        task.name.contains("Release", ignoreCase = true) &&
                        releaseArtifactTaskPrefixes.any { prefix ->
                            task.name.startsWith(prefix, ignoreCase = true)
                        }
                }

            val defines = dartDefines()
            val qaCallback = defines["FUTBEAT_QA_ISOLATED_PACKAGE"] == "true"
            val qaPackage = System.getenv("FUTBEAT_QA_ISOLATED_PACKAGE") == "true"
            val r05Test = defines["FUTBEAT_R05_TEST_PACKAGE"] == "true"
            val commercialQa = defines["FUTBEAT_COMMERCIAL_QA"] == "true"
            val integralQa = defines["FUTBEAT_INTEGRAL_QA"] == "true"
            val billingQa = defines["FUTBEAT_PREMIUM_PLAY_QA"] == "true"
            val billingQaIsolated =
                defines["FUTBEAT_SUPABASE_URL"] == "https://wctxcnqcblgewaznxrqh.supabase.co" &&
                defines["BILLING_BASE"] == "https://wctxcnqcblgewaznxrqh.supabase.co/functions/v1/futbeat-billing" &&
                defines["FUTBEAT_API_URL"] == "https://wctxcnqcblgewaznxrqh.supabase.co/functions/v1/futbeat-api"
            val commercialUmp = defines["FUTBEAT_COMMERCIAL_UMP"] == "true"
            val acceptanceUmp = qaPackage && qaCallback &&
                !releaseArtifactRequested && !billingQa && !commercialQa && !integralQa &&
                !r05Test && !offlinePreview && !passivePreview &&
                defines["FUTBEAT_ADMOB_TEST_ADS"] == "true" &&
                defines["FUTBEAT_ADS_DISABLED"] == "false" &&
                listOf("FUTBEAT_ADMOB_MATCHES_FEED_ID", "FUTBEAT_PREMIUM_MONTHLY_ID",
                    "FUTBEAT_PREMIUM_YEARLY_ID").all { defines[it].isNullOrBlank() }
            check(billingQa == billingQaPackage && (!billingQa || (
                billingQaIsolated && !integralQa && !commercialQa && !qaPackage && !r05Test &&
                !offlinePreview && !passivePreview && !releaseArtifactRequested &&
                commercialUmp && defines["FUTBEAT_ADMOB_TEST_ADS"] == "true" &&
                defines["FUTBEAT_ADS_DISABLED"] == "false" &&
                listOf("FUTBEAT_ADMOB_MATCHES_FEED_ID", "FUTBEAT_PREMIUM_MONTHLY_ID",
                    "FUTBEAT_PREMIUM_YEARLY_ID").all { defines[it].isNullOrBlank() } &&
                listOf("FUTBEAT_PUSH_ENABLED", "FUTBEAT_NOTIFICATION_SCOPES_ENABLED",
                    "FUTBEAT_OAUTH_GOOGLE_ENABLED", "FUTBEAT_OAUTH_FACEBOOK_ENABLED")
                    .all { defines[it] == "false" }
            ))) { "G1 requires official debug, matching QA Auth/API/Billing origins, and N1/push/OAuth disabled." }
            check(if (commercialUmp) {
                (commercialQa || integralQa || acceptanceUmp || billingQaIsolated && billingQa) && admobAppIdPattern.matches(commercialUmpAppId) &&
                    !commercialUmpAppId.startsWith(googleTestAdPublisher)
            } else commercialUmpAppId.isEmpty()) {
                "Commercial UMP requires the isolated QA package and an approved AdMob App ID."
            }
            check(commercialQa == commercialQaPackage && (!commercialQa || (
                !releaseArtifactRequested && !qaPackage && !r05Test &&
                    !offlinePreview && !passivePreview &&
                    listOf("FUTBEAT_R05_ENABLED", "FUTBEAT_ADMOB_TEST_ADS",
                        "FUTBEAT_USER_SESSION_ACCESS").all { defines[it] == "true" } &&
                    listOf("FUTBEAT_ADS_DISABLED", "FUTBEAT_USE_DEMO",
                        "FUTBEAT_QA_LOCAL_CACHE_ONLY", "FUTBEAT_PUSH_ENABLED",
                        "FUTBEAT_OAUTH_GOOGLE_ENABLED", "FUTBEAT_OAUTH_FACEBOOK_ENABLED")
                        .all { defines[it] == "false" } &&
                    listOf("FUTBEAT_ADMOB_MATCHES_FEED_ID", "FUTBEAT_PREMIUM_MONTHLY_ID",
                        "FUTBEAT_PREMIUM_YEARLY_ID").all { defines[it].isNullOrBlank() }
                ))) { "Commercial QA requires its isolated debug package, test ads, and no store products." }
            check(r05Test || defines.keys.none {
                it == "FUTBEAT_R05_PHYSICAL_DIAGNOSTICS" || it.startsWith("FUTBEAT_R05_CASE_")
            }) { "R05 physical diagnostics require the isolated test package." }
            check(r05Test == r05TestPackage && (!r05Test || (
                !releaseArtifactRequested && !qaPackage && !offlinePreview && !passivePreview &&
                    defines["FUTBEAT_R05_ENABLED"] == "true" &&
                    defines["FUTBEAT_ADS_DISABLED"] == "true" &&
                    listOf("FUTBEAT_PUSH_ENABLED", "FUTBEAT_USE_DEMO",
                        "FUTBEAT_OAUTH_GOOGLE_ENABLED", "FUTBEAT_OAUTH_FACEBOOK_ENABLED",
                        "FUTBEAT_USER_SESSION_ACCESS").all { defines[it] == "false" }
                ))) { "R05 Test requires its isolated debug package, R05, and explicit disabled features." }
            check(qaCallback == qaPackage && (!qaCallback || (!releaseArtifactRequested && !offlinePreview && !passivePreview))) {
                "QA callback and isolated debug package must be enabled together; neither is allowed in release or preview."
            }
            if ((offlinePreview || passivePreview || defines["FUTBEAT_PASSIVE_PREVIEW"] == "true" ||
                defines["FUTBEAT_PASSIVE_PREVIEW_ENABLED"] == "true") && releaseArtifactRequested) {
                throw GradleException("FutBeat Preview is available only as an isolated debug artifact.")
            }
            if (taskGraph.allTasks.any { it.project.path == appProjectPath && it.name == "assembleDebug" }) {
                check(passivePreview == (defines["FUTBEAT_PASSIVE_PREVIEW"] == "true")) {
                    "Passive Preview build and Dart flags must match."
                }
                check(passivePreview || defines["FUTBEAT_PASSIVE_PREVIEW_ENABLED"] != "true") {
                    "Passive Preview activation requires the isolated package."
                }
                if (passivePreview) {
                    val disabled = listOf("FUTBEAT_QA_LOCAL_CACHE_ONLY", "FUTBEAT_OFFLINE_PREVIEW",
                        "FUTBEAT_USE_DEMO", "FUTBEAT_PUSH_ENABLED", "FUTBEAT_OAUTH_GOOGLE_ENABLED",
                        "FUTBEAT_OAUTH_FACEBOOK_ENABLED")
                    check(defines["FUTBEAT_ADS_DISABLED"] == "true" && disabled.none { defines[it] == "true" }) {
                        "Passive Preview requires Ads/OAuth/Push/DEMO off."
                    }
                }
            }
            if (offlinePreview && taskGraph.allTasks.any {
                    it.project.path == appProjectPath && it.name == "assembleDebug"
                }) {
                if (defines["FUTBEAT_OFFLINE_PREVIEW"] != "true" ||
                    defines["FUTBEAT_QA_LOCAL_CACHE_ONLY"] != "true" ||
                    defines["FUTBEAT_ADS_DISABLED"] != "true" ||
                    listOf("FUTBEAT_USE_DEMO", "FUTBEAT_PUSH_ENABLED", "FUTBEAT_OAUTH_GOOGLE_ENABLED",
                        "FUTBEAT_OAUTH_FACEBOOK_ENABLED").any { defines[it] == "true" }) {
                    throw GradleException("FutBeat Preview requires local cache and Ads/OAuth/Push/DEMO off.")
                }
            }
            check(integralQa == integralQaPackage && (!integralQa || (
                !releaseArtifactRequested && !qaPackage && !commercialQa && !r05Test &&
                !offlinePreview && !passivePreview && commercialUmp &&
                defines["FUTBEAT_ADMOB_TEST_ADS"] == "true" &&
                defines["FUTBEAT_ADS_DISABLED"] == "false" &&
                listOf("FUTBEAT_PUSH_ENABLED", "FUTBEAT_NOTIFICATION_SCOPES_ENABLED",
                    "FUTBEAT_PREMIUM_PLAY_QA", "FUTBEAT_OAUTH_GOOGLE_ENABLED",
                    "FUTBEAT_OAUTH_FACEBOOK_ENABLED", "FUTBEAT_USE_DEMO")
                    .all { defines[it] == "false" } &&
                listOf("FUTBEAT_PREMIUM_MONTHLY_ID", "FUTBEAT_PREMIUM_YEARLY_ID",
                    "FUTBEAT_ADMOB_MATCHES_FEED_ID", "BILLING_BASE")
                    .all { defines[it].isNullOrBlank() }
            ))) { "Integral diagnostic requires the official debug package, test ads, and pending services disabled." }

            if (releaseArtifactRequested) {
                val runtimeProblems = releaseRuntimeProblems()
                if (runtimeProblems.isNotEmpty()) {
                    throw GradleException(
                        "Release runtime configuration:\n - " + runtimeProblems.joinToString("\n - "),
                    )
                }
                val adsProblems = releaseAdsProblems()
                if (adsProblems.isNotEmpty()) {
                    throw GradleException(
                        "Release ads configuration:\n - " + adsProblems.joinToString("\n - "),
                    )
                }
            }

            if (releaseArtifactRequested && missingReleaseSigningProperties.isNotEmpty()) {
                throw GradleException(
                    "Release signing credentials are not configured. " +
                        "Copy android/key.properties.example to android/key.properties and provide all required values.",
                )
            }
        }
    },
)
