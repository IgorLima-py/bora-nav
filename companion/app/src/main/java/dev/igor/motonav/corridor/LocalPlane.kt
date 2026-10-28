package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PointE5
import kotlin.math.cos
import kotlin.math.hypot

/**
 * Local equirectangular projection, in meters — **a mirror of `Projection.mc`** on the
 * watch (ADR-6 of `02-ARCHITECTURE.md`).
 *
 * It exists here for the same reason it exists there: buffer, clip and simplification are
 * distance computations, and doing them in degrees gives a 10% error in longitude at the
 * latitude of São Paulo — enough to make the corridor crooked on one side.
 * The cosine of the latitude is computed **once** per route, not per point.
 */
class LocalPlane(val lat0: Int, val lon0: Int) {

    private val lonScale = METRES_PER_DEGREE * cos(Math.toRadians(lat0 * E5_TO_DEGREE))

    fun x(lonE5: Int): Double = (lonE5 - lon0) * E5_TO_DEGREE * lonScale

    fun y(latE5: Int): Double = (latE5 - lat0) * E5_TO_DEGREE * METRES_PER_DEGREE

    fun x(point: PointE5): Double = x(point.lon)

    fun y(point: PointE5): Double = y(point.lat)

    /** Back to protocol units — used when building the query polygon. */
    fun toLatE5(y: Double): Int = Math.round(y / METRES_PER_DEGREE / E5_TO_DEGREE).toInt() + lat0

    fun toLonE5(x: Double): Int = Math.round(x / lonScale / E5_TO_DEGREE).toInt() + lon0

    companion object {
        const val METRES_PER_DEGREE = 111194.9
        const val E5_TO_DEGREE = 0.00001

        fun distance(x1: Double, y1: Double, x2: Double, y2: Double): Double =
            hypot(x2 - x1, y2 - y1)

        /**
         * Distance from the point to segment AB. This is the computation that decides whether a street
         * enters the corridor, so it runs millions of times: no square root
         * whenever possible, and no allocation.
         */
        fun distanceToSegment(
            px: Double,
            py: Double,
            ax: Double,
            ay: Double,
            bx: Double,
            by: Double,
        ): Double {
            val dx = bx - ax
            val dy = by - ay
            val lengthSq = dx * dx + dy * dy
            if (lengthSq <= 0.0) {
                return distance(px, py, ax, ay)
            }
            var t = ((px - ax) * dx + (py - ay) * dy) / lengthSq
            t = t.coerceIn(0.0, 1.0)
            return distance(px, py, ax + dx * t, ay + dy * t)
        }
    }
}
