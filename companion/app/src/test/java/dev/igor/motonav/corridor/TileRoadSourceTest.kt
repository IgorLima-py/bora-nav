package dev.igor.motonav.corridor

import dev.igor.motonav.net.answering
import dev.igor.motonav.net.oversized
import dev.igor.motonav.proto.PointE5
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.GZIPOutputStream
import kotlinx.coroutines.delay
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Vector tiles in place of Overpass (C16): the MVT reader, the polygon coverage, the clipping
 * at the edge, the stitching between tiles and the fallback. The tiles are built here, byte by byte, per spec
 * 2.1: no tile from any server goes into git.
 */
class TileRoadSourceTest {

    // ---- a minimal protobuf writer, only to build test tiles ----

    private class Pb {
        val out = ByteArrayOutputStream()
        fun varint(v: Long) {
            var x = v
            while (x and 0x7fL.inv() != 0L) {
                out.write(((x and 0x7f) or 0x80).toInt())
                x = x ushr 7
            }
            out.write(x.toInt())
        }
        fun tag(field: Int, wire: Int) = varint(((field shl 3) or wire).toLong())
        fun bytes(field: Int, b: ByteArray) { tag(field, 2); varint(b.size.toLong()); out.write(b) }
        fun string(field: Int, s: String) = bytes(field, s.toByteArray())
        fun uint(field: Int, v: Long) { tag(field, 0); varint(v) }
        fun packed(field: Int, values: List<Int>) {
            val inner = Pb()
            values.forEach { inner.varint(it.toLong() and 0xffffffffL) }
            bytes(field, inner.out.toByteArray())
        }
        fun toByteArray(): ByteArray = out.toByteArray()
    }

    private fun zz(n: Int) = (n shl 1) xor (n shr 31)

    /** Line geometry: each list of (x, y) becomes a MoveTo and a LineTo (spec §4.3). */
    private fun lineGeometry(vararg lines: List<Pair<Int, Int>>): List<Int> {
        val cmds = mutableListOf<Int>()
        var cx = 0
        var cy = 0
        for (line in lines) {
            cmds.add((1 and 0x7) or (1 shl 3))
            cmds.add(zz(line[0].first - cx)); cmds.add(zz(line[0].second - cy))
            cx = line[0].first; cy = line[0].second
            cmds.add((2 and 0x7) or ((line.size - 1) shl 3))
            for ((x, y) in line.drop(1)) {
                cmds.add(zz(x - cx)); cmds.add(zz(y - cy))
                cx = x; cy = y
            }
        }
        return cmds
    }

    private class Feature(val tags: Map<String, String>, val type: Int, val geometry: List<Int>)

    private fun layer(name: String, features: List<Feature>, extent: Int = 4096): ByteArray {
        val keys = features.flatMap { it.tags.keys }.distinct()
        val values = features.flatMap { it.tags.values }.distinct()
        val pb = Pb()
        pb.uint(15, 2)
        pb.string(1, name)
        for (f in features) {
            val fp = Pb()
            fp.packed(2, f.tags.flatMap { (k, v) -> listOf(keys.indexOf(k), values.indexOf(v)) })
            fp.uint(3, f.type.toLong())
            fp.packed(4, f.geometry)
            pb.bytes(2, fp.toByteArray())
        }
        keys.forEach { pb.string(3, it) }
        values.forEach { v -> pb.bytes(4, Pb().apply { string(1, v) }.toByteArray()) }
        pb.uint(5, extent.toLong())
        return pb.toByteArray()
    }

    private fun tile(vararg layers: ByteArray): ByteArray {
        val pb = Pb()
        layers.forEach { pb.bytes(3, it) }
        return pb.toByteArray()
    }

    private fun road(cls: String, vararg lines: List<Pair<Int, Int>>) =
        Feature(mapOf("class" to cls), 2, lineGeometry(*lines))

    private val schema = TileRoadSource.Schema("test", "road", setOf("class")) { p ->
        when (val c = p["class"]) {
            "street" -> "residential"
            "primary", "motorway" -> c as String
            else -> null
        }
    }

    // ---- the reader ----

    // prevents: the reader mixing up layers, losing the zigzag sign or joining the parts of a multiline.
    @Test
    fun `the reader takes the lines of the road layer and nothing else`() {
        val water = layer("water", listOf(Feature(mapOf("class" to "river"), 3, lineGeometry(listOf(0 to 0, 10 to 0, 10 to 10)))))
        val roads = layer(
            "road",
            listOf(
                road("street", listOf(100 to 200, 50 to 150, 300 to 400)),
                road("primary", listOf(10 to 10, 20 to 20), listOf(4000 to 10, 3990 to 4000)),
                Feature(mapOf("class" to "turning_circle"), 1, listOf((1 or (1 shl 3)), zz(5), zz(5))),
            ),
        )
        val lines = MvtReader.lines(tile(water, roads), "road", setOf("class"))
        assertEquals(3, lines.size)
        assertEquals("street", lines[0].properties["class"])
        assertEquals(listOf(100, 50, 300), lines[0].xs.toList())
        assertEquals(listOf(200, 150, 400), lines[0].ys.toList())
        assertEquals(listOf(4000, 3990), lines[2].xs.toList())
        assertEquals(4096, lines[0].extent)
    }

    // prevents: the server that sends the `.pbf` gzipped without `Content-Encoding` becoming "tile … unreadable".
    @Test
    fun `a gzipped tile reads the same`() {
        val raw = tile(layer("road", listOf(road("street", listOf(0 to 0, 100 to 100)))))
        val gz = ByteArrayOutputStream().also { GZIPOutputStream(it).use { z -> z.write(raw) } }.toByteArray()
        assertEquals(1, MvtReader.lines(gz, "road", setOf("class")).size)
    }

    // ---- the tile math ----

    private fun e5(deg: Double) = OverpassClient.quantize(deg)

    // prevents: the tile math getting São Paulo's tile wrong (the same as the XYZ servers' `tile()`).
    @Test
    fun `the tile of downtown Sao Paulo at z14`() {
        assertEquals(6069, VectorTiles.tileX(-46.6333, 14).toInt())
        assertEquals(9295, VectorTiles.tileY(-23.5505, 14).toInt())
        assertEquals(-23.5505, VectorTiles.latOf(VectorTiles.tileY(-23.5505, 14), 14), 1e-9)
    }

    // prevents: a tile that the polygon only crosses being left out, or the middle one of a large polygon.
    @Test
    fun `the cover takes the tiles the border crosses and the ones inside`() {
        val z = 14
        fun lon(tx: Double) = e5(VectorTiles.lonOf(tx, z))
        fun lat(ty: Double) = e5(VectorTiles.latOf(ty, z))
        // A thin ribbon from 6069.2 to 6071.8 on row 9301: three tiles.
        val ribbon = listOf(
            PointE5(lat(9301.4), lon(6069.2)), PointE5(lat(9301.4), lon(6071.8)),
            PointE5(lat(9301.6), lon(6071.8)), PointE5(lat(9301.6), lon(6069.2)),
        )
        assertEquals(setOf(6069, 6070, 6071), VectorTiles.cover(ribbon, z).map { it.x }.toSet())
        // A 3x3 tile square: the center one does not touch the edge and has to be included.
        val square = listOf(
            PointE5(lat(9300.5), lon(6068.5)), PointE5(lat(9300.5), lon(6071.5)),
            PointE5(lat(9303.5), lon(6071.5)), PointE5(lat(9303.5), lon(6068.5)),
        )
        val tiles = VectorTiles.cover(square, z).toSet()
        assertEquals(16, tiles.size)
        assertTrue(TileId(z, 6069, 9301) in tiles && TileId(z, 6070, 9302) in tiles)
    }

    // prevents: the same street twice in the buffer band, once from each neighboring tile.
    @Test
    fun `the clip drops the buffer and marks the cut ends`() {
        val line = MvtReader.Line(emptyMap(), intArrayOf(-64, 2048, 4160), intArrayOf(1000, 1000, 1000), 4096)
        val pieces = VectorTiles.clipToTile(line, TileId(14, 6069, 9301), "residential")
        assertEquals(1, pieces.size)
        val p = pieces[0]
        assertTrue(p.cutStart && p.cutEnd)
        assertEquals(e5(VectorTiles.lonOf(6069.0, 14)), p.points.first().lon)
        assertEquals(e5(VectorTiles.lonOf(6070.0, 14)), p.points.last().lon)
        // A line that leaves and comes back becomes two pieces.
        val zigzag = MvtReader.Line(emptyMap(), intArrayOf(100, 100, 100), intArrayOf(100, -500, 200), 4096)
        assertEquals(2, VectorTiles.clipToTile(zigzag, TileId(14, 6069, 9301), "residential").size)
    }

    // prevents: the street split by the tile edge becoming two ways (and the corner piece, under 20 m, vanishing).
    @Test
    fun `the stitch joins what the tile border split and nothing else`() {
        val a = VectorTiles.Piece("residential", listOf(PointE5(0, 0), PointE5(0, 100)), cutStart = false, cutEnd = true)
        val b = VectorTiles.Piece("residential", listOf(PointE5(200, 300), PointE5(1, 101)), cutStart = false, cutEnd = true)
        val other = VectorTiles.Piece("primary", listOf(PointE5(0, 101), PointE5(0, 500)), cutStart = true, cutEnd = false)
        val junction = VectorTiles.Piece("residential", listOf(PointE5(0, 0), PointE5(-100, 0)), cutStart = false, cutEnd = false)
        val ways = VectorTiles.stitch(listOf(a, b, other, junction))
        assertEquals(3, ways.size)
        val joined = ways.first { it.points.size == 3 }
        assertEquals(listOf(PointE5(0, 0), PointE5(0, 100), PointE5(200, 300)), joined.points)
    }

    // ---- the whole source, with the network swapped ----

    /** A source that answers [tiles] by the `z/x/y` URL; a missing tile is an empty tile. */
    private fun source(tiles: Map<TileId, ByteArray>, cache: TileCache? = null, fail: (TileId, Int) -> Int? = { _, _ -> null }) =
        object : TileRoadSource("test", schema, template = { "{z}/{x}/{y}" }, cache = cache) {
            val calls = HashMap<TileId, Int>()
            override suspend fun download(url: String): ByteArray {
                val (z, x, y) = url.split("/").map { it.toInt() }
                val id = TileId(z, x, y)
                val n = synchronized(calls) { (calls[id] ?: 0) + 1 }.also { synchronized(calls) { calls[id] = it } }
                fail(id, n)?.let { code -> throw RoadSourceException("HTTP $code", retryable = code >= 500) }
                return tiles[id] ?: ByteArray(0)
            }
        }

    private val z = 14
    private fun lon(tx: Double) = e5(VectorTiles.lonOf(tx, z))
    private fun lat(ty: Double) = e5(VectorTiles.latOf(ty, z))

    /** A ribbon over tiles 6069 and 6070 of row 9301. */
    private val twoTiles = listOf(
        PointE5(lat(9301.4), lon(6069.5)), PointE5(lat(9301.4), lon(6070.5)),
        PointE5(lat(9301.6), lon(6070.5)), PointE5(lat(9301.6), lon(6069.5)),
    )

    private val roadsAcross = mapOf(
        // A street that crosses the 6069|6070 edge, with the 64 buffer on each side.
        TileId(z, 6069, 9301) to tile(layer("road", listOf(road("street", listOf(3000 to 2000, 4160 to 2000)), road("path", listOf(0 to 0, 9 to 9))))),
        TileId(z, 6070, 9301) to tile(layer("road", listOf(road("street", listOf(-64 to 2000, 1000 to 2000)), road("primary", listOf(0 to 100, 4096 to 100))))),
    )

    // prevents: the tile source returning the split street, the way outside the filter or anything other than the Overpass contract.
    @Test
    fun `two tiles give the street once and the primary, and the path is left out`() {
        val ways = runBlocking { source(roadsAcross).fetch(twoTiles) }
        assertEquals(listOf("primary", "residential"), ways.map { it.highway }.sorted())
        val street = ways.first { it.highway == "residential" }
        assertEquals(3, street.points.size)
        assertEquals(lon(6069.0 + 3000.0 / 4096), street.points.first().lon)
        assertEquals(lon(6070.0 + 1000.0 / 4096), street.points.last().lon)
    }

    // prevents: a passing 503 taking down the corridor, or a 401 (token) being retried for nothing.
    @Test
    fun `a tile gets one retry on 5xx and none on 401`() {
        val flaky = source(roadsAcross) { id, n -> if (id.x == 6070 && n == 1) 503 else null }
        assertEquals(2, runBlocking { flaky.fetch(twoTiles) }.size)
        val denied = source(roadsAcross) { _, _ -> 401 }
        val failed = runCatching { runBlocking { denied.fetch(twoTiles) } }.exceptionOrNull()
        assertTrue(failed is RoadSourceException)
        assertTrue("401 is not repeated: ${denied.calls}", denied.calls.values.all { it == 1 })
    }

    // prevents: half a corridor, with a 2 km hole where the tile was missing, with nobody knowing.
    @Test(expected = RoadSourceException::class)
    fun `a tile that fails twice fails the whole fetch`() {
        runBlocking { source(roadsAcross) { id, _ -> if (id.x == 6069) 502 else null }.fetch(twoTiles) }
    }

    // prevents: the repeated route downloading everything again, or the stored tile giving a different street than the downloaded one.
    @Test
    fun `a cached tile is not downloaded again and gives the same streets`() {
        val dir = Files.createTempDirectory("motonav-tiles").toFile()
        try {
            val count = VectorTiles.cover(twoTiles, z).size
            val first = source(roadsAcross, TileCache(dir))
            val fresh = runBlocking { first.fetch(twoTiles) }
            assertEquals(count, first.calls.size)

            // Another process, the same directory: nothing goes to the network, and the streets come out the same.
            val second = source(roadsAcross, TileCache(dir))
            val cached = runBlocking { second.fetch(twoTiles) }
            assertTrue("no download: ${second.calls}", second.calls.isEmpty())
            assertEquals(count, second.lastStats!!.cached)
            assertEquals(fresh.map { it.highway to it.points }, cached.map { it.highway to it.points })

            // The tile that vanished from disk is the only one that gets downloaded.
            assertTrue(File(dir, "14_6070_9301.bin").delete())
            val third = source(roadsAcross, TileCache(dir))
            runBlocking { third.fetch(twoTiles) }
            assertEquals(setOf(TileId(z, 6070, 9301)), third.calls.keys)
        } finally {
            dir.deleteRecursively()
        }
    }

    // ---- the tile cap ----

    /**
     * The whole source, with OkHttp and its body reading: only the network is swapped, by an
     * interceptor that answers [body] for each tile and counts the calls in [calls].
     */
    private fun servedBy(calls: AtomicInteger = AtomicInteger(), body: (TileId) -> ResponseBody) = TileRoadSource(
        "test",
        schema,
        template = { "https://tiles.invalid/{z}/{x}/{y}" },
        client = OkHttpClient.Builder().addInterceptor { chain ->
            calls.incrementAndGet()
            val (z, x, y) = chain.request().url.pathSegments.map { it.toInt() }
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body(body(TileId(z, x, y))).build()
        }.build(),
    )

    /** 64 MB of zeros in gzip: ~64 KB that open into sixteen times the cap. */
    private val gzipBomb: ByteArray by lazy {
        val zeros = ByteArray(1024 * 1024)
        ByteArrayOutputStream().also { out -> GZIPOutputStream(out).use { z -> repeat(64) { z.write(zeros) } } }.toByteArray()
    }

    private fun failureOf(source: RoadSource): Throwable? =
        runCatching { runBlocking { source.fetch(twoTiles) } }.exceptionOrNull()

    // prevents: the gzip bomb from a server that sends the `.pbf` compressed without `Content-Encoding` becoming
    // `OutOfMemoryError` in `MvtReader`: it is an `Error`, goes past the `catch (e: Exception)` and takes down the
    // companion in the middle of the navigation, without ever reaching the Overpass backup.
    @Test
    fun `a gzip bomb in the body fails the fetch and the reserve answers`() {
        val failed = failureOf(servedBy { gzipBomb.toResponseBody() })
        assertTrue("got $failed", failed is RoadSourceException && !failed.retryable)
        val fallback = FallbackRoadSource(servedBy { gzipBomb.toResponseBody() }, RoadSource { one }, "tiles")
        assertEquals(one, runBlocking { fallback.fetch(twoTiles) })
    }

    // prevents: the same gzip bomb with `Content-Encoding: gzip`, which OkHttp opens on its own before
    // `read` (via `GzipSource`, with no known size), becoming `OutOfMemoryError` in `bytes()`.
    @Test
    fun `a gzip bomb opened by OkHttp stops at the cap`() {
        val failed = failureOf(servedBy { GzipSource(Buffer().write(gzipBomb)).buffer().asResponseBody(null, -1) })
        assertTrue("got $failed", failed is RoadSourceException && !failed.retryable)
        assertTrue(failed!!.message!!, "over" in failed.message!!)
    }

    // prevents: a body larger than the cap being read whole into memory, or getting the network's second chance:
    // the tile does not change the other time.
    @Test
    fun `a body over the cap fails at once, without the retry`() {
        val calls = AtomicInteger()
        val failed = failureOf(servedBy(calls) { ByteArray(MvtReader.MAX_TILE_BYTES + 1).toResponseBody() })
        assertTrue("got $failed", failed is RoadSourceException && !failed.retryable)
        assertTrue("no second chance: ${calls.get()} calls for 2 tiles", calls.get() <= 2)
        // And the real tiles, below the cap, go through the same read as before.
        val ways = runBlocking { servedBy { id -> roadsAcross.getValue(id).toResponseBody() }.fetch(twoTiles) }
        assertEquals(listOf("primary", "residential"), ways.map { it.highway }.sorted())
    }

    // prevents: OpenFreeMap's TileJSON, read before any tile, becoming `OutOfMemoryError` with an endless
    // body or a gzip that OkHttp opens on its own, without ever reaching the Overpass backup.
    @Test
    fun `a TileJSON over the cap fails the fetch and the reserve answers`() {
        val tileJson = """{"tilejson":"3.0.0","tiles":["https://tiles.invalid/planet/20261011/{z}/{x}/{y}.pbf"]}"""
        for ((what, served) in oversized(TileRoadSource.MAX_TILEJSON_BYTES, tileJson)) {
            val template = TileRoadSource.tileJsonTemplate("https://tiles.invalid/planet", answering(body = served))
            val failed = runCatching { runBlocking { template() } }.exceptionOrNull()
            assertTrue("$what: got $failed", failed is RoadSourceException && "over" in failed.message!!)
            val fallback = FallbackRoadSource(TileRoadSource.openFreeMap(answering(body = served)), RoadSource { one }, "OpenFreeMap")
            assertEquals(what, one, runBlocking { fallback.fetch(twoTiles) })
        }
        // And the real TileJSON goes through the same read.
        val template = TileRoadSource.tileJsonTemplate("https://tiles.invalid/planet", answering { tileJson.toResponseBody() })
        assertEquals("https://tiles.invalid/planet/20261011/{z}/{x}/{y}.pbf", runBlocking { template() })
    }

    // ---- the schemas ----

    // prevents: the ramp becoming the main way (or vanishing), and the service street entering the map.
    @Test
    fun `the schemas map back to the OSM highway of the Overpass filter`() {
        val omt = RoadSchemas.OPENMAPTILES.highwayOf
        assertEquals("residential", omt(mapOf("class" to "minor")))
        assertEquals("motorway_link", omt(mapOf("class" to "motorway", "ramp" to 1L)))
        assertEquals("primary", omt(mapOf("class" to "primary", "ramp" to 0L)))
        assertEquals(null, omt(mapOf("class" to "tertiary", "ramp" to 1L)))
        assertEquals(null, omt(mapOf("class" to "service")))
        val sb = RoadSchemas.SHORTBREAD.highwayOf
        assertEquals("unclassified", sb(mapOf("kind" to "unclassified")))
        assertEquals("trunk_link", sb(mapOf("kind" to "trunk", "link" to true)))
        assertEquals(null, sb(mapOf("kind" to "living_street")))
        assertEquals(null, sb(mapOf("kind" to "footway")))
        val pm = RoadSchemas.PROTOMAPS.highwayOf
        assertEquals("secondary_link", pm(mapOf("kind_detail" to "secondary", "is_link" to true)))
        assertEquals("residential", pm(mapOf("kind_detail" to "residential")))
    }

    // ---- a reserva ----

    private val one = listOf(OsmWay("residential", listOf(PointE5(0, 0), PointE5(1, 1))))

    // prevents: the failure (or delay, or emptiness) of the tiles leaving the corridor without the Overpass backup.
    @Test
    fun `the fallback goes to the reserve when the tiles fail, hang or come empty`() = runBlocking {
        var reserveCalls = 0
        val reserve = RoadSource { reserveCalls++; one }
        val failing = FallbackRoadSource(RoadSource { throw RoadSourceException("401") }, reserve, "tiles")
        val hanging = FallbackRoadSource(RoadSource { delay(5_000); one }, reserve, "tiles", primaryBudgetMs = 50)
        val empty = FallbackRoadSource(RoadSource { emptyList() }, reserve, "tiles")
        assertEquals(one, failing.fetch(twoTiles))
        assertEquals(one, hanging.fetch(twoTiles))
        assertEquals(one, empty.fetch(twoTiles))
        assertEquals(3, reserveCalls)
        val fine = FallbackRoadSource(RoadSource { one }, RoadSource { error("Overpass should not have been called") }, "tiles")
        assertEquals(one, fine.fetch(twoTiles))
        assertFalse(reserveCalls > 3)
    }
}
