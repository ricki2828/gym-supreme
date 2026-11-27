package app.gymsupreme.core.selfcheck

import java.util.Locale
import kotlin.test.Test
import kotlin.test.assertEquals

class SelfCheckKeysTest {
    private fun snap(vararg sets: Triple<String, String, String?>): Map<String, Any?> = mapOf(
        "exercises" to listOf(
            mapOf(
                "sets" to sets.map { (id, state, src) -> mapOf("set_id" to id, "state" to state, "source" to src) },
            ),
        ),
    )

    @Test
    fun slotKeysAreAsciiInAnyLocale() {
        val saved = Locale.getDefault()
        try {
            for (tag in listOf("en-US", "ar-EG-u-nu-arab", "fa-IR", "hi-IN-u-nu-deva", "th-TH-u-nu-thai")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                assertEquals("sc_cue_07", SelfCheckKeys.slot("sc_cue", 67, 60), tag)
                assertEquals("sc_lock_00", SelfCheckKeys.slot("sc_lock", 20, 20), tag)
            }
        } finally {
            Locale.setDefault(saved)
        }
    }

    @Test
    fun appDoneSetsAreTheNewNonLockscreenOnes() {
        val before = snap(Triple("a", "done", null), Triple("b", "pending", null), Triple("c", "pending", null))
        val now = snap(Triple("a", "done", null), Triple("b", "done", "lockscreen"), Triple("c", "done", null))
        assertEquals(listOf("c"), SelfCheckKeys.newAppDoneSetIds(before, now))
        assertEquals(listOf("a", "c"), SelfCheckKeys.newAppDoneSetIds(null, now.let { snap(Triple("a", "done", null), Triple("c", "done", "app")) }))
    }
}
