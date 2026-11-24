package app.gymsupreme.workout

import android.content.Context

/**
 * Native gate counters for the export (t3x 23-Nov, B4): journals lost or with corrupt lines, and
 * rest alerts fired, fired late (> [LATE_MS]) or missed (rest ended while the app was dead, found
 * on resume). Dart derives the rest of B4 from rows. Kept in SharedPreferences; never reset.
 */
object NativeCounters {
    private const val PREFS = "gymsupreme.counters"
    const val LATE_MS = 1_000L
    const val JOURNALS_LOST = "journals_lost"
    const val JOURNAL_CORRUPT_LINES = "journal_corrupt_lines"
    const val JOURNAL_TORN_TAILS = "journal_torn_tails"
    const val REST_ALERTS_FIRED = "rest_alerts_fired"
    const val REST_ALERTS_LATE = "rest_alerts_late"
    const val REST_ALERTS_MISSED = "rest_alerts_missed"
    const val REST_ALERT_MAX_LATE_MS = "rest_alert_max_late_ms"
    const val REST_ALERTS_AUDIO_FAILED = "rest_alerts_audio_failed"

    /** deleteJournal refused or failed (code in the log): a stored workout whose journal stays blocks every Start. */
    const val JOURNAL_DELETE_FAILED = "journal_delete_failed"

    /** Timer-block cues (0.3 cut T1), every block: played, played > [LATE_MS] late, overdue and not played, tone failed. */
    const val TIMER_CUES_FIRED = "timer_cues_fired"
    const val TIMER_CUES_LATE = "timer_cues_late"
    const val TIMER_CUES_MISSED = "timer_cues_missed"
    const val TIMER_CUE_MAX_LATE_MS = "timer_cue_max_late_ms"
    const val TIMER_CUES_AUDIO_FAILED = "timer_cues_audio_failed"

    val KEYS = listOf(
        JOURNALS_LOST, JOURNAL_CORRUPT_LINES, JOURNAL_TORN_TAILS, REST_ALERTS_FIRED, REST_ALERTS_LATE,
        REST_ALERTS_MISSED, REST_ALERT_MAX_LATE_MS, REST_ALERTS_AUDIO_FAILED, JOURNAL_DELETE_FAILED,
        TIMER_CUES_FIRED, TIMER_CUES_LATE, TIMER_CUES_MISSED, TIMER_CUE_MAX_LATE_MS, TIMER_CUES_AUDIO_FAILED,
    )

    private fun prefs(c: Context) = c.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun add(c: Context, key: String, n: Long = 1) {
        if (n == 0L) return
        val p = prefs(c)
        p.edit().putLong(key, p.getLong(key, 0) + n).commit()
    }

    @Synchronized
    fun max(c: Context, key: String, v: Long) {
        val p = prefs(c)
        if (v > p.getLong(key, 0)) p.edit().putLong(key, v).commit()
    }

    /** Flag `timers` off: the timer_* keys are left out, so the export matches main before T1. */
    fun all(c: Context): Map<String, Long> {
        val p = prefs(c)
        val keys = if (Features.timers) KEYS else KEYS.filterNot { it.startsWith("timer_") }
        return keys.associateWith { p.getLong(it, 0) }
    }
}
