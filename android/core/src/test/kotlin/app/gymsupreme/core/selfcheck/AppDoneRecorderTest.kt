package app.gymsupreme.core.selfcheck

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class AppDoneRecorderTest {
    private fun line(vararg sets: Pair<String, String>, src: String? = null): String {
        val ss = sets.joinToString(",") { (id, st) ->
            """{"set_id":"$id","state":"$st"${if (st == "done" && src != null) ",\"source\":\"$src\"" else ""}}"""
        }
        return """{"exercises":[{"sets":[$ss]}]}"""
    }

    private class Rig(var disk: String? = null) {
        val done = ArrayList<String>()
        val undone = ArrayList<String>()
        var reads = 0
        val rec = AppDoneRecorder({ reads++; disk }, { done.add(it) }, { undone.add(it) })

        /** An app submit: the append moves the "disk" like the real one. */
        fun submit(newLine: String, apply: () -> Unit = {}) = rec.accept(newLine, { disk = newLine }, apply)
    }

    @Test
    fun startLogsNothingEvenWithAPreviousWorkoutOnDisk() {
        val r = Rig(disk = line("old" to "done"))
        r.rec.remember(line("a" to "pending")) // what start() does
        assertEquals(emptyList(), r.done)
        r.submit(line("a" to "pending", "b" to "pending"))
        assertEquals(emptyList(), r.done)
        assertEquals(0, r.reads)
    }

    @Test
    fun anAppSubmitThatCompletesASetLogsExactlyOneRow() {
        val r = Rig()
        r.rec.remember(line("a" to "pending", "b" to "pending"))
        r.submit(line("a" to "done", "b" to "pending"))
        assertEquals(listOf("a"), r.done)
        r.submit(line("a" to "done", "b" to "pending"))
        assertEquals(listOf("a"), r.done)
        assertEquals(0, r.reads)
    }

    @Test
    fun theColdStartReadHappensBeforeTheAppendSoTheFirstDoneIsLogged() {
        val r = Rig(disk = line("a" to "pending"))
        r.submit(line("a" to "done"))
        assertEquals(listOf("a"), r.done)
        assertEquals(1, r.reads)
        r.submit(line("a" to "done"))
        assertEquals(1, r.reads)
    }

    @Test
    fun theLineIsCurrentEvenWhenApplyThrows() {
        val r = Rig()
        r.rec.remember(line("a" to "pending"))
        val next = line("a" to "done")
        assertFailsWith<IllegalStateException> { r.submit(next) { throw IllegalStateException("service") } }
        assertEquals(next, r.rec.lastLine()) // a later lock action reduces THIS, not the old line
        assertEquals(listOf("a"), r.done) // and the Done that is in the journal is still logged
    }

    @Test
    fun aThrowingColdStartReadStillAppendsAndAppliesAndLogsNothing() {
        val errors = ArrayList<Exception>()
        val rec = AppDoneRecorder({ throw java.io.IOException("read") }, { errors.add(RuntimeException("done")) }, { }, { errors.add(it) })
        var appended = false
        var applied = false
        val next = line("a" to "done")
        rec.accept(next, { appended = true }, { applied = true })
        assertEquals(true, appended && applied)
        assertEquals(1, errors.size) // only the read error, no "done" row
        assertEquals("read", errors[0].message)
        assertEquals(next, rec.lastLine())
    }

    @Test
    fun aFailedAppendLeavesTheLineAlone() {
        val r = Rig()
        val old = line("a" to "pending")
        r.rec.remember(old)
        assertFailsWith<java.io.IOException> {
            r.rec.accept(line("a" to "done"), { throw java.io.IOException("disk") }, {})
        }
        assertEquals(old, r.rec.lastLine())
        assertEquals(emptyList(), r.done)
    }

    @Test
    fun aLockscreenDoneIsNotLogged() {
        val r = Rig()
        r.rec.remember(line("a" to "pending"))
        r.submit(line("a" to "done", src = "lockscreen"))
        r.submit(line("a" to "done"))
        assertEquals(emptyList(), r.done)
    }

    @Test
    fun anUndoIsReported() {
        val r = Rig()
        r.rec.remember(line("a" to "done"))
        r.submit(line("a" to "pending"))
        assertEquals(listOf("a"), r.undone)
        r.submit(line("a" to "done"))
        assertEquals(listOf("a"), r.done)
    }

    @Test
    fun aGarbledLineNeverThrowsAndStillBecomesCurrent() {
        val r = Rig()
        r.rec.remember(line("a" to "pending"))
        r.submit("not json")
        assertEquals("not json", r.rec.lastLine())
    }
}
