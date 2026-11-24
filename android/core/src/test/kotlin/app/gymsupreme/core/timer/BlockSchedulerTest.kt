package app.gymsupreme.core.timer

import app.gymsupreme.core.journal.SnapshotView
import app.gymsupreme.core.json.Json
import app.gymsupreme.core.rest.RestSpec
import app.gymsupreme.core.rest.RestTracker
import java.io.File
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Proof ladder step 1 (0.3 plan, cut T1): the native cue scheduler on a fake clock, fed the
 * Dart-generated `timer_v1_emom20` vector (TimerSession: attach, start, mark, pause near a cue,
 * resume, finish, undo, restart). The offsets are printed for the CI log.
 */
class BlockSchedulerTest {
    private val vector = File("src/test/fixtures/contract/timer_v1_emom20.json").readText(Charsets.UTF_8)

    @Suppress("UNCHECKED_CAST")
    private val steps: List<Map<String, Any?>> = Json.parseObject(vector)["steps"] as List<Map<String, Any?>>

    private fun view(step: String) = SnapshotView.of(steps.first { it["step"] == step }["snapshot"] as Map<String, Any?>)

    private fun nowWall(step: String) = steps.first { it["step"] == step }["now_ms"] as Long

    /** A fired or missed cue as the service would log it. */
    data class Fire(val run: Long, val index: Int, val kind: String, val lateMs: Long, val missed: Boolean)

    /**
     * The service around the scheduler: elapsed = wall - [skew]; each snapshot reaches Kotlin
     * [deliveryMs] after Dart wrote it; every wake comes 0..[jitterMs] late. A pause stops the
     * service (the scheduler is dropped, only [store] survives), like WorkoutService.stopWorkout.
     */
    private class Service(val store: FiredStore, val jitterMs: Long, seed: Int) {
        val skew = 1_795_000_000_000L
        val rnd = Random(seed)
        var now = 0L // elapsed
        var sched: BlockScheduler? = BlockScheduler(store)
        val fires = ArrayList<Fire>()

        fun wall() = now + skew

        fun runUntil(elapsed: Long) {
            while (true) {
                val s = sched ?: break
                val next = s.nextAt() ?: break
                val wake = maxOf(now, next) + if (next == Long.MIN_VALUE) 0 else rnd.nextLong(0, jitterMs + 1)
                if (wake > elapsed) break
                now = maxOf(now, wake)
                for (d in s.due(now)) fires.add(Fire(d.run, d.cue.index, d.cue.kind, d.lateMs, d.missed))
            }
            now = maxOf(now, elapsed)
        }

        fun apply(v: SnapshotView) {
            if (v.paused) {
                sched?.clear("paused")
                sched = null
                return
            }
            val s = sched ?: BlockScheduler(store).also { sched = it }
            s.onSnapshot(v.blocks, v.paused, wall(), now)
            runUntil(now)
        }

        fun processDeath() {
            sched = null
        }
    }

    private fun replay(svc: Service, deliveryMs: Long, deathAfter: String? = null) {
        for (st in steps) {
            val name = st["step"] as String
            val at = (st["now_ms"] as Long) - svc.skew + deliveryMs
            svc.runUntil(at)
            if (name == deathAfter) {
                // Reopened 2 s after the kill: Dart re-sends the head snapshot.
                svc.processDeath()
                svc.runUntil(at + 2_000)
            }
            svc.apply(view(name))
        }
        // Run the restarted block (run 1) to its end.
        svc.runUntil(svc.now + 25 * 60_000L)
    }

    private fun check(fires: List<Fire>, label: String) {
        val byKey = fires.groupBy { it.run to it.index }
        assertTrue(byKey.values.all { it.size == 1 }, "$label: duplicate cue: ${byKey.filterValues { it.size > 1 }}")
        for (run in 0L..1L) {
            val r = fires.filter { it.run == run }.sortedBy { it.index }
            assertEquals((0..20).toList(), r.map { it.index }, "$label run $run: indices")
            assertEquals(20, r.count { it.kind == "emom_minute" }, "$label run $run: emom_minute")
            assertEquals(1, r.count { it.kind == "block_end" }, "$label run $run: block_end")
            assertTrue(r.none { it.missed }, "$label run $run: missed ${r.filter { it.missed }}")
            val max = r.maxOf { it.lateMs }
            assertTrue(max <= 1_000, "$label run $run: max late $max ms")
            val emom = r.filter { it.kind == "emom_minute" }
            println(
                "T1 JVM $label run=$run emom_minute=${emom.size}/20 block_end=1/1 duplicates=0 max_late_ms=$max " +
                    "late_ms=[${r.joinToString(",") { it.lateMs.toString() }}]",
            )
        }
    }

    @Test
    fun `20-min EMOM from the Dart vector fires 20 of 20 on time, no duplicates, across mark, pause near a cue, resume, undo and restart`() {
        val svc = Service(MemoryFiredStore(), jitterMs = 300, seed = 7)
        replay(svc, deliveryMs = 120)
        check(svc.fires, "jitter300")
        // Cue 2 was 400 ms behind the pause point: it fired before the pause, and its resend at
        // at_ms 0 on resume was suppressed by the store.
        assertEquals(1, svc.fires.count { it.run == 0L && it.index == 2 })
    }

    @Test
    fun `process death mid-block and re-arm from the durable store neither loses nor repeats a cue`() {
        val store = MemoryFiredStore()
        val svc = Service(store, jitterMs = 250, seed = 11)
        replay(svc, deliveryMs = 80, deathAfter = "mark")
        check(svc.fires, "death")
    }

    @Test
    fun `run bump re-fires every cue and drops the older run's keys`() {
        val store = MemoryFiredStore()
        val svc = Service(store, jitterMs = 0, seed = 1)
        replay(svc, deliveryMs = 0)
        assertEquals(21, svc.fires.count { it.run == 1L })
        assertTrue(store.keys.none { it.startsWith("c\t") && it.split('\t')[2] == "0" }, "run 0 keys dropped: ${store.keys}")
    }

    @Test
    fun `re-applying the same block keeps the anchor even if the wall clock jumps`() {
        val s = BlockScheduler(MemoryFiredStore())
        val v = view("start")
        val start = nowWall("start")
        val first = s.onSnapshot(v.blocks, false, start, 1_000)
        assertTrue(first.single() is BlockScheduler.Change.Armed)
        val t0 = (first.single() as BlockScheduler.Change.Armed).t0
        assertEquals(1_000, t0)
        // Wall clock moved 1 h forward; the same block (mark tap) must not re-anchor.
        val again = s.onSnapshot(view("mark").blocks, false, start + 3_600_000, 5_000)
        assertEquals(listOf<BlockScheduler.Change>(BlockScheduler.Change.Kept(v.blocks.single().setId, 0)), again)
        assertEquals(t0 + 10_000, s.nextAt())
    }

    @Test
    fun `a late wake fires every due cue once, in order`() {
        val s = BlockScheduler(MemoryFiredStore())
        s.onSnapshot(view("start").blocks, false, nowWall("start"), 0)
        val d = s.due(190_500) // cues 0..3 at 10 s, 70 s, 130 s, 190 s
        assertEquals(listOf(0, 1, 2, 3), d.map { it.cue.index })
        assertEquals(listOf(180_500L, 120_500L, 60_500L, 500L), d.map { it.lateMs })
        assertTrue(d.none { it.missed })
        assertTrue(s.due(190_600).isEmpty())
        assertEquals(250_000L, s.nextAt())
    }

    @Test
    fun `cues overdue at arm time are recorded as missed, not played`() {
        val store = MemoryFiredStore()
        val s = BlockScheduler(store)
        // Armed 192.5 s after the anchor (app reopened late): cues 0..2 are stale; cue 3 (190 s)
        // is 2.5 s late, inside STALE_MS, so it still plays.
        val ch = s.onSnapshot(view("start").blocks, false, nowWall("start") + 192_500, 192_500)
        assertEquals(3, (ch.single() as BlockScheduler.Change.Armed).overdue)
        val d = s.due(192_500)
        assertEquals(listOf(0, 1, 2, 3), d.map { it.cue.index })
        assertEquals(listOf(true, true, true, false), d.map { it.missed })
        assertEquals(listOf(182_500L, 122_500L, 62_500L, 2_500L), d.map { it.lateMs })
        assertTrue(listOf(0, 1, 2, 3).all { store.contains(FiredKeys.cue(view("start").blocks.single().setId, 0, it)) })
        // A cue a few seconds overdue (inside STALE_MS) still fires.
        val s2 = BlockScheduler(MemoryFiredStore())
        s2.onSnapshot(view("start").blocks, false, nowWall("start") + 13_000, 13_000)
        val d2 = s2.due(13_000)
        assertEquals(listOf(0), d2.map { it.cue.index })
        assertTrue(d2.none { it.missed })
    }

    @Test
    fun `pause, finish and a non-pending set cancel the block`() {
        val s = BlockScheduler(MemoryFiredStore())
        s.onSnapshot(view("start").blocks, false, nowWall("start"), 0)
        assertTrue(view("pause").paused)
        assertEquals("paused", (s.onSnapshot(view("pause").blocks, true, 0, 1).single() as BlockScheduler.Change.Cancelled).why)
        assertNull(s.nextAt())
        s.onSnapshot(view("resume").blocks, false, nowWall("resume"), 1_000)
        assertTrue(view("finish").blocks.isEmpty(), "a done set's block is not armed")
        assertEquals("stopped", (s.onSnapshot(view("finish").blocks, false, nowWall("finish"), 2_000).single() as BlockScheduler.Change.Cancelled).why)
        assertNull(s.nextAt())
        // Undo re-arms the block but without an anchor: nothing runs until Start.
        assertTrue(view("undo").blocks.isEmpty())
        assertTrue(view("attach").blocks.isEmpty())
    }

    @Test
    fun `the view reads the block from the vector, lenient on a malformed one`() {
        val v = view("resume")
        val b = v.blocks.single()
        assertEquals(0L, b.run)
        assertEquals(nowWall("resume"), b.startedAtWallMs)
        assertEquals(BlockCue(2, 0, "emom_minute", "EMOM 3 of 20"), b.cues.first())
        assertEquals("block_end", b.cues.last().kind)
        assertEquals(20, b.cues.last().index)
        assertEquals(steps.first()["snapshot"].let { (it as Map<*, *>)["workout_uuid"] }, v.workoutUuid)
        val bad = vector.substringAfter("\"step\":\"start\"").substringAfter("\"snapshot\":").let { s ->
            // Cut the start snapshot out of the vector and break one cue's at_ms.
            var depth = 0
            var end = 0
            for ((i, ch) in s.withIndex()) {
                if (ch == '{') depth++
                if (ch == '}') depth--
                if (depth == 0) {
                    end = i
                    break
                }
            }
            s.substring(0, end + 1).replaceFirst("\"at_ms\":10000", "\"at_ms\":\"soon\"")
        }
        val bv = SnapshotView.of(Json.parseObject(bad))
        assertTrue(bv.blocks.isEmpty())
        assertEquals(1, bv.badBlocks)
        assertTrue(bv.current != null, "the rest of the view still reads")
    }

    @Test
    fun `fired log round-trips, ignores a torn tail and another workout's file`() {
        val text = FiredLog.encode("u1", listOf(FiredKeys.cue("u1:0", 0, 3), FiredKeys.rest("u1:1")))
        assertEquals(setOf("c\tu1:0\t0\t3", "r\tu1:1"), FiredLog.parse(text, "u1"))
        assertEquals(setOf("c\tu1:0\t0\t3"), FiredLog.parse(text.dropLast(3), "u1"))
        assertNull(FiredLog.parse(text, "u2"))
        assertNull(FiredLog.parse("", "u1"))
    }

    @Test
    fun `a rest fired before process death does not buzz again on resume`() {
        val store = MemoryFiredStore()
        store.add(FiredKeys.rest(RestSpec("s1", 1_000, 90_000).id))
        val t = RestTracker(firedBefore = { store.contains(FiredKeys.rest(it)) })
        assertEquals(RestTracker.Action.Keep, t.onSnapshot(RestSpec("s1", 1_000, 90_000), 1_500, 10))
        assertTrue(t.onSnapshot(RestSpec("s2", 1_000, 90_000), 1_500, 10) is RestTracker.Action.FireNow)
    }

    @Test
    fun `durable store - done, undo, done again buzzes twice`() {
        val store = MemoryFiredStore()
        val first = RestSpec("s1", 100_000, 90_000)
        val t1 = RestTracker(firedBefore = { store.contains(FiredKeys.rest(it)) })
        assertTrue(t1.onSnapshot(first, 10_000, 10) is RestTracker.Action.Arm)
        store.add(FiredKeys.rest(first.id)) // committed before the buzz, as the service does
        t1.onFired(first.id)
        // Pause (service stops), then the redone set's rest arrives in a fresh process.
        val again = RestSpec("s1", 300_000, 90_000)
        val t2 = RestTracker(firedBefore = { store.contains(FiredKeys.rest(it)) })
        assertTrue(t2.onSnapshot(again, 220_000, 10) is RestTracker.Action.Arm)
        // The first rest still never re-fires after process death.
        assertEquals(RestTracker.Action.Keep, RestTracker(firedBefore = { store.contains(FiredKeys.rest(it)) }).onSnapshot(first, 100_500, 30))
    }
}
