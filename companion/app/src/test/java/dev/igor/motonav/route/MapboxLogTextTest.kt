package dev.igor.motonav.route

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** What of Mapbox goes into `motonav.log` when the request fails. Public places: Parque Ecológico do Tietê and Copan. */
class MapboxLogTextTest {

    private val url = "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/" +
        "-46.525715,-23.498327;-46.642686,-23.547538?alternatives=false&bearings=90,45;&access_token=pk.segredo"

    // prevents: the Mapbox token being written to the log that Igor sends for diagnosis.
    @Test
    fun theTokenNeverGoesToTheLog() {
        assertFalse(mapboxLogText(url, keepCoordinates = true).contains("pk.segredo"))
        assertFalse(mapboxLogText(url, keepCoordinates = false).contains("pk.segredo"))
    }

    // prevents: outside the `sim` variant, an HTTP 5xx or 429 from Mapbox writing to the log the start, the
    // stops and the destination (which may be the home of whoever uses it), which go in the URL path (C13a finding).
    @Test
    fun outsideTheSimVariantTheUrlGoesWithoutCoordinates() {
        val logged = mapboxLogText(url, keepCoordinates = false)

        assertFalse(logged, logged.contains("46.5") || logged.contains("46.6") || logged.contains("23.4") || logged.contains("23.5"))
        assertTrue("the rest of the URL stays, for diagnostics", logged.contains("driving-traffic/#,#;#,#?alternatives=false"))
        assertTrue("the heading is not a position", logged.contains("bearings=90,45"))
    }

    // prevents: the body of a Mapbox error, which repeats the refused coordinate, carrying into the log
    // what was removed from the URL.
    @Test
    fun outsideTheSimVariantTheErrorBodyGoesWithoutCoordinates() {
        val body = """{"message":"Coordinate is invalid: -46.525715,-23.498327","code":"InvalidInput"}"""

        assertEquals(
            """{"message":"Coordinate is invalid: #,#","code":"InvalidInput"}""",
            mapboxLogText(body, keepCoordinates = false),
        )
    }

    // prevents: the `sim` variant losing the coordinate that `tools/e2e.py` checks (public places in the emulator).
    @Test
    fun theSimVariantKeepsTheCoordinates() {
        assertTrue(mapboxLogText(url, keepCoordinates = true).contains("-46.525715,-23.498327;-46.642686,-23.547538"))
    }
}
