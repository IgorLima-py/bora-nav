package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PointE5
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Overpass mirrors' hedge (C16.5): the network swapped for delays, to measure how long
 * [OverpassClient.fetch] waits.
 */
class OverpassHedgeTest {

    private val polygon = listOf(PointE5(-2356145, -4665000), PointE5(-2356045, -4665000), PointE5(-2356145, -4664900))

    private val body = """{"elements":[{"type":"way","tags":{"highway":"residential"},
        "geometry":[{"lat":-23.5,"lon":-46.6},{"lat":-23.501,"lon":-46.601}]}]}"""

    /** Each mirror answers `body` (or fails, with `null`) after `delayMs`. */
    private fun client(hedgeMs: Long, vararg mirrors: Pair<Long, String?>) =
        object : OverpassClient(endpoints = mirrors.indices.map { "m$it" }, hedgeAfterMs = hedgeMs) {
            override suspend fun request(endpoint: String, query: String): String {
                val (delayMs, answer) = mirrors[endpoint.removePrefix("m").toInt()]
                delay(delayMs)
                return answer ?: throw OverpassException("HTTP 504")
            }
        }

    private fun timed(block: suspend () -> List<OsmWay>): Pair<Long, List<OsmWay>> = runBlocking {
        val start = System.nanoTime()
        val ways = block()
        (System.nanoTime() - start) / 1_000_000 to ways
    }

    // prevents: the corridor waiting for the main mirror after the backup already answered —
    // 8 of 13 queries in the C16 logs waited 5.8 to 27.9 s longer (10/16, mail.ru in 27.6 s
    // and the main one in 55.6 s, corridor in 55.6 s).
    @Test
    fun `the mirror that answers first wins without waiting for the primary`() {
        val overpass = client(hedgeMs = 100, 3_000L to body, 50L to body)
        val (ms, ways) = timed { overpass.fetch(polygon) }
        assertEquals(1, ways.size)
        assertTrue("took $ms ms; the backup answered in ~150 ms", ms < 1_500)
    }

    // prevents: the main one failing with 502/504 in 1 to 7 s (street logs, 10/16) and the backup only being
    // called when the 5 s hedge won.
    @Test
    fun `a primary that fails fast calls the mirror at once`() {
        val overpass = client(hedgeMs = 5_000, 20L to null, 50L to body)
        val (ms, ways) = timed { overpass.fetch(polygon) }
        assertEquals(1, ways.size)
        assertTrue("took $ms ms; without the 5 s hedge it should be ~70 ms", ms < 2_000)
    }

    // prevents: the failure of both mirrors becoming an infinite wait instead of an error.
    @Test(expected = OverpassException::class)
    fun `when every mirror fails the fetch fails`() {
        runBlocking { client(hedgeMs = 10, 10L to null, 10L to null).fetch(polygon) }
    }
}
