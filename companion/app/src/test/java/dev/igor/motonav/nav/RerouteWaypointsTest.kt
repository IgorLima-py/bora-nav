package dev.igor.motonav.nav

import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.MapboxProvider
import dev.igor.motonav.route.RouteResult
import dev.igor.motonav.share.Destination
import dev.igor.motonav.share.LinkResolver
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stops of a `dir/A/B/C` link survive the reroute (C11).
 *
 * Before C11 the `LinkResolver` returned only the last point, and a stop in the
 * middle vanished on the first route. Here the whole path is exercised without network:
 * link → resolver → session → "what is left" → the URL Mapbox receives.
 *
 * The coordinates are made up: Igor's addresses do not go into the repository.
 *
 * **Canary** (`./gradlew testDebugUnitTest -Pcanary`): throws away the `via` between
 * the resolver and the session, which is the pre-C11 defect. The second test has to
 * fail.
 */
class RerouteWaypointsTest {

    private val resolver = LinkResolver()
    private val canary = System.getProperty("motonav.canary") == "true"

    private val origin = LatLng(-23.561400, -46.655900)
    private val stopA = LatLng(-23.570000, -46.660000)
    private val stopB = LatLng(-23.590000, -46.640000)
    private val destination = LatLng(-23.626600, -46.656400)

    /** A waypoint in the Maps app format: `!1m5!1m4!1s<id>!8m2!3d<lat>!4d<lon>` (6 tokens). */
    private fun appBlock(point: LatLng, n: Int) =
        "!1m5!1m4!1s0x94ce$n:0x$n!8m2!3d%.6f!4d%.6f".format(Locale.US, point.lat, point.lon)

    /** The web format: `!1m<k>…!2m2!1d<lon>!2d<lat>` (also 6 tokens). */
    private fun webBlock(point: LatLng, n: Int) =
        "!1m5!1m4!1s0x94ce$n:0x$n!2m2!1d%.6f!2d%.6f".format(Locale.US, point.lon, point.lat)

    private fun dirLink(block: (LatLng, Int) -> String, vararg points: LatLng): String {
        val blocks = points.mapIndexed { i, p -> block(p, i + 1) }.joinToString("")
        // 6 tokens per waypoint + `!2m1!11b1` + `!3e9`: the `4m` counts the descendants.
        val inner = points.size * 6 + 3
        return "https://www.google.com/maps/dir/Origin/Stop+A/Stop+B/Destination/" +
            "data=!4m${inner + 1}!4m$inner$blocks!2m1!11b1!3e9"
    }

    private fun assertSame(expected: LatLng, got: LatLng) {
        assertEquals(expected.lat, got.lat, 1e-6)
        assertEquals(expected.lon, got.lon, 1e-6)
    }

    /** What the resolver hands to the app: the destination with the stops, or, in the canary, without them. */
    private fun resolved(url: String): Destination {
        val stops = resolver.stopsFrom(url)!!
        val kept = Destination(stops.last(), "Destino", via = stops.dropLast(1))
        return if (canary) kept.copy(via = emptyList()) else kept
    }

    /** A straight route north, 100 E5 units (~111 m) per point, 21 points. */
    private fun straightRoute(stopIdx: Int): RouteResult {
        val points = (0..20).map { PointE5(-2_356_000 + it * 100, -4_665_000) }
        return RouteResult(
            points = points,
            turns = emptyList(),
            distanceM = 2_226,
            durationS = 200,
            destName = "Destino",
            stopIdx = listOf(stopIdx),
        )
    }

    @Test
    fun dirLinkKeepsEveryStopInOrder() {
        val stops = resolver.stopsFrom(dirLink(::appBlock, origin, stopA, stopB, destination))!!

        assertEquals("origem ignorada: paradas + destino", 3, stops.size)
        assertSame(stopA, stops[0])
        assertSame(stopB, stops[1])
        assertSame(destination, stops[2])
    }

    @Test
    fun webFormatLinkKeepsEveryStopInOrderToo() {
        val stops = resolver.stopsFrom(dirLink(::webBlock, origin, stopA, destination))!!

        assertEquals(2, stops.size)
        assertSame(stopA, stops[0])
        assertSame(destination, stops[1])
    }

    @Test
    fun rerouteBeforeTheStopStillGoesThroughIt() {
        val dest = resolved(dirLink(::appBlock, origin, stopA, destination))
        val session = RerouteSession.of(routeId = 7, destination = dest, route = straightRoute(stopIdx = 10))

        // 500 m along: the stop is at ~1,113 m, still ahead.
        val via = session.remainingVia(distAlongM = 500)
        assertEquals("the stop must stay on the route", 1, via.size)
        assertSame(stopA, via[0])

        val url = MapboxProvider.directionsUrl(origin, 90f, dest.position, via, "TOKEN")
        val coordinates = url.substringAfter("driving-traffic/").substringBefore("?").split(";")
        assertEquals("origem; parada; destino", 3, coordinates.size)
        assertTrue(coordinates[1].startsWith("%.6f,%.6f".format(Locale.US, stopA.lon, stopA.lat)))
        assertTrue(url.contains("bearings=90,45;;"))
    }

    @Test
    fun rerouteAfterTheStopSkipsIt() {
        val dest = resolved(dirLink(::appBlock, origin, stopA, destination))
        val session = RerouteSession.of(routeId = 7, destination = dest, route = straightRoute(stopIdx = 10))

        // 1,100 m: the stop (~1,113 m) is less than 30 m away, the watch's `ARRIVAL_M`.
        assertEquals(emptyList<LatLng>(), session.remainingVia(distAlongM = 1_100))
        // And well past it, of course.
        assertEquals(emptyList<LatLng>(), session.remainingVia(distAlongM = 2_000))
    }
}
