package app.gymsupreme.workout

import android.os.SystemClock
import app.gymsupreme.core.ble.HrReading
import java.io.File
import java.io.FileOutputStream

/**
 * R2: heart rate never goes in the journal. The service appends `{"t_ms":wall,"e_ms":elapsed,"bpm":n}`
 * per reading to its own file and fsyncs at most every [SYNC_MS]; a torn last line is skipped on
 * read. One file per workout in the spike (`spike/hr-<start wall ms>.jsonl`). Main thread only.
 */
class HrFile(val file: File) {
    private var out: FileOutputStream? = null
    private var lastSync = 0L
    var count = 0
        private set

    fun append(r: HrReading, wallMs: Long) {
        val o = out ?: try {
            FileOutputStream(file, true).also { out = it }
        } catch (_: Exception) {
            return
        }
        try {
            o.write("{\"t_ms\":$wallMs,\"e_ms\":${r.t},\"bpm\":${r.bpm}}\n".toByteArray(Charsets.US_ASCII))
            count++
            val now = SystemClock.elapsedRealtime()
            if (now - lastSync >= SYNC_MS) {
                o.fd.sync()
                lastSync = now
            }
        } catch (_: Exception) {
        }
    }

    fun close() {
        try {
            out?.fd?.sync()
            out?.close()
        } catch (_: Exception) {
        }
        out = null
    }

    companion object {
        const val SYNC_MS = 10_000L
        private val LINE = Regex("""^\{"t_ms":(-?\d+),"e_ms":(-?\d+),"bpm":(\d+)}$""")

        /** Readings on the elapsed-realtime clock; unparseable (torn) lines are skipped. */
        fun read(file: File): List<HrReading> = try {
            file.readLines().mapNotNull { line ->
                LINE.matchEntire(line.trim())?.let { m -> HrReading(m.groupValues[2].toLong(), m.groupValues[3].toInt()) }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }
}
