package app.gymsupreme.health

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.ExerciseSessionRecord
import app.gymsupreme.platform.FlutterError
import app.gymsupreme.platform.HealthApi
import app.gymsupreme.platform.HealthAvailability
import app.gymsupreme.platform.HealthOutcome
import app.gymsupreme.platform.HealthResult
import app.gymsupreme.platform.HealthSession
import app.gymsupreme.platform.HealthStatus
import app.gymsupreme.workout.Features
import app.gymsupreme.workout.SelfCheckLog
import app.gymsupreme.workout.SpikeLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Shows Health Connect's permission screen; answers the permissions granted afterwards, or null if one is already open. */
fun interface HealthPrompter {
    fun request(permissions: Set<String>, callback: (Set<String>?) -> Unit)
}

/**
 * Writes finished workouts to Health Connect (0.3 H1, flag `health`, dogfood flavour only: the
 * permission is merged from `src/health/AndroidManifest.xml` only when the build has the flag).
 * Write only: no read permission is declared or asked. The permission is asked only from his tap
 * on the Diagnostics switch, never from the background. His switch lives in this app's own
 * preferences (not in Auto Backup, which copies only the snapshot database). A Health Connect
 * problem never throws to Dart: it comes back as a [HealthOutcome] and a `GymSupreme/service` line.
 */
class HealthApiImpl(
    private val context: Context,
    private val prompter: HealthPrompter,
) : HealthApi {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    /** Writes and deletes run one at a time, in call order: a fast delete + UNDO lands in that order. */
    private val io = Mutex()

    private val prefs get() = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, false)
        set(v) {
            prefs.edit().putBoolean(KEY_ENABLED, v).commit()
        }

    /** True when this APK's merged manifest asks for WRITE_EXERCISE. */
    private fun declared(): Boolean = try {
        @Suppress("DEPRECATION")
        val info = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS)
        info.requestedPermissions?.contains(WRITE_EXERCISE) == true
    } catch (_: Exception) {
        false
    }

    private fun availability(): HealthAvailability {
        if (!Features.health) return HealthAvailability.FLAG_OFF
        if (!declared()) return HealthAvailability.NOT_DECLARED
        return try {
            when (HealthConnectClient.getSdkStatus(context)) {
                HealthConnectClient.SDK_AVAILABLE -> HealthAvailability.AVAILABLE
                HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> HealthAvailability.NEEDS_UPDATE
                // Android 14+ has it built in: unavailable there means this phone does not support it.
                else -> if (Build.VERSION.SDK_INT >= 34) HealthAvailability.UNSUPPORTED else HealthAvailability.NOT_INSTALLED
            }
        } catch (_: Exception) {
            HealthAvailability.UNSUPPORTED
        }
    }

    private suspend fun granted(): Boolean = try {
        WRITE_EXERCISE in HealthConnectClient.getOrCreate(context).permissionController.getGrantedPermissions()
    } catch (_: Exception) {
        false
    }

    private suspend fun currentStatus(): HealthStatus {
        val a = availability()
        val g = a == HealthAvailability.AVAILABLE && granted()
        return HealthStatus(a, g, enabled)
    }

    private fun logStatus(event: String, s: HealthStatus, extra: Map<String, Any?> = emptyMap()) {
        val l = SpikeLog.line(event).put("availability", s.availability.name.lowercase())
            .put("granted", s.granted).put("enabled", s.enabled)
        for ((k, v) in extra) l.put(k, v)
        SpikeLog.write(context, l)
    }

    override fun status(callback: (Result<HealthStatus>) -> Unit) {
        scope.launch {
            val s = currentStatus()
            logStatus("health_status", s)
            callback(Result.success(s))
        }
    }

    override fun setEnabled(enabled: Boolean, callback: (Result<HealthStatus>) -> Unit) {
        scope.launch {
            if (!enabled) {
                this@HealthApiImpl.enabled = false
                val s = currentStatus()
                logStatus("health_permission", s, mapOf("asked" to false, "on" to false))
                callback(Result.success(s))
                return@launch
            }
            if (availability() != HealthAvailability.AVAILABLE) {
                val s = currentStatus()
                logStatus("health_permission", s, mapOf("asked" to false, "on" to true))
                callback(Result.success(s))
                return@launch
            }
            if (granted()) {
                this@HealthApiImpl.enabled = true
                val s = currentStatus()
                logStatus("health_permission", s, mapOf("asked" to false, "on" to true))
                callback(Result.success(s))
                return@launch
            }
            SpikeLog.write(context, SpikeLog.line("health_permission_shown"))
            prompter.request(setOf(WRITE_EXERCISE)) { got ->
                if (got == null) {
                    callback(Result.failure(FlutterError("already_pending", "a Health Connect permission screen is open", null)))
                    return@request
                }
                scope.launch {
                    // Ask Health Connect, not the result intent: BACK after an outside grant reports nothing.
                    val ok = WRITE_EXERCISE in got || granted()
                    if (ok) this@HealthApiImpl.enabled = true
                    val s = currentStatus()
                    logStatus("health_permission", s, mapOf("asked" to true, "on" to true))
                    callback(Result.success(s))
                }
            }
        }
    }

    /** The gate every write and delete passes; null = go. */
    private suspend fun refusal(): HealthOutcome? {
        val a = availability()
        return when {
            a == HealthAvailability.FLAG_OFF -> HealthOutcome.DISABLED
            a != HealthAvailability.AVAILABLE -> HealthOutcome.NOT_AVAILABLE
            !enabled -> HealthOutcome.DISABLED
            !granted() -> HealthOutcome.PERMISSION_DENIED
            else -> null
        }
    }

    private fun reply(
        event: String,
        callback: (Result<HealthResult>) -> Unit,
        outcome: HealthOutcome,
        count: Int,
        asked: Int,
        detail: String? = null,
    ) {
        val l = SpikeLog.line(event).put("outcome", outcome.name.lowercase()).put("count", count).put("asked", asked)
        if (detail != null) l.put("detail", detail)
        SpikeLog.write(context, l)
        SelfCheckLog.health(context, event == "health_delete", outcome.name, count)
        callback(Result.success(HealthResult(outcome, count.toLong(), detail)))
    }

    override fun writeSessions(sessions: List<HealthSession>, callback: (Result<HealthResult>) -> Unit) {
        scope.launch { io.withLock { write(sessions, callback) } }
    }

    private suspend fun write(sessions: List<HealthSession>, callback: (Result<HealthResult>) -> Unit) {
        run {
            refusal()?.let {
                reply("health_write", callback, it, 0, sessions.size)
                return
            }
            var n = 0
            try {
                val client = HealthConnectClient.getOrCreate(context)
                for (batch in sessions.chunked(BATCH)) {
                    client.insertRecords(batch.map { HealthRecords.toRecord(it) })
                    n += batch.size
                }
                reply("health_write", callback, HealthOutcome.OK, n, sessions.size)
            } catch (e: SecurityException) {
                reply("health_write", callback, HealthOutcome.PERMISSION_DENIED, n, sessions.size)
            } catch (e: Exception) {
                reply("health_write", callback, HealthOutcome.FAILED, n, sessions.size, "${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    override fun deleteSessions(clientRecordIds: List<String>, callback: (Result<HealthResult>) -> Unit) {
        scope.launch { io.withLock { delete(clientRecordIds, callback) } }
    }

    private suspend fun delete(clientRecordIds: List<String>, callback: (Result<HealthResult>) -> Unit) {
        run {
            refusal()?.let {
                reply("health_delete", callback, it, 0, clientRecordIds.size)
                return
            }
            var n = 0
            try {
                val client = HealthConnectClient.getOrCreate(context)
                for (batch in clientRecordIds.chunked(BATCH)) {
                    client.deleteRecords(ExerciseSessionRecord::class, recordIdsList = emptyList(), clientRecordIdsList = batch)
                    n += batch.size
                }
                reply("health_delete", callback, HealthOutcome.OK, n, clientRecordIds.size)
            } catch (e: SecurityException) {
                reply("health_delete", callback, HealthOutcome.PERMISSION_DENIED, n, clientRecordIds.size)
            } catch (e: Exception) {
                reply("health_delete", callback, HealthOutcome.FAILED, n, clientRecordIds.size, "${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    companion object {
        const val WRITE_EXERCISE = "android.permission.health.WRITE_EXERCISE"
        private const val PREFS = "gym_health"
        private const val KEY_ENABLED = "enabled"

        /** Records per insert / delete call (Health Connect caps a call at 1000 records). */
        const val BATCH = 100
    }
}
