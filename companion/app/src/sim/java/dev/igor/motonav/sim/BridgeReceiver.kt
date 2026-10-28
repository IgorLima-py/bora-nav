package dev.igor.motonav.sim

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.link.WatchLink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The bridge proof, **only in the `sim` variant** (C7a). `tools/ponte.py` calls:
 *
 * ```
 * adb -s emulator-5554 shell am broadcast -a dev.igor.motonav.sim.PONTE -n dev.igor.motonav.sim/dev.igor.motonav.sim.BridgeReceiver --es id 1234
 * ```
 *
 * and the companion sends `PONTE:C2R:1234` to the app in the simulator. The watch prints
 * the same line and answers `PONTE:R2C:1234`, which [WatchLink] writes to
 * logcat. None of this goes through `05-PROTOCOL.md`: it is pure transport.
 *
 * The reply does not come back through the SDK: `transmit` over `TETHERED` freezes the app in the
 * SDK 9.2.0 simulator (CIQQA-4579). The watch prints `PONTE:TX:<texto>` and
 * `ponte.py` delivers the text here, through the second action:
 *
 * ```
 * adb -s emulator-5554 shell am broadcast -a dev.igor.motonav.sim.RELAY -n dev.igor.motonav.sim/dev.igor.motonav.sim.BridgeReceiver --es text <texto>
 * ```
 */
class BridgeReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EventLog.init(context.applicationContext)
        if (intent.action == ACTION_RELAY) {
            val text = intent.getStringExtra(EXTRA_TEXT)
            if (text.isNullOrEmpty()) {
                EventLog.w(TAG, "relay without text: use --es text <line>")
            } else {
                WatchLink.of(context.applicationContext).relayFromWatch(text)
            }
            return
        }
        if (intent.action == ACTION_CMD) {
            sendCommand(context.applicationContext, intent.getStringExtra(EXTRA_TEXT))
            return
        }
        val id = intent.getStringExtra(EXTRA_ID)
        if (id.isNullOrBlank()) {
            EventLog.w(TAG, "probe without id: use --es id <id>")
            return
        }

        // Same care as in `ConfigReceiver`: the SDK starts asynchronously and the send
        // waits for the callback; `goAsync` keeps the process alive meanwhile.
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val link = WatchLink.of(context.applicationContext)
                withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { link.state.first { !it.initializing } }
                // The simulator only shows up after Connection > Start: the list
                // read when the SDK opened may predate it.
                link.refreshDevices()
                val ok = link.sendProbe("${WatchLink.PROBE_PREFIX}C2R:$id")
                EventLog.i(TAG, "probe $id ${if (ok) "delivered" else "NOT delivered"}")
            } catch (e: Exception) {
                EventLog.e(TAG, "probe failed", e)
            } finally {
                pending.finish()
            }
        }
    }

    /**
     * A command to the app in the simulator (`PONTE:CMD:<texto>`, C11): it is how
     * `tools/e2e.py --desvio` turns on the virtual lap and diverts the bike. Same path
     * as the proof — `TETHERED`, outbound —, just with another prefix.
     */
    private fun sendCommand(context: Context, text: String?) {
        if (text.isNullOrBlank()) {
            EventLog.w(TAG, "command without text: use --es text <command>")
            return
        }
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val link = WatchLink.of(context)
                withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { link.state.first { !it.initializing } }
                link.refreshDevices()
                val ok = link.sendProbe("PONTE:CMD:$text")
                EventLog.i(TAG, "command '$text' ${if (ok) "delivered" else "NOT delivered"}")
            } catch (e: Exception) {
                EventLog.e(TAG, "command failed", e)
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        const val TAG = "BridgeReceiver"
        const val ACTION_CMD = "dev.igor.motonav.sim.CMD"
        const val EXTRA_ID = "id"
        const val ACTION_RELAY = "dev.igor.motonav.sim.RELAY"
        const val EXTRA_TEXT = "text"
        const val SDK_READY_TIMEOUT_MS = 10_000L
    }
}
