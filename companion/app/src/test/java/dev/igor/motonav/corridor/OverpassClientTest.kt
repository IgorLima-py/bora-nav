package dev.igor.motonav.corridor

import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import dev.igor.motonav.proto.PointE5
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The whole [OverpassClient], with OkHttp: only the network is swapped, for an interceptor
 * ([answering]). The hedge has its own test, `OverpassHedgeTest`.
 */
class OverpassClientTest {

    private val polygon = listOf(PointE5(-2356145, -4665000), PointE5(-2356045, -4665000), PointE5(-2356145, -4664900))

    private val body = """{"elements":[{"type":"way","tags":{"highway":"residential"},
        "geometry":[{"lat":-23.5,"lon":-46.6},{"lat":-23.501,"lon":-46.601}]}]}"""

    private fun servedBy(body: () -> ResponseBody) =
        OverpassClient(endpoints = listOf("https://overpass.invalid/api/interpreter"), client = answering(body = body))

    // prevents: an endless Overpass response, or a gzip that OkHttp opens on its own, becoming
    // `OutOfMemoryError`: it is an `Error`, goes past each mirror's `catch` and takes the app down, with the
    // navigation along (the service is in the same process).
    @Test
    fun `a body over the cap fails the mirror instead of the app`() {
        for ((what, served) in oversized(OverpassClient.MAX_BODY_BYTES, body)) {
            val overpass = servedBy(served)
            val read = runCatching { runBlocking { overpass.request("https://overpass.invalid/api/interpreter", "q") } }.exceptionOrNull()
            assertTrue("$what: got $read", read is OverpassException && " over " in read.message!!)
            // The mirror that overflows fails like a 504: with the others out, the whole query fails.
            val fetched = runCatching { runBlocking { overpass.fetch(polygon) } }.exceptionOrNull()
            assertTrue("$what: veio $fetched", fetched is OverpassException)
        }
        // And the real response goes through the same read.
        assertEquals(listOf("residential"), runBlocking { servedBy { body.toResponseBody() }.fetch(polygon) }.map { it.highway })
    }
}
