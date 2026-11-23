package app.gymsupreme.workout

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Rest-end and EMOM cue (plan 6.2, Q8): a buzz plus a short tone heard over music, with brief
 * transient focus that asks music to duck. Route depends on what is plugged in, checked per cue:
 * - No headphones: alarm stream, so it plays under battery saver and Do Not Disturb (alarms
 *   allowed) and is not muted by media volume.
 * - Headphones (wired, USB, Bluetooth A2DP/LE, hearing aid): media stream at media volume. Android
 *   routes alarm audio to the speaker AND the headset (audio policy STRATEGY_SONIFICATION), which
 *   would beep out loud in the gym ~20 times a session; media goes to the headset only. Media
 *   volume 0 means no tone (logged); the buzz still fires. DND set to block media (or Total
 *   Silence) also mutes it; the buzz still fires. Played at [HEADSET_TONE_VOLUME], not full scale,
 *   since a 0 dBFS sine in the ears is much louder than music at the same volume. Known risk, not
 *   handled: an idle Bluetooth link can take a few hundred ms to wake and clip the short beep
 *   (TONE_PROP_BEEP2 has a fixed length, so a longer duration does not help). Device check. The
 * vibration is tagged as an alarm so Android 13+ does not drop it while the screen is off.
 * [fire] returns how each part went ("ok", "skipped:<why>" or "error:<what>"); the spike logs
 * both. Runs on the service's cue thread; focus is given back on that thread after the tone.
 */
class Alerter(context: Context, private val handler: Handler) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var tone: ToneGenerator? = null
    private var toneStream = -1
    private var focus: AudioFocusRequest? = null

    data class Result(val audio: String, val audioMethod: String, val vibrate: String, val focus: String)

    fun fire(long: Boolean): Result {
        val v = vibrate(if (long) longArrayOf(0, 400, 150, 400) else longArrayOf(0, 300))
        val headset = headsetType()
        val ms = if (long) TONE_LONG_MS else TONE_MS
        if (headset != null && audio.getStreamVolume(AudioManager.STREAM_MUSIC) == 0) {
            return Result("skipped:media_volume_0", "$METHOD_HEADSET:$headset", v, "none")
        }
        val stream = if (headset != null) AudioManager.STREAM_MUSIC else AudioManager.STREAM_ALARM
        val f = requestFocus(if (headset != null) HEADSET_ATTRS else ALARM_ATTRS)
        val a = playTone(stream, ms)
        handler.postDelayed({ abandonFocus() }, ms + 250L)
        val method = if (headset != null) "$METHOD_HEADSET:$headset" else METHOD
        return Result(a, method, v, f)
    }

    /** The connected headphone-like output, or null for the phone speaker. */
    private fun headsetType(): String? {
        val outs = try {
            audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        } catch (_: RuntimeException) {
            return null
        }
        for (d in outs) {
            val name = when (d.type) {
                AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
                AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
                AudioDeviceInfo.TYPE_USB_DEVICE -> "usb_device"
                AudioDeviceInfo.TYPE_LINE_ANALOG -> "line_analog"
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bt_a2dp"
                AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
                TYPE_BLE_HEADSET -> "ble_headset"
                else -> null
            }
            if (name != null) return name
        }
        return null
    }

    private fun playTone(stream: Int, ms: Int): String {
        if (tone != null && toneStream != stream) {
            try {
                tone?.release()
            } catch (_: RuntimeException) {
            }
            tone = null
        }
        val t = tone ?: try {
            ToneGenerator(stream, if (stream == AudioManager.STREAM_MUSIC) HEADSET_TONE_VOLUME else ToneGenerator.MAX_VOLUME).also {
                tone = it
                toneStream = stream
            }
        } catch (e: RuntimeException) {
            // No audio device (CI emulators run -noaudio) or the audio service refused.
            return "error:tonegen_init:${e.javaClass.simpleName}"
        }
        return try {
            if (t.startTone(ToneGenerator.TONE_PROP_BEEP2, ms)) "ok" else "error:startTone_false"
        } catch (e: RuntimeException) {
            "error:startTone:${e.javaClass.simpleName}"
        }
    }

    private fun requestFocus(attrs: AudioAttributes): String {
        if (focus != null) return "held"
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(attrs)
            .setWillPauseWhenDucked(false)
            .build()
        return try {
            val r = audio.requestAudioFocus(req)
            if (r != AudioManager.AUDIOFOCUS_REQUEST_FAILED) focus = req
            when (r) {
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> "granted"
                AudioManager.AUDIOFOCUS_REQUEST_DELAYED -> "delayed"
                else -> "failed"
            }
        } catch (e: RuntimeException) {
            "error:${e.javaClass.simpleName}"
        }
    }

    private fun abandonFocus() {
        focus?.let {
            try {
                audio.abandonAudioFocusRequest(it)
            } catch (_: RuntimeException) {
            }
        }
        focus = null
    }

    private fun vibrate(pattern: LongArray): String {
        val v: Vibrator = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
        } catch (e: RuntimeException) {
            return "error:${e.javaClass.simpleName}"
        }
        if (!v.hasVibrator()) return "skipped:no_vibrator"
        val effect = VibrationEffect.createWaveform(pattern, -1)
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM))
                "ok:usage_alarm"
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(effect, ALARM_ATTRS)
                "ok:audio_attrs_alarm"
            }
        } catch (e: RuntimeException) {
            "error:${e.javaClass.simpleName}"
        }
    }

    fun release() {
        abandonFocus()
        try {
            tone?.release()
        } catch (_: RuntimeException) {
        }
        tone = null
    }

    companion object {
        const val METHOD = "tonegen:stream_alarm+focus:transient_may_duck"
        const val METHOD_HEADSET = "tonegen:stream_music+focus:transient_may_duck"

        /** ToneGenerator volume on the headset path (log scale, ~0.5 dB a step: 80 is about -10 dB). */
        const val HEADSET_TONE_VOLUME = 80

        /** AudioDeviceInfo.TYPE_BLE_HEADSET (API 31); a literal so minSdk 29 lint stays quiet. */
        private const val TYPE_BLE_HEADSET = 26
        private const val TONE_MS = 400
        private const val TONE_LONG_MS = 700
        private val ALARM_ATTRS: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
        private val HEADSET_ATTRS: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
    }
}
