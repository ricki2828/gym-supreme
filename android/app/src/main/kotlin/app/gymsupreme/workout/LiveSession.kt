package app.gymsupreme.workout

import android.content.Context
import android.content.SharedPreferences
import app.gymsupreme.core.journal.FinishStamp
import app.gymsupreme.core.journal.Journal
import app.gymsupreme.core.journal.SnapshotView
import app.gymsupreme.core.json.Json
import app.gymsupreme.core.json.JsonException
import app.gymsupreme.core.json.JsonWriter

/**
 * The live workout's native side (t3x 23-Nov ruling on t5v's proposal; plan 6.2, 7). Dart runs the
 * transitions in cut 1 and submits each whole snapshot; this object is the journal's only writer
 * and the rev authority, and drives [WorkoutService] (rest alert + notification) from what it
 * accepts. Pigeon calls land here (lane A wires them). Main thread only.
 *
 * Lifecycle: the service starts only from the visible activity (every call here comes from Dart
 * in the activity) and is not sticky, so crash-safe resume is "a journal found on next open":
 * [readPending] returns its last good snapshot; Dart offers Resume, or stores a finished one and
 * calls [delete]. Pause keeps the journal and stops the service.
 */
class LiveSession private constructor(private val context: Context) {
    class Refused(val code: String, message: String) : Exception(message)

    private val store = JournalStore(context)
    private val prefs: SharedPreferences = context.getSharedPreferences("gymsupreme.journal", Context.MODE_PRIVATE)
    private var head: Journal.Head? = null
    private var loaded = false

    /** Snapshots the service accepted or wrote, for Dart's stream (cut 2: lock-screen changes). */
    var onSnapshot: ((String) -> Unit)? = null

    private fun current(): Journal.Head? {
        if (!loaded) {
            loaded = true
            head = inspect().last
        }
        return head
    }

    /** Reads the journal; counts corrupt lines and torn tails once per workout; quarantines an unreadable file. */
    private fun inspect(): Journal.Read {
        val r = store.read()
        val last = r.last
        if (last == null) {
            if (store.file.exists() && store.file.length() > 0) {
                val aside = store.quarantine()
                if (aside == null) store.file.delete()
                NativeCounters.add(context, NativeCounters.JOURNALS_LOST)
                SpikeLog.write(context, SpikeLog.line("journal_lost").put("corrupt_lines", r.corruptLines).put("torn_tail", r.tornTail).put("moved_to", aside))
            }
            return r
        }
        // A crash mid-write left half a line: cut it off so the next append starts a clean line.
        if (r.tornTail) store.truncateTornTail()
        val key = "counted:${last.uuid}"
        val counted = prefs.getString(key, null)
        val sig = "${r.corruptLines}/${r.tornTail}"
        if (counted != sig && (r.corruptLines > 0 || r.tornTail)) {
            val prev = counted?.split('/')
            val prevCorrupt = prev?.getOrNull(0)?.toIntOrNull() ?: 0
            val prevTorn = prev?.getOrNull(1) == "true"
            NativeCounters.add(context, NativeCounters.JOURNAL_CORRUPT_LINES, (r.corruptLines - prevCorrupt).coerceAtLeast(0).toLong())
            if (r.tornTail && !prevTorn) NativeCounters.add(context, NativeCounters.JOURNAL_TORN_TAILS)
            prefs.edit().putString(key, sig).apply()
            SpikeLog.write(context, SpikeLog.line("journal_damage").put("uuid", last.uuid).put("corrupt_lines", r.corruptLines).put("torn_tail", r.tornTail))
        }
        return r
    }

    /** Start a workout: rev 0. Refused while any journal is still present (resume goes through [submit]). */
    fun start(json: String): Long {
        val cur = current()
        if (cur != null && cur.finished) throw Refused("finish_pending", "workout ${cur.uuid} is finished but not stored yet; store it, then deleteJournal")
        val r = Journal.submit(json, 0, cur, isStart = true)
        if (r is Journal.Submit.Rejected) throw Refused(r.code, r.message)
        r as Journal.Submit.Accepted
        store.append(r.line)
        head = r.head
        SpikeLog.write(context, SpikeLog.line("session_start").put("uuid", r.head.uuid))
        apply(r.snapshot, r.line)
        return r.head.rev
    }

    /** One whole snapshot from Dart against [baseRev]. Returns the new rev after fsync. */
    fun submit(json: String, baseRev: Long): Long {
        val r = Journal.submit(json, baseRev, current(), isStart = false)
        if (r is Journal.Submit.Rejected) throw Refused(r.code, r.message)
        r as Journal.Submit.Accepted
        store.append(r.line)
        head = r.head
        apply(r.snapshot, r.line)
        return r.head.rev
    }

    /**
     * Stops the service and its alerts; the journal stays for Resume. Dart submits the paused
     * snapshot first (which already stops the service), so this is idempotent while an unfinished
     * journal exists; `not_running` only when there is none.
     */
    fun pause() {
        val cur = current()
        if (cur == null || cur.finished) throw Refused("not_running", "no workout in progress")
        WorkoutService.instance?.endSession("pause")
        SpikeLog.write(context, SpikeLog.line("session_pause").put("uuid", head?.uuid))
    }

    /**
     * Finish (plan 7, B1): writes `finished=true` (and `ended_at_ms` if Dart left it null) as the
     * next rev, fsyncs, stops the service, then returns that snapshot. Dart upserts it into
     * SQLite in one transaction and only then calls [delete].
     */
    fun finish(): String {
        val cur = current() ?: throw Refused("not_running", "no workout in progress")
        val line = store.read().lastLine ?: throw Refused("not_running", "journal unreadable")
        if (cur.finished) {
            WorkoutService.instance?.endSession("finish")
            onSnapshot?.invoke(line)
            return line
        }
        val out = JsonWriter.write(FinishStamp.stamp(Json.parseObject(line), System.currentTimeMillis()))
        val r = Journal.submit(out, cur.rev, cur, isStart = false)
        if (r is Journal.Submit.Rejected) throw Refused(r.code, r.message)
        store.append(out)
        head = (r as Journal.Submit.Accepted).head
        WorkoutService.instance?.endSession("finish")
        SpikeLog.write(context, SpikeLog.line("session_finish").put("uuid", cur.uuid).put("rev", cur.rev + 1))
        onSnapshot?.invoke(out)
        return out
    }

    /** The last good snapshot of a journal left by an earlier run (resume or store), or null. */
    fun readPending(): String? {
        loaded = true
        val r = inspect()
        head = r.last
        return r.lastLine
    }

    /**
     * Dart stored workout [uuid]; the journal goes. False if the journal is another workout's.
     * Every refusal, mismatch or IO failure counts in `journal_delete_failed` with its code in the
     * log (t3x 23-Nov): a journal that will not go blocks every later Start with finish_pending.
     */
    fun delete(uuid: String): Boolean {
        val ok = try {
            deleteChecked(uuid)
        } catch (e: Refused) {
            deleteFailed(uuid, e.code, e.message)
            throw e
        } catch (e: Exception) {
            deleteFailed(uuid, "io_error", "${e.javaClass.simpleName}: ${e.message}")
            throw Refused("io_error", "could not delete the journal: ${e.message}")
        }
        if (!ok) deleteFailed(uuid, "wrong_workout", "journal belongs to ${head?.uuid}")
        return ok
    }

    private fun deleteFailed(uuid: String, code: String, message: String?) {
        NativeCounters.add(context, NativeCounters.JOURNAL_DELETE_FAILED)
        SpikeLog.write(context, SpikeLog.line("journal_delete_failed").put("uuid", uuid).put("code", code).put("message", message))
    }

    private fun deleteChecked(uuid: String): Boolean {
        val cur = current()
        if (cur != null && cur.uuid == uuid && !cur.finished && WorkoutService.status.running) {
            throw Refused("still_running", "finish or pause before deleting the journal")
        }
        val ok = store.deleteIf(uuid)
        if (ok) {
            head = null
            prefs.edit().remove("counted:$uuid").apply()
        }
        SpikeLog.write(context, SpikeLog.line("journal_delete").put("uuid", uuid).put("ok", ok))
        return ok
    }

    fun counters(): Map<String, Long> = NativeCounters.all(context)

    /** An accepted snapshot: start or update the service from the visible activity, or stop it on pause. */
    private fun apply(snapshot: Map<String, Any?>, line: String) {
        val view = try {
            SnapshotView.of(snapshot)
        } catch (e: JsonException) {
            SpikeLog.write(context, SpikeLog.line("snapshot_view_error").put("message", e.message))
            null
        }
        if (view != null) {
            if (view.paused) {
                WorkoutService.instance?.endSession("pause")
            } else {
                WorkoutService.session(context, view)
            }
        }
        onSnapshot?.invoke(line)
    }

    companion object {
        private var instance: LiveSession? = null

        fun get(context: Context): LiveSession = instance ?: LiveSession(context.applicationContext).also { instance = it }
    }
}
