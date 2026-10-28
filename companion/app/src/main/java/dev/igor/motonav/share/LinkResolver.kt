package dev.igor.motonav.share

import androidx.annotation.StringRes
import dev.igor.motonav.R
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.geo.PhotonGeocoder
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.route.LatLng
import java.io.IOException
import java.net.URLDecoder
import java.net.URLEncoder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * [via] are the stops in the middle of a `dir/A/B/C` link, in order (C11): without them the
 * route went straight to the last point and the recalculation lost them for good. Empty for anything
 * that is not a route link with stops.
 */
data class Destination(val position: LatLng, val label: String, val via: List<LatLng> = emptyList())

/**
 * Turns whatever Google Maps or Waze shared into coordinates
 * (docs/04-COMPANION-APP.md §ShareReceiverActivity).
 *
 * Order matters: the place pin beats the query, which beats the map centre.
 *
 * [mapboxGeocode] is the second geocoder (C8): Photon is free and keyless,
 * but public and sometimes down; with no coordinate in the link and without Photon, the
 * Mapbox search, which the app already has a token to use, still finds the place.
 */
class LinkResolver(
    private val client: OkHttpClient = OkHttpClient.Builder().followRedirects(false).build(),
    private val mapboxGeocode: (suspend (query: String, near: LatLng?) -> LatLng?)? = null,
) {

    private val json = Json { ignoreUnknownKeys = true }

    /** [near] is the position of whoever shared: breaks ties between namesakes in the geocoder. */
    suspend fun resolve(sharedText: String, near: LatLng? = null): Destination {
        val text = sharedText.trim()
        val url = URL_PATTERN.find(text)?.value
            // `geo:` from Waze and third-party apps: it is not http, but it is a link.
            ?: GEO_SCHEME.find(text)?.value
        // `freeText` is null when the share is just the URL, with no name at all.
        val freeText = text.replace(url.orEmpty(), "").trim().ifBlank { null }
        EventLog.i(TAG, "shared: ${sharedText.take(200)}")

        if (url == null) {
            return geocode(freeText, near)
        }

        // Waze's short link (`ul/h<geohash>`) already carries the coordinate:
        // decoding does not cost a network trip, and Waze's redirect is done in JS.
        geohashFrom(url)?.let { return Destination(it, freeText ?: DEFAULT_LABEL) }

        if (url.startsWith("geo:")) {
            val label = freeText ?: textQueryFrom(url) ?: DEFAULT_LABEL
            coordinatesFrom(url)?.let { return Destination(it, label) }
            return geocode(freeText ?: textQueryFrom(url), near)
        }

        val page = withContext(Dispatchers.IO) { expand(url) }
        EventLog.i(TAG, "expanded: ${page.url.take(400)}")
        val label = freeText ?: textQueryFrom(page.url) ?: DEFAULT_LABEL
        stopsFrom(page.url)?.let { stops ->
            EventLog.i(TAG, "route link: ${stops.size - 1} stop(s) + destination")
            return Destination(stops.last(), label, via = stops.dropLast(1))
        }
        coordinatesFrom(page.url)?.let { return Destination(it, label) }
        // When the short link does not redirect, the coordinates are usually
        // in the page's HTML. Only specific patterns here: `@lat,lon` would match
        // any loose number in the middle of the HTML.
        page.body?.let { body ->
            coordinatesFrom(body, allowViewport = false)?.let {
                EventLog.i(TAG, "coordinate came from the page body")
                return Destination(it, label)
            }
        }
        EventLog.w(TAG, "no coordinate pattern matched the URL or the body")
        return geocode(freeText ?: textQueryFrom(page.url), near)
    }

    /**
     * Geocoding only with a real name. Geocoding the default label
     * ("Destino") returned a random place on the planet — it is what sent
     * a route from São Paulo to Bosnia and, later, 9,991 km from here.
     */
    private suspend fun geocode(query: String?, near: LatLng?): Destination {
        if (query == null) {
            throw ShareException(
                "Could not find the coordinates in this link",
                R.string.share_no_coords,
            )
        }
        val photon = withContext(Dispatchers.IO) { photon(query, near) }
        if (photon != null) {
            return Destination(photon, query)
        }
        EventLog.w(TAG, "Photon did not find ${EventLog.place("'${query.take(60)}'")}")
        val mapbox = mapboxGeocode?.let {
            try {
                it(query, near)
            } catch (e: Exception) {
                EventLog.w(TAG, "Mapbox did not find ${EventLog.place("'${query.take(60)}'")}: ${e.message}")
                null
            }
        }
        if (mapbox != null) {
            EventLog.i(TAG, "coordinate from the Mapbox geocoder: ${EventLog.place("${mapbox.lat},${mapbox.lon}")}")
            return Destination(mapbox, query)
        }
        throw ShareException("Could not find the coordinates of \"$query\"", R.string.share_not_found, listOf(query))
    }

    /** Final URL and, when the redirect did not come, the response body. */
    private data class Page(val url: String, val body: String?)

    /** Follows the Location header by hand, at most [MAX_HOPS] times. */
    private fun expand(url: String): Page {
        var current = url
        repeat(MAX_HOPS) {
            val response = try {
                client.newCall(Request.Builder().url(current).header("User-Agent", USER_AGENT).build()).execute()
            } catch (e: IOException) {
                EventLog.w(TAG, "failed to expand: ${e.message}")
                return Page(current, null)
            }
            response.use {
                val location = it.header("Location")
                if (location == null) {
                    // The status goes to the log: a Google 429 explains a link
                    // that expanded on the first attempt and not on the second.
                    // With a cap ([MAX_PAGE_BYTES]): OkHttp opens the gzip on its own, and
                    // an endless page became `OutOfMemoryError`, which took the app down.
                    // Went past the cap, it is treated like a body that did not come.
                    val body = try {
                        it.textCapped(MAX_PAGE_BYTES).also { text ->
                            if (text == null) EventLog.w(TAG, "page exceeds ${MAX_PAGE_BYTES / 1024} KB: body ignored")
                        }
                    } catch (e: IOException) {
                        null
                    }
                    EventLog.i(TAG, "HTTP ${it.code} without Location, body ${body?.length ?: 0} B")
                    return Page(current, body)
                }
                current = if (location.startsWith("http")) {
                    location
                } else {
                    it.request.url.resolve(location)?.toString() ?: return Page(current, null)
                }
            }
        }
        return Page(current, null)
    }

    fun coordinatesFrom(url: String, allowViewport: Boolean = true): LatLng? {
        val decoded = url.replace("%2C", ",").replace("%2c", ",")
        // The **last** `!3d!4d` pair, not the first: in a route link (`dir/`)
        // each waypoint has its own, in trip order, and the destination is the last.
        // Taking the first, the app asked for a route from the origin to the origin itself
        // ("destino a 0 km em linha reta", i.e. destination 0 km away in a straight line).
        PLACE_PIN.findAll(decoded).lastOrNull()?.let {
            return matched("place-pin", it.groupValues[1], it.groupValues[2])
        }
        QUERY_COORDS.find(decoded)?.let {
            return matched("query", it.groupValues[2], it.groupValues[3])
        }
        WAZE_COORDS.find(decoded)?.let {
            return matched("waze", it.groupValues[2], it.groupValues[3])
        }
        GEO_URI.find(decoded)?.let {
            return matched("geo-uri", it.groupValues[1], it.groupValues[2])
        }
        // Viewport centre is the last resort: it is where the camera was, not
        // necessarily the place itself.
        if (allowViewport) {
            VIEWPORT.find(decoded)?.let {
                return matched("viewport", it.groupValues[1], it.groupValues[2])
            }
        }
        return null
    }

    /**
     * The points of a Maps `dir/` link **after the origin**, in order: the
     * stops and, last, the destination. `null` if the link is not a route with
     * readable points — the caller falls back to the old behavior (the last
     * `!3d!4d`).
     *
     * The origin (the first point) is ignored on purpose: the route starts from the GPS, not
     * from where the link says (Igor's decision, C11). Each point is a `!1m…` block
     * of `data=!4m…!4m…`; the coordinate comes from `!8m2!3d<lat>!4d<lon>` (app format),
     * from `!2m2!1d<lon>!2d<lat>` (web format) or, with neither, from the
     * raw `lat,lon` of the path segment. Segments are split on `/`
     * **before** decoding: `%2F` shows up in place names.
     */
    fun stopsFrom(url: String): List<LatLng>? {
        if (!url.contains("/dir/")) {
            return null
        }
        val data = url.substringAfter("data=", "").substringBefore('?')
        if (data.isEmpty()) {
            return null
        }
        val nodes = parseProtobufTokens(data.split('!').filter { it.isNotEmpty() })
        val blocks = findWaypointBlocks(nodes) ?: return null
        if (blocks.size < 2) {
            return null
        }
        val segments = pathSegments(url)
        val points = blocks.mapIndexed { i, block ->
            pinOf(block) ?: segments.getOrNull(i)?.let { rawCoordinates(it) }
        }
        val stops = points.drop(1)
        if (stops.any { it == null }) {
            EventLog.w(TAG, "route link with a point without coordinate: using only the destination")
            return null
        }
        return stops.filterNotNull()
    }

    /** A token `!<index><type><value>` of `data=`; type `m` groups the following `value`s. */
    private class PbNode(val index: Int, val type: Char, val value: String, val children: List<PbNode>)

    /**
     * The `data=` tree. The number of an `m` counts **all** descendant tokens
     * (`!4m16` = the next 16, nested included), so the slice is cut straight.
     */
    private fun parseProtobufTokens(tokens: List<String>): List<PbNode> {
        val out = mutableListOf<PbNode>()
        var i = 0
        while (i < tokens.size) {
            val match = PB_TOKEN.matchEntire(tokens[i])
            if (match == null) {
                i++
                continue
            }
            val index = match.groupValues[1].toIntOrNull() ?: 0
            val type = match.groupValues[2][0]
            val value = match.groupValues[3]
            if (type == 'm') {
                val count = value.toIntOrNull()?.coerceIn(0, tokens.size - i - 1) ?: 0
                out += PbNode(index, type, value, parseProtobufTokens(tokens.subList(i + 1, i + 1 + count)))
                i += 1 + count
            } else {
                out += PbNode(index, type, value, emptyList())
                i++
            }
        }
        return out
    }

    /** The first node that has `!1m…` blocks as children: they are the trip's points. */
    private fun findWaypointBlocks(nodes: List<PbNode>): List<PbNode>? {
        val own = nodes.filter { it.index == 1 && it.type == 'm' }
        if (own.isNotEmpty()) {
            return own
        }
        nodes.forEach { node -> findWaypointBlocks(node.children)?.let { return it } }
        return null
    }

    /** `!3d<lat>!4d<lon>` or `!2m2!1d<lon>!2d<lat>` anywhere in the block. */
    private fun pinOf(block: PbNode): LatLng? {
        fun find(nodes: List<PbNode>, index: Int, type: Char): Double? {
            nodes.forEach { node ->
                if (node.index == index && node.type == type) {
                    node.value.toDoubleOrNull()?.let { return it }
                }
                find(node.children, index, type)?.let { return it }
            }
            return null
        }
        val lat = find(block.children, 3, 'd')
        val lon = find(block.children, 4, 'd')
        if (lat != null && lon != null) {
            return LatLng(lat, lon)
        }
        val webLon = find(block.children, 1, 'd')
        val webLat = find(block.children, 2, 'd')
        if (webLat != null && webLon != null) {
            return LatLng(webLat, webLon)
        }
        return null
    }

    /** The path segments after `/dir/`, still **not** decoded. */
    private fun pathSegments(url: String): List<String> =
        url.substringAfter("/dir/")
            .substringBefore('?')
            .split('/')
            .takeWhile { !it.startsWith("data=") && !it.startsWith("@") }

    private fun rawCoordinates(segment: String): LatLng? {
        val decoded = try {
            URLDecoder.decode(segment, "UTF-8")
        } catch (e: IllegalArgumentException) {
            segment
        }
        val match = RAW_COORDS.matchEntire(decoded.trim()) ?: return null
        return LatLng(match.groupValues[1].toDouble(), match.groupValues[2].toDouble())
    }

    /**
     * The search text the link itself carries — `waze.com/ul?q=Aeroporto…`,
     * `geo:0,0?q=Rua+X`, `maps/search/?api=1&query=Posto+Shell` —, when
     * `q`/`query` is not a coordinate pair. `null` if there is none.
     */
    fun textQueryFrom(url: String): String? {
        val raw = TEXT_PARAM.find(url)?.groupValues?.get(2) ?: return null
        val decoded = try {
            URLDecoder.decode(raw, "UTF-8")
        } catch (e: IllegalArgumentException) {
            raw
        }.trim()
        if (decoded.isEmpty()) {
            return null
        }
        // `geo:` accepts a label in parentheses after the coordinates.
        COORDS_WITH_LABEL.matchEntire(decoded)?.let { return it.groupValues[1].trim().ifBlank { null } }
        if (COORDS_ONLY.matches(decoded)) {
            return null
        }
        return decoded
    }

    /** `waze.com/ul/h<geohash>` -> the coordinate, no network. */
    fun geohashFrom(url: String): LatLng? {
        val hash = WAZE_GEOHASH.find(url)?.groupValues?.get(1) ?: return null
        val point = Geohash.decode(hash) ?: return null
        return matched("waze-geohash", point.lat.toString(), point.lon.toString())
    }

    /** Which of the patterns won — it is the clue when the destination comes out wrong. */
    private fun matched(pattern: String, lat: String, lon: String): LatLng {
        val point = LatLng(lat.toDouble(), lon.toDouble())
        EventLog.i(TAG, "coordinate by '$pattern': ${EventLog.place("${point.lat},${point.lon}")}")
        return point
    }

    /**
     * Photon: free, no key, good with pt-BR place names (06 §Geocoding). With
     * [near], asks Photon to prefer what is near whoever shared.
     */
    private fun photon(query: String, near: LatLng?): LatLng? {
        val bias = if (near != null) "&lat=${near.lat}&lon=${near.lon}" else ""
        val url = "https://photon.komoot.io/api/?q=${URLEncoder.encode(query, "UTF-8")}&lang=default&limit=1$bias"
        val body = try {
            client.newCall(Request.Builder().url(url).header("User-Agent", USER_AGENT).build())
                .execute()
                .use {
                    if (!it.isSuccessful) return null
                    // With the [PhotonGeocoder] cap: going past it is like not finding, and Mapbox tries.
                    it.textCapped(PhotonGeocoder.MAX_BODY_BYTES) ?: run {
                        EventLog.w(TAG, "Photon response exceeds ${PhotonGeocoder.MAX_BODY_BYTES / 1024} KB")
                        return null
                    }
                }
        } catch (e: IOException) {
            return null
        }
        val point = json.decodeFromString<PhotonResponse>(body).features.firstOrNull()?.geometry?.coordinates
        return if (point != null && point.size >= 2) LatLng(point[1], point[0]) else null
    }

    @Serializable
    private data class PhotonResponse(val features: List<PhotonFeature> = emptyList())

    @Serializable
    private data class PhotonFeature(val geometry: PhotonGeometry? = null)

    @Serializable
    private data class PhotonGeometry(val coordinates: List<Double> = emptyList())

    private companion object {
        const val TAG = "LinkResolver"
        const val MAX_HOPS = 5
        const val USER_AGENT = "BoraNav/1.0"

        /** Label when the share is just the link. Never geocode. */
        const val DEFAULT_LABEL = "Destino"

        val PB_TOKEN = Regex("""(\d+)([a-z])(.*)""", RegexOption.DOT_MATCHES_ALL)
        val RAW_COORDS = Regex("""(-?\d+\.\d+)\s*,\s*(-?\d+\.\d+)""")

        val URL_PATTERN = Regex("""https?://\S+""")
        val GEO_SCHEME = Regex("""geo:\S+""")

        /** Google Maps place pin: the real coordinates of the place. */
        val PLACE_PIN = Regex("""!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)""")
        val QUERY_COORDS = Regex("""[?&](q|query|destination|daddr)=(-?\d+\.\d+),\s*(-?\d+\.\d+)""")
        val WAZE_COORDS = Regex("""[?&](ll|latlng|to=ll\.)=?(-?\d+\.\d+),\s*(-?\d+\.\d+)""")
        val GEO_URI = Regex("""geo:(-?\d+\.\d+),(-?\d+\.\d+)""")
        val VIEWPORT = Regex("""@(-?\d+\.\d+),(-?\d+\.\d+)""")

        /** `q=`/`query=`/`address=` with text (the coordinate belongs to QUERY_COORDS). */
        val TEXT_PARAM = Regex("""[?&](q|query|address)=([^&#]+)""")
        val COORDS_ONLY = Regex("""-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?""")
        val COORDS_WITH_LABEL = Regex("""-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\((.*)\)""")

        /** `https://waze.com/ul/h6gycd6cv5` — the `h` is Waze's, the rest is the geohash. */
        val WAZE_GEOHASH = Regex("""waze\.com/ul/h([0-9b-hjkmnp-z]{4,12})(?:[/?#]|$)""", RegexOption.IGNORE_CASE)
    }
}

/**
 * [message] is technical and goes to the log in Portuguese; [userText] and [userArgs] are what the screen shows,
 * in the device's language (C16.8b).
 */
class ShareException(
    message: String,
    @StringRes val userText: Int = R.string.share_unrecognized,
    val userArgs: List<Any> = emptyList(),
) : Exception(message)

/**
 * Cap of the page that comes back without a redirect, in [LinkResolver]. Outside the `companion`, which is private, so
 * the test can see it. Google Maps' was ~220 KB on 2026-10-17 (measurement: three public place links
 * and search links, with the User-Agent used here), Waze's 9 KB; 2 MB is slack (a choice).
 */
internal const val MAX_PAGE_BYTES = 2 * 1024 * 1024
