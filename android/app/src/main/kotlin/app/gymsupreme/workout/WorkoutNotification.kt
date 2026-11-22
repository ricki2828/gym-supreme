package app.gymsupreme.workout

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
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

    data class Content(val title: String, val text: String, val nextCueWallMs: Long?)

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
            .addAction(Notification.Action.Builder(null, "Stop", action(WorkoutActionReceiver.ACTION_STOP)).build())
        if (c.nextCueWallMs != null) {
            b.setUsesChronometer(true).setChronometerCountDown(true).setWhen(c.nextCueWallMs).setShowWhen(true)
        } else {
            b.setShowWhen(false)
        }
        return b.build()
    }

    fun update(c: Content) = try {
        manager.notify(NOTIFICATION_ID, build(c))
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
        const val NOTIFICATION_ID = 2001
        const val CUE_ID = 2002
    }
}
