package app.gymsupreme.core.json

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class JsonWriterTest {
    @Test
    fun `round trips what the reader produces, byte for byte for Dart-style JSON`() {
        val src = """{"schema_version":1,"uuid":"a\"b","rev":12,"finished":false,"x":null,"l":[1,{"k":"v\né"}],"d":22.5,"z":-3}"""
        assertEquals(src.replace("\\u00e9", "é"), JsonWriter.write(Json.parse(src)))
    }

    @Test
    fun `stamps fields while keeping order`() {
        val m = LinkedHashMap(Json.parseObject("""{"uuid":"u","rev":4,"finished":false,"exercises":[]}"""))
        m["rev"] = 5L
        m["finished"] = true
        assertEquals("""{"uuid":"u","rev":5,"finished":true,"exercises":[]}""", JsonWriter.write(m))
    }

    @Test
    fun `whole doubles keep a fraction, control chars are escaped, NaN refused`() {
        assertEquals("[2.0,0.5]", JsonWriter.write(listOf(2.0, 0.5)))
        assertEquals("\"a\\u0001\"", JsonWriter.write("a\u0001"))
        assertFailsWith<JsonException> { JsonWriter.write(Double.NaN) }
    }
}
