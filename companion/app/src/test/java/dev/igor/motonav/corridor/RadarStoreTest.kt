package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.route.MapboxRouteParser
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The [RadarStore] (C16.6): the cameras already downloaded, for the route that leaves with Overpass down. */
class RadarStoreTest {

    private lateinit var dir: File
    private val repo = File("../..")

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-radares").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun camera(id: Long, maxspeed: String? = "50") = OsmCamera(id, PointE5(-2355000, -4663000 + id.toInt()), maxspeed, null)

    private fun way(vararg nodes: Long) =
        OsmCameraWay(nodes.toList(), nodes.map { PointE5(-2355000, -4663000 + it.toInt()) }, "yes", "50")

    // prevents: the camera cache vanishing when Android kills the process between two routes (it is the rule
    // of the phone with the screen off), or a new route wiping the cameras of another part of the city.
    @Test
    fun theUnionSurvivesANewProcess() {
        val file = RadarStore.defaultFile(dir)
        val first = RadarStore(file)
        first.merge(OsmRadars(listOf(camera(1), camera(2)), listOf(way(1, 10))))
        // Another route: camera 2 with a new limit, and a camera and a way that were not there.
        first.merge(OsmRadars(listOf(camera(2, maxspeed = "40"), camera(3)), listOf(way(1, 10), way(3, 30))))

        val reopened = RadarStore(file).all()
        assertEquals(listOf(1L, 2L, 3L), reopened.cameras.map { it.id })
        assertEquals("a resposta nova ganha", "40", reopened.cameras.first { it.id == 2L }.maxspeed)
        assertEquals("the same way is not added twice", 2, reopened.ways.size)
        assertEquals(way(3, 30), reopened.ways.last())
    }

    // prevents: a damaged cache file (cut-off write) taking down the camera search.
    @Test
    fun aBrokenFileStartsEmpty() {
        val file = RadarStore.defaultFile(dir)
        file.writeText("{\"cameras\": [", Charsets.UTF_8)
        val store = RadarStore(file)
        assertTrue(store.all().cameras.isEmpty())
        store.merge(OsmRadars(listOf(camera(7)), emptyList()))
        assertEquals(listOf(7L), RadarStore(file).all().cameras.map { it.id })
    }

    // prevents: the cache giving other cameras than the search on the same route (the filter is the same, and a whole
    // city's cache cannot bring the camera of another street): on the real route, the cache with the recorded
    // response gives exactly the 8 cameras of the search.
    @Test
    fun theCacheGivesTheSameRadarsAsTheSearch() = runBlocking {
        val route: PackableRoute = MapboxRouteParser
            .parse(File(repo, "tools/fixtures/route_tiete_copan.json").readText(Charsets.UTF_8), "Copan")
            .toPackable(routeId = 1)
        val client = RadarClient(store = RadarStore(RadarStore.defaultFile(dir)))
        val osm = client.parse(File(repo, "tools/fixtures/overpass_radars_tiete_copan.json").readText(Charsets.UTF_8))
        // A camera far from the route, from another part of the city, already in the cache.
        val far = OsmRadars(listOf(OsmCamera(999, PointE5(-2370000, -4680000), "60", null)), emptyList())
        RadarStore(RadarStore.defaultFile(dir)).merge(far)
        val store = RadarStore(RadarStore.defaultFile(dir))
        store.merge(osm)

        val cached = RadarClient(store = store).cached(route)
        assertEquals(RadarFilter.filter(route, osm), cached)
        assertEquals(RadarFilterTest.REAL_ON_ROUTE, cached.size)
        assertTrue("no store, nothing", RadarClient().cached(route).isEmpty())
        assertTrue(client.cached(route).isNotEmpty())
    }
}
