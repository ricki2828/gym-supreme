package app.gymsupreme.core.flags

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class FeatureSetTest {
    @Test
    fun `empty means every flag off`() {
        val f = FeatureSet("")
        FeatureSet.NAMES.forEach { assertFalse(f.on(it), it) }
        assertEquals("timers=0 ghost=0 rotation=0 plates=0 lockdone=0 health=0", f.logLine())
    }

    @Test
    fun `all turns every flag on`() {
        val f = FeatureSet("all")
        FeatureSet.NAMES.forEach { assertTrue(f.on(it), it) }
        assertEquals("timers=1 ghost=1 rotation=1 plates=1 lockdone=1 health=1", f.logLine())
    }

    @Test
    fun `a list turns on only its names, trimmed, like the Dart parser`() {
        val f = FeatureSet("ghost, rotation ,lockdone")
        assertEquals("timers=0 ghost=1 rotation=1 plates=0 lockdone=1 health=0", f.logLine())
        assertFalse(f.on("lock"))
        assertFalse(FeatureSet("lockdonex").on("lockdone"))
    }

    @Test
    fun `all only counts as the whole string, as in Dart`() {
        // Dart: `_features == 'all' || split(',').map(trim).contains(name)`.
        assertFalse(FeatureSet(" all").on("ghost"))
        assertFalse(FeatureSet("ghost,all").on("timers"))
    }
}
