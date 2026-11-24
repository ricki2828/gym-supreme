package app.gymsupreme.core.flags

import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals

class DartDefinesTest {
    private fun enc(vararg entries: String) =
        entries.joinToString(",") { Base64.getEncoder().encodeToString(it.toByteArray(Charsets.UTF_8)) }

    @Test
    fun `the last define of a key wins, as in Dart`() {
        assertEquals("y", DartDefines.value(enc("A=1", "GS_FEATURES=x", "GS_FEATURES=y"), "GS_FEATURES"))
    }

    @Test
    fun `missing or empty input gives empty`() {
        assertEquals("", DartDefines.value(null, "GS_FEATURES"))
        assertEquals("", DartDefines.value("", "GS_FEATURES"))
        assertEquals("", DartDefines.value(enc("A=1", "BUILD_SHA=abc"), "GS_FEATURES"))
        assertEquals("", DartDefines.value(enc("GS_FEATURES="), "GS_FEATURES"))
    }

    @Test
    fun `values keep commas and equals signs, keys must match whole`() {
        assertEquals("ghost,rotation,lockdone", DartDefines.value(enc("GS_FEATURES=ghost,rotation,lockdone"), "GS_FEATURES"))
        assertEquals("a=b", DartDefines.value(enc("K=a=b"), "K"))
        assertEquals("", DartDefines.value(enc("GS_FEATURES_X=1"), "GS_FEATURES"))
    }

    @Test
    fun `a bad entry is skipped, not fatal`() {
        assertEquals("ok", DartDefines.value("!!!," + enc("GS_FEATURES=ok"), "GS_FEATURES"))
    }
}
