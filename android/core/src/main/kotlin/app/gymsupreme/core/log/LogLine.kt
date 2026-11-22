package app.gymsupreme.core.log

/**
 * One spike-log event as a single JSON object line (brief section 5). Values are strings,
 * numbers, booleans or null; insertion order is kept so the log reads the same way every time.
 * Pure, so the format is unit-tested off the phone.
 */
class LogLine(event: String) {
    private val fields = LinkedHashMap<String, Any?>()

    init {
        fields["event"] = event
    }

    fun put(key: String, value: Any?): LogLine {
        fields[key] = value
        return this
    }

    fun encode(): String {
        val sb = StringBuilder("{")
        var first = true
        for ((k, v) in fields) {
            if (!first) sb.append(',')
            first = false
            str(sb, k)
            sb.append(':')
            when (v) {
                null -> sb.append("null")
                is Boolean -> sb.append(v)
                is Int, is Long -> sb.append(v)
                is Double -> if (v.isNaN() || v.isInfinite()) sb.append("null") else sb.append(v)
                is Float -> if (v.isNaN() || v.isInfinite()) sb.append("null") else sb.append(v.toDouble())
                else -> str(sb, v.toString())
            }
        }
        return sb.append('}').toString()
    }

    private fun str(sb: StringBuilder, s: String) {
        sb.append('"')
        for (ch in s) {
            when (ch) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (ch < ' ') sb.append(String.format("\\u%04x", ch.code)) else sb.append(ch)
            }
        }
        sb.append('"')
    }
}
