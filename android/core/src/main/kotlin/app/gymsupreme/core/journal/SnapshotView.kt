package app.gymsupreme.core.journal

import app.gymsupreme.core.json.long
import app.gymsupreme.core.json.longOrNull
import app.gymsupreme.core.json.objList
import app.gymsupreme.core.json.objOrNull
import app.gymsupreme.core.json.str
import app.gymsupreme.core.json.strOrNull
import app.gymsupreme.core.rest.RestSpec

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
) {
    data class Current(
        val exerciseName: String,
        val setNumber: Int,
        val setCount: Int,
        val loadG: Long?,
        val reps: Long?,
        val loadKind: String,
        val unilateral: Boolean,
    )

    /** "22.5 kg ea x 10", "Bodyweight x 12", "Starting weight?" (cold start). */
    fun doneLine(): String? {
        val c = current ?: return null
        val reps = c.reps?.let { " x $it" } ?: ""
        val load = when {
            c.loadKind == "bodyweight" && (c.loadG == null || c.loadG == 0L) -> "Bodyweight"
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
            var done = 0
            var total = 0
            for (e in s.objList("exercises")) {
                val sets = e.objList("sets")
                sets.forEachIndexed { i, set ->
                    total++
                    val state = set.strOrNull("state")
                    if (state != "pending") {
                        done++
                    } else if (current == null) {
                        current = Current(
                            exerciseName = e.str("name"),
                            setNumber = (set.longOrNull("set_ordinal") ?: (i + 1).toLong()).toInt(),
                            setCount = sets.size,
                            loadG = set.longOrNull("target_load_g"),
                            reps = set.longOrNull("target_reps"),
                            loadKind = e.strOrNull("load_kind") ?: "",
                            unilateral = e["unilateral"] as? Boolean ?: false,
                        )
                    }
                }
            }
            return SnapshotView(paused, rest, current, done, total)
        }

        /** Grams to "22.5 kg" / "20 kg". */
        fun kg(g: Long): String {
            val tenths = Math.round(g / 100.0)
            return if (tenths % 10 == 0L) "${tenths / 10} kg" else "${tenths / 10}.${Math.abs(tenths % 10)} kg"
        }
    }
}
