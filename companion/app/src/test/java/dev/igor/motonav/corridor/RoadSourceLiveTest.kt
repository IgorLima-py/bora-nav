package dev.igor.motonav.corridor

import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.route.MapboxRouteParser
import java.io.File
import kotlin.math.floor
import kotlinx.coroutines.runBlocking
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * **The measurement of the street sources on the real network** (C16), for the same route: the query time
 * and how much of one's corridor the other covers.
 *
 * Off in the battery (the battery depends on no network or public server). Turn it on with
 * `MOTONAV_REDE=1`:
 *
 * ```
 * MOTONAV_REDE=1 ./gradlew --no-daemon testDebugUnitTest --tests "*RoadSourceLiveTest*"
 * ```
 *
 * The report goes to `companion/app/build/road_measurement.txt` (outside git) and only has counts and
 * times: the route is the public fixture `tiete_copan` (18.6 km), no coordinate goes into the file.
 */
class RoadSourceLiveTest {

    private val repo = File("../..")

    @Test
    fun `measure the road sources on the same route`() {
        assumeTrue("enable with MOTONAV_REDE=1", System.getenv("MOTONAV_REDE") == "1")
        val route = MapboxRouteParser
            .parse(File(repo, "tools/fixtures/route_tiete_copan.json").readText(Charsets.UTF_8), "Copan")
            .toPackable(routeId = 1)
        val plane = LocalPlane(route.lat0, route.lon0)
        val builder = CorridorBuilder { emptyList() }
        val polygon = builder.bufferPolygon(route, plane)
        val report = StringBuilder()
        fun line(s: String) {
            println(s)
            report.append(s).append('\n')
        }
        line("route tiete_copan: ${route.points.size} points, polygon of ${polygon.size} vertices, " +
            "${VectorTiles.cover(polygon, TileRoadSource.ZOOM).size} tiles z${TileRoadSource.ZOOM}")

        val stored = OverpassClient().parse(File(repo, "tools/fixtures/corridor_tiete_copan.json").readText(Charsets.UTF_8))
        val corridors = linkedMapOf("Overpass (fixture of 2026-10-26)" to builder.assemble(stored, route, plane))
        // `MOTONAV_FONTES=VersaTiles,OpenFreeMap` measures only those (without bothering Overpass again).
        val only = System.getenv("MOTONAV_FONTES")?.split(',')?.map { it.trim() }?.toSet()
        for ((name, source) in LiveCandidates.candidates().filter { only == null || it.first in only }) {
            repeat(RUNS) { run ->
                val startedAt = System.nanoTime()
                val result = runCatching { runBlocking { source.fetch(polygon) } }
                val ms = (System.nanoTime() - startedAt) / 1_000_000
                result.onSuccess { ways ->
                    val corridor = builder.assemble(ways, route, plane)
                    val kb = (source as? TileRoadSource)?.lastStats?.let { ", ${it.bytes / 1024} KB in ${it.tiles} tiles, ${it.retries} retries" }.orEmpty()
                    line("$name, round ${run + 1}: ${ways.size} ways in $ms ms$kb; ${describe(corridor)}")
                    if (run == 0) corridors[name] = corridor
                }.onFailure { line("$name, round ${run + 1}: failed in $ms ms: ${it.message}") }
            }
        }
        // Only what stays within NEAR_M of the route: there the segment cap cuts nothing in any
        // source, so the difference is in the data, not in `fitToCaps`'s distance cut.
        val proximity = RouteProximity(
            DoubleArray(route.points.size) { plane.x(route.points[it]) },
            DoubleArray(route.points.size) { plane.y(route.points[it]) },
            route.turns.map { it.pointIdx },
        )
        val names = corridors.keys.toList()
        for (a in names) for (b in names) {
            if (a == b) continue
            val cover = (0 until 4).joinToString(" ") { lod ->
                "LOD$lod ${"%.0f".format(100 * coverage(corridors.getValue(a), corridors.getValue(b), plane, lod, proximity))}%"
            }
            line("from «$a», within $NEAR_M m of the route, at ≤ $TOLERANCE_M m from «$b»: $cover")
        }
        File(repo, "companion/app/build").mkdirs()
        File(repo, "companion/app/build/road_measurement.txt").writeText(report.toString(), Charsets.UTF_8)
    }

    /**
     * The [TileCache] on the same route: the first query downloads, the others come from disk. Measures the time
     * of each and the cache size, so `MAX_TILES` stops being just a choice.
     */
    @Test
    fun `measure the tile cache on the same route`() {
        assumeTrue("enable with MOTONAV_REDE=1", System.getenv("MOTONAV_REDE") == "1")
        val route = MapboxRouteParser
            .parse(File(repo, "tools/fixtures/route_tiete_copan.json").readText(Charsets.UTF_8), "Copan")
            .toPackable(routeId = 1)
        val polygon = CorridorBuilder { emptyList() }.bufferPolygon(route, LocalPlane(route.lat0, route.lon0))
        val dir = java.nio.file.Files.createTempDirectory("motonav-tiles").toFile()
        val report = StringBuilder()
        try {
            repeat(RUNS) { run ->
                // A new source every round: what comes from the cache comes from disk, as in another process.
                val source = TileRoadSource.versaTiles(cache = TileCache(dir))
                val ways = runBlocking { source.fetch(polygon) }
                val stats = source.lastStats!!
                report.append("VersaTiles with cache, round ${run + 1}: ${ways.size} ways in ${stats.ms} ms, ")
                    .append("${stats.cached} of ${stats.tiles} tiles from cache, ${stats.bytes / 1024} KB downloaded\n")
            }
            val files = dir.listFiles().orEmpty()
            report.append("cache: ${files.size} tiles, ${files.sumOf { it.length() } / 1024} KB on disk, ")
                .append("maior ${(files.maxOfOrNull { it.length() } ?: 0) / 1024} KB\n")
        } finally {
            dir.deleteRecursively()
        }
        print(report)
        File(repo, "companion/app/build").mkdirs()
        File(repo, "companion/app/build/medicao_cache.txt").writeText(report.toString(), Charsets.UTF_8)
    }

    private fun describe(c: PackableCorridor): String =
        (0 until 4).joinToString(", ") { lod ->
            val ways = c.ways[lod]
            "LOD$lod ${ways.size} vias/${ways.sumOf { maxOf(it.size - 1, 0) }} seg"
        } + ", ${c.segmentCount()} segmentos"

    /**
     * The fraction of the length of [a]'s ways of LOD [lod], up to [NEAR_M] from the route, that lies within
     * [TOLERANCE_M] of some way (of any LOD) of [b], sampled every [STEP_M].
     */
    private fun coverage(
        a: PackableCorridor,
        b: PackableCorridor,
        plane: LocalPlane,
        lod: Int,
        proximity: RouteProximity,
    ): Double {
        val grid = HashMap<Long, MutableList<DoubleArray>>()
        fun key(cx: Int, cy: Int) = (cx.toLong() shl 32) or (cy.toLong() and 0xffffffffL)
        for (way in b.ways.flatten()) for (i in 0 until way.size - 1) {
            val s = doubleArrayOf(plane.x(way[i]), plane.y(way[i]), plane.x(way[i + 1]), plane.y(way[i + 1]))
            val x0 = floor(minOf(s[0], s[2]) / CELL_M).toInt() - 1
            val x1 = floor(maxOf(s[0], s[2]) / CELL_M).toInt() + 1
            val y0 = floor(minOf(s[1], s[3]) / CELL_M).toInt() - 1
            val y1 = floor(maxOf(s[1], s[3]) / CELL_M).toInt() + 1
            for (cx in x0..x1) for (cy in y0..y1) grid.getOrPut(key(cx, cy)) { mutableListOf() }.add(s)
        }
        var total = 0.0
        var near = 0.0
        for (way in a.ways[lod]) for (i in 0 until way.size - 1) {
            val ax = plane.x(way[i]); val ay = plane.y(way[i])
            val bx = plane.x(way[i + 1]); val by = plane.y(way[i + 1])
            val length = LocalPlane.distance(ax, ay, bx, by)
            val steps = maxOf(1, (length / STEP_M).toInt())
            for (k in 0 until steps) {
                val t = (k + 0.5) / steps
                val px = ax + (bx - ax) * t
                val py = ay + (by - ay) * t
                if (proximity.distanceTo(px, py) > NEAR_M) continue
                val candidates = grid[key(floor(px / CELL_M).toInt(), floor(py / CELL_M).toInt())].orEmpty()
                val hit = candidates.any { s -> LocalPlane.distanceToSegment(px, py, s[0], s[1], s[2], s[3]) <= TOLERANCE_M }
                total += length / steps
                if (hit) near += length / steps
            }
        }
        return if (total == 0.0) 0.0 else near / total
    }

    companion object {
        const val RUNS = 3
        const val TOLERANCE_M = 8.0
        const val STEP_M = 5.0
        const val CELL_M = 25.0
        const val NEAR_M = 150.0
    }
}

/** The sources measured by [RoadSourceLiveTest], with what each one needs. */
internal object LiveCandidates {
    fun candidates(): List<Pair<String, RoadSource>> = listOf(
        "VersaTiles" to TileRoadSource.versaTiles(),
        "OpenFreeMap" to TileRoadSource.openFreeMap(),
        "Overpass live" to OverpassClient(),
    )
}
