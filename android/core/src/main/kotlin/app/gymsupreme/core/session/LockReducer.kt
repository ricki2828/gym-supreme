package app.gymsupreme.core.session

/**
 * Lock-screen actions (0.3 cut L1, plan item 9 / R3): Done, +1 rep and Skip rest applied by
 * Kotlin to the journal head when the Flutter engine may not be running. Each is a byte-for-byte
 * twin of a Dart transition in `packages/gym_engine/lib/src/session.dart`:
 *  - [Action.DONE]      = `Session.done(s, setId, nowMs, source: lockscreen)` (logs the targets)
 *  - [Action.PLUS_REP]  = `Session.retarget(s, setId, reps: max(1, target_reps + 1))`
 *                         (what LiveController.reps(+1) sends)
 *  - [Action.SKIP_REST] = `Session.skipRest(s, nowMs)`
 * The guard is the shared vectors (`lockscreen_v1_*.json`), generated from those Dart calls by
 * `packages/gym_engine/tool/gen_contract_fixtures.dart` and replayed here by LockReducerTest.
 *
 * Narrower than Dart on purpose (each a [Result.NoOp], never a guess): a finished or paused
 * session, an unknown or non-pending set, and for Done / +1 a set that is not [eligible] (timed
 * or carrying a timer block, no target reps, or a loaded lift with no target weight: the
 * notification shows "Log it in the app" for those instead of the buttons).
 *
 * Works on the decoded snapshot map; key order is kept, so [app.gymsupreme.core.json.JsonWriter]
 * writes canonical bytes.
 */
object LockReducer {
    enum class Action(val wire: String) {
        DONE("done"),
        PLUS_REP("plus_rep"),
        SKIP_REST("skip_rest"),
        ;

        companion object {
            fun of(wire: String?): Action? = values().firstOrNull { it.wire == wire }
        }
    }

    sealed class Result {
        data class Applied(val snapshot: Map<String, Any?>) : Result()
        data class NoOp(val reason: String) : Result()
    }

    private val LOADED = setOf("dumbbell", "stack", "barbell")

    /**
     * Whether Done / +1 rep may be offered for [set] of [exercise]: a reps set without a timer
     * block whose Done would log a concrete value (reps known; a weight known unless the lift
     * is bodyweight).
     */
    fun eligible(exercise: Map<String, Any?>, set: Map<String, Any?>): Boolean {
        if (set["kind"] != "reps" || set["block"] != null) return false
        if (set["target_reps"] == null) return false
        // A null load is only a real value for bodyweight (the notification shows a weight otherwise).
        if (exercise["load_kind"] != "bodyweight" && set["target_load_g"] == null) return false
        return true
    }

    fun apply(s: Map<String, Any?>, action: Action, setId: String?, nowMs: Long): Result {
        if (s["finished"] == true) return Result.NoOp("finished")
        if (s["state"] != "active") return Result.NoOp("paused")
        return when (action) {
            Action.SKIP_REST -> skipRest(s, nowMs)
            Action.DONE, Action.PLUS_REP -> {
                val at = find(s, setId) ?: return Result.NoOp("unknown_set")
                val ex = exercises(s)[at.first]
                val set = sets(ex)[at.second]
                if (set["state"] != "pending") return Result.NoOp("not_pending")
                if (!eligible(ex, set)) return Result.NoOp("not_eligible")
                if (action == Action.DONE) done(s, at.first, at.second, nowMs) else plusRep(s, at.first, at.second)
            }
        }
    }

    // ---- transitions ----

    private fun done(s: Map<String, Any?>, e: Int, i: Int, now: Long): Result {
        val ex = exercises(s)[e]
        val set = sets(ex)[i]
        val load = set["target_load_g"] as Long?
        val reps = set["target_reps"] as Long?
        val coldStart = ex["load_kind"] in LOADED && set["plan_load_g"] == null && !anyLoggedLoad(ex, i)
        val started = minOf(setReady(s), now)
        val logged = LinkedHashMap(set)
        logged["state"] = "done"
        logged["load_g"] = load
        logged["reps"] = reps
        // A typed set (`entry: "typed"`, kept as it is copied) stays typed; a first-time set stays cold_start.
        logged["completion"] = if (coldStart) "cold_start" else if (set["entry"] == "typed") "typed" else "tap_unchanged"
        logged["source"] = "lockscreen"
        logged["started_at_ms"] = started
        logged["ended_at_ms"] = now
        logged["offset_ms"] = now - (s["started_at_ms"] as Long) - (s["paused_total_ms"] as Long)
        // Done logs the target unchanged, so Dart's carry-forward moves nothing here.
        val next = replaceSet(s, e, i, logged)
        val restMs = (ex["rest_s"] as Long) * 1000
        val more = hasPending(next)
        next["rev"] = (s["rev"] as Long) + 1
        next["rest"] = if (more && restMs > 0) {
            linkedMapOf<String, Any?>("set_id" to set["set_id"], "ends_at_wall_ms" to now + restMs, "duration_ms" to restMs)
        } else {
            null
        }
        next["set_ready_at_ms"] = now + if (more) restMs else 0
        return Result.Applied(next)
    }

    private fun plusRep(s: Map<String, Any?>, e: Int, i: Int): Result {
        val ex = exercises(s)[e]
        val list = sets(ex)
        val edited = list[i]
        val from = edited["target_reps"] as Long?
        val to = maxOf(1L, (from ?: 0L) + 1)
        if (to == from) return Result.NoOp("unchanged")
        val out = ArrayList<Map<String, Any?>>(list.size)
        for ((k, x) in list.withIndex()) {
            out.add(
                when {
                    k == i -> LinkedHashMap(x).also { it["target_reps"] = to }
                    // Carry-forward (Session._carryForward): later pending sets of the same kind,
                    // planned the same, still holding the old target. Timed sets never carry;
                    // only reps move here, and `to` is never null.
                    k > i && x["state"] == "pending" && x["kind"] == edited["kind"] && edited["kind"] != "timed" &&
                        x["target_reps"] == from && x["plan_reps"] == edited["plan_reps"] ->
                        LinkedHashMap(x).also { it["target_reps"] = to }
                    else -> x
                },
            )
        }
        val next = replaceExerciseSets(s, e, out)
        next["rev"] = (s["rev"] as Long) + 1
        return Result.Applied(next)
    }

    private fun skipRest(s: Map<String, Any?>, now: Long): Result {
        val rest = s["rest"] as Map<*, *>? ?: return Result.NoOp("no_rest")
        // Kotlin-only: a rest already over has nothing to skip (a late tap would only move
        // set_ready_at_ms and shorten the next set's recorded start).
        if ((rest["ends_at_wall_ms"] as Long) <= now) return Result.NoOp("rest_over")
        val next = LinkedHashMap(s)
        next["rev"] = (s["rev"] as Long) + 1
        next["rest"] = null
        next["set_ready_at_ms"] = now
        return Result.Applied(next)
    }

    // ---- helpers (mirror session.dart) ----

    @Suppress("UNCHECKED_CAST")
    private fun exercises(s: Map<String, Any?>): List<Map<String, Any?>> = s["exercises"] as List<Map<String, Any?>>

    @Suppress("UNCHECKED_CAST")
    private fun sets(ex: Map<String, Any?>): List<Map<String, Any?>> = ex["sets"] as List<Map<String, Any?>>

    private fun find(s: Map<String, Any?>, setId: String?): Pair<Int, Int>? {
        if (setId == null) return null
        for ((e, ex) in exercises(s).withIndex()) {
            for ((i, x) in sets(ex).withIndex()) if (x["set_id"] == setId) return e to i
        }
        return null
    }

    private fun hasPending(s: Map<String, Any?>): Boolean = exercises(s).any { ex -> sets(ex).any { it["state"] == "pending" } }

    /** `_anyLoggedLoad`: an earlier done set of the same kind in [ex] logged a load. */
    private fun anyLoggedLoad(ex: Map<String, Any?>, i: Int): Boolean {
        val list = sets(ex)
        val kind = list[i]["kind"]
        for (k in 0 until i) {
            val x = list[k]
            if (x["kind"] == kind && x["state"] == "done" && x["load_g"] != null) return true
        }
        return false
    }

    /** `_setStart` before the cap: `set_ready_at_ms`, or for older lines the latest done end. */
    private fun setReady(s: Map<String, Any?>): Long {
        (s["set_ready_at_ms"] as Long?)?.let { return it }
        var ready = s["started_at_ms"] as Long
        for (ex in exercises(s)) for (x in sets(ex)) {
            val end = x["ended_at_ms"] as Long?
            if (x["state"] == "done" && end != null && end > ready) ready = end
        }
        return ready
    }

    private fun replaceSet(s: Map<String, Any?>, e: Int, i: Int, set: Map<String, Any?>): LinkedHashMap<String, Any?> {
        val list = ArrayList(sets(exercises(s)[e]))
        list[i] = set
        return replaceExerciseSets(s, e, list)
    }

    private fun replaceExerciseSets(s: Map<String, Any?>, e: Int, list: List<Map<String, Any?>>): LinkedHashMap<String, Any?> {
        val exs = ArrayList(exercises(s))
        exs[e] = LinkedHashMap(exs[e]).also { it["sets"] = list }
        return LinkedHashMap(s).also { it["exercises"] = exs }
    }
}
