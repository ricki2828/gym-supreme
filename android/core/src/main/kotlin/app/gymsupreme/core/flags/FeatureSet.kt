package app.gymsupreme.core.flags

/**
 * The build's GS_FEATURES list, parsed exactly as `lib/app/feature_flags.dart` parses it:
 * `all` (whole string) turns every flag on, otherwise a comma list of trimmed names. The app
 * gets [raw] from `BuildConfig.GS_FEATURES`, which Gradle fills from Flutter's `--dart-define`
 * list, so the native and Dart flags of one APK always agree (0.3 plan, cut N0).
 */
class FeatureSet(val raw: String) {
    private val names: Set<String> = raw.split(',').map { it.trim() }.toSet()

    fun on(name: String): Boolean = raw == "all" || name in names

    /**
     * `timers=0 ghost=1 ...` in [NAMES] order: the same names and order as the Dart
     * `featuresLogLine`, so tools/emulator_smoke.sh can compare the two lines.
     */
    fun logLine(): String = NAMES.joinToString(" ") { "$it=${if (on(it)) 1 else 0}" }

    companion object {
        /** Every flag either side knows, in the Dart log line's order. */
        val NAMES: List<String> = listOf("timers", "ghost", "rotation", "plates", "lockdone", "health")
    }
}
