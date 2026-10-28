package dev.igor.motonav.trips

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Igor's motorcycle pace against Mapbox's car time (C16). Numbers only: the trips have no
 * place or time, and those of 2026-10-16 come from `DECISIONS.md` §2026-10-17 — Igor's pace.
 */
class PersonalPaceTest {

    private fun trip(
        plannedS: Int,
        realS: Int,
        distanceM: Int = 10_000,
        riddenM: Int = distanceM,
        pauseS: Int? = 60,
        end: Trip.End = Trip.End.ARRIVED,
    ) = Trip(
        startMs = 0,
        lastMs = realS * 1000L,
        endMs = realS * 1000L,
        label = "Destino",
        plannedS = plannedS,
        distanceM = distanceM,
        end = end,
        riddenM = riddenM,
        longestPauseS = pauseS,
    )

    /** A trip with ratio [ratio] over 30 min of plan. */
    private fun ratio(ratio: Double) = trip(plannedS = 1800, realS = (1800 * ratio).toInt())

    // prevents: the watch and the phone disagreeing on the minute: PersonalPace and RouteUpdateTest read the
    // same fixture, and its `watch_s` is what the HUD has to show.
    @Test
    fun `the shared fixture gives the factor and the paced duration the watch test shows`() {
        val fixture = Json.parseToJsonElement(File("../../tools/fixtures/ritmo.json").readText(Charsets.UTF_8)).jsonObject
        val trips = fixture["trips"]!!.jsonArray.map { (it as JsonObject).toTrip() }

        val pace = PersonalPace.estimate(trips)

        assertEquals(5, pace.samples)
        assertEquals(fixture["factor"]!!.jsonPrimitive.double, pace.factor, 1e-12)
        assertEquals(
            fixture["watch_s"]!!.jsonPrimitive.int,
            PersonalPace.scale(fixture["mapbox_s"]!!.jsonPrimitive.int, pace.factor),
        )
    }

    // prevents: the factor jumping from 1.0 to that of two trips: on 16/10 they gave 0.96 and 0.73, and the
    // watch would come out changing the time by 16% with Igor not having ridden for a week.
    @Test
    fun `below the floor the watch keeps the Mapbox time`() {
        val four = List(PersonalPace.MIN_TRIPS - 1) { ratio(0.7) }

        assertEquals(PersonalPace.Estimate(1.0, 4), PersonalPace.estimate(four))
        assertEquals(0.7, PersonalPace.estimate(four + ratio(0.7)).factor, 1e-9)
    }

    // prevents: a real trip with ~12 min on foot in the middle teaching the watch that the
    // rider takes 1.05 of Mapbox's time, when the two without a stop gave 0.96 and 0.73.
    @Test
    fun `the rides of 16 October leave the interrupted one out and the other two give 0,84`() {
        val a = trip(plannedS = 2609, realS = 2728, distanceM = 23_224, riddenM = 24_900, pauseS = 702)
        val b = trip(plannedS = 1431, realS = 1368, distanceM = 10_206, riddenM = 10_000, pauseS = 72)
        val c = trip(plannedS = 2578, realS = 1875, distanceM = 23_862, riddenM = 23_700, pauseS = 96)

        assertNull("stopped 11.7 min in the middle", PersonalPace.sample(a))
        assertEquals(0.956, PersonalPace.sample(b)!!, 0.001)
        assertEquals(0.727, PersonalPace.sample(c)!!, 0.001)
        assertEquals(0.84, PersonalPace.median(listOf(PersonalPace.sample(b)!!, PersonalPace.sample(c)!!)), 0.005)
        assertEquals("two do not pass the floor", 1.0, PersonalPace.estimate(listOf(a, b, c)).factor, 0.0)
    }

    // prevents: a trip that is not pace entering the calculation: the one ended on the watch, the short one, the
    // simulated ride (no track), the one on another route (twice the km), and the route from another origin (half
    // of Mapbox's time, like the favorite's first route on 16/10).
    @Test
    fun `trips that are not pace are left out`() {
        assertNull(PersonalPace.sample(trip(1800, 1500, end = Trip.End.CANCELLED)))
        assertNull(PersonalPace.sample(trip(1800, 1500, end = Trip.End.INTERRUPTED)))
        assertNull(PersonalPace.sample(trip(1800, 1500).copy(endMs = null)))
        assertNull(PersonalPace.sample(trip(PersonalPace.MIN_PLANNED_S - 1, 200)))
        assertNull(PersonalPace.sample(trip(1800, 1500, riddenM = 0)))
        assertNull(PersonalPace.sample(trip(1800, 1500, distanceM = 10_000, riddenM = 16_000)))
        assertNull(PersonalPace.sample(trip(1800, 1500, pauseS = PersonalPace.MAX_PAUSE_S)))
        assertNull(PersonalPace.sample(trip(5784, 2806)))
        assertEquals(1500.0 / 1800, PersonalPace.sample(trip(1800, 1500))!!, 1e-12)
    }

    // prevents: an interrupted trip, recorded by 1.1.1 (without the stop field), entering
    // the pace with the 0 of a default: in the file it passes every other filter, with 1.05.
    @Test
    fun `a trip kept before the pause meter is left out`() {
        val kept = """{"startMs":0,"lastMs":2728000,"endMs":2728000,"label":"Destino","plannedS":2609,
            "distanceM":23224,"end":"ARRIVED","riddenM":24900}"""

        val trip = Json { ignoreUnknownKeys = true }.decodeFromString(Trip.serializer(), kept)

        assertNull(trip.longestPauseS)
        assertNull(PersonalPace.sample(trip))
        assertEquals(2728000.0 / 1000 / 2609, PersonalPace.sample(trip.copy(longestPauseS = 0))!!, 1e-12)
    }

    // prevents: an off-curve trip that passed the filters moving the factor, and the pace from months
    // ago weighing as much as this week's.
    @Test
    fun `the median of the newest twenty`() {
        val old = List(20) { ratio(1.2) }
        val recent = List(19) { ratio(0.8) } + ratio(1.9)

        val pace = PersonalPace.estimate(old + recent)

        assertEquals(20, pace.samples)
        assertEquals(0.8, pace.factor, 0.001)
    }

    // prevents: a ROUTE_UPDATE of 0 s, which the watch refuses and the phone would read as "navigation ended".
    @Test
    fun `the paced duration rounds and never reaches zero`() {
        assertEquals(1368, PersonalPace.scale(1710, 0.8))
        assertEquals(1, PersonalPace.scale(1, 0.5))
        assertEquals(1710, PersonalPace.scale(1710, 1.0))
    }

    private fun JsonObject.toTrip() = trip(
        plannedS = this["planned_s"]!!.jsonPrimitive.int,
        realS = this["actual_s"]!!.jsonPrimitive.int,
        distanceM = this["planned_m"]!!.jsonPrimitive.int,
        riddenM = this["ridden_m"]!!.jsonPrimitive.int,
        pauseS = this["pause_s"]!!.jsonPrimitive.int,
        end = Trip.End.valueOf(this["end"]!!.jsonPrimitive.content),
    )
}
