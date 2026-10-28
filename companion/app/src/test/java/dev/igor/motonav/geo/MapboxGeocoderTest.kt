package dev.igor.motonav.geo

import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The Geocoding v5 response (`docs/06 §Geocoding`) becomes the search list.
 * The JSON has the real response **structure**, with public places in São
 * Paulo — no address of Igor's enters the repository (`08 §Conventions`).
 */
class MapboxGeocoderTest {

    private val body = """
        {"type":"FeatureCollection","query":["copan"],"features":[
          {"id":"poi.1","type":"Feature","place_type":["poi"],"relevance":1,
           "properties":{"address":"Avenida Ipiranga, 200"},
           "text":"Edifício Copan","place_name":"Edifício Copan, Avenida Ipiranga, 200, São Paulo - SP, Brasil",
           "center":[-46.642686,-23.547538],"geometry":{"type":"Point","coordinates":[-46.642686,-23.547538]}},
          {"id":"address.2","type":"Feature","place_type":["address"],
           "text":"Rua Copan","place_name":"Rua Copan, Bela Vista, São Paulo - SP, Brasil",
           "center":[-46.65,-23.56]},
          {"id":"poi.3","type":"Feature","text":"Sem centro","place_name":"Sem centro, Brasil"}
        ],"attribution":"NOTICE: © 2026 Mapbox"}
    """.trimIndent()

    @Test
    fun `parse reads name address and position with the longitude first`() {
        val places = MapboxGeocoder.parse(body)

        assertEquals(2, places.size)
        assertEquals("Edifício Copan", places[0].name)
        assertTrue(places[0].address.startsWith("Edifício Copan, Avenida Ipiranga"))
        // `center` is [lon, lat]: swapping the two would send the route to the ocean.
        assertEquals(-23.547538, places[0].position.lat, 1e-6)
        assertEquals(-46.642686, places[0].position.lon, 1e-6)
    }

    @Test
    fun `parse discards a result without a center`() {
        val names = MapboxGeocoder.parse(body).map { it.name }

        assertEquals(listOf("Edifício Copan", "Rua Copan"), names)
    }

    @Test
    fun `parse of an empty response returns an empty list`() {
        assertEquals(emptyList<Place>(), MapboxGeocoder.parse("""{"type":"FeatureCollection","features":[]}"""))
    }

    @Test
    fun `parse of a body that is not json fails with a message`() {
        try {
            MapboxGeocoder.parse("<html>502</html>")
            fail("should have thrown GeocodeException")
        } catch (e: GeocodeException) {
            assertTrue(e.message!!.isNotBlank())
        }
    }

    // prevents: an endless body, or a gzip that OkHttp opens on its own, becoming `OutOfMemoryError`: it is an `Error`,
    // goes past the search's `catch` blocks and takes the app down, with the navigation along (the service is in the same process).
    @Test
    fun `body above the cap fails the search and not the app`() {
        var requests = 0
        fun servedBy(served: () -> ResponseBody) = MapboxGeocoder({ "pk.test" }, answering(body = served)) { requests++ }
        for ((what, served) in oversized(MapboxGeocoder.MAX_BODY_BYTES, body)) {
            try {
                runBlocking { servedBy(served).search("copan") }
                fail("$what: should refuse")
            } catch (e: GeocodeException) {
                assertTrue("$what: ${e.message}", "too large" in e.message!!)
            }
        }
        // The call went to Mapbox and counts toward the month, even if refused.
        assertEquals(2, requests)
        // And the real response goes through the same read.
        assertEquals(2, runBlocking { servedBy { body.toResponseBody() }.search("copan") }.size)
    }
}
