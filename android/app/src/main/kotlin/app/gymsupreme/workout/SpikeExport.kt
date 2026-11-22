package app.gymsupreme.workout

import android.content.Context
import android.os.SystemClock
import app.gymsupreme.ble.BleTrail
import app.gymsupreme.core.ble.HrSummary
import java.io.File

/**
 * Builds the one file "Share log" sends (runbook card step 4): the spike log, an HR summary of a
 * workout still running, and the strap's link trail. Raw HR samples stay on the phone; their
 * per-minute counts and gaps are what S3 needs. Main thread.
 */
object SpikeExport {
    const val NAME = "gym-supreme-spike-log.txt"

    fun build(context: Context): File {
        val ctx = context.applicationContext
        val out = File(SpikeLog.dir(ctx), NAME)
        val s = WorkoutService.status
        val live = s.hrFile?.takeIf { s.running }?.let { File(SpikeLog.dir(ctx), it) }
        if (live != null && live.exists()) {
            SpikeLog.write(ctx, WorkoutService.hrSummaryLine(HrSummary.of(HrFile.read(live), s.t0, SystemClock.elapsedRealtime()), live.name).put("live", true))
        }
        SpikeLog.write(ctx, DeviceState.addTo(ctx, SpikeLog.line("share").put("running", s.running)))
        val tmp = File(out.path + ".tmp")
        tmp.bufferedWriter().use { w ->
            w.write("# Gym Supreme spike log. One JSON event per line, oldest first.\n")
            SpikeLog.file(ctx).takeIf { it.exists() }?.forEachLine { w.write(it); w.write("\n") }
            w.write("\n# Strap link trail (${BleTrail.FILE})\n")
            File(ctx.filesDir, BleTrail.FILE).takeIf { it.exists() }?.forEachLine { w.write(it); w.write("\n") }
        }
        tmp.renameTo(out)
        return out
    }
}
