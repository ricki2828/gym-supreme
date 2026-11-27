package app.gymsupreme.core.selfcheck

/** Pure pieces of the self-check evidence log (the Android side is `SelfCheckLog` in the app module). */
object SelfCheckKeys {
    /** `base_NN` for ring entry [seq]: plain ASCII digits whatever the phone's locale. */
    fun slot(base: String, seq: Long, slots: Int): String = "${base}_${(seq % slots).toInt().toString().padStart(2, '0')}"

    /** Ids of the sets a journal snapshot holds as done. */
    @Suppress("UNCHECKED_CAST")
    fun doneSetIds(snapshot: Map<String, Any?>): Set<String> {
        val out = HashSet<String>()
        for (ex in snapshot["exercises"] as? List<Map<String, Any?>> ?: return out) {
            for (set in ex["sets"] as? List<Map<String, Any?>> ?: continue) {
                if (set["state"] == "done") (set["set_id"] as? String)?.let { out.add(it) }
            }
        }
        return out
    }

    /** Ids of sets done in [now] and not in [before], whose `source` is not the lock screen. */
    @Suppress("UNCHECKED_CAST")
    fun newAppDoneSetIds(before: Map<String, Any?>?, now: Map<String, Any?>): List<String> {
        val was = if (before == null) emptySet() else doneSetIds(before)
        val out = ArrayList<String>()
        for (ex in now["exercises"] as? List<Map<String, Any?>> ?: return out) {
            for (set in ex["sets"] as? List<Map<String, Any?>> ?: continue) {
                val id = set["set_id"] as? String ?: continue
                if (set["state"] == "done" && id !in was && set["source"] != "lockscreen") out.add(id)
            }
        }
        return out
    }

    /** Ids of sets done in [before] and no longer done in [now] (an undo in the app). */
    fun newlyUndoneSetIds(before: Map<String, Any?>?, now: Map<String, Any?>): List<String> =
        if (before == null) emptyList() else (doneSetIds(before) - doneSetIds(now)).toList()
}
