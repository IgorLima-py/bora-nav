package dev.igor.motonav.nav

import android.content.Context

/**
 * The dead-app drill (C16, the laps of 2026-10-19 and 20): armed on the "Watch
 * settings" screen, it kills the process [AFTER_MS] after navigation starts, **only once**,
 * as Android would for lack of memory. It is the "companion dead in the middle" of the old C18,
 * which Igor cannot do on the motorcycle.
 *
 * What the lap shows, without a report: `START_STICKY` bringing the service back (`restarted by the
 * system: session lost`, [NavForegroundService]), and the watch carrying on with its own GPS, the
 * warnings and, at a wrong turn after that, `recalculating needs the phone`.
 *
 * **It disarms before killing**, and writes with `commit`, which waits for the disk: the process that
 * is born afterwards must not find the drill still armed and kill itself again.
 */
class KillDrill(private val store: Store) {

    /** Where the "armed" flag lives. In the app, the preferences; in the test, a variable. */
    interface Store {
        var armed: Boolean
    }

    /**
     * Kills if armed. [log] receives the line before [kill], which in the app does not return.
     * Returns whether it killed (in the test [kill] returns).
     */
    fun fire(log: (String) -> Unit, kill: () -> Unit): Boolean {
        if (!store.armed) return false
        store.armed = false
        log("drill: the app kills itself now, ${AFTER_MS / 60_000} min after departure")
        kill()
        return true
    }

    companion object {
        /**
         * 15 min: after the GPS drill if it is within 13 min, and before arrival on a
         * trip longer than 20 min. A choice, not a measurement. A shorter trip does not kill and the drill
         * stays armed for the next one.
         */
        const val AFTER_MS = 15 * 60_000L

        private const val PREFS = "bancada"
        private const val KEY_ARMED = "derrubar_o_app"

        fun prefs(context: Context): Store = object : Store {
            private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            override var armed: Boolean
                get() = prefs.getBoolean(KEY_ARMED, false)
                set(value) {
                    prefs.edit().putBoolean(KEY_ARMED, value).commit()
                }
        }
    }
}
