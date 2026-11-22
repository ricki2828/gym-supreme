package app.gymsupreme.core.timer

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class CuePlanTest {
    @Test
    fun `spike - 10 rest ends then 20 EMOM minutes then the strap mark`() {
        val cues = CuePlan.spike()
        val rests = cues.filter { it.kind == CueKind.REST_END }
        val emom = cues.filter { it.kind == CueKind.EMOM_MINUTE }
        assertEquals(10, rests.size)
        assertEquals((1..10).map { it * 90_000L }, rests.map { it.atMs })
        assertEquals(20, emom.size)
        assertEquals((0 until 20).map { 900_000L + it * 60_000L }, emom.map { it.atMs })
        assertEquals(listOf(45 * 60_000L), cues.filter { it.kind == CueKind.MARK }.map { it.atMs })
        assertEquals(cues.indices.toList(), cues.map { it.index })
        assertEquals(cues.sortedBy { it.atMs }, cues)
    }

    @Test
    fun `spike - the last rest end and the first EMOM minute share a moment, rest first`() {
        val cues = CuePlan.spike()
        val at = 900_000L
        assertEquals(listOf(CueKind.REST_END, CueKind.EMOM_MINUTE), cues.filter { it.atMs == at }.map { it.kind })
    }

    @Test
    fun `clock - cues are anchored to t0, a late wake-up never shifts later cues`() {
        val c = CueClock(CuePlan.spike(), t0 = 1_000_000)
        assertEquals(90_000L, c.delayToNext(1_000_000))
        assertTrue(c.due(1_089_999).isEmpty(), "early wake-up fires nothing")
        // Woken 2.5 s late: rest 1 fires now, rest 2 is still at t0 + 180 s.
        assertEquals(listOf("rest 1 of 10"), c.due(1_092_500).map { it.label })
        assertEquals(1_180_000L - 1_092_500L, c.delayToNext(1_092_500))
        assertEquals(1_180_000L, c.scheduledAt(c.peek()!!))
    }

    @Test
    fun `clock - a long stall fires every due cue once, in order`() {
        val c = CueClock(CuePlan.spike(), t0 = 0)
        val fired = c.due(300_000)
        assertEquals(listOf("rest 1 of 10", "rest 2 of 10", "rest 3 of 10"), fired.map { it.label })
        assertTrue(c.due(300_000).isEmpty())
        assertEquals(3, c.firedCount)
    }

    @Test
    fun `clock - done after the last cue`() {
        val c = CueClock(CuePlan.selftest(), t0 = 50)
        assertEquals(3_000L, c.delayToNext(50))
        assertEquals(1, c.due(3_050).size)
        assertTrue(c.done)
        assertNull(c.delayToNext(4_000))
        assertNull(c.peek())
    }
}
