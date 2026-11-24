package app.gymsupreme.core.timer

/**
 * The on-disk form of a [FiredStore] (cut T1): line 1 `workout<TAB><uuid>`, then one key per line
 * ([FiredKeys]). Append-only while a workout runs; a torn last line (power cut mid-write) is
 * ignored, since its buzz never happened (the key is committed before the buzz). Pure.
 */
object FiredLog {
    private const val HEADER = "workout\t"

    fun header(uuid: String) = HEADER + uuid.replace('\n', ' ').replace('\t', ' ') + "\n"

    fun line(key: String) = key + "\n"

    /** The keys recorded for [uuid], or null if the text is empty or belongs to another workout. */
    fun parse(text: String, uuid: String): Set<String>? {
        if (!text.startsWith(header(uuid))) return null
        val body = text.substring(header(uuid).length)
        val complete = if (body.endsWith("\n")) body else body.substringBeforeLast('\n', "")
        return complete.split('\n').filter { it.isNotEmpty() }.toCollection(LinkedHashSet())
    }

    fun encode(uuid: String, keys: Collection<String>): String = buildString {
        append(header(uuid))
        for (k in keys) append(line(k))
    }
}
