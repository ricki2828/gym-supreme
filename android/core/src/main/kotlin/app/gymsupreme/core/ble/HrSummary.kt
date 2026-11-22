package app.gymsupreme.core.ble

/**
 * The strap test's evidence (S3) in a few lines: readings per minute since the workout started
 * and every gap longer than [gapMs] between readings. "HR samples throughout" means no empty
 * minute; a walk-away shows as one gap that closes by itself.
 */
object HrSummary {
    data class Gap(val fromMs: Long, val toMs: Long) {
        val lengthMs: Long get() = toMs - fromMs
    }

    data class Result(val perMinute: List<Int>, val gaps: List<Gap>, val readings: Int)

    /**
     * [readings] are elapsedRealtime stamps in any order; [t0] the workout start and [endMs] its
     * end (or now), on the same clock. Minutes run from [t0]; the last partial minute is included.
     * A gap at the start (strap not yet linked) or the end (strap lost, never back) counts too.
     */
    fun of(readings: List<HrReading>, t0: Long, endMs: Long, gapMs: Long = 5_000): Result {
        require(endMs >= t0)
        val inWindow = readings.filter { it.t in t0..endMs }.sortedBy { it.t }
        val minutes = ((endMs - t0 + 59_999) / 60_000).toInt()
        val per = IntArray(minutes)
        for (r in inWindow) {
            val m = ((r.t - t0) / 60_000).toInt().coerceAtMost(minutes - 1)
            if (m >= 0) per[m]++
        }
        val gaps = ArrayList<Gap>()
        var prev = t0
        for (r in inWindow) {
            if (r.t - prev > gapMs) gaps.add(Gap(prev - t0, r.t - t0))
            prev = r.t
        }
        if (endMs - prev > gapMs) gaps.add(Gap(prev - t0, endMs - t0))
        return Result(per.toList(), gaps, inWindow.size)
    }
}
