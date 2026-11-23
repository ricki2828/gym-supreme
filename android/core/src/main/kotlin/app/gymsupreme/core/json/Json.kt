package app.gymsupreme.core.json

/**
 * Minimal strict JSON reader for the journal (no dependency in the pure core). Objects become
 * [LinkedHashMap] (key order kept), arrays [List], integers [Long], other numbers [Double].
 * Throws [JsonException] on anything that is not exactly one JSON value.
 */
class JsonException(message: String) : Exception(message)

object Json {
    private const val MAX_DEPTH = 64

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value(0)
        p.ws()
        if (p.i != text.length) throw JsonException("trailing data at ${p.i}")
        return v
    }

    /** Parses and requires an object. */
    fun parseObject(text: String): Map<String, Any?> {
        val v = parse(text)
        if (v !is Map<*, *>) throw JsonException("not an object")
        @Suppress("UNCHECKED_CAST")
        return v as Map<String, Any?>
    }

    private class Parser(val s: String) {
        var i = 0

        fun ws() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        fun value(depth: Int): Any? {
            if (depth > MAX_DEPTH) throw JsonException("too deep")
            if (i >= s.length) throw JsonException("unexpected end")
            return when (val c = s[i]) {
                '{' -> obj(depth)
                '[' -> arr(depth)
                '"' -> str()
                't' -> lit("true", true)
                'f' -> lit("false", false)
                'n' -> lit("null", null)
                else -> if (c == '-' || c in '0'..'9') num() else throw JsonException("unexpected '$c' at $i")
            }
        }

        private fun lit(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) throw JsonException("bad literal at $i")
            i += word.length
            return v
        }

        private fun obj(depth: Int): Map<String, Any?> {
            val m = LinkedHashMap<String, Any?>()
            i++
            ws()
            if (i < s.length && s[i] == '}') {
                i++
                return m
            }
            while (true) {
                ws()
                if (i >= s.length || s[i] != '"') throw JsonException("expected key at $i")
                val k = str()
                ws()
                if (i >= s.length || s[i] != ':') throw JsonException("expected ':' at $i")
                i++
                ws()
                m[k] = value(depth + 1)
                ws()
                if (i >= s.length) throw JsonException("unexpected end in object")
                when (s[i]) {
                    ',' -> i++
                    '}' -> {
                        i++
                        return m
                    }
                    else -> throw JsonException("expected ',' or '}' at $i")
                }
            }
        }

        private fun arr(depth: Int): List<Any?> {
            val l = ArrayList<Any?>()
            i++
            ws()
            if (i < s.length && s[i] == ']') {
                i++
                return l
            }
            while (true) {
                ws()
                l.add(value(depth + 1))
                ws()
                if (i >= s.length) throw JsonException("unexpected end in array")
                when (s[i]) {
                    ',' -> i++
                    ']' -> {
                        i++
                        return l
                    }
                    else -> throw JsonException("expected ',' or ']' at $i")
                }
            }
        }

        private fun str(): String {
            i++
            val sb = StringBuilder()
            while (true) {
                if (i >= s.length) throw JsonException("unterminated string")
                val c = s[i++]
                when {
                    c == '"' -> return sb.toString()
                    c == '\\' -> {
                        if (i >= s.length) throw JsonException("bad escape")
                        when (val e = s[i++]) {
                            '"' -> sb.append('"')
                            '\\' -> sb.append('\\')
                            '/' -> sb.append('/')
                            'b' -> sb.append('\b')
                            'f' -> sb.append('\u000C')
                            'n' -> sb.append('\n')
                            'r' -> sb.append('\r')
                            't' -> sb.append('\t')
                            'u' -> {
                                if (i + 4 > s.length) throw JsonException("bad \\u escape")
                                val h = s.substring(i, i + 4).toIntOrNull(16) ?: throw JsonException("bad \\u escape")
                                sb.append(h.toChar())
                                i += 4
                            }
                            else -> throw JsonException("bad escape '\\$e'")
                        }
                    }
                    c < ' ' -> throw JsonException("control character in string")
                    else -> sb.append(c)
                }
            }
        }

        private fun num(): Any {
            val start = i
            if (s[i] == '-') i++
            if (i >= s.length || s[i] !in '0'..'9') throw JsonException("bad number at $start")
            if (s[i] == '0') i++ else while (i < s.length && s[i] in '0'..'9') i++
            var integral = true
            if (i < s.length && s[i] == '.') {
                integral = false
                i++
                if (i >= s.length || s[i] !in '0'..'9') throw JsonException("bad fraction at $start")
                while (i < s.length && s[i] in '0'..'9') i++
            }
            if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
                integral = false
                i++
                if (i < s.length && (s[i] == '+' || s[i] == '-')) i++
                if (i >= s.length || s[i] !in '0'..'9') throw JsonException("bad exponent at $start")
                while (i < s.length && s[i] in '0'..'9') i++
            }
            val t = s.substring(start, i)
            return if (integral) t.toLongOrNull() ?: throw JsonException("integer out of range at $start") else t.toDouble()
        }
    }
}

/** Typed reads with a clear error, for snapshot fields. */
fun Map<String, Any?>.str(k: String): String = this[k] as? String ?: throw JsonException("'$k' is not a string")
fun Map<String, Any?>.strOrNull(k: String): String? = this[k] as? String
fun Map<String, Any?>.long(k: String): Long = this[k] as? Long ?: throw JsonException("'$k' is not an integer")
fun Map<String, Any?>.longOrNull(k: String): Long? = this[k] as? Long
fun Map<String, Any?>.bool(k: String): Boolean = this[k] as? Boolean ?: throw JsonException("'$k' is not a boolean")

@Suppress("UNCHECKED_CAST")
fun Map<String, Any?>.objOrNull(k: String): Map<String, Any?>? = this[k] as? Map<String, Any?>

@Suppress("UNCHECKED_CAST")
fun Map<String, Any?>.objList(k: String): List<Map<String, Any?>> =
    (this[k] as? List<*> ?: throw JsonException("'$k' is not an array")).map { it as? Map<String, Any?> ?: throw JsonException("'$k' has a non-object") }
