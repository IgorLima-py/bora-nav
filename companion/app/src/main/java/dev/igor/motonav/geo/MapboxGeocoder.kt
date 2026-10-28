package dev.igor.motonav.geo

import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.route.LatLng
import java.io.IOException
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request

/** A search result: [name] is what the person looked for, [address] the full address. */
data class Place(val name: String, val address: String, val position: LatLng)

/**
 * [message] is technical and goes to the log in Portuguese; [userText] is what the screen shows, in the
 * device language (C16.8b).
 */
class GeocodeException(message: String, @StringRes val userText: Int = R.string.err_search) : Exception(message)

/** The line the search shows for any error. */
@StringRes
fun userMessage(e: Exception): Int = (e as? GeocodeException)?.userText ?: R.string.err_search

/**
 * Address and place search through Mapbox Geocoding v5 (C8; `docs/04 §1`).
 *
 * Same token as the route — no new key. The search is **temporary** in the sense
 * of Mapbox's terms (show and route; nothing is stored), and every call goes
 * through [onRequest] for the monthly count. The token never goes to the log.
 */
class MapboxGeocoder(
    private val tokenProvider: () -> String,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .callTimeout(CALL_TIMEOUT_S, java.util.concurrent.TimeUnit.SECONDS)
        .build(),
    private val onRequest: () -> Unit = {},
) {

    /** Up to [LIMIT] places, the closest to [near] first (a bias, not a filter). */
    suspend fun search(query: String, near: LatLng? = null): List<Place> {
        val text = query.trim()
        if (text.length < MIN_QUERY) {
            return emptyList()
        }
        val url = urlFor(text) {
            addQueryParameter("autocomplete", "true")
            addQueryParameter("limit", LIMIT.toString())
            addQueryParameter("types", "address,poi,place,locality,neighborhood")
            if (near != null) {
                addQueryParameter("proximity", "%.6f,%.6f".format(Locale.US, near.lon, near.lat))
            }
        }
        val places = parse(get(url))
        // The typed text may be the user's address: only the `sim` variant logs it.
        val what = if (BuildConfig.CIQ_TETHERED) "'${text.take(60)}'" else "(texto omitido)"
        EventLog.i(TAG, "search $what: ${places.size} result(s)")
        return places
    }

    /** The approximate address of a point, or `null` — the confirmation works without it. */
    suspend fun reverse(point: LatLng): String? {
        val url = urlFor("%.6f,%.6f".format(Locale.US, point.lon, point.lat)) {
            addQueryParameter("limit", "1")
            addQueryParameter("types", "address,poi,neighborhood,locality")
        }
        return try {
            parse(get(url)).firstOrNull()?.address
        } catch (e: GeocodeException) {
            EventLog.w(TAG, "point address not returned: ${e.message}")
            null
        }
    }

    private fun urlFor(subject: String, params: okhttp3.HttpUrl.Builder.() -> Unit): String {
        val token = tokenProvider().trim()
        if (token.isEmpty()) {
            throw GeocodeException("Mapbox token not configured", R.string.err_token_missing)
        }
        return BASE.toHttpUrl().newBuilder()
            .addPathSegment("$subject.json")
            .addQueryParameter("language", dev.igor.motonav.route.ApiLanguage.geocode())
            .apply(params)
            .addQueryParameter("access_token", token)
            .build()
            .toString()
    }

    private suspend fun get(url: String): String = withContext(Dispatchers.IO) {
        try {
            client.newCall(Request.Builder().url(url).build()).execute().use { response ->
                // With a cap, like Photon's: OkHttp opens the gzip by itself, and an endless body became
                // `OutOfMemoryError`, which slips past the `catch`es and takes the app down. The call counts the same.
                val body = response.textCapped(MAX_BODY_BYTES)
                onRequest()
                when {
                    response.code == 401 || response.code == 403 ->
                        throw GeocodeException("Mapbox refused the token (HTTP ${response.code})", R.string.err_token_refused)
                    !response.isSuccessful -> {
                        EventLog.w(TAG, "HTTP ${response.code} on search — body: ${body?.take(200) ?: "(over the cap)"}")
                        throw GeocodeException("Search unavailable (HTTP ${response.code})")
                    }
                    body == null -> {
                        EventLog.w(TAG, "Mapbox response over ${MAX_BODY_BYTES / 1024} KB")
                        throw GeocodeException("Search response too large")
                    }
                    else -> body
                }
            }
        } catch (e: IOException) {
            EventLog.w(TAG, "no response from Mapbox on search: ${e.javaClass.simpleName}: ${e.message}")
            throw GeocodeException("No internet to look up the address", R.string.err_offline)
        }
    }

    companion object {
        private const val TAG = "MapboxGeocoder"
        private const val BASE = "https://api.mapbox.com/geocoding/v5/mapbox.places/"
        private const val LIMIT = 6
        private const val MIN_QUERY = 3
        private const val CALL_TIMEOUT_S = 8L

        /**
         * The same cap as [PhotonGeocoder.MAX_BODY_BYTES]: six v5 places are a few KB. A choice,
         * not a measurement: measuring needs the token, and Photon's six places were 2.3 KB (2026-10-17).
         */
        const val MAX_BODY_BYTES = 256 * 1024

        private val json = Json { ignoreUnknownKeys = true }

        /** Geocoding v5 body -> places. Pure: it is what the test checks. */
        fun parse(body: String): List<Place> {
            val response = try {
                json.decodeFromString<Response>(body)
            } catch (e: kotlinx.serialization.SerializationException) {
                throw GeocodeException("Unreadable search response")
            }
            return response.features.mapNotNull { feature ->
                // `center` is [lon, lat]; without it the result is no use for routing.
                val center = feature.center.takeIf { it.size >= 2 } ?: return@mapNotNull null
                val address = feature.placeName.ifBlank { feature.text }
                Place(
                    name = feature.text.ifBlank { address.substringBefore(',') },
                    address = address,
                    position = LatLng(center[1], center[0]),
                )
            }
        }
    }

    @Serializable
    private data class Response(val features: List<Feature> = emptyList())

    @Serializable
    private data class Feature(
        val text: String = "",
        @SerialName("place_name") val placeName: String = "",
        val center: List<Double> = emptyList(),
    )
}
