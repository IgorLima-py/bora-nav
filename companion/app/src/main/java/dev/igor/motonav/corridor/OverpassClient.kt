package dev.igor.motonav.corridor

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.net.textCapped
import dev.igor.motonav.proto.PointE5
import java.io.IOException
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.Call
import okhttp3.Callback
import okhttp3.FormBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** An OSM way, already in protocol units. */
data class OsmWay(val highway: String, val points: List<PointE5>)

class OverpassException(message: String, cause: Throwable? = null) : RoadSourceException(message, cause)

/**
 * Overpass client (`04 §3.2`, `06-APIS-DATA.md`).
 *
 * One query per route, filtered by the corridor polygon. Overpass's `poly:`
 * accepts at most a handful of vertices before the query gets expensive, hence the
 * cap of [MAX_POLY_VERTICES] — the polygon is a deliberately coarse approximation:
 * it exists only so the server does not return the whole city, and the
 * fine clip is done here by [RouteProximity], which is exact.
 *
 * The query goes as a **POST**: a long route generates a polygon of hundreds of
 * characters and some Overpass mirrors refuse a long GET.
 *
 * **The deadlines here are not a detail — they have hidden the corridor twice.**
 * A deadline that is too short is indistinguishable from "Overpass is down":
 * `null` corridor, map without the gray streets, no error on screen. The query for
 * a 19 km route, measured by hand on a quiet server, costs **12.7 s** — and
 * has already been cut by a 10 s client and then by a 15 s budget. Hence
 * the wide ladder of deadlines: nobody is waiting for it.
 */
open class OverpassClient(
    private val endpoints: List<String> = DEFAULT_ENDPOINTS,
    private val client: OkHttpClient = defaultClient(),
    /** [HEDGE_AFTER_MS]; a parameter only so the hedge test can run in milliseconds. */
    private val hedgeAfterMs: Long = HEDGE_AFTER_MS,
) : RoadSource {

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Queries the mirrors with a **hedged request**: starts with the primary and, if
     * it does not answer within [HEDGE_AFTER_MS], fires the backup **in parallel** and
     * keeps the first one to answer.
     *
     * The reason is measured, not theoretical. In the 5th test the primary returned HTTP 504
     * in 9.7 s and the backup took another 23 s: **33 s in series**, with Igor standing
     * waiting for the route that only comes out after this. In parallel the same pair would cost
     * ~14 s. And public Overpass is shared — one mirror being busy says
     * nothing about the other, so asking both is the right answer.
     *
     * The [HEDGE_AFTER_MS] delay before firing the second exists out of
     * politeness: most of the time the primary answers first and the backup is never
     * bothered.
     *
     * **C16.5: the first to answer really wins.** Until then the loop waited for the mirrors
     * **in order** (`await` on the primary before the backup), and OkHttp's blocking `execute()`
     * could not be cancelled: the backup answered and the corridor kept waiting for the primary. In the
     * C16 logs (Oct 15 and 16), 8 of 13 queries waited 5.8 to 27.9 s longer than the first
     * response with ways, 21 s on average. Now whoever arrives first with ways ends the wait, and
     * the other's call is cancelled in OkHttp ([request], `Call.cancel`). And the primary failing
     * early (502 and 504 in 1 to 7 s, in the same logs) calls the backup **right away**, without waiting for the rest
     * of [HEDGE_AFTER_MS].
     */
    override suspend fun fetch(polygon: List<PointE5>): List<OsmWay> =
        // **An empty response is a failure, not a win.** A car route always has streets around it;
        // zero ways means that server does not have this region's data — which is exactly
        // what `overpass.osm.ch` did, returning 200 in 0.7 s and no ways, because it only
        // loads Switzerland. Since the hedge winner was the first to **respond**, it cancelled
        // the mirrors that would have worked.
        hedged(buildQuery(polygon), { body -> parse(body).takeIf { it.isNotEmpty() } }) { "${it.size} ways" }

    /**
     * The [fetch] hedge for any query (C16.6: `RadarClient` asks the same mirrors
     * for the speed cameras, the same way). [parse] returns `null` for a response that is no use,
     * and then that mirror counts as failed; [describe] says what came back, for the log.
     */
    suspend fun <T : Any> hedged(query: String, parse: (String) -> T?, describe: (T) -> String): T {
        if (endpoints.isEmpty()) {
            throw OverpassException("no Overpass mirror configured")
        }

        return coroutineScope {
            val winner = CompletableDeferred<T?>()
            val failed = List(endpoints.size) { CompletableDeferred<Unit>() }
            val pending = AtomicInteger(endpoints.size)
            val jobs = endpoints.mapIndexed { index, endpoint ->
                launch {
                    if (index > 0) {
                        // Waits for the hedge **or** the previous one's failure, whichever comes first.
                        withTimeoutOrNull(hedgeAfterMs * index) { failed[index - 1].await() }
                    }
                    val result = attempt(endpoint, query, parse, describe)
                    if (result != null) {
                        winner.complete(result)
                    } else {
                        failed[index].complete(Unit)
                        if (pending.decrementAndGet() == 0) {
                            winner.complete(null)
                        }
                    }
                }
            }
            val result = winner.await()
            jobs.forEach { it.cancel() }
            result ?: throw OverpassException("all ${endpoints.size} Overpass mirrors failed")
        }
    }

    /** One mirror: what it returned, or `null` if it failed or the response is no use. */
    private suspend fun <T : Any> attempt(
        endpoint: String,
        query: String,
        parse: (String) -> T?,
        describe: (T) -> String,
    ): T? {
        return try {
            val startedAt = System.currentTimeMillis()
            val result = parse(request(endpoint, query))
            val elapsed = System.currentTimeMillis() - startedAt
            if (result == null) {
                EventLog.w(TAG, "mirror $endpoint answered with no data in $elapsed ms — no data for this region?")
            } else {
                EventLog.i(TAG, "$endpoint returned ${describe(result)} in $elapsed ms")
            }
            result
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            EventLog.w(TAG, "mirror $endpoint failed: ${e.message}")
            null
        }
    }

    /**
     * A mirror's HTTP call, **cancellable**: `enqueue` instead of `execute()`, and the
     * coroutine's cancellation becomes `Call.cancel()`, which closes the socket. With `execute()` inside
     * `withContext(IO)` the hedge loser held the `coroutineScope` until it answered.
     * `open` so the hedge test can swap the network for a delay.
     */
    open suspend fun request(endpoint: String, query: String): String =
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(buildRequest(endpoint, query))
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    cont.resumeWithException(OverpassException("Overpass unreachable: ${e.message}", e))
                }

                override fun onResponse(call: Call, response: Response) {
                    // A continuation already cancelled ignores the resume: the loser vanishes quietly.
                    cont.resumeWith(runCatching { response.use { readBody(it) } })
                }
            })
        }

    fun buildQuery(polygon: List<PointE5>): String {
        val poly = poly(polygon)
        return """
            [out:json][timeout:$TIMEOUT_S];
            way[highway~"^($HIGHWAY_FILTER)${'$'}"](poly:"$poly");
            out geom;
        """.trimIndent()
    }

    fun parse(body: String): List<OsmWay> {
        val response = try {
            json.decodeFromString<OverpassResponse>(body)
        } catch (e: Exception) {
            throw OverpassException("unreadable Overpass response: ${body.take(200)}", e)
        }
        return response.elements.mapNotNull { element ->
            val highway = element.tags?.highway ?: return@mapNotNull null
            val geometry = element.geometry ?: return@mapNotNull null
            if (geometry.size < 2) {
                return@mapNotNull null
            }
            OsmWay(
                highway = highway,
                points = geometry.map { PointE5(quantize(it.lat), quantize(it.lon)) },
            )
        }
    }

    /**
     * The request, built separately so a test can inspect it.
     *
     * **The `User-Agent` is the header that made the corridor not exist.** Without it the
     * call dies with **HTTP 406** and an Apache HTML page — it is not Overpass
     * refusing the query, it is the server refusing the library. Measured on
     * 2026-07-31, same query in the same minute: `okhttp/4.12.0` → **406**,
     * descriptive User-Agent → **200**. The public Overpass operators ask for
     * an identifiable agent and block library defaults.
     */
    fun buildRequest(endpoint: String, query: String): Request =
        Request.Builder()
            .url(endpoint)
            .header("User-Agent", USER_AGENT)
            .post(FormBody.Builder().add("data", query).build())
            .build()

    private fun readBody(response: Response): String {
        // With a cap ([MAX_BODY_BYTES]): OkHttp opens the gzip by itself, and an endless body became
        // `OutOfMemoryError`, which passes through [attempt]'s `catch` and takes the app down.
        val body = try {
            response.textCapped(MAX_BODY_BYTES)
        } catch (e: IOException) {
            throw OverpassException("Overpass unreachable: ${e.message}", e)
        }
        if (!response.isSuccessful) {
            // 429 and 504 are public Overpass saying "I am full".
            // It is not a MotoNav error and insisting right away is pointless.
            EventLog.w(TAG, "Overpass HTTP ${response.code}: ${body?.take(200) ?: "(body over the cap)"}")
            throw OverpassException("Overpass answered HTTP ${response.code}")
        }
        // Past the cap, the mirror failed, as with a 504: the other mirror may still answer.
        return body ?: throw OverpassException("Overpass response over ${MAX_BODY_BYTES / (1024 * 1024)} MB")
    }

    companion object {
        private const val TAG = "Overpass"

        const val DEFAULT_ENDPOINT = "https://overpass-api.de/api/interpreter"

        /** Backup mirror: same API, a server independent of the primary. */
        const val MIRROR_ENDPOINT = "https://overpass.kumi.systems/api/interpreter"

        /** Second mirror with the **whole planet**, measured in São Paulo. */
        const val PLANET_MIRROR = "https://maps.mail.ru/osm/tools/overpass/api/interpreter"

        /**
         * Mirrors in order of preference.
         *
         * **To get in here, a mirror must return São Paulo data** — answering
         * fast is not enough. Measurement of 2026-08-01, same query on a block
         * of the neighborhood, with `tools/check_overpass.py`:
         *
         * | mirror | result |
         * |---------|-----------|
         * | `overpass-api.de` | ✅ 200, **75 ways**, 2.5 s |
         * | `maps.mail.ru/osm/tools/overpass` | ✅ 200, **75 ways**, 6.6 s |
         * | `overpass.osm.ch` | ⚠️ 200, **0 ways**, 0.7 s — **only loads Switzerland** |
         * | `overpass.kumi.systems` | ❌ timeout |
         * | `overpass.private.coffee` | ❌ timeout |
         * | `overpass.osm.jp` | ❌ connection refused |
         *
         * `overpass.osm.ch` was first for a whole round
         * because the earlier measurement looked at **latency and HTTP code, not the
         * response**. It won the hedge in 0.7 s with an empty list and
         * cancelled `overpass-api.de`, which worked — the corridor vanished with
         * no error anywhere. Two defenses came out of it: this list only
         * has whole-planet mirrors, and [fetch] treats an **empty response
         * as a failure**.
         *
         * **If the corridor starts failing again, run `python tools/check_overpass.py`
         * before touching the code.** Public server health changes on its own, and the
         * script measures the right thing: how many ways came back.
         */
        val DEFAULT_ENDPOINTS = listOf(DEFAULT_ENDPOINT, PLANET_MIRROR)

        /**
         * Identifiable agent, required by public Overpass. See the comment
         * in [buildRequest]: OkHttp's default gets a 406. The contact is the repository's
         * address, never an e-mail: the code is open, and every install sends this.
         */
        const val USER_AGENT = "BoraNav/1.0 (+https://github.com/IgorLima-py/bora-nav)"

        /**
         * Timeout the query asks of the **server**, and the bottom rung of the
         * deadline ladder: `server 18 s < read 20 s < call 22 s`.
         *
         * The order matters and is the reverse of intuition. Asking the server for more
         * than one is willing to wait means abandoning queries it
         * would still finish — waste on both sides. Saying exactly how much
         * we accept waiting makes the server give up first and return a clean
         * error, instead of the connection dying in the dark.
         *
         * The numbers went from 18/20/22 s to 60/75/85 s when the route stopped
         * waiting for the corridor: measured by hand, the query for a 19 km route
         * costs **12.7 s** on a quiet server. The earlier 18 s was tight
         * even in the best case.
         */
        const val TIMEOUT_S = 60

        /**
         * Timeout the **client** waits for the response. It must be larger than
         * [TIMEOUT_S]: the server may legitimately use the full 25 s, and
         * there is still public Overpass's queue before that.
         *
         * What really bounds Igor's wait is the total budget in
         * `CorridorBuilder.BUDGET_MS` — this one is only the network.
         */
        const val READ_TIMEOUT_S = 75L

        const val CONNECT_TIMEOUT_S = 8L

        /** Wait before bothering the backup mirror. See [fetch]. */
        const val HEDGE_AFTER_MS = 5_000L

        /**
         * Deadline for the **whole** call — and this is what makes the budget exist.
         *
         * `withTimeoutOrNull` around `withContext(Dispatchers.IO)` **does not
         * interrupt** an OkHttp `execute()`: the coroutine is only cancelled at a
         * suspension point, and a blocking call has none. That is why
         * `CorridorBuilder`'s 15 s deadline let the query run for
         * 33 s in the 5th test. OkHttp's `callTimeout`, by contrast, really aborts
         * the call. (Since C16.5 the call goes through `enqueue`, and the coroutine's
         * cancellation also aborts it: see [request].)
         */
        const val CALL_TIMEOUT_S = 85L

        /** The polygon in the format of Overpass's `poly:` filter: `lat lon lat lon ...`, in degrees. */
        fun poly(polygon: List<PointE5>): String {
            require(polygon.size >= 3) { "the corridor polygon needs at least 3 vertices" }
            return polygon.joinToString(" ") {
                "%.5f %.5f".format(Locale.US, it.lat * LocalPlane.E5_TO_DEGREE, it.lon * LocalPlane.E5_TO_DEGREE)
            }
        }

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            .connectTimeout(CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
            .writeTimeout(CONNECT_TIMEOUT_S, TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_S, TimeUnit.SECONDS)
            .callTimeout(CALL_TIMEOUT_S, TimeUnit.SECONDS)
            .build()

        /**
         * Cap on the response, expanded. **A choice based on measurement:** the largest saved response, the
         * corridor of the old test route (22.4 km, recorded on 2026-08-01 and replaced by `tiete_copan`
         * on 2026-10-26), was 3.1 MB as Overpass sends it; that of another 23.6 km route, 2.5 MB.
         * That is ~140 KB per km of São Paulo, and 16 MB fits ~110 km of dense city. With the hedge, two
         * mirrors answer at the same time: 32 MB in the worst case.
         */
        const val MAX_BODY_BYTES = 16 * 1024 * 1024

        /** Maximum vertices in the `poly:` — see the class note. */
        const val MAX_POLY_VERTICES = 80

        /** Exactly the classes that `04 §3.2` asks for. */
        const val HIGHWAY_FILTER =
            "motorway|trunk|primary|secondary|tertiary|residential|unclassified|" +
                "motorway_link|trunk_link|primary_link|secondary_link"

        /**
         * Degrees → protocol units, with the **same** rounding as
         * `packer.py` and `MapboxRouteParser`: half rounds away from
         * zero. A different rule here would make the street be born 1 m beside the route.
         */
        fun quantize(degrees: Double): Int {
            val scaled = degrees * 100000.0
            return (if (scaled >= 0) scaled + 0.5 else scaled - 0.5).toInt()
        }
    }

    @Serializable
    private data class OverpassResponse(val elements: List<OverpassElement> = emptyList())

    @Serializable
    private data class OverpassElement(
        val type: String = "",
        val tags: OverpassTags? = null,
        val geometry: List<OverpassPoint>? = null,
    )

    @Serializable
    private data class OverpassTags(@SerialName("highway") val highway: String? = null)

    @Serializable
    private data class OverpassPoint(val lat: Double = 0.0, val lon: Double = 0.0)
}
