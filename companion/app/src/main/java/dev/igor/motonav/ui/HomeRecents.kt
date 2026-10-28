package dev.igor.motonav.ui

import android.content.res.Resources
import dev.igor.motonav.R
import dev.igor.motonav.favorites.Favorite
import dev.igor.motonav.geo.Place
import dev.igor.motonav.route.LatLng
import dev.igor.motonav.trips.Trip
import java.util.Calendar
import java.text.SimpleDateFormat
import java.util.TimeZone

/**
 * The Home "Recentes" (sheet 2, `docs/design/telas.md` §5.3): the places from
 * `TripRecorder.recents()`, each with the line of the newest trip of the same name, such as
 * "ontem · 23 min · 11,4 km".
 *
 * @param trips newest first, as `TripRecorder.list()` returns them.
 */
fun homeRecents(
    res: Resources,
    recents: List<Favorite>,
    trips: List<Trip>,
    nowMs: Long,
    zone: TimeZone = TimeZone.getDefault(),
    max: Int = 3,
): List<HomeRecent> = recents.filter { it.hasPlace }.take(max).map { place ->
    val trip = trips.firstOrNull { it.label == place.name }
    HomeRecent(
        name = place.name,
        line = trip?.let { recentLine(res, it, nowMs, zone) } ?: "",
        place = Place(place.name, place.address ?: "", LatLng(place.lat!!, place.lon!!)),
    )
}

/** "hoje", "ontem" or "12/10", then the time (the traveled or the planned) and the distance. */
fun recentLine(res: Resources, trip: Trip, nowMs: Long, zone: TimeZone = TimeZone.getDefault()): String {
    val day = dayLabel(res, trip.startMs, nowMs, zone)
    val time = duration(trip.durationS ?: trip.plannedS)
    val meters = if (trip.riddenM > 0) trip.riddenM else trip.distanceM
    val km = "%.1f km".format(res.locale(), meters / 1000.0)
    return "$day · $time · $km"
}

private fun dayLabel(res: Resources, atMs: Long, nowMs: Long, zone: TimeZone): String {
    val at = Calendar.getInstance(zone).apply { timeInMillis = atMs }
    val now = Calendar.getInstance(zone).apply { timeInMillis = nowMs }
    val yesterday = (now.clone() as Calendar).apply { add(Calendar.DAY_OF_YEAR, -1) }
    fun Calendar.sameDay(other: Calendar) =
        get(Calendar.YEAR) == other.get(Calendar.YEAR) && get(Calendar.DAY_OF_YEAR) == other.get(Calendar.DAY_OF_YEAR)
    return when {
        at.sameDay(now) -> res.getString(R.string.day_today)
        at.sameDay(yesterday) -> res.getString(R.string.day_yesterday)
        else -> SimpleDateFormat(res.getString(R.string.day_format), res.locale()).apply { timeZone = zone }.format(at.time)
    }
}

/** "23 min" up to the hour; then "1h05". */
private fun duration(seconds: Int): String {
    val minutes = (seconds + 30) / 60
    return if (minutes < 60) "$minutes min" else "%dh%02d".format(minutes / 60, minutes % 60)
}
