package app.gymsupreme.core.journal

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class JournalTest {
    private val u = "8f2c9a1e-3b4d-4e5f-9a6b-7c8d9e0f1a2b"

    private fun snap(rev: Long, uuid: String = u, finished: Boolean = false, schema: Long = 1) =
        """{"schema":$schema,"workout_uuid":"$uuid","rev":$rev,"finished":$finished,"exercises":[]}"""

    private fun accepted(r: Journal.Submit) = assertIs<Journal.Submit.Accepted>(r)

    private fun code(r: Journal.Submit) = assertIs<Journal.Submit.Rejected>(r).code

    @Test
    fun `start is rev 0, then each submit is base plus 1`() {
        val a = accepted(Journal.submit(snap(0), 0, null, isStart = true))
        assertEquals(Journal.Head(u, 0, 1, false), a.head)
        val b = accepted(Journal.submit(snap(1), 0, a.head, isStart = false))
        assertEquals(1, b.head.rev)
    }

    @Test
    fun `stale or skipped revs are refused so two writers never both win`() {
        val h = Journal.Head(u, 5, 1, false)
        assertEquals("stale_rev", code(Journal.submit(snap(5), 4, h, false)), "Dart behind the service")
        assertEquals("stale_rev", code(Journal.submit(snap(7), 5, h, false)), "rev must be base + 1")
        assertEquals("stale_rev", code(Journal.submit(snap(1), 0, null, true)), "a start is rev 0")
        accepted(Journal.submit(snap(6), 5, h, false))
    }

    @Test
    fun `wrong workout, finished, not running, already running, bad schema, bad JSON`() {
        val h = Journal.Head(u, 3, 1, false)
        assertEquals("wrong_workout", code(Journal.submit(snap(4, uuid = "other"), 3, h, false)))
        assertEquals("finished", code(Journal.submit(snap(4), 3, h.copy(finished = true), false)))
        assertEquals("not_running", code(Journal.submit(snap(4), 3, null, false)))
        assertEquals("already_running", code(Journal.submit(snap(0, uuid = "new"), 0, h, true)))
        accepted(Journal.submit(snap(0, uuid = "new"), 0, h.copy(finished = true), true))
        assertEquals("bad_schema", code(Journal.submit(snap(0, schema = 99), 0, null, true)))
        assertEquals("bad_snapshot", code(Journal.submit("{not json", 0, null, true)))
        assertEquals("bad_snapshot", code(Journal.submit("""{"schema":1,"rev":0}""", 0, null, true)))
        assertEquals("bad_snapshot", code(Journal.submit(snap(0).replace(",", ",\n"), 0, null, true)))
    }

    @Test
    fun `read - last good line wins and a torn tail is ignored`() {
        val text = snap(1) + "\n" + snap(2) + "\n" + snap(3).take(20)
        val r = Journal.read(text)
        assertEquals(snap(2), r.lastLine)
        assertEquals(2, r.last?.rev)
        assertEquals(2, r.goodLines)
        assertEquals(0, r.corruptLines)
        assertTrue(r.tornTail)
    }

    @Test
    fun `read - corrupt middle line is counted, good lines after it still win`() {
        val text = snap(1) + "\n" + "garbage" + "\n" + snap(2) + "\n"
        val r = Journal.read(text)
        assertEquals(snap(2), r.lastLine)
        assertEquals(1, r.corruptLines)
        assertFalse(r.tornTail)
    }

    @Test
    fun `read - lines from another workout, a non-rising rev or after finish are corrupt`() {
        val text = listOf(snap(1), snap(2, uuid = "x"), snap(2), snap(2), snap(3, finished = true), snap(4)).joinToString("\n", postfix = "\n")
        val r = Journal.read(text)
        assertEquals(3, r.last?.rev)
        assertTrue(r.last!!.finished)
        assertEquals(3, r.goodLines)
        assertEquals(3, r.corruptLines)
    }

    @Test
    fun `read - empty and all-torn`() {
        assertNull(Journal.read("").last)
        val r = Journal.read(snap(1).dropLast(3))
        assertNull(r.lastLine)
        assertTrue(r.tornTail)
        assertEquals(0, r.corruptLines)
    }
}
