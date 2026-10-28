package dev.igor.motonav.route

import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The whole [MapboxProvider], with OkHttp: only the network is swapped, by an interceptor ([answering]).
 * The response is `route_sample.json`, a **real** OSRM response, in the Directions format
 * (public places).
 */
class MapboxProviderTest {

    private val sample = File("../../tools/fixtures/route_sample.json").readText(Charsets.UTF_8)

    private val from = LatLng(-23.5614, -46.6559)
    private val to = LatLng(-23.6266, -46.6564)

    private fun servedBy(calls: AtomicInteger, body: () -> ResponseBody) =
        MapboxProvider({ "pk.teste" }, answering(calls, body = body))

    // prevents: an endless route, or a gzip that OkHttp opens by itself, becoming `OutOfMemoryError`: it is
    // an `Error`, goes through the attempts' `catch` and takes the app down, navigation included. And without the
    // other two attempts: the same route comes back at the same size.
    @Test
    fun `a route over the cap fails at once, without the retries`() {
        val calls = AtomicInteger()
        for ((what, served) in oversized(MapboxProvider.MAX_BODY_BYTES, sample)) {
            calls.set(0)
            try {
                runBlocking { servedBy(calls, served).route(from, null, to, emptyList()) }
                fail("$what: should have refused")
            } catch (e: RouteException) {
                assertTrue("$what: ${e.message}", "too large" in e.message!!)
            }
            assertEquals("$what: chamadas", 1, calls.get())
        }
        // And the real route goes through the same reading.
        val route = runBlocking { servedBy(calls) { sample.toResponseBody() }.route(from, null, to, emptyList()) }
        assertEquals(MapboxRouteParser.parse(sample).points, route.points)
    }

    // prevents: the reroute sending the bike down the Marginal express lane, forbidden to it (C16,
    // trip of 2026-10-20). In OSM that lane is `motorway`, and the request went out with no `exclude`.
    @Test
    fun `the route avoids motorways unless told otherwise`() {
        val avoided = MapboxProvider.directionsUrl(from, 90f, to, emptyList(), "TOKEN")
        assertTrue(avoided, "&exclude=motorway&" in avoided)
        assertTrue("o bearings continua inteiro", "bearings=90,45;&exclude" in avoided)

        val allowed = MapboxProvider.directionsUrl(from, null, to, emptyList(), "TOKEN", avoidMotorways = false)
        assertTrue(allowed, "exclude" !in allowed)
    }
}
