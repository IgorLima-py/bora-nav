package dev.igor.motonav.proto

import dev.igor.motonav.route.MapboxRouteParser
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The packer is validated against the very fixtures tools/packer.py generates.
 * A mismatch here means the two implementations of docs/05-PROTOCOL.md drifted —
 * the single most likely defect in this project (05 §Test vectors).
 */
class ProtocolPackerTest {

    private val fixtures = File("../../tools/fixtures")

    private fun route() = MapboxRouteParser
        .parse(File(fixtures, "route_sample.json").readText(Charsets.UTF_8), DEST_NAME)
        .toPackable(routeId = ROUTE_ID)

    @Test
    fun `fixtures are present`() {
        assertTrue("run: python tools/packer.py --route … --out tools/fixtures/", fixtures.isDirectory)
    }

    @Test
    fun `route meta matches the python fixture`() {
        // The fixture is generated with the synthetic corridor, and the META announces how many
        // LODs will come — hence the corridorLodCount here.
        val expected = File(fixtures, "meta_00.bin").readBytes()
        val route = route().copy(corridorLodCount = FIXTURE_LOD_COUNT)
        val actual = ProtocolPacker.chunk(Protocol.MSG_ROUTE_META, ROUTE_ID, ProtocolPacker.packRouteMeta(route))
        assertEquals(1, actual.size)
        assertArrayEquals(expected, actual[0])
    }

    @Test
    fun `buildRouteBlocks announces the corridor LOD count in the meta`() {
        val route = route()
        val withCorridor = ProtocolPacker.buildRouteBlocks(route, corridor = syntheticCorridor(route))
        val without = ProtocolPacker.buildRouteBlocks(route)

        assertArrayEquals(
            "the META of the full build must match the fixture",
            File(fixtures, "meta_00.bin").readBytes(),
            withCorridor[0].chunks[0],
        )
        // Without a corridor the field is 0, and the watch does not wait for any block.
        // META layout (05 §ROUTE_META): 16 B of numbers, destName with a
        // 1 B prefix, then polyPointCount(2) + turnCount(1) + corridorLodCount(1).
        val lodCountAt = Protocol.HEADER_SIZE + 17 + DEST_NAME.toByteArray(Charsets.UTF_8).size + 3
        assertEquals(0, without[0].chunks[0][lodCountAt].toInt())
        assertEquals(FIXTURE_LOD_COUNT, withCorridor[0].chunks[0][lodCountAt].toInt())
    }

    @Test
    fun `route polyline matches the python fixture`() {
        val expected = File(fixtures, "poly_00.bin").readBytes()
        val actual = ProtocolPacker.chunk(Protocol.MSG_ROUTE_POLY, ROUTE_ID, ProtocolPacker.packRoutePoly(route()))
        assertEquals(1, actual.size)
        assertArrayEquals(expected, actual[0])
    }

    @Test
    fun `turns match the python fixture`() {
        val expected = File(fixtures, "turns_00.bin").readBytes()
        val actual = ProtocolPacker.chunk(Protocol.MSG_TURNS, ROUTE_ID, ProtocolPacker.packTurns(route()))
        assertEquals(1, actual.size)
        assertArrayEquals(expected, actual[0])
    }

    @Test
    fun `every corridor LOD matches the python fixture`() {
        val route = route()
        val corridor = syntheticCorridor(route)

        assertEquals("o packer python gerou 4 LODs", 4, corridor.nonEmptyLods().size)
        for (lod in corridor.nonEmptyLods()) {
            val expected = File(fixtures, "corridor_lod${lod}_00.bin").readBytes()
            val payload = ProtocolPacker.packCorridor(lod, corridor.ways[lod], route.lat0, route.lon0)
            val actual = ProtocolPacker.chunk(Protocol.MSG_CORRIDOR, ROUTE_ID, payload)
            assertEquals(1, actual.size)
            assertArrayEquals("LOD $lod diverged from the fixture", expected, actual[0])
        }
    }

    @Test
    fun `a way past the uint8 ceiling is cut with a shared vertex`() {
        val points = (0 until 300).map { PointE5(-2356145 + it, -4665584) }
        val pieces = ProtocolPacker.splitWay(points)

        assertEquals(2, pieces.size)
        assertEquals(Protocol.MAX_WAY_POINTS, pieces[0].size)
        assertEquals(46, pieces[1].size)
        assertEquals("the pieces share the cut vertex", pieces[0].last(), pieces[1].first())
        assertEquals(
            "no segment is lost in the cut",
            points.size - 1,
            pieces.sumOf { it.size - 1 },
        )
    }

    @Test
    fun `the corridor caps drop whole LODs, locals first`() {
        val fat = List(Protocol.MAX_WAY_POINTS) { PointE5(-2356145 + it, -4665584) }
        val corridor = PackableCorridor(
            ways = listOf(
                listOf(fat),
                listOf(fat),
                List(8) { fat },
                List(8) { fat },
            ),
        )
        assertTrue(corridor.segmentCount() > Protocol.MAX_CORRIDOR_SEGMENTS)

        val (capped, dropped) = corridor.capped(-2356145, -4665584)

        assertTrue("the local streets go first", dropped.first().startsWith("LOD ${Protocol.LOD_LOCAL}"))
        assertTrue(capped.segmentCount() <= Protocol.MAX_CORRIDOR_SEGMENTS)
        assertTrue("express and arterial are never dropped", capped.ways[Protocol.LOD_EXPRESS].isNotEmpty())
        assertTrue(capped.ways[Protocol.LOD_ARTERIAL].isNotEmpty())
    }

    @Test
    fun `corridor blocks come after the route and carry msgType 0x04`() {
        val route = route()
        val blocks = ProtocolPacker.buildRouteBlocks(route, corridor = syntheticCorridor(route))

        assertEquals(7, blocks.size)
        assertEquals(
            listOf(
                Protocol.MSG_ROUTE_META,
                Protocol.MSG_ROUTE_POLY,
                Protocol.MSG_TURNS,
                Protocol.MSG_CORRIDOR,
                Protocol.MSG_CORRIDOR,
                Protocol.MSG_CORRIDOR,
                Protocol.MSG_CORRIDOR,
            ),
            blocks.map { it.msgType },
        )
    }

    /**
     * Exact mirror of `synthetic_corridor` in `tools/packer.py` — it is what makes
     * the byte-by-byte comparison above possible without calling Overpass. The shape was
     * chosen there to exercise every branch of the encoder: a way going past the 255-point
     * ceiling, several ways per block and offsets big enough
     * to force the int32 on the first point of each way.
     */
    private fun syntheticCorridor(route: PackableRoute): PackableCorridor {
        fun shifted(start: Int, count: Int, dLat: Int, dLon: Int): List<PointE5> =
            route.points.subList(start, minOf(start + count, route.points.size))
                .map { PointE5(it.lat + dLat, it.lon + dLon) }

        return PackableCorridor(
            ways = listOf(
                listOf(shifted(0, 300, 200, -200)),
                listOf(shifted(20, 40, -150, 120), shifted(120, 40, -150, 120)),
                (0 until 3).map { shifted(it * 60, 12, 90, 90) },
                (0 until 5).map { shifted(it * 40 + 5, 6, -60, -60) },
            ).map { lod -> lod.filter { it.size >= 2 } },
        )
    }

    @Test
    fun `header carries version type route seq total and length`() {
        val message = ProtocolPacker.frame(Protocol.MSG_TURNS, 0x0102, 3, 7, byteArrayOf(0xAA.toByte()))
        assertArrayEquals(
            byteArrayOf(Protocol.VERSION.toByte(), Protocol.MSG_TURNS.toByte(), 0x01, 0x02, 3, 7, 0x00, 0x01, 0xAA.toByte()),
            message,
        )
    }

    @Test
    fun `chunking splits on the payload boundary and numbers every chunk`() {
        val payload = ByteArray(Protocol.MAX_CHUNK_PAYLOAD + 1) { (it % 251).toByte() }
        val chunks = ProtocolPacker.chunk(Protocol.MSG_CORRIDOR, 9, payload)

        assertEquals(2, chunks.size)
        assertEquals(Protocol.CHUNK_SIZE, chunks[0].size)
        assertEquals(Protocol.HEADER_SIZE + 1, chunks[1].size)
        chunks.forEachIndexed { seq, message ->
            assertEquals(seq, message[4].toInt())
            assertEquals(2, message[5].toInt())
        }
        val rebuilt = chunks.fold(ByteArray(0)) { acc, m -> acc + m.copyOfRange(Protocol.HEADER_SIZE, m.size) }
        assertArrayEquals(payload, rebuilt)
    }

    @Test
    fun `long deltas fall back to the escape pair`() {
        // ~0.5 degree apart: does not fit in an int16 delta.
        val points = listOf(PointE5(-2356145, -4665584), PointE5(-2306145, -4665584))
        val encoded = ProtocolPacker.encodePoints(points, points[0].lat, points[0].lon)

        assertEquals(8 + 4 + 8, encoded.size)
        assertEquals(0x7F, encoded[8].toInt() and 0xFF)
        assertEquals(0xFF, encoded[9].toInt() and 0xFF)
    }

    @Test
    fun `street names are cut on a character boundary`() {
        val name = "Rua General Panteleão Teles do Amaral"
        val packed = ProtocolPacker.packString(name, Protocol.MAX_STREET_NAME_BYTES)
        val text = String(packed, 1, packed[0].toInt(), Charsets.UTF_8)

        assertTrue(packed[0].toInt() <= Protocol.MAX_STREET_NAME_BYTES)
        assertTrue(name.startsWith(text))
        assertTrue("truncation split a multibyte char", text.none { it == '�' })
    }

    @Test
    fun `quantization breaks ties away from zero, like python`() {
        assertEquals(-2356146, MapboxRouteParser.quantizeE6(-23561455))
        assertEquals(2356146, MapboxRouteParser.quantizeE6(23561455))
        assertEquals(-2356145, MapboxRouteParser.quantizeE6(-23561454))
    }

    /**
     * CONFIG (05 §CONFIG, C5) against the packer.py `config_00.bin` — the same
     * file that the watch's `ConfigTest.parsesTheFixture` reads. The values are
     * the packer.py `CONFIG_SAMPLE`, mirrored by hand by name.
     */
    @Test
    fun configMatchesFixture() {
        val expected = File(fixtures, "config_00.bin").readBytes()
        val sample = mapOf(
            "lead_s" to 10,
            "lead_min_m" to 100,
            "near_m" to 30,
            "pulse_ms" to 250,
            "zoom" to 2,
            "corridor_pct" to 120,
            "hud_pct" to 95,
            "orbit_px" to 3,
            "orbit_s" to 30,
            "dist_pct" to 80,
            "eta_pct" to 90,
            "text_pct" to 70,
            "arrow_pct" to 85,
            "plate_w_pct" to 60,
            "plate_h_pct" to 40,
            "gps_drill_min" to 8,
            "street_img" to 0,
            "map_tilt" to 0,
            "street_16bit" to 0,
            "street_diag" to 3,
            "vibe_on" to 1,
            "radar_vibe" to 0,
        )
        val block = ProtocolPacker.buildConfigBlock(ConfigKey.parse(sample))
        assertEquals(Protocol.MSG_CONFIG, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    /**
     * RADARS (05 §RADARS, C16.6) against `radars_00.bin`, the packer.py `RADARS_SAMPLE`
     * mirrored by hand, on the fixture route (routeId 1, the default of `packer.py --route`).
     */
    @Test
    fun radarsMatchFixture() {
        val expected = File(fixtures, "radars_00.bin").readBytes()
        val sample = listOf(
            WireRadar(distAlongM = 1200, dLat = -850, dLon = 410, limitKmh = 50, flags = Protocol.RADAR_FLAG_DIRECTION),
            WireRadar(distAlongM = 5400, dLat = -3120, dLon = 1900, limitKmh = 0, flags = Protocol.RADAR_FLAG_DIRECTION),
            WireRadar(distAlongM = 9800, dLat = -6010, dLon = 2250, limitKmh = 60, flags = 0),
        )
        val block = ProtocolPacker.buildRadarsBlock(1, sample)
        assertEquals(Protocol.MSG_RADARS, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    @Test
    fun `radars out of order or over the cap do not pack`() {
        val a = WireRadar(5400, 0, 0, 50, 1)
        val b = WireRadar(1200, 0, 0, 50, 1)
        assertThrows(IllegalArgumentException::class.java) { ProtocolPacker.packRadars(listOf(a, b)) }
        val many = (0..Protocol.MAX_RADARS).map { WireRadar(it * 100L, it, -it, 40, 1) }
        assertThrows(IllegalArgumentException::class.java) { ProtocolPacker.packRadars(many) }
        assertEquals(2 + 14 * 200, ProtocolPacker.packRadars(many.take(200)).size)
    }

    @Test
    fun `an empty config is the reset message`() {
        val block = ProtocolPacker.buildConfigBlock(emptyList())
        // header (version, 0x09, routeId 0, seq 0, total 1, len 1) + count 0
        assertArrayEquals(byteArrayOf(Protocol.VERSION.toByte(), 9, 0, 0, 0, 1, 0, 1, 0), block.chunks[0])
    }

    /**
     * FAVORITES (05 §FAVORITES, C12) against the packer.py `favorites_00.bin`: the
     * same file that the watch's `FavoritesTest.parsesTheFixture` reads. Only
     * public places, as the fixture requires. The values are the `FAVORITES_SAMPLE`.
     */
    // prevents: packing a favorite in a way the watch does not read (ids out of order, multibyte
    // name, coordinate sign): the watch would list garbage or refuse the whole list.
    @Test
    fun favoritesMatchFixture() {
        val expected = File(fixtures, "favorites_00.bin").readBytes()
        val sample = listOf(
            WireFavorite(favId = 1, latE5 = -2354522, lonE5 = -4664218, name = "Copan", icon = 2),
            WireFavorite(favId = 2, latE5 = -2356135, lonE5 = -4665589, name = "MASP", icon = 3),
            WireFavorite(favId = 4, latE5 = -2355050, lonE5 = -4663340, name = "Praça da Sé", icon = 5),
        )
        val block = ProtocolPacker.buildFavoritesBlock(sample)
        assertEquals(Protocol.MSG_FAVORITES, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    // prevents: the "Recentes" list (C16.5) going out in a format the watch does not read, or with the type of
    // FAVORITES and wiping its favorites: `recents_00.bin` is the same one the watch reproduces.
    @Test
    fun recentsMatchFixture() {
        val expected = File(fixtures, "recents_00.bin").readBytes()
        val sample = listOf(
            WireFavorite(favId = 0, latE5 = -2353475, lonE5 = -4663494, name = "Estação da Luz", icon = 0),
            WireFavorite(favId = 3, latE5 = -2358742, lonE5 = -4665755, name = "Ibirapuera", icon = 0),
        )
        val block = ProtocolPacker.buildRecentsBlock(sample)
        assertEquals(Protocol.MSG_RECENTS, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    // prevents: a favorite name over 20 B cut in the middle of a letter (invalid UTF-8
    // on the watch) — 08 §Pitfalls 6. "í" is 2 B: the cut at 20 falls inside it.
    @Test
    fun `a favorite name is cut on a codepoint at 20 bytes`() {
        val name = "Escritório no Paraíso, Sé" // 'í' takes bytes 19 and 20: the cut falls inside it
        val block = ProtocolPacker.buildFavoritesBlock(
            listOf(WireFavorite(favId = 1, latE5 = 1, lonE5 = 2, name = name, icon = 0)),
        )
        val payload = block.chunks[0].copyOfRange(Protocol.HEADER_SIZE, block.chunks[0].size)
        val nameLen = payload[1 + 1 + 8].toInt() and 0xFF
        val bytes = payload.copyOfRange(1 + 1 + 8 + 1, 1 + 1 + 8 + 1 + nameLen)
        assertTrue("up to 20 B", nameLen <= 20)
        val decoded = String(bytes, Charsets.UTF_8)
        assertTrue("no U+FFFD: the cut does not split a letter", '�' !in decoded)
        assertTrue("is a prefix of the name", name.startsWith(decoded))
    }

    // prevents: sending the watch a list it refuses whole (more than 6 items): Igor
    // would add the 7th favorite and the list on the watch would be stuck on the old version.
    @Test
    fun `more than six favorites do not fit the message`() {
        val seven = (1..7).map { WireFavorite(favId = it, latE5 = it, lonE5 = it, name = "F$it", icon = 0) }

        assertThrows(IllegalArgumentException::class.java) { ProtocolPacker.buildFavoritesBlock(seven) }
    }

    /**
     * ROUTE_UPDATE (05 §ROUTE_UPDATE, C13a) against the `route_update_00.bin` of
     * packer.py: the same file that the watch's `RouteUpdateTest` applies. The
     * values are the `ROUTE_UPDATE_SAMPLE`.
     */
    // prevents: sending the duration with the wrong width or endianness (2 bytes, little-endian) and the
    // watch showing an absurd ETA, or refusing every update and the phone ending the session.
    @Test
    fun routeUpdateMatchesFixture() {
        val expected = File(fixtures, "route_update_00.bin").readBytes()
        val block = ProtocolPacker.buildRouteUpdateBlock(routeId = 7, durationS = 0x00010203)
        assertEquals(Protocol.MSG_ROUTE_UPDATE, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    // prevents: a zero or negative ETA leaving the phone (odd response from the provider): the
    // watch would refuse it, and the refusal ends the session on the phone.
    @Test
    fun `a route update without a positive duration is not packed`() {
        assertThrows(IllegalArgumentException::class.java) { ProtocolPacker.buildRouteUpdateBlock(7, 0) }
        assertThrows(IllegalArgumentException::class.java) { ProtocolPacker.buildRouteUpdateBlock(7, -1) }
    }

    /**
     * PHONE_FIX (C13b): the phone's GPS fix, 16 bytes, against `phone_fix_00.bin`, the
     * same fixture the watch reads (`PhoneFixTest.parsesTheFixture`). The place is MASP.
     */
    // prevents: the phone fix going out with one field in place of another (the accuracy where the watch
    // reads the speed), or with the wrong endianness, and the watch putting the bike somewhere else.
    @Test
    fun phoneFixMatchesFixture() {
        val expected = File(fixtures, "phone_fix_00.bin").readBytes()
        val block = ProtocolPacker.buildPhoneFixBlock(
            latE5 = -2356141,
            lonE5 = -4665588,
            speedDms = 300,
            headingDeg = 271,
            accuracyM = 12,
            ageMs = 850,
        )
        assertEquals(Protocol.MSG_PHONE_FIX, block.msgType)
        assertEquals(1, block.chunks.size)
        assertArrayEquals(expected, block.chunks[0])
    }

    // prevents: an old fix, or one too imprecise for 16 bits, wrapping around and reaching the watch
    // as new and precise (70 s of age becoming 4.4 s), and the stopped phone sending heading 0
    // (north) instead of "unknown".
    @Test
    fun `a phone fix saturates what does not fit and says when it has no heading`() {
        val payload = ProtocolPacker.packPhoneFix(
            latE5 = -2356141,
            lonE5 = -4665588,
            speedDms = 70_000,
            headingDeg = null,
            accuracyM = 100_000,
            ageMs = 70_000,
        )
        assertEquals(ProtocolPacker.PHONE_FIX_SIZE, payload.size)
        for (field in listOf(8, 10, 12, 14)) {
            assertEquals("field at offset $field", 0xFF.toByte(), payload[field])
            assertEquals("field at offset $field", 0xFF.toByte(), payload[field + 1])
        }
        val turned = ProtocolPacker.packPhoneFix(0, 0, 0, headingDeg = 360, accuracyM = 0, ageMs = 0)
        assertEquals("360 is not a heading", 0xFF.toByte(), turned[10])
    }

    // prevents: an impossible coordinate (garbage Location) going out to the watch, and the error's own
    // message carrying the phone position into the log.
    @Test
    fun `a phone fix that is not a place is not packed`() {
        val error = assertThrows(IllegalArgumentException::class.java) {
            ProtocolPacker.packPhoneFix(9_000_001, -4665588, 0, null, 0, 0)
        }
        assertTrue(error.message, error.message!!.none { it.isDigit() })
        assertThrows(IllegalArgumentException::class.java) {
            ProtocolPacker.packPhoneFix(-2356141, 18_000_001, 0, null, 0, 0)
        }
        assertThrows(IllegalArgumentException::class.java) {
            ProtocolPacker.packPhoneFix(-2356141, -4665588, -1, null, 0, 0)
        }
    }

    private companion object {
        const val ROUTE_ID = 1
        const val DEST_NAME = "Aeroporto de Congonhas"

        /** LODs that the packer.py `synthetic_corridor` produces. */
        const val FIXTURE_LOD_COUNT = 4
    }
}
