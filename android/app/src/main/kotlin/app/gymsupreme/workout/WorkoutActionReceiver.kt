package app.gymsupreme.workout

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import app.gymsupreme.core.session.LockReducer

/**
 * Lock-screen actions (R3): a broadcast reaches the running service and never starts it. With
 * no workout running the action is logged and dropped.
 *
 * Done / +1 rep / Skip rest (0.3 cut L1, flag `lockdone`) carry the journal `rev` the
 * notification was built from (and the set id for Done / +1). [LiveSession.lockAction] applies
 * them through the pure [LockReducer] and journals the result as rev + 1, Flutter attached or
 * not. Exactly once per tap: each rev has its own PendingIntent, a stale rev is a no-op, and any
 * action within [DEBOUNCE_MS] of the last accepted one is dropped. Every outcome is one
 * `lock_action` line under GymSupreme/service. Main thread; never throws (a crash here would
 * take the service and its rest alerts with it).
 */
class WorkoutActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val s = WorkoutService.instance
        val lock = when (intent.action) {
            ACTION_DONE -> LockReducer.Action.DONE
            ACTION_PLUS_REP -> LockReducer.Action.PLUS_REP
            ACTION_SKIP_REST -> LockReducer.Action.SKIP_REST
            else -> null
        }
        if (lock == null) {
            SpikeLog.write(context, SpikeLog.line("action").put("action", intent.action).put("service_running", s != null))
            if (intent.action == ACTION_STOP) s?.stopWorkout("lockscreen")
            return
        }
        val rev = intent.getLongExtra(EXTRA_REV, -1)
        val setId = intent.getStringExtra(EXTRA_SET_ID)
        val line = SpikeLog.line("lock_action").put("action", lock.wire).put("rev", rev).put("set_id", setId)
        try {
            val now = SystemClock.elapsedRealtime()
            val outcome = when {
                !Features.lockDone -> "flag_off"
                lastAcceptedAt.let { it != null && now - it < DEBOUNCE_MS } -> "debounced"
                else -> {
                    val live = LiveSession.get(context)
                    line.put("dart_listening", live.onSnapshot != null)
                    val r = live.lockAction(lock, setId, rev)
                    if (r.applied) {
                        lastAcceptedAt = now
                        line.put("new_rev", r.newRev)
                    }
                    r.outcome
                }
            }
            line.put("outcome", outcome)
        } catch (e: Exception) {
            line.put("outcome", "error").put("error", "${e.javaClass.simpleName}: ${e.message}")
        }
        SpikeLog.write(context, line)
    }

    companion object {
        const val ACTION_STOP = "app.gymsupreme.action.STOP"
        const val ACTION_DONE = "app.gymsupreme.action.LOCK_DONE"
        const val ACTION_PLUS_REP = "app.gymsupreme.action.LOCK_PLUS_REP"
        const val ACTION_SKIP_REST = "app.gymsupreme.action.LOCK_SKIP_REST"
        const val EXTRA_REV = "rev"
        const val EXTRA_SET_ID = "set_id"

        /** A second tap this soon after an accepted action is dropped (plan item 9, R3). */
        const val DEBOUNCE_MS = 600L

        /** elapsedRealtime of the last applied action; in memory (a new process has no tap to debounce). */
        private var lastAcceptedAt: Long? = null
    }
}
