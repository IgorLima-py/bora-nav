package dev.igor.motonav.trips

import org.junit.Assert.assertEquals
import org.junit.Test

/** The watch track odometer (C16.5). Made-up points near zero, never from a ride. */
class TrackOdometerTest {

    /** 0.001° of latitude ≈ 111.2 m: 100 E5 units. */
    private fun trk(t: Int, latE5: Int, speedDms: Int = 140) = "trk $t $latE5 0 $speedDms 0"

    private fun ride(vararg lines: String): Double {
        val odometer = TrackOdometer()
        return lines.sumOf { odometer.feed(it) }
    }

    // prevents: the trip with no km ridden ("does the log track how many km it rode?", Igor, 2026-10-17): three
    // stretches of ~111 m at 14 m/s have to add up to ~334 m.
    @Test
    fun `consecutive fixes add the distance between them`() {
        assertEquals(333.6, ride(trk(0, 0), trk(8, 100), trk(16, 200), trk(24, 300)), 1.0)
    }

    // prevents: the bike stopped at a traffic light adding up GPS jumps, and the simulated ride counting as street.
    @Test
    fun `standing still and the simulated ride add nothing`() {
        assertEquals(0.0, ride(trk(0, 0, speedDms = 3), trk(5, 2, speedDms = 5), trk(10, 0, speedDms = 2)), 0.0)
        assertEquals(0.0, ride("trs 0 0 0 140 0", "trs 8 100 0 140 0"), 0.0)
    }

    // prevents: a bad fix (1 km in 5 s) or the watch reopening (time going back) becoming a kilometer.
    @Test
    fun `jumps and a clock that restarts add nothing`() {
        assertEquals(0.0, ride(trk(0, 0), trk(5, 1000)), 0.0)
        assertEquals(0.0, ride(trk(100, 0), trk(5, 100)), 0.0)
    }
}
