package dev.igor.motonav.corridor

/**
 * Douglas-Peucker over points already in local meters (`04 §3.4`).
 *
 * The ε is per LOD and not global: on an expressway, 2 m of error disappear in the width of the
 * road; on a local street, 4 m still do not move the corner. What is gained is
 * bytes on the air and fewer vertices for the watch to rotate per frame — and the corridor is,
 * by far, the largest consumer of both.
 */
object Simplify {

    /** ε per LOD, in meters (04 §3.4): expressways, arterials, collectors, locals. */
    val EPSILON_M = doubleArrayOf(2.0, 2.0, 3.0, 4.0)

    fun douglasPeucker(xs: DoubleArray, ys: DoubleArray, epsilon: Double): IntArray {
        if (xs.size <= 2) {
            return IntArray(xs.size) { it }
        }
        val keep = BooleanArray(xs.size)
        keep[0] = true
        keep[xs.size - 1] = true

        // Explicit stack instead of recursion: an OSM way can have thousands
        // of vertices and deep recursion overflows the stack on Android.
        val stack = ArrayDeque<Pair<Int, Int>>()
        stack.addLast(0 to xs.size - 1)

        while (stack.isNotEmpty()) {
            val (from, to) = stack.removeLast()
            if (to <= from + 1) {
                continue
            }
            var worst = -1
            var worstDist = epsilon
            for (i in from + 1 until to) {
                val d = LocalPlane.distanceToSegment(xs[i], ys[i], xs[from], ys[from], xs[to], ys[to])
                if (d > worstDist) {
                    worstDist = d
                    worst = i
                }
            }
            if (worst >= 0) {
                keep[worst] = true
                stack.addLast(from to worst)
                stack.addLast(worst to to)
            }
        }

        return keep.indices.filter { keep[it] }.toIntArray()
    }

    /** Length of the polyline in meters — the short-way filter from 04 §3.4. */
    fun lengthM(xs: DoubleArray, ys: DoubleArray): Double {
        var total = 0.0
        for (i in 0 until xs.size - 1) {
            total += LocalPlane.distance(xs[i], ys[i], xs[i + 1], ys[i + 1])
        }
        return total
    }
}
