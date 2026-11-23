package app.gymsupreme.workout

import android.content.Context
import app.gymsupreme.core.journal.Journal
import java.io.File
import java.io.FileOutputStream

/**
 * The journal file (plan 7): `files/journal/workout.jsonl`, one snapshot per line, written only
 * here. Each append is fsynced before the call returns, so an accepted submit survives a crash.
 * Android Auto Backup does not cover it (plan B6). Main thread.
 */
class JournalStore(context: Context) {
    private val dir = File(context.applicationContext.filesDir, DIR).also { it.mkdirs() }
    val file = File(dir, FILE)

    fun append(line: String) {
        FileOutputStream(file, true).use { out ->
            out.write((line + "\n").toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
    }

    fun read(): Journal.Read = if (file.exists()) Journal.read(file.readText(Charsets.UTF_8)) else Journal.read("")

    /** Delete only if the journal still belongs to [uuid] (Dart has stored that workout). */
    fun deleteIf(uuid: String): Boolean {
        val last = read().last
        if (last != null && last.uuid != uuid) return false
        return !file.exists() || file.delete()
    }

    /** Move an unreadable journal aside (kept for the log, counted as lost). */
    fun quarantine(): String? {
        if (!file.exists()) return null
        val aside = File(dir, "corrupt-${System.currentTimeMillis()}.jsonl")
        return if (file.renameTo(aside)) aside.name else null
    }

    companion object {
        const val DIR = "journal"
        const val FILE = "workout.jsonl"
    }
}
