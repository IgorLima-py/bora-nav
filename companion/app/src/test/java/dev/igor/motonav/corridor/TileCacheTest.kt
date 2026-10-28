package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PointE5
import java.io.DataOutputStream
import java.io.File
import java.nio.file.Files
import java.util.zip.GZIPOutputStream
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The stored tiles (C16): a repeated route asks the network for nothing, and only OSM data per [TileId]
 * stays on disk, never the route.
 */
class TileCacheTest {

    private lateinit var dir: File
    private var clock = 1_760_000_000_000L

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-tiles").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun cache(maxTiles: Int = TileCache.MAX_TILES) = TileCache(dir, now = { clock }, maxTiles = maxTiles)

    private val tile = TileId(14, 6069, 9295)

    private val pieces = listOf(
        VectorTiles.Piece("primary", listOf(PointE5(-2354000, -4664000), PointE5(-2354100, -4663900)), cutStart = true, cutEnd = false),
        VectorTiles.Piece("residential_link", listOf(PointE5(-2354200, -4664100), PointE5(-2354250, -4664050), PointE5(-2354300, -4664000)), cutStart = false, cutEnd = true),
    )

    private fun assertSamePieces(expected: List<VectorTiles.Piece>, actual: List<VectorTiles.Piece>?) {
        assertEquals(expected.size, actual!!.size)
        expected.zip(actual).forEach { (e, a) ->
            assertEquals(e.highway, a.highway)
            assertEquals(e.points, a.points)
            assertEquals(e.cutStart, a.cutStart)
            assertEquals(e.cutEnd, a.cutEnd)
        }
    }

    @Test
    fun `a tile read back from disk is the same, in another process too`() {
        cache().put(tile, pieces)
        assertSamePieces(pieces, cache().get(tile))
        assertNull("another tile was not there", cache().get(TileId(14, 6070, 9295)))
    }

    @Test
    fun `an empty tile is kept, so the sea is not downloaded again`() {
        cache().put(tile, emptyList())
        assertEquals(emptyList<VectorTiles.Piece>(), cache().get(tile))
    }

    @Test
    fun `a month later the tile is gone and the file too`() {
        val c = cache()
        c.put(tile, pieces)
        clock += TileCache.MAX_AGE_MS
        assertNull(c.get(tile))
        assertFalse(File(dir, "14_6069_9295.bin").exists())
        // And it is valid again when the new tile is stored on top.
        c.put(tile, pieces)
        assertSamePieces(pieces, c.get(tile))
    }

    @Test
    fun `past the cap the oldest tile leaves`() {
        val c = cache(maxTiles = 2)
        c.put(TileId(14, 1, 1), pieces)
        clock += 1000
        c.put(TileId(14, 2, 2), pieces)
        clock += 1000
        c.put(TileId(14, 3, 3), pieces)
        val reread = cache(maxTiles = 2)
        assertNull("the oldest one left", reread.get(TileId(14, 1, 1)))
        assertSamePieces(pieces, reread.get(TileId(14, 2, 2)))
        assertSamePieces(pieces, reread.get(TileId(14, 3, 3)))
        assertEquals(2, dir.listFiles()!!.size)
    }

    @Test
    fun `a broken file is a miss and is deleted`() {
        dir.mkdirs()
        File(dir, "14_6069_9295.bin").writeBytes(byteArrayOf(1, 2, 3))
        assertNull(cache().get(tile))
        assertFalse(File(dir, "14_6069_9295.bin").exists())
    }

    // prevents: a file's broken count becoming `OutOfMemoryError` in `List(n)`, which goes past the
    // `catch` and leaves the tile without streets until it expires, without reaching the Overpass backup.
    @Test
    fun `a file with a broken count is a miss and is deleted`() {
        dir.mkdirs()
        val file = File(dir, "14_6069_9295.bin")
        DataOutputStream(GZIPOutputStream(file.outputStream())).use { out ->
            out.writeInt(TileCache.VERSION)
            out.writeLong(clock)
            out.writeInt(Int.MAX_VALUE)
        }
        assertNull(cache().get(tile))
        assertFalse(file.exists())
    }

    // prevents: a name with a number that does not fit in an `Int` taking down the index read, and with it every
    // `get` and every `put` of the cache.
    @Test
    fun `a file name out of range is dropped and the cache keeps working`() {
        dir.mkdirs()
        val odd = File(dir, "99999999999_0_0.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val c = cache()
        c.put(tile, pieces)
        assertSamePieces(pieces, c.get(tile))
        assertFalse(odd.exists())
    }
}
