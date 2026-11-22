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
 * Serves exactly one file, the shared spike log, read-only to the app the user picks in the
 * share sheet (non-exported, per-URI grant). A tiny stand-in for androidx FileProvider so the
 * spike adds no dependency. Authority `<applicationId>.spikelog`.
 */
class SpikeLogProvider : ContentProvider() {
    override fun onCreate() = true

    private fun file(uri: Uri): File {
        val ctx = context ?: throw FileNotFoundException("no context")
        if (uri.lastPathSegment != SpikeExport.NAME) throw FileNotFoundException(uri.toString())
        return File(SpikeLog.dir(ctx), SpikeExport.NAME)
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read only")
        val f = file(uri)
        if (!f.exists()) throw FileNotFoundException(f.name)
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "text/plain"

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = file(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val c = MatrixCursor(cols, 1)
        c.addRow(
            cols.map {
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
        fun uri(packageName: String): Uri = Uri.parse("content://$packageName.spikelog/${SpikeExport.NAME}")
    }
}
