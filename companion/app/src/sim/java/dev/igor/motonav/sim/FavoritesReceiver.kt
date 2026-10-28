package dev.igor.motonav.sim

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.favorites.FavoritesStore
import dev.igor.motonav.link.WatchLink
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * The **public-place** favorites for `tools/e2e.py --favorito` (C12),
 * **only in the `sim` variant**. The `.sim` package is another app to Android: its
 * [FavoritesStore] is born with the three seeds with no address, and the app's
 * edit screen needs a keyboard and search. This swaps the whole list for the three
 * places below and sends it to the watch, as the app would after saving:
 *
 * ```
 * adb -s emulator-5554 shell am broadcast -a dev.igor.motonav.sim.FAVORITES -n dev.igor.motonav.sim/dev.igor.motonav.sim.FavoritesReceiver
 * ```
 *
 * Never an address of Igor's: Copan, MASP and Praça da Sé are public points
 * (the same names as the fixture `favorites_00.bin`). Neither the S25 debug nor the
 * release has this component.
 */
class FavoritesReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        EventLog.init(context.applicationContext)
        val store = FavoritesStore.of(context.applicationContext)
        store.list().forEach { store.delete(it.id) }
        PUBLIC_PLACES.forEach { store.save(it) }
        EventLog.i(TAG, "test favorites saved: ${store.list().size}")

        val pending = goAsync()
        CoroutineScope(Dispatchers.Main.immediate).launch {
            try {
                val ok = WatchLink.of(context.applicationContext).sendFavorites(store.wire())
                EventLog.i(TAG, "test favorites sent to the watch: $ok")
            } finally {
                pending.finish()
            }
        }
    }

    private companion object {
        const val TAG = "FavoritesReceiver"

        val PUBLIC_PLACES = listOf(
            Favorite(id = 0, name = "Copan", lat = -23.547538, lon = -46.642686, icon = 2, address = "Edifício Copan"),
            Favorite(id = 0, name = "MASP", lat = -23.561414, lon = -46.655881, icon = 3, address = "Av. Paulista, MASP"),
            Favorite(id = 0, name = "Praça da Sé", lat = -23.550520, lon = -46.633309, icon = 5, address = "Praça da Sé"),
        )
    }
}
