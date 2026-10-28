package dev.igor.motonav.corridor

import android.content.Context
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PointE5
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * **The OSM speed cameras the phone already downloaded** (C16.6), for the route that goes out with Overpass down.
 *
 * On 2026-10-23 both mirrors refused both attempts for the cameras (502 "at capacity" and 504),
 * and no camera reached the wrist; the streets come from the tiles and were unaffected. Here is kept the union of everything
 * [RadarClient] has already received: the nodes and the ways that pass through them, which is what [RadarFilter]
 * reads. Whoever always rides in the same city has its cameras after the first few routes.
 *
 * A camera that left OSM stays here until a new search does not bring it back — and even then
 * it stays, because the search is by a route's polygon and the cache does not know the polygon. The cost is one
 * extra warning, which is the cheap side of the error (`DECISIONS.md` §"o radar de verdade"). The cache is only
 * used when Overpass fails.
 *
 * In a file in the app's **private** storage, like the favorites: the cameras are public, but
 * the set of them shows where Igor goes. Pure, no Android: it takes the [File]. Both
 * operations are synchronized; the caller does the I/O off the main thread.
 */
class RadarStore(private val file: File) {

    @Serializable
    private class Stored(val cameras: List<Camera> = emptyList(), val ways: List<Way> = emptyList())

    @Serializable
    private class Camera(val id: Long, val lat: Int, val lon: Int, val maxspeed: String? = null, val direction: String? = null)

    @Serializable
    private class Way(
        val nodes: List<Long>,
        val lats: List<Int>,
        val lons: List<Int>,
        val oneway: String? = null,
        val maxspeed: String? = null,
    )

    private var cameras: LinkedHashMap<Long, OsmCamera>? = null
    private var ways: LinkedHashMap<List<Long>, OsmCameraWay>? = null

    /** Everything downloaded so far. Empty if nothing was, or if the file cannot be read. */
    @Synchronized
    fun all(): OsmRadars {
        load()
        return OsmRadars(cameras!!.values.toList(), ways!!.values.toList())
    }

    /** Merges a new response: the node by id and the way by its node list, the new one winning. */
    @Synchronized
    fun merge(found: OsmRadars) {
        load()
        val byId = cameras!!
        val byNodes = ways!!
        val before = byId.size
        found.cameras.forEach { byId[it.id] = it }
        found.ways.forEach { byNodes[it.nodes] = it }
        save()
        EventLog.i(TAG, "radars cache: ${byId.size} (${byId.size - before} new), ${byNodes.size} ways")
    }

    private fun load() {
        if (cameras != null) {
            return
        }
        val stored = read()
        cameras = LinkedHashMap<Long, OsmCamera>().apply {
            stored.cameras.forEach { put(it.id, OsmCamera(it.id, PointE5(it.lat, it.lon), it.maxspeed, it.direction)) }
        }
        ways = LinkedHashMap<List<Long>, OsmCameraWay>().apply {
            stored.ways.filter { it.nodes.size == it.lats.size && it.lats.size == it.lons.size }.forEach { way ->
                put(way.nodes, OsmCameraWay(way.nodes, way.lats.zip(way.lons) { lat, lon -> PointE5(lat, lon) }, way.oneway, way.maxspeed))
            }
        }
    }

    private fun read(): Stored {
        if (!file.exists()) {
            return Stored()
        }
        return try {
            json.decodeFromString<Stored>(file.readText(Charsets.UTF_8))
        } catch (e: Exception) {
            // Starts over empty: the cache is a backup, and the next good search rebuilds it.
            EventLog.w(TAG, "radars cache unreadable: ${e.javaClass.simpleName}")
            Stored()
        }
    }

    private fun save() {
        val stored = Stored(
            cameras = cameras!!.values.map { Camera(it.id, it.point.lat, it.point.lon, it.maxspeed, it.direction) },
            ways = ways!!.values.map { way ->
                Way(way.nodes, way.points.map { it.lat }, way.points.map { it.lon }, way.oneway, way.maxspeed)
            },
        )
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.writeText(json.encodeToString(stored), Charsets.UTF_8)
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
        } catch (e: Exception) {
            // Stayed in memory: valid until the process dies.
            EventLog.w(TAG, "radars cache not saved: ${e.javaClass.simpleName}")
        }
    }

    companion object {
        private const val TAG = "RadarStore"
        const val FILE_NAME = "radares_osm.json"

        private val json = Json { ignoreUnknownKeys = true }

        /** The file inside [filesDir] (`Context.filesDir`, private to the app). */
        fun defaultFile(filesDir: File): File = File(filesDir, FILE_NAME)

        @Volatile
        private var instance: RadarStore? = null

        /** One per process: the writer (the search) and the reader (the route with Overpass down) see the same one. */
        fun of(context: Context): RadarStore =
            instance ?: synchronized(this) {
                instance ?: RadarStore(defaultFile(context.applicationContext.filesDir)).also { instance = it }
            }
    }
}
