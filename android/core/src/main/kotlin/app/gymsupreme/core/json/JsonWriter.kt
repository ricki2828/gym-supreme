package app.gymsupreme.core.json

/**
 * Writes values read by [Json] back as one line: maps (key order kept), lists, strings, Long/Int,
 * Double, Boolean, null. Used when the service itself writes the next snapshot (finish now;
 * lock-screen actions in cut 2), so a read-then-write keeps every field Dart sent.
 */
object JsonWriter {
    fun write(v: Any?): String = StringBuilder().also { put(it, v) }.toString()

    private fun put(sb: StringBuilder, v: Any?) {
        when (v) {
            null -> sb.append("null")
            is String -> str(sb, v)
            is Boolean -> sb.append(v)
            is Long, is Int -> sb.append(v)
            is Double -> {
                if (v.isNaN() || v.isInfinite()) throw JsonException("non-finite number")
                if (v == Math.floor(v) && Math.abs(v) < 1e15) sb.append(v.toLong()).append(".0") else sb.append(v)
            }
            is Map<*, *> -> {
                sb.append('{')
                var first = true
                for ((k, x) in v) {
                    if (k !is String) throw JsonException("non-string key")
                    if (!first) sb.append(',')
                    first = false
                    str(sb, k)
                    sb.append(':')
                    put(sb, x)
                }
                sb.append('}')
            }
            is List<*> -> {
                sb.append('[')
                v.forEachIndexed { i, x ->
                    if (i > 0) sb.append(',')
                    put(sb, x)
                }
                sb.append(']')
            }
            else -> throw JsonException("cannot write ${v.javaClass.simpleName}")
        }
    }

    private fun str(sb: StringBuilder, s: String) {
        sb.append('"')
        var i = 0
        while (i < s.length) {
            val ch = s[i]
            if (Character.isSurrogate(ch)) {
                // A valid pair is written raw (UTF-8); a lone surrogate as lowercase \udxxx, like Dart.
                if (Character.isHighSurrogate(ch) && i + 1 < s.length && Character.isLowSurrogate(s[i + 1])) {
                    sb.append(ch).append(s[i + 1])
                    i += 2
                } else {
                    sb.append(String.format("\\u%04x", ch.code))
                    i++
                }
                continue
            }
            i++
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                '\b' -> sb.append("\\b")
                '\u000C' -> sb.append("\\f")
                else -> if (ch < ' ') sb.append(String.format("\\u%04x", ch.code)) else sb.append(ch)
            }
        }
        sb.append('"')
    }
}
