package app.gymsupreme.workout

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import app.gymsupreme.ble.BleHrClient
import app.gymsupreme.ble.HrHolder
import app.gymsupreme.core.ble.HrReading
import app.gymsupreme.core.ble.HrSummary
import app.gymsupreme.core.journal.SnapshotView
import app.gymsupreme.core.rest.RestSpec
import app.gymsupreme.core.rest.RestTracker
import app.gymsupreme.core.timer.Cue
import app.gymsupreme.core.timer.CueClock
import app.gymsupreme.core.timer.CueKind
import app.gymsupreme.core.timer.CuePlan
import java.io.File

/**
 * The live workout service, phase-0 spike (brief section 5; plan 6.2, R1, R4). Started only from
 * the visible activity ([start]); `START_NOT_STICKY`. It owns the cue clock, the alarm-stream
 * alert, the strap and the ongoing notification, so the cues keep firing with the screen off
 * and Flutter stopped. Everything it does goes to [SpikeLog].
 *
 * Service type (R1): `specialUse` at start; `connectedDevice` is added by a second
 * `startForeground` once the strap's first reading arrives. Below Android 14 `specialUse` is
 * unknown to the platform, so the start tries it, logs what happened and falls back to the
 * manifest types; S5 (CI, API 29/33/34/36) reads the outcome from the log.
 *
 * Threads: cues run on [cueThread] from `elapsedRealtime`, anchored to the block start, under a
 * partial wake lock. The strap and notification run on the main thread. In the spike the wake
 * lock is held until Stop (capped at [SAFETY_CAP_MS]), not just for the timed block as R4 says:
 * the strap's reconnect timers are uptime-clock `postDelayed`s, so after the last cue a drop with
 * the screen off could wait for the next wake-up and fail S3 for a reason that is ours, not the
 * phone's. Phase 1 should hold a short wake lock in the strap client while it hunts instead.
 */
class WorkoutService : Service() {
    private lateinit var notification: WorkoutNotification
    private val main = Handler(Looper.getMainLooper())
    private var cueThread: HandlerThread? = null
    private var cues: Handler? = null
    private var alerter: Alerter? = null
    private var clock: CueClock? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var hrFile: HrFile? = null
    private var hr: BleHrClient? = null
    private var mode: String = MODE_SPIKE
    private var t0 = 0L
    private var t0Wall = 0L
    private var connectedDeviceAdded = false
    private var maxLateMs = 0L
    private var audibleFired = 0
    private var audibleTotal = 0
    private var stopping = false

    // Session mode (cut 1): the rest alert from Dart's snapshots, one bounded wake lock per rest.
    private var tracker: RestTracker? = null
    private var sessionView: SnapshotView? = null
    private var restLock: PowerManager.WakeLock? = null
    @Volatile
    private var restRunnable: Runnable? = null
    private var restArmedAt: Long? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        notification = WorkoutNotification(this).also { it.createChannels() }
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        val wanted = when (action) {
            ACTION_START_SPIKE -> MODE_SPIKE
            ACTION_SELFTEST -> MODE_SELFTEST
            ACTION_SESSION -> MODE_SESSION
            else -> null
        }
        if (wanted == null || status.running) {
            // Every startForegroundService must reach startForeground, even with nothing to do.
            SpikeLog.write(this, SpikeLog.line("start_ignored").put("action", action).put("running", status.running))
            if (status.running) {
                goForeground(currentTypes(), "restart")
            } else {
                goForeground(SPECIAL_USE, "idle")
                stopSelfNow()
            }
            return START_NOT_STICKY
        }
        begin(wanted)
        return START_NOT_STICKY
    }

    private fun begin(m: String) {
        mode = m
        stopping = false
        if (m == MODE_SESSION) {
            beginSession()
            return
        }
        t0 = SystemClock.elapsedRealtime()
        t0Wall = System.currentTimeMillis()
        val plan = if (m == MODE_SELFTEST) CuePlan.selftest() else CuePlan.spike()
        audibleTotal = plan.count { it.kind != CueKind.MARK }
        audibleFired = 0
        maxLateMs = 0
        connectedDeviceAdded = false
        reset(Status(running = true, mode = m, t0 = t0, total = plan.size, title = firstTitle(plan)))
        val started = goForeground(SPECIAL_USE, "start")
        if (!started) {
            // Android 14+ refused the foreground start: nothing ran yet, so nothing is lost.
            reset(Status())
            stopSelfNow()
            return
        }
        wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gymsupreme:cues")
            .also { it.acquire(if (m == MODE_SELFTEST) SELFTEST_RUN_MS + WAKE_MARGIN_MS else SAFETY_CAP_MS + WAKE_MARGIN_MS) }
        val th = HandlerThread("gym-cues", Process.THREAD_PRIORITY_URGENT_AUDIO).also { it.start() }
        cueThread = th
        val h = Handler(th.looper)
        cues = h
        alerter = Alerter(this, h)
        clock = CueClock(plan, t0)
        if (m == MODE_SPIKE) startStrap()
        refreshNotification()
        h.post { tick() }
        if (m == MODE_SELFTEST) main.postDelayed({ stopWorkout("selftest_done") }, SELFTEST_RUN_MS)
        else main.postDelayed({ stopWorkout("safety_cap") }, SAFETY_CAP_MS)
    }

    private fun firstTitle(plan: List<Cue>): String = plan.firstOrNull()?.let { nextTitle(it) } ?: ""

    // ---- service type ----

    /**
     * startForeground with [types]; below Android 14 an unknown-type failure falls back to the
     * manifest's types. Logs requested and actual. False if no foreground state was reached.
     */
    private fun goForeground(types: Int, why: String): Boolean {
        val n = notification.build(content())
        var outcome: String
        var ok = true
        try {
            startForeground(WorkoutNotification.NOTIFICATION_ID, n, types)
            outcome = "ok"
        } catch (e: Exception) {
            outcome = "error:${e.javaClass.simpleName}:${e.message}"
            if (Build.VERSION.SDK_INT < 34 && why != "add_connected_device") {
                try {
                    @Suppress("DEPRECATION")
                    startForeground(WorkoutNotification.NOTIFICATION_ID, n)
                    outcome += " fallback=manifest_types:ok"
                } catch (e2: Exception) {
                    outcome += " fallback=manifest_types:error:${e2.javaClass.simpleName}"
                    ok = false
                }
            } else if (why == "start") {
                ok = false
            }
        }
        val actual = try {
            foregroundServiceType
        } catch (_: Exception) {
            -1
        }
        update { it.copy(serviceType = typeName(actual)) }
        SpikeLog.write(
            this,
            DeviceState.addTo(
                this,
                SpikeLog.line(
                    when (why) {
                        "add_connected_device" -> "service_type_change"
                        "idle" -> "service_idle_start"
                        "restart" -> "service_restart"
                        else -> "service_started"
                    },
                )
                    .put("mode", mode)
                    .put("requested", typeName(types))
                    .put("requested_bits", types)
                    .put("actual", typeName(actual))
                    .put("actual_bits", actual)
                    .put("outcome", outcome),
            ),
        )
        return ok
    }

    private fun currentTypes() = if (connectedDeviceAdded) SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else SPECIAL_USE

    private fun addConnectedDevice() {
        if (connectedDeviceAdded || !status.running) return
        connectedDeviceAdded = true
        goForeground(SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE, "add_connected_device")
    }

    // ---- cues (cue thread) ----

    private fun tick() {
        val c = clock ?: return
        val now = SystemClock.elapsedRealtime()
        for (cue in c.due(now)) fire(c, cue)
        val d = c.delayToNext(SystemClock.elapsedRealtime())
        if (d == null) {
            main.post { onPlanDone() }
            return
        }
        cues?.postDelayed({ tick() }, d)
        main.post { refreshNotification() }
    }

    private fun fire(c: CueClock, cue: Cue) {
        val scheduled = c.scheduledAt(cue)
        val firedAt = SystemClock.elapsedRealtime()
        val late = firedAt - scheduled
        val audible = cue.kind != CueKind.MARK
        val r = if (audible) alerter?.fire(long = cue.kind == CueKind.REST_END) else null
        val posted = if (audible) notification.cue(cueTitle(cue)) else "none"
        if (audible) {
            audibleFired++
            if (late > maxLateMs) maxLateMs = late
        }
        val next = c.peek()
        update { it.copy(fired = c.firedCount, title = next?.let { n -> nextTitle(n) } ?: "Strap only", lastCue = cue.label, lastLateMs = late) }
        SpikeLog.write(
            this,
            DeviceState.addTo(
                this,
                SpikeLog.line("cue")
                    .put("mode", mode)
                    .put("n", cue.index + 1)
                    .put("of", status.total)
                    .put("kind", cue.kind.wire)
                    .put("label", cue.label)
                    .put("scheduled_elapsed_ms", scheduled)
                    .put("fired_elapsed_ms", firedAt)
                    .put("late_ms", late)
                    .put("since_start_ms", firedAt - t0)
                    .put("audio", r?.audio)
                    .put("audio_method", r?.audioMethod)
                    .put("focus", r?.focus)
                    .put("vibrate", r?.vibrate)
                    .put("notification", posted)
                    .put("service_type", status.serviceType)
                    .put("wake_lock_held", wakeLock?.isHeld == true)
                    .put("hr_connected", status.hrConnected)
                    .put("hr_bpm", status.hr),
            ),
        )
    }

    private fun cueTitle(c: Cue) = when (c.kind) {
        CueKind.REST_END -> "Rest over: ${c.label}"
        CueKind.EMOM_MINUTE -> "Go: ${c.label}"
        else -> c.label
    }

    private fun nextTitle(c: Cue) = when (c.kind) {
        CueKind.REST_END -> "Rest ${c.label.removePrefix("rest ")}"
        CueKind.EMOM_MINUTE -> "EMOM, next: ${c.label.removePrefix("EMOM ")}"
        CueKind.MARK -> "Strap check until 45 min"
        CueKind.SELFTEST -> "Self-test"
    }

    private fun onPlanDone() {
        if (!status.running) return
        update { it.copy(title = if (mode == MODE_SELFTEST) "Self-test done" else "Strap only: tap Stop or Share log") }
        refreshNotification()
        SpikeLog.write(this, SpikeLog.line("plan_done").put("mode", mode).put("audible_fired", audibleFired).put("audible_total", audibleTotal).put("max_late_ms", maxLateMs))
    }

    // ---- strap (main thread) ----

    private fun startStrap() {
        if (!BleHrClient.supported) {
            SpikeLog.write(this, SpikeLog.line("strap").put("state", "unsupported_below_android_12"))
            return
        }
        val client = HrHolder.get(this)
        hr = client
        val f = File(SpikeLog.dir(this), "hr-$t0Wall.jsonl")
        hrFile = HrFile(f)
        update { it.copy(hrFile = f.name) }
        SpikeLog.write(this, SpikeLog.line("strap").put("state", if (client.savedAddress == null) "not_linked" else "wanted").put("name", client.deviceName).put("perms", client.hasPermissions()).put("hr_file", f.name))
        client.listener = object : BleHrClient.Listener {
            override fun onReading(reading: HrReading) {
                hrFile?.append(reading, System.currentTimeMillis())
                update { it.copy(hr = reading.bpm, hrConnected = true, hrCount = hrFile?.count ?: 0) }
            }

            override fun onNoContact() {
                update { it.copy(hr = null) }
            }

            override fun onLink(connected: Boolean) {
                update { it.copy(hrConnected = connected, hr = if (connected) it.hr else null) }
                SpikeLog.write(this@WorkoutService, SpikeLog.line("strap_link").put("connected", connected).put("since_start_ms", SystemClock.elapsedRealtime() - t0).put("screen_on", (getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive))
                if (connected) addConnectedDevice()
                refreshNotification()
            }
        }
        if (client.connected) {
            update { it.copy(hrConnected = true) }
            addConnectedDevice()
        }
        client.connectIfPaired()
    }

    private fun stopStrap() {
        hr?.let {
            it.listener = null
            it.disconnect()
        }
        hr = null
        hrFile?.close()
        val f = hrFile?.file
        hrFile = null
        if (f != null && f.exists()) {
            val s = HrSummary.of(HrFile.read(f), t0, SystemClock.elapsedRealtime())
            SpikeLog.write(this, hrSummaryLine(s, f.name))
        }
    }

    // ---- session mode (cut 1) ----

    private fun beginSession() {
        t0 = SystemClock.elapsedRealtime()
        t0Wall = System.currentTimeMillis()
        val view = pendingView
        pendingView = null
        sessionView = view
        reset(Status(running = true, mode = MODE_SESSION, t0 = t0, title = view?.current?.exerciseName ?: "Workout"))
        if (!goForeground(SPECIAL_USE, "start")) {
            reset(Status())
            stopSelfNow()
            return
        }
        val th = HandlerThread("gym-cues", Process.THREAD_PRIORITY_URGENT_AUDIO).also { it.start() }
        cueThread = th
        val h = Handler(th.looper)
        cues = h
        alerter = Alerter(this, h)
        tracker = RestTracker()
        if (view != null) applyView(view) else refreshNotification()
    }

    /** An accepted snapshot (main thread): arm, keep, cancel or fire the rest; refresh the notification. */
    fun applyView(view: SnapshotView) {
        if (status.mode != MODE_SESSION || stopping) return
        sessionView = view
        update { it.copy(title = view.current?.exerciseName ?: "All sets logged", fired = view.setsDone, total = view.setsTotal) }
        val t = tracker ?: return
        val action = if (view.paused) t.clear() else t.onSnapshot(view.rest, System.currentTimeMillis(), SystemClock.elapsedRealtime())
        when (action) {
            is RestTracker.Action.Keep -> Unit
            is RestTracker.Action.Cancel -> cancelRest("cancelled")
            is RestTracker.Action.Arm -> armRest(action.spec, action.atElapsedMs)
            is RestTracker.Action.FireNow -> {
                cancelRest("replaced")
                cues?.post { fireRest(action.spec, SystemClock.elapsedRealtime() - action.lateMs, "resume_grace", null) }
            }
            is RestTracker.Action.Missed -> {
                NativeCounters.add(this, NativeCounters.REST_ALERTS_MISSED)
                SpikeLog.write(this, SpikeLog.line("rest_missed").put("set_id", action.spec.key).put("late_ms", action.lateMs))
            }
        }
        refreshNotification()
    }

    private fun armRest(spec: RestSpec, atElapsed: Long) {
        cancelRest("replaced")
        val h = cues ?: return
        val delay = (atElapsed - SystemClock.elapsedRealtime()).coerceAtLeast(0)
        // R4: a wake lock bounded to this rest, so the alert fires with the screen off.
        restLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gymsupreme:rest")
            .also { it.acquire(delay + REST_LOCK_MARGIN_MS) }
        restArmedAt = atElapsed
        lateinit var run: Runnable
        run = Runnable { fireRest(spec, atElapsed, "timer", run) }
        restRunnable = run
        h.postDelayed(run, delay)
        SpikeLog.write(this, SpikeLog.line("rest_armed").put("set_id", spec.key).put("duration_ms", spec.durationMs).put("fires_in_ms", delay).put("scheduled_elapsed_ms", atElapsed))
    }

    private fun cancelRest(why: String) {
        val run = restRunnable
        restRunnable = null
        restArmedAt = null
        if (run != null) {
            cues?.removeCallbacks(run)
            SpikeLog.write(this, SpikeLog.line("rest_cancelled").put("why", why))
        }
        restLock?.let { if (it.isHeld) it.release() }
        restLock = null
    }

    /**
     * Cue thread. [run] is the timer's own runnable (null for a resume-grace fire): if the rest was
     * re-armed or cancelled meanwhile it is no longer current and this fire is dropped. A timer
     * that wakes early re-posts itself; the alert fires once.
     */
    private fun fireRest(spec: RestSpec, scheduled: Long, cause: String, run: Runnable?) {
        if (run != null && restRunnable !== run) return
        val now = SystemClock.elapsedRealtime()
        if (run != null && now < scheduled) {
            cues?.postDelayed(run, scheduled - now)
            return
        }
        val late = now - scheduled
        val r = alerter?.fire(long = true)
        val next = sessionView?.current
        val posted = notification.cue(if (next != null) "Rest over: ${next.exerciseName}, set ${next.setNumber}" else "Rest over")
        NativeCounters.add(this, NativeCounters.REST_ALERTS_FIRED)
        if (late > NativeCounters.LATE_MS) NativeCounters.add(this, NativeCounters.REST_ALERTS_LATE)
        NativeCounters.max(this, NativeCounters.REST_ALERT_MAX_LATE_MS, late)
        if (r == null || !r.audio.startsWith("ok")) NativeCounters.add(this, NativeCounters.REST_ALERTS_AUDIO_FAILED)
        SpikeLog.write(
            this,
            DeviceState.addTo(
                this,
                SpikeLog.line("rest_alert")
                    .put("set_id", spec.key)
                    .put("cause", cause)
                    .put("duration_ms", spec.durationMs)
                    .put("scheduled_elapsed_ms", scheduled)
                    .put("fired_elapsed_ms", now)
                    .put("late_ms", late)
                    .put("audio", r?.audio)
                    .put("audio_method", r?.audioMethod)
                    .put("focus", r?.focus)
                    .put("vibrate", r?.vibrate)
                    .put("notification", posted)
                    .put("service_type", status.serviceType)
                    .put("wake_lock_held", restLock?.isHeld == true),
            ),
        )
        main.post {
            tracker?.onFired(spec.key)
            // Only clear what this fire owned: a +15 s change may have armed a new rest meanwhile.
            // A resume-grace fire (run == null) owns nothing armed: leave a rest armed since alone.
            if ((run == null && restRunnable == null) || (run != null && restRunnable === run)) {
                restRunnable = null
                restArmedAt = null
                restLock?.let { if (it.isHeld) it.release() }
                restLock = null
            }
            update { it.copy(lastCue = "rest ${spec.key}", lastLateMs = late) }
            refreshNotification()
        }
    }

    /** Pause or finish from [LiveSession]: stop the service; the journal stays until Dart deletes it. */
    fun endSession(reason: String) {
        if (status.mode == MODE_SESSION) stopWorkout(reason)
    }

    // ---- stop ----

    /** Stop from the app, the lock screen, the self-test timer or the safety cap. Main thread; idempotent. */
    fun stopWorkout(reason: String) {
        if (!status.running || stopping) return
        stopping = true
        val c = clock
        clock = null
        cues?.removeCallbacksAndMessages(null)
        val a = alerter
        alerter = null
        val th = cueThread
        cueThread = null
        cues = null
        if (a != null && th != null) {
            Handler(th.looper).post {
                a.release()
                th.quitSafely()
            }
        }
        main.removeCallbacksAndMessages(null)
        cancelRest("stop")
        tracker = null
        sessionView = null
        releaseWakeLock("stop")
        stopStrap()
        notification.clearCue()
        SpikeLog.write(
            this,
            SpikeLog.line("service_stopped").put("mode", mode).put("reason", reason)
                .put("duration_ms", SystemClock.elapsedRealtime() - t0)
                .put("cues_fired", c?.firedCount).put("audible_fired", audibleFired).put("audible_total", audibleTotal)
                .put("max_late_ms", maxLateMs),
        )
        reset(Status())
        stopSelfNow()
    }

    private fun stopSelfNow() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun releaseWakeLock(why: String) {
        val w = wakeLock ?: return
        wakeLock = null
        if (w.isHeld) w.release()
        SpikeLog.write(this, SpikeLog.line("wake_lock_released").put("why", why).put("since_start_ms", SystemClock.elapsedRealtime() - t0))
    }

    private fun content(): WorkoutNotification.Content {
        if (mode == MODE_SESSION) return sessionContent()
        val s = status
        val c = clock
        val nextWall = c?.peek()?.let { System.currentTimeMillis() + (c.scheduledAt(it) - SystemClock.elapsedRealtime()) }
        val text = buildString {
            append("${s.fired} of ${s.total} cues")
            if (s.hrConnected) append("  ·  ${s.hr ?: "--"} bpm") else if (mode == MODE_SPIKE) append("  ·  strap not connected")
        }
        return WorkoutNotification.Content(s.title, text, nextWall)
    }

    /** R3: exercise, set n of m, what Done will log, the rest countdown. No actions until cut 2. */
    private fun sessionContent(): WorkoutNotification.Content {
        val v = sessionView
        val c = v?.current
        val restEndWall = restArmedAt?.let { System.currentTimeMillis() + (it - SystemClock.elapsedRealtime()) }
        val title = when {
            v == null -> "Workout"
            c == null -> "All sets logged: finish in the app"
            restEndWall != null -> "Rest · next ${c.exerciseName}"
            else -> c.exerciseName
        }
        val text = if (c == null) "${v?.setsDone ?: 0} sets" else "Set ${c.setNumber} of ${c.setCount}  ·  ${v?.doneLine() ?: ""}"
        return WorkoutNotification.Content(title, text, restEndWall, stopAction = false)
    }

    private fun refreshNotification() {
        if (status.running) notification.update(content())
    }

    override fun onDestroy() {
        if (status.running) {
            SpikeLog.write(this, SpikeLog.line("service_destroyed_mid_workout").put("mode", mode))
            stopping = false
            stopWorkout("destroyed")
        }
        if (instance === this) instance = null
        super.onDestroy()
    }

    /** What the spike screen shows; replaced whole, read from any thread. */
    data class Status(
        val running: Boolean = false,
        val mode: String? = null,
        val t0: Long = 0,
        val total: Int = 0,
        val fired: Int = 0,
        val title: String = "",
        val lastCue: String? = null,
        val lastLateMs: Long? = null,
        val serviceType: String? = null,
        val hrConnected: Boolean = false,
        val hr: Int? = null,
        val hrCount: Int = 0,
        val hrFile: String? = null,
    )

    companion object {
        const val ACTION_START_SPIKE = "app.gymsupreme.action.START_SPIKE"
        const val ACTION_SELFTEST = "app.gymsupreme.action.SELFTEST"
        const val MODE_SPIKE = "spike"
        const val MODE_SELFTEST = "selftest"
        const val MODE_SESSION = "session"
        const val ACTION_SESSION = "app.gymsupreme.action.SESSION"
        private const val REST_LOCK_MARGIN_MS = 30_000L

        /** The view for a session start, handed to onStartCommand. Main thread. */
        private var pendingView: SnapshotView? = null

        /**
         * An accepted snapshot that is not paused: update the running session, or start the
         * service for it (the caller is Dart in the visible activity). A spike run in progress
         * is left alone and logged.
         */
        fun session(context: Context, view: SnapshotView) {
            val s = instance
            when {
                status.running && status.mode == MODE_SESSION && s != null -> s.applyView(view)
                status.running -> SpikeLog.write(context, SpikeLog.line("session_blocked").put("running_mode", status.mode))
                else -> {
                    pendingView = view
                    start(context, ACTION_SESSION)
                }
            }
        }

        /** ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE (API 34), as a literal so older SDK levels can try it. */
        const val SPECIAL_USE = 1 shl 30
        private const val WAKE_MARGIN_MS = 60_000L
        private const val SELFTEST_RUN_MS = 20_000L

        /** The spike stops itself after an hour if nobody taps Stop. */
        private const val SAFETY_CAP_MS = 60 * 60_000L

        @Volatile
        var instance: WorkoutService? = null

        @Volatile
        var status: Status = Status()
            private set

        @Synchronized
        private fun update(f: (Status) -> Status) {
            status = f(status)
        }

        @Synchronized
        private fun reset(s: Status) {
            status = s
        }

        /** From the visible activity only (plan 6.2). */
        fun start(context: Context, action: String) {
            val i = Intent(context, WorkoutService::class.java).setAction(action)
            context.startForegroundService(i)
        }

        fun hrSummaryLine(s: HrSummary.Result, file: String) =
            SpikeLog.line("hr_summary")
                .put("file", file)
                .put("readings", s.readings)
                .put("minutes", s.perMinute.size)
                .put("empty_minutes", s.perMinute.count { it == 0 })
                .put("per_minute", s.perMinute.joinToString(","))
                .put("gaps", s.gaps.joinToString(";") { "${it.fromMs / 1000}-${it.toMs / 1000}s" })
                .put("longest_gap_s", (s.gaps.maxOfOrNull { it.lengthMs } ?: 0L) / 1000)

        fun typeName(bits: Int): String {
            if (bits < 0) return "unknown"
            if (bits == 0) return "none"
            val names = ArrayList<String>()
            if (bits and SPECIAL_USE != 0) names.add("specialUse")
            if (bits and ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE != 0) names.add("connectedDevice")
            val rest = bits and (SPECIAL_USE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE).inv()
            if (rest != 0) names.add("other:$rest")
            return names.joinToString("|")
        }
    }
}
