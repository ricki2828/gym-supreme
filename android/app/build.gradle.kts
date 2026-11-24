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
}
