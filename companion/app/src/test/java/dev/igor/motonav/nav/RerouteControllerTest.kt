package dev.igor.motonav.nav

import dev.igor.motonav.corridor.OverpassException
import dev.igor.motonav.link.UpdateResult
import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.RerouteReq
import dev.igor.motonav.proto.WireRadar
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RouteProvider
import dev.igor.motonav.route.RouteResult
import dev.igor.motonav.share.Destination
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.yield
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The reroute controller, without network or clock: the fakes do not suspend, and `Unconfined` runs right away. */
class RerouteControllerTest {

    private class FakeProvider : RouteProvider {
        // Thread-safe list: the loop test reads from here while the tick runs on another.
        val calls = CopyOnWriteArrayList<Triple<LatLng, Float?, List<LatLng>>>()
        var durationS = 200
        var failure: Exception? = null

        /** With a gate, the query stays in flight until it opens; [heldAt] is the gate where the last one stopped. */
        @Volatile
        var gate: CompletableDeferred<Unit>? = null

        @Volatile
        var heldAt: CompletableDeferred<Unit>? = null

        override suspend fun route(from: LatLng, fromBearing: Float?, to: LatLng, via: List<LatLng>): RouteResult {
            calls += Triple(from, fromBearing, via)
            gate?.let {
                heldAt = it
                it.await()
            }
            failure?.let { throw it }
            return routeWithStops(via.size, durationS)
        }
    }

    private val stop = LatLng(-23.570000, -46.660000)
    private val destination = LatLng(-23.626600, -46.656400)
    private val provider = FakeProvider()
    private val sent = mutableListOf<PackableRoute>()
    private var nextId = 100
    private var sendOk = true

    /** The `ROUTE_UPDATE`s that went out (`routeId` and duration) and what the watch answers to each route. */
    private val updates = CopyOnWriteArrayList<Pair<Int, Int>>()
    private var watchAnswers: (Int) -> UpdateResult = { UpdateResult.DELIVERED }
    private var clockMs = 1_000_000L
    private val sessionChanges = mutableListOf<Int?>()

    /** The start of `routeWithStops`: its first point. */
    private val origin = LatLng(-23.56, -46.65)

    private fun controller(
        etaIntervalMs: Long = RerouteController.ETA_REFRESH_MS,
        now: () -> Long = { clockMs },
        send: suspend (PackableRoute) -> Boolean = { sent += it; sendOk },
        toWatchS: (Int) -> Int = { it },
    ) = RerouteController(
        scope = CoroutineScope(Dispatchers.Unconfined),
        provider = provider,
        nextRouteId = { nextId++ },
        sendRoute = send,
        buildCorridor = { null },
        sendCorridor = { _, _ -> true },
        retryDelayMs = 0,
        sendRouteUpdate = { routeId, durationS ->
            updates += routeId to durationS
            watchAnswers(routeId)
        },
        etaIntervalMs = etaIntervalMs,
        now = now,
        onSessionChanged = { sessionChanges += it?.routeId },
        toWatchS = toWatchS,
    ).also {
        it.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )
    }

    private fun request(routeId: Int = 7, distAlongM: Int = 500) =
        RerouteReq(routeId, latE5 = -2_356_500, lonE5 = -4_665_900, headingDeg = 90, distAlongM = distAlongM)

    @Test
    fun requestRecalculatesThroughTheRemainingStopAndRegistersTheNewRoute() {
        val controller = controller()

        controller.onRerouteReq(request())

        assertEquals(1, provider.calls.size)
        assertEquals(listOf(stop), provider.calls[0].third)
        assertEquals(90f, provider.calls[0].second)
        assertEquals(listOf(100), sent.map { it.routeId })
        assertEquals(100, controller.currentSession!!.routeId)
    }

    @Test
    fun requestAboutAnOlderRouteIsIgnored() {
        val controller = controller()

        controller.onRerouteReq(request(routeId = 6))

        assertTrue(provider.calls.isEmpty())
        assertTrue(sent.isEmpty())
    }

    @Test
    fun requestAfterNavEndedDoesNotReopenNavigation() {
        val controller = controller()

        controller.onNavEnded()
        controller.onRerouteReq(request())

        assertNull(controller.currentSession)
        assertTrue(provider.calls.isEmpty())
        assertTrue(sent.isEmpty())
    }

    @Test
    fun secondRequestOnTheOldIdAfterTheSwapIsIgnored() {
        val controller = controller()

        controller.onRerouteReq(request())
        controller.onRerouteReq(request())

        assertEquals("id 7 is no longer the current one", 1, provider.calls.size)
    }

    @Test
    fun requestWithTheOldIdAfterAFailedSendRecalculatesAgain() {
        val controller = controller()
        sendOk = false

        controller.onRerouteReq(request())
        // The watch did not adopt route 100: its retry is still for route 7.
        controller.onRerouteReq(request())

        assertEquals("the retry with the old id must be served", 2, provider.calls.size)
        assertEquals(listOf(100, 101), sent.map { it.routeId })
    }

    @Test
    fun supersedeKeepsTheSessionSoAShareThatNeverArrivedDoesNotKillReroute() {
        val controller = controller()

        controller.supersede()
        controller.endSupersede()
        controller.onRerouteReq(request())

        assertEquals(1, provider.calls.size)
        assertEquals(listOf(100), sent.map { it.routeId })
    }

    @Test
    fun shareThatCancelsARerouteMidSendAndThenFailsLeavesTheOldIdServed() {
        val gate = CompletableDeferred<Boolean>()
        val controller = controller(send = { sent += it; gate.await() })

        controller.onRerouteReq(request())
        assertTrue("the send of route 100 is in flight", controller.busy)
        controller.supersede()
        controller.endSupersede()
        // The watch never adopted 100: it keeps asking with id 7.
        controller.onRerouteReq(request())

        assertEquals("id 7 must still be served", 2, provider.calls.size)
    }

    @Test
    fun requestWhileAShareIsBeingSentIsIgnored() {
        val controller = controller()

        controller.supersede()
        controller.onRerouteReq(request())

        assertTrue("the share send and the reroute must not trample each other", provider.calls.isEmpty())
        assertTrue(sent.isEmpty())
    }

    // prevents: the ETA being requested by a path other than the route's (`remainingVia(0)` cuts the
    // stop less than 30 m from the start), and the watch showing the duration of a route it
    // does not have.
    @Test
    fun etaRefreshAsksForTheSameRouteAgainAndSendsTheNewDuration() {
        val controller = controller()
        provider.durationS = 260

        runBlocking { controller.refreshEta() }

        assertEquals(listOf<Any>(Triple(origin, null, listOf(stop))), provider.calls.toList())
        assertEquals(listOf(7 to 260), updates.toList())
        assertEquals(7, controller.currentSession!!.routeId)
        assertEquals("the session started and did not end", listOf<Int?>(7), sessionChanges)
    }

    // prevents: the 10-minute ROUTE_UPDATE and the reroute route taking Mapbox's car time to the watch and
    // undoing Igor's pace that went in the META (C16); and the pace entering the
    // session, where the silence math measures the route by the provider.
    @Test
    fun whatGoesToTheWatchCarriesThePaceAndTheSessionKeepsTheProviders() {
        val controller = controller(toWatchS = { it * 4 / 5 })
        provider.durationS = 260

        runBlocking { controller.refreshEta() }
        controller.onRerouteReq(request())

        assertEquals("the update, with the pace", listOf(7 to 208), updates.toList())
        assertEquals("the reroute's route, with the pace", 208, sent.single().durationS)
        assertEquals("the session keeps the provider's", 260, controller.currentSession!!.durationS)
    }

    // prevents: the reroute route, which was requested with the bike's heading, having its ETA redone without
    // heading: Mapbox could then start in the opposite direction and the duration belongs to another path.
    @Test
    fun etaRefreshAfterARerouteAsksWithTheBearingOfTheRequest() {
        val controller = controller()
        controller.onRerouteReq(request())

        runBlocking { controller.refreshEta() }

        assertEquals(Triple(origin, 90f, listOf(stop)), provider.calls[1])
        assertEquals(listOf(100 to 200), updates.toList())
    }

    // prevents: two sends to the watch at the same time (`WatchLink` has no lock): a
    // ROUTE_UPDATE in the middle of the transfer of a new route.
    @Test
    fun etaRefreshWaitsWhileAShareOrARerouteHoldsTheLink() {
        val gate = CompletableDeferred<Boolean>()
        val controller = controller(send = { sent += it; gate.await() })

        controller.supersede()
        runBlocking { controller.refreshEta() }
        assertTrue("with a share being sent, not even a query", provider.calls.isEmpty())
        controller.endSupersede()

        controller.onRerouteReq(request())
        assertTrue("the send of route 100 is in flight", controller.busy)
        runBlocking { controller.refreshEta() }

        assertEquals("only the reroute's query", 1, provider.calls.size)
        assertTrue(updates.isEmpty())
    }

    // prevents: `NAV_ENDED` getting lost on arrival and the session (with the foreground service
    // and the CPU awake) staying alive until the phone battery runs out.
    @Test
    fun aRefusedUpdateEndsTheSession() {
        val controller = controller()
        watchAnswers = { UpdateResult.REFUSED }

        runBlocking { controller.refreshEta() }

        assertNull(controller.currentSession)
        assertEquals("whoever runs the service learns of the end", listOf(7, null), sessionChanges)
    }

    // prevents: a reroute whose send did not complete leaving the phone on route 100 and the watch
    // on 7; the update of 100 is refused and the session died with the watch still navigating.
    @Test
    fun refusedOnTheNewRouteFallsBackToTheOneTheWatchStillNavigates() {
        val controller = controller()
        sendOk = false
        controller.onRerouteReq(request())
        assertEquals(100, controller.currentSession!!.routeId)
        watchAnswers = { if (it == 100) UpdateResult.REFUSED else UpdateResult.DELIVERED }

        runBlocking { controller.refreshEta() }

        assertEquals(listOf(100, 7), updates.map { it.first })
        assertEquals("the route the watch accepted is the current one", 7, controller.currentSession!!.routeId)
        assertEquals(listOf<Int?>(7), sessionChanges)
        sendOk = true
        controller.onRerouteReq(request())
        assertEquals("and its request is still served", listOf(100, 101), sent.map { it.routeId })
    }

    // prevents: a lost tick (watch out of range for a minute) taking the service down in the
    // middle of the trip; and the opposite, the watch off and the session alive forever.
    @Test
    fun aSilentWatchEndsTheSessionOnlyAfterTheArrivalTime() {
        val controller = controller()
        watchAnswers = { UpdateResult.SILENT }

        clockMs += 199_000
        runBlocking { controller.refreshEta() }
        assertNotNull("1 s was left to the arrival (200 s route)", controller.currentSession)

        clockMs += 2_000
        runBlocking { controller.refreshEta() }
        assertNull("1 s past the arrival time, no answer", controller.currentSession)
        assertEquals(listOf(7, null), sessionChanges)
    }

    // prevents: on a route shorter than the loop interval (10 min), a single tick without a response
    // (Bluetooth dropped that minute) ending the session with the rider still on the road: the service
    // goes down, and from then on no REROUTE_REQ or FIX_REQ is served (C13a, C13b edge).
    @Test
    fun oneUnansweredTickDoesNotEndTheSession() {
        val controller = controller()
        watchAnswers = { UpdateResult.SILENT }

        clockMs += 600_000 // the first tick: 10 min, three times the route's 200 s
        runBlocking { controller.refreshEta() }
        assertNotNull("a tick with no answer is a link drop, not the end of the trip", controller.currentSession)

        watchAnswers = { UpdateResult.DELIVERED }
        clockMs += 600_000
        runBlocking { controller.refreshEta() }
        assertNotNull("the watch answered", controller.currentSession)

        watchAnswers = { UpdateResult.SEND_FAILED }
        clockMs += 600_000
        runBlocking { controller.refreshEta() }
        assertNotNull("the middle answer reset the count", controller.currentSession)

        clockMs += 600_000
        runBlocking { controller.refreshEta() }
        assertNull("two ticks in a row with no answer, past the arrival time", controller.currentSession)
    }

    // prevents: the trip that took longer than planned being ended by the phone clock
    // with the wristwatch still navigating and responding.
    @Test
    fun aDeliveredUpdateKeepsTheSessionPastTheArrivalTime() {
        val controller = controller()

        clockMs += 3_600_000
        runBlocking { controller.refreshEta() }

        assertEquals(7, controller.currentSession!!.routeId)
        assertEquals(1, updates.size)
    }

    // prevents: past the arrival time (stopped to refuel), a failed Mapbox query
    // ending the session without even asking the watch, which kept navigating: the service went down and
    // every REROUTE_REQ from then on was ignored (C13a second opinion, finding 1). And the
    // Mapbox failure on the twelfth try throwing out of the loop (a loose exception in a `launch` takes the
    // process down) or becoming a ROUTE_UPDATE of invented duration.
    @Test
    fun aProviderFailurePastTheArrivalTimeStillAsksTheWatch() {
        val controller = controller()
        provider.failure = IOException("no network")

        clockMs += 3_600_000
        runBlocking { controller.refreshEta() }

        assertEquals("the watch is queried with the duration it already has", listOf(7 to 200), updates.toList())
        assertNotNull("the watch answered: the session stands", controller.currentSession)
    }

    // prevents: the arrival time counted from when the route went out, and not from the watch's last
    // response: after it a single update without an ACK took down the navigation the watch had
    // just confirmed (findings 1 and 3 of the second opinion).
    @Test
    fun theSilenceThatEndsTheSessionCountsFromTheLastAnswerOfTheWatch() {
        val controller = controller()

        clockMs += 250_000 // 50 s after the arrival time of the 200 s route
        runBlocking { controller.refreshEta() }
        assertNotNull("delivered: the watch navigates", controller.currentSession)

        watchAnswers = { UpdateResult.SILENT }
        clockMs += 100_000
        runBlocking { controller.refreshEta() }
        assertNotNull("100 s of silence on a 200 s route do not end it", controller.currentSession)

        clockMs += 101_000
        runBlocking { controller.refreshEta() }
        assertNull("201 s of silence: more than the whole route", controller.currentSession)
    }

    // prevents: the watch accepting the update of the route being prepared (a reroute that did not arrive
    // whole) and the phone dropping the route it actually navigates: its requests became
    // "the current one is another" and on the next tick the session ended (finding 2 of the second opinion).
    @Test
    fun bothRoutesStayWhileTheWatchAcceptsUpdatesForBoth() {
        val controller = controller()
        sendOk = false
        controller.onRerouteReq(request())
        sendOk = true

        runBlocking { controller.refreshEta() }

        assertEquals("asks about both", listOf(100, 7), updates.map { it.first })
        controller.onRerouteReq(request(routeId = 7))
        assertEquals("the old route's request is still served", listOf(100, 101), sent.map { it.routeId })
    }

    // prevents: the opposite of the above: continuing to serve requests for the old route after the
    // watch switches, with a `distAlong` that does not hold for the route it navigates.
    @Test
    fun theOldRouteIsDroppedWhenTheWatchRefusesIt() {
        val controller = controller()
        sendOk = false
        controller.onRerouteReq(request())
        sendOk = true
        watchAnswers = { if (it == 7) UpdateResult.REFUSED else UpdateResult.DELIVERED }

        runBlocking { controller.refreshEta() }
        val asked = provider.calls.size
        controller.onRerouteReq(request(routeId = 7))

        assertEquals(100, controller.currentSession!!.routeId)
        assertEquals("route 7 is nobody's any more", asked, provider.calls.size)
    }

    // prevents: the loop dying along with the query that a share cancelled (the new route
    // does not arrive, the old one stays valid and never gets an ETA again), and continuing to send
    // after `NAV_ENDED`.
    @Test
    fun theEtaLoopSurvivesACancelledRefreshAndStopsWhenNavigationEnds() {
        val firstTick = CompletableDeferred<Unit>()
        provider.gate = firstTick
        val controller = controller(etaIntervalMs = 40, now = System::currentTimeMillis)

        waitUntil("the first tick to be in flight") { provider.heldAt === firstTick }
        controller.supersede()
        assertTrue("the cancelled query does not become an update", updates.isEmpty())
        controller.endSupersede()
        // Opens the gate for the following ticks; the cancelled query no longer waits for it.
        firstTick.complete(Unit)
        waitUntil("the loop to go on after the cancelled query") { updates.isNotEmpty() }

        val lastTick = CompletableDeferred<Unit>()
        provider.gate = lastTick
        // Stopped at the new gate: the previous tick has already finished (the loop is one at a time).
        waitUntil("a query to be in flight") { provider.heldAt === lastTick }
        val delivered = updates.size
        val asked = provider.calls.size
        controller.onNavEnded()
        lastTick.complete(Unit)
        Thread.sleep(200) // five intervals of 40 ms

        assertEquals("no update after the end", delivered, updates.size)
        assertEquals("nem consulta", asked, provider.calls.size)
    }

    // prevents: Overpass only starting after the route finishes arriving at the watch, 2.4 to 3.6 s
    // more on every corridor (15/10 bench: Overpass started 14 ms after the TOTAL), and the
    // early search becoming an extra query instead of the 1st attempt.
    @Test
    fun theCorridorSearchStartsWhileTheRouteIsStillGoingToTheWatch() {
        val builds = mutableListOf<Int>()
        var buildsWhenSent = -1
        val controller = RerouteController(
            scope = CoroutineScope(Dispatchers.Unconfined),
            provider = provider,
            nextRouteId = { nextId++ },
            // The real send suspends waiting for the Bluetooth ACKs: that is where the search comes in.
            sendRoute = { yield(); buildsWhenSent = builds.size; true },
            buildCorridor = { builds += it.routeId; null },
            sendCorridor = { _, _ -> true },
            retryDelayMs = 0,
        )
        controller.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )

        controller.onRerouteReq(request())

        assertEquals("the corridor search had already started when the route went out", 1, buildsWhenSent)
        assertEquals(
            "the early one counts as the 1st of the ${RerouteController.CORRIDOR_ATTEMPTS} attempts",
            List(RerouteController.CORRIDOR_ATTEMPTS) { 100 },
            builds,
        )
    }

    // prevents: a street-source failure that escapes `CorridorBuilder` taking the companion down in the middle
    // of navigation. A giant tile's `OutOfMemoryError` is an `Error`, went through the early search's
    // `catch` and the `await` and left the `launch` with no handler: in the app, that closes the process.
    @Test
    fun aCorridorFailureNeverEscapesTheCorridorJob() {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val builds = mutableListOf<Int>()
        val controller = RerouteController(
            // The app scope (`RerouteHub`), with the handler in place of what Android would do: close.
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined + CoroutineExceptionHandler { _, e -> uncaught += e }),
            provider = provider,
            nextRouteId = { nextId++ },
            sendRoute = { true },
            buildCorridor = { builds += it.routeId; throw OutOfMemoryError("2 GB tile") },
            sendCorridor = { _, _ -> true },
            retryDelayMs = 0,
        )
        controller.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )

        controller.onRerouteReq(request())

        assertTrue("escaped from the corridor: $uncaught", uncaught.isEmpty())
        assertEquals("what escapes the CorridorBuilder is not repeated", listOf(100), builds)
        // Navigation continues: the next request for the new route is still served.
        controller.onRerouteReq(request(routeId = 100))
        assertEquals(listOf(100, 101), builds)
        assertTrue("escaped from the corridor: $uncaught", uncaught.isEmpty())
    }

    // prevents: the radars competing with the corridor for `WatchLink`, going out before it, or a radar
    // Overpass failure taking navigation down; and a route with no radar sending a message for nothing.
    @Test
    fun theRadarsFollowTheCorridorInTheSameJob() {
        val uncaught = CopyOnWriteArrayList<Throwable>()
        val order = mutableListOf<String>()
        var radarBuilds = 0
        var answer: () -> List<WireRadar> = { throw OverpassException("504") }
        val radar = WireRadar(distAlongM = 900, dLat = 10, dLon = 20, limitKmh = 50, flags = 1)
        val controller = RerouteController(
            scope = CoroutineScope(SupervisorJob() + Dispatchers.Unconfined + CoroutineExceptionHandler { _, e -> uncaught += e }),
            provider = provider,
            nextRouteId = { nextId++ },
            sendRoute = { true },
            buildCorridor = { PackableCorridor() },
            sendCorridor = { route, _ -> order += "corridor ${route.routeId}"; true },
            retryDelayMs = 0,
            buildRadars = { radarBuilds++; answer() },
            sendRadars = { route, radars -> order += "radars ${route.routeId} ${radars.size}"; true },
            radarDelaysMs = RerouteController.RADAR_RETRY_MS.map { 0L },
        )
        controller.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )

        controller.onRerouteReq(request())
        assertEquals("Overpass down: the attempts and nothing sent", RerouteController.RADAR_ATTEMPTS, radarBuilds)
        assertEquals(listOf("corridor 100"), order)
        assertTrue("escapou: $uncaught", uncaught.isEmpty())

        answer = { listOf(radar) }
        controller.onRerouteReq(request(routeId = 100))
        assertEquals(listOf("corridor 100", "corridor 101", "radars 101 1"), order)

        answer = { emptyList() }
        controller.onRerouteReq(request(routeId = 101))
        assertEquals("a route with no radar sends nothing", "corridor 102", order.last())
        assertTrue("escapou: $uncaught", uncaught.isEmpty())
    }

    // prevents: no radar on the wrist with Overpass down (2026-10-23: 502 and 504 on both attempts in
    // 25 s), even with that city's radars already downloaded on an earlier route.
    @Test
    fun theCacheCoversTheOverpassAndTheFreshAnswerReplacesIt() {
        val order = mutableListOf<String>()
        val cachedRadar = WireRadar(distAlongM = 900, dLat = 10, dLon = 20, limitKmh = 50, flags = 1)
        val freshRadar = WireRadar(distAlongM = 1500, dLat = 30, dLon = 40, limitKmh = 60, flags = 0)
        var builds = 0
        var answer: (Int) -> List<WireRadar> = { throw OverpassException("502 at capacity") }
        var cache: List<WireRadar> = listOf(cachedRadar)
        val controller = RerouteController(
            scope = CoroutineScope(Dispatchers.Unconfined),
            provider = provider,
            nextRouteId = { nextId++ },
            sendRoute = { true },
            buildCorridor = { PackableCorridor() },
            sendCorridor = { _, _ -> true },
            retryDelayMs = 0,
            buildRadars = { answer(++builds) },
            sendRadars = { route, radars -> order += "radars ${route.routeId} ${radars.map { it.distAlongM }}"; true },
            cachedRadars = { cache },
            radarDelaysMs = RerouteController.RADAR_RETRY_MS.map { 0L },
        )
        controller.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )

        // Overpass down the whole time: the cache goes once, and the attempts continue to the end.
        controller.onRerouteReq(request())
        assertEquals(RerouteController.RADAR_ATTEMPTS, builds)
        assertEquals(listOf("radars 100 [900]"), order)

        // Back on the 3rd attempt: the cache first, the new response after, which swaps the list.
        order.clear()
        builds = 0
        answer = { attempt -> if (attempt < 3) throw OverpassException("504") else listOf(freshRadar) }
        controller.onRerouteReq(request(routeId = 100))
        assertEquals(listOf("radars 101 [900]", "radars 101 [1500]"), order)

        // The new response equal to the cache does not send again.
        order.clear()
        builds = 0
        answer = { attempt -> if (attempt < 2) throw OverpassException("504") else listOf(cachedRadar) }
        controller.onRerouteReq(request(routeId = 101))
        assertEquals(listOf("radars 102 [900]"), order)

        // The cache sent a radar and the new response says there is none: the empty list erases the cache's.
        order.clear()
        builds = 0
        answer = { attempt -> if (attempt < 2) throw OverpassException("504") else emptyList() }
        controller.onRerouteReq(request(routeId = 102))
        assertEquals(listOf("radars 103 [900]", "radars 103 []"), order)

        // With nothing in the cache, the failure sends nothing.
        order.clear()
        builds = 0
        cache = emptyList()
        answer = { throw OverpassException("502") }
        controller.onRerouteReq(request(routeId = 103))
        assertTrue("empty cache sent: $order", order.isEmpty())
    }

    // prevents: the radars at the start of the route going by without warning while the corridor is still going (the list
    // arrived 16 to 46 s after the route, C16.7), even with them already downloaded on an earlier route.
    @Test
    fun theCachedRadarsGoBeforeTheCorridor() {
        val order = mutableListOf<String>()
        val cachedRadar = WireRadar(distAlongM = 300, dLat = 10, dLon = 20, limitKmh = 50, flags = 1)
        val freshRadar = WireRadar(distAlongM = 1500, dLat = 30, dLon = 40, limitKmh = 60, flags = 0)
        val controller = RerouteController(
            scope = CoroutineScope(Dispatchers.Unconfined),
            provider = provider,
            nextRouteId = { nextId++ },
            sendRoute = { true },
            buildCorridor = { PackableCorridor() },
            sendCorridor = { route, _ -> order += "corridor ${route.routeId}"; true },
            retryDelayMs = 0,
            buildRadars = { listOf(cachedRadar, freshRadar) },
            sendRadars = { route, radars -> order += "radars ${route.routeId} ${radars.map { it.distAlongM }}"; true },
            cachedRadars = { listOf(cachedRadar) },
            radarDelaysMs = RerouteController.RADAR_RETRY_MS.map { 0L },
        )
        controller.register(
            RerouteSession.of(7, Destination(destination, "Destino", via = listOf(stop)), routeWithStops(1)),
        )

        controller.onRerouteReq(request())
        assertEquals(listOf("radars 100 [300]", "corridor 100", "radars 100 [300, 1500]"), order)
    }

    private fun waitUntil(what: String, condition: () -> Boolean) = runBlocking {
        // 5 s: leaves room for a 40 ms tick on a loaded test JVM.
        try {
            withTimeout(5_000) {
                while (!condition()) {
                    delay(5)
                }
            }
        } catch (e: TimeoutCancellationException) {
            throw AssertionError("esperando $what")
        }
    }

    private companion object {
        /** A straight route of 21 points, with [stops] stops at point 10. */
        fun routeWithStops(stops: Int, durationS: Int = 200) = RouteResult(
            points = (0..20).map { PointE5(-2_356_000 + it * 100, -4_665_000) },
            turns = emptyList(),
            distanceM = 2_226,
            durationS = durationS,
            destName = "Destino",
            stopIdx = List(stops) { 10 },
        )
    }
}
