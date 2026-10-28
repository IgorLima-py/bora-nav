package dev.igor.motonav.share

import dev.igor.motonav.geo.PhotonGeocoder
import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import dev.igor.motonav.route.LatLng
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Tests for parsing a shared link (`docs/04-COMPANION-APP.md §Share`).
 *
 * The URLs have the real **structure** of the ones Google Maps generates — the phone
 * log revealed each format — but with swapped coordinates and streets: Igor's
 * addresses do not go into the repository (`08 §Conventions`).
 */
class LinkResolverTest {

    private val resolver = LinkResolver()

    /**
     * Case that made the app ask for a route to its own origin: in a route link,
     * each waypoint has its own `!3d!4d` pair, and the destination is the **last** one.
     */
    @Test
    fun `route with two place-pins uses the last as destination`() {
        val url = "https://www.google.com/maps/dir/Avenida+Paulista/Aeroporto+de+Congonhas/" +
            "data=!4m16!4m15!1m5!1m4!1s0x94ce111111111111:0x1111!8m2!3d-23.561400!4d-46.655900" +
            "!1m5!1m4!1s0x94ce222222222222:0x2222!8m2!3d-23.626600!4d-46.656400!2m1!11b1!3e9"

        val point = resolver.coordinatesFrom(url)

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    /** Origin in raw coordinates in the path: the only pin is the destination. */
    @Test
    fun `route with origin in raw coordinates uses the destination pin`() {
        val url = "https://www.google.com/maps/dir/-23.561400,-46.655900/Aeroporto+de+Congonhas/" +
            "data=!4m12!4m11!1m1!4e1!1m5!1m4!1s0x94ce222222222222:0x2222!8m2!3d-23.626600" +
            "!4d-46.656400!2m1!11b1!3e9"

        val point = resolver.coordinatesFrom(url)

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    @Test
    fun `place link uses the place-pin`() {
        val url = "https://www.google.com/maps/place/Aeroporto+de+Congonhas/" +
            "data=!4m6!3m5!1s0x94ce222222222222:0x2222!8m2!3d-23.626600!4d-46.656400!16s%2Fg%2F123"

        val point = resolver.coordinatesFrom(url)

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    @Test
    fun `destination in query beats the map center`() {
        val url = "https://www.google.com/maps/@-23.500000,-46.600000,15z?destination=-23.626600,-46.656400"

        val point = resolver.coordinatesFrom(url)

        assertEquals(-23.626600, point!!.lat, 1e-6)
    }

    /** The map center is the last resort: it is where the camera was. */
    @Test
    fun `viewport is the last resort and can be turned off`() {
        val url = "https://www.google.com/maps/search/posto/@-23.500000,-46.600000,15z"

        assertEquals(-23.500000, resolver.coordinatesFrom(url)!!.lat, 1e-6)
        assertNull(resolver.coordinatesFrom(url, allowViewport = false))
    }

    @Test
    fun `short link with no coordinate at all does not resolve`() {
        assertNull(resolver.coordinatesFrom("https://maps.app.goo.gl/AbCdEfGhIjKlMnOpQ"))
    }

    /** `geo:` from Waze and from third-party apps. */
    @Test
    fun `geo uri resolves`() {
        val point = resolver.coordinatesFrom("geo:-23.626600,-46.656400?q=Congonhas")

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    // --- Waze (C8): the three `waze.com/ul` formats and the short link ---------

    /** `waze.com/ul?ll=` — the destination coordinate, which is what Waze shares. */
    @Test
    fun `waze ul ll resolves the coordinate`() {
        val point = resolver.coordinatesFrom("https://waze.com/ul?ll=-23.626600,-46.656400")

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    /** Waze encodes the comma (`%2C`) when the link goes through another app. */
    @Test
    fun `waze ul ll with the encoded comma resolves`() {
        val point = resolver.coordinatesFrom(
            "https://www.waze.com/ul?ll=-23.626600%2C-46.656400&navigate=yes&utm_campaign=default",
        )

        assertEquals(-23.626600, point!!.lat, 1e-6)
        assertEquals(-46.656400, point.lon, 1e-6)
    }

    /** `navigate=yes` is just the request to open navigating: it must not get in the way of the coordinate. */
    @Test
    fun `waze navigate yes does not change the coordinate`() {
        val with = resolver.coordinatesFrom("https://waze.com/ul?ll=-23.626600,-46.656400&navigate=yes")
        val without = resolver.coordinatesFrom("https://waze.com/ul?ll=-23.626600,-46.656400")

        assertEquals(without!!.lat, with!!.lat, 0.0)
        assertEquals(without.lon, with.lon, 0.0)
    }

    /** `waze.com/ul?q=` is text, not a coordinate: it goes to the geocoder, with the text decoded. */
    @Test
    fun `waze ul q is search text and not a coordinate`() {
        val url = "https://waze.com/ul?q=Aeroporto%20de%20Congonhas&navigate=yes"

        assertNull(resolver.coordinatesFrom(url, allowViewport = false))
        assertEquals("Aeroporto de Congonhas", resolver.textQueryFrom(url))
    }

    @Test
    fun `waze ul q with plus and accents decodes`() {
        val url = "https://www.waze.com/ul?q=Pra%C3%A7a+da+S%C3%A9&navigate=yes"

        assertEquals("Praça da Sé", resolver.textQueryFrom(url))
    }

    /** `ll` and `q` together: the coordinate wins, and `q` becomes the label. */
    @Test
    fun `waze with ll and q uses the coordinate and keeps the text`() {
        val url = "https://waze.com/ul?ll=-23.626600,-46.656400&q=Congonhas&navigate=yes"

        assertEquals(-23.626600, resolver.coordinatesFrom(url)!!.lat, 1e-6)
        assertEquals("Congonhas", resolver.textQueryFrom(url))
    }

    /** `q=` with a coordinate pair is not text: QUERY_COORDS is what reads it. */
    @Test
    fun `q with coordinates is not search text`() {
        val url = "https://waze.com/ul?q=-23.626600,-46.656400&navigate=yes"

        assertNull(resolver.textQueryFrom(url))
        assertEquals(-23.626600, resolver.coordinatesFrom(url)!!.lat, 1e-6)
    }

    /** The Waze short link carries the coordinate in a geohash: no network needed. */
    @Test
    fun `waze short link decodes the geohash`() {
        val point = resolver.geohashFrom("https://waze.com/ul/h6gycd6cv5")

        assertEquals(-23.626600, point!!.lat, 1e-4)
        assertEquals(-46.656400, point.lon, 1e-4)
    }

    @Test
    fun `link that is not a waze geohash does not decode`() {
        assertNull(resolver.geohashFrom("https://maps.app.goo.gl/AbCdEfGhIjKlMnOpQ"))
        // `a`, `i`, `l` and `o` do not exist in the geohash alphabet.
        assertNull(resolver.geohashFrom("https://waze.com/ul/hailo1234"))
    }

    /** `geo:0,0?q=` (third-party apps): no coordinate, text for the geocoder. */
    @Test
    fun `geo uri with q is search text`() {
        val uri = "geo:0,0?q=Rua+Augusta+100"

        assertNull(resolver.coordinatesFrom(uri))
        assertEquals("Rua Augusta 100", resolver.textQueryFrom(uri))
    }

    @Test
    fun `geo uri with coordinates and label in parentheses uses the label`() {
        val uri = "geo:0,0?q=-23.626600,-46.656400(Congonhas)"

        assertEquals("Congonhas", resolver.textQueryFrom(uri))
    }

    @Test
    fun `google maps search query with text becomes search text`() {
        val url = "https://www.google.com/maps/search/?api=1&query=Posto+Shell+Ibirapuera"

        assertEquals("Posto Shell Ibirapuera", resolver.textQueryFrom(url))
    }

    // --- resolve() end to end, no network --------------------------------

    @Test
    fun `resolve of the waze short link uses the geohash without going to the network`() = kotlinx.coroutines.runBlocking {
        val destination = resolver.resolve("Congonhas https://waze.com/ul/h6gycd6cv5")

        assertEquals("Congonhas", destination.label)
        assertEquals(-23.626600, destination.position.lat, 1e-4)
    }

    @Test
    fun `resolve of geo uri with coordinates does not geocode`() = kotlinx.coroutines.runBlocking {
        val destination = resolver.resolve("geo:-23.626600,-46.656400?q=Congonhas")

        assertEquals("Congonhas", destination.label)
        assertEquals(-46.656400, destination.position.lon, 1e-6)
    }

    @Test
    fun `resolve falls back to the mapbox geocoder when there is only text and photon finds nothing`() =
        kotlinx.coroutines.runBlocking {
            // A client that does not leave the JVM: Photon "fails" with an IOException, and the
            // second geocoder is the one that answers.
            val offline = okhttp3.OkHttpClient.Builder()
                .addInterceptor { throw java.io.IOException("no network in the test") }
                .build()
            var asked: String? = null
            val withMapbox = LinkResolver(offline) { query, _ ->
                asked = query
                dev.igor.motonav.route.LatLng(-23.5, -46.6)
            }

            val destination = withMapbox.resolve("geo:0,0?q=Rua+Augusta+100")

            assertEquals("Rua Augusta 100", asked)
            assertEquals(-23.5, destination.position.lat, 0.0)
            assertEquals("Rua Augusta 100", destination.label)
        }

    // prevents: the page the short link returns without a redirect (Google's is ~220 KB) being read with no
    // ceiling: an endless body, or a gzip that OkHttp opens by itself, became `OutOfMemoryError`, which
    // goes through the `catch` blocks and takes the app down. Above the ceiling it is ignored, even with the coordinate inside.
    @Test
    fun `page above the ceiling is ignored like a body that never came`() {
        val page = "<html><a href=\"/maps/place/Congonhas/data=!3d-23.626600!4d-46.656400\">Congonhas</a></html>"
        for ((what, served) in oversized(MAX_PAGE_BYTES, page)) {
            try {
                runBlocking { LinkResolver(answering(body = served)).resolve("https://maps.app.goo.gl/test") }
                fail("$what: should ignore the page")
            } catch (e: ShareException) {
                assertTrue("$what: ${e.message}", "Could not find the coordinates in this link" in e.message!!)
            }
        }
        // And the real page goes through the same reading.
        val destination = runBlocking { LinkResolver(answering { page.toResponseBody() }).resolve("https://maps.app.goo.gl/test") }
        assertEquals(-23.626600, destination.position.lat, 1e-6)
    }

    // prevents: the Photon response in sharing with no ceiling (the same `OutOfMemoryError`). Above the
    // ceiling it is like Photon finding nothing, and the Mapbox fallback answers.
    @Test
    fun `photon above the ceiling falls back to the mapbox geocoder`() {
        val photon = """{"features":[{"geometry":{"coordinates":[-46.642686,-23.547538]},"properties":{"name":"Copan"}}]}"""
        val fromMapbox = LatLng(-23.5, -46.6)
        for ((what, served) in oversized(PhotonGeocoder.MAX_BODY_BYTES, photon)) {
            val destination = runBlocking { LinkResolver(answering(body = served)) { _, _ -> fromMapbox }.resolve("Edifício Copan") }
            assertEquals(what, fromMapbox, destination.position)
        }
        // And the real response goes through the same reading.
        val destination = runBlocking { LinkResolver(answering { photon.toResponseBody() }) { _, _ -> fromMapbox }.resolve("Edifício Copan") }
        assertEquals(-23.547538, destination.position.lat, 1e-6)
    }
}
