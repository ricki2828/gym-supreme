package app.gymsupreme.core.journal

/**
 * The only transition Kotlin applies in cut 1 (contract `session_snapshot.md`, "Kotlin-side
 * transitions"): `finished=true`, `rev+1`, `rest=null`, `ended_at_ms` if null, and when paused,
 * fold the pause in (`paused_total_ms += now - paused_at_ms`, `paused_at_ms=null`,
 * `state="active"`), matching Dart's `Session.finish`. A snapshot that is already finished comes
 * back unchanged (Dart's preferred path: it submits `Session.finish` itself). Key order is kept.
 */
object FinishStamp {
    fun stamp(snapshot: Map<String, Any?>, nowMs: Long): Map<String, Any?> {
        if (snapshot[Journal.F_FINISHED] == true) return snapshot
        val out = LinkedHashMap(snapshot)
        val rev = snapshot[Journal.F_REV] as? Long ?: throw IllegalArgumentException("rev")
        out[Journal.F_REV] = rev + 1
        if (snapshot["state"] == "paused") {
            val pausedAt = snapshot["paused_at_ms"] as? Long
            val total = snapshot["paused_total_ms"] as? Long ?: 0L
            if (pausedAt != null) out["paused_total_ms"] = total + (nowMs - pausedAt).coerceAtLeast(0)
            out["paused_at_ms"] = null
            out["state"] = "active"
        }
        out["rest"] = null
        out[Journal.F_FINISHED] = true
        if (snapshot["ended_at_ms"] == null) out["ended_at_ms"] = nowMs
        return out
    }
}
