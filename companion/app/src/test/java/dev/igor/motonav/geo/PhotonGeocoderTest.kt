package dev.igor.motonav.geo

import dev.igor.motonav.route.LatLng
import java.io.ByteArrayOutputStream
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.asResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import okio.GzipSource
import okio.buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The Photon response (`docs/06 §Geocoding`) becomes the search list, and Mapbox only comes in when
 * Photon does not serve. The JSON has the **structure** of the Photon response, with public places in São
 * Paulo: no address of Igor's goes into the repository (`08 §Conventions`).
 */
class PhotonGeocoderTest {

    private val body = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-46.642686,-23.547538]},
           "properties":{"osm_key":"building","name":"Edifício Copan","street":"Avenida Ipiranga","housenumber":"200",
             "district":"República","city":"São Paulo","state":"São Paulo","country":"Brasil","type":"house"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-46.6566,-23.5614]},
           "properties":{"osm_key":"highway","street":"Avenida Paulista","housenumber":"1578",
             "district":"Bela Vista","city":"São Paulo","state":"São Paulo","type":"house"}},
          {"type":"Feature","geometry":{"type":"Point","coordinates":[-46.66]},
           "properties":{"name":"Sem coordenada"}}
        ]}
    """.trimIndent()

    @Test
    fun `parse reads name, address and position with the longitude first`() {
        val places = PhotonGeocoder.parse(body)

        assertEquals(2, places.size)
        assertEquals("Edifício Copan", places[0].name)
        assertEquals("Edifício Copan, Avenida Ipiranga, 200, República, São Paulo", places[0].address)
        // `coordinates` is [lon, lat]: swapping the two would send the route to the ocean.
        assertEquals(-23.547538, places[0].position.lat, 1e-6)
        assertEquals(-46.642686, places[0].position.lon, 1e-6)
        // Address without a place name: the name is the street with the number, and it is not repeated in the address.
        assertEquals("Avenida Paulista, 1578", places[1].name)
        assertEquals("Avenida Paulista, 1578, Bela Vista, São Paulo", places[1].address)
    }

    @Test
    fun `parse refuses a body that is not the Photon's`() {
        try {
            PhotonGeocoder.parse("<html>502</html>")
            fail("should refuse")
        } catch (e: GeocodeException) {
            assertTrue(e.message!!.contains("Unreadable search response"))
        }
    }

    // prevents: the screen drawing thousands of places at once when the server sends more than asked.
    @Test
    fun `parse keeps only the six asked for`() {
        val feature = """{"geometry":{"coordinates":[-46.64,-23.54]},"properties":{"name":"Copan"}}"""
        val many = """{"features":[${List(50) { feature }.joinToString(",")}]}"""
        assertEquals(6, PhotonGeocoder.parse(many).size)
    }

    /** The whole [PhotonGeocoder], with OkHttp: only the network is swapped, by an interceptor that answers [body]. */
    private fun servedBy(body: () -> ResponseBody) = PhotonGeocoder(
        client = OkHttpClient.Builder().addInterceptor { chain ->
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body()).build()
        }.build(),
        base = "https://photon.invalid",
    )

    // prevents: an endless body, or a gzip that OkHttp opens by itself, becoming `OutOfMemoryError`: it is an `Error`,
    // goes through the search's `catch` blocks and takes the app down, navigation included (the service is in the same process).
    @Test
    fun `a body over the cap fails the search instead of the app`() {
        val zeros = ByteArray(1024 * 1024)
        val bomb = ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { z -> repeat(64) { z.write(zeros) } } }.toByteArray()
        val bodies = listOf<() -> ResponseBody>(
            { ByteArray(PhotonGeocoder.MAX_BODY_BYTES + 1).toResponseBody() },
            { GzipSource(Buffer().write(bomb)).buffer().asResponseBody(null, -1) },
        )
        for (served in bodies) {
            try {
                runBlocking { servedBy(served).search("copan") }
                fail("should refuse")
            } catch (e: GeocodeException) {
                assertTrue(e.message!!, "too large" in e.message!!)
            }
        }
        // And the real response goes through the same reading.
        assertEquals(2, runBlocking { servedBy { body.toResponseBody() }.search("copan") }.size)
    }

    private val copan = Place("Edifício Copan", "Avenida Ipiranga, 200", LatLng(-23.547538, -46.642686))
    private val fromMapbox = Place("Copan (Mapbox)", "Av. Ipiranga, 200", LatLng(-23.5475, -46.6427))

    private fun search(photon: suspend (String, LatLng?) -> List<Place>, reserve: (suspend (String, LatLng?) -> List<Place>)?) =
        PlaceSearch(photon, { null }, reserve, null)

    @Test
    fun `the Photon answers first and the Mapbox is not asked`() = runBlocking {
        var mapboxCalls = 0
        val found = search({ _, _ -> listOf(copan) }, { _, _ -> mapboxCalls++; listOf(fromMapbox) }).search("copan")
        assertEquals(listOf(copan), found)
        assertEquals(0, mapboxCalls)
    }

    @Test
    fun `the Mapbox answers when the Photon finds nothing or fails`() = runBlocking {
        val empty = search({ _, _ -> emptyList() }, { _, _ -> listOf(fromMapbox) }).search("copan")
        assertEquals(listOf(fromMapbox), empty)
        val down = search({ _, _ -> throw GeocodeException("No internet to look up the address") }, { _, _ -> listOf(fromMapbox) })
            .search("copan")
        assertEquals(listOf(fromMapbox), down)
    }

    @Test
    fun `when neither answers the error is the Photon's`() = runBlocking {
        val photonDown: suspend (String, LatLng?) -> List<Place> = { _, _ -> throw GeocodeException("No internet to look up the address") }
        for (reserve in listOf<(suspend (String, LatLng?) -> List<Place>)?>(null, { _, _ -> emptyList() }, { _, _ -> throw GeocodeException("Mapbox refused the token (HTTP 401)") })) {
            try {
                search(photonDown, reserve).search("copan")
                fail("should throw")
            } catch (e: GeocodeException) {
                assertEquals("No internet to look up the address", e.message)
            }
        }
    }
}
