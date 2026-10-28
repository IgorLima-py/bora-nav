package dev.igor.motonav.proto

/**
 * Constants of the phone <-> watch protocol (docs/05-PROTOCOL.md).
 *
 * Any change here must be mirrored in tools/packer.py (source of truth for the
 * test vectors) and in watch/source/comm/MessageAssembler.mc.
 */
object Protocol {

    /** 2 since C16.5: maneuver types 14..30 and the exitNum of 21..28 (05 §TURNS). */
    const val VERSION = 2

    // Phone -> watch
    const val MSG_ROUTE_META = 0x01
    const val MSG_ROUTE_POLY = 0x02
    const val MSG_TURNS = 0x03
    const val MSG_CORRIDOR = 0x04
    const val MSG_FAVORITES = 0x05
    const val MSG_ROUTE_UPDATE = 0x06
    const val MSG_CANCEL_NAV = 0x07

    /**
     * The route's speed cameras (05 §RADARS, C16.6): per route, one chunk, after the corridor.
     * Up to [MAX_RADARS] records of [RADAR_RECORD_BYTES], in `distAlong` order.
     */
    const val MSG_RADARS = 0x08
    const val MAX_RADARS = 200
    const val RADAR_RECORD_BYTES = 14

    /** `flags` bit0: the camera's direction is known and matches the route. */
    const val RADAR_FLAG_DIRECTION = 0x01

    /**
     * Wireless fine tuning (05 §CONFIG, C5): `routeId` 0, outside the route
     * check. Keys in [ConfigKey]; the watch is what checks the ranges.
     */
    const val MSG_CONFIG = 0x09

    /**
     * The phone's GPS position, sent while the watch asks for it (05 §PHONE_FIX,
     * C13b): `routeId` 0, one chunk, **no ACK**.
     */
    const val MSG_PHONE_FIX = 0x0A

    /**
     * The latest destinations (05 §RECENTS, C16.5): the same format as FAVORITES, at most
     * [MAX_RECENTS], `routeId` 0. The watch's home screen lists them under "Recentes".
     */
    const val MSG_RECENTS = 0x0B

    // Watch -> phone
    const val MSG_ACK = 0x81
    const val MSG_REROUTE_REQ = 0x82
    const val MSG_NAV_START_REQ = 0x83
    const val MSG_NAV_ENDED = 0x84

    /** The reasons for NAV_ENDED, the payload byte (05 §Message types). */
    const val NAV_ENDED_ARRIVED = 0
    const val NAV_ENDED_CANCELLED = 1
    const val NAV_ENDED_ERROR = 2

    /**
     * Watch log, UTF-8 text (05 §Diagnostic messages). Only for the debug
     * phase: the watch has no logcat, and without this the only way to read what
     * it saw is for Igor to type the screen by hand.
     */
    const val MSG_LOG = 0x85

    /** The watch asks for (1) or dismisses (0) the phone's GPS (05 §FIX_REQ, C13b). */
    const val MSG_FIX_REQ = 0x86

    /** `heading` of someone with no bearing: any value ≥ 360 (05 §REROUTE_REQ, §PHONE_FIX). */
    const val HEADING_UNKNOWN = 0xFFFF

    /** Outside this it is not a place (1e-5 degree): ±90° and ±180°. */
    const val MAX_LAT_E5 = 9_000_000
    const val MAX_LON_E5 = 18_000_000

    const val HEADER_SIZE = 8

    /** Whole framed message handed to sendMessage, header included. Recalibrated in F1. */
    const val CHUNK_SIZE = 4096
    const val MAX_CHUNK_PAYLOAD = CHUNK_SIZE - HEADER_SIZE
    const val MAX_CHUNKS = 255

    /** Marks a delta that does not fit in an int16 (05 §ROUTE_POLY). */
    const val DELTA_ESCAPE = 0x7FFF

    // Caps that protect the watch (03 §Memory budget).
    const val MAX_POLY_POINTS = 4000
    const val MAX_DEST_NAME_BYTES = 40
    const val MAX_STREET_NAME_BYTES = 28

    // FAVORITES (0x05), mirroring tools/packer.py (05 §FAVORITES).
    const val MAX_FAVORITES = 6
    const val MAX_FAVORITE_NAME_BYTES = 20

    // RECENTS (0x0B) and NAV_START_REQ's `kind`, mirroring tools/packer.py (05 §RECENTS).
    const val MAX_RECENTS = 5
    const val NAV_START_KIND_FAVORITE = 0
    const val NAV_START_KIND_RECENT = 1

    // CORRIDOR (0x04), mirroring tools/packer.py.
    /** Levels of detail, coarsest first (05 §CORRIDOR, 04 §3.3). */
    const val LOD_EXPRESS = 0
    const val LOD_ARTERIAL = 1
    const val LOD_COLLECTOR = 2
    const val LOD_LOCAL = 3
    const val CORRIDOR_LOD_COUNT = 4

    /** `pointCount` is a uint8, so longer ways are cut into pieces. */
    const val MAX_WAY_POINTS = 255

    /**
     * Hard caps of the corridor (`04 §3.5`).
     *
     * **Recalibrated on 2026-08-01, and this time against the screen.** The 1,200
     * segments were chosen on 2026-07-31 against the BLE throughput, and the log of
     * four shares in a row shows the price: `teto do corredor: LOD 3
     * (439 ways) descartado`, **every time**. LOD 3 is `residential`/`unclassified`
     * — the neighborhood street grid. Igor got only avenues, and that is exactly
     * what he reported: *"only some streets show up, not all of them"*.
     *
     * The reasoning error was to confuse two budgets. The **whole** corridor
     * is what crosses BLE and takes memory; what the watch **draws per
     * frame** is only what fits in a ~380 m radius at 1.2 m/px, that is, a fraction
     * of it. Sizing the whole corridor by the frame's cost is sizing the
     * library by the size of the desk.
     *
     * What protects the frame now is the `MapRenderer`'s adaptive leash, which
     * measures the real watch. These numbers protect the **air and the memory**:
     * ~2,600 segments ≈ 20 KB ≈ 45 s of BLE in the background, with the route already on
     * screen, and ~140 KB of the 768 KB that the `venu445mm` gives a watch app.
     */
    const val MAX_CORRIDOR_SEGMENTS = 2600
    const val MAX_CORRIDOR_BYTES = 32 * 1024

    // Turn types (05 §TURNS).
    const val TURN_DEPART = 0
    const val TURN_STRAIGHT = 1
    const val TURN_SLIGHT_RIGHT = 2
    const val TURN_RIGHT = 3
    const val TURN_SHARP_RIGHT = 4
    const val TURN_UTURN = 5
    const val TURN_SHARP_LEFT = 6
    const val TURN_LEFT = 7
    const val TURN_SLIGHT_LEFT = 8
    const val TURN_ROUNDABOUT = 9
    const val TURN_HIGHWAY_ENTER = 10
    const val TURN_HIGHWAY_EXIT = 11
    const val TURN_ARRIVE = 12
    const val TURN_NEW_NAME = 13
    // C16.5: the Google Navigation SDK icon set (tools/glifos.py) draws these separately.
    const val TURN_FORK_LEFT = 14
    const val TURN_FORK_RIGHT = 15
    const val TURN_MERGE = 16
    const val TURN_MERGE_LEFT = 17
    const val TURN_MERGE_RIGHT = 18
    const val TURN_ARRIVE_LEFT = 19
    const val TURN_ARRIVE_RIGHT = 20
    /** Roundabout with the exit at the angle: clockwise-closed (21), counterclockwise, up to the U-turn (28). */
    const val TURN_ROUNDABOUT_SHARP_RIGHT = 21
    const val TURN_ROUNDABOUT_UTURN = 28
    const val TURN_HIGHWAY_ENTER_LEFT = 29
    const val TURN_HIGHWAY_EXIT_LEFT = 30

    /**
     * Upper edge of each 45° band of Mapbox's `degrees` (counterclockwise arc on the ring,
     * 180 = straight ahead), centered on 45, 90 … 315; after the last one is the U-turn. Mirrors
     * `packer.ROUNDABOUT_DEGREE_EDGES`.
     */
    val ROUNDABOUT_DEGREE_EDGES = doubleArrayOf(67.5, 112.5, 157.5, 202.5, 247.5, 292.5, 337.5)

    /** A roundabout carries `exitNum` (05 §TURNS): the 9, and 21..28 since version 2. */
    fun hasExitNum(type: Int): Boolean =
        type == TURN_ROUNDABOUT || type in TURN_ROUNDABOUT_SHARP_RIGHT..TURN_ROUNDABOUT_UTURN

    fun roundaboutByDegrees(degrees: Double): Int {
        ROUNDABOUT_DEGREE_EDGES.forEachIndexed { k, edge ->
            if (degrees < edge) {
                return TURN_ROUNDABOUT_SHARP_RIGHT + k
            }
        }
        return TURN_ROUNDABOUT_UTURN
    }
}

/** A coordinate in protocol units: degrees x 1e5 (~1.1 m). */
data class PointE5(val lat: Int, val lon: Int)

/**
 * One item of FAVORITES (0x05): what the watch lists. `favId` is the phone's
 * stable id, returned in NAV_START_REQ; `icon` is opaque to the watch in v1.
 */
data class WireFavorite(
    val favId: Int,
    val latE5: Int,
    val lonE5: Int,
    val name: String,
    val icon: Int,
)

/**
 * A RADARS record (0x08): meters along the sent POLY, the position as an
 * e5 delta from the META's lat0/lon0, the limit in km/h (0 = unknown) and the flags.
 */
data class WireRadar(
    val distAlongM: Long,
    val dLat: Int,
    val dLon: Int,
    val limitKmh: Int,
    val flags: Int,
)

data class Turn(
    val pointIdx: Int,
    val type: Int,
    val streetName: String,
    val exitNum: Int = 0,
)

/**
 * The surrounding streets, grouped by level of detail (04 §3).
 *
 * `ways[lod]` holds the ways of that LOD, each a polyline in protocol units.
 * Mirror of `Corridor` in `tools/packer.py`.
 */
data class PackableCorridor(
    val ways: List<List<List<PointE5>>> = List(Protocol.CORRIDOR_LOD_COUNT) { emptyList() },
) {
    fun segmentCount(): Int = ways.sumOf { lod -> lod.sumOf { maxOf(it.size - 1, 0) } }

    fun nonEmptyLods(): List<Int> = ways.indices.filter { ways[it].isNotEmpty() }

    /**
     * Safety net: drops whole LODs until the corridor fits.
     *
     * **It is no longer the normal path.** What decides what stays is
     * `CorridorBuilder.fitToCaps`, which cuts the ways **farthest from the route** and
     * so preserves the local mesh around the track — the one that is useful
     * for navigating. Dropping the whole local LOD, as this function does, is
     * exactly the behavior that wiped out Igor's neighborhood streets in
     * four shares in a row.
     *
     * It stays because a cap must hold even if the previous stage miscounts:
     * what reaches the watch can never exceed what it can take.
     */
    fun capped(lat0: Int, lon0: Int): Pair<PackableCorridor, List<String>> {
        var current = this
        val dropped = mutableListOf<String>()
        for (lod in listOf(Protocol.LOD_LOCAL, Protocol.LOD_COLLECTOR)) {
            if (current.segmentCount() <= Protocol.MAX_CORRIDOR_SEGMENTS &&
                current.packedSize(lat0, lon0) <= Protocol.MAX_CORRIDOR_BYTES
            ) {
                break
            }
            if (current.ways[lod].isNotEmpty()) {
                dropped += "LOD $lod (${current.ways[lod].size} ways)"
                current = current.copy(
                    ways = current.ways.mapIndexed { i, w -> if (i == lod) emptyList() else w },
                )
            }
        }
        return current to dropped
    }

    private fun packedSize(lat0: Int, lon0: Int): Int =
        nonEmptyLods().sumOf { ProtocolPacker.packCorridor(it, ways[it], lat0, lon0).size }
}

/** A route ready to be packed. Coordinates already quantized to 1e-5 degrees. */
data class PackableRoute(
    val routeId: Int,
    val points: List<PointE5>,
    val turns: List<Turn>,
    val distanceM: Int,
    val durationS: Int,
    val destName: String,
    val corridorLodCount: Int = 0,
    val flags: Int = 0,
) {
    val lat0: Int get() = points.first().lat
    val lon0: Int get() = points.first().lon
}
