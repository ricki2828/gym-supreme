package app.gymsupreme.core.log

import kotlin.test.Test
import kotlin.test.assertEquals

class LogLineTest {
    @Test
    fun `encodes in insertion order with every value kind`() {
        val s = LogLine("cue").put("n", 3).put("late_ms", 1_250L).put("saver", true).put("hr", null).put("x", 1.5).encode()
        assertEquals("""{"event":"cue","n":3,"late_ms":1250,"saver":true,"hr":null,"x":1.5}""", s)
    }

    @Test
    fun `escapes strings and keeps one line`() {
        val s = LogLine("err").put("msg", "a \"b\"\\c\nd\u0001").encode()
        assertEquals("""{"event":"err","msg":"a \"b\"\\c\nd\u0001"}""", s)
    }

    @Test
    fun `non-finite numbers become null`() {
        assertEquals("""{"event":"e","v":null}""", LogLine("e").put("v", Double.NaN).encode())
    }
}
