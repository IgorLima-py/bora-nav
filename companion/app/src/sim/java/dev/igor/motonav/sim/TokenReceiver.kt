package dev.igor.motonav.sim

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.settings.TokenStore

/**
 * The Mapbox token, **only in the `sim` variant** (C7b). The `.sim` package is another
 * app to Android, so its [TokenStore] is born empty; and the prefs are
 * encrypted by the Keystore, which rules out `run-as`. `tools/e2e.py` reads
 * the token from `.secrets/` at run time and delivers it like this:
 *
 * ```
 * adb -s emulator-5554 shell am broadcast -a dev.igor.motonav.sim.TOKEN -n dev.igor.motonav.sim/dev.igor.motonav.sim.TokenReceiver --es token <token>
 * ```
 *
 * The token never goes to the log (08 §Conventions): only the length. Neither the S25 debug nor the
 * release has this component — there the token enters through the screen.
 */
class TokenReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EventLog.init(context.applicationContext)
        val token = intent.getStringExtra(EXTRA_TOKEN)?.trim()
        if (token.isNullOrEmpty()) {
            EventLog.w(TAG, "empty token: use --es token <token>")
            return
        }
        TokenStore(context.applicationContext).mapboxToken = token
        EventLog.i(TAG, "token saved (${token.length} characters)")
    }

    private companion object {
        const val TAG = "TokenReceiver"
        const val EXTRA_TOKEN = "token"
    }
}
