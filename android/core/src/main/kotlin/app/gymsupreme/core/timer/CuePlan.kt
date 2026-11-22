package app.gymsupreme.core.timer

/**
 * What a timed block asks the service to do at a given moment (plan 6.2, R4). Every cue is an
 * offset from the block's start on the `elapsedRealtime` clock, so a late cue never pushes the
 * next one later: cue k fires at `t0 + atMs`, never at "previous fire + period".
 */
data class Cue(val index: Int, val kind: CueKind, val atMs: Long, val label: String)

enum class CueKind(val wire: String) {
    /** A rest finished: buzz plus tone, "go". */
    REST_END("rest_end"),

    /** The start of an EMOM minute. */
    EMOM_MINUTE("emom_minute"),

    /** No sound: marks a point in the log (the strap test's 45-minute mark). */
    MARK("mark"),

    /** CI emulator self-test (S5): one cue a few seconds after start. */
    SELFTEST("selftest"),
}

/**
 * The phase-0 spike (brief section 5, runbook card): from one "Start all" tap, [rests] rests of
 * [restMs] back to back (S1), then a [emomMinutes]-minute EMOM with a cue at the start of every
 * minute (S2), while the strap is tracked throughout (S3). A silent mark at [strapMarkMs]
 * records that the 45-minute strap window was reached; the service keeps tracking until Stop.
 */
object CuePlan {
    const val SPIKE_RESTS = 10
    const val SPIKE_REST_MS = 90_000L
    const val SPIKE_EMOM_MINUTES = 20
    const val SPIKE_STRAP_MARK_MS = 45 * 60_000L
    const val SELFTEST_DELAY_MS = 3_000L

    fun spike(
        rests: Int = SPIKE_RESTS,
        restMs: Long = SPIKE_REST_MS,
        emomMinutes: Int = SPIKE_EMOM_MINUTES,
        strapMarkMs: Long = SPIKE_STRAP_MARK_MS,
    ): List<Cue> {
        require(rests >= 0 && restMs > 0 && emomMinutes >= 0)
        val out = ArrayList<Cue>()
        for (k in 1..rests) out.add(Cue(0, CueKind.REST_END, k * restMs, "rest $k of $rests"))
        val emomStart = rests * restMs
        for (m in 0 until emomMinutes) out.add(Cue(0, CueKind.EMOM_MINUTE, emomStart + m * 60_000L, "EMOM minute ${m + 1} of $emomMinutes"))
        out.add(Cue(0, CueKind.MARK, strapMarkMs, "strap ${strapMarkMs / 60_000} min mark"))
        return out.sortedWith(compareBy<Cue> { it.atMs }.thenBy { it.kind.ordinal })
            .mapIndexed { i, c -> c.copy(index = i) }
    }

    fun selftest(): List<Cue> = listOf(Cue(0, CueKind.SELFTEST, SELFTEST_DELAY_MS, "selftest cue"))
}

/**
 * Walks a cue list against the clock. Pure: the service asks [due] what to fire now and
 * [delayToNext] how long to sleep, on `elapsedRealtime`. A wake-up that comes early fires
 * nothing; one that comes late fires every cue that is due, each once, in order.
 */
class CueClock(private val cues: List<Cue>, val t0: Long) {
    private var next = 0

    val done: Boolean get() = next >= cues.size
    val firedCount: Int get() = next

    /** Scheduled elapsedRealtime of a cue. */
    fun scheduledAt(c: Cue): Long = t0 + c.atMs

    /** Cues whose time has come and that have not fired yet, in order; each is returned once. */
    fun due(nowMs: Long): List<Cue> {
        val out = ArrayList<Cue>()
        while (next < cues.size && scheduledAt(cues[next]) <= nowMs) out.add(cues[next++])
        return out
    }

    /** Milliseconds until the next cue (0 if one is already due), or null when all have fired. */
    fun delayToNext(nowMs: Long): Long? {
        if (done) return null
        return (scheduledAt(cues[next]) - nowMs).coerceAtLeast(0)
    }

    /** The next cue that will fire, or null. */
    fun peek(): Cue? = cues.getOrNull(next)
}
