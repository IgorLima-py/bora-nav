package dev.igor.motonav.route

import dev.igor.motonav.proto.Protocol
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The maneuver types of C16.5 (05 §TURNS): what the comparison with the packer fixture does not
 * catch, because `route_sample.json` does not have these cases.
 */
class MapboxTurnTypeTest {

    private fun roundabout() = MbManeuver(type = "roundabout", modifier = "right", exit = 2)

    // prevents: a left-hand-traffic roundabout drawn turning counterclockwise (the ring turns clockwise there, and
    // Mapbox's `degrees` counts in the direction of the ring).
    @Test
    fun `a roundabout where traffic keeps left stays the plain roundabout`() {
        assertEquals(Protocol.TURN_ROUNDABOUT, MapboxRouteParser.maneuverToTurnType(roundabout(), 90.0, "left"))
        assertEquals(Protocol.TURN_ROUNDABOUT, MapboxRouteParser.maneuverToTurnType(roundabout(), null, "right"))
    }

    // prevents: Kotlin and packer.py disagreeing on a bucket edge (67.5 is a right exit, not
    // closed) — the fixture only has 306, 139 and 270, far from all the edges.
    @Test
    fun `the degree buckets turn at the edges the protocol names`() {
        val cases = listOf(
            0.0 to 21, 67.4 to 21, 67.5 to 22, 112.5 to 23, 180.0 to 24, 202.5 to 25,
            247.5 to 26, 292.5 to 27, 337.4 to 27, 337.5 to 28, 359.0 to 28,
        )
        for ((degrees, type) in cases) {
            assertEquals("$degrees graus", type, MapboxRouteParser.maneuverToTurnType(roundabout(), degrees))
        }
    }

    // prevents: the roundabout angle read from the banner of the step itself (which already describes the next
    // maneuver): the three roundabouts would come out with the degrees of the neighbor. The response is synthetic, in the
    // Directions format: the route fixture comes from OSRM, which does not send a banner.
    @Test
    fun `the exit angle comes from the previous step's banner`() {
        val route = MapboxRouteParser.parse(THREE_ROUNDABOUTS)
        val roundabouts = route.turns.filter { Protocol.hasExitNum(it.type) }
        assertEquals(listOf(27, 23, 26), roundabouts.map { it.type })
        assertEquals(listOf(2, 1, 1), roundabouts.map { it.exitNum })
    }

    private companion object {
        /** Three roundabouts in a row; the banner of each step describes the next maneuver. */
        val THREE_ROUNDABOUTS = """
            {"routes":[{"distance":450,"duration":60,"geometry":"~liyk@~rf{wAn}@?n}@?n}@?n}@?","legs":[{"steps":[
              {"name":"","maneuver":{"type":"depart","location":[-46.6,-23.5]},
               "bannerInstructions":[{"primary":{"type":"roundabout","degrees":306}}]},
              {"name":"","maneuver":{"type":"roundabout","modifier":"right","exit":2,"location":[-46.6,-23.501]},
               "bannerInstructions":[{"primary":{"type":"roundabout","degrees":139}}]},
              {"name":"","maneuver":{"type":"roundabout","modifier":"right","exit":1,"location":[-46.6,-23.502]},
               "bannerInstructions":[{"primary":{"type":"roundabout","degrees":270}}]},
              {"name":"","maneuver":{"type":"roundabout","modifier":"slight right","exit":1,"location":[-46.6,-23.503]}},
              {"name":"","maneuver":{"type":"arrive","location":[-46.6,-23.504]}}
            ]}]}],"waypoints":[{"name":""},{"name":""}]}
        """.trimIndent()
    }
}
