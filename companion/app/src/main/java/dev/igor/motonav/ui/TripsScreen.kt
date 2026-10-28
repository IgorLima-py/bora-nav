package dev.igor.motonav.ui

import android.content.res.Resources
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.igor.motonav.R
import dev.igor.motonav.trips.PersonalPace
import dev.igor.motonav.trips.Trip
import java.text.SimpleDateFormat
import java.util.Date
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * "Viagens" (Trips, C16.5): what [dev.igor.motonav.trips.TripRecorder] saved, the
 * newest on top. No button at all: trips enter on their own.
 */
@Composable
fun TripsScreen(trips: List<Trip>, onBack: () -> Unit) {
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier.fillMaxSize().padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    text = stringResource(R.string.trips_title),
                    style = MaterialTheme.typography.headlineMedium,
                )
                TextButton(onClick = onBack) { Text(stringResource(R.string.settings_back)) }
            }
            Text(
                text = stringResource(R.string.trips_intro),
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                text = TripText.paceLine(LocalContext.current.resources, PersonalPace.estimate(trips.asReversed())),
                style = MaterialTheme.typography.bodyMedium,
            )
            Column(
                modifier = Modifier.weight(1f).verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (trips.isEmpty()) {
                    Text(stringResource(R.string.trips_empty))
                }
                trips.forEach { trip ->
                    TripRow(trip)
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun TripRow(trip: Trip) {
    val res = LocalContext.current.resources
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            text = "${TripText.whenText(res, trip.startMs)} · ${trip.label}",
            style = MaterialTheme.typography.titleMedium,
        )
        TripText.lines(res, trip).forEach { line ->
            Text(text = line, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** The lines of a trip, without Compose: it is what the screen shows, in the language of [Resources]. */
object TripText {

    fun whenText(res: Resources, atMs: Long): String =
        SimpleDateFormat(res.getString(R.string.trip_when_format), res.locale()).format(Date(atMs))

    fun lines(res: Resources, trip: Trip): List<String> = listOfNotNull(
        timeLine(res, trip),
        distanceLine(res, trip) +
            if (trip.reroutes > 0) " · " + res.getQuantityString(R.plurals.trip_reroutes, trip.reroutes, trip.reroutes) else "",
        batteryLine(res, R.string.trip_battery_watch, trip.watchBatStart, trip.watchBatEnd, trip.watchPerHour),
        batteryLine(res, R.string.trip_battery_phone, trip.phoneBatStart, trip.phoneBatEnd, null),
    )

    /** The learned pace (C16): how much of Mapbox's (car) time Igor takes on a motorcycle. */
    fun paceLine(res: Resources, pace: PersonalPace.Estimate): String {
        if (pace.samples < PersonalPace.MIN_TRIPS) {
            return res.getString(R.string.trip_pace_learning, pace.samples, PersonalPace.MIN_TRIPS)
        }
        return res.getString(R.string.trip_pace, (pace.factor * 100).roundToInt(), pace.samples)
    }

    private fun timeLine(res: Resources, trip: Trip): String {
        val duration = trip.durationS ?: return res.getString(R.string.trip_running, minutes(trip.plannedS))
        val delay = trip.delayS
        val delta = if (delay == null) "" else " " + res.getString(R.string.trip_delta, "${if (delay >= 0) "+" else "-"}${clock(abs(delay))}")
        return "${minutes(duration)}$delta · ${endName(res, trip.end)}"
    }

    /** The km traveled (from the watch's track, C16.5) and the planned ones; with no track, only the plan. */
    private fun distanceLine(res: Resources, trip: Trip): String {
        val loc = res.locale()
        val planned = "%.1f".format(loc, trip.distanceM / 1000.0)
        if (trip.riddenM <= 0) {
            return res.getString(R.string.trip_planned, planned)
        }
        val avg = trip.avgKmh?.let { " · " + res.getString(R.string.trip_avg, "%.0f".format(loc, it)) } ?: ""
        return res.getString(R.string.trip_ridden, "%.1f".format(loc, trip.riddenM / 1000.0), planned) + avg
    }

    private fun batteryLine(res: Resources, who: Int, start: Int?, end: Int?, perHour: Double?): String? {
        if (start == null || end == null) {
            return null
        }
        val rate = perHour?.let { " · " + res.getString(R.string.trip_battery_rate, "%.1f".format(res.locale(), it)) } ?: ""
        val used = start - end
        return res.getQuantityString(R.plurals.trip_battery, used, res.getString(who), start, end, used) + rate
    }

    private fun minutes(seconds: Int): String = "${(seconds + 30) / 60} min"

    private fun clock(seconds: Int): String = "%d:%02d".format(seconds / 60, seconds % 60)

    private fun endName(res: Resources, end: Trip.End?): String = res.getString(
        when (end) {
            Trip.End.ARRIVED -> R.string.trip_end_arrived
            Trip.End.CANCELLED -> R.string.trip_end_cancelled
            Trip.End.ERROR -> R.string.trip_end_error
            Trip.End.NO_WORD -> R.string.trip_end_no_word
            Trip.End.REPLACED -> R.string.trip_end_replaced
            Trip.End.INTERRUPTED -> R.string.trip_end_interrupted
            null -> R.string.trip_end_running
        },
    )
}
