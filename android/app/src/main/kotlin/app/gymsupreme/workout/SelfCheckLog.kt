package app.gymsupreme.workout

import android.content.Context
import android.util.Log
import app.gymsupreme.core.selfcheck.SelfCheckKeys

/**
 * Evidence for the Diagnostics "Self-checks" section (0.3.2): what the app saw during real use,
 * kept as three small ring buffers in SharedPreferences and reported through getNativeCounters
 * (no Pigeon change), so it also lands in the JSON export under `counters.native` as raw keys.
 * Long values only; the verdict rules live in Dart (`lib/app/self_checks.dart`), which reads
 * these same keys. Bounded: [CUE_SLOTS] + [LOCK_SLOTS] + [HEALTH_SLOTS] entries, oldest
 * overwritten. Nothing leaves the phone; every call swallows its own errors.
 *
 * Auto Backup: deliberately NOT backed up (`backup_rules.xml` / `data_extraction_rules.xml` allow-list
 * only `gymsupreme.counters.xml`): evidence about this phone's behaviour must not restore onto another.
 *
 * Keys, NN = slot (seq % size, ASCII digits), all Long. Each ring also writes `<ring>_slots`, its size,
 * which Dart reads, so the two sides cannot disagree about it:
 * - `sc_cue_next`, `sc_cue_NN_{seq,wall,late,flags,blk}`: one per timer cue.
 *   `late` = ms after the scheduled time. `flags` bits: 0 missed, 1 screen off, 2 battery saver,
 *   3 doze, 4 tone failed, 5 rest alert, 6 music playing, 8-9 audio route
 *   (0 speaker, 1 wired, 2 bluetooth, 3 other). `blk` = hash of the timer block.
 * - `sc_rest_next`, `sc_rest_NN_{seq,wall,late,flags,blk}`: the same for rest alerts (own ring, so a
 *   long timer block cannot push them out and the other way round; `blk` is 0).
 * - `sc_lock_next`, `sc_lock_NN_{seq,wall,act,out,set,rev,src}`: one per Done / +1 / Skip action.
 *   `act` 1 done, 2 +1 rep, 3 skip rest. `src` 0 lock screen, 1 in the app (only Done is logged from
 *   the app, so a lock-screen and an in-app Done on one set can be compared). `out` 0 applied,
 *   1 debounced, 2 stale rev, 3 flag off, 4 error, 5 not pending (set already done, the reducer's
 *   guard working), 6 paused, 7 finished, 8 unknown set, 9 not eligible, 10 no session, 11 no journal,
 *   12 other. `set` = hash of the set id.
 * - `sc_health_next`, `sc_health_NN_{seq,wall,op,out,n}`: one per Health Connect write/delete.
 *   `op` 0 write, 1 delete. `out` 0 ok, 1 failed, 2 permission denied, 3 not available, 4 disabled.
 */
object SelfCheckLog {
    private const val PREFS = "gymsupreme.selfcheck"
    const val CUE_SLOTS = 60
    const val REST_SLOTS = 30
    const val LOCK_SLOTS = 20
    const val HEALTH_SLOTS = 10

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Stable positive hash of an id: the log needs "same set" and "same block", not the text. */
    fun hash(s: String?): Long = (s?.hashCode()?.toLong() ?: 0L) and 0x7fffffffL

    /** The flags word of a cue; [rest] true for a rest alert. */
    fun cueFlags(c: Context, missed: Boolean, toneFailed: Boolean, rest: Boolean): Long {
        var f = 0L
        if (missed) f = f or (1L shl 0)
        if (toneFailed) f = f or (1L shl 4)
        if (rest) f = f or (1L shl 5)
        try {
            val d = DeviceState.snapshot(c)
            if (!d.screenOn) f = f or (1L shl 1)
            if (d.batterySaver) f = f or (1L shl 2)
            if (d.doze) f = f or (1L shl 3)
            if (d.music) f = f or (1L shl 6)
            f = f or (d.route.toLong() shl 8)
        } catch (e: Exception) {
            Log.w(SpikeLog.TAG, "self-check device state failed: $e")
        }
        return f
    }

    @Synchronized
    fun cue(c: Context, block: String?, lateMs: Long, missed: Boolean, toneFailed: Boolean, rest: Boolean) {
        val f = cueFlags(c, missed, toneFailed, rest)
        put(c, if (rest) "sc_rest" else "sc_cue", if (rest) REST_SLOTS else CUE_SLOTS) { p ->
            p.put("late", lateMs).put("flags", f).put("blk", if (rest) 0 else hash(block))
        }
    }

    /** [fromApp]: a Done made in the app (logged from the journal submit), not a notification tap. */
    @Synchronized
    fun lock(c: Context, action: Long, outcome: String, setId: String?, rev: Long, fromApp: Boolean = false) {
        val reason = outcome.removePrefix("noop:")
        val out = when {
            outcome == "applied" -> 0L
            outcome == "debounced" -> 1L
            outcome == "stale_rev" -> 2L
            outcome == "flag_off" -> 3L
            outcome == "error" -> 4L
            reason == "not_pending" -> 5L
            reason == "paused" -> 6L
            reason == "finished" -> 7L
            reason == "unknown_set" -> 8L
            reason == "not_eligible" -> 9L
            reason == "no_session" -> 10L
            reason == "no_journal" -> 11L
            else -> 12L
        }
        put(c, "sc_lock", LOCK_SLOTS) { p ->
            p.put("act", action).put("out", out).put("set", hash(setId)).put("rev", rev).put("src", if (fromApp) 1L else 0L)
        }
    }

    @Synchronized
    fun health(c: Context, delete: Boolean, outcome: String, count: Int) {
        val out = when (outcome.lowercase()) {
            "ok" -> 0L
            "failed" -> 1L
            "permission_denied" -> 2L
            "not_available" -> 3L
            else -> 4L
        }
        put(c, "sc_health", HEALTH_SLOTS) { p -> p.put("op", if (delete) 1L else 0L).put("out", out).put("n", count.toLong()) }
    }

    /** Field collector for one ring entry. */
    class Fields {
        internal val m = LinkedHashMap<String, Long>()
        fun put(k: String, v: Long): Fields = apply { m[k] = v }
    }

    private fun put(c: Context, base: String, slots: Int, fill: (Fields) -> Fields) {
        try {
            val p = prefs(c)
            val seq = p.getLong("${base}_next", 0) + 1
            val slot = SelfCheckKeys.slot(base, seq, slots)
            val e = p.edit()
                .putLong("${base}_next", seq)
                .putLong("${base}_slots", slots.toLong())
                .putLong("${slot}_seq", seq)
                .putLong("${slot}_wall", System.currentTimeMillis())
            for ((k, v) in fill(Fields()).m) e.putLong("${slot}_$k", v)
            e.apply()
        } catch (e: Exception) {
            Log.w(SpikeLog.TAG, "self-check log failed: $e")
        }
    }

    /** Every key, for the export; empty before anything was recorded. */
    fun all(c: Context): Map<String, Long> = try {
        prefs(c).all.filter { it.key.startsWith("sc_") }.mapNotNull { (k, v) -> (v as? Long)?.let { k to it } }.toMap(java.util.TreeMap())
    } catch (_: Exception) {
        emptyMap()
    }
}
