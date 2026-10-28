package dev.igor.motonav.corridor

import android.content.Context
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.proto.PointE5
import java.io.File
import kotlinx.coroutines.withTimeoutOrNull

/**
 * A street source failed: [CorridorBuilder] carries on without a corridor (`04 §3.7`). [retryable] says whether
 * trying again right away may give a different answer (network, 429, 5xx) or not (token, unreadable tile).
 */
open class RoadSourceException(
    message: String,
    cause: Throwable? = null,
    val retryable: Boolean = false,
) : Exception(message, cause)

/**
 * **Where the corridor's raw ways come from** (C16): the contract that [OverpassClient.fetch] already had.
 *
 * It takes the coarse polygon from [CorridorBuilder.bufferPolygon] and returns the ways that touch it,
 * with OSM's `highway` and the points in protocol units. It may return ways slightly outside the
 * polygon: the precise clip is done by [RouteProximity], afterwards. It throws [RoadSourceException]
 * when it cannot, and never returns half a corridor without saying so.
 */
fun interface RoadSource {
    suspend fun fetch(polygon: List<PointE5>): List<OsmWay>
}

/**
 * **The app's streets** (C16): the VersaTiles tiles, stored per tile in the [TileCache], with
 * Overpass as a fallback. Only one per process, so OkHttp reuses connections from one route to the next
 * and the cache has a single owner ([CorridorBuilder] is created on every route). The choice, and the
 * rejected sources, are in `DECISIONS.md` §2026-10-17, "the street source".
 */
object AppRoads {

    @Volatile
    private var instance: RoadSource? = null

    fun of(context: Context): RoadSource =
        instance ?: synchronized(this) {
            instance ?: inCacheDir(context.applicationContext.cacheDir).also { instance = it }
        }

    /** The source with the tiles in [cacheDir]. Pure, no Android, for the test. */
    fun inCacheDir(cacheDir: File): RoadSource {
        // C16.5's `CorridorCache` stored the Mapbox route there, which the terms do not allow storing
        // (2.10.1). It goes away on the first route of this version.
        File(cacheDir, OLD_CORRIDORS_DIR).deleteRecursively()
        return FallbackRoadSource(
            TileRoadSource.versaTiles(cache = TileCache(File(cacheDir, TILES_DIR))),
            OverpassClient(),
            primaryName = "VersaTiles",
        )
    }

    const val TILES_DIR = "tiles_versatiles"
    const val OLD_CORRIDORS_DIR = "corredores"
}

/**
 * The fast source first and Overpass as a fallback.
 *
 * The [primary] has [primaryBudgetMs] to answer; if it failed, timed out or came back empty, the whole query goes
 * to the [reserve]. In series and not in parallel: public Overpass is shared, and asking
 * it every time the tiles answer in seconds is just a queue for everyone else.
 */
class FallbackRoadSource(
    private val primary: RoadSource,
    private val reserve: RoadSource,
    private val primaryName: String,
    private val primaryBudgetMs: Long = PRIMARY_BUDGET_MS,
) : RoadSource {

    override suspend fun fetch(polygon: List<PointE5>): List<OsmWay> {
        val startedAt = System.currentTimeMillis()
        val ways = try {
            withTimeoutOrNull(primaryBudgetMs) { primary.fetch(polygon) }
        } catch (e: RoadSourceException) {
            EventLog.w(TAG, "$primaryName failed in ${System.currentTimeMillis() - startedAt} ms: ${e.message}")
            null
        }
        if (!ways.isNullOrEmpty()) {
            return ways
        }
        if (ways == null) {
            EventLog.w(TAG, "$primaryName no response in $primaryBudgetMs ms; going to Overpass")
        } else {
            EventLog.w(TAG, "$primaryName returned 0 ways; going to Overpass")
        }
        return reserve.fetch(polygon)
    }

    companion object {
        private const val TAG = "RoadSource"

        /**
         * The tiles of a 22 km route arrive in a few seconds (the measurement is in `DECISIONS.md`
         * §2026-10-17, "the street source"); 20 s is the network: beyond that, the phone's network is
         * bad, and Overpass still has the 90 s of [CorridorBuilder.BUDGET_MS] minus this.
         */
        const val PRIMARY_BUDGET_MS = 20_000L
    }
}
