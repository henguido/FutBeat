import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningPropertiesFile = rootProject.file("key.properties")
val releaseSigningProperties = Properties()
if (releaseSigningPropertiesFile.exists()) {
    releaseSigningPropertiesFile.inputStream().use(releaseSigningProperties::load)
}

val requiredReleaseSigningProperties =
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingReleaseSigningProperties =
    requiredReleaseSigningProperties.filter { releaseSigningProperties.getProperty(it).isNullOrBlank() }
val releaseArtifactTaskPrefixes =
    listOf("assemble", "bundle", "package", "sign", "validateSigning")
val appProjectPath = project.path

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

fun releaseAdsProblems(): List<String> {
    val problems = mutableListOf<String>()
    val appId = System.getenv("FUTBEAT_ADMOB_APP_ID")?.trim().orEmpty()
    when {
        appId.isEmpty() -> problems += "FUTBEAT_ADMOB_APP_ID (environment) is missing"
        appId.startsWith(googleTestAdPublisher) -> problems += "FUTBEAT_ADMOB_APP_ID is Google's test App ID"
        !admobAppIdPattern.matches(appId) -> problems += "FUTBEAT_ADMOB_APP_ID is not an AdMob App ID (ca-app-pub-…~…)"
    }
    val defines = dartDefines()
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
    }

    signingConfigs {
        if (missingReleaseSigningProperties.isEmpty()) {
            create("release") {
                storeFile = rootProject.file(releaseSigningProperties.getProperty("storeFile"))
                storePassword = releaseSigningProperties.getProperty("storePassword")
                keyAlias = releaseSigningProperties.getProperty("keyAlias")
                keyPassword = releaseSigningProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Opt-in QA install alongside the Play-signed app. Never changes
            // the normal debug or release package when the flag is absent.
            if (System.getenv("FUTBEAT_QA_ISOLATED_PACKAGE") == "true") {
                applicationIdSuffix = ".qa"
                manifestPlaceholders["futbeatAppLabel"] = "FutBeat QA"
                manifestPlaceholders["futbeatAuthScheme"] = "com.futbeat.futbeat.qa"
                manifestPlaceholders["futbeatAppLinkHost"] = "qa.invalid"
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

            if (releaseArtifactRequested) {
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
