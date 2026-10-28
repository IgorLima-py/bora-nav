package dev.igor.motonav.nav

import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.geo.KnownPosition
import dev.igor.motonav.proto.NavStartReq
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.RerouteReq
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RouteProvider
import dev.igor.motonav.route.RouteResult
import dev.igor.motonav.share.Destination
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `NAV_START_REQ` on the phone (C12): the watch picked a favorite, the phone
 * routes from the current position to it through the same path as sharing.
 * No network or watch: the fakes do not suspend and `Unconfined` runs right away.
 */
class FavoriteNavigatorTest {

    private class FakeProvider : RouteProvider {
        val calls = mutableListOf<Triple<LatLng, LatLng, List<LatLng>>>()

        override suspend fun route(from: LatLng, fromBearing: Float?, to: LatLng, via: List<LatLng>): RouteResult {
            calls += Triple(from, to, via)
            return straightRoute("from Mapbox")
        }
    }

    private val copan = Favorite(id = 1, name = "Copan", lat = -23.54522, lon = -46.64218, icon = 2)
    private val seed = Favorite(id = 9, name = "Casa") // no place
    private val recentMasp = Favorite(id = 0, name = "MASP", lat = -23.5614, lon = -46.6559)
    private val here = LatLng(-23.5629, -46.6544)
    private val provider = FakeProvider()
    private val sent = mutableListOf<PackableRoute>()
    private var sendOk = true
    private var position: LatLng? = here
    private var known: KnownPosition? = null
    private var nextId = 100

    private val controller = RerouteController(
        scope = CoroutineScope(Dispatchers.Unconfined),
        provider = provider,
        nextRouteId = { nextId++ },
        sendRoute = { sent += it; sendOk },
        buildCorridor = { null },
        sendCorridor = { _, _ -> true },
        retryDelayMs = 0,
    ).also {
        // an earlier navigation in progress: route 7, to the "Destino"
        it.register(RerouteSession.of(7, Destination(LatLng(-23.6266, -46.6564), "Destino"), straightRoute("Destino")))
    }

    private val navigator = FavoriteNavigator(
        scope = CoroutineScope(Dispatchers.Unconfined),
        find = { id -> listOf(copan, seed).firstOrNull { it.id == id } },
        findRecent = { id -> listOf(recentMasp).getOrNull(id) },
        locate = { position },
        provider = provider,
        nextRouteId = { nextId++ },
        sendRoute = { sent += it; sendOk },
        controller = controller,
        lastKnown = { known },
        now = { 1_000_000_000L },
    )

    private fun reroute(routeId: Int) =
        RerouteReq(routeId, latE5 = -2_356_500, lonE5 = -4_665_900, headingDeg = 90, distAlongM = 500)

    // prevents: favorite navigation coming out with the wrong destination or name (the watch would show
    // "from Mapbox" instead of "Copan") or not becoming the current session (the C11 reroute would ask for a
    // route to the old destination).
    @Test
    fun `a known favorite is routed from here and becomes the session`() {
        navigator.onNavStartReq(NavStartReq(favId = 1))

        assertEquals(1, provider.calls.size)
        assertEquals(here, provider.calls[0].first)
        assertEquals(LatLng(-23.54522, -46.64218), provider.calls[0].second)
        assertTrue("no stops", provider.calls[0].third.isEmpty())
        assertEquals(listOf(100), sent.map { it.routeId })
        assertEquals("Copan", sent[0].destName)
        assertEquals(100, controller.currentSession!!.routeId)
        assertEquals("Copan", controller.currentSession!!.label)
    }

    // prevents: picking "MASP" in Recents (C16.5) and the phone routing to the favorite with the same number,
    // or the other way around: the two lists have their own ids, and the NAV_START_REQ `kind` says which.
    @Test
    fun `a recent is looked up in the recents, never in the favorites`() {
        navigator.onNavStartReq(NavStartReq(favId = 1, kind = Protocol.NAV_START_KIND_RECENT))
        assertTrue("there is no recent 1, even with a favorite 1", provider.calls.isEmpty())

        navigator.onNavStartReq(NavStartReq(favId = 0, kind = Protocol.NAV_START_KIND_RECENT))
        assertEquals(LatLng(-23.5614, -46.6559), provider.calls.single().second)
        assertEquals("MASP", sent.single().destName)
    }

    // prevents: a favorite deleted on the phone while the watch still listed it generating a route to
    // nowhere — or, worse, tearing down the navigation that was already up.
    @Test
    fun `an unknown favorite changes nothing`() {
        navigator.onNavStartReq(NavStartReq(favId = 42))

        assertTrue(provider.calls.isEmpty())
        assertTrue(sent.isEmpty())
        assertEquals(7, controller.currentSession!!.routeId)
    }

    // prevents: seed "Casa" without a coordinate becoming a route to (0, 0) if a NAV_START_REQ arrives
    // with its id (watch with a stale list).
    @Test
    fun `a favorite without a place is ignored`() {
        navigator.onNavStartReq(NavStartReq(favId = 9))

        assertTrue(provider.calls.isEmpty())
        assertEquals(7, controller.currentSession!!.routeId)
    }

    // prevents: without a position, the phone asking for a route "from nowhere" or dropping the current navigation.
    @Test
    fun `without a position nothing is requested and the old session stays`() {
        position = null

        navigator.onNavStartReq(NavStartReq(favId = 1))

        assertTrue(provider.calls.isEmpty())
        assertTrue(sent.isEmpty())
        assertEquals(7, controller.currentSession!!.routeId)
    }

    // prevents: on 2026-10-16 the first favorite requested with the phone app off screen was discarded
    // ("NAV_START_REQ favId 4 no current position: ignored") and the watch gave up in 20 s.
    @Test
    fun `without a current position the last known one is the origin`() {
        position = null
        val parked = LatLng(-23.5505, -46.6333)
        known = KnownPosition(parked, atMs = 1_000_000_000L - 3 * 60 * 60_000L)

        navigator.onNavStartReq(NavStartReq(favId = 1))

        assertEquals(1, provider.calls.size)
        assertEquals(parked, provider.calls[0].first)
        assertEquals(listOf(100), sent.map { it.routeId })
        assertEquals("Copan", controller.currentSession!!.label)
    }

    // prevents: the send failing and the old route being left without recalculation forever — the sharing
    // `supersede` has to be undone (the same rule as ShareReceiverActivity).
    @Test
    fun `a failed send leaves the old session recalculable`() {
        sendOk = false

        navigator.onNavStartReq(NavStartReq(favId = 1))
        provider.calls.clear()
        controller.onRerouteReq(reroute(7))

        assertEquals("the reroute of route 7 still works", 1, provider.calls.size)
        assertNull("the favorite's route did not become a session", controller.currentSession?.takeIf { it.label == "Copan" })
    }

    private companion object {
        /** A straight route of 21 points, no stops. */
        fun straightRoute(name: String) = RouteResult(
            points = (0..20).map { PointE5(-2_356_000 + it * 100, -4_665_000) },
            turns = emptyList(),
            distanceM = 2_226,
            durationS = 200,
            destName = name,
        )
    }
}
