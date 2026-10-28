package dev.igor.motonav.sim

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.nav.NavForegroundService

/**
 * The canary of `tools/e2e.py --doze --canary` (C13a), **only in the `sim` variant**: stops
 * the foreground service and leaves the navigation as it is. With the same code and
 * without the service, the round must exit 1; if it exits 0, `--doze` is not measuring the
 * service.
 *
 * ```
 * adb -s emulator-5554 shell am broadcast -a dev.igor.motonav.sim.STOP_NAV_SERVICE -n dev.igor.motonav.sim/dev.igor.motonav.sim.ServiceReceiver
 * ```
 *
 * Neither the S25 debug nor the release has this component.
 */
class ServiceReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EventLog.init(context.applicationContext)
        NavForegroundService.shutdown()
        EventLog.i("ServiceReceiver", "service stopped at the e2e request (canary)")
    }
}
