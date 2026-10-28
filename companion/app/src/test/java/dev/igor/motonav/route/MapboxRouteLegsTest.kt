package dev.igor.motonav.route

import dev.igor.motonav.proto.Protocol
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Route with one stop (2 legs) read by the parser — C11.
 *
 * The fixture `route_2legs.json` is a **real** OSRM response (`tools/make_fixture.py --via`)
 * with the stop in the middle of the `route_sample.json` route. The expected numbers come from the mirror
 * in Python (`route_from_mapbox` of `tools/packer.py`): `stop_idx == [202]`, 18 maneuvers,
 * arrivals at indices 202 and 264 (the last one on the left).
 */
class MapboxRouteLegsTest {

    private val body = File("../../tools/fixtures/route_2legs.json").readText(Charsets.UTF_8)

    @Test
    fun stopIndexMatchesThePythonMirror() {
        val route = MapboxRouteParser.parse(body)

        assertEquals(listOf(202), route.stopIdx)
        assertEquals(265, route.points.size)
    }

    @Test
    fun theMiddleDepartIsDroppedAndBothArrivalsStay() {
        val route = MapboxRouteParser.parse(body)

        assertEquals(18, route.turns.size)
        assertEquals(1, route.turns.count { it.type == Protocol.TURN_DEPART })
        val arrive = setOf(Protocol.TURN_ARRIVE, Protocol.TURN_ARRIVE_LEFT, Protocol.TURN_ARRIVE_RIGHT)
        val arrivals = route.turns.filter { it.type in arrive }.map { it.pointIdx }
        assertEquals(listOf(202, 264), arrivals)
    }

    @Test
    fun aSingleLegRouteHasNoStops() {
        val single = File("../../tools/fixtures/route_sample.json").readText(Charsets.UTF_8)

        assertEquals(emptyList<Int>(), MapboxRouteParser.parse(single).stopIdx)
    }
}
