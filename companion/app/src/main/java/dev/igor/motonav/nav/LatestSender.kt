package dev.igor.motonav.nav

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

/**
 * One send at a time, and what goes out is always the newest value ("the last wins", C13b).
 *
 * It exists because of `WatchLink`'s queue (`sendMutex`): with a corridor chunk in the
 * air, a GPS fix waits a few seconds for its turn, and meanwhile others arrive.
 * Sending the whole queue afterwards would hand the watch old positions in a burst. Here
 * the value is only chosen **when the turn comes**: [sendTurn] receives a `take` and
 * calls it already holding the link.
 */
class LatestSender<T : Any>(
    scope: CoroutineScope,
    private val sendTurn: suspend (take: () -> T?) -> Unit,
) {
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val lock = Any()
    private var latest: T? = null

    init {
        scope.launch {
            for (ping in wake) {
                sendTurn(::take)
            }
        }
    }

    /** A new value: takes the place of the one still waiting. */
    fun offer(value: T) {
        synchronized(lock) { latest = value }
        wake.trySend(Unit)
    }

    /** Drops what was waiting for its turn (a send already in progress finishes). */
    fun clear() {
        synchronized(lock) { latest = null }
    }

    private fun take(): T? = synchronized(lock) { latest.also { latest = null } }
}
