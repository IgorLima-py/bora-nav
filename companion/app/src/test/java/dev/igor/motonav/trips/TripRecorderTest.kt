package dev.igor.motonav.trips

import dev.igor.motonav.route.LatLng
import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The automatic trips (C16.5). The places are public (Copan, MASP), never
 * an address of Igor's; the telemetry lines follow the `Telemetry.mc` format.
 */
class TripRecorderTest {

    private lateinit var dir: File
    private var clock = 1_760_000_000_000L
    private var phone: Int? = 80

    private val copan = LatLng(-23.54522, -46.64218)
    private val masp = LatLng(-23.5614, -46.6559)

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("motonav-trips").toFile()
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
    }

    private fun recorder() = TripRecorder(TripRecorder.defaultFile(dir), phoneBattery = { phone }, now = { clock })

    private fun telemetry(bat: Int) =
        "142516s phase navigating · screen map · route 51 120pts · mem 80/124KB · bat $bat% · eta 600s · fix gps"

    private fun minutes(n: Int) {
        clock += n * 60_000L
    }

    private var watchT = 0L
    private var latE5 = 0

    /** [n] `trk` lines every [everyS] s; with the default, each one 111 m ahead at 14 m/s. */
    private fun track(trips: TripRecorder, n: Int, speedDms: Int = 140, stepE5: Int = 100, everyS: Int = 8) {
        repeat(n) {
            trips.onWatchLog("trk $watchT $latE5 0 $speedDms 0")
            watchT += everyS
            latE5 += stepE5
        }
    }

    // prevents: the favorite's first route of 16/10 (96 min, which Igor asked for again 74 s later and
    // ~200 m ahead: 43 min) staying as the trip plan: the "Viagens" screen gave 50 min of slack and
    // the pace, half of Mapbox's. And, after leaving, sharing again swapping the plan.
    @Test
    fun `the same destination again before leaving replaces the plan, after leaving it does not`() {
        val trips = recorder()
        trips.onSessionStarted(copan, "Copan", plannedS = 96 * 60, distanceM = 50_000)
        minutes(1)
        track(trips, 3) // ~222 m
        trips.onSessionStarted(copan, "Copan", plannedS = 43 * 60, distanceM = 23_000)
        val replanned = trips.list().single()
        assertEquals(43 * 60, replanned.plannedS)
        assertEquals(23_000, replanned.distanceM)
        assertEquals("the trip's clock is the new route's", clock, replanned.startMs)

        track(trips, 10) // another ~1.1 km: already left
        minutes(20)
        trips.onSessionStarted(copan, "Copan", plannedS = 25 * 60, distanceM = 12_000)
        minutes(25)
        trips.onNavEnded(0)

        val trip = trips.list().single()
        assertEquals("after leaving, the plan stays", 43 * 60, trip.plannedS)
        assertEquals(45 * 60, trip.durationS)
        assertEquals(2 * 60, trip.delayS)
    }

    // prevents: a stop on foot in the middle of a real trip (11.7 min under 10 km/h, on foot and
    // stopped) entering the pace; and the wait before leaving (helmet, gate) counting as a stop.
    @Test
    fun `a long stop in the middle is kept and keeps the trip out of the pace, the wait before leaving is not`() {
        val trips = recorder()
        trips.onSessionStarted(copan, "Copan", plannedS = 30 * 60, distanceM = 3_000)
        track(trips, 181, speedDms = 0, stepE5 = 0, everyS = 5) // 15 min stopped before leaving
        track(trips, 10) // moving
        track(trips, 145, speedDms = 14, stepE5 = 1, everyS = 5) // 12 min on foot
        track(trips, 10)
        minutes(45)
        trips.onNavEnded(0)

        val trip = trips.list().single()
        assertEquals(720, trip.longestPauseS)
        assertNull(PersonalPace.sample(trip))
        assertEquals("survives a new process", 720, recorder().list().single().longestPauseS)
    }

    // prevents: the time that goes to the watch not changing with the trips the phone kept: the factor comes
    // from the trips file, and only after the floor.
    @Test
    fun `the duration to the watch carries the pace of the trips it kept`() {
        val trips = recorder()
        repeat(PersonalPace.MIN_TRIPS) { i ->
            assertEquals("before trip ${i + 1}", 1710, trips.toWatchS(1710))
            trips.onSessionStarted(if (i % 2 == 0) copan else masp, "Destino", plannedS = 30 * 60, distanceM = 2_000)
            track(trips, 21) // ~2,2 km
            minutes(24)
            trips.onNavEnded(0)
        }

        assertEquals(0.8, trips.pace().factor, 1e-9)
        assertEquals(1368, trips.toWatchS(1710))
        assertEquals("survives a new process", 1368, recorder().toWatchS(1710))
    }

    // prevents: on 2026-10-16 the trips' battery came out from memory ("about 4%", "I forgot how much it was"),
    // and the arrival screen open after NAV_ENDED spent 4 points in 4 h, more than the trip.
    @Test
    fun `a ride keeps its own battery, its reroutes and its delay, and ends on arrival`() {
        val trips = recorder()
        trips.onSessionStarted(copan, "Copan", plannedS = 28 * 60, distanceM = 12_300)
        minutes(1)
        trips.onWatchLog(telemetry(61))
        trips.onWatchLog("142530s vibra curva a 200 m") // not telemetry
        minutes(10)
        trips.onReroute()
        trips.onSessionStarted(copan, "Copan", plannedS = 20 * 60, distanceM = 9_000) // shared again
        minutes(20)
        trips.onWatchLog(telemetry(59))
        phone = 74
        trips.onNavEnded(0)
        minutes(240)
        trips.onWatchLog(telemetry(55)) // the arrival screen, after the end

        val trip = trips.list().single()
        assertEquals(Trip.End.ARRIVED, trip.end)
        assertEquals(31 * 60, trip.durationS)
        assertEquals("the plan is the departure's", 3 * 60, trip.delayS)
        assertEquals(61, trip.watchBatStart)
        assertEquals(59, trip.watchBatEnd)
        assertEquals(80, trip.phoneBatStart)
        assertEquals(74, trip.phoneBatEnd)
        assertEquals(1, trip.reroutes)
        assertEquals(2 * 3600.0 / (31 * 60), trip.watchPerHour!!, 1e-9)
        assertEquals("survives a new process", trip, recorder().list().single())
    }

    // prevents: `relatorio.py` gave 0.6 %/h on 2026-10-16 because it counted time with the app closed; a
    // trip open when the process died would count until the next app opening.
    @Test
    fun `a trip the process lost ends at its last signal, and a new destination starts another`() {
        val first = recorder()
        first.onSessionStarted(copan, "Copan", plannedS = 600, distanceM = 4_000)
        minutes(7)
        first.onWatchLog(telemetry(70))
        minutes(300) // the process died here; navigation does not come back

        val reopened = recorder()
        val lost = reopened.list().single()
        assertEquals(Trip.End.INTERRUPTED, lost.end)
        assertEquals(7 * 60, lost.durationS)
        assertNull("only those who arrived have a delay", lost.delayS)

        reopened.onSessionStarted(masp, "MASP", plannedS = 900, distanceM = 6_000)
        minutes(2)
        reopened.onSessionStarted(copan, "Copan", plannedS = 600, distanceM = 4_000)

        val (newest, replaced) = reopened.list().take(2)
        assertTrue(newest.open)
        assertEquals("Copan", newest.label)
        assertEquals(Trip.End.REPLACED, replaced.end)
        assertEquals(3, reopened.list().size)
    }

    // prevents: the watch's "Recentes" screen (C16.5) repeating the same building shared from two apps,
    // going past the 5 the protocol carries, or putting the old destination on top.
    @Test
    fun `the recents are the newest places, one per place, at most five`() {
        val trips = recorder()
        val places = listOf(
            "Sé" to LatLng(-23.5505, -46.6333),
            "Luz" to LatLng(-23.5347, -46.6349),
            "Ibirapuera" to LatLng(-23.5874, -46.6576),
            "Pacaembu" to LatLng(-23.5475, -46.6650),
            "MASP" to masp,
        )
        for ((name, place) in places) {
            trips.onSessionStarted(place, name, plannedS = 600, distanceM = 4_000)
            minutes(30)
        }
        trips.onSessionStarted(copan, "Copan", plannedS = 600, distanceM = 4_000)
        minutes(30)
        // The same Copan from another app, 20 m to the side: the same place.
        trips.onSessionStarted(LatLng(copan.lat + 0.0002, copan.lon), "Edifício Copan", plannedS = 600, distanceM = 4_000)

        val recents = trips.recents()
        assertEquals(listOf("Edifício Copan", "MASP", "Pacaembu", "Ibirapuera", "Luz"), recents.map { it.name })
        assertEquals(listOf(0, 1, 2, 3, 4), recents.map { it.id })
        assertEquals("survives a new process", recents, recorder().recents())
    }
}
