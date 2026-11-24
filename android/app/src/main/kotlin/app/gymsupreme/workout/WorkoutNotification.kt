package app.gymsupreme.workout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import app.gymsupreme.MainActivity

/**
 * The ongoing workout notification (plan 6.2, R3), shown on the lock screen: what runs now, a
 * countdown to the next cue, the last heart rate, and Stop as a broadcast to
 * [WorkoutActionReceiver] (never a service start). Each audible cue also posts a short
 * heads-up on a separate channel; its sound and vibration are off because the service plays
 * them itself on the alarm stream ([Alerter]).
 */
class WorkoutNotification(private val context: Context) {
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun createChannels() {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ONGOING, "Workout", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while a workout runs"
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_CUE, "Rest and timer alerts", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Rest over and interval cues"
                setSound(null, null)
                enableVibration(false)
                setShowBadge(false)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            },
        )
    }

    /**
     * Lock-screen actions for one journal rev (cut L1, flag `lockdone`): Done and +1 rep for
     * [setId] when it is eligible, Skip rest while a rest runs. Null = no actions (0.2 behaviour).
     */
    data class Lock(val rev: Long, val setId: String?, val doneAndPlus: Boolean, val skipRest: Boolean)

    data class Content(
        val title: String,
        val text: String,
        val nextCueWallMs: Long?,
        val stopAction: Boolean = true,
        val lock: Lock? = null,
    )

    fun build(c: Content): Notification {
        val b = Notification.Builder(context, CHANNEL_ONGOING)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(c.title)
            .setContentText(c.text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setContentIntent(openApp())
        // Android 12+ may hold a new foreground service's notification back for up to 10 s unless
        // it has actions or asks to show at once; in that window updates are swallowed. The
        // workout notification has no actions in cut 1 and must be on the lock screen at once (R3).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) b.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        if (c.stopAction) b.addAction(Notification.Action.Builder(null, "Stop", action(WorkoutActionReceiver.ACTION_STOP)).build())
        c.lock?.let { l ->
            if (l.doneAndPlus && l.setId != null) {
                b.addAction(Notification.Action.Builder(null, LABEL_DONE, lockIntent(context, WorkoutActionReceiver.ACTION_DONE, l.rev, l.setId)).build())
                b.addAction(Notification.Action.Builder(null, LABEL_PLUS_REP, lockIntent(context, WorkoutActionReceiver.ACTION_PLUS_REP, l.rev, l.setId)).build())
            }
            if (l.skipRest) b.addAction(Notification.Action.Builder(null, LABEL_SKIP_REST, lockIntent(context, WorkoutActionReceiver.ACTION_SKIP_REST, l.rev, null)).build())
        }
        if (c.nextCueWallMs != null) {
            b.setUsesChronometer(true).setChronometerCountDown(true).setWhen(c.nextCueWallMs).setShowWhen(true)
        } else {
            b.setShowWhen(false)
        }
        return b.build()
    }

    fun update(c: Content, id: Int) = try {
        manager.notify(id, build(c))
    } catch (_: RuntimeException) {
    }

    /** Heads-up for one cue; replaced by the next and gone after a minute. */
    fun cue(title: String): String = try {
        if (!manager.areNotificationsEnabled()) {
            "denied"
        } else {
            val n = Notification.Builder(context, CHANNEL_CUE)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setContentTitle(title)
                .setCategory(Notification.CATEGORY_ALARM)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setTimeoutAfter(60_000)
                .setContentIntent(openApp())
                .build()
            manager.notify(CUE_ID, n)
            "posted"
        }
    } catch (e: RuntimeException) {
        "error:${e.javaClass.simpleName}"
    }

    fun clearCue() = try {
        manager.cancel(CUE_ID)
    } catch (_: RuntimeException) {
    }

    private fun openApp(): PendingIntent {
        val i = Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, 0, i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    /** Explicit, immutable broadcast to the in-process receiver (R3). */
    private fun action(action: String): PendingIntent {
        val i = Intent(context, WorkoutActionReceiver::class.java).setAction(action)
        return PendingIntent.getBroadcast(context, action.hashCode(), i, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        const val CHANNEL_ONGOING = "workout"
        const val CHANNEL_CUE = "cues"
        /** Spike and self-test runs. */
        const val NOTIFICATION_ID = 2001

        /**
         * A workout. A different id from the spike's: on Android 13+ the removal of the previous
         * run's foreground notification (stopForeground REMOVE) is processed asynchronously and,
         * with the same id, can land after the new run posted its notification and delete it
         * (seen in CI on API 33/34/36 when a session started 1 s after the spike self-test).
         */
        const val SESSION_ID = 2003
        const val CUE_ID = 2002

        const val LABEL_DONE = "Done"
        const val LABEL_PLUS_REP = "+1 rep"
        const val LABEL_SKIP_REST = "Skip rest"

        /**
         * An explicit, immutable broadcast for one lock-screen action at one journal rev. The rev
         * and set id are in the data URI as well as the extras, so every rev gets its own
         * PendingIntent: a tap on a notification that has since been refreshed still carries its
         * old rev and is refused as stale (with FLAG_UPDATE_CURRENT on a shared intent, the old
         * button would fire the NEW rev and set id, logging the next set: a double tap = 2 sets).
         */
        fun lockIntent(context: Context, action: String, rev: Long, setId: String?): PendingIntent {
            val uri = Uri.Builder().scheme("gymsupreme").authority("lock").appendPath(action.substringAfterLast('.'))
                .appendQueryParameter("rev", rev.toString()).appendQueryParameter("set", setId ?: "").build()
            val i = Intent(context, WorkoutActionReceiver::class.java).setAction(action).setData(uri)
                .putExtra(WorkoutActionReceiver.EXTRA_REV, rev)
                .putExtra(WorkoutActionReceiver.EXTRA_SET_ID, setId)
            return PendingIntent.getBroadcast(context, action.hashCode(), i, PendingIntent.FLAG_IMMUTABLE)
        }
    }
}
