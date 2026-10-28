package dev.igor.motonav.route

import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.textCapped
import java.io.IOException
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Mapbox Directions `driving-traffic` (docs/04-COMPANION-APP.md §MapboxProvider,
 * docs/06-APIS-DATA.md). The v1 routing backend behind [RouteProvider].
 */
class MapboxProvider(
    private val tokenProvider: () -> String,
    private val client: OkHttpClient = defaultClient(),
    private val onRequest: () -> Unit = {},
    private val avoidMotorways: () -> Boolean = { true },
) : RouteProvider {

    override suspend fun route(from: LatLng, fromBearing: Float?, to: LatLng, via: List<LatLng>): RouteResult {
        val token = tokenProvider().trim()
        if (token.isEmpty()) {
            throw RouteException("Mapbox token not configured", userText = R.string.err_token_missing)
        }

        // Coordinates in the log only in the `sim` variant (public places on the emulator, which
        // `tools/e2e.py` checks). On the real phone the log carries no address: a favorite
        // or destination may be the user's home (C12 second opinion, `DECISIONS.md`).
        val where = if (BuildConfig.CIQ_TETHERED) "${from.lat},${from.lon} -> ${to.lat},${to.lon}" else "(coordinates omitted)"
        EventLog.i(
            TAG,
            "route $where" + (if (via.isEmpty()) "" else " via ${via.size} stop(s)"),
        )
        val url = directionsUrl(from, fromBearing, to, via, token, avoidMotorways())
        val body = withContext(Dispatchers.IO) { getWithRetry(url) }
        onRequest()
        return MapboxRouteParser.parse(body)
    }

    /** Three attempts with exponential backoff (02 §Failure modes). */
    private suspend fun getWithRetry(url: String): String {
        var lastError: Exception? = null
        repeat(MAX_ATTEMPTS) { attempt ->
            try {
                client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                    // With a cap ([MAX_BODY_BYTES]): OkHttp opens the gzip on its own, and an endless route
                    // became `OutOfMemoryError`, which no `catch` here handles, and the app crashed.
                    val capped = response.textCapped(MAX_BODY_BYTES)
                    if (response.isSuccessful) {
                        // Without the other attempts: the same route comes back the same size.
                        return capped ?: throw RouteException(
                            "Mapbox sent a route that is too large (over ${MAX_BODY_BYTES / (1024 * 1024)} MB)",
                        )
                    }
                    // An error above the cap follows the HTTP code path, just without the body.
                    val body = capped.orEmpty()
                    EventLog.w(
                        TAG,
                        "HTTP ${response.code} for ${mapboxLogText(url, BuildConfig.CIQ_TETHERED)} - body: " +
                            mapboxLogText(body.take(400), BuildConfig.CIQ_TETHERED),
                    )
                    // 401/403 are token problems: retrying will not help.
                    if (response.code == 401 || response.code == 403) {
                        throw RouteException("Mapbox refused the token (HTTP ${response.code})", userText = R.string.err_token_refused)
                    }
                    // 422 = InvalidInput: Mapbox rejected a coordinate or
                    // parameter. Insisting 3x changes nothing, and the explanation is in
                    // the body — throwing it away was what made this error become an
                    // "HTTP 422" with no clue on screen.
                    if (response.code == 422) {
                        // The message goes to the screen and, from whoever catches it, to the log.
                        throw RouteException(
                            "Mapbox rejected the route: " +
                                mapboxLogText(mapboxMessage(body), BuildConfig.CIQ_TETHERED),
                        )
                    }
                    lastError = IOException("HTTP ${response.code}")
                }
            } catch (e: RouteException) {
                throw e
            } catch (e: IOException) {
                // Without network there is no HTTP to log above: without this line the log
                // cannot tell "Mapbox down" from "watch silent".
                EventLog.w(
                    TAG,
                    "no response from Mapbox (attempt ${attempt + 1}/$MAX_ATTEMPTS): " +
                        "${e.javaClass.simpleName}: ${e.message}",
                )
                lastError = e
            }
            if (attempt < MAX_ATTEMPTS - 1) {
                delay(BACKOFF_MS shl attempt)
            }
        }
        throw RouteException("Could not calculate the route: ${lastError?.message}", lastError)
    }

    companion object {
        private const val TAG = "MapboxProvider"
        private const val MAX_ATTEMPTS = 3
        private const val BACKOFF_MS = 800L

        /**
         * Cap of the Directions response, unzipped. **A choice based on measurement:** the measured
         * Directions responses were 5.7 to 7.5 KB per km (one of 13.3 km, with `annotations`, gave
         * 97 KB). Today's fixtures come from OSRM, with no banner or `annotations`, and are smaller. Sharing refuses a destination more than 500 km in a
         * straight line (`ShareReceiverActivity`); 8 MB fits ~1,000 km at city pace, and
         * the highway, with fewer maneuvers and points per km, goes further.
         */
        const val MAX_BODY_BYTES = 8 * 1024 * 1024

        private fun defaultClient() = OkHttpClient.Builder().build()

        /**
         * The Directions URL: origin, the [via] in order, destination. `bearings` carries
         * **one entry per coordinate** (Mapbox docs), and only the origin has a heading:
         * the others stay empty, hence the repeated `;`. Up to 25 coordinates in
         * `driving-traffic` (Mapbox docs limit, checked in C11).
         *
         * `exclude=motorway` is for the motorcycle (C16, 2026-10-21): Mapbox has no motorcycle profile, and in
         * OSM the Marginal Pinheiros express lane, forbidden to motorcycles, is `motorway` (the local one is
         * `trunk`). The exclusion is best-effort: with no path that avoids it, the route uses it anyway.
         */
        fun directionsUrl(
            from: LatLng,
            fromBearing: Float?,
            to: LatLng,
            via: List<LatLng>,
            token: String,
            avoidMotorways: Boolean = true,
        ): String {
            val points = listOf(from) + via + to
            val coordinates = points.joinToString(";") { "%.6f,%.6f".format(Locale.US, it.lon, it.lat) }
            val parameters = buildString {
                append("geometries=polyline6&overview=full&steps=true&banner_instructions=true")
                append("&annotations=maxspeed,congestion_numeric&language=${ApiLanguage.route()}")
                // Only send bearings when the heading is trustworthy, otherwise the
                // route may start with a U-turn (04 §MapboxProvider).
                if (fromBearing != null) {
                    append("&bearings=${fromBearing.toInt()},45")
                    append(";".repeat(points.size - 1))
                }
                if (avoidMotorways) {
                    append("&exclude=motorway")
                }
                append("&access_token=$token")
            }
            return "https://api.mapbox.com/directions/v5/mapbox/driving-traffic/$coordinates?$parameters"
        }

        /** `{"code":"InvalidInput","message":"..."}` → the message, or the raw body. */
        private fun mapboxMessage(body: String): String {
            val message = MESSAGE_FIELD.find(body)?.groupValues?.get(1)
            return message ?: body.take(200).ifBlank { "no detail" }
        }

        private val MESSAGE_FIELD = Regex(""""message"\s*:\s*"([^"]*)"""")
    }
}

private val TOKEN_PARAM = Regex("""access_token=[^&]*""")

/** A number that looks like a latitude or longitude: up to 3 digits and 3 or more decimal places. */
private val COORDINATE = Regex("""-?\d{1,3}\.\d{3,}""")

/**
 * What from Mapbox may go to `motonav.log`: the requested URL and an error's body.
 *
 * The token never goes (08 §Conventions). The coordinate only goes in the `sim` variant
 * ([keepCoordinates]): the URL carries the start, the stops and the destination in the path, and the
 * body of an error repeats the one that was refused. On the real phone that is the user's home, in a log
 * that leaves the phone for diagnostics (finding from the C13a second opinion). Each
 * number becomes `#`, so the URL still shows how many points the route had.
 */
internal fun mapboxLogText(text: String, keepCoordinates: Boolean): String {
    val withoutToken = text.replace(TOKEN_PARAM, "access_token=***")
    return if (keepCoordinates) withoutToken else withoutToken.replace(COORDINATE, "#")
}
