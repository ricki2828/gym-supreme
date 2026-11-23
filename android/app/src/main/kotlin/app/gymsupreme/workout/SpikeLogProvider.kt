package app.gymsupreme.workout

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Serves the shared spike log and the export files (`files/export/<name>`), read-only, to the app
 * the user picks in the share sheet (non-exported, per-URI grant). A tiny stand-in for androidx
 * FileProvider so nothing is added to the build. Authority `<applicationId>.spikelog`.
 */
class SpikeLogProvider : ContentProvider() {
    override fun onCreate() = true

    private fun file(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException("no context")
        val seg = uri.pathSegments
        return when {
            seg.size == 1 && seg[0] == SpikeExport.NAME -> File(SpikeLog.dir(ctx), SpikeExport.NAME)
            seg.size == 2 && seg[0] == EXPORT_DIR && ExportShare.validName(seg[1]) -> File(File(ctx.filesDir, EXPORT_DIR), seg[1])
            else -> throw FileNotFoundException(uri.toString())
        }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        val f = file(uri)
        if (!f.exists()) throw FileNotFoundException(f.name)
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = ExportShare.mimeFor(uri.lastPathSegment ?: "")

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = file(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val c = MatrixCursor(cols, 1)
        c.addRow(
            cols.map<String, Any?> {
                when (it) {
                    OpenableColumns.DISPLAY_NAME -> f.name
                    OpenableColumns.SIZE -> f.length()
                    else -> null
                }
            }.toTypedArray(),
        )
        return c
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0

    companion object {
        const val EXPORT_DIR = "export"

        fun uri(packageName: String): Uri = Uri.parse("content://$packageName.spikelog/${SpikeExport.NAME}")

        fun exportUri(packageName: String, name: String): Uri = Uri.parse("content://$packageName.spikelog/$EXPORT_DIR/$name")
    }
}
