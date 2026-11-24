package app.gymsupreme.core.flags

import java.util.Base64

/**
 * Flutter hands Gradle its `--dart-define` list as `-Pdart-defines=<b64>,<b64>,...`, each entry
 * base64 of UTF-8 `KEY=VALUE` (flutter_tools `encodeDartDefines`). android/app/build.gradle.kts
 * copies that string verbatim into `BuildConfig.DART_DEFINES`; this decodes one value from it at
 * runtime, so the native flags read exactly what Dart's `String.fromEnvironment` reads.
 *
 * Assumes standard base64 (`+/=`), which is what flutter_tools writes; build.gradle.kts keeps
 * only those characters. If Flutter ever switched to URL-safe base64 (`-_`), entries would fail
 * to decode and every flag would read "" (all off): safe, and the emulator smoke's native
 * features line check (it must match GS_FEATURES) would fail the build.
 */
object DartDefines {
    /** The value of [key] (the last one if repeated, as in Dart), or "" when absent or unreadable. */
    fun value(encoded: String?, key: String): String {
        if (encoded.isNullOrBlank()) return ""
        val prefix = "$key="
        var out = ""
        for (part in encoded.split(',')) {
            if (part.isBlank()) continue
            val entry = try {
                String(Base64.getDecoder().decode(part.trim()), Charsets.UTF_8)
            } catch (_: IllegalArgumentException) {
                continue
            }
            if (entry.startsWith(prefix)) out = entry.removePrefix(prefix)
        }
        return out
    }
}
