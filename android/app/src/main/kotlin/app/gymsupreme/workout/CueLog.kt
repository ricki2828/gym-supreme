package app.gymsupreme.workout

import android.content.Context

/**
 * The last timer block's cue log for the Diagnostics export (0.3 cut T1; plan section 5 item 2:
 * the Pixel 20/20 screen-off run is read from the export). Kept in SharedPreferences, reported
 * through getNativeCounters beside [NativeCounters] (no Pigeon change), so it lands in the JSON
 * export under `counters.native`:
 * - `timer_last_block_cues`: cues in the block (highest index + 1);
 * - `timer_last_block_fired` / `_late` (played > 1 s late) / `_missed` (overdue, not played) /
 *   `_max_late_ms` (over played cues);
 * - `timer_last_cue_NN_late_ms`: each cue's lateness, NN = index + 1.
 * A new block (another set, or a higher run) starts a fresh log. The full per-cue JSON lines
 * (`cue` events) stay in the spike log.
 */
object CueLog {
    private const val PREFS = "gymsupreme.cuelog"
    private const val ID = "timer_last_block_id"
    const val CUES = "timer_last_block_cues"
    const val FIRED = "timer_last_block_fired"
    const val LATE = "timer_last_block_late"
    const val MISSED = "timer_last_block_missed"
    const val MAX_LATE_MS = "timer_last_block_max_late_ms"
    private val SUMMARY = listOf(CUES, FIRED, LATE, MISSED, MAX_LATE_MS)

    fun cueKey(index: Int) = "timer_last_cue_%02d_late_ms".format(index + 1)

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** A block was armed with [cues] cues: start its log if it is a new block. */
    @Synchronized
    fun armed(c: Context, setId: String, run: Long, cues: Int) {
        val p = prefs(c)
        val id = "$setId|$run"
        if (p.getString(ID, null) != id) {
            p.edit().clear().putString(ID, id).putLong(CUES, cues.toLong()).commit()
        } else if (cues > p.getLong(CUES, 0)) {
            p.edit().putLong(CUES, cues.toLong()).commit()
        }
    }

    @Synchronized
    fun cue(c: Context, setId: String, run: Long, index: Int, lateMs: Long, missed: Boolean) {
        val p = prefs(c)
        if (p.getString(ID, null) != "$setId|$run") armed(c, setId, run, index + 1)
        val e = p.edit().putLong(cueKey(index), lateMs)
        if (missed) {
            e.putLong(MISSED, p.getLong(MISSED, 0) + 1)
        } else {
            e.putLong(FIRED, p.getLong(FIRED, 0) + 1)
            if (lateMs > NativeCounters.LATE_MS) e.putLong(LATE, p.getLong(LATE, 0) + 1)
            if (lateMs > p.getLong(MAX_LATE_MS, 0)) e.putLong(MAX_LATE_MS, lateMs)
        }
        e.commit()
    }

    /** Summary first, then one entry per cue in index order; empty before any block ran. */
    fun all(c: Context): Map<String, Long> {
        val p = prefs(c)
        if (p.getString(ID, null) == null) return emptyMap()
        val out = LinkedHashMap<String, Long>()
        for (k in SUMMARY) out[k] = p.getLong(k, 0)
        p.all.keys.filter { it.startsWith("timer_last_cue_") }.sorted().forEach { out[it] = p.getLong(it, 0) }
        return out
    }
}
