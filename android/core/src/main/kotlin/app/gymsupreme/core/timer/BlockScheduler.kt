package app.gymsupreme.core.timer

/**
 * One cue of a timer block as Dart compiled it (`contracts/session_snapshot.md`, block section;
 * producer `gym_engine/lib/src/cut2/timers.dart`). [atMs] is an offset from the block's
 * `started_at_wall_ms`; Dart already rebased it by `elapsed_before_ms` on resume, so it is never
 * subtracted again here. [kind] stays a string: kinds Kotlin does not know play the default cue.
 */
data class BlockCue(val index: Int, val atMs: Long, val kind: String, val label: String)

/** A started timer block on a pending set: what the scheduler arms. */
data class TimerBlockSpec(val setId: String, val run: Long, val startedAtWallMs: Long, val cues: List<BlockCue>)

/**
 * Durable record of what already buzzed, per workout (cut T1): a cue is `(set_id, run, index)`,
 * a rest is its set id. The service's store commits each key to app-private storage before the
 * buzz, so a cue never fires twice across a re-applied snapshot, a pause/resume (which stops the
 * whole service) or process death. Implementations must be safe to call from one thread at a time.
 */
interface FiredStore {
    fun contains(key: String): Boolean

    /** Commit [key] durably; returns only once it is written. */
    fun add(key: String)

    fun removeIf(p: (String) -> Boolean)
}

/** In-memory [FiredStore] (tests; the durable one lives in the app module). */
class MemoryFiredStore : FiredStore {
    val keys = LinkedHashSet<String>()
    override fun contains(key: String) = key in keys
    override fun add(key: String) {
        keys.add(key)
    }

    override fun removeIf(p: (String) -> Boolean) {
        keys.removeAll(p)
    }
}

object FiredKeys {
    private fun clean(s: String) = s.replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')

    fun cue(setId: String, run: Long, index: Int) = "c\t${clean(setId)}\t$run\t$index"

    fun rest(setId: String) = "r\t${clean(setId)}"

    /** True for a cue key of [setId] with a run below [run]. */
    fun olderRun(key: String, setId: String, run: Long): Boolean {
        val p = key.split('\t')
        return p.size == 4 && p[0] == "c" && p[1] == clean(setId) && (p[2].toLongOrNull() ?: Long.MAX_VALUE) < run
    }
}

/**
 * Runs the snapshot's timer blocks against `elapsedRealtime` (0.3 cut T1, plan item 7, R4). Pure:
 * the service feeds it every accepted snapshot ([onSnapshot]), asks [nextAt] when to wake, and on
 * each wake takes [due]. Like [CueClock], a cue is an offset from an anchor, never from the
 * previous fire, so a late wake never pushes later cues back.
 *
 * - Anchor once: a block is identified by `(set_id, run, started_at_wall_ms)`. The first snapshot
 *   that carries it maps the wall anchor to elapsed time (`t0 = now - (nowWall - startedAt)`);
 *   later snapshots with the same identity (a mark tap, an unrelated rev) keep it, so a wall-clock
 *   change mid-block does not move the cues.
 * - Fire once: every cue key goes through the [FiredStore] and is committed before [due] hands it
 *   out, so the caller buzzes only after the record is durable.
 * - Late wake while armed: every due cue fires once, in order, with its lateness.
 * - Overdue at arm time by more than [staleMs] (process death, an app reopened minutes later):
 *   recorded as missed, no buzz. A resume-grace resend (`at_ms` 0) is only ms late and fires.
 * - Cancel: a set that is no longer pending, a block without anchor or cues, a pause, a finish:
 *   whatever the anchor says.
 */
class BlockScheduler(private val store: FiredStore, private val staleMs: Long = STALE_MS) {
    private class Armed(val spec: TimerBlockSpec, val t0: Long) {
        val cues = spec.cues.sortedWith(compareBy<BlockCue> { it.atMs }.thenBy { it.index })
        var next = 0
        fun scheduledAt(c: BlockCue) = t0 + c.atMs
    }

    sealed class Change {
        data class Armed(val spec: TimerBlockSpec, val t0: Long, val alreadyFired: Int, val overdue: Int) : Change()

        data class Kept(val setId: String, val run: Long) : Change()

        data class Cancelled(val setId: String, val run: Long, val why: String) : Change()
    }

    /** One cue handed to the caller, already committed. [missed] = overdue at arm time: log only. */
    data class Due(val setId: String, val run: Long, val cue: BlockCue, val scheduledAt: Long, val lateMs: Long, val missed: Boolean)

    private val armed = LinkedHashMap<String, Armed>()
    private val missedQueue = ArrayList<Due>()

    /** Blocks armed (fired out or not). */
    val armedSetIds: Set<String> get() = armed.keys

    fun onSnapshot(blocks: List<TimerBlockSpec>, paused: Boolean, nowWallMs: Long, nowElapsedMs: Long): List<Change> {
        if (paused) return clear("paused")
        val out = ArrayList<Change>()
        val wanted = LinkedHashMap<String, TimerBlockSpec>()
        for (b in blocks) if (b.cues.isNotEmpty()) wanted.putIfAbsent(b.setId, b)
        val it = armed.entries.iterator()
        while (it.hasNext()) {
            val (id, a) = it.next()
            if (id !in wanted) {
                it.remove()
                dropQueued(id)
                out.add(Change.Cancelled(id, a.spec.run, "stopped"))
            }
        }
        for (b in wanted.values) {
            val a = armed[b.setId]
            if (a != null && a.spec.run == b.run && a.spec.startedAtWallMs == b.startedAtWallMs) {
                out.add(Change.Kept(b.setId, b.run))
                continue
            }
            if (a != null) {
                dropQueued(b.setId)
                out.add(Change.Cancelled(b.setId, a.spec.run, "replaced"))
            }
            out.add(arm(b, nowWallMs, nowElapsedMs))
        }
        return out
    }

    private fun arm(b: TimerBlockSpec, nowWallMs: Long, nowElapsedMs: Long): Change.Armed {
        // A higher run is a re-arm (reset, undo, new definition): the older runs' keys can go.
        if (b.run > 0) store.removeIf { FiredKeys.olderRun(it, b.setId, b.run) }
        val t0 = nowElapsedMs - (nowWallMs - b.startedAtWallMs).coerceAtLeast(0)
        val a = Armed(b, t0)
        armed[b.setId] = a
        var already = 0
        var overdue = 0
        while (a.next < a.cues.size) {
            val c = a.cues[a.next]
            val key = FiredKeys.cue(b.setId, b.run, c.index)
            if (store.contains(key)) {
                already++
                a.next++
                continue
            }
            val late = nowElapsedMs - a.scheduledAt(c)
            if (late <= staleMs) break
            store.add(key)
            missedQueue.add(Due(b.setId, b.run, c, a.scheduledAt(c), late, missed = true))
            overdue++
            a.next++
        }
        // Count the already-fired cues further on too (re-applied after a late fire).
        for (i in a.next until a.cues.size) if (store.contains(FiredKeys.cue(b.setId, b.run, a.cues[i].index))) already++
        return Change.Armed(b, t0, already, overdue)
    }

    private fun dropQueued(setId: String) {
        missedQueue.removeAll { it.setId == setId }
    }

    /** Cues whose time has come, oldest first, each committed to the store; missed ones first. */
    fun due(nowElapsedMs: Long): List<Due> {
        val out = ArrayList<Due>(missedQueue)
        missedQueue.clear()
        val fresh = ArrayList<Due>()
        for (a in armed.values) {
            while (a.next < a.cues.size && a.scheduledAt(a.cues[a.next]) <= nowElapsedMs) {
                val c = a.cues[a.next++]
                val key = FiredKeys.cue(a.spec.setId, a.spec.run, c.index)
                if (store.contains(key)) continue
                store.add(key)
                fresh.add(Due(a.spec.setId, a.spec.run, c, a.scheduledAt(c), nowElapsedMs - a.scheduledAt(c), missed = false))
            }
        }
        fresh.sortBy { it.scheduledAt }
        out.addAll(fresh)
        return out
    }

    /** Elapsed time of the next cue still to fire (skipping ones already in the store), or null. */
    fun nextAt(): Long? {
        if (missedQueue.isNotEmpty()) return Long.MIN_VALUE
        var best: Long? = null
        for (a in armed.values) {
            while (a.next < a.cues.size && store.contains(FiredKeys.cue(a.spec.setId, a.spec.run, a.cues[a.next].index))) a.next++
            val c = a.cues.getOrNull(a.next) ?: continue
            val t = a.scheduledAt(c)
            if (best == null || t < best) best = t
        }
        return best
    }

    /** The next cue to fire and its elapsed time, for the notification. */
    fun peek(): Pair<BlockCue, Long>? {
        nextAt() ?: return null
        var best: Pair<BlockCue, Long>? = null
        for (a in armed.values) {
            val c = a.cues.getOrNull(a.next) ?: continue
            val t = a.scheduledAt(c)
            if (best == null || t < best.second) best = c to t
        }
        return best
    }

    /** Elapsed time of the last cue of every armed block, for bounding the wake lock. */
    fun lastAt(): Long? = armed.values.mapNotNull { a -> a.cues.lastOrNull()?.let { a.scheduledAt(it) } }.maxOrNull()

    /** Pause, finish or stop: cancel everything armed. */
    fun clear(why: String): List<Change> {
        val out = armed.values.map { Change.Cancelled(it.spec.setId, it.spec.run, why) }
        armed.clear()
        missedQueue.clear()
        return out
    }

    companion object {
        /**
         * A cue more than this overdue when its block is armed is recorded as missed, not played:
         * a beep minutes late would tell him the wrong minute.
         */
        const val STALE_MS = 5_000L
    }
}
