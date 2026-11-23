package app.gymsupreme.core.journal

import app.gymsupreme.core.json.Json
import app.gymsupreme.core.json.JsonException
import app.gymsupreme.core.json.long
import app.gymsupreme.core.json.str

/**
 * The live-workout journal (plan 6.2, 7; t3x 23-Nov): one full snapshot per line, appended and
 * fsynced by the Kotlin service, which is its only writer and the `rev` authority. Dart submits
 * a whole snapshot against the rev it last saw; a stale submit is refused, so cut 2's lock-screen
 * Done (Kotlin writes the next rev itself) needs no format change.
 *
 * Reading: the last good line wins. A torn last line (a crash mid-write) is ignored; an
 * unreadable line before it counts as corrupt (it feeds the "lost or corrupt journal" counter)
 * but does not hide the good lines after it. Lines must all carry the same workout uuid and a
 * strictly rising rev; a line that breaks that is corrupt too.
 */
object Journal {
    const val F_SCHEMA = "schema"
    const val F_UUID = "workout_uuid"
    const val F_REV = "rev"
    const val F_FINISHED = "finished"

    /** Snapshot schema versions this build can journal and resume. */
    val SUPPORTED_SCHEMAS = setOf(1L)

    data class Head(val uuid: String, val rev: Long, val schema: Long, val finished: Boolean)

    /** The fields the service checks on every line; the rest of the snapshot is the view's business. */
    fun head(snapshot: Map<String, Any?>): Head = Head(
        uuid = snapshot.str(F_UUID),
        rev = snapshot.long(F_REV),
        schema = snapshot.long(F_SCHEMA),
        finished = snapshot[F_FINISHED] as? Boolean ?: false,
    )

    sealed class Submit {
        data class Accepted(val line: String, val head: Head, val snapshot: Map<String, Any?>) : Submit()
        data class Rejected(val code: String, val message: String) : Submit()
    }

    /**
     * A snapshot from Dart. [current] is the journal's last head (null: nothing running yet,
     * which is only allowed for a start). The snapshot's own rev must be `baseRev + 1` and
     * `baseRev` must be the current rev, so two writers can never both win.
     */
    fun submit(json: String, baseRev: Long, current: Head?, isStart: Boolean): Submit {
        if (json.indexOf('\n') >= 0 || json.indexOf('\r') >= 0) return Submit.Rejected("bad_snapshot", "snapshot must be one line")
        val snap = try {
            Json.parseObject(json)
        } catch (e: JsonException) {
            return Submit.Rejected("bad_snapshot", "not JSON: ${e.message}")
        }
        val h = try {
            head(snap)
        } catch (e: JsonException) {
            return Submit.Rejected("bad_snapshot", e.message ?: "bad head")
        }
        if (h.schema !in SUPPORTED_SCHEMAS) return Submit.Rejected("bad_schema", "schema ${h.schema} not supported")
        if (isStart) {
            if (current != null && !current.finished) return Submit.Rejected("already_running", "workout ${current.uuid} is in progress")
            if (baseRev != 0L || h.rev != 0L) return Submit.Rejected("stale_rev", "a start is rev 0")
        } else {
            if (current == null) return Submit.Rejected("not_running", "no workout in progress")
            if (h.uuid != current.uuid) return Submit.Rejected("wrong_workout", "snapshot is for ${h.uuid}, journal is ${current.uuid}")
            if (current.finished) return Submit.Rejected("finished", "workout already finished")
            if (baseRev != current.rev) return Submit.Rejected("stale_rev", "base rev $baseRev, journal is at ${current.rev}")
            if (h.rev != baseRev + 1) return Submit.Rejected("stale_rev", "snapshot rev ${h.rev} must be base + 1")
        }
        return Submit.Accepted(json, h, snap)
    }

    data class Read(
        /** The last good snapshot line, verbatim, or null if none. */
        val lastLine: String?,
        val last: Head?,
        val goodLines: Int,
        val corruptLines: Int,
        val tornTail: Boolean,
    )

    /** Reads journal text written by [submit]-accepted appends (each line ends with '\n'). */
    fun read(text: String): Read {
        if (text.isEmpty()) return Read(null, null, 0, 0, false)
        val complete = text.endsWith("\n")
        val lines = text.split('\n').let { if (complete) it.dropLast(1) else it }
        var lastLine: String? = null
        var last: Head? = null
        var good = 0
        var corrupt = 0
        var torn = false
        for ((i, line) in lines.withIndex()) {
            val isTail = i == lines.size - 1 && !complete
            val h = try {
                head(Json.parseObject(line)).takeIf { it.schema in SUPPORTED_SCHEMAS }
            } catch (_: JsonException) {
                null
            }
            val fits = h != null && (last == null || (h.uuid == last.uuid && h.rev > last.rev && !last.finished))
            when {
                fits -> {
                    lastLine = line
                    last = h
                    good++
                }
                isTail -> torn = true
                else -> corrupt++
            }
        }
        return Read(lastLine, last, good, corrupt, torn)
    }
}
