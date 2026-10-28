package dev.igor.motonav.nav

import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.link.UpdateResult
import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.RerouteReq
import dev.igor.motonav.proto.WireRadar
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.route.RouteProvider
import dev.igor.motonav.share.Destination
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * The phone-side route recalculation (C11): receives `REROUTE_REQ`, asks for another
 * route through the remaining stops, sends it to the watch and then the corridor.
 *
 * **Sole owner of the corridor and the recalculation.** Before C11 the corridor lived in the
 * share screen's `lifecycleScope`: closing the screen (or a new
 * share) killed the send, and a recalculation in the middle of navigation has no
 * screen at all. Here it runs in a process scope.
 *
 * The 20 s limit between requests (ADR-4) belongs to the watch; the phone only guards
 * against a request on top of a request ([busy]).
 *
 * **Also owner of `ROUTE_UPDATE`** (C13a): while there is a session, a loop asks the
 * provider every [etaIntervalMs] how long the route takes now and sends it to the watch. The
 * watch's reply is also how the phone finds out navigation ended without
 * `NAV_ENDED` ([refreshEta]). The loop lives here, and not in the foreground service,
 * because it competes for `WatchLink` with the recalculation and the corridor.
 *
 * Everything comes in and goes out on the main thread (`Dispatchers.Main.immediate` in the app),
 * so the state here needs no lock.
 */
class RerouteController(
    private val scope: CoroutineScope,
    private val provider: RouteProvider,
    private val nextRouteId: () -> Int,
    private val sendRoute: suspend (PackableRoute) -> Boolean,
    private val buildCorridor: suspend (PackableRoute) -> PackableCorridor?,
    private val sendCorridor: suspend (PackableRoute, PackableCorridor) -> Boolean,
    private val retryDelayMs: Long = CORRIDOR_RETRY_MS,
    private val sendRouteUpdate: suspend (routeId: Int, durationS: Int) -> UpdateResult =
        { _, _ -> UpdateResult.NOT_CONNECTED },
    private val etaIntervalMs: Long = ETA_REFRESH_MS,
    private val now: () -> Long = System::currentTimeMillis,
    /** The session began (non-null) or ended (null): this is what turns the service on and off. */
    private val onSessionChanged: (RerouteSession?) -> Unit = {},
    /** A recalculation began (the request passed the filters): the trip's tally (C16.5). */
    private val onRerouteStarted: () -> Unit = {},
    /**
     * The provider's duration as it goes to the watch, times Igor's pace (C16, `TripRecorder.toWatchS`).
     * Only for what goes out to the watch: the session and [refreshEta]'s silence count with the provider's.
     */
    private val toWatchS: (Int) -> Int = { it },
    /**
     * The route's speed cameras (C16.6, `RadarClient`), fetched **after** the corridor and in the same job:
     * the two share `WatchLink`, and the corridor is what Igor sees first. The exception is
     * [cachedRadars], which goes first (C16.7).
     */
    private val buildRadars: suspend (PackableRoute) -> List<WireRadar> = { emptyList() },
    private val sendRadars: suspend (PackableRoute, List<WireRadar>) -> Boolean = { _, _ -> true },
    /** The route's cameras from what the phone already downloaded (`RadarStore`), sent before the corridor. */
    private val cachedRadars: suspend (PackableRoute) -> List<WireRadar> = { emptyList() },
    /** The waits between camera attempts: one more attempt than waits. */
    private val radarDelaysMs: List<Long> = RADAR_RETRY_MS,
) {

    private var session: RerouteSession? = null

    /**
     * The session from before a send that did **not** close. The watch only adopts the new route
     * if it arrives whole; meanwhile it keeps asking (every 20 s, ADR-4) with
     * the **old** `routeId`. Without keeping the previous one, those requests were discarded
     * as "from an old route" and the recalculation died until a new share.
     */
    private var unconfirmed: RerouteSession? = null

    /**
     * A share is sending a new route. While it lasts, the recalculation
     * request is ignored: the two sends share `WatchLink` without a lock and the watch
     * drops its preparation when a META with another `routeId` arrives, so the recalculation
     * (old destination) could beat the share. The watch repeats the request.
     */
    private var sharing = false
    private var rerouteJob: Job? = null
    private var corridorJob: Job? = null

    /**
     * The first corridor search, already running while the route travels to the watch (C16.5), and the route
     * it belongs to. The same route's [startCorridor] reuses it instead of starting from zero.
     */
    private var prefetch: Pair<PackableRoute, Deferred<PackableCorridor?>>? = null

    /** The `ROUTE_UPDATE` loop, one per delivered route, and the query it has in flight. */
    private var etaLoop: Job? = null
    private var refreshJob: Job? = null

    /** When the last route reached the watch: the loop's ticks count from here. */
    private var anchorMs = 0L

    /**
     * The last time the watch showed it is navigating: the delivered route or an
     * accepted `ROUTE_UPDATE`. The silence that ends the session in [refreshEta] is
     * counted from here.
     */
    private var confirmedMs = 0L

    /** Consecutive ETA ticks in which the watch did not answer (neither accepted nor refused). */
    private var unansweredTicks = 0

    /** The last duration the provider gave for each route, by `routeId`. */
    private val freshDurationS = mutableMapOf<Int, Int>()

    /** A recalculation is running (route being requested or sent). */
    val busy: Boolean get() = rerouteJob?.isActive == true

    /** The current session, for the test and for the log. */
    val currentSession: RerouteSession? get() = session

    /** A new route (share) began: drops everything that belonged to the previous one. */
    fun cancel() {
        val had = session != null
        rerouteJob?.cancel()
        corridorJob?.cancel()
        etaLoop?.cancel()
        dropPrefetch()
        rerouteJob = null
        corridorJob = null
        etaLoop = null
        refreshJob = null
        session = null
        unconfirmed = null
        sharing = false
        freshDurationS.clear()
        if (had) {
            onSessionChanged(null)
        }
    }

    /**
     * A share is about to send a new route: stops the recalculation and the corridor in
     * progress, **but keeps the session**. If the new route does not arrive (cancelled, Mapbox
     * went down, the send failed), the watch stays on the old one and keeps asking
     * with its id; clearing the session here left the recalculation dead until the next
     * share that worked.
     *
     * With [next], the new route's corridor search already starts here ([prefetchCorridor]).
     */
    fun supersede(next: PackableRoute? = null) {
        rerouteJob?.cancel()
        corridorJob?.cancel()
        // Only the query in flight: the loop carries on, because the old session remains valid
        // if the new route does not arrive.
        refreshJob?.cancel()
        rerouteJob = null
        corridorJob = null
        sharing = true
        if (next != null) {
            prefetchCorridor(next)
        } else {
            dropPrefetch()
        }
    }

    /**
     * The share ended without a new route (failed or was cancelled): the old session
     * becomes recalculable again, and the corridor that was coming for the new one is dropped.
     */
    fun endSupersede() {
        sharing = false
        dropPrefetch()
    }

    /**
     * Starts fetching [route]'s corridor **while it travels to the watch** (C16.5). Overpass
     * uses the phone's network and the send uses Bluetooth; only the corridor send has to wait for the route,
     * and the search depended only on the geometry. In the bench logs (Oct 15) Overpass started 14 ms
     * after the route arrived, and its send took 2.4 to 3.6 s: that is what is gained on every
     * corridor. The Bluetooth order does not change: the route first, alone (`01 §RNF-02`).
     */
    fun prefetchCorridor(route: PackableRoute) {
        dropPrefetch()
        prefetch = route to scope.async {
            try {
                buildCorridor(route)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // `async` with an exception would take down the whole scope: here it becomes "no corridor",
                // and [startCorridor] tries again.
                EventLog.w(TAG, "early corridor failed: ${e.message}")
                null
            }
        }
    }

    private fun dropPrefetch() {
        prefetch?.second?.cancel()
        prefetch = null
    }

    /** The route that just went to the watch becomes the current session. */
    fun register(newSession: RerouteSession) {
        session = newSession
        unconfirmed = null
        sharing = false
        anchor(newSession)
        onSessionChanged(newSession)
    }

    /** The route of [delivered] just reached the watch: the ETA ticks restart from here. */
    private fun anchor(delivered: RerouteSession) {
        anchorMs = now()
        confirmedMs = anchorMs
        unansweredTicks = 0
        etaLoop?.cancel()
        etaLoop = scope.launch {
            while (true) {
                // Fixed rhythm over the delivery instant: the query's time does not
                // push the next tick back.
                val sinceAnchor = now() - anchorMs
                delay((sinceAnchor / etaIntervalMs + 1) * etaIntervalMs - sinceAnchor)
                // Lazy so `refreshJob` exists before the query goes out: whoever
                // cancels "what is in flight" must find this one, not the previous tick's.
                val refresh = launch(start = CoroutineStart.LAZY) { refreshEta() }
                refreshJob = refresh
                refresh.join()
            }
        }
    }

    /**
     * One `ROUTE_UPDATE` tick: asks the provider how long the current route takes
     * **now**, by the same request that generated it, and sends it to the watch. With no answer from the
     * provider, it sends the duration the watch already has: **every tick queries the watch**.
     *
     * It skips when another send to the watch is running. Since C13b `WatchLink` queues
     * the sends (`sendMutex`), so it is no longer to protect the link: it is that
     * an update waiting behind a one-minute corridor would arrive stale, and the
     * next tick sends another.
     *
     * **It is also what ends the session without `NAV_ENDED`**, so the foreground
     * service does not stay alive forever:
     * - the watch refused (no longer navigating this route, or arrived): done;
     * - the watch has not answered for longer than the whole route takes, counted from its
     *   last answer ([confirmedMs]), **over [SILENT_TICKS_TO_END] consecutive
     *   ticks**: it was turned off or fell behind. Whoever was navigating at that time
     *   would already have arrived. One lost tick ends nothing, nor does a trip that takes
     *   longer than predicted: each accepted update restarts the count. The two ticks are from
     *   C13b: on a route shorter than the loop interval, the first tick is already
     *   past the arrival time, and a Bluetooth drop in that minute ended the session
     *   with the rider on the road.
     *
     * With a recalculation whose send did not close ([unconfirmed]), the watch may be on the
     * new route, the old one, or with the new one still being prepared, and it accepts an update for the route
     * being prepared (`05 §ROUTE_UPDATE`). So it asks about both and **only drops the
     * one it refuses**.
     */
    internal suspend fun refreshEta() {
        val latest = session ?: return
        val skip = when {
            sharing -> "share in progress"
            busy -> "recalculation in progress"
            corridorJob?.isActive == true -> "corridor being sent"
            else -> null
        }
        if (skip != null) {
            EventLog.i(TAG, "ROUTE_UPDATE route ${latest.routeId} skipped: $skip")
            return
        }

        val older = unconfirmed
        val newAnswer = updateEta(latest)
        val oldAnswer = older?.let { updateEta(it) }
        if (session !== latest || unconfirmed !== older) {
            // The session changed while the update was traveling: the answer is from another time.
            return
        }

        val accepted = UpdateResult.DELIVERED
        val refused = UpdateResult.REFUSED
        if (newAnswer == accepted || oldAnswer == accepted) {
            confirmedMs = now()
            unansweredTicks = 0
            if (newAnswer == accepted && oldAnswer == refused) {
                EventLog.i(TAG, "the watch switched to route ${latest.routeId}: ${older?.routeId} drops out")
                unconfirmed = null
            } else if (newAnswer == refused && older != null) {
                EventLog.i(TAG, "the watch stays on route ${older.routeId}: it becomes the current one again")
                session = older
                unconfirmed = null
            }
            return
        }
        if (newAnswer == refused && (older == null || oldAnswer == refused)) {
            EventLog.i(TAG, "session ended: the watch no longer navigates route ${latest.routeId}")
            cancel()
            return
        }
        unansweredTicks++
        val silentMs = now() - confirmedMs
        val routeS = knownDurationS(latest)
        if (silentMs > routeS * 1000L && unansweredTicks >= SILENT_TICKS_TO_END) {
            EventLog.i(
                TAG,
                "session ended: the watch has not answered for ${silentMs / 1000} s, more than the $routeS s of the " +
                    "whole route, in $unansweredTicks consecutive queries",
            )
            cancel()
        }
    }

    private fun knownDurationS(route: RerouteSession): Int = freshDurationS[route.routeId] ?: route.durationS

    /**
     * Queries the provider and sends the duration to the watch: the new one, or the one it already has
     * when the provider did not answer.
     */
    private suspend fun updateEta(target: RerouteSession): UpdateResult {
        val before = knownDurationS(target)
        var missing: String? = null
        val result = try {
            withTimeoutOrNull(ETA_ROUTE_TIMEOUT_MS) {
                provider.route(target.origin, target.bearing, target.destination, target.allVia())
            }.also { if (it == null) missing = "the provider did not answer in $ETA_ROUTE_TIMEOUT_MS ms" }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            missing = e.message ?: e.javaClass.simpleName
            null
        }
        val fresh = result?.durationS?.takeIf { it > 0 }
        if (fresh == null) {
            EventLog.w(TAG, "ROUTE_UPDATE route ${target.routeId} no new duration: ${missing ?: "duration ${result?.durationS}"}")
        }
        val seconds = fresh ?: before
        if (seconds <= 0) {
            // `ROUTE_UPDATE` does not carry a zero duration (`05 §ROUTE_UPDATE`): without a number, there is no question.
            return UpdateResult.SEND_FAILED
        }
        val outcome = sendRouteUpdate(target.routeId, toWatchS(seconds))
        when {
            outcome != UpdateResult.DELIVERED ->
                EventLog.w(TAG, "ROUTE_UPDATE route ${target.routeId} not delivered: $outcome")
            fresh == null ->
                EventLog.i(TAG, "ROUTE_UPDATE route ${target.routeId} kept at $before s: the watch answered")
            else -> {
                // The distance goes along so it is possible to count, afterwards, how many times
                // the provider answered with another path (the duration is then its own).
                EventLog.i(
                    TAG,
                    "ROUTE_UPDATE route ${target.routeId} delivered: $before -> $fresh s " +
                        "(dist ${target.distanceM} -> ${result?.distanceM} m)",
                )
                freshDurationS[target.routeId] = fresh
            }
        }
        return outcome
    }

    /**
     * Fetches the corridor and sends it **after** the route is already on the watch, with retries:
     * public Overpass answered once in six in the street tests and
     * the failure is a full queue, the kind of thing that passes on the next attempt (it was the share screen's
     * `fetchCorridorInBackground`).
     */
    fun startCorridor(route: PackableRoute) {
        corridorJob?.cancel()
        // This same route's early search counts as the 1st attempt ([prefetchCorridor]).
        val early = prefetch?.takeIf { it.first === route }?.second
        if (early == null) {
            dropPrefetch()
        }
        prefetch = null
        corridorJob = scope.launch {
            // The camera cache goes before the corridor (C16.7): with no network, it is a small message, and
            // the corridor and the new search took 16 to 46 s, with the cameras at the start already passing.
            val fromCache = try {
                sendCachedRadars(route)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                EventLog.w(TAG, "radars cache abandoned on this route: ${e.javaClass.simpleName}: ${e.message}")
                null
            }
            try {
                sendCorridorWithRetries(route, early)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // The corridor is decoration: the route is already on the watch, and an exception that escaped
                // from this `launch` took the companion down in the middle of navigation. `Throwable`, not
                // `Exception`: a giant tile's `OutOfMemoryError` slipped past every catch
                // on the path. No retry: a network failure already returns `null` from
                // [CorridorBuilder]; what gets here is a defect or memory, and repeating only repeats.
                EventLog.w(TAG, "corridor abandoned on this route: ${e.javaClass.simpleName}: ${e.message}")
            }
            try {
                sendRadarsWithRetries(route, fromCache)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                // For the same reason as the corridor: the camera is an extra warning, never takes navigation down.
                EventLog.w(TAG, "radars abandoned on this route: ${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    /**
     * The cameras, with one more attempt than [radarDelaysMs]: the query goes to the same Overpass
     * mirrors that fail with a full queue. An empty list does not go to the watch: the new route starts
     * with no cameras anyway.
     *
     * **What the phone already knows** ([cachedRadars]) went before the corridor ([fromCache], what it
     * sent); the new answer, when it comes, replaces the cache's on the watch (a RADARS replaces the whole
     * list, `05 §RADARS`). If the new one says there are no cameras and the cache sent some, the empty
     * list goes out, to erase the cache's.
     */
    private suspend fun sendRadarsWithRetries(route: PackableRoute, fromCache: List<WireRadar>?) {
        val attempts = radarDelaysMs.size + 1
        for (attempt in 1..attempts) {
            val startedAt = System.currentTimeMillis()
            val radars = try {
                buildRadars(route)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                EventLog.w(TAG, "radars failed on attempt $attempt/$attempts: ${e.message}")
                null
            }
            if (radars != null) {
                val elapsed = System.currentTimeMillis() - startedAt
                when {
                    radars == fromCache ->
                        EventLog.i(TAG, "radars of route ${route.routeId} on attempt $attempt: same as the cache")
                    radars.isEmpty() && fromCache == null ->
                        EventLog.i(TAG, "no radar on route ${route.routeId} ($elapsed ms)")
                    else -> {
                        val sent = sendRadars(route, radars)
                        EventLog.i(
                            TAG,
                            "${radars.size} radars of route ${route.routeId} on attempt $attempt in $elapsed ms, " +
                                "sent: $sent",
                        )
                    }
                }
                return
            }
            if (attempt < attempts) {
                delay(radarDelaysMs[attempt - 1])
            }
        }
        EventLog.w(
            TAG,
            "no radars from Overpass on this route after $attempts attempts" +
                (fromCache?.let { ", keeping the ${it.size} from the cache" } ?: ""),
        )
    }

    /** Sends the cache's cameras, if there are any on the route; returns what it sent, or `null`. */
    private suspend fun sendCachedRadars(route: PackableRoute): List<WireRadar>? {
        val cached = try {
            cachedRadars(route)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            EventLog.w(TAG, "radars cache failed: ${e.javaClass.simpleName}: ${e.message}")
            emptyList()
        }
        if (cached.isEmpty()) {
            EventLog.i(TAG, "no radar in the cache for route ${route.routeId}")
            return null
        }
        val sent = sendRadars(route, cached)
        EventLog.i(TAG, "${cached.size} radars from cache for route ${route.routeId}, sent: $sent")
        return cached
    }

    private suspend fun sendCorridorWithRetries(route: PackableRoute, early: Deferred<PackableCorridor?>?) {
        for (attempt in 1..CORRIDOR_ATTEMPTS) {
            val startedAt = System.currentTimeMillis()
            val corridor = if (attempt == 1 && early != null) early.await() else buildCorridor(route)
            val elapsed = System.currentTimeMillis() - startedAt
            if (corridor != null) {
                EventLog.i(
                    TAG,
                    "corridor on attempt $attempt in $elapsed ms" +
                        if (attempt == 1 && early != null) " after the route (early search)" else "",
                )
                val sent = sendCorridor(route, corridor)
                EventLog.i(TAG, "corridor sent to watch: $sent")
                return
            }
            EventLog.w(TAG, "corridor failed on attempt $attempt/$CORRIDOR_ATTEMPTS in $elapsed ms")
            if (attempt < CORRIDOR_ATTEMPTS) {
                delay(retryDelayMs)
            }
        }
        EventLog.w(TAG, "no corridor on this route after $CORRIDOR_ATTEMPTS attempts")
    }

    /** The watch's `REROUTE_REQ`. */
    fun onRerouteReq(req: RerouteReq) {
        val latest = session
        if (latest == null) {
            EventLog.w(TAG, "route request ${req.routeId} with no navigation in progress: ignored")
            return
        }
        if (sharing) {
            EventLog.i(TAG, "route request ${req.routeId} while a share is being sent: ignored")
            return
        }
        val current = if (req.routeId == unconfirmed?.routeId) unconfirmed ?: latest else latest
        if (req.routeId != current.routeId) {
            // The watch was still asking about the previous route: its `distAlong` is not
            // valid for the route that was already sent.
            EventLog.w(TAG, "request for route ${req.routeId}, the current one is ${current.routeId}: ignored")
            return
        }
        if (busy) {
            EventLog.i(TAG, "route request ${req.routeId} while recalculating: ignored")
            return
        }
        onRerouteStarted()
        rerouteJob = scope.launch { reroute(current, req) }
    }

    /** `NAV_ENDED`: Igor ended it. A late request must not reopen navigation. */
    fun onNavEnded() {
        EventLog.i(TAG, "navigation ended on the watch: no recalculation")
        cancel()
    }

    private suspend fun reroute(current: RerouteSession, req: RerouteReq) {
        val startedAt = System.currentTimeMillis()
        try {
            // The old route's corridor has nothing to do on the watch after the new one.
            corridorJob?.cancel()
            // Nor its ETA: the in-flight query would fight the new route for the link.
            refreshJob?.cancel()
            val from = LatLng(req.latE5 / 1e5, req.lonE5 / 1e5)
            val via = current.remainingVia(req.distAlongM)
            EventLog.i(
                TAG,
                "recalculating from route ${current.routeId} at ${req.distAlongM} m: ${via.size} stop(s) left",
            )
            val result = provider.route(from, req.headingDeg?.toFloat(), current.destination, via)
            val routeId = nextRouteId()
            val packable = result.toPackable(routeId = routeId, destNameOverride = current.label, watchS = toWatchS(result.durationS))
            // The session becomes the new one **before** the send: a request that arrives about the
            // old route while the new one travels is discarded by `routeId`.
            val next = RerouteSession.of(
                routeId,
                Destination(current.destination, current.label, via),
                result,
                bearing = req.headingDeg?.toFloat(),
            )
            session = next
            // Until the send closes, the new route is not confirmed: the watch still asks
            // with the old id, and if it adopts the new one, it starts asking with the new. Accept
            // both. Marking **before** the send also covers cancellation in the middle of it
            // (a share that arrived), which exits by exception and does not pass through the `if`.
            unconfirmed = current
            prefetchCorridor(packable)
            val ok = sendRoute(packable)
            if (!ok) {
                dropPrefetch()
            }
            if (ok) {
                unconfirmed = null
                freshDurationS.remove(current.routeId)
                anchor(next)
            }
            EventLog.i(
                TAG,
                "route $routeId of the recalculation ${if (ok) "sent" else "NOT sent"} in " +
                    "${System.currentTimeMillis() - startedAt} ms",
            )
            if (ok) {
                startCorridor(packable)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // The watch retries on its own (20 s, ADR-4): here only the why is kept.
            EventLog.w(TAG, "recalculation failed: ${e.message}")
        }
    }

    companion object {
        private const val TAG = "RerouteController"

        /**
         * Attempts to fetch the corridor, spaced by [CORRIDOR_RETRY_MS]: in the street
         * tests public Overpass answered **once in six**, with a full queue
         * (504/timeout). Since the route is already on the watch, insisting is free.
         */
        const val CORRIDOR_ATTEMPTS = 3
        const val CORRIDOR_RETRY_MS = 20_000L

        /**
         * The waits between camera attempts, increasing. On 2026-10-23 the 2 attempts in 25 s
         * caught both mirrors down (502 "at capacity" at 22:41:07 and 504 at 22:41:30): on a busy
         * night, the queue does not empty in 25 s. Four attempts in ~3.5 min, a choice; the route is already on the
         * watch and the cache covers the wait ([cachedRadars]). During them `ROUTE_UPDATE` skips
         * ("corridor being sent"), but its first tick is at 10 min ([ETA_REFRESH_MS]).
         */
        val RADAR_RETRY_MS = listOf(25_000L, 60_000L, 120_000L)
        val RADAR_ATTEMPTS = RADAR_RETRY_MS.size + 1

        /** `07-ROADMAP.md` §F4: "ROUTE_UPDATE (ETA refresh 10 min)". */
        const val ETA_REFRESH_MS = 600_000L

        /**
         * Consecutive queries with no answer from the watch for the session to end, beyond the
         * silence longer than the route. Two: a single one is the size of a Bluetooth
         * drop. Cost: with the watch turned off, the service stays alive one more interval
         * (10 min) than it otherwise would.
         */
        const val SILENT_TICKS_TO_END = 2

        /**
         * How long the tick waits for the provider before carrying on with the duration it already has:
         * the 3 attempts of `MapboxProvider` times the 10 s timeout that OkHttp
         * uses by default. It does not interrupt the network call in progress (OkHttp's
         * `execute()` is blocking and `withTimeoutOrNull` waits for it to return): the real
         * cap is OkHttp's own timeouts.
         */
        const val ETA_ROUTE_TIMEOUT_MS = 30_000L
    }
}
