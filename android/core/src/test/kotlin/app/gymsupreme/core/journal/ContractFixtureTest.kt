package app.gymsupreme.core.journal

import app.gymsupreme.core.json.Json
import app.gymsupreme.core.json.JsonWriter
import app.gymsupreme.core.rest.RestSpec
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * B1: the shared journal fixtures (authored by the engine lane, byte-identical in
 * packages/gym_engine/test/fixtures/contract). Kotlin must read every one and write it back
 * byte for byte, since it re-encodes the snapshot when it stamps a finish.
 */
class ContractFixtureTest {
    private val dir = File("src/test/fixtures/contract")
    private val names = listOf("fresh", "resting", "mid_set", "paused", "finished", "typed")

    private fun fixture(name: String): String {
        val text = File(dir, "snapshot_v1_$name.json").readText(Charsets.UTF_8)
        assertTrue(text.endsWith("\n") && text.count { it == '\n' } == 1, "$name: one line plus newline")
        return text.dropLast(1)
    }

    @Test
    fun `every snapshot fixture round-trips byte for byte`() {
        for (n in names) {
            val line = fixture(n)
            assertEquals(line, JsonWriter.write(Json.parse(line)), n)
        }
    }

    @Test
    fun `heads and views read as the fixtures say`() {
        val u = "3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b"
        assertEquals(Journal.Head(u, 0, 1, false), Journal.head(Json.parseObject(fixture("fresh"))))
        val fresh = SnapshotView.of(Json.parseObject(fixture("fresh")))
        assertNull(fresh.rest)
        assertEquals(SnapshotView.Current("Dumbbell Bench Press", 1, 3, 22500, 10, "dumbbell", false), fresh.current)
        assertEquals("22.5 kg ea x 10", fresh.doneLine())

        val resting = SnapshotView.of(Json.parseObject(fixture("resting")))
        assertEquals(RestSpec("$u:1", 1795400380000, 120000), resting.rest)
        assertEquals(3, resting.current?.setNumber)

        val paused = SnapshotView.of(Json.parseObject(fixture("paused")))
        assertTrue(paused.paused)
        assertNull(paused.rest)

        val fin = Json.parseObject(fixture("finished"))
        assertTrue(Journal.head(fin).finished)
        assertNull(SnapshotView.of(fin).current)
    }

    @Test
    fun `optional set key entry is ignored by strict decode and kept byte for byte`() {
        val typed = fixture("typed")
        assertTrue(typed.contains(",\"entry\":\"typed\"}"), "the typed fixture carries entry")
        SnapshotSchema.validate(Json.parseObject(typed))
        assertEquals(typed, JsonWriter.write(Json.parse(typed)))
        assertFalse(fixture("mid_set").contains("\"entry\""), "0.2-shaped fixtures have no entry")
    }

    @Test
    fun `torn-tail journal - line 3 wins, the half line is a torn tail, not corrupt`() {
        val r = Journal.read(File(dir, "journal_v1_torn_tail.jsonl").readText(Charsets.UTF_8))
        assertEquals(3, r.goodLines)
        assertEquals(0, r.corruptLines)
        assertTrue(r.tornTail)
        assertEquals(4L, r.last?.rev)
    }

    @Test
    fun `finish stamp - paused fixture folds the pause and ends`() {
        val now = 1795400500000L
        val out = FinishStamp.stamp(Json.parseObject(fixture("paused")), now)
        assertEquals(6L, out["rev"])
        assertEquals(true, out["finished"])
        assertEquals("active", out["state"])
        assertNull(out["paused_at_ms"])
        assertEquals(100000L, out["paused_total_ms"])
        assertEquals(now, out["ended_at_ms"])
        assertNull(out["rest"])
        assertEquals(Json.parseObject(fixture("paused")).keys.toList(), out.keys.toList(), "key order kept")
    }

    @Test
    fun `finish stamp - resting clears the rest, finished comes back unchanged`() {
        val out = FinishStamp.stamp(Json.parseObject(fixture("resting")), 1795400390000L)
        assertNull(out["rest"])
        assertEquals(3L, out["rev"])
        assertEquals(0L, out["paused_total_ms"])
        val fin = Json.parseObject(fixture("finished"))
        assertEquals(JsonWriter.write(fin), JsonWriter.write(FinishStamp.stamp(fin, 1L)))
        assertFalse(fin.containsKey("nothing"))
    }
}

class SnapshotSchemaTest {
    private val fresh = File("src/test/fixtures/contract/snapshot_v1_fresh.json").readText(Charsets.UTF_8).dropLast(1)

    private fun bad(edit: (LinkedHashMap<String, Any?>) -> Unit): String {
        val m = LinkedHashMap(Json.parseObject(fresh))
        edit(m)
        return assertFailsWith<app.gymsupreme.core.json.JsonException> { SnapshotSchema.validate(Json.parseObject(JsonWriter.write(m))) }.message ?: ""
    }

    @Suppress("UNCHECKED_CAST")
    private fun firstSet(m: Map<String, Any?>): LinkedHashMap<String, Any?> =
        ((m["exercises"] as List<Any?>)[0] as Map<String, Any?>)["sets"].let { (it as List<Any?>)[0] as LinkedHashMap<String, Any?> }

    @Test
    fun `every fixture passes strict decode, the torn journal's whole lines too`() {
        for (n in listOf("fresh", "resting", "mid_set", "paused", "finished", "typed")) {
            SnapshotSchema.validate(Json.parseObject(File("src/test/fixtures/contract/snapshot_v1_$n.json").readText(Charsets.UTF_8).dropLast(1)))
        }
        val lines = File("src/test/fixtures/contract/journal_v1_torn_tail.jsonl").readText(Charsets.UTF_8).split('\n')
        lines.dropLast(1).forEach { SnapshotSchema.validate(Json.parseObject(it)) }
    }

    @Test
    fun `fresh fixture keeps U+2028 and DEL raw`() {
        val name = ((Json.parseObject(fresh)["exercises"] as List<*>)[1] as Map<*, *>)["name"] as String
        assertTrue(name.contains(' ') && name.contains('\u007f'), name)
        assertTrue(JsonWriter.write(name).contains(' '))
    }

    @Test
    fun `strict rules refuse missing keys, unknown enums, broken pairings, doubles`() {
        assertTrue(bad { it.remove("swaps") }.contains("swaps"))
        assertTrue(bad { it["type_id"] = 3L }.contains("type_id"))
        assertTrue(bad { it["state"] = "stopped" }.contains("state"))
        assertTrue(bad { it["state"] = "paused" }.contains("paused_at_ms"))
        assertTrue(bad { it["paused_at_ms"] = 5L }.contains("paused_at_ms"))
        assertTrue(bad { it["rev"] = 1.5 }.contains("floating"))
        assertTrue(bad { firstSet(it)["block"] = mapOf("work_ms" to 60000.0) }.contains("floating"))
        assertTrue(bad { firstSet(it)["state"] = "done" }.contains("completion"))
        assertTrue(bad { firstSet(it)["completion"] = "tap_unchanged" }.contains("completion"))
        assertTrue(bad { firstSet(it)["kind"] = "distance" }.contains("kind"))
        assertTrue(bad { firstSet(it).remove("plan_reps") }.contains("plan_reps"))
        assertTrue(bad { it["next_set_n"] = 0L }.contains("next_set_n"))
    }

    @Test
    fun `extra keys are ignored`() {
        val m = LinkedHashMap(Json.parseObject(fresh))
        m["future_field"] = "x"
        SnapshotSchema.validate(m)
    }
}
