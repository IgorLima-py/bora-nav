package dev.igor.motonav.corridor

import kotlin.math.floor

/**
 * Answers "is this point inside the corridor?" — the question that defines the
 * buffer of `04 §3.1`: inside means within [corridorM] of the route, **or** within
 * [maneuverM] of a maneuver point, because at an intersection it matters to see
 * farther than on a straight.
 *
 * ## Why there is an index here
 *
 * The naive answer is to test the point against every segment of the route. On an urban
 * route of 500 points and a corridor with tens of thousands of vertices,
 * that is tens of millions of computations **per share**, in the middle of the
 * 7 s the whole transfer takes today. The index is a uniform grid of
 * cells the size of the search radius: a point is only tested against the
 * segments of the 9 neighboring cells, and the cost becomes proportional to the number of
 * corridor points instead of the product of the two.
 */
class RouteProximity(
    private val xs: DoubleArray,
    private val ys: DoubleArray,
    private val maneuverIdx: List<Int>,
    private val corridorM: Double = CORRIDOR_M,
    private val maneuverM: Double = MANEUVER_M,
) {

    private val cellSize = maxOf(corridorM, maneuverM)
    private val cells = HashMap<Long, MutableList<Int>>()

    init {
        // Each segment goes into every cell that its bounding box
        // touches; without that, a long segment crossing an empty cell
        // would leave a hole in the middle of the avenue.
        for (i in 0 until xs.size - 1) {
            val minCx = cellOf(minOf(xs[i], xs[i + 1]))
            val maxCx = cellOf(maxOf(xs[i], xs[i + 1]))
            val minCy = cellOf(minOf(ys[i], ys[i + 1]))
            val maxCy = cellOf(maxOf(ys[i], ys[i + 1]))
            for (cx in minCx..maxCx) {
                for (cy in minCy..maxCy) {
                    cells.getOrPut(key(cx, cy)) { mutableListOf() }.add(i)
                }
            }
        }
    }

    fun isInside(px: Double, py: Double): Boolean {
        val cx = cellOf(px)
        val cy = cellOf(py)
        for (dx in -1..1) {
            for (dy in -1..1) {
                val bucket = cells[key(cx + dx, cy + dy)] ?: continue
                for (i in bucket) {
                    val limit = if (isNearManeuver(i)) maneuverM else corridorM
                    val d = LocalPlane.distanceToSegment(px, py, xs[i], ys[i], xs[i + 1], ys[i + 1])
                    if (d <= limit) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /**
     * Smallest distance from the point to the track, in meters — `Double.MAX_VALUE` if the
     * point is far from any grid cell.
     *
     * It is the cut key of `CorridorBuilder.fitToCaps`: when the corridor does not
     * fit, what goes is the street **farthest from the route**, not the humblest street.
     * On a motorcycle, the neighborhood street hugging the track is the one that says which entrance
     * to turn into; the arterial 300 m away is scenery.
     */
    fun distanceTo(px: Double, py: Double): Double {
        var best = Double.MAX_VALUE
        val cx = cellOf(px)
        val cy = cellOf(py)
        for (dx in -1..1) {
            for (dy in -1..1) {
                val bucket = cells[key(cx + dx, cy + dy)] ?: continue
                for (i in bucket) {
                    val d = LocalPlane.distanceToSegment(px, py, xs[i], ys[i], xs[i + 1], ys[i + 1])
                    if (d < best) {
                        best = d
                    }
                }
            }
        }
        return best
    }

    /** Distance along the route, approximated by the index of the nearest point. */
    fun nearestRouteIndex(px: Double, py: Double): Int {
        var best = 0
        var bestDist = Double.MAX_VALUE
        for (i in xs.indices) {
            val d = LocalPlane.distance(px, py, xs[i], ys[i])
            if (d < bestDist) {
                bestDist = d
                best = i
            }
        }
        return best
    }

    private fun isNearManeuver(segmentIdx: Int): Boolean =
        maneuverIdx.any { it == segmentIdx || it == segmentIdx + 1 }

    private fun cellOf(value: Double): Int = floor(value / cellSize).toInt()

    private fun key(cx: Int, cy: Int): Long = (cx.toLong() shl 32) xor (cy.toLong() and 0xFFFFFFFFL)

    companion object {
        /** A ±300 m band along the route (04 §3.1). */
        const val CORRIDOR_M = 300.0

        /** At maneuvers the radius opens to 600 m: that is where one looks around. */
        const val MANEUVER_M = 600.0
    }
}
