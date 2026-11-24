package app.gymsupreme.core.journal

import app.gymsupreme.core.json.long
import app.gymsupreme.core.json.longOrNull
import app.gymsupreme.core.json.objList
import app.gymsupreme.core.json.objOrNull
import app.gymsupreme.core.json.str
import app.gymsupreme.core.json.strOrNull
import app.gymsupreme.core.rest.RestSpec
import app.gymsupreme.core.session.LockReducer
import app.gymsupreme.core.timer.BlockCue
import app.gymsupreme.core.timer.TimerBlockSpec

/**
 * What the service needs from a snapshot (schema v1, `packages/gym_engine/lib/src/snapshot.dart`,
 * `contracts/session_snapshot.md`): the running rest, whether the workout is paused, and the
 * notification lines (R3: exercise, set n of m, the load and reps Done will log, rest countdown).
 * Everything else in the snapshot passes through untouched.
 */
data class SnapshotView(
    val paused: Boolean,
    val rest: RestSpec?,
    /** Null when every set is done or skipped. */
    val current: Current?,
    val setsDone: Int,
    val setsTotal: Int,
    /** The snapshot's rev: lock-screen actions carry it and are dropped when it is stale (L1). */
    val rev: Long = -1,
    /** [current]'s set id, for lock-screen Done / +1 rep. */
    val currentSetId: String? = null,
    /** Whether Done / +1 rep may be offered for [current] ([LockReducer.eligible]). */
    val lockEligible: Boolean = false,
    /** The snapshot's workout_uuid (the durable fired-cue store is per workout). */
    val workoutUuid: String? = null,
    /**
     * Started timer blocks on pending sets (cut T1): anchor set and cues left. Any pending set, not
     * only [current]. Read leniently: a malformed block is left out (and counted in
     * [badBlocks]) instead of failing the whole view, so the rest alert keeps working.
     */
    val blocks: List<TimerBlockSpec> = emptyList(),
    val badBlocks: Int = 0,
) {
    data class Current(
        val exerciseName: String,
        val setNumber: Int,
        val setCount: Int,
        val loadG: Long?,
        val reps: Long?,
        val loadKind: String,
        val unilateral: Boolean,
        val timed: Boolean = false,
    )

    /** "22.5 kg ea x 10", "Bodyweight x 12", "Starting weight?" (cold start). */
    fun doneLine(): String? {
        val c = current ?: return null
        if (c.timed) return "Timed"
        val reps = c.reps?.let { " x $it" } ?: ""
        val load = when {
            c.loadKind == "bodyweight" && (c.loadG == null || c.loadG == 0L) -> "Bodyweight"
            c.loadKind == "bodyweight" -> "Bodyweight +" + kg(c.loadG!!)
            c.loadG == null -> return "Set starting weight in the app"
            else -> kg(c.loadG) + (if (c.loadKind == "dumbbell" || c.unilateral) " ea" else "")
        }
        return load + reps
    }

    companion object {
        fun of(s: Map<String, Any?>): SnapshotView {
            val paused = s.strOrNull("state") == "paused"
            val rest = s.objOrNull("rest")?.let { RestSpec(it.str("set_id"), it.long("ends_at_wall_ms"), it.long("duration_ms")) }
            var current: Current? = null
            var currentSetId: String? = null
            var lockEligible = false
            var done = 0
            var total = 0
            val blocks = ArrayList<TimerBlockSpec>()
            var badBlocks = 0
            for (e in s.objList("exercises")) {
                val sets = e.objList("sets")
                sets.forEachIndexed { i, set ->
                    total++
                    val state = set.strOrNull("state")
                    if (state == "pending") {
                        val b = block(set)
                        if (b === BAD) badBlocks++ else if (b != null) blocks.add(b)
                    }
                    if (state != "pending") {
                        done++
                    } else if (current == null) {
                        currentSetId = set.strOrNull("set_id")
                        lockEligible = LockReducer.eligible(e, set)
                        current = Current(
                            exerciseName = e.str("name"),
                            setNumber = (set.longOrNull("set_ordinal") ?: (i + 1).toLong()).toInt(),
                            setCount = sets.size,
                            loadG = set.longOrNull("target_load_g"),
                            reps = set.longOrNull("target_reps"),
                            loadKind = e.strOrNull("load_kind") ?: "",
                            unilateral = e["unilateral"] as? Boolean ?: false,
                            timed = set.strOrNull("kind") == "timed",
                        )
                    }
                }
            }
            return SnapshotView(
                paused, rest, current, done, total, s.longOrNull("rev") ?: -1, currentSetId, lockEligible,
                s.strOrNull("workout_uuid"), blocks, badBlocks,
            )
        }

        private val BAD = TimerBlockSpec("", -1, 0, emptyList())

        /**
         * A pending set's started block: null when it has none, is not started (anchor null) or has
         * no cues left (paused, finished); [BAD] when it is malformed. Every number is an integer
         * (contract: no floats anywhere).
         */
        private fun block(set: Map<String, Any?>): TimerBlockSpec? {
            val b = set["block"] as? Map<*, *> ?: return null
            val anchor = b["started_at_wall_ms"] ?: return null
            val cues = b["cues"] as? List<*> ?: return BAD
            if (cues.isEmpty()) return null
            val setId = set["set_id"] as? String ?: return BAD
            if (anchor !is Long) return BAD
            val run = when (val r = b["run"]) {
                null -> 0L
                is Long -> r
                else -> return BAD
            }
            val out = ArrayList<BlockCue>(cues.size)
            for (c in cues) {
                val m = c as? Map<*, *> ?: return BAD
                val index = m["index"] as? Long ?: return BAD
                val at = m["at_ms"] as? Long ?: return BAD
                if (index < 0 || index > Int.MAX_VALUE || at < 0) return BAD
                out.add(BlockCue(index.toInt(), at, m["kind"] as? String ?: "", m["label"] as? String ?: ""))
            }
            return TimerBlockSpec(setId, run, anchor, out)
        }

        /** Grams to "22.5 kg" / "20 kg". */
        fun kg(g: Long): String {
            val tenths = Math.round(g / 100.0)
            return if (tenths % 10 == 0L) "${tenths / 10} kg" else "${tenths / 10}.${Math.abs(tenths % 10)} kg"
        }
    }
}
