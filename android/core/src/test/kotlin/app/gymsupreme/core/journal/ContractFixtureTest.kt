package app.gymsupreme.core.journal

import app.gymsupreme.core.json.Json
import app.gymsupreme.core.json.JsonWriter
import app.gymsupreme.core.rest.RestSpec
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
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
    private val names = listOf("fresh", "resting", "mid_set", "paused", "finished")

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
