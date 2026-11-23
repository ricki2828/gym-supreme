package app.gymsupreme.core.journal

import app.gymsupreme.core.json.Json
import app.gymsupreme.core.rest.RestSpec
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SnapshotViewTest {
    private fun set(id: String, state: String, load: Long?, reps: Long?) =
        """{"set_id":"$id","set_ordinal":1,"kind":"reps","target_load_g":${load ?: "null"},"target_reps":${reps ?: "null"},"state":"$state","load_g":null,"reps":null,"completion":null,"source":null,"started_at_ms":null,"ended_at_ms":null,"offset_ms":null,"block":null}"""

    private fun ex(name: String, kind: String, vararg sets: String) =
        """{"exercise_id":"x","name":"$name","load_kind":"$kind","unilateral":false,"rest_s":90,"rep_lo":8,"rep_hi":12,"sets":[${sets.joinToString(",")}]}"""

    private fun snap(state: String, rest: String, vararg exercises: String) = Json.parseObject(
        """{"schema":1,"workout_uuid":"u","rev":3,"app_version":"0.1.0","gym_id":"condo","type_id":"push","muscles":["chest"],"started_at_ms":1,"tz_offset_min":480,"state":"$state","paused_at_ms":null,"paused_total_ms":0,"rest":$rest,"finished":false,"ended_at_ms":null,"exercises":[${exercises.joinToString(",")}]}""",
    )

    @Test
    fun `current is the first pending set with its targets, rest is read`() {
        val v = SnapshotView.of(
            snap(
                "active",
                """{"set_id":"s2","ends_at_wall_ms":1800000090000,"duration_ms":90000}""",
                ex("Dumbbell bench press", "dumbbell", set("s1", "done", 22500, 10), set("s2", "done", 22500, 10), set("s3", "pending", 22500, 10)),
                ex("Cable fly", "stack", set("s4", "pending", 15000, 12)),
            ),
        )
        assertFalse(v.paused)
        assertEquals(RestSpec("s2", 1800000090000, 90000), v.rest)
        assertEquals(SnapshotView.Current("Dumbbell bench press", 3, 3, 22500, 10, "dumbbell", false), v.current)
        assertEquals(2, v.setsDone)
        assertEquals(4, v.setsTotal)
        assertEquals("22.5 kg ea x 10", v.doneLine())
    }

    @Test
    fun `skipped counts as handled, paused and no rest, all handled`() {
        val v = SnapshotView.of(snap("paused", "null", ex("Lat pulldown", "stack", set("a", "skipped", 40000, 10), set("b", "done", 40000, 10))))
        assertTrue(v.paused)
        assertNull(v.rest)
        assertNull(v.current)
        assertNull(v.doneLine())
        assertEquals(2, v.setsDone)
    }

    @Test
    fun `done line for stack, bodyweight and cold start`() {
        fun line(kind: String, load: Long?, reps: Long?) = SnapshotView.of(snap("active", "null", ex("E", kind, set("a", "pending", load, reps)))).doneLine()
        assertEquals("40 kg x 10", line("stack", 40000, 10))
        assertEquals("Bodyweight x 12", line("bodyweight", null, 12))
        assertEquals("Set starting weight in the app", line("dumbbell", null, 10))
        assertEquals("2.5 kg ea", line("dumbbell", 2500, null))
        assertEquals("Bodyweight +10 kg x 8", line("bodyweight", 10000, 8))
    }
}
