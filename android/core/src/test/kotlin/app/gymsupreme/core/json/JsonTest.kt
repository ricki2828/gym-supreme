package app.gymsupreme.core.json

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class JsonTest {
    @Test
    fun `parses every value kind with key order kept`() {
        val m = Json.parseObject("""{"b":1,"a":-2.5,"t":true,"f":false,"n":null,"s":"x","l":[1,{"k":"v"}],"e":1e3}""")
        assertEquals(listOf("b", "a", "t", "f", "n", "s", "l", "e"), m.keys.toList())
        assertEquals(1L, m["b"])
        assertEquals(-2.5, m["a"])
        assertEquals(true, m["t"])
        assertEquals(false, m["f"])
        assertNull(m["n"])
        assertEquals("x", m["s"])
        assertEquals(listOf(1L, mapOf("k" to "v")), m["l"])
        assertEquals(1000.0, m["e"])
    }

    @Test
    fun `string escapes including unicode`() {
        assertEquals("a\"b\\c/d\n\té", Json.parse(""""a\"b\\c\/d\n\té""""))
        assertEquals("Lat pulldown – wide", Json.parse("\"Lat pulldown – wide\""))
    }

    @Test
    fun `large integers stay exact`() {
        assertEquals(1795354001039L, Json.parse("1795354001039"))
    }

    @Test
    fun `torn and malformed input is rejected`() {
        for (bad in listOf("""{"a":1""", """{"a":1,}""", """{"a" 1}""", "[1,2", "\"abc", "tru", "01", "1.", "-", """{"a":1} x""", "")) {
            assertFailsWith<JsonException>(bad) { Json.parse(bad) }
        }
    }

    @Test
    fun `typed reads fail clearly`() {
        val m = Json.parseObject("""{"n":3,"s":"x"}""")
        assertEquals(3L, m.long("n"))
        assertFailsWith<JsonException> { m.long("s") }
        assertFailsWith<JsonException> { m.str("missing") }
    }
}
