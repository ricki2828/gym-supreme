package app.gymsupreme.workout

import android.app.Activity
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Handler
import android.os.Looper
import app.gymsupreme.core.journal.SnapshotView
import app.gymsupreme.core.json.Json
import app.gymsupreme.core.json.JsonWriter
import app.gymsupreme.core.log.LogLine
import java.util.UUID

/**
 * CI emulator smoke for the production path (tools/emulator_smoke.sh; phase-1 exit "rest alert
 * path covered", resume). Dogfood and debug builds only. Steps, one `am start` extra each:
 *  - `start`: a schema-v1 snapshot whose first set is done with a 3 s rest, through [LiveSession]
 *    exactly as Dart would send it (journal line, service start, rest armed, alert fired).
 *  - `pending`: after `am force-stop` and a relaunch, the journal is found (crash-safe resume).
 *  - `finish`: finish (stamps finished, stops the service) then delete, as Dart does after storing.
 *  - `lock_fire` (0.3 L1): fires the notification's Done with the activity gone; see [lockFire].
 *  - `emom:<rounds>:<period_ms>:<lead_in_ms>` (0.3 T1): a session whose timed set holds a started
 *    EMOM block compiled as Dart compiles it; the activity closes (Flutter detaches) and the
 *    service runs the cues; the same snapshot is re-submitted once mid-block. See [emom].
 * Each step logs a `selftest_session` line under GymSupreme/service.
 */
object SessionSelfTest {
    const val EXTRA = "gym_selftest_session"

    fun allowed(context: Context): Boolean = context.packageName.endsWith(".dogfood") || context.packageName.endsWith(".debug")

    fun run(context: Context, step: String) {
        val live = LiveSession.get(context)
        val line = SpikeLog.line("selftest_session").put("step", step)
        try {
            when (step) {
                "start" -> {
                    val now = System.currentTimeMillis()
                    val uuid = UUID.randomUUID().toString()
                    val rev = live.start(JsonWriter.write(snapshot(uuid, now, now + REST_MS)))
                    line.put("uuid", uuid).put("rev", rev).put("ok", true)
                }
                "pending" -> {
                    val json = live.readPending()
                    line.put("found", json != null).put("ok", json != null)
                    if (json != null) {
                        line.put("chars", json.length)
                        // L1: what a lock-screen Done left in the journal.
                        val s = Json.parseObject(json)
                        line.put("rev", s["rev"] as? Long).put("finished", s["finished"] == true)
                        val lock = (s["exercises"] as List<*>).flatMap { (it as Map<*, *>)["sets"] as List<*> }
                            .map { it as Map<*, *> }.filter { it["state"] == "done" && it["source"] == "lockscreen" }
                        line.put("lockscreen_sets", lock.size)
                        lock.firstOrNull()?.let { line.put("lock_load_g", it["load_g"] as? Long).put("lock_reps", it["reps"] as? Long).put("lock_completion", it["completion"] as? String) }
                    }
                }
                "lock_fire" -> lockFire(context, line)
                "finish" -> {
                    val out = live.finish()
                    val uuid = Regex("\"workout_uuid\":\"([^\"]+)\"").find(out)?.groupValues?.get(1)
                    line.put("finished", out.contains("\"finished\":true")).put("deleted", uuid != null && live.delete(uuid))
                        .put("ok", uuid != null)
                }
                else -> if (step.startsWith("emom:")) emom(context, step, line) else line.put("ok", false).put("error", "unknown step")
            }
        } catch (e: LiveSession.Refused) {
            line.put("ok", false).put("code", e.code).put("error", e.message)
        } catch (e: Exception) {
            line.put("ok", false).put("error", "${e.javaClass.simpleName}: ${e.message}")
        }
        line.put("counters", NativeCounters.all(context).entries.joinToString(",") { "${it.key}=${it.value}" })
        SpikeLog.write(context, line)
    }

    private const val REST_MS = 3_000L

    /**
     * L1 smoke: takes the Done button's own PendingIntent from the posted session notification,
     * closes the activity (Flutter detaches) and, [FIRE_DELAY_MS] later with the screen off,
     * fires it twice back to back (a double tap), then once more after the notification has
     * moved on (a tap on a stale notification). The receiver logs one `lock_action` line per
     * fire. With `lockdone` off there is no button: the same intent is built by hand to show the
     * receiver ignores it.
     */
    private fun lockFire(context: Context, line: LogLine) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val n = nm.activeNotifications.firstOrNull { it.id == WorkoutNotification.SESSION_ID }?.notification
        val actions = n?.actions.orEmpty()
        line.put("notification", n != null).put("actions", actions.joinToString("|") { it.title.toString() })
        val done = actions.firstOrNull { it.title == WorkoutNotification.LABEL_DONE }?.actionIntent
        val head = LiveSession.get(context).readPending()
        if (done == null && head == null) {
            line.put("ok", false).put("error", "no journal")
            return
        }
        val pi = done ?: SnapshotView.of(Json.parseObject(head!!)).let {
            WorkoutNotification.lockIntent(context, WorkoutActionReceiver.ACTION_DONE, it.rev, it.currentSetId)
        }
        line.put("from_notification", done != null).put("ok", true)
        val main = Handler(Looper.getMainLooper())
        val live = LiveSession.get(context)
        val startRev = live.headRev()
        main.postDelayed({
            send(context, pi, "first")
            send(context, pi, "double")
            // Broadcast delivery to a backgrounded app can lag by seconds (seen on API 33 CI):
            // send the stale tap only once the first one has been applied, plus well over the
            // debounce, so it can only be refused for its rev.
            var waited = 0L
            lateinit var stale: Runnable
            stale = Runnable {
                val moved = live.headRev() != startRev
                if (moved || waited >= STALE_WAIT_CAP_MS) {
                    main.postDelayed({ send(context, pi, "stale") }, WorkoutActionReceiver.DEBOUNCE_MS + 900)
                } else {
                    waited += 250
                    main.postDelayed(stale, 250)
                }
            }
            main.postDelayed(stale, 250)
        }, FIRE_DELAY_MS)
        (context as? Activity)?.finishAndRemoveTask()
    }

    private fun send(context: Context, pi: PendingIntent, which: String) {
        val l = SpikeLog.line("lock_selftest_fire").put("which", which)
        try {
            pi.send()
            l.put("sent", true)
        } catch (e: PendingIntent.CanceledException) {
            l.put("sent", false).put("error", e.message)
        }
        SpikeLog.write(context, l)
    }

    /**
     * T1 proof ladder step 2 (tools/emulator_emom.sh): starts a workout whose only pending set is
     * a timed set with a started EMOM block, anchored now, cues compiled exactly as
     * `TimerBlock.cues()` does (emom_minute at lead-in + k x period, block_end at the end). Then
     * closes the activity so Flutter detaches. Half a period after the first cue the same snapshot
     * is re-submitted as the next rev (what a mark tap or an unrelated change does): the service
     * must keep the anchor and fire nothing twice.
     */
    private fun emom(context: Context, step: String, line: LogLine) {
        val p = step.removePrefix("emom:").split(':').map { it.toLongOrNull() }
        val rounds = p.getOrNull(0)
        val period = p.getOrNull(1)
        val leadIn = p.getOrNull(2) ?: 0L
        if (rounds == null || period == null || rounds !in 1..99 || period < 1_000 || leadIn < 0) {
            line.put("ok", false).put("error", "bad emom step: $step")
            return
        }
        val live = LiveSession.get(context)
        val now = System.currentTimeMillis()
        val uuid = UUID.randomUUID().toString()
        val snap = emomSnapshot(uuid, now, rounds.toInt(), period, leadIn)
        val rev = live.start(JsonWriter.write(snap))
        line.put("uuid", uuid).put("rev", rev).put("rounds", rounds).put("period_ms", period).put("lead_in_ms", leadIn)
            .put("cues", rounds + 1).put("timers", Features.timers).put("ok", true)
        Handler(Looper.getMainLooper()).postDelayed({
            val l = SpikeLog.line("emom_reapply")
            try {
                val again = LinkedHashMap(snap).apply { put("rev", rev + 1) }
                l.put("rev", live.submit(JsonWriter.write(again), rev)).put("ok", true)
            } catch (e: Exception) {
                l.put("ok", false).put("error", "${e.javaClass.simpleName}: ${e.message}")
            }
            SpikeLog.write(context, l)
        }, leadIn + period / 2)
        (context as? Activity)?.finishAndRemoveTask()
    }

    private fun emomSnapshot(uuid: String, now: Long, rounds: Int, period: Long, leadIn: Long): Map<String, Any?> {
        val cues = ArrayList<Map<String, Any?>>()
        for (k in 0 until rounds) {
            cues.add(linkedMapOf("index" to k.toLong(), "at_ms" to leadIn + k * period, "kind" to "emom_minute", "label" to "EMOM ${k + 1} of $rounds"))
        }
        cues.add(linkedMapOf("index" to rounds.toLong(), "at_ms" to leadIn + rounds * period, "kind" to "block_end", "label" to "Done"))
        val block = linkedMapOf<String, Any?>(
            "type" to "emom", "work_ms" to period, "rest_ms" to 0L, "rounds" to rounds.toLong(), "cap_ms" to 0L,
            "lead_in_ms" to leadIn, "warn_ms" to 0L, "run" to 0L, "started_at_wall_ms" to now, "elapsed_before_ms" to 0L,
            "cues" to cues,
        )
        val set = linkedMapOf<String, Any?>(
            "set_id" to "$uuid:0", "set_ordinal" to 1L, "kind" to "timed", "plan_load_g" to null, "plan_reps" to 0L,
            "target_load_g" to null, "target_reps" to 0L, "state" to "pending", "load_g" to null, "reps" to null,
            "completion" to null, "source" to null, "started_at_ms" to null, "ended_at_ms" to null, "offset_ms" to null,
            "block" to block,
        )
        return LinkedHashMap(snapshot(uuid, now, now)).apply {
            put("rest", null)
            put("next_set_n", 1L)
            put(
                "exercises",
                listOf(
                    linkedMapOf(
                        "exercise_id" to "selftest-emom", "name" to "Self-test EMOM", "load_kind" to "timed", "unilateral" to false,
                        "rest_s" to 0L, "rep_lo" to 0L, "rep_hi" to 0L, "sets" to listOf(set),
                    ),
                ),
            )
        }
    }

    private const val FIRE_DELAY_MS = 5_000L
    private const val STALE_WAIT_CAP_MS = 20_000L

    private fun set(id: String, ordinal: Int, done: Boolean, now: Long): Map<String, Any?> = linkedMapOf(
        "set_id" to id,
        "set_ordinal" to ordinal.toLong(),
        "kind" to "reps",
        "plan_load_g" to 20_000L,
        "plan_reps" to 10L,
        "target_load_g" to 20_000L,
        "target_reps" to 10L,
        "state" to if (done) "done" else "pending",
        "load_g" to if (done) 20_000L else null,
        "reps" to if (done) 10L else null,
        "completion" to if (done) "tap_unchanged" else null,
        "source" to if (done) "app" else null,
        "started_at_ms" to if (done) now - 40_000 else null,
        "ended_at_ms" to if (done) now else null,
        "offset_ms" to if (done) 0L else null,
        "block" to null,
    )

    private fun snapshot(uuid: String, now: Long, restEnd: Long): Map<String, Any?> = linkedMapOf(
        "schema" to 1L,
        "workout_uuid" to uuid,
        "rev" to 0L,
        "app_version" to "selftest",
        "gym_id" to "selftest",
        "type_id" to null,
        "muscles" to listOf("chest"),
        "started_at_ms" to now - 60_000,
        "tz_offset_min" to 0L,
        "state" to "active",
        "paused_at_ms" to null,
        "paused_total_ms" to 0L,
        "rest" to linkedMapOf("set_id" to "$uuid:0", "ends_at_wall_ms" to restEnd, "duration_ms" to REST_MS),
        "finished" to false,
        "ended_at_ms" to null,
        "set_ready_at_ms" to now,
        "next_set_n" to 2L,
        "swaps" to 0L,
        "exercises" to listOf(
            linkedMapOf(
                "exercise_id" to "selftest-press",
                "name" to "Self-test press",
                "load_kind" to "dumbbell",
                "unilateral" to false,
                "rest_s" to 3L,
                "rep_lo" to 8L,
                "rep_hi" to 12L,
                "sets" to listOf(set("$uuid:0", 1, true, now), set("$uuid:1", 2, false, now)),
            ),
        ),
    )
}
