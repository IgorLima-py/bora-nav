package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.WireRadar
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * **Of the OSM speed cameras around the route, the ones the route passes over** (C16.6, `05 §RADARS`).
 *
 * Four rules, in this order:
 *
 * 1. **Near the track**: within [NEAR_M] of the POLY sent. The query polygon is deliberately wide
 *    ([CorridorBuilder.bufferPolygon]) and brings in the surrounding city.
 * 2. **On the route's street**: if the camera's node is on a way, the way most aligned with the track must
 *    follow its heading within 60°. More than that is the crossing street, and the camera belongs to it.
 * 3. **In the route's direction**: `direction=forward|backward` on the node, relative to the way's drawing (the
 *    convention for OSM way nodes), or the way's one-way (`oneway`). Opposite direction is dropped;
 *    same direction gets the [Protocol.RADAR_FLAG_DIRECTION] flag. With none of that, the camera stays, without
 *    the flag, and the watch warns in both directions. **`direction` in degrees or in compass points
 *    is not read**: the tag's OSM wiki page says it is where the camera points, which is the
 *    opposite of the traffic it measures when it looks head-on, and not every mapper follows that.
 *    Reading it wrong would drop a real camera; warning too much costs a vibration.
 * 4. **One per place**: two nodes less than [DEDUP_M] apart along the route are the same camera mapped
 *    twice; the one with a limit stays.
 *
 * Before rule 4, the official pardal cameras that OSM lacks come in ([judgePardal], C16.7b).
 *
 * The limit comes from the node's `maxspeed`, or the way it is on; anything that is not a number in km/h
 * becomes 0, "unknown". The list comes out in `distAlong` order and cut at [Protocol.MAX_RADARS].
 *
 * `distAlong` is the projection onto the nearest POLY segment, in the same plane as `Projection.mc`
 * ([LocalPlane]), which is what the watch's matching measures. A route that passes through the
 * same street twice gets the camera at the pass nearest the node.
 */
object RadarFilter {

    /**
     * Maximum distance from the camera to the track, from the `06-APIS-DATA.md` §Radares pipeline; not
     * measured. On the real route (`RadarFilterTest`, 2026-10-23) the farthest camera that stayed was at
     * 28.2 m, so the margin decided no camera there.
     */
    const val NEAR_M = 60.0

    /** Two cameras less than this apart along the route are one. From the same `06` pipeline, not measured. */
    const val DEDUP_M = 50L

    /** cos 60°: the way's heading and the track's agree within 60°. */
    private const val ALIGNED_COS = 0.5

    /** A camera that stayed, before the cut and the wire, with the distance to the track for the test. */
    data class Kept(val radar: WireRadar, val offsetM: Double, val osmId: Long = 0, val direction: String? = null)

    /**
     * **Why a polygon camera stayed or left** (C16.7): this is what separates, in the coverage, the camera
     * missing from OSM from the one the filter removed. In rule order; [CAP] is the wire cut.
     */
    enum class Reason(val label: String) {
        KEPT("on route"),
        FAR("far"),
        CROSS_STREET("cross street"),
        WRONG_WAY("wrong way"),
        DUPLICATE("duplicate"),
        CAP("cap"),
        /** A pardal camera that OSM already has within [SAME_PLACE_M]: OSM's verdict applies (C16.7b). */
        IN_OSM("in OSM"),
    }

    /** Where the camera came from: OSM via Overpass, or pardal ([PardalSource]). */
    enum class Source { OSM, PARDAL }

    /**
     * A pardal camera stays within this distance of the track, half of [NEAR_M]: it does not bring the way, so
     * rule 2 (the crossing street) does not apply, and the parallel street is left out by distance. The 19
     * that got in on the 20 routes of C16.7 were within 25 m.
     */
    const val PARDAL_NEAR_M = 30.0

    /** An OSM node within this distance of the pardal camera is the same camera: the coverage tolerance from C16.7. */
    const val SAME_PLACE_M = 30.0

    /**
     * The verdict on a polygon camera. [distAlongM] and [bearingDeg] (the route's heading at the point, 0 =
     * north, clockwise) come from the nearest segment, also for the ones that left; [radar] only
     * exists on those that passed rule 3.
     */
    data class Verdict(
        val camera: OsmCamera,
        val reason: Reason,
        val offsetM: Double,
        val distAlongM: Long,
        val bearingDeg: Int,
        val radar: WireRadar? = null,
        val source: Source = Source.OSM,
    )

    fun filter(route: PackableRoute, osm: OsmRadars): List<WireRadar> = keep(route, osm).map { it.radar }

    fun keep(route: PackableRoute, osm: OsmRadars): List<Kept> = judge(route, osm)
        .filter { it.reason == Reason.KEPT }
        .map { Kept(it.radar!!, it.offsetM, it.camera.id, it.camera.direction) }

    /** One verdict per polygon camera; the ones that stay ([Reason.KEPT]) in `distAlong` order. */
    fun judge(route: PackableRoute, osm: OsmRadars, pardal: List<PardalCamera> = emptyList()): List<Verdict> {
        if (route.points.size < 2) {
            return emptyList()
        }
        val plane = LocalPlane(route.lat0, route.lon0)
        val xs = DoubleArray(route.points.size) { plane.x(route.points[it]) }
        val ys = DoubleArray(route.points.size) { plane.y(route.points[it]) }
        val along = DoubleArray(xs.size)
        for (i in 1 until xs.size) {
            along[i] = along[i - 1] + LocalPlane.distance(xs[i - 1], ys[i - 1], xs[i], ys[i])
        }
        val waysOf = HashMap<Long, MutableList<OsmCameraWay>>()
        for (way in osm.ways) {
            for (node in way.nodes) {
                waysOf.getOrPut(node) { mutableListOf() }.add(way)
            }
        }

        val dropped = mutableListOf<Verdict>()
        val found = mutableListOf<Verdict>()
        for (camera in osm.cameras) {
            val px = plane.x(camera.point)
            val py = plane.y(camera.point)
            val near = nearestSegment(xs, ys, px, py)
            val sx = xs[near.index + 1] - xs[near.index]
            val sy = ys[near.index + 1] - ys[near.index]
            val segment = hypot(sx, sy)
            val dist = (along[near.index] + near.t * segment).roundToLong()
            val bearing = ((Math.toDegrees(atan2(sx, sy)) + 360.0) % 360.0).roundToInt() % 360
            fun verdict(reason: Reason, radar: WireRadar? = null) =
                Verdict(camera, reason, near.offsetM, dist, bearing, radar)
            if (near.offsetM > NEAR_M) {
                dropped.add(verdict(Reason.FAR))
                continue
            }

            // The camera's way most aligned with the track, and the cosine between the two.
            var bestWay: OsmCameraWay? = null
            var bestCos = 0.0
            for (way in waysOf[camera.id].orEmpty()) {
                val cos = cosAt(way, camera.id, plane, sx, sy, segment) ?: continue
                if (bestWay == null || abs(cos) > abs(bestCos)) {
                    bestWay = way
                    bestCos = cos
                }
            }
            if (bestWay != null && abs(bestCos) < ALIGNED_COS) {
                dropped.add(verdict(Reason.CROSS_STREET))
                continue
            }
            var flags = 0
            if (bestWay != null) {
                val routeAlongWay = bestCos > 0
                val enforcedAlongWay = when (camera.direction?.trim()?.lowercase()) {
                    "forward" -> true
                    "backward" -> false
                    else -> when (bestWay.oneway?.trim()?.lowercase()) {
                        "yes", "true", "1" -> true
                        "-1", "reverse" -> false
                        else -> null
                    }
                }
                if (enforcedAlongWay != null) {
                    if (enforcedAlongWay != routeAlongWay) {
                        dropped.add(verdict(Reason.WRONG_WAY))
                        continue
                    }
                    flags = Protocol.RADAR_FLAG_DIRECTION
                }
            }
            val limit = kmh(camera.maxspeed) ?: kmh(bestWay?.maxspeed) ?: 0
            found.add(
                verdict(
                    Reason.KEPT,
                    WireRadar(
                        distAlongM = dist,
                        dLat = camera.point.lat - route.lat0,
                        dLon = camera.point.lon - route.lon0,
                        limitKmh = limit,
                        flags = flags,
                    ),
                ),
            )
        }

        judgePardal(route, plane, xs, ys, along, osm.cameras, pardal, found, dropped)

        found.sortBy { it.distAlongM }
        val unique = mutableListOf<Verdict>()
        for (kept in found) {
            val last = unique.lastOrNull()
            if (last != null && kept.distAlongM - last.distAlongM < DEDUP_M) {
                if (last.radar!!.limitKmh == 0 && kept.radar!!.limitKmh > 0) {
                    unique[unique.size - 1] = kept
                    dropped.add(last.copy(reason = Reason.DUPLICATE))
                } else {
                    dropped.add(kept.copy(reason = Reason.DUPLICATE))
                }
                continue
            }
            unique.add(kept)
        }
        val cut = unique.drop(Protocol.MAX_RADARS).map { it.copy(reason = Reason.CAP) }
        return unique.take(Protocol.MAX_RADARS) + cut + dropped
    }

    /**
     * **Pardal, after OSM** (C16.7b): a camera comes in within [PARDAL_NEAR_M] of the track, with no OSM node
     * within [SAME_PLACE_M] and in the route's direction (within 90°, the rule from pardal's README). The ones that stay
     * go through the same duplicate check and the same cap. The file is all of Brazil: whatever lies farther
     * than [NEAR_M] from the route gets no verdict.
     */
    private fun judgePardal(
        route: PackableRoute,
        plane: LocalPlane,
        xs: DoubleArray,
        ys: DoubleArray,
        along: DoubleArray,
        cameras: List<OsmCamera>,
        pardal: List<PardalCamera>,
        found: MutableList<Verdict>,
        dropped: MutableList<Verdict>,
    ) {
        if (pardal.isEmpty()) {
            return
        }
        val minX = xs.min() - NEAR_M
        val maxX = xs.max() + NEAR_M
        val minY = ys.min() - NEAR_M
        val maxY = ys.max() + NEAR_M
        val osmX = DoubleArray(cameras.size) { plane.x(cameras[it].point) }
        val osmY = DoubleArray(cameras.size) { plane.y(cameras[it].point) }
        for (camera in pardal) {
            val px = plane.x(camera.point)
            val py = plane.y(camera.point)
            if (px < minX || px > maxX || py < minY || py > maxY) {
                continue
            }
            val near = nearestSegment(xs, ys, px, py)
            if (near.offsetM > NEAR_M) {
                continue
            }
            val sx = xs[near.index + 1] - xs[near.index]
            val sy = ys[near.index + 1] - ys[near.index]
            val dist = (along[near.index] + near.t * hypot(sx, sy)).roundToLong()
            val bearing = ((Math.toDegrees(atan2(sx, sy)) + 360.0) % 360.0).roundToInt() % 360
            val asCamera = OsmCamera(
                id = pardalKey(camera.point),
                point = camera.point,
                maxspeed = camera.limitKmh.takeIf { it > 0 }?.toString(),
                direction = "${camera.directionDeg}°",
            )
            fun verdict(reason: Reason, radar: WireRadar? = null) =
                Verdict(asCamera, reason, near.offsetM, dist, bearing, radar, Source.PARDAL)
            val turn = abs(((camera.directionDeg - bearing) % 360 + 540) % 360 - 180)
            when {
                near.offsetM > PARDAL_NEAR_M -> dropped.add(verdict(Reason.FAR))
                osmX.indices.any { LocalPlane.distance(osmX[it], osmY[it], px, py) <= SAME_PLACE_M } ->
                    dropped.add(verdict(Reason.IN_OSM))
                turn > 90 -> dropped.add(verdict(Reason.WRONG_WAY))
                else -> found.add(
                    verdict(
                        Reason.KEPT,
                        WireRadar(
                            distAlongM = dist,
                            dLat = camera.point.lat - route.lat0,
                            dLon = camera.point.lon - route.lon0,
                            limitKmh = camera.limitKmh,
                            flags = Protocol.RADAR_FLAG_DIRECTION,
                        ),
                    ),
                )
            }
        }
    }

    /**
     * The pardal camera's key in the log, in place of the OSM id: negative, so it does not collide with a node,
     * and one per position, so `tools/relatorio.py` does not merge two cameras under one key.
     */
    fun pardalKey(point: PointE5): Long = -(abs(point.lat).toLong() * 100_000_000L + abs(point.lon))

    /** `maxspeed` in km/h: "60" or "60 km/h"; miles, "none" and the like are `null`. */
    fun kmh(tag: String?): Int? {
        val value = tag?.trim()?.lowercase() ?: return null
        if (value.contains("mph") || value.contains("knots")) {
            return null
        }
        val number = Regex("^(\\d+)\\s*(km/h|kmh|kph)?$").find(value)?.groupValues?.get(1) ?: return null
        return number.toIntOrNull()?.takeIf { it in 1..255 }
    }

    private class Near(val index: Int, val t: Double, val offsetM: Double)

    private fun nearestSegment(xs: DoubleArray, ys: DoubleArray, px: Double, py: Double): Near {
        var best = Near(0, 0.0, Double.MAX_VALUE)
        for (i in 0 until xs.size - 1) {
            val d = LocalPlane.distanceToSegment(px, py, xs[i], ys[i], xs[i + 1], ys[i + 1])
            if (d < best.offsetM) {
                val dx = xs[i + 1] - xs[i]
                val dy = ys[i + 1] - ys[i]
                val lengthSq = dx * dx + dy * dy
                val t = if (lengthSq <= 0.0) 0.0 else (((px - xs[i]) * dx + (py - ys[i]) * dy) / lengthSq).coerceIn(0.0, 1.0)
                best = Near(i, t, d)
            }
        }
        return best
    }

    /** Cosine between the way's drawing at the camera node and the track's segment (sx, sy). */
    private fun cosAt(way: OsmCameraWay, node: Long, plane: LocalPlane, sx: Double, sy: Double, segment: Double): Double? {
        val at = way.nodes.indexOf(node)
        if (at < 0 || segment <= 0.0) {
            return null
        }
        val from = way.points[maxOf(at - 1, 0)]
        val to = way.points[minOf(at + 1, way.points.size - 1)]
        val wx = plane.x(to) - plane.x(from)
        val wy = plane.y(to) - plane.y(from)
        val length = hypot(wx, wy)
        if (length <= 0.0) {
            return null
        }
        return (wx * sx + wy * sy) / (length * segment)
    }
}
