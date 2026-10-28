package dev.igor.motonav.proto

import java.io.ByteArrayOutputStream
import java.io.DataOutputStream

/**
 * Binary packer for the phone -> watch protocol (docs/05-PROTOCOL.md).
 *
 * Mirror of tools/packer.py, which generates the fixtures this is unit-tested
 * against. Integers are big-endian; there is no compression.
 */
object ProtocolPacker {

    /** Wraps a block payload chunk in the 8-byte header of 05 §Framing. */
    fun frame(msgType: Int, routeId: Int, seq: Int, total: Int, payload: ByteArray): ByteArray {
        require(payload.size <= 0xFFFF) { "payload longer than uint16: ${payload.size}" }
        require(total in 1..Protocol.MAX_CHUNKS) { "invalid total: $total" }
        require(seq in 0 until total) { "invalid seq/total: $seq/$total" }

        val out = ByteArrayOutputStream(Protocol.HEADER_SIZE + payload.size)
        DataOutputStream(out).apply {
            writeByte(Protocol.VERSION)
            writeByte(msgType)
            writeShort(routeId)
            writeByte(seq)
            writeByte(total)
            writeShort(payload.size)
            write(payload)
        }
        return out.toByteArray()
    }

    /**
     * Splits a block payload into framed chunks of at most [chunkSize] bytes.
     * The watch concatenates every chunk before parsing, so records may straddle
     * a chunk boundary.
     */
    fun chunk(
        msgType: Int,
        routeId: Int,
        payload: ByteArray,
        chunkSize: Int = Protocol.CHUNK_SIZE,
    ): List<ByteArray> {
        val body = chunkSize - Protocol.HEADER_SIZE
        val total = if (payload.isEmpty()) 1 else (payload.size + body - 1) / body
        require(total <= Protocol.MAX_CHUNKS) {
            "block needs $total chunks, protocol allows ${Protocol.MAX_CHUNKS}"
        }
        return (0 until total).map { seq ->
            val from = seq * body
            val to = minOf(from + body, payload.size)
            frame(msgType, routeId, seq, total, payload.copyOfRange(from, to))
        }
    }

    fun packRouteMeta(route: PackableRoute): ByteArray {
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            writeInt(route.lat0)
            writeInt(route.lon0)
            writeInt(route.distanceM)
            writeInt(route.durationS)
            write(packString(route.destName, Protocol.MAX_DEST_NAME_BYTES))
            writeShort(route.points.size)
            writeByte(route.turns.size)
            writeByte(route.corridorLodCount)
            writeByte(route.flags)
        }
        return out.toByteArray()
    }

    fun packRoutePoly(route: PackableRoute): ByteArray =
        encodePoints(route.points, route.lat0, route.lon0)

    fun packTurns(route: PackableRoute): ByteArray {
        val out = ByteArrayOutputStream()
        val data = DataOutputStream(out)
        route.turns.forEach { turn ->
            data.writeShort(turn.pointIdx)
            data.writeByte(turn.type)
            if (Protocol.hasExitNum(turn.type)) {
                data.writeByte(turn.exitNum)
            }
            data.write(packString(turn.streetName, Protocol.MAX_STREET_NAME_BYTES))
        }
        return out.toByteArray()
    }

    /** Delta-encodes coordinates as described in 05 §ROUTE_POLY. */
    fun encodePoints(points: List<PointE5>, lat0: Int, lon0: Int): ByteArray {
        val out = ByteArrayOutputStream(points.size * 4)
        val data = DataOutputStream(out)
        var prevLat = lat0
        var prevLon = lon0
        points.forEachIndexed { i, point ->
            val dLat = point.lat - prevLat
            val dLon = point.lon - prevLon
            when {
                i == 0 -> {
                    data.writeInt(dLat)
                    data.writeInt(dLon)
                }

                dLat in -32767..32767 && dLon in -32767..32767 -> {
                    data.writeShort(dLat)
                    data.writeShort(dLon)
                }

                else -> {
                    data.writeShort(Protocol.DELTA_ESCAPE)
                    data.writeShort(Protocol.DELTA_ESCAPE)
                    data.writeInt(dLat)
                    data.writeInt(dLon)
                }
            }
            prevLat = point.lat
            prevLon = point.lon
        }
        return out.toByteArray()
    }

    /** uint8 length prefix + UTF-8 bytes, cut on a codepoint boundary. */
    fun packString(text: String, maxBytes: Int): ByteArray {
        val raw = truncateUtf8(text, maxBytes)
        return ByteArray(1 + raw.size).also {
            it[0] = raw.size.toByte()
            raw.copyInto(it, 1)
        }
    }

    /**
     * Encodes to UTF-8 and cuts at [maxBytes] without splitting a character
     * (docs/08-CODEX-GUIDE.md §Pitfalls 6 — pt-BR street names carry accents).
     */
    fun truncateUtf8(text: String, maxBytes: Int): ByteArray {
        val raw = text.toByteArray(Charsets.UTF_8)
        if (raw.size <= maxBytes) {
            return raw
        }
        var cut = maxBytes
        while (cut > 0 && (raw[cut].toInt() and 0xC0) == 0x80) {
            cut--
        }
        return raw.copyOfRange(0, cut)
    }

    /**
     * Cuts a way into pieces of at most [Protocol.MAX_WAY_POINTS] points.
     *
     * Consecutive pieces **share** the vertex where they were cut: without it
     * the segment between them would not exist and the street would show a gap.
     */
    fun splitWay(points: List<PointE5>): List<List<PointE5>> {
        if (points.size <= Protocol.MAX_WAY_POINTS) {
            return listOf(points)
        }
        val pieces = mutableListOf<List<PointE5>>()
        var start = 0
        while (start < points.size - 1) {
            val end = minOf(start + Protocol.MAX_WAY_POINTS, points.size)
            pieces += points.subList(start, end)
            start = end - 1
        }
        return pieces
    }

    /**
     * CORRIDOR (0x04) payload for one LOD (05 §CORRIDOR).
     *
     * `lod uint8`, then `pointCount uint8` + delta-encoded points per way. Every
     * way restarts its delta chain at (lat0, lon0): the first point costs 8 bytes
     * instead of 4, and in exchange a corrupt way cannot drag the following ones
     * out of place — which matters because these arrive over BLE.
     */
    fun packCorridor(lod: Int, ways: List<List<PointE5>>, lat0: Int, lon0: Int): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(lod and 0xFF)
        for (way in ways) {
            for (piece in splitWay(way)) {
                if (piece.size < 2) {
                    continue
                }
                out.write(piece.size and 0xFF)
                out.write(encodePoints(piece, lat0, lon0))
            }
        }
        return out.toByteArray()
    }

    /**
     * Blocks in send order (ADR-3: META -> POLY -> TURNS -> CORRIDOR).
     *
     * The corridor goes last on purpose: it is the only optional block, and the
     * route has to be usable before the scenery arrives.
     */
    fun buildRouteBlocks(
        route: PackableRoute,
        chunkSize: Int = Protocol.CHUNK_SIZE,
        corridor: PackableCorridor? = null,
    ): List<Block> {
        // META announces how many LODs will come; it is the answer key the watch uses
        // to know whether there is still corridor arriving.
        val announced =
            if (corridor == null) route else route.copy(corridorLodCount = corridor.nonEmptyLods().size)

        val blocks = mutableListOf(
            Block(
                Protocol.MSG_ROUTE_META,
                chunk(Protocol.MSG_ROUTE_META, announced.routeId, packRouteMeta(announced), chunkSize),
            ),
            Block(
                Protocol.MSG_ROUTE_POLY,
                chunk(Protocol.MSG_ROUTE_POLY, route.routeId, packRoutePoly(route), chunkSize),
            ),
            Block(Protocol.MSG_TURNS, chunk(Protocol.MSG_TURNS, route.routeId, packTurns(route), chunkSize)),
        )
        if (corridor != null) {
            blocks += buildCorridorBlocks(route, corridor, chunkSize)
        }
        return blocks
    }

    /**
     * Only the CORRIDOR blocks, one per non-empty LOD.
     *
     * Separate from [buildRouteBlocks] because the corridor now travels **after**
     * the route, in its own transfer: Overpass is a free public service
     * and failed in five of six attempts in the street tests, and nobody
     * should be left without a map waiting for scenery.
     */
    fun buildCorridorBlocks(
        route: PackableRoute,
        corridor: PackableCorridor,
        chunkSize: Int = Protocol.CHUNK_SIZE,
    ): List<Block> = corridor.nonEmptyLods().map { lod ->
        val payload = packCorridor(lod, corridor.ways[lod], route.lat0, route.lon0)
        Block(Protocol.MSG_CORRIDOR, chunk(Protocol.MSG_CORRIDOR, route.routeId, payload, chunkSize))
    }

    /**
     * RADARS (05 §RADARS): `count uint16` + count x (`distAlong uint32`, `dLat int32`,
     * `dLon int32`, `limit uint8`, `flags uint8`), in `distAlong` order. Whoever trims to the
     * cap is whoever builds the list ([dev.igor.motonav.corridor.RadarFilter]); here it is an error.
     */
    fun packRadars(radars: List<WireRadar>): ByteArray {
        require(radars.size <= Protocol.MAX_RADARS) {
            "${radars.size} radars; the protocol carries at most ${Protocol.MAX_RADARS}"
        }
        val out = ByteArrayOutputStream(2 + Protocol.RADAR_RECORD_BYTES * radars.size)
        DataOutputStream(out).apply {
            writeShort(radars.size)
            var last = 0L
            for (radar in radars) {
                require(radar.distAlongM in last..0xFFFFFFFFL) { "radar out of order or outside uint32: $radar" }
                require(radar.limitKmh in 0..0xFF && radar.flags in 0..0xFF) { "radar $radar does not fit the format" }
                writeInt(radar.distAlongM.toInt())
                writeInt(radar.dLat)
                writeInt(radar.dLon)
                writeByte(radar.limitKmh)
                writeByte(radar.flags)
                last = radar.distAlongM
            }
        }
        return out.toByteArray()
    }

    /** RADARS belongs to the route: its `routeId`, one chunk. */
    fun buildRadarsBlock(routeId: Int, radars: List<WireRadar>): Block =
        Block(Protocol.MSG_RADARS, chunk(Protocol.MSG_RADARS, routeId, packRadars(radars)))

    /**
     * CONFIG (05 §CONFIG): `count uint8` + count x (`key uint8`, `value uint16`),
     * in key id order. An empty list is the "back to default" message.
     */
    fun packConfig(entries: List<Pair<Int, Int>>): ByteArray {
        require(entries.size <= 0xFF) { "too many config entries: ${entries.size}" }
        val out = ByteArrayOutputStream(1 + 3 * entries.size)
        DataOutputStream(out).apply {
            writeByte(entries.size)
            for ((key, value) in entries.sortedBy { it.first }) {
                require(key in 0..0xFF && value in 0..0xFFFF) { "config $key=$value does not fit the wire format" }
                writeByte(key)
                writeShort(value)
            }
        }
        return out.toByteArray()
    }

    /** CONFIG belongs to no route: `routeId` 0, one chunk. */
    fun buildConfigBlock(entries: List<Pair<Int, Int>>): Block =
        Block(Protocol.MSG_CONFIG, chunk(Protocol.MSG_CONFIG, 0, packConfig(entries)))

    /**
     * FAVORITES (05 §FAVORITES): `count uint8` + per item `favId uint8`, lat and lon
     * int32 (1e-5 degree), len-prefixed UTF-8 name (<= 20 B) and `icon uint8`. RECENTS uses the
     * same format, with `max` 5.
     */
    fun packFavorites(items: List<WireFavorite>, max: Int = Protocol.MAX_FAVORITES): ByteArray {
        require(items.size <= max) {
            "${items.size} items; the protocol carries at most $max"
        }
        require(items.map { it.favId }.toSet().size == items.size) { "favId repeated" }
        val out = ByteArrayOutputStream()
        DataOutputStream(out).apply {
            writeByte(items.size)
            for (item in items) {
                require(item.favId in 0..0xFF && item.icon in 0..0xFF) { "favorite $item does not fit the format" }
                writeByte(item.favId)
                writeInt(item.latE5)
                writeInt(item.lonE5)
                write(packString(item.name, Protocol.MAX_FAVORITE_NAME_BYTES))
                writeByte(item.icon)
            }
        }
        return out.toByteArray()
    }

    /** FAVORITES belongs to no route: `routeId` 0, one chunk. */
    fun buildFavoritesBlock(items: List<WireFavorite>): Block =
        Block(Protocol.MSG_FAVORITES, chunk(Protocol.MSG_FAVORITES, 0, packFavorites(items)))

    /** RECENTS (05 §RECENTS, C16.5): the FAVORITES format, up to 5 items, `routeId` 0, one chunk. */
    fun buildRecentsBlock(items: List<WireFavorite>): Block =
        Block(Protocol.MSG_RECENTS, chunk(Protocol.MSG_RECENTS, 0, packFavorites(items, Protocol.MAX_RECENTS)))

    /**
     * ROUTE_UPDATE (05 §ROUTE_UPDATE): `durationS uint32`, what the provider says
     * the whole route takes now. Zero is not a duration, and the watch reads the field
     * signed: outside 1..Int.MAX_VALUE it does not fit.
     */
    fun packRouteUpdate(durationS: Int): ByteArray {
        require(durationS > 0) { "durationS $durationS does not fit the format" }
        val out = ByteArrayOutputStream(4)
        DataOutputStream(out).writeInt(durationS)
        return out.toByteArray()
    }

    /** The `routeId` is that of the route the duration is about; one chunk. */
    fun buildRouteUpdateBlock(routeId: Int, durationS: Int): Block =
        Block(Protocol.MSG_ROUTE_UPDATE, chunk(Protocol.MSG_ROUTE_UPDATE, routeId, packRouteUpdate(durationS)))

    /**
     * PHONE_FIX (05 §PHONE_FIX): lat, lon `int32` (1e-5 degree), speed `uint16`
     * in dm/s, heading `uint16` in degrees (≥ 360 = unknown), accuracy `uint16` in
     * meters and age `uint16` in ms. 16 bytes, mirror of `pack_phone_fix`.
     *
     * Speed, accuracy and age **saturate** at 0xFFFF instead of failing: a fix
     * from a minute ago is still a fix, and the watch reads the saturated age as
     * "old". [headingDeg] `null`, or outside 0..359, goes as unknown.
     *
     * The error messages do not carry the coordinate: whoever catches them may write them
     * to `motonav.log`, and the phone's position does not go there (08 §Conventions).
     */
    fun packPhoneFix(
        latE5: Int,
        lonE5: Int,
        speedDms: Int,
        headingDeg: Int?,
        accuracyM: Int,
        ageMs: Int,
    ): ByteArray {
        require(
            latE5 in -Protocol.MAX_LAT_E5..Protocol.MAX_LAT_E5 && lonE5 in -Protocol.MAX_LON_E5..Protocol.MAX_LON_E5,
        ) { "the fix coordinate is not a place" }
        require(speedDms >= 0 && accuracyM >= 0 && ageMs >= 0) { "speed, accuracy and age are not negative" }
        val out = ByteArrayOutputStream(PHONE_FIX_SIZE)
        DataOutputStream(out).apply {
            writeInt(latE5)
            writeInt(lonE5)
            writeShort(minOf(speedDms, 0xFFFF))
            writeShort(headingDeg?.takeIf { it in 0..359 } ?: Protocol.HEADING_UNKNOWN)
            writeShort(minOf(accuracyM, 0xFFFF))
            writeShort(minOf(ageMs, 0xFFFF))
        }
        return out.toByteArray()
    }

    /** PHONE_FIX belongs to no route: `routeId` 0, one chunk. */
    fun buildPhoneFixBlock(
        latE5: Int,
        lonE5: Int,
        speedDms: Int,
        headingDeg: Int?,
        accuracyM: Int,
        ageMs: Int,
    ): Block = Block(
        Protocol.MSG_PHONE_FIX,
        chunk(Protocol.MSG_PHONE_FIX, 0, packPhoneFix(latE5, lonE5, speedDms, headingDeg, accuracyM, ageMs)),
    )

    /** PHONE_FIX payload: two `int32` and four `uint16`. */
    const val PHONE_FIX_SIZE = 16

    data class Block(val msgType: Int, val chunks: List<ByteArray>)
}
