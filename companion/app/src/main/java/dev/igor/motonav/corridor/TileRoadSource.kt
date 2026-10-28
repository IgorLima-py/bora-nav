package dev.igor.motonav.corridor

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.bytesCapped
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.proto.PointE5
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * **The corridor's streets taken from vector tiles** (C16), in place of public Overpass.
 *
 * The zoom-[zoom] tiles that cover the polygon go out in parallel (up to [maxParallel] at a time),
 * each one is read by
 * [MvtReader], the lines of layer [schema] become OSM `highway` through [Schema.highwayOf], are
 * clipped at the tile edge and stitched between neighbors ([VectorTiles.stitch]). What comes out is the
 * same `List<OsmWay>` as [OverpassClient.fetch], and the rest of [CorridorBuilder] does not change.
 *
 * A tile that fails gets one more chance; if it fails again, the whole query fails
 * ([RoadSourceException]) and the [FallbackRoadSource] goes to Overpass. Half a corridor, with a 2 km
 * hole where the tile was missing, would be worse than waiting.
 *
 * With [cache], a tile already read comes from disk and only what is missing goes to the network: a repeated route downloads
 * nothing, and a neighboring one downloads only the new tip.
 */
open class TileRoadSource(
    /** The server's name, for the log. */
    private val name: String,
    private val schema: Schema,
    /**
     * The tile URL template, with `{z}`, `{x}` and `{y}`. Suspending because some servers change the
     * path with every map version and only say so in the TileJSON ([tileJsonTemplate]).
     */
    private val template: suspend () -> String,
    /** Requests in flight at the same time: what the server's terms ask for. */
    private val maxParallel: Int = 8,
    private val zoom: Int = ZOOM,
    private val client: OkHttpClient = defaultClient(),
    /** The tiles already read, by [TileId]; `null` downloads everything on every query. */
    private val cache: TileCache? = null,
) : RoadSource {

    /** What the last query cost: tiles, bytes downloaded, time and how many tiles came from the [cache]. */
    data class Stats(val tiles: Int, val bytes: Long, val pieces: Int, val ways: Int, val ms: Long, val retries: Int, val cached: Int = 0)

    @Volatile
    var lastStats: Stats? = null
        private set

    /** How a tile layer states a road's class. */
    class Schema(
        val name: String,
        val layer: String,
        val keys: Set<String>,
        /** The line's properties → OSM `highway` in the `04 §3.2` filter, or `null` (out of the map). */
        val highwayOf: (Map<String, Any>) -> String?,
    )

    override suspend fun fetch(polygon: List<PointE5>): List<OsmWay> {
        val startedAt = System.currentTimeMillis()
        val tiles = VectorTiles.cover(polygon, zoom)
        val stored = if (cache == null) {
            emptyMap()
        } else {
            withContext(Dispatchers.IO) { tiles.mapNotNull { tile -> cache.get(tile)?.let { tile to it } }.toMap() }
        }
        val missing = tiles.filter { it !in stored }
        // The template may cost a trip to the TileJSON: only when some tile is missing.
        val pattern = if (missing.isEmpty()) "" else template()
        val bytes = AtomicLong()
        val retries = AtomicInteger()
        val gate = Semaphore(maxParallel)
        val fetched = coroutineScope {
            missing.map { tile ->
                async {
                    val body = gate.withPermit { downloadWithRetry(urlOf(pattern, tile), tile, retries) }
                    bytes.addAndGet(body.size.toLong())
                    // A dense São Paulo tile is 300 to 600 KB: the read moves off the main thread.
                    val pieces = withContext(Dispatchers.Default) { decode(body, tile) }
                    cache?.let { withContext(Dispatchers.IO) { it.put(tile, pieces) } }
                    tile to pieces
                }
            }.awaitAll().toMap()
        }
        // In `cover` order, stored or downloaded: the stitching comes out the same in both cases.
        val pieces = tiles.flatMap { stored[it] ?: fetched.getValue(it) }
        val ways = withContext(Dispatchers.Default) { VectorTiles.stitch(pieces) }
        val stats = Stats(tiles.size, bytes.get(), pieces.size, ways.size, System.currentTimeMillis() - startedAt, retries.get(), stored.size)
        lastStats = stats
        EventLog.i(
            TAG,
            "$name: ${stats.tiles} tiles z$zoom (${stats.cached} from cache), ${stats.bytes / 1024} KB, ${stats.pieces} pieces → " +
                "${stats.ways} ways in ${stats.ms} ms" + if (stats.retries > 0) ", ${stats.retries} tile(s) retried" else "",
        )
        return ways
    }

    /** The lines that matter from a tile, already clipped at its edge. */
    fun decode(body: ByteArray, tile: TileId): List<VectorTiles.Piece> {
        val lines = try {
            MvtReader.lines(body, schema.layer, schema.keys)
        } catch (e: Exception) {
            throw RoadSourceException("tile ${tile.z}/${tile.x}/${tile.y} unreadable: ${e.message}", e)
        }
        return lines.flatMap { line ->
            val highway = schema.highwayOf(line.properties) ?: return@flatMap emptyList()
            VectorTiles.clipToTile(line, tile, highway)
        }
    }

    private fun urlOf(pattern: String, tile: TileId): String =
        pattern.replace("{z}", tile.z.toString()).replace("{x}", tile.x.toString()).replace("{y}", tile.y.toString())

    private suspend fun downloadWithRetry(url: String, tile: TileId, retries: AtomicInteger): ByteArray {
        return try {
            download(url)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: RoadSourceException) {
            if (!e.retryable) throw e
            EventLog.w(TAG, "tile ${tile.z}/${tile.x}/${tile.y} failed (${e.message}); once more")
            retries.incrementAndGet()
            download(url)
        }
    }

    /**
     * A tile, **cancellable** like [OverpassClient.request]: `enqueue`, and the coroutine's
     * cancellation becomes `Call.cancel()`. `open` so the test can swap the network.
     */
    open suspend fun download(url: String): ByteArray =
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(Request.Builder().url(url).header("User-Agent", OverpassClient.USER_AGENT).build())
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    cont.resumeWithException(RoadSourceException("$name unreachable: ${e.message}", e, retryable = true))
                }

                override fun onResponse(call: Call, response: Response) {
                    cont.resumeWith(runCatching { response.use { read(it) } })
                }
            })
        }

    private fun read(response: Response): ByteArray {
        // 404 is an empty tile on some servers (sea, nothing mapped): no streets, no error.
        if (response.code == 404 || response.code == 204) {
            return ByteArray(0)
        }
        if (!response.isSuccessful) {
            // 401/403 is the token; repeating changes nothing. 429 and 5xx may pass.
            val retryable = response.code == 429 || response.code >= 500
            throw RoadSourceException("$name answered HTTP ${response.code}", retryable = retryable)
        }
        val body = response.body ?: return ByteArray(0)
        // In blocks, up to the cap: OkHttp opens `Content-Encoding: gzip` by itself, and a gzip bomb
        // from the server would become `OutOfMemoryError` in `bytes()`. Repeating does not change the tile.
        return try {
            body.bytesCapped(MvtReader.MAX_TILE_BYTES)
                ?: throw RoadSourceException("$name: tile over ${MvtReader.MAX_TILE_BYTES / (1024 * 1024)} MB")
        } catch (e: IOException) {
            throw RoadSourceException("$name: tile cut off midway: ${e.message}", e, retryable = true)
        }
    }

    companion object {
        private const val TAG = "Tiles"

        /** z14: ~2.2 km on a side in São Paulo, 15 to 19 tiles on a 22 km route (computation in `DECISIONS.md`). */
        const val ZOOM = 14

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .callTimeout(20, TimeUnit.SECONDS)
            // OkHttp's default is 5 calls per host; a route asks for ~20 tiles from the same host.
            .dispatcher(Dispatcher().apply { maxRequestsPerHost = 16 })
            .build()

        /** The public VersaTiles server, Shortbread 1.0 schema, z0-14. */
        const val VERSATILES_TEMPLATE = "https://tiles.versatiles.org/tiles/osm/{z}/{x}/{y}"

        /**
         * OpenFreeMap's TileJSON: the tile path carries the map version
         * (`/planet/20261011_080001_pt/{z}/{x}/{y}.pbf` on 2026-10-17) and changes with every build.
         */
        const val OPENFREEMAP_TILEJSON = "https://tiles.openfreemap.org/planet"

        fun versaTiles(client: OkHttpClient = defaultClient(), cache: TileCache? = null) =
            // 16 at once: the published limit is 200 per second per IP, and a route asks for ~20.
            TileRoadSource("VersaTiles", RoadSchemas.SHORTBREAD, { VERSATILES_TEMPLATE }, maxParallel = 16, client = client, cache = cache)

        /** OpenFreeMap's terms ask for at most 4 parallel requests and a User-Agent of your own. */
        fun openFreeMap(client: OkHttpClient = defaultClient()) =
            TileRoadSource(
                "OpenFreeMap",
                RoadSchemas.OPENMAPTILES,
                tileJsonTemplate(OPENFREEMAP_TILEJSON, client),
                maxParallel = 4,
                client = client,
            )

        /**
         * The tile template from a TileJSON (the first of `tiles`), read once and kept for
         * [TILEJSON_TTL_MS].
         */
        fun tileJsonTemplate(url: String, client: OkHttpClient): suspend () -> String {
            var cached: Pair<Long, String>? = null
            return {
                cached?.takeIf { System.currentTimeMillis() - it.first < TILEJSON_TTL_MS }?.second
                    ?: fetchTemplate(url, client).also { cached = System.currentTimeMillis() to it }
            }
        }

        private suspend fun fetchTemplate(url: String, client: OkHttpClient): String {
            val body = suspendCancellableCoroutine { cont ->
                val call = client.newCall(Request.Builder().url(url).header("User-Agent", OverpassClient.USER_AGENT).build())
                cont.invokeOnCancellation { call.cancel() }
                call.enqueue(object : Callback {
                    override fun onFailure(call: Call, e: IOException) {
                        cont.resumeWithException(RoadSourceException("TileJSON unreachable: ${e.message}", e, retryable = true))
                    }

                    override fun onResponse(call: Call, response: Response) {
                        cont.resumeWith(runCatching {
                            response.use {
                                if (!it.isSuccessful) throw RoadSourceException("TileJSON answered HTTP ${it.code}")
                                // With a cap, like the tile: if exceeded, the query fails and Overpass answers.
                                val text = try {
                                    it.textCapped(MAX_TILEJSON_BYTES)
                                } catch (e: IOException) {
                                    throw RoadSourceException("TileJSON cut off midway: ${e.message}", e, retryable = true)
                                }
                                text ?: throw RoadSourceException("TileJSON over ${MAX_TILEJSON_BYTES / 1024} KB")
                            }
                        })
                    }
                })
            }
            val first = try {
                Json.parseToJsonElement(body).jsonObject["tiles"]?.jsonArray?.firstOrNull()?.jsonPrimitive?.content
            } catch (e: Exception) {
                null
            } ?: throw RoadSourceException("TileJSON without `tiles`: ${body.take(120)}")
            return if (first.startsWith("/")) url.substringBefore("://") + "://" + url.substringAfter("://").substringBefore('/') + first else first
        }

        /** OpenFreeMap changes the map version once a week; a 6 h cache is at most one extra query per trip. */
        const val TILEJSON_TTL_MS = 6 * 3600_000L

        /** OpenFreeMap's TileJSON was 19 KB expanded on 2026-10-17 (measurement); 256 KB is slack (a choice). */
        const val MAX_TILEJSON_BYTES = 256 * 1024
    }
}
