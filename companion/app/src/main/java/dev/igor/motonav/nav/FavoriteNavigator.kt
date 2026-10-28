package dev.igor.motonav.nav

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.geo.KnownPosition
import dev.igor.motonav.proto.NavStartReq
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RouteProvider
import dev.igor.motonav.share.Destination
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * `NAV_START_REQ` from the watch (C12, RF-02): Igor chose a favorite, and the
 * phone routes from the current position to it **by the same path as the
 * share** (`ShareReceiverActivity.startRoute`): Mapbox, route send,
 * then the corridor, and the route becomes the C11 recalculation session.
 *
 * No screen: the request comes from the watch, with the phone in the pocket. Whatever fails here
 * only has the log as a voice, and the watch is left without a route (its screen reports no response).
 *
 * It only looks up the `favId` in the phone's storage — the coordinate never comes from the
 * watch — and **writes neither name nor coordinate to the log on its own** (the shared `MapboxProvider` still logs the route; see DECISIONS §C12) (`CLAUDE.md`: Igor's address
 * is sensitive data; `motonav.log` already holds too many destinations).
 *
 * Without a current position, it leaves from the last known one ([lastKnown], C16.5): with the app
 * off screen Fused may not answer, and the discarded request made the watch
 * give up after 20 s (`DECISIONS.md` §2026-10-16).
 *
 * Everything runs on the main thread (`Dispatchers.Main.immediate` in the app).
 */
class FavoriteNavigator(
    private val scope: CoroutineScope,
    private val find: (Int) -> Favorite?,
    /** The recent destinations, by the RECENTS list `id` (C16.5, `TripRecorder.recents`). */
    private val findRecent: (Int) -> Favorite? = { null },
    private val locate: suspend () -> LatLng?,
    private val provider: RouteProvider,
    private val nextRouteId: () -> Int,
    private val sendRoute: suspend (PackableRoute) -> Boolean,
    private val controller: RerouteController,
    private val lastKnown: () -> KnownPosition? = { null },
    private val now: () -> Long = System::currentTimeMillis,
    /** The provider's duration as it goes to the watch, times Igor's pace (C16, `TripRecorder.toWatchS`). */
    private val toWatchS: (Int) -> Int = { it },
) {

    private var job: Job? = null

    /** The last favorite wins: a new request drops whatever was in progress. */
    fun onNavStartReq(req: NavStartReq) {
        job?.cancel()
        job = scope.launch { start(req) }
    }

    private suspend fun start(req: NavStartReq) {
        val favId = req.favId
        // Only the id goes to the log, with the list it came from.
        val what = if (req.recent) "recent $favId" else "favId $favId"
        val favorite = if (req.recent) findRecent(favId) else find(favId)
        if (favorite == null) {
            EventLog.w(TAG, "NAV_START_REQ $what unknown: ignored")
            return
        }
        val lat = favorite.lat
        val lon = favorite.lon
        if (lat == null || lon == null) {
            EventLog.w(TAG, "NAV_START_REQ $what no place filled in: ignored")
            return
        }
        val startedAt = System.currentTimeMillis()
        NavActivityBus.calculating(favorite.name, fromWatch = true)
        try {
            val origin = locate() ?: lastKnown()?.let { known ->
                // The age and nothing more: the coordinate is where Igor goes.
                val ageMin = (now() - known.atMs).coerceAtLeast(0) / 60_000
                EventLog.w(TAG, "NAV_START_REQ $what no current position: leaves from the last known one, from $ageMin min ago")
                known.position
            }
            if (origin == null) {
                EventLog.w(TAG, "NAV_START_REQ $what no current or known position: ignored")
                return
            }
            val destination = Destination(LatLng(lat, lon), favorite.name)
            val result = provider.route(origin, null, destination.position, destination.via)
            val packable = result.toPackable(
                routeId = nextRouteId(),
                destNameOverride = destination.label,
                watchS = toWatchS(result.durationS),
            )
            EventLog.i(TAG, "route ${packable.routeId} of favorite $favId ready in ${System.currentTimeMillis() - startedAt} ms")

            // Only here are the previous route's recalculation and corridor dropped: if the
            // send dies, the old route keeps navigating and stays recalculable. The new one's corridor already
            // starts being fetched (C16.5).
            controller.supersede(packable)
            var sent = false
            NavActivityBus.sending(favorite.name, fromWatch = true)
            try {
                sent = sendRoute(packable)
            } finally {
                if (!sent) controller.endSupersede()
            }
            EventLog.i(
                TAG,
                "route ${packable.routeId} of favorite $favId ${if (sent) "sent" else "NOT sent"} " +
                    "in ${System.currentTimeMillis() - startedAt} ms",
            )
            if (sent) {
                controller.register(RerouteSession.of(packable.routeId, destination, result))
                controller.startCorridor(packable)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            EventLog.w(TAG, "navigation by favorite $favId failed: ${e.message}")
        } finally {
            NavActivityBus.idle()
        }
    }

    private companion object {
        const val TAG = "FavoriteNavigator"
    }
}
