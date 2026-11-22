package app.gymsupreme.workout

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Lock-screen actions (R3): a broadcast reaches the running service and never starts it. With
 * no workout running the action is logged and dropped. The spike has Stop only; Done, +1 rep
 * and Skip rest follow in phase 1 with `set_id` + `rev` and the 600 ms debounce.
 */
class WorkoutActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val s = WorkoutService.instance
        SpikeLog.write(context, SpikeLog.line("action").put("action", intent.action).put("service_running", s != null))
        if (intent.action == ACTION_STOP) s?.stopWorkout("lockscreen")
    }

    companion object {
        const val ACTION_STOP = "app.gymsupreme.action.STOP"
    }
}
