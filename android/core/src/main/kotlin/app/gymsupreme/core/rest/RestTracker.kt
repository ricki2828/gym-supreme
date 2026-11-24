package app.gymsupreme.core.rest

/**
 * One rest as Dart sends it inside a snapshot: a wall-clock end plus its length (Dart cannot see
 * `elapsedRealtime`). [key] identifies the rest (the set it follows), so re-sending the same
 * snapshot, or a snapshot that only changed something else, never re-arms or re-fires it.
 */
data class RestSpec(val key: String, val endsAtWallMs: Long, val durationMs: Long) {
    /**
     * One rest occurrence: the set plus its end. Done X, Undo, Done X again is a new rest with a
     * new end, so it buzzes again; a re-sent snapshot keeps the same end and stays deduped.
     */
    val id: String get() = "$key|$endsAtWallMs"
}

/**
 * Decides what the service does with the rest in each snapshot (plan 6.2, R4): Kotlin re-anchors
 * the wall-clock end to `elapsedRealtime` once, on receipt, and fires from that, so a wall-clock
 * change mid-rest does not move the alert. Pure; the service calls it on every accepted snapshot
 * and on resume.
 */
class RestTracker(
    private val staleGraceMs: Long = STALE_GRACE_MS,
    /**
     * Rests that already buzzed in an earlier process (cut T1: the service's durable fired store,
     * committed before the buzz). Without it a rest could buzz twice after process death plus a
     * resume inside [staleGraceMs]. Called with [RestSpec.id].
     */
    private val firedBefore: (String) -> Boolean = { false },
) {
    sealed class Action {
        /** Nothing changes. */
        object Keep : Action()

        /** Cancel any pending alert (rest skipped, ended early, or the workout paused/finished). */
        object Cancel : Action()

        /** Arm the alert at [atElapsedMs]; cancel any other first. */
        data class Arm(val spec: RestSpec, val atElapsedMs: Long) : Action()

        /** The rest already ended within the grace window (e.g. app reopened just after): alert now. */
        data class FireNow(val spec: RestSpec, val lateMs: Long) : Action()

        /** The rest ended long ago (resumed hours later): do not buzz, just record it. */
        data class Missed(val spec: RestSpec, val lateMs: Long) : Action()
    }

    private var armed: RestSpec? = null
    private val done = HashSet<String>()

    /** The rest currently armed, if any. */
    val current: RestSpec? get() = armed

    fun onSnapshot(rest: RestSpec?, nowWallMs: Long, nowElapsedMs: Long): Action {
        if (rest == null || rest.id in done || firedBefore(rest.id)) {
            if (armed == null) return Action.Keep
            armed = null
            return Action.Cancel
        }
        val a = armed
        if (a != null && a.key == rest.key && a.endsAtWallMs == rest.endsAtWallMs) return Action.Keep
        val remaining = rest.endsAtWallMs - nowWallMs
        if (remaining > 0) {
            armed = rest
            return Action.Arm(rest, nowElapsedMs + remaining)
        }
        armed = null
        done.add(rest.id)
        return if (-remaining <= staleGraceMs) Action.FireNow(rest, -remaining) else Action.Missed(rest, -remaining)
    }

    /** The armed alert fired ([RestSpec.id]); the same rest never fires again. */
    fun onFired(id: String) {
        done.add(id)
        if (armed?.id == id) armed = null
    }

    /** Pause, finish or service stop. */
    fun clear(): Action {
        if (armed == null) return Action.Keep
        armed = null
        return Action.Cancel
    }

    companion object {
        const val STALE_GRACE_MS = 30_000L
    }
}
