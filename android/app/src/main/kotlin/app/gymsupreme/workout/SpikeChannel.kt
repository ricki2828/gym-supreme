package app.gymsupreme.workout

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import app.gymsupreme.ble.BleHrClient
import app.gymsupreme.ble.HrHolder
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The spike screen's channel (agreed with lane A: a plain MethodChannel confined to the spike;
 * anything that outlives it moves to Pigeon in phase 1). Main thread.
 */
class SpikeChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, NAME).also { it.setMethodCallHandler(this) }
    private val hr: BleHrClient get() = HrHolder.get(activity)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "requestPermissions" -> {
                    requestPermissions()
                    result.success(null)
                }
                "startAll" -> {
                    SpikeLog.write(activity, SpikeLog.line("start_all_tapped").put("strap_linked", hr.savedAddress != null))
                    WorkoutService.start(activity, WorkoutService.ACTION_START_SPIKE)
                    result.success(null)
                }
                "stop" -> {
                    WorkoutService.instance?.stopWorkout("app")
                    result.success(null)
                }
                "scan" -> hr.scan { r ->
                    r.fold(
                        { list -> result.success(list.map { mapOf("address" to it.address, "name" to it.name) }) },
                        { e -> result.error("scan_failed", e.message ?: e.javaClass.simpleName, null) },
                    )
                }
                "pair" -> {
                    val a = call.argument<String>("address") ?: return result.error("bad_args", "address", null)
                    hr.pair(a)
                    SpikeLog.write(activity, SpikeLog.line("strap_paired").put("name", hr.deviceName))
                    result.success(null)
                }
                "forget" -> {
                    hr.forget()
                    SpikeLog.write(activity, SpikeLog.line("strap_forgotten"))
                    result.success(null)
                }
                "screenWants" -> {
                    hr.screenWants()
                    result.success(null)
                }
                "screenReleases" -> {
                    hr.screenReleases()
                    result.success(null)
                }
                "share" -> {
                    share()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("spike_error", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    private fun status(): Map<String, Any?> {
        val s = WorkoutService.status
        val pm = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        val nm = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val c = hr
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "release" to Build.VERSION.RELEASE,
            "model" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "versionCode" to activity.packageManager.getPackageInfo(activity.packageName, 0).longVersionCode,
            "notificationsOn" to nm.areNotificationsEnabled(),
            "batterySaver" to pm.isPowerSaveMode,
            "hrSupported" to BleHrClient.supported,
            "btPermissions" to c.hasPermissions(),
            "btOn" to c.adapterOn,
            "strapName" to c.deviceName,
            "strapLinked" to (c.savedAddress != null),
            "strapConnected" to c.connected,
            "hr" to c.lastHr,
            "running" to s.running,
            "mode" to s.mode,
            "title" to s.title,
            "fired" to s.fired,
            "total" to s.total,
            "lastCue" to s.lastCue,
            "lastLateMs" to s.lastLateMs,
            "serviceType" to s.serviceType,
            "hrCount" to s.hrCount,
            "elapsedS" to if (s.running) (SystemClock.elapsedRealtime() - s.t0) / 1000 else null,
            "logLines" to SpikeLog.lineCount(activity),
            "tail" to SpikeLog.tail(activity, 6),
        )
    }

    private fun requestPermissions() {
        val want = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 33) want.add(Manifest.permission.POST_NOTIFICATIONS)
        if (Build.VERSION.SDK_INT >= 31) {
            want.add(Manifest.permission.BLUETOOTH_SCAN)
            want.add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        val missing = want.filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) activity.requestPermissions(missing.toTypedArray(), REQUEST_CODE)
    }

    private fun share() {
        SpikeExport.build(activity)
        val uri = SpikeLogProvider.uri(activity.packageName)
        val send = Intent(Intent.ACTION_SEND)
            .setType("text/plain")
            .putExtra(Intent.EXTRA_STREAM, uri)
            .putExtra(Intent.EXTRA_SUBJECT, "Gym Supreme spike log")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = android.content.ClipData.newRawUri(SpikeExport.NAME, uri)
        activity.startActivity(Intent.createChooser(send, "Share spike log").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    fun dispose() = channel.setMethodCallHandler(null)

    companion object {
        const val NAME = "app.gymsupreme/spike"
        private const val REQUEST_CODE = 7301
    }
}
