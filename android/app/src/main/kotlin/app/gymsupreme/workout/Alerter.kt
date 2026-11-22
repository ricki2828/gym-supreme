package app.gymsupreme.workout

import android.content.Context
import android.media.AudioAttributes
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
 * Rest-end and EMOM cue (plan 6.2, Q8): a buzz plus a short tone heard over music. The tone goes
 * on the alarm stream with brief transient focus that asks music to duck, so it plays under
 * battery saver and Do Not Disturb (alarms allowed) and is not muted by media volume. The
 * vibration is tagged as an alarm so Android 13+ does not drop it while the screen is off.
 * [fire] returns how each part went ("ok", "skipped:<why>" or "error:<what>"); the spike logs
 * both. Runs on the service's cue thread; focus is given back on that thread after the tone.
 */
class Alerter(context: Context, private val handler: Handler) {
    private val context = context.applicationContext
    private val audio = this.context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var tone: ToneGenerator? = null
    private var focus: AudioFocusRequest? = null

    data class Result(val audio: String, val audioMethod: String, val vibrate: String, val focus: String)

    fun fire(long: Boolean): Result {
        val v = vibrate(if (long) longArrayOf(0, 400, 150, 400) else longArrayOf(0, 300))
        val f = requestFocus()
        val a = playTone(if (long) TONE_LONG_MS else TONE_MS)
        val release = if (long) TONE_LONG_MS else TONE_MS
        handler.postDelayed({ abandonFocus() }, release + 250L)
        return Result(a, METHOD, v, f)
    }

    private fun playTone(ms: Int): String {
        val t = tone ?: try {
            ToneGenerator(AudioManager.STREAM_ALARM, ToneGenerator.MAX_VOLUME).also { tone = it }
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

    private fun requestFocus(): String {
        if (focus != null) return "held"
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(ALARM_ATTRS)
            .setWillPauseWhenDucked(false)
            .build()
        return try {
            val r = audio.requestAudioFocus(req)
            focus = req
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
        private const val TONE_MS = 400
        private const val TONE_LONG_MS = 700
        private val ALARM_ATTRS: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ALARM)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()
    }
}
