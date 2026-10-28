package dev.igor.motonav.nav

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RouteResult
import dev.igor.motonav.share.Destination
import kotlin.math.cos
import kotlin.math.hypot

/**
 * The route the watch is navigating, from the point of view of whoever recalculates it (C11):
 * the destination and the stops, each with the distance along the route where it sits.
 *
 * It also keeps **the request that produced it** ([origin], [bearing], all the stops): it is
 * with that request that `ROUTE_UPDATE` (C13a) asks the provider again how long the same
 * route takes now.
 *
 * Pure, no Android: it is what `RerouteWaypointsTest` exercises.
 */
class RerouteSession private constructor(
    val routeId: Int,
    val destination: LatLng,
    val label: String,
    private val stops: List<Stop>,
    /** The start: the first point of the route that went to the watch. */
    val origin: LatLng,
    /** The request's bearing, when there was one (only the recalculation sends it). */
    val bearing: Float?,
    /** What the provider said when the route was calculated. */
    val durationS: Int,
    val distanceM: Int,
) {

    /** An intermediate stop and how far from the start it sits, in meters. */
    data class Stop(val position: LatLng, val alongM: Int)

    /**
     * The stops the recalculation still has to cross, in order.
     *
     * [distAlongM] is the one from the **last fix where the watch was on the route**. A
     * stop less than [ARRIVAL_M] from it has already been reached: asking for a route through it
     * again would send Igor back to a point he already visited.
     */
    fun remainingVia(distAlongM: Int): List<LatLng> =
        stops.filter { it.alongM - ARRIVAL_M > distAlongM }.map { it.position }

    /**
     * All the stops, in order, as they were requested. It is not `remainingVia(0)`: that one
     * drops a stop less than [ARRIVAL_M] from the start, and the original request did not.
     */
    fun allVia(): List<LatLng> = stops.map { it.position }

    companion object {
        /**
         * The watch's arrival radius: `ARRIVAL_M` of `NavEngine.mc`. A stop
         * counts as visited when the watch would consider it reached.
         */
        const val ARRIVAL_M = 30

        /** Meters per E5 unit of latitude: 1° ≈ 111.32 km (WGS84, mean) ÷ 100,000. */
        private const val M_PER_E5 = 1.1132

        /**
         * The session of a freshly calculated route: [destination] carries the stops, and
         * [route] says at which polyline point each one ended. [bearing] is the heading
         * the route was requested with, if any.
         */
        fun of(routeId: Int, destination: Destination, route: RouteResult, bearing: Float? = null): RerouteSession {
            val via = destination.via
            // A route with no points does not get here (the parser refuses it); the destination is only
            // there so the session exists without throwing.
            val origin = route.points.firstOrNull()?.let { LatLng(it.lat / 1e5, it.lon / 1e5) } ?: destination.position
            if (via.size != route.stopIdx.size) {
                // Mapbox returns one leg per stretch, so this does not happen; if it
                // does, without the distance there is no way to know which stop was passed.
                EventLog.w(
                    "RerouteSession",
                    "${via.size} stop(s) requested and ${route.stopIdx.size} leg(s) in the route: no stops in the recalculation",
                )
                return RerouteSession(
                    routeId, destination.position, destination.label, emptyList(),
                    origin, bearing, route.durationS, route.distanceM,
                )
            }
            val stops = via.mapIndexed { i, position ->
                Stop(position, alongMetres(route.points, route.stopIdx[i]))
            }
            return RerouteSession(
                routeId, destination.position, destination.label, stops,
                origin, bearing, route.durationS, route.distanceM,
            )
        }

        /**
         * Meters from the start to point [index], summed **over the same E5 points
         * the watch receives** (local equirectangular plane: the route is urban).
         */
        fun alongMetres(points: List<PointE5>, index: Int): Int {
            var total = 0.0
            val last = index.coerceIn(0, points.size - 1)
            for (i in 1..last) {
                val a = points[i - 1]
                val b = points[i]
                val midLat = Math.toRadians((a.lat + b.lat) / 2.0 / 1e5)
                val dy = (b.lat - a.lat) * M_PER_E5
                val dx = (b.lon - a.lon) * M_PER_E5 * cos(midLat)
                total += hypot(dx, dy)
            }
            return Math.round(total).toInt()
        }
    }
}
