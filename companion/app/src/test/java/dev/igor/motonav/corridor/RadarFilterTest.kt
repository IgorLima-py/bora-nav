package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.ProtocolPacker
import dev.igor.motonav.route.MapboxRouteParser
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The [RadarFilter] and [RadarClient.parse] (C16.6), on a made-up route, rule by rule, and on the real
 * `tiete_copan` route with the Overpass response recorded in
 * `tools/fixtures/overpass_radars_tiete_copan.json` (data © OpenStreetMap contributors, ODbL).
 *
 * The recording is the first test, off in the battery; turn it on with `MOTONAV_REDE=1`:
 *
 * ```
 * MOTONAV_REDE=1 ./gradlew testDebugUnitTest --tests "*RadarFilterTest*record*"
 * ```
 */
class RadarFilterTest {

    private val repo = File("../..")
    private val fixture = File(repo, "tools/fixtures/overpass_radars_tiete_copan.json")

    private fun realRoute(): PackableRoute = MapboxRouteParser
        .parse(File(repo, "tools/fixtures/route_tiete_copan.json").readText(Charsets.UTF_8), "Copan")
        .toPackable(routeId = 1)

    @Test
    fun `record the radars of the real route`() {
        assumeTrue("enable with MOTONAV_REDE=1", System.getenv("MOTONAV_REDE") == "1")
        val route = realRoute()
        val polygon = CorridorBuilder { emptyList() }.bufferPolygon(route, LocalPlane(route.lat0, route.lon0))
        val body = runBlocking {
            OverpassClient().request(OverpassClient.DEFAULT_ENDPOINT, RadarClient().buildQuery(polygon))
        }
        fixture.writeText(body, Charsets.UTF_8)
        println("recorded: ${body.length} B in ${fixture.path}")
    }

    // prevents: the camera across the avenue, on the crossing street or a block away buzzing
    // on the wrist; or the same camera, mapped twice, warning twice.
    @Test
    fun `the real route keeps only the radars on it`() {
        val route = realRoute()
        val osm = RadarClient().parse(fixture.readText(Charsets.UTF_8))
        val kept = RadarFilter.keep(route, osm)
        for (k in kept) {
            println("radar at ${k.radar.distAlongM} m, ${"%.1f".format(k.offsetM)} m from the trace, " +
                "limit ${k.radar.limitKmh}, flags ${k.radar.flags}")
        }
        println("real route: ${osm.cameras.size} radars in the polygon, ${osm.ways.size} ways, ${kept.size} on the route")
        assertEquals("radars in the polygon (the recording)", REAL_IN_POLYGON, osm.cameras.size)
        assertEquals("radars on the route", REAL_ON_ROUTE, kept.size)
        assertTrue(kept.all { it.offsetM <= RadarFilter.NEAR_M })
        assertTrue(kept.zipWithNext().all { (a, b) -> b.radar.distAlongM - a.radar.distAlongM >= RadarFilter.DEDUP_M })
        assertTrue(kept.all { it.radar.distAlongM in 0..route.distanceM.toLong() + 100 })
        // And the list goes onto the wire without the packer complaining.
        ProtocolPacker.packRadars(kept.map { it.radar })
    }

    // A straight route heading east, from 0 to 2 km, with lat0/lon0 at the first point.
    private val lat0 = -2355000
    private val lon0 = -4663000
    private val plane = LocalPlane(lat0, lon0)
    private val route = PackableRoute(
        routeId = 1,
        points = listOf(PointE5(lat0, lon0), PointE5(lat0, plane.toLonE5(2000.0))),
        turns = emptyList(),
        distanceM = 2000,
        durationS = 200,
        destName = "Leste",
    )

    private fun at(x: Double, y: Double) = PointE5(plane.toLatE5(y), plane.toLonE5(x))

    private fun camera(id: Long, x: Double, y: Double, maxspeed: String? = "50", direction: String? = null) =
        OsmCamera(id, at(x, y), maxspeed, direction)

    /** A 3-node way passing through camera `id` at (x, y), drawn from (x−dx, y−dy) to (x+dx, y+dy). */
    private fun way(id: Long, x: Double, y: Double, dx: Double, dy: Double, oneway: String? = null) =
        OsmCameraWay(
            nodes = listOf(id * 10, id, id * 10 + 1),
            points = listOf(at(x - dx, y - dy), at(x, y), at(x + dx, y + dy)),
            oneway = oneway,
            maxspeed = "70",
        )

    @Test
    fun `a radar on the route lands at its distance with its limit`() {
        val kept = RadarFilter.filter(route, OsmRadars(listOf(camera(1, 500.0, 10.0)), emptyList()))
        assertEquals(1, kept.size)
        assertEquals(500L, kept[0].distAlongM)
        assertEquals(50, kept[0].limitKmh)
        assertEquals("off a way: unknown direction", 0, kept[0].flags)
        assertEquals(at(500.0, 10.0).lat - lat0, kept[0].dLat)
    }

    @Test
    fun `a radar far from the route or on a crossing street is dropped`() {
        val far = camera(1, 500.0, RadarFilter.NEAR_M + 5)
        val crossing = camera(2, 900.0, 0.0)
        val kept = RadarFilter.filter(
            route,
            OsmRadars(listOf(far, crossing), listOf(way(2, 900.0, 0.0, 0.0, 40.0))),
        )
        assertTrue("got $kept", kept.isEmpty())
    }

    @Test
    fun `the direction keeps the radar of the route's way and drops the other`() {
        val along = camera(1, 300.0, 0.0, direction = "forward")
        val against = camera(2, 800.0, 0.0, direction = "backward")
        // The way drawn westward: its `forward` is against the route.
        val reversed = camera(3, 1200.0, 0.0, direction = "forward")
        val oneway = camera(4, 1600.0, 0.0, maxspeed = null)
        val degrees = camera(5, 1900.0, 0.0, direction = "270")
        val ways = listOf(
            way(1, 300.0, 0.0, 30.0, 0.0),
            way(2, 800.0, 0.0, 30.0, 0.0),
            way(3, 1200.0, 0.0, -30.0, 0.0),
            way(4, 1600.0, 0.0, 30.0, 0.0, oneway = "yes"),
            way(5, 1900.0, 0.0, 30.0, 0.0),
        )
        val kept = RadarFilter.filter(route, OsmRadars(listOf(along, against, reversed, oneway, degrees), ways))
        assertEquals(listOf(300L, 1600L, 1900L), kept.map { it.distAlongM })
        assertEquals(Protocol.RADAR_FLAG_DIRECTION, kept[0].flags)
        assertEquals("one-way in the route's direction", Protocol.RADAR_FLAG_DIRECTION, kept[1].flags)
        assertEquals("no maxspeed on the node, the way's", 70, kept[1].limitKmh)
        assertEquals("degrees are not read", 0, kept[2].flags)
    }

    @Test
    fun `a radar mapped twice is one, the one with the limit`() {
        val kept = RadarFilter.filter(
            route,
            OsmRadars(listOf(camera(1, 1000.0, 5.0, maxspeed = null), camera(2, 1030.0, -5.0, maxspeed = "60")), emptyList()),
        )
        assertEquals(1, kept.size)
        assertEquals(60, kept[0].limitKmh)
    }

    @Test
    fun `the list is sorted and cut at the cap`() {
        val long = route.copy(points = listOf(PointE5(lat0, lon0), PointE5(lat0, plane.toLonE5(20_000.0))))
        val spread = (0 until Protocol.MAX_RADARS + 20).map { camera(it.toLong(), 19_000.0 - it * 80.0, 0.0) }
        val kept = RadarFilter.filter(long, OsmRadars(spread, emptyList()))
        assertEquals(Protocol.MAX_RADARS, kept.size)
        assertTrue(kept.zipWithNext().all { (a, b) -> a.distAlongM < b.distAlongM })
        assertTrue("the cap keeps the first ones of the route", kept.first().distAlongM < 2000)
    }

    // prevents: C16.7's coverage not knowing why an OSM camera did not reach the watch (the 10/26 log
    // only had the count); and `keep` changing behavior when it gained the verdict.
    @Test
    fun `every radar of the polygon gets its reason`() {
        val cameras = listOf(
            camera(1, 300.0, 5.0),
            camera(2, 500.0, RadarFilter.NEAR_M + 5),
            camera(3, 900.0, 0.0),
            camera(4, 1200.0, 0.0, direction = "backward"),
            camera(5, 1500.0, 0.0, maxspeed = null),
            camera(6, 1530.0, 0.0, maxspeed = "60"),
            camera(7, 1800.0, 0.0, maxspeed = "60"),
            camera(8, 1820.0, 0.0, maxspeed = "50"),
        )
        val ways = listOf(way(3, 900.0, 0.0, 0.0, 40.0), way(4, 1200.0, 0.0, 30.0, 0.0))
        val osm = OsmRadars(cameras, ways)
        val reasons = RadarFilter.judge(route, osm).associate { it.camera.id to it.reason }
        assertEquals(
            mapOf(
                1L to RadarFilter.Reason.KEPT,
                2L to RadarFilter.Reason.FAR,
                3L to RadarFilter.Reason.CROSS_STREET,
                4L to RadarFilter.Reason.WRONG_WAY,
                5L to RadarFilter.Reason.DUPLICATE,
                6L to RadarFilter.Reason.KEPT,
                7L to RadarFilter.Reason.KEPT,
                8L to RadarFilter.Reason.DUPLICATE,
            ),
            reasons,
        )
        assertEquals("keep is what judge kept", listOf(1L, 6L, 7L), RadarFilter.keep(route, osm).map { it.osmId })
        assertEquals(listOf(300L, 1530L, 1800L), RadarFilter.filter(route, osm).map { it.distAlongM })
        assertTrue("route heading east", RadarFilter.judge(route, osm).all { it.bearingDeg == 90 })
    }

    // prevents: a camera going past the cap silently; the verdict has to say it was the wire cut.
    @Test
    fun `the radars past the cap are marked as cut`() {
        val long = route.copy(points = listOf(PointE5(lat0, lon0), PointE5(lat0, plane.toLonE5(20_000.0))))
        val spread = (0 until Protocol.MAX_RADARS + 3).map { camera(it.toLong(), 100.0 + it * 80.0, 0.0) }
        val verdicts = RadarFilter.judge(long, OsmRadars(spread, emptyList()))
        assertEquals(Protocol.MAX_RADARS, verdicts.count { it.reason == RadarFilter.Reason.KEPT })
        assertEquals(3, verdicts.count { it.reason == RadarFilter.Reason.CAP })
    }

    // prevents: `tools/relatorio.py` (RADAR_PHONE) no longer reading the camera line because the format
    // changed on only one side, and the coverage coming out zeroed with no error.
    @Test
    fun `the radar log line is the one the report reads`() {
        val osm = OsmRadars(
            listOf(camera(42, 500.0, 10.0, direction = "forward")),
            listOf(way(42, 500.0, 10.0, 30.0, 0.0)),
        )
        val verdict = RadarFilter.judge(route, osm).single()
        val point = verdict.camera.point
        assertEquals(
            "radar 0/1 route 1 osm 42 d 500 e5 ${point.lat},${point.lon} lim 50 bearing 90 direction fwd source osm",
            RadarClient.radarLine(1, 0, 1, verdict, "osm"),
        )
    }

    private fun pardal(x: Double, y: Double, directionDeg: Int, limitKmh: Int = 50) =
        PardalCamera(at(x, y), limitKmh, directionDeg)

    // prevents: the 19 CET cameras missing from OSM on Igor's routes (C16.7: 24 of 67) staying
    // out of the list, with the pardal knowing about them and their direction.
    @Test
    fun `a pardal radar the OSM lacks joins the list with its direction`() {
        val verdicts = RadarFilter.judge(route, OsmRadars(emptyList(), emptyList()), listOf(pardal(700.0, 8.0, 95, 60)))
        val kept = verdicts.single()
        assertEquals(RadarFilter.Reason.KEPT, kept.reason)
        assertEquals(RadarFilter.Source.PARDAL, kept.source)
        assertEquals(700L, kept.radar!!.distAlongM)
        assertEquals(60, kept.radar!!.limitKmh)
        assertEquals("o pardal diz o sentido", Protocol.RADAR_FLAG_DIRECTION, kept.radar!!.flags)
    }

    // prevents: the camera across the avenue, which OSM already cut for wrong-way, coming back through the pardal
    // (11 cases in the 20 routes), and the same camera warning twice for being in both sources.
    @Test
    fun `the OSM verdict wins over a pardal radar at the same place`() {
        val wrongWay = camera(1, 400.0, 0.0, direction = "backward")
        val kept = camera(2, 1200.0, 0.0)
        val osm = OsmRadars(listOf(wrongWay, kept), listOf(way(1, 400.0, 0.0, 30.0, 0.0)))
        val verdicts = RadarFilter.judge(route, osm, listOf(pardal(410.0, 15.0, 90), pardal(1220.0, 10.0, 90)))
        assertEquals(listOf(1200L), verdicts.filter { it.reason == RadarFilter.Reason.KEPT }.map { it.radar!!.distAlongM })
        assertEquals(2, verdicts.count { it.reason == RadarFilter.Reason.IN_OSM })
    }

    // prevents: the pardal camera for the other direction, more than 30 m from the track (the parallel street, which the
    // pardal does not say which one is) or with no direction buzzing on the wrist.
    @Test
    fun `a pardal radar of the other way or off the route stays out`() {
        val verdicts = RadarFilter.judge(
            route,
            OsmRadars(emptyList(), emptyList()),
            listOf(pardal(300.0, 0.0, 270), pardal(800.0, RadarFilter.PARDAL_NEAR_M + 5, 90), pardal(5000.0, 3000.0, 90)),
        )
        assertEquals(listOf(RadarFilter.Reason.WRONG_WAY, RadarFilter.Reason.FAR), verdicts.map { it.reason })
    }

    // prevents: the pardal cameras, which have no OSM id, all falling on the same key of
    // `tools/relatorio.py` (RADAR_PHONE, `osm -?\d+`) and the coverage counting just one.
    @Test
    fun `a pardal radar logs its own key and source`() {
        val verdicts = RadarFilter.judge(route, OsmRadars(emptyList(), emptyList()), listOf(pardal(500.0, 0.0, 90), pardal(900.0, 0.0, 90)))
        val (a, b) = verdicts
        assertTrue("negative key", a.camera.id < 0 && b.camera.id < 0)
        assertTrue("one key per radar", a.camera.id != b.camera.id)
        val point = a.camera.point
        assertEquals(
            "radar 0/2 route 1 osm ${a.camera.id} d 500 e5 ${point.lat},${point.lon} lim 50 bearing 90 direction fwd source pardal",
            RadarClient.radarLine(1, 0, 2, a, "osm"),
        )
    }

    @Test
    fun `maxspeed reads km per hour only`() {
        assertEquals(60, RadarFilter.kmh("60"))
        assertEquals(40, RadarFilter.kmh("40 km/h"))
        assertNull(RadarFilter.kmh("30 mph"))
        assertNull(RadarFilter.kmh("BR:urban"))
        assertNull(RadarFilter.kmh("none"))
        assertNull(RadarFilter.kmh(null))
    }

    @Test
    fun `the parse reads the cameras and the ways through them`() {
        val body = """{"elements":[
            {"type":"node","id":7,"lat":-23.55,"lon":-46.63,"tags":{"highway":"speed_camera","maxspeed":"50","direction":"forward"}},
            {"type":"way","id":9,"nodes":[6,7,8],"tags":{"highway":"primary","oneway":"yes"},
             "geometry":[{"lat":-23.55,"lon":-46.631},{"lat":-23.55,"lon":-46.63},{"lat":-23.55,"lon":-46.629}]}
        ]}"""
        val osm = RadarClient().parse(body)
        assertEquals(listOf(OsmCamera(7, PointE5(-2355000, -4663000), "50", "forward")), osm.cameras)
        assertEquals(listOf(6L, 7L, 8L), osm.ways.single().nodes)
        assertEquals("yes", osm.ways.single().oneway)
    }

    companion object {
        /**
         * Counted in the 2026-10-27 recording (`tools/make_fixture.py --radares`, the same query, on the
         * OSRM route polygon, OSM base of 2026-10-27T18:24Z): 59 nodes in the polygon, 59 ways through
         * them; 8 are on the route, the farthest 31.1 m from the track, 7 with direction (only one node of the
         * polygon has `forward`, none has `backward` or degrees; the rest comes from one-way).
         */
        const val REAL_IN_POLYGON = 59
        const val REAL_ON_ROUTE = 8
    }
}
