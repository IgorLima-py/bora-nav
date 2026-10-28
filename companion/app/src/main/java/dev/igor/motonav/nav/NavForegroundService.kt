package dev.igor.motonav.nav

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.igor.motonav.MainActivity
import dev.igor.motonav.R
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.geo.LocationSource
import dev.igor.motonav.settings.BatteryExemption
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The foreground service that holds the process while the watch navigates (C13a),
 * **and outside navigation too, listening to the watch** (C16.5).
 *
 * **It has no navigation logic.** What answers `REROUTE_REQ` and sends
 * `ROUTE_UPDATE` is the [RerouteController]; this only makes Android keep the process
 * alive, with network and with the CPU awake, with the phone locked in the pocket. It turns on when
 * the session starts and off when it ends (`RerouteHub`, `onSessionChanged`).
 *
 * The survival design came from another app's `RideService` (`startForeground`
 * before anything else, partial wake lock, `START_STICKY`, a log of who stopped it); the class
 * did not, and the decision is in `docs/DECISIONS.md` §C13a.
 *
 * **Type `specialUse`, and `location` along with it when possible** (C13b). `specialUse` is what
 * holds the process. `location` is what lets Android deliver position with the app
 * off screen, so the phone's GPS can back up the watch's
 * (`PhoneFixFeed`). It only comes up with location permission granted **and** with the
 * app on screen at the moment the service is created: in the background, without
 * `ACCESS_BACKGROUND_LOCATION` (which the app does not ask for, `04 §Permissions`), Android 14+
 * answers `SecurityException`. That is the case of a favorite requested by the watch with the
 * phone in the pocket: the service comes up with `specialUse` only, as in C13a, and that trip
 * goes without the GPS backup.
 *
 * **Listening to the watch** (C16.5). Until C16 the service fell when navigation
 * ended, Android froze the process, and a favorite requested on the watch only
 * arrived when Igor opened the phone app (`DECISIONS.md` §2026-10-16: 25 s of
 * watch messages delivered at once at 14:09). Now it comes up when the app
 * opens ([listen]) and stays: between one navigation and the next, with no wake lock (what wakes
 * the process is the message arriving from the watch), with the notification "Bora? listening to the
 * watch". Opened by the app on screen, it carries the `location` type, and a favorite requested
 * with the phone in the pocket has a current position. Only `e2e.py`'s canary ([shutdown])
 * takes it down on purpose.
 *
 * **The session is not persisted.** If Android kills the process, `START_STICKY`
 * restarts the service with a null `intent`, with no session to hold: it logs
 * `restarted by the system: session lost` and goes back to listening to the watch (with only
 * `specialUse`: in the background `location` does not come up). That line is the evidence
 * for C16 to say whether the S25 kills it.
 */
class NavForegroundService : Service() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var wakeLock: PowerManager.WakeLock? = null
    private var cpuJob: Job? = null
    private var drillJob: Job? = null

    /** `startForeground` has been called: only from then on may the service be stopped. */
    private var inForeground = false

    /** This instance was told to stop by [stop]: the `onDestroy` log says by whom. */
    private var finishing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        EventLog.init(applicationContext)
        RerouteHub.of(applicationContext)
        running = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            // Restarted after the process died: the navigation was lost, but the watch
            // may still ask for a favorite. If the system refuses foreground from here
            // (without the battery exemption), the `catch` below ends it, as before C16.5.
            EventLog.w(TAG, "restarted by the system: session lost (pid ${android.os.Process.myPid()})")
        }
        // Before anything else: whoever calls `startForegroundService` and does not
        // get here within a few seconds is taken down by the system.
        val notification = notification()
        var withLocation = LocationSource(this).hasPermission()
        try {
            if (inForeground && hasLocationType) {
                // Already up with the `location` type (recalculation, new destination): only the notification
                // text changes. Redoing `startForeground` with the phone in the
                // pocket could be refused, and the refusal would swap the type for
                // `specialUse` in the middle of a tunnel. Whoever is already in the foreground
                // owes the system no new `startForeground`.
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
            } else try {
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types(withLocation))
            } catch (e: SecurityException) {
                if (!withLocation) {
                    throw e
                }
                // The app was not on screen when the service was created: the
                // `location` type does not come up, `specialUse` does.
                EventLog.w(TAG, "without the location type (${e.message}): comes up with specialUse only, no GPS reserve")
                withLocation = false
                ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, types(false))
            }
        } catch (e: Exception) {
            // `ForegroundServiceStartNotAllowedException` (app in the background without the
            // battery exemption) or `SecurityException`. Carries on without the service, as before C13a.
            EventLog.w(TAG, "did not come up in foreground: ${e.javaClass.simpleName}: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        inForeground = true
        hasLocationType = withLocation
        if (!wanted && !listening) {
            // Turned off ([shutdown]) between the request and its arrival here. Stopping before
            // `startForeground` would take the process down; after it, it is fine.
            EventLog.i(TAG, "shut down before the service came up")
            finish()
            return START_NOT_STICKY
        }
        if (wanted) holdCpu() else releaseCpu()
        // `e2e.py` reads the type from the last of these lines (`C_SERVICE_TYPE`): it is also emitted
        // when navigation starts with the service already listening.
        EventLog.i(
            TAG,
            "in foreground: pid ${android.os.Process.myPid()}, " +
                "type ${if (withLocation) "specialUse|location" else "specialUse"}, " +
                "battery exempt: ${if (BatteryExemption.granted(this)) "yes" else "no"}, " +
                if (wanted) "navigating" else "listening to the watch",
        )
        return START_STICKY
    }

    /** The navigation ended and the service stays listening: no wake lock, with the other notification. */
    private fun idle() {
        releaseCpu()
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification())
        EventLog.i(TAG, "navigation ended: keeps listening to the watch, no wake lock")
    }

    /**
     * Holds the CPU. The `ROUTE_UPDATE` loop waits with `delay`, which on the main
     * thread counts time while the CPU is **awake**: with the phone
     * asleep, the 10 min would never pass.
     *
     * The lock has a timeout of two intervals and is renewed at each one: while this
     * loop runs, the lock never expires; if the process hangs, it expires by itself instead of
     * draining the battery to the end.
     */
    private fun holdCpu() {
        if (wakeLock != null) {
            return
        }
        val lock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, WAKE_LOCK_TAG)
        // Not counted: each `acquire` renews the timeout instead of stacking.
        lock.setReferenceCounted(false)
        wakeLock = lock
        cpuJob = scope.launch {
            while (true) {
                lock.acquire(2 * RerouteController.ETA_REFRESH_MS)
                delay(RerouteController.ETA_REFRESH_MS)
            }
        }
        // The dead-app drill (C16): the wait counts with the CPU awake, which the lock above holds.
        val drill = KillDrill.prefs(this)
        if (drill.armed) {
            EventLog.i(TAG, "drill armed: the app kills itself ${KillDrill.AFTER_MS / 60_000} min after departure")
            drillJob = scope.launch {
                delay(KillDrill.AFTER_MS)
                KillDrill(drill).fire(
                    log = { EventLog.w(TAG, "$it (pid ${android.os.Process.myPid()})") },
                    kill = { android.os.Process.killProcess(android.os.Process.myPid()) },
                )
            }
        }
    }

    /** Outside navigation the CPU sleeps: the `ROUTE_UPDATE` loop has nothing to wait for. */
    private fun releaseCpu() {
        // The trip ended before the 15 min: the drill stays armed for the next one.
        drillJob?.cancel()
        drillJob = null
        cpuJob?.cancel()
        cpuJob = null
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
    }

    private fun types(withLocation: Boolean): Int =
        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
            (if (withLocation) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0)

    private fun finish() {
        finishing = true
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        if (running === this) {
            running = null
            hasLocationType = false
        }
        val why = when {
            finishing -> "shut down"
            wanted -> "by the system, with navigation in progress"
            else -> "by the system, listening to the watch"
        }
        EventLog.i(TAG, "ended ($why)")
        super.onDestroy()
    }

    /** The one for the navigation in progress ([wanted]) or the one for listening to the watch. */
    private fun notification(): Notification {
        val label = currentLabel
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            // Low: stays in the drawer with no sound or vibration, for the whole trip.
            NotificationChannel(CHANNEL_ID, getString(R.string.nav_channel), NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val title = when {
            !wanted -> getString(R.string.listen_notification)
            label.isBlank() -> getString(R.string.nav_notification_plain)
            else -> getString(R.string.nav_notification, label)
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(title)
            .setContentText(getString(if (wanted) R.string.nav_notification_text else R.string.listen_notification_text))
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }

    companion object {
        private const val TAG = "NavService"
        private const val CHANNEL_ID = "nav"
        private const val NOTIFICATION_ID = 1

        /** The label that `dumpsys power` shows, and that `e2e.py --doze` looks for. */
        const val WAKE_LOCK_TAG = "motonav:nav"

        // Everything on the main thread: `RerouteHub` calls from there and the service's
        // callbacks run there.
        private var running: NavForegroundService? = null

        /** There is a navigation the service must hold. */
        private var wanted = false

        /** The destination of the navigation in progress, for the notification. */
        private var currentLabel = ""

        /**
         * Outside navigation the service stays listening to the watch (C16.5). Only `e2e.py`'s canary
         * turns it off ([shutdown]); the new process is born listening.
         */
        private var listening = true

        /**
         * The service is up **with the `location` type**: only then does Android deliver
         * position with the app off screen, and only then does `PhoneFixFeed` turn on (C13b).
         */
        @Volatile
        var hasLocationType = false
            private set

        /** Turns on (or updates the notification of) the service for the navigation to [label]. */
        fun start(context: Context, label: String) {
            wanted = true
            currentLabel = label
            launch(context)
        }

        /**
         * The app opened (C16.5): the service comes up, or gains the `location` type that it
         * could not get in the background. With the app on screen Android allows both.
         */
        fun listen(context: Context) {
            listening = true
            if (running?.inForeground == true && hasLocationType) {
                return
            }
            launch(context)
        }

        private fun launch(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, NavForegroundService::class.java))
            } catch (e: Exception) {
                // In the background without the battery exemption (the favorite requested by the
                // watch with the phone in the pocket): the system refuses. Navigation carries on
                // as before C13a, without the service's guarantee.
                EventLog.w(TAG, "the system refused the service: ${e.javaClass.simpleName}: ${e.message}")
            }
        }

        /**
         * The navigation ended: the service releases the CPU and stays listening to the watch. If it
         * has not yet reached `startForeground`, `onStartCommand` sees [wanted] false
         * and comes up already listening.
         */
        fun stop() {
            wanted = false
            val service = running?.takeIf { it.inForeground } ?: return
            if (listening) service.idle() else service.finish()
        }

        /**
         * Turns off for good, listening included: only the canary of `e2e.py --doze --canary`.
         * From inside the process, and not through `stopService`: stopping a service requested by
         * `startForegroundService` before it calls `startForeground` takes the app down.
         */
        fun shutdown() {
            listening = false
            wanted = false
            running?.takeIf { it.inForeground }?.finish()
        }
    }
}
