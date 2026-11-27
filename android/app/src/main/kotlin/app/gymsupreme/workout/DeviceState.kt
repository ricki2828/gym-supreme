package app.gymsupreme.workout

import android.app.NotificationManager
import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import app.gymsupreme.core.log.LogLine

/**
 * What the phone was doing when a cue fired, so "I didn't hear it" can be explained from the log:
 * battery saver, doze, screen, music, alarm volume, ringer, Do Not Disturb and audio outputs.
 */
object DeviceState {
    fun addTo(context: Context, l: LogLine): LogLine {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        return l.put("battery_saver", pm.isPowerSaveMode)
            .put("doze", pm.isDeviceIdleMode)
            .put("screen_on", pm.isInteractive)
            .put("music_active", am.isMusicActive)
            .put("alarm_vol", am.getStreamVolume(AudioManager.STREAM_ALARM))
            .put("alarm_vol_max", am.getStreamMaxVolume(AudioManager.STREAM_ALARM))
            .put("music_vol", am.getStreamVolume(AudioManager.STREAM_MUSIC))
            .put("ringer", ringer(am.ringerMode))
            .put("dnd", dnd(nm.currentInterruptionFilter))
            .put("outputs", outputs(am))
            .put("sdk", Build.VERSION.SDK_INT)
    }

    /** The few fields the self-checks keep per cue. [route]: 0 speaker, 1 wired, 2 bluetooth, 3 other. */
    data class Snap(val screenOn: Boolean, val batterySaver: Boolean, val doze: Boolean, val music: Boolean, val route: Int)

    fun snapshot(context: Context): Snap {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val types = try {
            am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { it.type }
        } catch (_: Exception) {
            emptyList()
        }
        val route = when {
            types.any { it == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP || it == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || it == 26 } -> 2
            types.any { it == AudioDeviceInfo.TYPE_WIRED_HEADPHONES || it == AudioDeviceInfo.TYPE_WIRED_HEADSET } -> 1
            types.any { it == AudioDeviceInfo.TYPE_USB_HEADSET || it == AudioDeviceInfo.TYPE_USB_DEVICE || it == 27 } -> 3
            else -> 0
        }
        return Snap(pm.isInteractive, pm.isPowerSaveMode, pm.isDeviceIdleMode, am.isMusicActive, route)
    }

    private fun ringer(m: Int) = when (m) {
        AudioManager.RINGER_MODE_SILENT -> "silent"
        AudioManager.RINGER_MODE_VIBRATE -> "vibrate"
        else -> "normal"
    }

    private fun dnd(f: Int) = when (f) {
        NotificationManager.INTERRUPTION_FILTER_ALL -> "off"
        NotificationManager.INTERRUPTION_FILTER_PRIORITY -> "priority"
        NotificationManager.INTERRUPTION_FILTER_ALARMS -> "alarms"
        NotificationManager.INTERRUPTION_FILTER_NONE -> "none"
        else -> "unknown"
    }

    private fun outputs(am: AudioManager): String = try {
        am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map { type(it.type) }.distinct().joinToString("+")
    } catch (_: Exception) {
        "?"
    }

    private fun type(t: Int) = when (t) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt_a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bt_sco"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired"
        AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE -> "usb"
        26 /* TYPE_BLE_HEADSET, API 31 */, 27 /* TYPE_BLE_SPEAKER */ -> "ble_audio"
        else -> "t$t"
    }
}
