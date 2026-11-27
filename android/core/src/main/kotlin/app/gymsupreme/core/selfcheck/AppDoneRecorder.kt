package app.gymsupreme.core.selfcheck

import app.gymsupreme.core.json.Json

/**
 * Self-checks: finds the Done taps (and undos) made in the app by comparing each accepted journal
 * snapshot with the one before it. It keeps the last accepted line in memory, so a submit never
 * re-reads or re-parses the whole journal; [readLast] is only the fallback for a cold start (a
 * resumed journal nobody has written to yet).
 *
 * Call [remember] where a snapshot is accepted but must not be logged ([start][remember] of a new
 * workout, a lock-screen action, finish, delete) and [accepted] for an app submit, AFTER the line
 * is appended and applied. Never throws.
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

    @Synchronized
    fun accepted(newLine: String) {
        try {
            val prev = lastLine()
            remember(newLine)
            val before = prev?.let { Json.parseObject(it) }
            val now = Json.parseObject(newLine)
            SelfCheckKeys.newAppDoneSetIds(before, now).forEach(done)
            SelfCheckKeys.newlyUndoneSetIds(before, now).forEach(undone)
        } catch (e: Exception) {
            remember(newLine)
            onError(e)
        }
    }
}
