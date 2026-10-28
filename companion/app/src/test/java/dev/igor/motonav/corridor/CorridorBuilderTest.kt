package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.Turn
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `CorridorBuilder` is the corridor piece with no byte-for-byte fixture: it decides
 * what **goes into** the map, and getting it wrong breaks nothing — it just produces a
 * silently wrong corridor (too many streets, too few, or the whole city).
 * So the tests attack the decisions, not the format.
 */
class CorridorBuilderTest {

    // The tests here build the corridor with `assemble`, with no network; the source only exists for `build`.
    private val builder = CorridorBuilder { emptyList() }

    /** A straight route heading north, ~1.1 m per 1e-5 degree step. */
    private fun straightRoute(points: Int = 200): PackableRoute = PackableRoute(
        routeId = 1,
        points = (0 until points).map { PointE5(LAT0 + it * 10, LON0) },
        turns = listOf(Turn(0, Protocol.TURN_DEPART, "Origem")),
        distanceM = 2000,
        durationS = 300,
        destName = "Destino",
    )

    private fun plane() = LocalPlane(LAT0, LON0)

    /**
     * **The 2026-08-01 regression, turned into a test.**
     *
     * The phone log said `teto do corredor: LOD 3 (439 ways) descartado` in
     * four shares in a row. LOD 3 is `residential` — the neighborhood street
     * mesh, the one that answers "is it this turn or the next?". Igor got
     * only avenues and reported exactly that: *"aparece só algumas ruas"*.
     *
     * This test builds a city that **does not fit** under the cap and demands that, of what
     * survives, the local mesh hugging the route is there. The cut criterion is
     * geographic, not by class.
     */
    @Test
    fun `over the cap it drops the far streets, never the local mesh`() {
        val route = straightRoute(400)
        val plane = plane()
        val ways = mutableListOf<OsmWay>()

        // Dense mesh on both sides of the route, from touching (~11 m) to the edge
        // of the corridor (~290 m), along its whole length. All of it **inside**
        // the band on purpose: if some way were clipped by distance, the
        // test would pass for the wrong reason — it would prove the clipping, not the cap.
        for (step in 0 until 400) {
            for (offset in listOf(10, 40, 70, 100, 130, 160, 190, 220, 250, 280)) {
                ways += OsmWay(
                    "residential",
                    listOf(
                        PointE5(LAT0 + step * 10, LON0 + offset),
                        PointE5(LAT0 + step * 10 + 40, LON0 + offset),
                    ),
                )
            }
        }
        // More avenues than any real city, so the cap really bites.
        for (step in 0 until 400 step 4) {
            ways += OsmWay(
                "secondary",
                listOf(PointE5(LAT0 + step * 10, LON0 - 50), PointE5(LAT0 + step * 10 + 60, LON0 - 50)),
            )
        }

        val corridor = builder.assemble(ways, route, plane)

        assertTrue(
            "the cap must have tightened, otherwise the test proves nothing",
            ways.size > corridor.ways.sumOf { it.size },
        )
        assertTrue(
            "the local mesh survived the cap: ${corridor.ways[Protocol.LOD_LOCAL].size} ways",
            corridor.ways[Protocol.LOD_LOCAL].isNotEmpty(),
        )
        assertTrue("and the corridor fits under the cap", corridor.segmentCount() <= Protocol.MAX_CORRIDOR_SEGMENTS)

        // What is left has to be what is NEAR. The proof: the mean distance
        // of the kept locals is well below the corridor width.
        val offsets = corridor.ways[Protocol.LOD_LOCAL].map { way ->
            Math.abs(way.first().lon - LON0)
        }
        val mean = offsets.average()
        assertTrue("the kept local streets are the ones hugging the route (mean offset $mean)", mean < 150.0)
    }

    /**
     * The other side: when everything fits, nothing is cut. A cap that cuts
     * any which way would just be the silent version of the earlier bug.
     */
    @Test
    fun `under the cap nothing is dropped`() {
        val route = straightRoute()
        val plane = plane()
        val ways = (0 until 20).map { i ->
            OsmWay(
                "residential",
                listOf(PointE5(LAT0 + i * 50, LON0 + 50), PointE5(LAT0 + i * 50 + 40, LON0 + 50)),
            )
        }

        val corridor = builder.assemble(ways, route, plane)

        assertEquals(20, corridor.ways[Protocol.LOD_LOCAL].size)
    }

    @Test
    fun `classifies OSM highway tags into the four LODs`() {
        assertEquals(Protocol.LOD_EXPRESS, builder.lodOf("motorway"))
        assertEquals(Protocol.LOD_EXPRESS, builder.lodOf("trunk_link"))
        assertEquals(Protocol.LOD_ARTERIAL, builder.lodOf("secondary"))
        assertEquals(Protocol.LOD_COLLECTOR, builder.lodOf("tertiary"))
        assertEquals(Protocol.LOD_LOCAL, builder.lodOf("residential"))
        // Not every `highway` is a street for a motorcycle: trail and sidewalk are left out.
        assertNull(builder.lodOf("footway"))
        assertNull(builder.lodOf("cycleway"))
        assertNull(builder.lodOf("service"))
    }

    @Test
    fun `keeps streets inside the corridor and drops the far ones`() {
        val route = straightRoute()
        val plane = plane()
        val near = OsmWay("residential", listOf(PointE5(LAT0 + 500, LON0), PointE5(LAT0 + 500, LON0 + 100)))
        // ~2 km to the east: far beyond the band's 300 m.
        val far = OsmWay("residential", listOf(PointE5(LAT0 + 500, LON0 + 2000), PointE5(LAT0 + 500, LON0 + 2100)))

        val corridor = builder.assemble(listOf(near, far), route, plane)

        assertEquals(1, corridor.ways[Protocol.LOD_LOCAL].size)
    }

    @Test
    fun `a street crossing the corridor twice becomes two ways`() {
        val route = straightRoute()
        val plane = plane()
        // Goes from far away (east) until it crosses the route, exits to the west and comes back.
        val zigzag = OsmWay(
            "secondary",
            listOf(
                PointE5(LAT0 + 400, LON0 + 3000), // outside
                PointE5(LAT0 + 400, LON0), // inside
                PointE5(LAT0 + 600, LON0 + 3000), // outside
                PointE5(LAT0 + 800, LON0 + 3000), // outside
                PointE5(LAT0 + 800, LON0), // inside
                PointE5(LAT0 + 900, LON0 + 3000), // outside
            ),
        )

        val corridor = builder.assemble(listOf(zigzag), route, plane)

        assertEquals("each entry into the band becomes a way", 2, corridor.ways[Protocol.LOD_ARTERIAL].size)
    }

    @Test
    fun `clipping keeps one point past each end so the street does not die on the border`() {
        val route = straightRoute()
        val plane = plane()
        val proximity = RouteProximity(
            DoubleArray(route.points.size) { plane.x(route.points[it]) },
            DoubleArray(route.points.size) { plane.y(route.points[it]) },
            listOf(0),
        )
        val points = listOf(
            PointE5(LAT0 + 400, LON0 + 3000), // outside
            PointE5(LAT0 + 400, LON0 + 100), // inside
            PointE5(LAT0 + 400, LON0 - 100), // inside
            PointE5(LAT0 + 400, LON0 - 3000), // outside
        )

        val runs = builder.clip(points, plane, proximity)

        assertEquals(1, runs.size)
        assertEquals("the two outside points come along", 4, runs[0].size)
    }

    @Test
    fun `very short streets are dropped`() {
        val route = straightRoute()
        // ~5 m: below the 20 m that 04 §3.4 says to discard.
        val stub = OsmWay("residential", listOf(PointE5(LAT0 + 500, LON0), PointE5(LAT0 + 505, LON0)))

        val corridor = builder.assemble(listOf(stub), route, plane())

        assertEquals(0, corridor.segmentCount())
    }

    @Test
    fun `simplification drops collinear points but keeps the shape`() {
        val route = straightRoute()
        // 60 points on a perfect east-west line, crossing the route.
        val straight = OsmWay(
            "primary",
            (0 until 60).map { PointE5(LAT0 + 500, LON0 - 300 + it * 10) },
        )

        val corridor = builder.assemble(listOf(straight), route, plane())
        val way = corridor.ways[Protocol.LOD_ARTERIAL].single()

        assertEquals("a straight line fits in two points", 2, way.size)
        assertEquals(PointE5(LAT0 + 500, LON0 - 300), way.first())
        assertEquals("the endpoint does not move", PointE5(LAT0 + 500, LON0 - 300 + 59 * 10), way.last())
    }

    @Test
    fun `ways come ordered by how close they are to the start of the route`() {
        val route = straightRoute()
        val far = OsmWay("residential", listOf(PointE5(LAT0 + 1500, LON0 - 100), PointE5(LAT0 + 1500, LON0 + 100)))
        val near = OsmWay("residential", listOf(PointE5(LAT0 + 100, LON0 - 100), PointE5(LAT0 + 100, LON0 + 100)))

        val corridor = builder.assemble(listOf(far, near), route, plane())
        val ways = corridor.ways[Protocol.LOD_LOCAL]

        assertEquals(2, ways.size)
        assertTrue("the street near the start comes first", ways[0].first().lat < ways[1].first().lat)
    }

    @Test
    fun `the maneuver radius is wider than the plain corridor`() {
        val plane = plane()
        val route = straightRoute().copy(
            turns = listOf(Turn(100, Protocol.TURN_RIGHT, "Cruzamento")),
        )
        // ~410 m east of the route: outside the ordinary band's 300 m, inside the 600 m
        // that apply around a maneuver. The two streets are identical in shape;
        // the only difference is whether or not they are at the height of the turn (point 100).
        val atManeuver = OsmWay(
            "residential",
            listOf(
                PointE5(LAT0 + 950, LON0 + 400),
                PointE5(LAT0 + 1000, LON0 + 400),
                PointE5(LAT0 + 1050, LON0 + 400),
            ),
        )
        val awayFromIt = OsmWay(
            "residential",
            listOf(
                PointE5(LAT0 + 150, LON0 + 400),
                PointE5(LAT0 + 200, LON0 + 400),
                PointE5(LAT0 + 250, LON0 + 400),
            ),
        )

        assertEquals(1, builder.assemble(listOf(atManeuver), route, plane).ways[Protocol.LOD_LOCAL].size)
        assertEquals(0, builder.assemble(listOf(awayFromIt), route, plane).ways[Protocol.LOD_LOCAL].size)
    }

    @Test
    fun `the query polygon stays inside the Overpass vertex budget`() {
        // Long route: 3,000 points, ~33 km. This is where the polygon would blow up.
        val long = straightRoute(points = 3000)
        val polygon = builder.bufferPolygon(long, LocalPlane(LAT0, LON0))

        assertTrue("polygon with ${polygon.size} vertices", polygon.size <= OverpassClient.MAX_POLY_VERTICES)
        assertTrue("and closed on both sides", polygon.size >= 4)
        assertEquals("one vertex on each side per spine point", 0, polygon.size % 2)
    }

    @Test
    fun `the query polygon wraps the whole route with margin`() {
        val route = straightRoute()
        val plane = plane()
        val polygon = builder.bufferPolygon(route, plane)

        // The polygon has to cover from the first to the last point of the route.
        val minLat = polygon.minOf { it.lat }
        val maxLat = polygon.maxOf { it.lat }
        assertTrue(minLat <= route.points.first().lat)
        assertTrue(maxLat >= route.points.last().lat)

        // And open to the sides by at least the real corridor.
        val widest = polygon.maxOf { kotlin.math.abs(plane.x(it)) }
        assertTrue("opened $widest m to the side", widest >= RouteProximity.CORRIDOR_M)
    }

    @Test
    fun `the Overpass query asks only for the road classes we draw`() {
        val query = OverpassClient().buildQuery(
            listOf(PointE5(LAT0, LON0), PointE5(LAT0 + 100, LON0), PointE5(LAT0, LON0 + 100)),
        )

        assertTrue(query.contains("[out:json]"))
        assertTrue(query.contains("out geom;"))
        assertTrue(query.contains("motorway"))
        assertTrue(query.contains("residential"))
        assertTrue("pedestrian path is not in the query", !query.contains("footway"))
        // The poly: uses degrees, not protocol units.
        assertTrue(query.contains("-23.56145"))
    }

    @Test
    fun `the Overpass parser skips elements without geometry or highway tag`() {
        val body = """
            {"elements":[
              {"type":"way","tags":{"highway":"residential"},"geometry":[{"lat":-23.5,"lon":-46.6},{"lat":-23.51,"lon":-46.6}]},
              {"type":"way","tags":{"highway":"residential"}},
              {"type":"way","geometry":[{"lat":-23.5,"lon":-46.6},{"lat":-23.51,"lon":-46.6}]},
              {"type":"way","tags":{"highway":"primary"},"geometry":[{"lat":-23.5,"lon":-46.6}]},
              {"type":"node","id":1}
            ]}
        """.trimIndent()

        val ways = OverpassClient().parse(body)

        assertEquals(1, ways.size)
        assertEquals("residential", ways[0].highway)
        // Same rounding as packer.py: half goes away from zero.
        assertEquals(PointE5(-2350000, -4660000), ways[0].points[0])
    }

    @Test
    fun `overpass coordinates quantize exactly like the python packer`() {
        assertEquals(-2355050, OverpassClient.quantize(-23.5505047))
        assertEquals(2350001, OverpassClient.quantize(23.500005))
        assertEquals(0, OverpassClient.quantize(0.0))
    }

    @Test
    fun `douglas peucker drops wiggle under the epsilon`() {
        // Meanders ±1 m on a 40 m straight line: within the 3 m ε, it all disappears.
        val xs = doubleArrayOf(0.0, 10.0, 20.0, 30.0, 40.0)
        val ys = doubleArrayOf(0.0, 1.0, -1.0, 1.0, 0.0)

        assertEquals(listOf(0, 4), Simplify.douglasPeucker(xs, ys, 3.0).toList())
    }

    @Test
    fun `douglas peucker keeps a real corner`() {
        // A 90° corner: the middle vertex is the information, it cannot disappear.
        val xs = doubleArrayOf(0.0, 10.0, 20.0)
        val ys = doubleArrayOf(0.0, 0.0, 20.0)

        assertEquals(listOf(0, 1, 2), Simplify.douglasPeucker(xs, ys, 3.0).toList())
    }

    @Test
    fun `a route with a single point yields no corridor`() {
        val degenerate = straightRoute().copy(points = listOf(PointE5(LAT0, LON0)))
        val corridor = kotlinx.coroutines.runBlocking { builder.build(degenerate) }
        assertNull(corridor)
    }

    @Test
    fun `an Overpass failure never breaks the route`() {
        val failing = object : OverpassClient() {
            override suspend fun fetch(polygon: List<PointE5>): List<OsmWay> =
                throw OverpassException("server down")
        }
        val corridor = kotlinx.coroutines.runBlocking { CorridorBuilder(failing).build(straightRoute()) }

        // null = "carry on without a corridor", which is the behavior of 04 §3.7.
        assertNull(corridor)
    }

    /**
     * **The real cause of the corridor never having appeared.** `overpass-api.de`
     * blocks the libraries' default User-Agent: with `okhttp/4.12.0` the
     * response is HTTP 406 and an Apache HTML page; with a descriptive agent, 200 —
     * same query, same minute (measured on 2026-07-31, `DECISIONS.md`).
     *
     * The test looks at the real request, not the constant: swapping the header by
     * mistake is precisely the kind of regression that disappears for four street tests.
     */
    @Test
    fun `the Overpass request carries an identifiable User-Agent`() {
        val request = OverpassClient().buildRequest(OverpassClient.DEFAULT_ENDPOINT, "[out:json];out;")
        val agent = request.header("User-Agent")

        assertNotNull("the request needs an explicit User-Agent", agent)
        assertTrue("descreve o app", agent!!.startsWith("BoraNav/"))
        assertTrue("not the library default", !agent.contains("okhttp", ignoreCase = true))
    }

    /**
     * The ladder of deadlines: **server < read < call**, each step larger than
     * the previous one. Two real defects live here.
     *
     * The first: OkHttp gives up at 10 s by default and the query asked the
     * server for 25 s — the client cut it off before the server was allowed to finish.
     *
     * The second, measured in the 5th test: `withTimeoutOrNull` around a blocking
     * `execute()` **interrupts nothing**, and `CorridorBuilder`'s "15 s deadline"
     * let a query run for 33 s. What really enforces a deadline is OkHttp's `callTimeout` —
     * which is why the test demands that it exists
     * and is the top step.
     */
    @Test
    fun `the timeout ladder goes server then read then whole call`() {
        val client = OverpassClient.defaultClient()

        assertTrue(
            "server ${OverpassClient.TIMEOUT_S}s < read ${OverpassClient.READ_TIMEOUT_S}s",
            OverpassClient.TIMEOUT_S < OverpassClient.READ_TIMEOUT_S,
        )
        assertTrue(
            "leitura ${OverpassClient.READ_TIMEOUT_S}s < chamada ${OverpassClient.CALL_TIMEOUT_S}s",
            OverpassClient.READ_TIMEOUT_S < OverpassClient.CALL_TIMEOUT_S,
        )
        assertEquals(OverpassClient.READ_TIMEOUT_S, client.readTimeoutMillis / 1000L)
        assertEquals(
            "without callTimeout there is no deadline at all: the rest is blocking",
            OverpassClient.CALL_TIMEOUT_S,
            client.callTimeoutMillis / 1000L,
        )
    }

    /**
     * **A regional mirror does not belong in the list.**
     *
     * `overpass.osm.ch` once was the main mirror because it answered
     * 200 in 0.7 s — and returned **zero ways** in São Paulo, because it only carries
     * Switzerland. Since the hedge keeps the first one that answers, it won with an
     * empty list and cancelled `overpass-api.de`, which worked. The corridor
     * vanished with no error anywhere.
     *
     * This test cannot measure coverage (there is no network here) — `tools/check_overpass.py`
     * does. What it does is keep an already
     * rejected mirror from coming back by mistake.
     */
    @Test
    fun `no region locked Overpass mirror is configured`() {
        val regionLocked = listOf("osm.ch", "osm.jp", "osm.fr")
        for (endpoint in OverpassClient.DEFAULT_ENDPOINTS) {
            for (region in regionLocked) {
                assertTrue(
                    "$endpoint is a regional mirror — measured fast and returned empty (see check_overpass.py)",
                    !endpoint.contains(region),
                )
            }
        }
        assertTrue("there is more than one planet mirror", OverpassClient.DEFAULT_ENDPOINTS.size >= 2)
        assertTrue(
            "the mirrors do not repeat",
            OverpassClient.DEFAULT_ENDPOINTS.toSet().size == OverpassClient.DEFAULT_ENDPOINTS.size,
        )
    }

    /**
     * An empty corridor is a mirror failure, not a result. A car route always
     * has streets around it; zero ways means "this server does not have this
     * region", and the next mirror has to be tried.
     */
    @Test
    fun `an empty answer is treated as a failed mirror`() {
        val empty = object : OverpassClient() {
            override suspend fun fetch(polygon: List<PointE5>): List<OsmWay> = emptyList()
        }
        val corridor = kotlinx.coroutines.runBlocking { CorridorBuilder(empty).build(straightRoute()) }
        assertNull("no ways means no corridor, and the log must say so", corridor)
    }

    @Test
    fun `a well formed corridor survives the whole chain`() {
        val ways = (0 until 20).map { i ->
            OsmWay(
                if (i % 4 == 0) "primary" else "residential",
                listOf(PointE5(LAT0 + i * 80, LON0 - 200), PointE5(LAT0 + i * 80, LON0 + 200)),
            )
        }
        val corridor = builder.assemble(ways, straightRoute(), plane())

        assertNotNull(corridor)
        assertEquals(20, corridor.segmentCount())
        assertEquals(5, corridor.ways[Protocol.LOD_ARTERIAL].size)
        assertEquals(15, corridor.ways[Protocol.LOD_LOCAL].size)
    }

    private companion object {
        const val LAT0 = -2356145
        const val LON0 = -4665584
    }
}
