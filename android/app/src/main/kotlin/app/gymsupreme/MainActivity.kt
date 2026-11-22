package app.gymsupreme

import android.os.Build
import android.os.Bundle
import android.util.Log
import app.gymsupreme.platform.GymHostApi
import app.gymsupreme.platform.HostInfo
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File
import java.util.UUID

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        InstallMarker.check(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        GymHostApi.setUp(flutterEngine.dartExecutor.binaryMessenger, HostApiImpl(this))
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
