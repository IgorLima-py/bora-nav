package dev.igor.motonav.geo

import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.corridor.OverpassClient
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.route.LatLng
import java.io.IOException
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * **Address and place search through Photon** (C16; `docs/06 §Geocoding`): free, keyless,
 * built for search-as-you-type, over OSM.
 *
 * It took [MapboxGeocoder]'s place as the first search because Mapbox's Product Terms forbid
 * storing the temporary geocode (2.7.2, `DECISIONS.md` §2026-10-17, "the vehicle license"), and the
 * destination chosen in the search is kept in `trips.json` and becomes a Recent. The OSM result is under ODbL and
 * may be stored. [PlaceSearch] combines the two, with Mapbox as a fallback.
 */
class PhotonGeocoder(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .callTimeout(CALL_TIMEOUT_S, java.util.concurrent.TimeUnit.SECONDS)
        .build(),
    private val base: String = BASE,
) {

    /** Up to [LIMIT] places, the closest to [near] first (a bias, not a filter). */
    suspend fun search(query: String, near: LatLng? = null): List<Place> {
        val text = query.trim()
        if (text.length < MIN_QUERY) {
            return emptyList()
        }
        val url = "$base/api/".toHttpUrl().newBuilder()
            .addQueryParameter("q", text)
            .addQueryParameter("lang", "default")
            .addQueryParameter("limit", LIMIT.toString())
            .apply {
                if (near != null) {
                    addQueryParameter("lat", "%.6f".format(Locale.US, near.lat))
                    addQueryParameter("lon", "%.6f".format(Locale.US, near.lon))
                }
            }
            .build()
            .toString()
        val places = parse(get(url))
        // The typed text may be the user's address: only the `sim` variant logs it.
        val what = if (BuildConfig.CIQ_TETHERED) "'${text.take(60)}'" else "(texto omitido)"
        EventLog.i(TAG, "search $what: ${places.size} result(s)")
        return places
    }

    /** The approximate address of a point, or `null`: the confirmation works without it. */
    suspend fun reverse(point: LatLng): String? {
        val url = "$base/reverse".toHttpUrl().newBuilder()
            .addQueryParameter("lat", "%.6f".format(Locale.US, point.lat))
            .addQueryParameter("lon", "%.6f".format(Locale.US, point.lon))
            .addQueryParameter("lang", "default")
            .addQueryParameter("limit", "1")
            .build()
            .toString()
        return try {
            parse(get(url)).firstOrNull()?.address?.ifBlank { null }
        } catch (e: GeocodeException) {
            EventLog.w(TAG, "point address not returned: ${e.message}")
            null
        }
    }

    private suspend fun get(url: String): String = withContext(Dispatchers.IO) {
        try {
            client.newCall(Request.Builder().url(url).header("User-Agent", OverpassClient.USER_AGENT).build()).execute().use { response ->
                if (!response.isSuccessful) {
                    EventLog.w(TAG, "HTTP ${response.code} on search")
                    throw GeocodeException("Search unavailable (HTTP ${response.code})")
                }
                // With a cap ([textCapped]), like the tile: OkHttp opens the gzip by itself, and an endless
                // body became `OutOfMemoryError`, which slips past the `catch`es and takes the app down.
                response.textCapped(MAX_BODY_BYTES) ?: run {
                    EventLog.w(TAG, "Photon response over ${MAX_BODY_BYTES / 1024} KB")
                    throw GeocodeException("Search response too large")
                }
            }
        } catch (e: IOException) {
            EventLog.w(TAG, "no response from Photon: ${e.javaClass.simpleName}: ${e.message}")
            throw GeocodeException("No internet to look up the address", R.string.err_offline)
        }
    }

    companion object {
        private const val TAG = "PhotonGeocoder"
        const val BASE = "https://photon.komoot.io"

        /** The same as the Mapbox search, and the `06 §Geocoding` fair use asks for little per call. */
        private const val LIMIT = 6
        private const val MIN_QUERY = 3
        private const val CALL_TIMEOUT_S = 8L

        /** Six places in GeoJSON are a few KB; 256 KB is slack. A choice, not a measurement. */
        const val MAX_BODY_BYTES = 256 * 1024

        private val json = Json { ignoreUnknownKeys = true }

        /**
         * Photon GeoJSON → places. Pure: it is what the test checks.
         *
         * The name is the place's, or the street with the number when the result is an address; the address
         * joins street, neighborhood, city and state, without repeating what is already in the name.
         */
        fun parse(body: String): List<Place> {
            val response = try {
                json.decodeFromString<Response>(body)
            } catch (e: kotlinx.serialization.SerializationException) {
                throw GeocodeException("Unreadable search response")
            } catch (e: IllegalArgumentException) {
                throw GeocodeException("Unreadable search response")
            }
            // Only [LIMIT]: the screen draws the whole list, and the server may send more than asked.
            return response.features.asSequence().mapNotNull { feature ->
                // `coordinates` is [lon, lat], as in Mapbox.
                val point = feature.geometry?.coordinates?.takeIf { it.size >= 2 } ?: return@mapNotNull null
                val p = feature.properties
                val streetLine = p.street?.let { street -> p.housenumber?.let { "$street, $it" } ?: street }
                val name = p.name?.ifBlank { null } ?: streetLine ?: p.city ?: return@mapNotNull null
                val address = listOfNotNull(streetLine, p.district ?: p.locality, p.city, p.state)
                    .filter { it.isNotBlank() && it != name }
                    .distinct()
                    .joinToString(", ")
                Place(
                    name = name,
                    address = if (address.isBlank()) name else "$name, $address",
                    position = LatLng(point[1], point[0]),
                )
            }.take(LIMIT).toList()
        }
    }

    @Serializable
    private data class Response(val features: List<Feature> = emptyList())

    @Serializable
    private data class Feature(val geometry: Geometry? = null, val properties: Properties = Properties())

    @Serializable
    private data class Geometry(val coordinates: List<Double> = emptyList())

    @Serializable
    private data class Properties(
        val name: String? = null,
        val street: String? = null,
        val housenumber: String? = null,
        val district: String? = null,
        val locality: String? = null,
        val city: String? = null,
        val state: String? = null,
    )
}

/**
 * **The app's search** (C16): [PhotonGeocoder] first and [MapboxGeocoder] as a fallback.
 *
 * Mapbox only comes in when Photon fails (network, HTTP) or finds nothing, and only if there is a token:
 * without a token, the search is Photon alone, and its failure is the search's failure. The fallback result
 * can still become a destination and stay in `trips.json`, which Mapbox's 2.7.2 does not allow; it was left
 * that way by choice, recorded in `DECISIONS.md` §2026-10-17, "stop storing the route".
 */
class PlaceSearch(
    private val primary: suspend (String, LatLng?) -> List<Place>,
    private val reverseOf: suspend (LatLng) -> String?,
    private val reserve: (suspend (String, LatLng?) -> List<Place>)?,
    private val reserveReverse: (suspend (LatLng) -> String?)?,
) {

    /** Throws [GeocodeException] only when neither answered; the message is Photon's. */
    suspend fun search(query: String, near: LatLng? = null): List<Place> {
        var failure: GeocodeException? = null
        val first = try {
            primary(query, near)
        } catch (e: GeocodeException) {
            failure = e
            emptyList()
        }
        if (first.isNotEmpty() || reserve == null || query.trim().length < MIN_QUERY) {
            failure?.let { throw it }
            return first
        }
        EventLog.w(TAG, if (failure != null) "Photon failed (${failure.message}); trying Mapbox" else "Photon returned no result; trying Mapbox")
        val second = try {
            reserve.invoke(query, near)
        } catch (e: GeocodeException) {
            throw failure ?: e
        }
        if (second.isEmpty() && failure != null) throw failure
        return second
    }

    suspend fun reverse(point: LatLng): String? = reverseOf(point) ?: reserveReverse?.invoke(point)

    companion object {
        private const val TAG = "PlaceSearch"
        private const val MIN_QUERY = 3

        /** The app's: Mapbox only as a fallback, and only with a token. */
        fun of(photon: PhotonGeocoder, mapbox: MapboxGeocoder, hasMapboxToken: () -> Boolean) = PlaceSearch(
            primary = photon::search,
            reverseOf = photon::reverse,
            reserve = { query, near -> if (hasMapboxToken()) mapbox.search(query, near) else emptyList() },
            reserveReverse = { point -> if (hasMapboxToken()) mapbox.reverse(point) else null },
        )
    }
}
