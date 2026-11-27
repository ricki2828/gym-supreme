package app.gymsupreme.core.selfcheck

import kotlin.test.Test
import kotlin.test.assertEquals

class AppDoneRecorderTest {
    private fun line(vararg sets: Pair<String, String>, src: String? = null): String {
        val ss = sets.joinToString(",") { (id, st) ->
            """{"set_id":"$id","state":"$st"${if (st == "done" && src != null) ",\"source\":\"$src\"" else ""}}"""
        }
        return """{"exercises":[{"sets":[$ss]}]}"""
    }

    private class Rig(private val disk: String? = null) {
        val done = ArrayList<String>()
        val undone = ArrayList<String>()
        var reads = 0
        val rec = AppDoneRecorder({ reads++; disk }, { done.add(it) }, { undone.add(it) })
    }

    @Test
    fun startLogsNothingEvenWithAPreviousWorkoutOnDisk() {
        val r = Rig(disk = line("old" to "done"))
        r.rec.remember(line("a" to "pending")) // what start() does
        assertEquals(emptyList(), r.done)
        r.rec.accepted(line("a" to "pending", "b" to "pending"))
        assertEquals(emptyList(), r.done)
        assertEquals(0, r.reads)
    }

    @Test
    fun anAppSubmitThatCompletesASetLogsExactlyOneRow() {
        val r = Rig()
        r.rec.remember(line("a" to "pending", "b" to "pending"))
        r.rec.accepted(line("a" to "done", "b" to "pending"))
        assertEquals(listOf("a"), r.done)
        r.rec.accepted(line("a" to "done", "b" to "pending")) // a later submit, nothing new
        assertEquals(listOf("a"), r.done)
        assertEquals(0, r.reads)
    }

    @Test
    fun aLockscreenDoneIsRememberedNotLogged() {
        val r = Rig()
        r.rec.remember(line("a" to "pending"))
        r.rec.accepted(line("a" to "done", src = "lockscreen"))
        assertEquals(emptyList(), r.done)
        r.rec.accepted(line("a" to "done"))
        assertEquals(emptyList(), r.done)
    }

    @Test
    fun anUndoIsReported() {
        val r = Rig()
        r.rec.remember(line("a" to "done"))
        r.rec.accepted(line("a" to "pending"))
        assertEquals(listOf("a"), r.undone)
        r.rec.accepted(line("a" to "done"))
        assertEquals(listOf("a"), r.done)
    }

    @Test
    fun aColdStartReadsTheJournalOnceAndAGarbledLineNeverThrows() {
        val r = Rig(disk = line("a" to "pending"))
        r.rec.accepted(line("a" to "done"))
        r.rec.accepted(line("a" to "done"))
        assertEquals(1, r.reads)
        assertEquals(listOf("a"), r.done)
        r.rec.accepted("not json")
    }
}
