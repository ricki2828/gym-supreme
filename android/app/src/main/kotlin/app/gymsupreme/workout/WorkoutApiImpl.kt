package app.gymsupreme.workout

import android.app.Activity
import app.gymsupreme.platform.FlutterError
import app.gymsupreme.platform.PigeonEventSink
import app.gymsupreme.platform.SnapshotsStreamHandler
import app.gymsupreme.platform.WorkoutApi

/**
 * Pigeon v1 `WorkoutApi` over [LiveSession] (contracts/session_snapshot.md, CHANGES.md). Every
 * call arrives on the main thread from Dart in the visible activity, so starting the service here
 * is allowed. A [LiveSession.Refused] becomes `FlutterError(code)`, which the Dart port maps to
 * `WorkoutPortException(code)` (`stale_rev` to `StaleRevException`).
 */
class WorkoutApiImpl(private val activity: Activity) : WorkoutApi {
    private val live get() = LiveSession.get(activity)

    private inline fun <T> guard(callback: (Result<T>) -> Unit, block: () -> T) {
        val r = try {
            Result.success(block())
        } catch (e: LiveSession.Refused) {
            Result.failure(FlutterError(e.code, e.message))
        } catch (e: Exception) {
            SpikeLog.write(activity, SpikeLog.line("workout_api_error").put("error", "${e.javaClass.simpleName}: ${e.message}"))
            Result.failure(FlutterError("native_error", "${e.javaClass.simpleName}: ${e.message}"))
        }
        callback(r)
    }

    override fun startSession(snapshotJson: String, callback: (Result<Long>) -> Unit) = guard(callback) { live.start(snapshotJson) }

    override fun submitSnapshot(snapshotJson: String, baseRev: Long, callback: (Result<Long>) -> Unit) =
        guard(callback) { live.submit(snapshotJson, baseRev) }

    override fun pauseSession(callback: (Result<Unit>) -> Unit) = guard(callback) { live.pause() }

    override fun finishSession(callback: (Result<String>) -> Unit) = guard(callback) { live.finish() }

    override fun readPendingJournal(callback: (Result<String?>) -> Unit) = guard(callback) { live.readPending() }

    override fun deleteJournal(workoutUuid: String, callback: (Result<Unit>) -> Unit) = guard(callback) {
        if (!live.delete(workoutUuid)) throw LiveSession.Refused("wrong_workout", "the journal belongs to another workout")
    }

    override fun shareFile(fileName: String, mimeType: String, content: String, callback: (Result<Unit>) -> Unit) =
        guard(callback) { ExportShare.share(activity, fileName, mimeType, content) }

    override fun getNativeCounters(): Map<String, Long> = live.counters()
}

/** `WorkoutEvents.snapshots`: every snapshot the service accepted or wrote, as JSON. Main thread. */
class SnapshotsStream(private val activity: Activity) : SnapshotsStreamHandler() {
    private var sink: PigeonEventSink<String>? = null

    override fun onListen(p0: Any?, sink: PigeonEventSink<String>) {
        this.sink = sink
        LiveSession.get(activity).onSnapshot = { json -> this.sink?.success(json) }
    }

    override fun onCancel(p0: Any?) {
        sink = null
        LiveSession.get(activity).onSnapshot = null
    }

    fun dispose() {
        sink = null
        LiveSession.get(activity).onSnapshot = null
    }
}
