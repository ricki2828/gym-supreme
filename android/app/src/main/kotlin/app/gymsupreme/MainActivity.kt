package app.gymsupreme

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Log
import app.gymsupreme.platform.GymHostApi
import app.gymsupreme.platform.HostInfo
import app.gymsupreme.workout.SpikeChannel
import app.gymsupreme.workout.SpikeLog
import app.gymsupreme.workout.WorkoutService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    private var spike: SpikeChannel? = null
    private var selftestPending = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        InstallMarker.check(this)
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
    }

    private fun noteSelftest(i: Intent?) {
        if (i?.getBooleanExtra(EXTRA_SELFTEST, false) == true) {
            i.removeExtra(EXTRA_SELFTEST)
            selftestPending = true
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GymHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, HostApiImpl(this))
        spike = SpikeChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        spike?.dispose()
        spike = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    companion object {
        /** `am start -n <pkg>/app.gymsupreme.MainActivity --ez gym_selftest true` (tools/emulator_smoke.sh). */
        const val EXTRA_SELFTEST = "gym_selftest"
    }
}

private class HostApiImpl(private val activity: MainActivity) : GymHostApi {
    override fun getHostInfo(): HostInfo =
        HostInfo(
            sdkInt = Build.VERSION.SDK_INT.toLong(),
            model = "${Build.MANUFACTURER} ${Build.MODEL}",
            versionCode = activity.packageManager.getPackageInfo(activity.packageName, 0).longVersionCode,
        )
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
