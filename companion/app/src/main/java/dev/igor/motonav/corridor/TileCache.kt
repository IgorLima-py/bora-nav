package dev.igor.motonav.corridor

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PointE5
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.File
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream

/**
 * **The street tiles already read, so a repeated trip does not wait for the network** (C16).
 *
 * It takes the place of C16.5's `CorridorCache`, which stored the Mapbox route together with the ways to
 * know whether a new route fit in the stored corridor. Mapbox's Product Terms forbid storing
 * Navigation API results (2.10.1, `DECISIONS.md` §2026-10-17, "the vehicle license"), and the
 * route is exactly that. Here the key is the [TileId] and the content is the street pieces that
 * [TileRoadSource] extracted from it, already clipped at the edge: OSM data under ODbL, with nothing from the route.
 * On a new route, only the missing tile is downloaded; a repeated route asks the network for nothing.
 *
 * It lives in the app's `cacheDir` (private; the system may clear it, and then it is just one more download). The stored
 * tiles say where Igor goes, in a ~2.2 km square, so nothing from here goes to the log
 * beyond counts (`CLAUDE.md`). Pure, no Android: it takes the directory. Several coroutines ask for
 * tiles at the same time, hence the `@Synchronized`.
 */
class TileCache(
    private val dir: File,
    private val now: () -> Long = System::currentTimeMillis,
    private val maxTiles: Int = MAX_TILES,
) {

    private class Entry(val file: File, val savedMs: Long)

    private var index: MutableMap<TileId, Entry>? = null

    /** The stored pieces of [tile], or `null` if there are none, it expired or it is unreadable. */
    @Synchronized
    fun get(tile: TileId): List<VectorTiles.Piece>? {
        val entry = entries()[tile] ?: return null
        if (now() - entry.savedMs >= MAX_AGE_MS) {
            forget(tile)
            return null
        }
        return try {
            read(entry.file).second
        } catch (e: Exception) {
            EventLog.w(TAG, "cached tile unreadable, downloading again: ${e.javaClass.simpleName}")
            forget(tile)
            null
        }
    }

    /** Stores the pieces of [tile]; the oldest tile goes beyond [maxTiles]. Failing here only costs a download. */
    @Synchronized
    fun put(tile: TileId, pieces: List<VectorTiles.Piece>) {
        try {
            dir.mkdirs()
            val savedMs = now()
            val file = File(dir, "${tile.z}_${tile.x}_${tile.y}.bin")
            val temp = File(dir, file.name + ".tmp")
            DataOutputStream(GZIPOutputStream(temp.outputStream().buffered())).use { out ->
                out.writeInt(VERSION)
                out.writeLong(savedMs)
                out.writeInt(pieces.size)
                for (piece in pieces) {
                    out.writeUTF(piece.highway)
                    out.writeBoolean(piece.cutStart)
                    out.writeBoolean(piece.cutEnd)
                    out.writeInt(piece.points.size)
                    piece.points.forEach { out.writeInt(it.lat); out.writeInt(it.lon) }
                }
            }
            // On Windows `renameTo` does not overwrite; the expired tile that comes back must go first.
            file.delete()
            check(temp.renameTo(file)) { "rename failed" }
            val map = entries()
            map[tile] = Entry(file, savedMs)
            while (map.size > maxTiles) {
                forget(map.minByOrNull { it.value.savedMs }!!.key)
            }
        } catch (e: Exception) {
            EventLog.w(TAG, "tile not cached: ${e.javaClass.simpleName}")
        }
    }

    private fun entries(): MutableMap<TileId, Entry> {
        index?.let { return it }
        val loaded = HashMap<TileId, Entry>()
        for (file in dir.listFiles { file -> file.name.endsWith(".bin") } ?: emptyArray()) {
            val tile = tileOf(file.name)
            val savedMs = try {
                read(file, header = true).first
            } catch (e: Exception) {
                null
            }
            if (tile == null || savedMs == null) {
                file.delete()
            } else {
                loaded[tile] = Entry(file, savedMs)
            }
        }
        index = loaded
        return loaded
    }

    private fun forget(tile: TileId) {
        index?.remove(tile)?.file?.delete()
    }

    /** The `savedMs` and the pieces; with [header], only the `savedMs` (the list comes back empty). */
    private fun read(file: File, header: Boolean = false): Pair<Long, List<VectorTiles.Piece>> =
        // The file opens outside the GZIP: with a broken file the GZIP fails right in the constructor, and the
        // file stayed open (on Windows, unable to be deleted).
        file.inputStream().use { raw ->
            val input = DataInputStream(GZIPInputStream(raw.buffered()))
            check(input.readInt() == VERSION) { "version" }
            val savedMs = input.readLong()
            if (header) return@use savedMs to emptyList()
            savedMs to List(count(input)) {
                val highway = input.readUTF()
                val cutStart = input.readBoolean()
                val cutEnd = input.readBoolean()
                VectorTiles.Piece(highway, List(count(input)) { PointE5(input.readInt(), input.readInt()) }, cutStart, cutEnd)
            }
        }

    /**
     * A count from the file, checked before `List(n)`, which reserves the `n` slots at once:
     * a broken count became `OutOfMemoryError`, which slips past [get]'s `catch`.
     */
    private fun count(input: DataInputStream): Int =
        input.readInt().also { check(it in 0..MAX_COUNT) { "count $it" } }

    companion object {
        private const val TAG = "TileCache"

        /**
         * Goes up when what a piece stores changes or how the layer becomes `highway` (the
         * `RoadSchemas`): the tile stored under the old rule is dropped on read and downloaded again.
         */
        internal const val VERSION = 1

        /**
         * A thousand z14 tiles, about 7.5 MB: on the old test route (22.4 km) the 18 tiles took 139 KB on
         * disk, the largest at 10 KB (`RoadSourceLiveTest`, 2026-10-17). A z14 tile in São Paulo is
         * ~5 km², so a thousand cover three times the municipality's area. The cap is a choice; the size, a measurement.
         */
        const val MAX_TILES = 1000

        /** A new street in OSM takes weeks to reach the tile; a month is slack. A choice, not a measurement. */
        const val MAX_AGE_MS = 30L * 24 * 60 * 60 * 1000

        /**
         * A tile above [MvtReader.MAX_TILE_BYTES] is refused earlier, and each point of it costs
         * at least one byte: a count larger than that is a broken file.
         */
        private const val MAX_COUNT = MvtReader.MAX_TILE_BYTES

        private val NAME = Regex("""(\d+)_(\d+)_(\d+)\.bin""")

        /** `null` also for a number that does not fit in an `Int`: the file goes, and the cache carries on. */
        private fun tileOf(name: String): TileId? {
            val (z, x, y) = NAME.matchEntire(name)?.destructured ?: return null
            return TileId(z.toIntOrNull() ?: return null, x.toIntOrNull() ?: return null, y.toIntOrNull() ?: return null)
        }
    }
}
