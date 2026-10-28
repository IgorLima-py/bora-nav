package dev.igor.motonav.corridor

import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import dev.igor.motonav.proto.PointE5
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The [PardalSource] (C16.7b): the pardal's `radares.csv`, downloaded once a month and kept. */
class PardalSourceTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-pardal").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private val csv = """
        lat,lng,kind,limit_kmh,source,active,end_lat,end_lng,direction_deg
        -23.550000,-46.630000,FIXED,50,CET-SP,1,,,184
        -23.551000,-46.631000,FIXED,60,CET-SP+OSM,1,,,
        -23.552000,-46.632000,RED_LIGHT,0,CET-SP,1,,,90
        -23.553000,-46.633000,FIXED,40,CET-SP,0,,,90
        -23.554000,-46.634000,SECTION,80,DER-SP,1,-23.56,-46.64,10
        -23.555000,-46.635000,FIXED,,DER-SP,1,,,359.6
        linha quebrada
    """.trimIndent()

    // prevents: the direction-less camera (it would warn both ways), the red-light one, the deactivated one or the
    // section one entering the list; and a bad line in the file taking down the whole read.
    @Test
    fun theParseKeepsTheActiveFixedRadarsWithADirection() {
        val cameras = PardalSource.parse(csv)
        assertEquals(
            listOf(
                PardalCamera(PointE5(-2355000, -4663000), 50, 184),
                PardalCamera(PointE5(-2355500, -4663500), 0, 0),
            ),
            cameras,
        )
    }

    // prevents: downloading 857 KB on every route, or keeping a months-old file forever.
    @Test
    fun theFileIsDownloadedOnlyWhenOld() = runBlocking {
        var now = 1_000_000_000_000L
        var downloads = 0
        val source = PardalSource(File(dir, PardalSource.FILE_NAME), download = { downloads++; csv }, now = { now })
        assertEquals(2, source.cameras().size)
        assertEquals(2, PardalSource(File(dir, PardalSource.FILE_NAME), download = { downloads++; csv }, now = { now }).cameras().size)
        assertEquals("the new file counts", 1, downloads)
        now += PardalSource.MAX_AGE_MS + 1
        PardalSource(File(dir, PardalSource.FILE_NAME), download = { downloads++; csv }, now = { now }).cameras()
        assertEquals("the old file is downloaded again", 2, downloads)
    }

    // prevents: the route going out without the pardal's cameras because GitHub is down, or without the OSM ones because the
    // pardal failed: missing network is never an error here.
    @Test
    fun withoutNetworkTheOldFileOrNothing() = runBlocking {
        var now = 1_000_000_000_000L
        val file = File(dir, PardalSource.FILE_NAME)
        val failing: suspend () -> String = { throw java.io.IOException("no network") }
        assertTrue("no file and no network, empty", PardalSource(file, download = failing, now = { now }).cameras().isEmpty())
        now += PardalSource.RETRY_MS
        PardalSource(file, download = { csv }, now = { now }).cameras()
        now += PardalSource.MAX_AGE_MS + 1
        assertEquals("the old one counts without network", 2, PardalSource(file, download = failing, now = { now }).cameras().size)
        var called = false
        val offline = PardalSource(file, download = { called = true; csv }, now = { now })
        assertEquals(2, offline.cameras(network = false).size)
        assertTrue("no network requested, no download", !called)
    }

    // prevents: a response that is not the CSV (a GitHub error page with 200) wiping the good file; and
    // the 857 KB downloaded again on every route, up to 4 per route with Overpass down, because nothing marked
    // the attempt (C16.7b second opinion, 2026-10-28).
    @Test
    fun aBadDownloadKeepsTheGoodFile() = runBlocking {
        var now = 1_000_000_000_000L
        val file = File(dir, PardalSource.FILE_NAME)
        PardalSource(file, download = { csv }, now = { now }).cameras()
        now += PardalSource.MAX_AGE_MS + 1
        var downloads = 0
        val bad: suspend () -> String = { downloads++; "<html>rate limited</html>" }
        val source = PardalSource(file, download = bad, now = { now })
        assertEquals(2, source.cameras().size)
        assertEquals(2, source.cameras().size)
        assertEquals("the next route does not download again", 1, downloads)
        assertEquals(2, PardalSource(file, download = bad, now = { now }).cameras().size)
        assertEquals("not even after the app reopens", 1, downloads)
        now += PardalSource.RETRY_MS
        PardalSource(file, download = bad, now = { now }).cameras()
        assertEquals("a day later, it tries again", 2, downloads)
    }

    // prevents: a write that fails (full disk, vanished folder) repeating the download on every route.
    @Test
    fun aFailedWriteIsNotRetriedOnTheNextRoute() = runBlocking {
        var downloads = 0
        val source = PardalSource(File(dir, "sumiu/" + PardalSource.FILE_NAME), download = { downloads++; csv }, now = { 1_000_000_000_000L })
        assertTrue(source.cameras().isEmpty())
        assertTrue(source.cameras().isEmpty())
        assertEquals(1, downloads)
    }

    // prevents: an endless body, or a gzip that OkHttp opens on its own, becoming `OutOfMemoryError` in
    // `string()`: it goes past `catch (e: Exception)`, and that route's OSM cameras are lost along with it,
    // because the pardal is read before Overpass (C16.7b second opinion, 2026-10-28).
    @Test
    fun aBodyOverTheCapIsRefused() {
        for ((what, served) in oversized(PardalSource.MAX_BODY_BYTES, csv)) {
            val read = runCatching { PardalSource.get(PardalSource.URL, answering(body = served)) }.exceptionOrNull()
            assertTrue("$what: got $read", read is IllegalStateException && "over" in read.message!!)
        }
        // And the real CSV goes through the same read.
        assertEquals(csv, PardalSource.get(PardalSource.URL, answering { csv.toResponseBody() }))
    }
}
