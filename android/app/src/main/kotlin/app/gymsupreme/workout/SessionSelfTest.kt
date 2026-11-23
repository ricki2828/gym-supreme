package app.gymsupreme.workout

import android.content.Context
import app.gymsupreme.core.json.JsonWriter
import java.util.UUID

/**
 * CI emulator smoke for the production path (tools/emulator_smoke.sh; phase-1 exit "rest alert
 * path covered", resume). Dogfood and debug builds only. Steps, one `am start` extra each:
 *  - `start`: a schema-v1 snapshot whose first set is done with a 3 s rest, through [LiveSession]
 *    exactly as Dart would send it (journal line, service start, rest armed, alert fired).
 *  - `pending`: after `am force-stop` and a relaunch, the journal is found (crash-safe resume).
 *  - `finish`: finish (stamps finished, stops the service) then delete, as Dart does after storing.
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
                    if (json != null) line.put("chars", json.length)
                }
                "finish" -> {
                    val out = live.finish()
                    val uuid = Regex("\"workout_uuid\":\"([^\"]+)\"").find(out)?.groupValues?.get(1)
                    line.put("finished", out.contains("\"finished\":true")).put("deleted", uuid != null && live.delete(uuid))
                        .put("ok", uuid != null)
                }
                else -> line.put("ok", false).put("error", "unknown step")
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

    private fun set(id: String, ordinal: Int, done: Boolean, now: Long): Map<String, Any?> = linkedMapOf(
        "set_id" to id,
        "set_ordinal" to ordinal.toLong(),
        "kind" to "reps",
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
        "rest" to linkedMapOf("set_id" to "st-1", "ends_at_wall_ms" to restEnd, "duration_ms" to REST_MS),
        "finished" to false,
        "ended_at_ms" to null,
        "exercises" to listOf(
            linkedMapOf(
                "exercise_id" to "selftest-press",
                "name" to "Self-test press",
                "load_kind" to "dumbbell",
                "unilateral" to false,
                "rest_s" to 3L,
                "rep_lo" to 8L,
                "rep_hi" to 12L,
                "sets" to listOf(set("st-1", 1, true, now), set("st-2", 2, false, now)),
            ),
        ),
    )
}
