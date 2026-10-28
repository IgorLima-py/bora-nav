package dev.igor.motonav.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.link.WatchLink
import dev.igor.motonav.proto.ConfigKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Wireless fine-tuning, **debug build only** (C5). The settings screen belongs to
 * C9; until then, Igor (or the test bench) changes the watch like this:
 *
 * ```
 * adb shell am broadcast -a dev.igor.motonav.debug.CONFIG -n dev.igor.motonav/.debug.ConfigReceiver --ei lead_s 10
 * adb shell am broadcast -a dev.igor.motonav.debug.CONFIG -n dev.igor.motonav/.debug.ConfigReceiver --ez reset true
 * ```
 *
 * Each `--ei <key> <value>` is a key of [ConfigKey]; `--ez reset true`
 * sends an empty CONFIG, which returns the watch to its defaults. The result goes to
 * `motonav.log` with the `ConfigReceiver` tag, and the watch's refusal, if any,
 * arrives through its log (`WATCH|config refused ...`).
 */
class ConfigReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EventLog.init(context.applicationContext)
        val entries = try {
            entriesOf(intent)
        } catch (e: IllegalArgumentException) {
            EventLog.w(TAG, "config not sent: ${e.message}")
            return
        }

        // The send waits for an ACK (up to ~8 s per round): `goAsync` keeps the process
        // alive meanwhile. An adb broadcast is a background one, with a 60 s deadline.
        val pending = goAsync()
        CoroutineScope(Dispatchers.Main).launch {
            try {
                val link = WatchLink.of(context.applicationContext)
                // Cold process: the Connect IQ SDK starts asynchronously, and without
                // waiting `sendConfig` finds no watch at all.
                withTimeoutOrNull(SDK_READY_TIMEOUT_MS) { link.state.first { !it.initializing } }
                val ok = link.sendConfig(entries) { progress ->
                    progress.error?.let { EventLog.w(TAG, "config: $it") }
                }
                val what = if (entries.isEmpty()) "default" else entries.joinToString(" ") { (id, v) -> "$id=$v" }
                EventLog.i(TAG, "config $what ${if (ok) "delivered" else "NOT delivered"}")
            } catch (e: Exception) {
                EventLog.e(TAG, "config failed", e)
            } finally {
                pending.finish()
            }
        }
    }

    private fun entriesOf(intent: Intent): List<Pair<Int, Int>> {
        val extras = intent.extras ?: throw IllegalArgumentException("no extras: use --ei <key> <value>")
        if (extras.getBoolean(RESET, false)) {
            return emptyList()
        }
        val values = extras.keySet().associateWith { name ->
            val value = extras.getInt(name, Int.MIN_VALUE)
            require(value != Int.MIN_VALUE) { "$name is not an integer: use --ei $name <value>" }
            value
        }
        require(values.isNotEmpty()) { "no key: use --ei <key> <value> or --ez reset true" }
        return ConfigKey.parse(values)
    }

    private companion object {
        const val TAG = "ConfigReceiver"
        const val RESET = "reset"
        const val SDK_READY_TIMEOUT_MS = 10_000L
    }
}
