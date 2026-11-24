package app.gymsupreme.workout

import android.content.Context
import app.gymsupreme.core.timer.FiredLog
import app.gymsupreme.core.timer.FiredStore
import java.io.File
import java.io.FileOutputStream

/**
 * The durable [FiredStore] (0.3 cut T1): `files/journal/fired.txt` ([FiredLog] format), one
 * workout at a time. Every [add] is fsynced before it returns, so the service buzzes only after
 * the record survives a crash; pause (which stops the service), process death and reboot keep it.
 * The journal directory is outside Auto Backup. Cleared when Dart deletes the journal. Thread-safe.
 */
class FiredFileStore private constructor(context: Context) : FiredStore {
    private val file = File(File(context.applicationContext.filesDir, JournalStore.DIR).also { it.mkdirs() }, FILE)
    private var uuid: String? = null
    private val keys = LinkedHashSet<String>()

    /** Load the keys of [workoutUuid]; a file for any other workout is replaced. */
    @Synchronized
    fun bind(workoutUuid: String) {
        if (uuid == workoutUuid) return
        uuid = workoutUuid
        keys.clear()
        val got = FiredLog.parse(readText(), workoutUuid)
        if (got != null) keys.addAll(got) else rewrite()
    }

    @Synchronized
    override fun contains(key: String): Boolean = key in keys

    @Synchronized
    override fun add(key: String) {
        if (!keys.add(key)) return
        if (uuid == null) return
        FileOutputStream(file, true).use { out ->
            out.write(FiredLog.line(key).toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
    }

    @Synchronized
    override fun removeIf(p: (String) -> Boolean) {
        if (keys.removeAll(p)) rewrite()
    }

    /** The journal of [workoutUuid] is gone: so is its record. */
    @Synchronized
    fun clear(workoutUuid: String) {
        if (uuid == workoutUuid) {
            uuid = null
            keys.clear()
        }
        val text = readText()
        if (text.isEmpty() || FiredLog.parse(text, workoutUuid) != null) file.delete()
    }

    @Synchronized
    fun size(): Int = keys.size

    private fun readText(): String = try {
        if (file.exists()) file.readText(Charsets.UTF_8) else ""
    } catch (_: Exception) {
        ""
    }

    private fun rewrite() {
        val u = uuid ?: return
        val tmp = File(file.path + ".tmp")
        FileOutputStream(tmp).use { out ->
            out.write(FiredLog.encode(u, keys).toByteArray(Charsets.UTF_8))
            out.fd.sync()
        }
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    }

    companion object {
        const val FILE = "fired.txt"

        @Volatile
        private var instance: FiredFileStore? = null

        fun get(context: Context): FiredFileStore =
            instance ?: synchronized(this) { instance ?: FiredFileStore(context).also { instance = it } }
    }
}
