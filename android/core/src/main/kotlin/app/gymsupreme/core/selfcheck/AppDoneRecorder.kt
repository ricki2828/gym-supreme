package app.gymsupreme.core.selfcheck

import app.gymsupreme.core.json.Json

/**
 * Self-checks: finds the Done taps (and undos) made in the app by comparing each accepted journal
 * snapshot with the one before it. It keeps the last accepted line in memory, so a submit never
 * re-reads or re-parses the whole journal; [readLast] is only the fallback for a cold start (a
 * resumed journal nobody has written to yet).
 *
 * Call [remember] where a snapshot is accepted but must not be logged (start of a new workout,
 * finish, delete) and [accept] around an app submit. [lastLine] is what a reducer must read, so it
 * is updated before anything that can throw.
 */
class AppDoneRecorder(
    private val readLast: () -> String?,
    private val done: (setId: String) -> Unit,
    private val undone: (setId: String) -> Unit,
    private val onError: (Exception) -> Unit = {},
) {
    private var last: String? = null
    private var known = false

    /** The last accepted line (null for none); [readLast] only when nothing is remembered yet. */
    @Synchronized
    fun lastLine(): String? {
        if (!known) {
            last = readLast()
            known = true
        }
        return last
    }

    @Synchronized
    fun remember(line: String?) {
        last = line
        known = true
    }

    /**
     * The submit sequence, in the one order that is safe: read the previous line (the cold-start
     * disk read happens HERE, before [append] changes the file), [append] (which also moves the
     * caller's head), [remember] the new line at once so the next reader never sees a stale one,
     * then [apply] (which may throw: the line is already current), and last compare previous with
     * new and log. The compare never touches the remembered line and never throws.
     */
    fun <T> accept(newLine: String, append: () -> Unit, apply: () -> T): T {
        // A failing cold-start read must not fail the submit; without a previous line there is nothing to compare.
        var comparable = true
        val prev = try {
            lastLine()
        } catch (e: Exception) {
            comparable = false
            onError(e)
            null
        }
        append()
        remember(newLine)
        try {
            return apply()
        } finally {
            if (comparable) compare(prev, newLine)
        }
    }

    private fun compare(prev: String?, newLine: String) {
        try {
            val before = prev?.let { Json.parseObject(it) }
            val now = Json.parseObject(newLine)
            SelfCheckKeys.newAppDoneSetIds(before, now).forEach(done)
            SelfCheckKeys.newlyUndoneSetIds(before, now).forEach(undone)
        } catch (e: Exception) {
            onError(e)
        }
    }
}
