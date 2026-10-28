package dev.igor.motonav.corridor

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Protocol
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Builds the street corridor around the route (`04 §3`).
 *
 * Chain: approximate polygon → [RoadSource] (the VersaTiles tiles, stored per tile
 * in the [TileCache], with Overpass as a fallback, C16) →
 * classification into LODs → exact clip by [RouteProximity] → Douglas-Peucker per
 * LOD → hard caps.
 *
 * **A street-source failure never takes navigation down.** The corridor is scenery: without it
 * the map keeps working with the route line, which is the information that
 * matters. That is why [build] returns `null` instead of propagating the exception — the
 * caller carries on with the route and the corridor arrives (or not) on a later attempt.
 */
class CorridorBuilder(
    /** Where the raw ways come from: in the app, the VersaTiles tiles with Overpass as a fallback ([AppRoads]). */
    private val roads: RoadSource,
) {

    /**
     * **Total** corridor budget, from the first byte to the last.
     *
     * The deadline was born at 15 s when the route **waited** for the corridor: every second
     * was Igor standing on the sidewalk. Once the route started going out first
     * (6.1 s from share to watch), those 15 s stopped protecting
     * anyone and started **killing queries that would have succeeded** — the log showed
     * "Timed out waiting for 15000 ms" on both mirrors, and the same query,
     * measured by hand, took **12.7 s** and returned 791 KB of ways.
     *
     * Now the deadline exists only so the search is not left hanging forever.
     * Nobody is waiting: the waiter is a background coroutine, and the
     * map is already on screen.
     */
    suspend fun build(route: PackableRoute): PackableCorridor? =
        withTimeoutOrNull(BUDGET_MS) { buildWithin(route) }

    private suspend fun buildWithin(route: PackableRoute): PackableCorridor? {
        if (route.points.size < 2) {
            return null
        }
        val plane = LocalPlane(route.lat0, route.lon0)
        val startedAt = System.currentTimeMillis()

        val polygon = bufferPolygon(route, plane)
        // One line before the call, so the log tells "never tried" apart from
        // "tried and the server did not answer" without relying on inference.
        EventLog.i(TAG, "querying streets: polygon of ${polygon.size} vertices")

        val ways = try {
            roads.fetch(polygon)
        } catch (e: RoadSourceException) {
            // Proceed without a corridor (04 §3.7). The log keeps the why, in
            // case it becomes the norm instead of chance.
            EventLog.w(TAG, "no corridor for this route: ${e.message}")
            return null
        }
        EventLog.i(TAG, "streets: ${ways.size} ways in ${System.currentTimeMillis() - startedAt} ms")

        val corridor = assemble(ways, route, plane)
        val (capped, dropped) = corridor.capped(route.lat0, route.lon0)
        dropped.forEach { EventLog.w(TAG, "corridor cap: $it dropped") }

        EventLog.i(
            TAG,
            "corridor: ${capped.segmentCount()} segments in ${capped.nonEmptyLods().size} LOD(s), " +
                "${System.currentTimeMillis() - startedAt} ms total",
        )
        return if (capped.segmentCount() == 0) null else capped
    }

    /**
     * Clips, classifies and simplifies the raw ways. Separate from [build] so it
     * is testable without a network — all the logic that can go wrong lives here.
     */
    fun assemble(ways: List<OsmWay>, route: PackableRoute, plane: LocalPlane): PackableCorridor {
        val proximity = proximityOf(route, plane)
        val buckets = mutableListOf<CorridorWay>()

        for (way in ways) {
            val lod = lodOf(way.highway) ?: continue
            for (run in clip(way.points, plane, proximity)) {
                val simplified = simplify(run, plane, lod) ?: continue
                val first = simplified.first()
                val middle = simplified[simplified.size / 2]
                buckets.add(
                    CorridorWay(
                        lod = lod,
                        order = proximity.nearestRouteIndex(plane.x(first), plane.y(first)),
                        distanceM = proximity.distanceTo(plane.x(middle), plane.y(middle)),
                        points = simplified,
                    ),
                )
            }
        }
        return fitToCaps(buckets)
    }

    /**
     * Picks what fits under the cap — **cutting by distance to the route, not by
     * road class.**
     *
     * The previous version dropped whole LODs, local first. That sounds
     * reasonable (a small street matters less) and in practice is the opposite of
     * what navigation needs: the log of four shares in a row says
     * `teto do corredor: LOD 3 (439 ways) descartado` every time, and what was left
     * on Igor's screen was only avenues — without the neighborhood grid, which is precisely
     * what answers "is it this turn or the next?".
     *
     * The right order is geographic. Expressways and arterials go in whole: there are
     * few and they guide from afar. What is left under the cap is filled with collectors
     * and locals **from the ones closest to the track to the farthest**, which is the
     * order in which they stop mattering. A ±300 m corridor over a 15 km route
     * has far more street than is visible in a 380 m radius; cutting the outer ones
     * removes nothing from any frame the rider actually looks at.
     */
    fun fitToCaps(all: List<CorridorWay>): PackableCorridor {
        val kept = List(Protocol.CORRIDOR_LOD_COUNT) { mutableListOf<CorridorWay>() }
        var segments = 0
        var bytes = 0

        val coarse = all.filter { it.lod <= Protocol.LOD_ARTERIAL }
        for (way in coarse) {
            kept[way.lod].add(way)
            segments += way.segments()
            bytes += way.bytes()
        }

        var trimmed = 0
        var lastKeptM = 0.0
        for (way in all.filter { it.lod > Protocol.LOD_ARTERIAL }.sortedBy { it.distanceM }) {
            // `continue` and not `break`: after one long way does not fit, a
            // short one right behind it still fits, and it costs almost nothing.
            if (segments + way.segments() > Protocol.MAX_CORRIDOR_SEGMENTS ||
                bytes + way.bytes() > Protocol.MAX_CORRIDOR_BYTES
            ) {
                trimmed++
                continue
            }
            kept[way.lod].add(way)
            segments += way.segments()
            bytes += way.bytes()
            lastKeptM = way.distanceM
        }
        if (trimmed > 0) {
            EventLog.i(
                TAG,
                "corridor cap: $trimmed thin ways cut by distance; " +
                    "mesh kept up to ${lastKeptM.toInt()} m from the route",
            )
        }

        // Within each LOD, sort by distance to the start of the route
        // (`04 §3.6`): the watch receives first what is near where the
        // rider is still going to pass.
        return PackableCorridor(kept.map { bucket -> bucket.sortedBy { it.order }.map { it.points } })
    }

    /**
     * Splits a way into the stretches that are inside the corridor.
     *
     * An avenue can enter and leave the band several times; each entry becomes its own
     * way. The points **immediately outside** each end are kept on
     * purpose: without them the street would end exactly at the invisible edge of the
     * buffer, and the cut would show on screen as a street that dies into nothing.
     */
    fun clip(
        points: List<PointE5>,
        plane: LocalPlane,
        proximity: RouteProximity,
    ): List<List<PointE5>> {
        val inside = BooleanArray(points.size) { proximity.isInside(plane.x(points[it]), plane.y(points[it])) }
        val runs = mutableListOf<List<PointE5>>()
        var i = 0
        while (i < points.size) {
            if (!inside[i]) {
                i++
                continue
            }
            var end = i
            while (end + 1 < points.size && inside[end + 1]) {
                end++
            }
            val from = maxOf(i - 1, 0)
            val to = minOf(end + 1, points.size - 1)
            if (to > from) {
                runs.add(points.subList(from, to + 1))
            }
            i = end + 1
        }
        return runs
    }

    /** Douglas-Peucker at the LOD's ε; `null` if the way became too short to be worth it. */
    private fun simplify(points: List<PointE5>, plane: LocalPlane, lod: Int): List<PointE5>? {
        val xs = DoubleArray(points.size) { plane.x(points[it]) }
        val ys = DoubleArray(points.size) { plane.y(points[it]) }
        if (Simplify.lengthM(xs, ys) < MIN_WAY_LENGTH_M) {
            return null
        }
        val keep = Simplify.douglasPeucker(xs, ys, Simplify.EPSILON_M[lod])
        return if (keep.size < 2) null else keep.map { points[it] }
    }

    private fun proximityOf(route: PackableRoute, plane: LocalPlane): RouteProximity {
        val xs = DoubleArray(route.points.size) { plane.x(route.points[it]) }
        val ys = DoubleArray(route.points.size) { plane.y(route.points[it]) }
        return RouteProximity(xs, ys, route.turns.map { it.pointIdx })
    }

    /**
     * Approximate polygon for Overpass's `poly:`: a ribbon around the route,
     * going up one side and coming back down the other.
     *
     * It is deliberately coarse and **wider** than the real corridor — it
     * only keeps the server from returning the whole city. The precise clipping is done
     * by [RouteProximity], afterwards, here on the phone. The route is reduced to half
     * the vertex cap because each of its points becomes **two** in the polygon.
     */
    fun bufferPolygon(route: PackableRoute, plane: LocalPlane): List<PointE5> {
        val points = route.points
        val xs = DoubleArray(points.size) { plane.x(points[it]) }
        val ys = DoubleArray(points.size) { plane.y(points[it]) }

        val spine = spineOf(xs, ys).first

        val left = mutableListOf<PointE5>()
        val right = mutableListOf<PointE5>()
        for ((n, index) in spine.withIndex()) {
            val previous = spine[maxOf(n - 1, 0)]
            val next = spine[minOf(n + 1, spine.size - 1)]
            var dx = xs[next] - xs[previous]
            var dy = ys[next] - ys[previous]
            val length = LocalPlane.distance(0.0, 0.0, dx, dy)
            if (length <= 0.0) {
                dx = 1.0
                dy = 0.0
            } else {
                dx /= length
                dy /= length
            }
            // Normal of the track, with a generous margin over the real corridor.
            val nx = -dy * POLYGON_MARGIN_M
            val ny = dx * POLYGON_MARGIN_M
            left.add(PointE5(plane.toLatE5(ys[index] + ny), plane.toLonE5(xs[index] + nx)))
            right.add(PointE5(plane.toLatE5(ys[index] - ny), plane.toLonE5(xs[index] - nx)))
        }
        return left + right.reversed()
    }

    /**
     * The polygon's spine and the ε that fit. Increasing ε until it fits: a short route
     * passes on the first try, a long one loosens until the polygon is the size
     * Overpass can handle.
     */
    private fun spineOf(xs: DoubleArray, ys: DoubleArray): Pair<IntArray, Double> {
        val maxSpine = OverpassClient.MAX_POLY_VERTICES / 2
        var epsilon = SPINE_EPSILON_M
        var spine = Simplify.douglasPeucker(xs, ys, epsilon)
        while (spine.size > maxSpine) {
            epsilon *= 2
            spine = Simplify.douglasPeucker(xs, ys, epsilon)
        }
        return spine to epsilon
    }

    /** OSM class → LOD (04 §3.3). `null` = a road that does not matter to the map. */
    fun lodOf(highway: String): Int? = when (highway) {
        "motorway", "trunk", "motorway_link", "trunk_link" -> Protocol.LOD_EXPRESS
        "primary", "secondary", "primary_link", "secondary_link" -> Protocol.LOD_ARTERIAL
        "tertiary" -> Protocol.LOD_COLLECTOR
        "residential", "unclassified" -> Protocol.LOD_LOCAL
        else -> null
    }

    /**
     * A way already clipped and simplified, with the two keys that decide its
     * fate: [order] (where it falls along the route, which rules the send
     * order) and [distanceM] (how far it is from the track, which rules
     * the cut when the cap tightens).
     */
    data class CorridorWay(
        val lod: Int,
        val order: Int,
        val distanceM: Double,
        val points: List<PointE5>,
    ) {
        fun segments(): Int = maxOf(points.size - 1, 0)

        /**
         * Approximate on-the-air size: way header plus two int16 per point
         * (`05 §CORRIDOR`). It is an estimate on purpose — calling the packer per way
         * to decide whether it fits would cost more than the whole corridor, and the
         * exact count is still checked by `PackableCorridor.capped`.
         */
        fun bytes(): Int = 4 + 4 * points.size
    }

    companion object {
        private const val TAG = "CorridorBuilder"

        /**
         * See [build]. Generous on purpose: the measured query of a 19 km
         * route costs 12.7 s on a quiet server, and the same query on a busy
         * server costs multiples of that. Since nobody is waiting,
         * the deadline only needs to be short enough that the search is not left
         * hanging beyond the three attempts.
         */
        const val BUDGET_MS = 90_000L

        /** A way shorter than this is scenery, not guidance (04 §3.4). */
        const val MIN_WAY_LENGTH_M = 20.0

        /** Slack of the query polygon over the real corridor, in meters. */
        const val POLYGON_MARGIN_M = 700.0

        /** Initial ε of the polygon spine — coarse, it is only for the query. */
        const val SPINE_EPSILON_M = 50.0
    }
}
