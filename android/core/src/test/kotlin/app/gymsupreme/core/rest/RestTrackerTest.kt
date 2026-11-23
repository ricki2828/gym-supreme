package app.gymsupreme.core.rest

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull

class RestTrackerTest {
    private val wall = 1_800_000_000_000L
    private val el = 50_000L

    @Test
    fun `arms once from the wall-clock end, re-sends keep it`() {
        val t = RestTracker()
        val r = RestSpec("set-1", wall + 90_000, 90_000)
        assertEquals(RestTracker.Action.Arm(r, el + 90_000), t.onSnapshot(r, wall, el))
        assertIs<RestTracker.Action.Keep>(t.onSnapshot(r, wall + 5_000, el + 5_000), "same rest re-sent with another change")
        assertEquals(r, t.current)
    }

    @Test
    fun `rest adjusted by +15 s re-arms, rest cleared cancels`() {
        val t = RestTracker()
        t.onSnapshot(RestSpec("set-1", wall + 90_000, 90_000), wall, el)
        val longer = RestSpec("set-1", wall + 105_000, 105_000)
        assertEquals(RestTracker.Action.Arm(longer, el + 10_000 + 95_000), t.onSnapshot(longer, wall + 10_000, el + 10_000))
        assertIs<RestTracker.Action.Cancel>(t.onSnapshot(null, wall + 20_000, el + 20_000))
        assertIs<RestTracker.Action.Keep>(t.onSnapshot(null, wall + 21_000, el + 21_000))
        assertNull(t.current)
    }

    @Test
    fun `a fired rest never fires again, the next set's rest arms`() {
        val t = RestTracker()
        val r1 = RestSpec("set-1", wall + 90_000, 90_000)
        t.onSnapshot(r1, wall, el)
        t.onFired("set-1")
        assertIs<RestTracker.Action.Keep>(t.onSnapshot(r1, wall + 95_000, el + 95_000))
        val r2 = RestSpec("set-2", wall + 300_000, 90_000)
        assertIs<RestTracker.Action.Arm>(t.onSnapshot(r2, wall + 210_000, el + 210_000))
    }

    @Test
    fun `resume after the end - fire now within grace, missed after`() {
        val t = RestTracker()
        val r = RestSpec("set-1", wall, 90_000)
        assertEquals(RestTracker.Action.FireNow(r, 10_000), t.onSnapshot(r, wall + 10_000, el))
        assertIs<RestTracker.Action.Keep>(t.onSnapshot(r, wall + 11_000, el), "fired once only")
        val t2 = RestTracker()
        assertEquals(RestTracker.Action.Missed(r, 3_600_000), t2.onSnapshot(r, wall + 3_600_000, el))
    }

    @Test
    fun `clear on pause cancels an armed rest`() {
        val t = RestTracker()
        t.onSnapshot(RestSpec("set-1", wall + 90_000, 90_000), wall, el)
        assertIs<RestTracker.Action.Cancel>(t.clear())
        assertIs<RestTracker.Action.Keep>(t.clear())
    }
}
