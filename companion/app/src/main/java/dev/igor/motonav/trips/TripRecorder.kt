package dev.igor.motonav.trips

import android.content.Context
import android.os.BatteryManager
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.favorites.FavoritesStore
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.WireFavorite
import dev.igor.motonav.route.LatLng
import java.io.File
import java.util.Locale
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * A trip, from the route send to the end of the navigation (C16.5).
 *
 * The batteries are those at the start and end **of the trip**: the arrival screen opened
 * after `NAV_ENDED` does not count (on 2026-10-16 it used more than the trip).
 */
@Serializable
data class Trip(
    val startMs: Long,
    /** The last event seen; it becomes the end of a trip that never received its own. */
    val lastMs: Long,
    val endMs: Long? = null,
    val label: String,
    /** What Mapbox said at departure. */
    val plannedS: Int,
    val distanceM: Int,
    val watchBatStart: Int? = null,
    val watchBatEnd: Int? = null,
    val phoneBatStart: Int? = null,
    val phoneBatEnd: Int? = null,
    val reroutes: Int = 0,
    val end: End? = null,
    /** The meters actually traveled, from the watch's track ([TrackOdometer], C16.5). */
    val riddenM: Int = 0,
    /**
     * The destination, for the watch's "Recentes" list (C16.5). It stays only in this private file, like
     * the [label]; a trip saved before C16.5 does not have it and does not enter the list.
     */
    val destLat: Double? = null,
    val destLon: Double? = null,
    /**
     * The longest stretch below 10 km/h after the bike moved ([PauseMeter], C16): a trip with a
     * long stop in the middle does not enter the pace ([PersonalPace]). A trip saved earlier (companion
     * up to 1.1.1) does not have it: `null`, and it stays out of the pace, because there is no way to know whether it stopped.
     */
    val longestPauseS: Int? = null,
) {
    enum class End { ARRIVED, CANCELLED, ERROR, NO_WORD, REPLACED, INTERRUPTED }

    val open: Boolean get() = endMs == null

    /** The actual duration, or `null` with the trip in progress. */
    val durationS: Int? get() = endMs?.let { ((it - startMs) / 1000).toInt() }

    /** Actual minus plan, in seconds; positive is delay. Only for those who arrived. */
    val delayS: Int? get() = durationS?.takeIf { end == End.ARRIVED }?.let { it - plannedS }

    val watchDrop: Int? get() = watchBatStart?.let { start -> watchBatEnd?.let { start - it } }

    val phoneDrop: Int? get() = phoneBatStart?.let { start -> phoneBatEnd?.let { start - it } }

    /** Average in km/h over the whole duration (stops included), only for a trip that ended and moved. */
    val avgKmh: Double?
        get() {
            val seconds = durationS ?: return null
            return if (seconds <= 0 || riddenM <= 0) null else riddenM * 3.6 / seconds
        }

    /**
     * Points per watch hour, only with [MIN_RATE_S] of trip: the level comes in whole
     * points, and 1 point in 10 min is already 6 %/h of uncertainty (`relatorio.py`, C6b).
     */
    val watchPerHour: Double?
        get() {
            val drop = watchDrop ?: return null
            val seconds = durationS ?: return null
            return if (seconds < MIN_RATE_S) null else drop * 3600.0 / seconds
        }

    override fun toString(): String = "Trip($startMs, ${end ?: "open"})"

    companion object {
        const val MIN_RATE_S = 600
    }
}

/**
 * **The trips, with nothing manual** (C16.5, Igor's request: "it has to be automatic").
 *
 * Listens to what already passes through the phone: the new route that becomes a session ([onSessionStarted]),
 * the recalculation request, the battery level the watch puts in the telemetry on each
 * `LOG` line (`bat N%`, `Telemetry.mc`), the `NAV_ENDED` and the session end without it.
 * The phone's battery comes from the caller, read at departure and at the end.
 *
 * Keeps the last [MAX] in a file in the app's **private** storage, like the
 * favorites: the destination name may be an address, so it does not go to a log or
 * commit (`CLAUDE.md`). Pure, no Android: it receives the [File]. It only touches the
 * main thread.
 */
class TripRecorder(
    private val file: File,
    private val phoneBattery: () -> Int? = { null },
    private val now: () -> Long = System::currentTimeMillis,
) {

    @Serializable
    private class Snapshot(val trips: List<Trip>, val openDestination: Point? = null)

    @Serializable
    private class Point(val lat: Double, val lon: Double)

    private var trips: List<Trip>
    private var openDestination: LatLng?
    private val odometer = TrackOdometer()
    private val pauses = PauseMeter()

    init {
        val loaded = load()
        trips = loaded?.trips.orEmpty()
        openDestination = loaded?.openDestination?.let { LatLng(it.lat, it.lon) }
    }

    /** Newest first. */
    fun list(): List<Trip> = trips.asReversed()

    /**
     * A new route went to the watch and became the session (share or favorite).
     * The trip open for another destination ends here; for the same one, it carries on (the
     * share of the same place again is not a new trip).
     *
     * For the same destination **before leaving** (no recalculation and with less than [REPLAN_BELOW_M]
     * traveled), the new route corrects the first: the plan and the watch of the trip become the
     * new route's (C16). On 2026-10-16 the favorite's first route gave 96 min and Igor asked again
     * 74 s later, ~200 m ahead: 43 min. Measured against the first, the trip gave half the
     * Mapbox time in [PersonalPace] and 50 min of slack on the "Viagens" screen.
     */
    fun onSessionStarted(destination: LatLng, label: String, plannedS: Int, distanceM: Int) {
        val at = now()
        val current = trips.lastOrNull()?.takeIf { it.open }
        if (current != null && destination == openDestination) {
            if (current.reroutes == 0 && current.riddenM < REPLAN_BELOW_M) {
                replaceLast(current.copy(startMs = at, lastMs = at, plannedS = plannedS, distanceM = distanceM))
                pauses.reset()
                EventLog.i(TAG, "trip replanned before leaving: ${plannedS / 60} min planned, ${distanceM / 1000} km")
            } else {
                replaceLast(current.copy(lastMs = at))
            }
            persist()
            return
        }
        if (current != null) {
            close(current, Trip.End.REPLACED, at)
        }
        pauses.reset()
        val battery = phoneBattery()
        trips = (trips + Trip(
            startMs = at,
            lastMs = at,
            label = label,
            plannedS = plannedS,
            distanceM = distanceM,
            phoneBatStart = battery,
            phoneBatEnd = battery,
            destLat = destination.lat,
            destLon = destination.lon,
            longestPauseS = 0,
        )).takeLast(MAX)
        openDestination = destination
        persist()
        EventLog.i(TAG, "new trip: ${plannedS / 60} min planned, ${distanceM / 1000} km")
    }

    /**
     * **The latest destinations**, for the watch's "Recent" screen (C16.5, `05 §RECENTS`): newest
     * first, one per place (the same destination within [SAME_PLACE_DEG] counts once), at the
     * at most [Protocol.MAX_RECENTS]. The `id` is the position in the list: it is what the watch returns in
     * `NAV_START_REQ`, and the phone looks it up again here, never in a coordinate coming from the watch.
     */
    fun recents(): List<Favorite> {
        val out = mutableListOf<Favorite>()
        for (trip in trips.asReversed()) {
            val lat = trip.destLat ?: continue
            val lon = trip.destLon ?: continue
            val seen = out.any { kotlin.math.abs(it.lat!! - lat) < SAME_PLACE_DEG && kotlin.math.abs(it.lon!! - lon) < SAME_PLACE_DEG }
            if (seen) continue
            out += Favorite(id = out.size, name = trip.label, lat = lat, lon = lon)
            if (out.size == Protocol.MAX_RECENTS) break
        }
        return out
    }

    /** The [recents] in the RECENTS message format. */
    fun wireRecents(): List<WireFavorite> = recents().map {
        WireFavorite(
            favId = it.id,
            latE5 = FavoritesStore.toE5(it.lat!!),
            lonE5 = FavoritesStore.toE5(it.lon!!),
            name = it.name,
            icon = 0,
        )
    }

    /** The watch asked for a recalculation in this trip. */
    fun onReroute() {
        val current = trips.lastOrNull()?.takeIf { it.open } ?: return
        replaceLast(current.copy(reroutes = current.reroutes + 1, lastMs = now()))
        persist()
    }

    /**
     * A line of the watch's `LOG`: the telemetry (`bat N%`) and, since C16.5, the track (`trk`),
     * which sums the meters traveled in the open trip and, since C16, measures its longest stop.
     */
    fun onWatchLog(line: String) {
        val fix = TrackOdometer.parse(line)
        if (fix != null) {
            onTrack(fix)
            return
        }
        val match = WATCH_BATTERY.find(line) ?: return
        val pct = match.groupValues[1].toIntOrNull() ?: return
        val current = trips.lastOrNull()?.takeIf { it.open } ?: return
        val changed = current.watchBatEnd != pct || current.watchBatStart == null
        val updated = current.copy(
            watchBatStart = current.watchBatStart ?: pct,
            watchBatEnd = pct,
            lastMs = now(),
        )
        replaceLast(updated)
        // One point at a time changes the file: the line comes every 15 s, the level every several minutes.
        if (changed) persist()
    }

    private fun onTrack(fix: TrackFix) {
        val metres = odometer.feed(fix)
        pauses.feed(fix)
        val open = trips.lastOrNull()?.takeIf { it.open } ?: return
        val ridden = open.riddenM + metres.toInt()
        // The trip opened before the update stays without the stop: the meter only saw the end of it.
        val known = open.longestPauseS
        val pause = known?.let { maxOf(it, pauses.longestS) }
        if (ridden == open.riddenM && pause == known) {
            return
        }
        replaceLast(open.copy(riddenM = ridden, longestPauseS = pause, lastMs = now()))
        // Writes every 100 m and every minute of stop: the track arrives every 15 s, in bursts of 3 lines.
        if (ridden / 100 != open.riddenM / 100 || (pause ?: 0) / 60 != (known ?: 0) / 60) persist()
    }

    /** Igor's pace, from the saved trips ([PersonalPace]). */
    fun pace(): PersonalPace.Estimate = PersonalPace.estimate(trips)

    /**
     * **The provider's duration as it goes to the watch** (C16): times Igor's pace. Whoever sends a route
     * or `ROUTE_UPDATE` goes through here; the trip's plan ([onSessionStarted]) stays the provider's,
     * otherwise the pace would learn from itself.
     */
    fun toWatchS(providerS: Int): Int {
        val pace = pace()
        val watchS = PersonalPace.scale(providerS, pace.factor)
        EventLog.i(
            TAG,
            "pace %.2f from %d trip(s): %d -> %d s to the watch".format(Locale.ROOT, pace.factor, pace.samples, providerS, watchS),
        )
        return watchS
    }

    /** `NAV_ENDED`, with the protocol's reason (`05 §Message types`). */
    fun onNavEnded(reason: Int) {
        val current = trips.lastOrNull()?.takeIf { it.open } ?: return
        val end = when (reason) {
            REASON_ARRIVED -> Trip.End.ARRIVED
            REASON_CANCELLED -> Trip.End.CANCELLED
            else -> Trip.End.ERROR
        }
        close(current, end, now())
        persist()
    }

    /** The session ended without `NAV_ENDED` (the phone gave up waiting for the watch). */
    fun onSessionEnded() {
        val current = trips.lastOrNull()?.takeIf { it.open } ?: return
        close(current, Trip.End.NO_WORD, now())
        persist()
    }

    private fun close(trip: Trip, end: Trip.End, at: Long) {
        val battery = phoneBattery() ?: trip.phoneBatEnd
        replaceLast(trip.copy(endMs = at, lastMs = at, end = end, phoneBatEnd = battery))
        openDestination = null
        EventLog.i(TAG, "trip ended: ${end.name.lowercase()}, ${(at - trip.startMs) / 60_000} min")
    }

    private fun replaceLast(trip: Trip) {
        trips = trips.dropLast(1) + trip
    }

    private fun load(): Snapshot? {
        if (!file.exists()) {
            return null
        }
        return try {
            val snapshot = json.decodeFromString<Snapshot>(file.readText(Charsets.UTF_8))
            // A trip opened by another process lost the session along with it: the
            // navigation does not come back, so it closes at the last signal it gave.
            val last = snapshot.trips.lastOrNull()
            if (last != null && last.open) {
                Snapshot(snapshot.trips.dropLast(1) + last.copy(endMs = last.lastMs, end = Trip.End.INTERRUPTED), null)
            } else {
                snapshot
            }
        } catch (e: Exception) {
            EventLog.w(TAG, "unreadable trips, starting over: ${e.javaClass.simpleName}")
            null
        }
    }

    /** Writes to a temp file in the same directory and renames, like the favorites. */
    private fun persist() {
        try {
            val temp = File(file.parentFile, file.name + ".tmp")
            val destination = openDestination?.let { Point(it.lat, it.lon) }
            temp.writeText(json.encodeToString(Snapshot(trips, destination)), Charsets.UTF_8)
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
        } catch (e: Exception) {
            EventLog.w(TAG, "trips not saved: ${e.javaClass.simpleName}")
        }
    }

    companion object {
        /**
         * Two destinations less than this apart (in degrees, ~55 m) are the same place in the "Recentes" list:
         * Igor shares the same building from different apps, and each one drops the pin in its own corner.
         * A choice, not a measurement.
         */
        const val SAME_PLACE_DEG = 0.0005

        /**
         * Less than this traveled, and with no recalculation, Igor has not left yet: the new route for the same
         * destination replaces the plan ([onSessionStarted]). On 10/16 he asked again at ~200 m. A choice.
         */
        const val REPLAN_BELOW_M = 1000

        private const val TAG = "TripRecorder"

        /** About three weeks of three trips a day. A choice, not a measurement. */
        const val MAX = 60

        const val FILE_NAME = "trips.json"

        /** `Protocol.NAV_ENDED_*`, repeated so the class stays Android-free. */
        private const val REASON_ARRIVED = 0
        private const val REASON_CANCELLED = 1

        /** The watch telemetry field (`Telemetry.mc`), the same one `relatorio.py` reads. */
        private val WATCH_BATTERY = Regex("""\bbat (\d+)%""")

        private val json = Json { ignoreUnknownKeys = true }

        fun defaultFile(filesDir: File): File = File(filesDir, FILE_NAME)

        @Volatile
        private var instance: TripRecorder? = null

        /** One per process: `RerouteHub` writes and the trips screen reads the same one. */
        fun of(context: Context): TripRecorder =
            instance ?: synchronized(this) {
                instance ?: context.applicationContext.let { app ->
                    TripRecorder(
                        file = defaultFile(app.filesDir),
                        phoneBattery = {
                            app.getSystemService(BatteryManager::class.java)
                                ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                                ?.takeIf { it in 0..100 }
                        },
                    )
                }.also { instance = it }
            }
    }
}
