package dev.igor.motonav.nav

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * What the phone is doing with a route right now (sheet 2, `docs/design/telas.md` §5.4): the Home
 * screen's ring spins while it calculates or sends. It does not change the protocol: it is only the process state.
 */
sealed interface NavActivity {
    data object Idle : NavActivity

    /** Asking Mapbox for the route to [destination]; [fromWatch] when the request came from the watch. */
    data class Calculating(val destination: String, val fromWatch: Boolean) : NavActivity

    /** The route to [destination] traveling to the watch. */
    data class Sending(val destination: String, val fromWatch: Boolean) : NavActivity
}

/** Only one per process: the favorite requested by the watch and the share publish here. */
object NavActivityBus {
    private val mutable = MutableStateFlow<NavActivity>(NavActivity.Idle)
    val state: StateFlow<NavActivity> = mutable.asStateFlow()

    fun calculating(destination: String, fromWatch: Boolean) {
        mutable.value = NavActivity.Calculating(destination, fromWatch)
    }

    fun sending(destination: String, fromWatch: Boolean) {
        mutable.value = NavActivity.Sending(destination, fromWatch)
    }

    fun idle() {
        mutable.value = NavActivity.Idle
    }
}
