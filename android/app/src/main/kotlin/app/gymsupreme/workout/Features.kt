package app.gymsupreme.workout

import android.util.Log
import app.gymsupreme.BuildConfig
import app.gymsupreme.core.flags.FeatureSet

/**
 * Native feature flags (0.3 plan, cut N0). `BuildConfig.GS_FEATURES` is the GS_FEATURES value
 * from the build's `--dart-define` list (android/app/build.gradle.kts), so these always match
 * the Dart `Features` of the same APK. Plain `./gradlew` builds (lint, unit tests) get "" = all off.
 */
object Features {
    private val set = FeatureSet(BuildConfig.GS_FEATURES)

    /** Lock-screen Done / +1 rep / Skip rest on the session notification (cut L1). */
    val lockDone: Boolean get() = set.on("lockdone")

    /** Health Connect write of finished sessions (cut H1). */
    val health: Boolean get() = set.on("health")

    const val TAG = "GymSupreme/features"

    /** One startup line for tools/emulator_smoke.sh, beside the Dart `GymSupreme/features` line. */
    fun logStartup() {
        Log.i(TAG, "native ${set.logLine()}")
    }
}
