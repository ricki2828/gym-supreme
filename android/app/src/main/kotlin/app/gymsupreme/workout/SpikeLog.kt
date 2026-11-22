package app.gymsupreme.workout

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.util.Log
import app.gymsupreme.core.log.LogLine
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * The spike's evidence (brief section 5): one JSON line per event in `files/spike/spike-log.jsonl`,
 * append-only and never rotated, so a second build installed over the first finds build 1's lines
 * (S4). Every line carries wall time, elapsed-realtime and the build's versionCode; cue lines add
 * the scheduled and fired times, the audio method, the service type and the device state.
 * Each line is also logged under [TAG] for the CI emulator smoke. Thread-safe; a write failure
 * is logged and ignored (the log never breaks the workout).
 */
object SpikeLog {
    const val TAG = "GymSupreme/service"
    private const val DIR = "spike"
    private const val FILE = "spike-log.jsonl"
    private val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)
    private var versionCode: Long = -1
    private var headerWritten = false

    fun dir(context: Context): File = File(context.applicationContext.filesDir, DIR).also { it.mkdirs() }

    fun file(context: Context): File = File(dir(context), FILE)

    /** Event line with the common fields; callers add their own with [LogLine.put]. */
    fun line(event: String): LogLine {
        val wall = System.currentTimeMillis()
        return LogLine(event)
            .put("wall", synchronized(fmt) { fmt.format(Date(wall)) })
            .put("wall_ms", wall)
            .put("elapsed_ms", SystemClock.elapsedRealtime())
            .put("vc", versionCode)
    }

    @Synchronized
    fun write(context: Context, line: LogLine) {
        val ctx = context.applicationContext
        if (!headerWritten) {
            headerWritten = true
            versionCode = try {
                ctx.packageManager.getPackageInfo(ctx.packageName, 0).longVersionCode
            } catch (_: Exception) {
                -1
            }
            // One header per process start: S4 reads build 1's header above build 2's.
            append(
                ctx,
                line("process_start")
                    .put("package", ctx.packageName)
                    .put("sdk", Build.VERSION.SDK_INT)
                    .put("release", Build.VERSION.RELEASE)
                    .put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
                    .put("fingerprint", Build.FINGERPRINT)
                    .encode(),
            )
        }
        append(ctx, line.put("vc", versionCode).encode())
    }

    private fun append(ctx: Context, s: String) {
        Log.i(TAG, s)
        try {
            FileOutputStream(file(ctx), true).use { out ->
                out.write((s + "\n").toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
        } catch (e: Exception) {
            Log.w(TAG, "spike log write failed: $e")
        }
    }

    fun lineCount(context: Context): Int = try {
        file(context).takeIf { it.exists() }?.useLines { it.count() } ?: 0
    } catch (_: Exception) {
        0
    }

    /** The newest [n] lines, for the spike screen. */
    fun tail(context: Context, n: Int): List<String> = try {
        file(context).takeIf { it.exists() }?.readLines()?.takeLast(n) ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }
}
