package app.gymsupreme

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.os.Bundle
import android.util.Log
import app.gymsupreme.platform.GymHostApi
import app.gymsupreme.platform.FlutterError
import app.gymsupreme.platform.HostInfo
import app.gymsupreme.platform.SnapshotsStreamHandler
import app.gymsupreme.platform.WorkoutApi
import app.gymsupreme.workout.Features
import app.gymsupreme.workout.SessionSelfTest
import app.gymsupreme.workout.SpikeChannel
import app.gymsupreme.workout.SnapshotsStream
import app.gymsupreme.workout.SpikeLog
import app.gymsupreme.workout.WorkoutApiImpl
import app.gymsupreme.workout.WorkoutService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var spike: SpikeChannel? = null
    private var snapshots: SnapshotsStream? = null
    private var selftestPending = false
    private var sessionStepPending: String? = null

    /** `gym_e2e` from the latest launch intent, until Dart takes it (CI e2e; dogfood/debug only). */
    private var launchCommand: String? = null

    fun takeLaunchCommand(): String? {
        val c = launchCommand
        launchCommand = null
        if (c != null) SpikeLog.write(this, SpikeLog.line("launch_command_taken").put("command", c))
        return c
    }

    /** The one in-flight requestNotificationPermission call (Dart awaits it). */
    private var notifCallback: ((Result<Boolean>) -> Unit)? = null

    fun notificationsEnabled(): Boolean =
        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).areNotificationsEnabled()

    fun requestNotificationPermission(callback: (Result<Boolean>) -> Unit) {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) {
            val on = notificationsEnabled()
            SpikeLog.write(this, SpikeLog.line("notif_request").put("result", on).put("asked", false))
            callback(Result.success(on))
            return
        }
        if (notifCallback != null) {
            callback(Result.failure(FlutterError("already_pending", "a notification permission request is open", null)))
            return
        }
        notifCallback = callback
        SpikeLog.write(this, SpikeLog.line("notif_request_shown"))
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIF_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIF_REQUEST_CODE) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        resolveNotif(granted && notificationsEnabled(), if (grantResults.isEmpty()) "cancelled" else null)
    }

    private fun resolveNotif(on: Boolean, why: String?) {
        val cb = notifCallback ?: return
        notifCallback = null
        val line = SpikeLog.line("notif_request").put("result", on).put("asked", true)
        if (why != null) line.put("why", why)
        SpikeLog.write(this, line)
        cb(Result.success(on))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        InstallMarker.check(this)
        Features.logStartup()
        // Not on a recreate (rotation): the intent that asked for the self-test is the same one.
        if (savedInstanceState == null) noteSelftest(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        noteSelftest(intent)
    }

    override fun onResume() {
        super.onResume()
        // S5 (CI emulators): the service starts only from the visible activity, so the
        // self-test waits for onResume.
        if (selftestPending) {
            selftestPending = false
            SpikeLog.write(this, SpikeLog.line("selftest_requested"))
            WorkoutService.start(this, WorkoutService.ACTION_SELFTEST)
        }
        sessionStepPending?.let {
            sessionStepPending = null
            SessionSelfTest.run(this, it)
        }
    }

    /** CI self-tests (S5 and the session path): dogfood and debug builds only, never play. */
    private fun noteSelftest(i: Intent?) {
        if (i == null || !SessionSelfTest.allowed(this)) return
        if (i.getBooleanExtra(EXTRA_SELFTEST, false)) {
            i.removeExtra(EXTRA_SELFTEST)
            selftestPending = true
        }
        i.getStringExtra(SessionSelfTest.EXTRA)?.let {
            i.removeExtra(SessionSelfTest.EXTRA)
            sessionStepPending = it
        }
        i.getStringExtra(EXTRA_E2E)?.let {
            i.removeExtra(EXTRA_E2E)
            launchCommand = it
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        GymHostApi.setUp(messenger, HostApiImpl(this))
        WorkoutApi.setUp(messenger, WorkoutApiImpl(this))
        snapshots = SnapshotsStream(this).also { SnapshotsStreamHandler.register(messenger, it) }
        spike = SpikeChannel(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        resolveNotif(false, "activity_gone")
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        GymHostApi.setUp(messenger, null)
        WorkoutApi.setUp(messenger, null)
        snapshots?.dispose()
        snapshots = null
        spike?.dispose()
        spike = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        /** `am start -n <pkg>/app.gymsupreme.MainActivity --ez gym_selftest true` (tools/emulator_smoke.sh). */
        const val EXTRA_SELFTEST = "gym_selftest"

        /** `am start ... --es gym_e2e run|start_only|resume`: read by Dart via GymHostApi.takeLaunchCommand. */
        const val EXTRA_E2E = "gym_e2e"

        /** Distinct from SpikeChannel's 7301. */
        private const val NOTIF_REQUEST_CODE = 7302
    }
}

private class HostApiImpl(private val activity: MainActivity) : GymHostApi {
    override fun getHostInfo(): HostInfo =
        HostInfo(
            sdkInt = Build.VERSION.SDK_INT.toLong(),
            model = "${Build.MANUFACTURER} ${Build.MODEL}",
            versionCode = activity.packageManager.getPackageInfo(activity.packageName, 0).longVersionCode,
            release = Build.VERSION.RELEASE ?: "",
            notificationsEnabled = activity.notificationsEnabled(),
            batterySaver = (activity.getSystemService(Context.POWER_SERVICE) as PowerManager).isPowerSaveMode,
        )

    override fun takeLaunchCommand(): String? = activity.takeLaunchCommand()

    override fun requestNotificationPermission(callback: (Result<Boolean>) -> Unit) =
        activity.requestNotificationPermission(callback)

    override fun openNotificationSettings() {
        val i = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        activity.startActivity(i)
    }
}

/**
 * Install-over evidence (phase-0 exit S4). The first launch of a fresh install writes
 * files/install_marker.txt ("<uuid> <versionCode>"); later launches keep it. CI installs build
 * N-1, launches, installs build N over it, launches again and checks the log line keeps the
 * same id with fresh=false. Release builds have no run-as, so the log is the evidence.
 */
internal object InstallMarker {
    private const val TAG = "GymSupreme/install"

    fun check(activity: MainActivity) {
        val now = activity.packageManager.getPackageInfo(activity.packageName, 0).longVersionCode
        val file = File(activity.filesDir, "install_marker.txt")
        var fresh = false
        val parts = file.takeIf { it.exists() }?.readText()?.trim()?.split(" ")
        val (id, first) =
            if (parts != null && parts.size == 2) {
                parts[0] to parts[1]
            } else {
                fresh = true
                val created = UUID.randomUUID().toString() to now.toString()
                val tmp = File(activity.filesDir, "install_marker.txt.tmp")
                tmp.writeText("${created.first} ${created.second}\n")
                if (!tmp.renameTo(file)) Log.w(TAG, "marker rename failed")
                created
            }
        Log.i(TAG, "install marker=$id firstVersion=$first thisVersion=$now fresh=$fresh")
    }
}
