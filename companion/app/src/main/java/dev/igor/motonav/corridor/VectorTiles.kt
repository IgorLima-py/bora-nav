package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PointE5
import kotlin.math.PI
import kotlin.math.asinh
import kotlin.math.atan
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.sinh
import kotlin.math.tan

/** A tile in the XYZ scheme (y grows southward), the one every vector-tile server uses. */
data class TileId(val z: Int, val x: Int, val y: Int)

/**
 * The corridor's tile computations (C16): which tiles cover the polygon, the clip of each line at the
 * edge of its tile, and the stitching of the lines the edge split.
 */
object VectorTiles {

    /** Longitude in degrees → fractional tile x at zoom [z] (Web Mercator). */
    fun tileX(lonDeg: Double, z: Int): Double = (lonDeg + 180.0) / 360.0 * (1 shl z)

    /** Latitude in degrees → fractional tile y at zoom [z]. */
    fun tileY(latDeg: Double, z: Int): Double =
        (1.0 - asinh(tan(Math.toRadians(latDeg))) / PI) / 2.0 * (1 shl z)

    fun lonOf(tileX: Double, z: Int): Double = tileX / (1 shl z) * 360.0 - 180.0

    fun latOf(tileY: Double, z: Int): Double = Math.toDegrees(atan(sinh(PI * (1.0 - 2.0 * tileY / (1 shl z)))))

    /**
     * The zoom-[z] tiles that touch [polygon]: the ones the edge crosses (sampled every 1/16 of a
     * tile) and the ones that sit entirely inside (the center inside the polygon).
     */
    fun cover(polygon: List<PointE5>, z: Int): List<TileId> {
        require(polygon.size >= 3) { "the corridor polygon needs at least 3 vertices" }
        val fx = DoubleArray(polygon.size) { tileX(polygon[it].lon * LocalPlane.E5_TO_DEGREE, z) }
        val fy = DoubleArray(polygon.size) { tileY(polygon[it].lat * LocalPlane.E5_TO_DEGREE, z) }
        val tiles = LinkedHashSet<TileId>()
        for (i in polygon.indices) {
            val j = (i + 1) % polygon.size
            val steps = maxOf(1, ceil(hypot(fx[j] - fx[i], fy[j] - fy[i]) * EDGE_SAMPLES_PER_TILE).toInt())
            for (s in 0..steps) {
                val t = s.toDouble() / steps
                tiles.add(TileId(z, floor(fx[i] + (fx[j] - fx[i]) * t).toInt(), floor(fy[i] + (fy[j] - fy[i]) * t).toInt()))
            }
        }
        for (x in floor(fx.min()).toInt()..floor(fx.max()).toInt()) {
            for (y in floor(fy.min()).toInt()..floor(fy.max()).toInt()) {
                if (inside(x + 0.5, y + 0.5, fx, fy)) {
                    tiles.add(TileId(z, x, y))
                }
            }
        }
        return tiles.toList()
    }

    /** Point in polygon, by ray casting (even-odd). */
    private fun inside(px: Double, py: Double, xs: DoubleArray, ys: DoubleArray): Boolean {
        var odd = false
        var j = xs.size - 1
        for (i in xs.indices) {
            if ((ys[i] > py) != (ys[j] > py) && px < (xs[j] - xs[i]) * (py - ys[i]) / (ys[j] - ys[i]) + xs[i]) {
                odd = !odd
            }
            j = i
        }
        return odd
    }

    /** A piece of line inside the tile, and whether each end was born from the cut at the edge. */
    class Piece(val highway: String, val points: List<PointE5>, val cutStart: Boolean, val cutEnd: Boolean)

    /**
     * Clips [line] to the tile square ([0, extent] on both axes) and returns the pieces in
     * protocol units.
     *
     * MVT stores each line with a margin beyond the edge (the tile's *buffer*, so the drawing does not
     * join crooked); without the clip, the same street would appear twice in that strip, once from each
     * neighboring tile.
     */
    fun clipToTile(line: MvtReader.Line, tile: TileId, highway: String): List<Piece> {
        val e = line.extent.toDouble()
        val pieces = mutableListOf<Piece>()
        var run = mutableListOf<PointE5>()
        var runCutStart = false
        fun point(x: Double, y: Double) = PointE5(
            OverpassClient.quantize(latOf(tile.y + y / e, tile.z)),
            OverpassClient.quantize(lonOf(tile.x + x / e, tile.z)),
        )
        fun close(cutEnd: Boolean) {
            if (run.size >= 2) pieces.add(Piece(highway, run, runCutStart, cutEnd))
            run = mutableListOf()
        }
        for (i in 0 until line.xs.size - 1) {
            val x0 = line.xs[i].toDouble()
            val y0 = line.ys[i].toDouble()
            val x1 = line.xs[i + 1].toDouble()
            val y1 = line.ys[i + 1].toDouble()
            val clipped = liangBarsky(x0, y0, x1, y1, e)
            if (clipped == null) {
                close(cutEnd = true)
                continue
            }
            val (t0, t1) = clipped
            if (run.isEmpty()) {
                runCutStart = t0 > 0.0
                run.add(point(x0 + (x1 - x0) * t0, y0 + (y1 - y0) * t0))
            }
            run.add(point(x0 + (x1 - x0) * t1, y0 + (y1 - y0) * t1))
            if (t1 < 1.0) {
                close(cutEnd = true)
            }
        }
        close(cutEnd = false)
        return pieces.map { piece -> Piece(piece.highway, dedupe(piece.points), piece.cutStart, piece.cutEnd) }
            .filter { it.points.size >= 2 }
    }

    /** The stretch [t0, t1] of the segment that lies in the square [0, e]², or `null` if none does. */
    private fun liangBarsky(x0: Double, y0: Double, x1: Double, y1: Double, e: Double): Pair<Double, Double>? {
        val dx = x1 - x0
        val dy = y1 - y0
        var t0 = 0.0
        var t1 = 1.0
        val p = doubleArrayOf(-dx, dx, -dy, dy)
        val q = doubleArrayOf(x0, e - x0, y0, e - y0)
        for (k in 0 until 4) {
            if (p[k] == 0.0) {
                if (q[k] < 0.0) return null
            } else {
                val r = q[k] / p[k]
                if (p[k] < 0.0) {
                    if (r > t1) return null
                    if (r > t0) t0 = r
                } else {
                    if (r < t0) return null
                    if (r < t1) t1 = r
                }
            }
        }
        return if (t1 > t0) t0 to t1 else null
    }

    /** Drops consecutive repeated points (rounding to 1e-5 degree merges adjacent vertices). */
    private fun dedupe(points: List<PointE5>): List<PointE5> {
        val out = ArrayList<PointE5>(points.size)
        for (p in points) if (out.isEmpty() || out.last() != p) out.add(p)
        return out
    }

    /**
     * **Stitches the lines the tile edge split**: two cut ends, of the same class,
     * within [STITCH_TOLERANCE_E5] of each other, become a single way.
     *
     * Without stitching each edge crossing leaves two ways in place of one, and the piece that stays
     * in a tile corner may be shorter than the 20 m of [CorridorBuilder.MIN_WAY_LENGTH_M] and vanish:
     * a hole in the street right at the edge.
     */
    fun stitch(pieces: List<Piece>): List<OsmWay> {
        class End(val piece: Int, val atStart: Boolean, val point: PointE5)
        val cells = HashMap<Long, MutableList<End>>()
        fun cell(lat: Int, lon: Int): Long = (Math.floorDiv(lat, CELL_E5).toLong() shl 32) or (Math.floorDiv(lon, CELL_E5).toLong() and 0xffffffffL)
        val ends = mutableListOf<End>()
        pieces.forEachIndexed { i, piece ->
            if (piece.cutStart) ends.add(End(i, true, piece.points.first()))
            if (piece.cutEnd) ends.add(End(i, false, piece.points.last()))
        }
        ends.forEach { cells.getOrPut(cell(it.point.lat, it.point.lon)) { mutableListOf() }.add(it) }

        // partner[2i] = the end matched with the start of piece i; partner[2i+1], with the end.
        val partner = arrayOfNulls<End>(pieces.size * 2)
        fun slot(end: End) = end.piece * 2 + if (end.atStart) 0 else 1
        for (end in ends) {
            if (partner[slot(end)] != null) continue
            var best: End? = null
            var bestD = Long.MAX_VALUE
            val cx = Math.floorDiv(end.point.lat, CELL_E5)
            val cy = Math.floorDiv(end.point.lon, CELL_E5)
            for (dx in -1..1) for (dy in -1..1) {
                val key = ((cx + dx).toLong() shl 32) or ((cy + dy).toLong() and 0xffffffffL)
                for (other in cells[key].orEmpty()) {
                    if (other.piece == end.piece || partner[slot(other)] != null) continue
                    if (pieces[other.piece].highway != pieces[end.piece].highway) continue
                    val dLat = (other.point.lat - end.point.lat).toLong()
                    val dLon = (other.point.lon - end.point.lon).toLong()
                    if (kotlin.math.abs(dLat) > STITCH_TOLERANCE_E5 || kotlin.math.abs(dLon) > STITCH_TOLERANCE_E5) continue
                    val d = dLat * dLat + dLon * dLon
                    if (d < bestD) {
                        bestD = d
                        best = other
                    }
                }
            }
            if (best != null) {
                partner[slot(end)] = best
                partner[slot(best)] = end
            }
        }

        val used = BooleanArray(pieces.size)
        val ways = mutableListOf<OsmWay>()
        fun chainFrom(first: Int, forward: Boolean) {
            val points = ArrayList<PointE5>()
            var piece = first
            var fwd = forward
            while (!used[piece]) {
                used[piece] = true
                val pts = if (fwd) pieces[piece].points else pieces[piece].points.asReversed()
                // The repeated stitch end (or one 1 m from the other) goes: a single point at the edge.
                points.addAll(if (points.isEmpty()) pts else pts.subList(1, pts.size))
                val next = partner[piece * 2 + if (fwd) 1 else 0] ?: break
                piece = next.piece
                fwd = next.atStart
            }
            if (points.size >= 2) ways.add(OsmWay(pieces[first].highway, points))
        }
        // First the chains with a loose end, then the rings (a roundabout that the edge split).
        for (i in pieces.indices) {
            if (used[i]) continue
            when {
                partner[i * 2] == null -> chainFrom(i, forward = true)
                partner[i * 2 + 1] == null -> chainFrom(i, forward = false)
            }
        }
        for (i in pieces.indices) if (!used[i]) chainFrom(i, forward = true)
        return ways
    }

    /** Samples per edge tile of the polygon in [cover]: 1/16 of a z14 tile is ~140 m in São Paulo. */
    private const val EDGE_SAMPLES_PER_TILE = 16

    /** Ends within 3e-5 degree (~3 m) are the same edge crossing. */
    const val STITCH_TOLERANCE_E5 = 3

    private const val CELL_E5 = 4
}
