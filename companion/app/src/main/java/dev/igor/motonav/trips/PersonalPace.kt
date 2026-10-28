package dev.igor.motonav.trips

import kotlin.math.roundToInt

/**
 * **Igor's motorcycle pace** (C16, his question on 2026-10-17: "is the time for a car or a motorcycle, and
 * does it learn?"). Mapbox has no motorcycle profile: the duration is `driving-traffic`'s, for a car. This
 * factor is how much of Mapbox's time Igor really takes, learned from the trips that
 * [TripRecorder] keeps, and the phone applies it to the duration before it goes to the watch (META and
 * `ROUTE_UPDATE`); the protocol format does not change.
 *
 * The calculation is the **median** of the actual ÷ predicted ratio of the last [WINDOW] trips that qualify, and 1.0
 * (pure Mapbox) while there are fewer than [MIN_TRIPS]. The median, not the mean, because the trip
 * that escapes the filters (a coffee stop that did not stop the bike, a wrong way) is one among several and would pull
 * the mean on its own. Measured on 2026-10-16 (`DECISIONS.md` §2026-10-17 — Igor's pace): 0.96 and 0.73
 * in the two clean trips, median 0.84; the third stopped ~12 min in the middle and would give 1.05.
 *
 * Pure, no Android: receives the trips, oldest first.
 */
object PersonalPace {

    /** Trips that qualify before the factor leaves 1.0: the median of 5 ignores even 2 outliers. A choice. */
    const val MIN_TRIPS = 5

    /** The most recent ones that enter the calculation: pace changes with the season and traffic. A choice, not a measurement. */
    const val WINDOW = 20

    /** Below 5 min of plan, the minute of sending the route and of arrival weighs too much in the ratio. A choice. */
    const val MIN_PLANNED_S = 300

    /** Ratios outside this are not pace: a route from another origin, a trip left open and forgotten. A choice. */
    const val MIN_RATIO = 0.5
    const val MAX_RATIO = 2.0

    /**
     * The watch's track has to cover from half to one and a half times the plan: with no track it is the simulated
     * lap (`trs` does not add up, [TrackOdometer]) or the link that brought nothing; with double, Igor
     * rode another trip. On 10/16 the three gave 0.98 to 1.07. A choice backed by that.
     */
    const val MIN_RIDDEN_SHARE = 0.5
    const val MAX_RIDDEN_SHARE = 1.5

    /**
     * A trip with a stop like these in the middle ([PauseMeter]) was interrupted: its time is not
     * pace. On 10/16 the stops of the clean trips were 1.2 and 1.6 min; the interrupted one, 11.7 min.
     * A choice backed by that.
     */
    const val MAX_PAUSE_S = 180

    /** The factor and how many trips it came from. */
    data class Estimate(val factor: Double, val samples: Int)

    /** The actual ÷ predicted ratio of this trip, or `null` when it does not qualify for pace. */
    fun sample(trip: Trip): Double? {
        if (trip.end != Trip.End.ARRIVED || trip.plannedS < MIN_PLANNED_S) {
            return null
        }
        val real = trip.durationS ?: return null
        val pause = trip.longestPauseS ?: return null
        val share = trip.riddenM.toDouble() / trip.distanceM.coerceAtLeast(1)
        if (share < MIN_RIDDEN_SHARE || share > MAX_RIDDEN_SHARE || pause >= MAX_PAUSE_S) {
            return null
        }
        return (real.toDouble() / trip.plannedS).takeIf { it in MIN_RATIO..MAX_RATIO }
    }

    /** The factor from the trips [oldestFirst]: 1.0 with fewer than [MIN_TRIPS] that qualify. */
    fun estimate(oldestFirst: List<Trip>): Estimate {
        val samples = oldestFirst.mapNotNull(::sample).takeLast(WINDOW)
        if (samples.size < MIN_TRIPS) {
            return Estimate(1.0, samples.size)
        }
        return Estimate(median(samples), samples.size)
    }

    /** The provider's duration as it goes to the watch: never 0, which `ROUTE_UPDATE` refuses (`05 §ROUTE_UPDATE`). */
    fun scale(providerS: Int, factor: Double): Int = (providerS * factor).roundToInt().coerceAtLeast(1)

    fun median(values: List<Double>): Double {
        val sorted = values.sorted()
        val mid = sorted.size / 2
        return if (sorted.size % 2 == 1) sorted[mid] else (sorted[mid - 1] + sorted[mid]) / 2
    }
}
