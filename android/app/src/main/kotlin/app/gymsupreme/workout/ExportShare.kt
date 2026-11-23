package app.gymsupreme.workout

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import java.io.File

/**
 * WorkoutApi.shareFile (plan 7 B6 export): Dart hands over the file's name, type and content;
 * Kotlin writes `files/export/<fileName>` (atomically) and opens the share sheet with a read-only
 * grant through [SpikeLogProvider]. Dart never needs a filesystem path.
 */
object ExportShare {
    private val NAME = Regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")

    fun validName(name: String): Boolean = NAME.matches(name) && !name.contains("..")

    fun mimeFor(name: String): String = when {
        name.endsWith(".json") -> "application/json"
        name.endsWith(".csv") -> "text/csv"
        else -> "text/plain"
    }

    /** Throws [LiveSession.Refused] `bad_file_name` for anything but a plain file name. */
    fun share(activity: Activity, fileName: String, mimeType: String, content: String) {
        if (!validName(fileName)) throw LiveSession.Refused("bad_file_name", "file name must be letters, digits, dot, dash or underscore")
        val dir = File(activity.filesDir, SpikeLogProvider.EXPORT_DIR).also { it.mkdirs() }
        val tmp = File(dir, "$fileName.tmp")
        tmp.writeText(content, Charsets.UTF_8)
        val out = File(dir, fileName)
        if (!tmp.renameTo(out)) {
            out.delete()
            if (!tmp.renameTo(out)) throw LiveSession.Refused("write_failed", "could not write $fileName")
        }
        val uri = SpikeLogProvider.exportUri(activity.packageName, fileName)
        val send = Intent(Intent.ACTION_SEND)
            .setType(mimeType)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(fileName, uri)
        activity.startActivity(Intent.createChooser(send, "Share $fileName").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        SpikeLog.write(activity, SpikeLog.line("export_shared").put("file", fileName).put("bytes", out.length()).put("mime", mimeType))
    }
}
