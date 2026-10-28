package dev.igor.motonav.nav

import android.content.Context
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.corridor.AppRoads
import dev.igor.motonav.corridor.CorridorBuilder
import dev.igor.motonav.corridor.PardalSource
import dev.igor.motonav.corridor.RadarClient
import dev.igor.motonav.corridor.RadarStore
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.favorites.FavoritesStore
import dev.igor.motonav.geo.LastPositionStore
import dev.igor.motonav.geo.LocationSource
import dev.igor.motonav.link.WatchLink
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.route.MapboxProvider
import dev.igor.motonav.route.RoutePrefs
import dev.igor.motonav.settings.TokenStore
import dev.igor.motonav.trips.TripRecorder
import java.util.Calendar
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * The process's [RerouteController], wired to the watch link.
 *
 * A single one, like `WatchLink`: two instances would compete for the same `REROUTE_REQ`.
 * Lives as long as the process lives; what holds the process with the screen off is the
 * [NavForegroundService], which this hub turns on and off with the session (C13a).
 */
object RerouteHub {

    @Volatile
    private var controller: RerouteController? = null

    fun of(context: Context): RerouteController =
        controller ?: synchronized(this) {
            controller ?: build(context.applicationContext).also { controller = it }
        }

    private fun build(context: Context): RerouteController {
        val link = WatchLink.of(context)
        val tokens = TokenStore(context)
        val ids = RouteIds(context)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val location = LocationSource(context)
        val trips = TripRecorder.of(context)
        val radarStore = RadarStore.of(context)
        val pardal = PardalSource.of(context)

        // The phone's GPS as the watch's fallback (C13b). Only during a navigation
        // and when it can read the position with the phone in a pocket, which needs the
        // permission and the foreground service of type `location`.
        var navigating: () -> Boolean = { false }
        val phoneFix = PhoneFixFeed(
            scope = scope,
            updates = { location.updates() },
            whyNot = {
                when {
                    !navigating() -> "no navigation in progress"
                    !location.hasPermission() -> "no location permission"
                    !NavForegroundService.hasLocationType -> "the foreground service does not have the location type"
                    else -> null
                }
            },
            send = { take -> link.sendPhoneFix(take) },
            keepCoordinates = BuildConfig.CIQ_TETHERED,
        )
        val provider = MapboxProvider(
            tokenProvider = { tokens.mapboxToken },
            onRequest = { tokens.countRouteRequest(currentYearMonth()) },
            avoidMotorways = { RoutePrefs.avoidMotorways(context) },
        )
        val built = RerouteController(
            scope = scope,
            provider = provider,
            nextRouteId = { ids.next() },
            sendRoute = { route -> link.sendRoute(route) { } },
            buildCorridor = { route -> CorridorBuilder(AppRoads.of(context)).build(route) },
            sendCorridor = { route, corridor -> link.sendCorridor(route, corridor) },
            buildRadars = { route -> RadarClient(store = radarStore, pardal = pardal).fetch(route) },
            sendRadars = { route, radars -> link.sendRadars(route, radars) },
            cachedRadars = { route -> RadarClient(store = radarStore, pardal = pardal).cached(route) },
            sendRouteUpdate = { routeId, durationS -> link.sendRouteUpdate(routeId, durationS) },
            // The foreground service lives from the start to the end of the session (C13a).
            onSessionChanged = { session ->
                if (session != null) {
                    trips.onSessionStarted(session.destination, session.label, session.durationS, session.distanceM)
                    NavForegroundService.start(context, session.label)
                } else {
                    trips.onSessionEnded()
                    phoneFix.onSessionEnded()
                    NavForegroundService.stop()
                }
            },
            onRerouteStarted = { trips.onReroute() },
            toWatchS = { trips.toWatchS(it) },
        )
        navigating = { built.currentSession != null }
        link.onWatchLog = { line -> trips.onWatchLog(line) }
        link.onFixReq = { req -> scope.launch { phoneFix.onFixReq(req.on) } }
        link.onRerouteReq = { built.onRerouteReq(it) }
        link.onNavEnded = { reason ->
            // Arrived: the destination is where Igor (and the bike) are now, the best origin for the
            // next favorite if Fused does not answer (C16.5, `LastPositionStore`).
            val arrivedAt = built.currentSession?.destination?.takeIf { reason == Protocol.NAV_ENDED_ARRIVED }
            // Before the controller: the session end it signals would close the trip without the reason.
            trips.onNavEnded(reason)
            built.onNavEnded()
            arrivedAt?.let { LastPositionStore.of(context).save(it) }
            // The trip that just ended goes into "Recent" on the watch (C16.5). After the navigation, with the
            // link free: at its start, the list would share the radio with the route.
            scope.launch {
                val ok = link.sendRecents(trips.wireRecents())
                EventLog.i("RerouteHub", "recents sent at the end of the trip: $ok")
            }
        }

        // Favorites (C12): the watch asks for navigation by `favId`, and the list goes out again
        // every time it shows up connected (`04 §Favorites`).
        val favorites = FavoritesStore.of(context)
        val navigator = FavoriteNavigator(
            scope = scope,
            find = { favorites.find(it) },
            findRecent = { trips.recents().getOrNull(it) },
            locate = { location.current() },
            provider = provider,
            nextRouteId = { ids.next() },
            sendRoute = { route -> link.sendRoute(route) { } },
            controller = built,
            lastKnown = { location.lastKnown() },
            toWatchS = { trips.toWatchS(it) },
        )
        link.onNavStartReq = { navigator.onNavStartReq(it) }
        link.onWatchReady = {
            scope.launch {
                val ok = link.sendFavorites(favorites.wire())
                EventLog.i("RerouteHub", "favorites resent on connection: $ok")
                val recents = link.sendRecents(trips.wireRecents())
                EventLog.i("RerouteHub", "recents resent on connection: $recents")
            }
        }
        return built
    }

    private fun currentYearMonth(): String {
        val now = Calendar.getInstance()
        return "%04d-%02d".format(now.get(Calendar.YEAR), now.get(Calendar.MONTH) + 1)
    }
}

/** uint16 that grows with each route, as the protocol expects; 0 is reserved. */
class RouteIds(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences("motonav", Context.MODE_PRIVATE)

    fun next(): Int {
        val next = (prefs.getInt("routeId", 0) + 1) and 0xFFFF
        prefs.edit().putInt("routeId", next).apply()
        return if (next == 0) 1 else next
    }
}
