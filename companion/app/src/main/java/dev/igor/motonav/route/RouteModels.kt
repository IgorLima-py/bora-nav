package dev.igor.motonav.route

import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.PointE5
import dev.igor.motonav.proto.Turn

/** A geographic coordinate in degrees, as used by the APIs and by Android. */
data class LatLng(val lat: Double, val lon: Double)

/**
 * Straight-line distance in km (haversine).
 *
 * Serves as a sanity check for the destination coming out of `LinkResolver`: a Maps link that
 * falls into the wrong regex once sent MotoNav asking for a route from São Paulo to Bosnia,
 * and the only clue was an "HTTP 422" from Mapbox.
 */
fun straightLineKm(from: LatLng, to: LatLng): Double {
    val earthKm = 6371.0
    val dLat = Math.toRadians(to.lat - from.lat)
    val dLon = Math.toRadians(to.lon - from.lon)
    val a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
        Math.cos(Math.toRadians(from.lat)) * Math.cos(Math.toRadians(to.lat)) *
        Math.sin(dLon / 2) * Math.sin(dLon / 2)
    return 2 * earthKm * Math.asin(Math.min(1.0, Math.sqrt(a)))
}

/**
 * Normalized route, independent of the provider (docs/04-COMPANION-APP.md §2).
 *
 * Deviation from the doc, on purpose: `points` carries protocol units (1e-5
 * degrees) instead of doubles. Quantization happens once, at decode time, with
 * the same integer rule as tools/packer.py, so packing is bit-for-bit
 * deterministic — see docs/DECISIONS.md.
 */
data class RouteResult(
    val points: List<PointE5>,
    val turns: List<Turn>,
    val distanceM: Int,
    val durationS: Int,
    val destName: String,
    val speedLimitsKmh: List<Int?>? = null, // v2 (Mapbox annotation maxspeed)
    val congestion: List<Int>? = null, // v2 (annotation congestion_numeric)
    /**
     * Index, in [points], where each intermediate stop ends (the end of each leg
     * except the last). It does not go to the watch: the phone uses it to know which
     * stops were left behind in a recalculation (C11). Mirrors `Route.stop_idx`
     * of `tools/packer.py`.
     */
    val stopIdx: List<Int> = emptyList(),
) {
    /** [watchS]: the duration that goes to the watch, the provider's times Igor's pace (C16, `PersonalPace`). */
    fun toPackable(routeId: Int, destNameOverride: String? = null, watchS: Int = durationS) = PackableRoute(
        routeId = routeId,
        points = points,
        turns = turns,
        distanceM = distanceM,
        durationS = watchS,
        destName = destNameOverride ?: destName,
    )
}

/** Swappable routing backend (ADR-5). Mapbox is the v1 implementation. */
interface RouteProvider {
    /** [via]: stops in between, in order; the provider goes through all of them before [to]. */
    suspend fun route(from: LatLng, fromBearing: Float?, to: LatLng, via: List<LatLng> = emptyList()): RouteResult
}

/**
 * [message] is technical and goes to the log in Portuguese; [userText] is what the screen shows, in the
 * device (C16.8b).
 */
class RouteException(
    message: String,
    cause: Throwable? = null,
    @StringRes val userText: Int = R.string.err_route,
) : Exception(message, cause)
