package app.gymsupreme.core.ble

import kotlin.test.Test
import kotlin.test.assertEquals

class HrSummaryTest {
    private fun every(fromMs: Long, toMs: Long, stepMs: Long = 1_000) =
        (fromMs..toMs step stepMs).map { HrReading(it, 120) }

    @Test
    fun `steady strap - a reading a second, no gaps`() {
        val r = HrSummary.of(every(1_000, 180_000), t0 = 0, endMs = 180_000)
        assertEquals(listOf(59, 60, 61), r.perMinute, "the reading at the end lands in the last minute")
        assertEquals(emptyList<HrSummary.Gap>(), r.gaps)
        assertEquals(180, r.readings)
    }

    @Test
    fun `walk-away shows as one gap that closes by itself`() {
        val readings = every(1_000, 60_000) + every(130_000, 180_000)
        val r = HrSummary.of(readings, t0 = 0, endMs = 180_000)
        assertEquals(listOf(HrSummary.Gap(60_000, 130_000)), r.gaps)
        assertEquals(70_000L, r.gaps[0].lengthMs)
        assertEquals(listOf(59, 1, 51), r.perMinute)
    }

    @Test
    fun `late link and a lost strap are gaps too`() {
        val r = HrSummary.of(every(20_000, 40_000), t0 = 0, endMs = 90_000)
        assertEquals(listOf(HrSummary.Gap(0, 20_000), HrSummary.Gap(40_000, 90_000)), r.gaps)
        assertEquals(listOf(21, 0), r.perMinute)
    }

    @Test
    fun `readings outside the window are ignored`() {
        val r = HrSummary.of(listOf(HrReading(-5, 100), HrReading(500, 100), HrReading(70_000, 100)), t0 = 0, endMs = 1_000)
        assertEquals(1, r.readings)
        assertEquals(listOf(1), r.perMinute)
    }
}
