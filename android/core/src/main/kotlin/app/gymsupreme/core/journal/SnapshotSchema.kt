package app.gymsupreme.core.journal

import app.gymsupreme.core.json.JsonException

/**
 * Strict decode of snapshot schema 1 (contracts/session_snapshot.md, "Strict decode, both
 * sides"): every listed key present (null only where allowed), integers only (no floating-point
 * number anywhere, `block` included), known enum values only, `paused_at_ms` non-null exactly when
 * paused, `completion` and `source` non-null exactly when the set is done. Extra keys are ignored.
 * Throws [JsonException] naming the first problem; the journal refuses such a snapshot as
 * `bad_snapshot`.
 */
object SnapshotSchema {
    private val STATES = setOf("active", "paused")
    private val SET_KINDS = setOf("reps", "timed")
    private val SET_STATES = setOf("pending", "done", "skipped")
    private val COMPLETIONS = setOf("tap_unchanged", "adjusted", "typed", "cold_start")
    private val SOURCES = setOf("app", "lockscreen")

    fun validate(s: Map<String, Any?>) {
        noDoubles(s, "snapshot")
        int(s, "schema")
        str(s, "workout_uuid")
        int(s, "rev")
        str(s, "app_version")
        str(s, "gym_id")
        strOrNull(s, "type_id")
        list(s, "muscles").forEachIndexed { i, m -> if (m !is String) fail("muscles[$i] is not a string") }
        int(s, "started_at_ms")
        int(s, "tz_offset_min")
        val state = enumOf(s, "state", STATES)
        val pausedAt = intOrNull(s, "paused_at_ms")
        if ((state == "paused") != (pausedAt != null)) fail("paused_at_ms must be set exactly when paused")
        int(s, "paused_total_ms")
        need(s, "rest")
        (s["rest"])?.let { r ->
            val o = obj(r, "rest")
            str(o, "set_id")
            int(o, "ends_at_wall_ms")
            int(o, "duration_ms")
        }
        bool(s, "finished")
        intOrNull(s, "ended_at_ms")
        intOrNull(s, "set_ready_at_ms")
        val nextN = intOrNull(s, "next_set_n")
        int(s, "swaps")
        list(s, "exercises").forEachIndexed { ei, e -> exercise(obj(e, "exercises[$ei]"), "exercises[$ei]") }
        // Set ids are `<workout_uuid>:<n>` and never reused: next_set_n must be above every n in use.
        if (nextN != null) {
            var highest = -1L
            for (e in list(s, "exercises")) for (x in list(obj(e, "exercise"), "sets")) {
                val n = (obj(x, "set")["set_id"] as String).substringAfterLast(':', "").toLongOrNull()
                if (n != null && n > highest) highest = n
            }
            if (nextN <= highest) fail("next_set_n $nextN must be above the highest set id number $highest")
        }
    }

    private fun exercise(e: Map<String, Any?>, at: String) {
        str(e, "exercise_id", at)
        str(e, "name", at)
        str(e, "load_kind", at)
        bool(e, "unilateral", at)
        int(e, "rest_s", at)
        intOrNull(e, "rep_lo", at)
        intOrNull(e, "rep_hi", at)
        list(e, "sets", at).forEachIndexed { si, x -> set(obj(x, "$at.sets[$si]"), "$at.sets[$si]") }
    }

    private fun set(x: Map<String, Any?>, at: String) {
        str(x, "set_id", at)
        int(x, "set_ordinal", at)
        enumOf(x, "kind", SET_KINDS, at)
        for (k in listOf("plan_load_g", "plan_reps", "target_load_g", "target_reps", "load_g", "reps", "started_at_ms", "ended_at_ms", "offset_ms")) intOrNull(x, k, at)
        val state = enumOf(x, "state", SET_STATES, at)
        val completion = enumOrNull(x, "completion", COMPLETIONS, at)
        val source = enumOrNull(x, "source", SOURCES, at)
        val done = state == "done"
        if (done != (completion != null)) fail("$at: completion must be set exactly when done")
        if (done != (source != null)) fail("$at: source must be set exactly when done")
        need(x, "block", at)
        x["block"]?.let { obj(it, "$at.block") }
    }

    // ---- helpers ----

    private fun fail(msg: String): Nothing = throw JsonException(msg)

    private fun need(m: Map<String, Any?>, k: String, at: String = "") {
        if (!m.containsKey(k)) fail("${prefix(at)}missing '$k'")
    }

    private fun prefix(at: String) = if (at.isEmpty()) "" else "$at: "

    private fun int(m: Map<String, Any?>, k: String, at: String = ""): Long {
        need(m, k, at)
        return m[k] as? Long ?: fail("${prefix(at)}'$k' must be an integer")
    }

    private fun intOrNull(m: Map<String, Any?>, k: String, at: String = ""): Long? {
        need(m, k, at)
        val v = m[k] ?: return null
        return v as? Long ?: fail("${prefix(at)}'$k' must be an integer or null")
    }

    private fun str(m: Map<String, Any?>, k: String, at: String = ""): String {
        need(m, k, at)
        return m[k] as? String ?: fail("${prefix(at)}'$k' must be a string")
    }

    private fun strOrNull(m: Map<String, Any?>, k: String, at: String = ""): String? {
        need(m, k, at)
        val v = m[k] ?: return null
        return v as? String ?: fail("${prefix(at)}'$k' must be a string or null")
    }

    private fun bool(m: Map<String, Any?>, k: String, at: String = ""): Boolean {
        need(m, k, at)
        return m[k] as? Boolean ?: fail("${prefix(at)}'$k' must be a boolean")
    }

    private fun list(m: Map<String, Any?>, k: String, at: String = ""): List<*> {
        need(m, k, at)
        return m[k] as? List<*> ?: fail("${prefix(at)}'$k' must be an array")
    }

    @Suppress("UNCHECKED_CAST")
    private fun obj(v: Any?, at: String): Map<String, Any?> = v as? Map<String, Any?> ?: fail("$at must be an object")

    private fun enumOf(m: Map<String, Any?>, k: String, allowed: Set<String>, at: String = ""): String {
        val v = str(m, k, at)
        if (v !in allowed) fail("${prefix(at)}unknown $k '$v'")
        return v
    }

    private fun enumOrNull(m: Map<String, Any?>, k: String, allowed: Set<String>, at: String = ""): String? {
        val v = strOrNull(m, k, at) ?: return null
        if (v !in allowed) fail("${prefix(at)}unknown $k '$v'")
        return v
    }

    private fun noDoubles(v: Any?, at: String) {
        when (v) {
            is Double -> fail("$at: floating-point number (integers only)")
            is Map<*, *> -> for ((k, x) in v) noDoubles(x, "$at.$k")
            is List<*> -> v.forEachIndexed { i, x -> noDoubles(x, "$at[$i]") }
            else -> Unit
        }
    }
}
