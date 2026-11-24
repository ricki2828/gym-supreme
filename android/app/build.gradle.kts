import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Native feature flags (0.3 plan, cut N0). Flutter hands Gradle its --dart-define list as
// -Pdart-defines=<base64("KEY=VALUE")>,...; it goes into BuildConfig.DART_DEFINES verbatim and
// core/flags/DartDefines decodes GS_FEATURES from it (unit-tested), so the native and Dart flags
// of one APK cannot disagree. Plain ./gradlew runs (lint, unit tests) get "" = all off.
val dartDefines: String = (project.findProperty("dart-defines") as String?) ?: ""

// The same GS_FEATURES, decoded here for the one manifest decision Gradle makes (0.3 H1): the
// Health Connect permission and privacy screen merge into the dogfood flavour only when the build
// has `health`. Without it the merged manifest is exactly what it was before H1, and
// tools/check_manifest_permissions.sh forbids the permission. Parsed exactly like
// core/flags/FeatureSet (and Dart, the gate, the emulator scripts): `all` only as the whole
// string, otherwise a comma list of trimmed names.
val gsFeaturesRaw: String = dartDefines.split(',')
    .filter { it.isNotBlank() }
    .mapNotNull { runCatching { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }.getOrNull() }
    .lastOrNull { it.startsWith("GS_FEATURES=") } // the last define wins, as in DartDefines
    ?.removePrefix("GS_FEATURES=")
    ?: ""
val healthManifest: Boolean =
    gsFeaturesRaw == "all" || "health" in gsFeaturesRaw.split(',').map { it.trim() }

android {
    // Permanent ids (plan 6.5): namespace and applicationId app.gymsupreme.
    namespace = "app.gymsupreme"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.gymsupreme"
        minSdk = 29
        targetSdk = 36
        // From pubspec.yaml; CI stamps 0.1.0+<run number> on dogfood builds so every build
        // installs over the last. Split APKs add 1000 * ABI code.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Read by workout/Features.kt. Base64 entries and commas only: no escaping needed.
        buildConfigField("String", "DART_DEFINES", "\"${dartDefines.filter { it.isLetterOrDigit() || it in "+/=," }}\"")
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        // CI runs :app:lintPlayDebug with only NewApi: any call above minSdk 29 without a
        // version guard fails the build.
        checkReleaseBuilds = false
        checkOnly += setOf("NewApi")
        abortOnError = true
    }

    signingConfigs {
        // CI dogfood key: repo secrets GYM_DOGFOOD_* decoded to a temp file by ci.yml. Offline
        // copy on the dev host, never in the repo. Absent locally -> debug key, so the variant
        // still configures; the CI job fails if the key is missing.
        create("dogfood") {
            val ksPath = System.getenv("GYM_DOGFOOD_KEYSTORE")
            if (ksPath != null) {
                storeFile = file(ksPath)
                storePassword = System.getenv("GYM_DOGFOOD_STORE_PASSWORD")
                keyAlias = System.getenv("GYM_DOGFOOD_KEY_ALIAS")
                keyPassword = System.getenv("GYM_DOGFOOD_KEY_PASSWORD")
            } else {
                initWith(getByName("debug"))
            }
        }
    }

    flavorDimensions += "dist"
    productFlavors {
        // Play track (phase 5): app.gymsupreme. Release signing is added with the Play pipeline.
        create("play") {
            dimension = "dist"
        }
        // Sideloadable build for Ricki's phone: release AOT + R8, own fixed key.
        create("dogfood") {
            dimension = "dist"
            applicationIdSuffix = ".dogfood"
            versionNameSuffix = "-dogfood"
            signingConfig = signingConfigs.getByName("dogfood")
        }
    }

    sourceSets {
        // H1: see healthManifest above. Dogfood only; play never declares Health Connect yet.
        if (healthManifest) getByName("dogfood").manifest.srcFile("src/health/AndroidManifest.xml")
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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

dependencies {
    // Pure Kotlin core from the included build android/core.
    implementation("app.gymsupreme:core")
    // H1: Health Connect write (write only). Its client API is suspend functions.
    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    // JVM unit tests (health record mapping); CI runs :app:testPlayDebugUnitTest.
    testImplementation("junit:junit:4.13.2")
}
