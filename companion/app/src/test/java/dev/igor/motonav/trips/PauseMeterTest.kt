package dev.igor.motonav.trips

import org.junit.Assert.assertEquals
import org.junit.Test

/** A stop in the middle of the trip (C16), fix by fix. */
class PauseMeterTest {

    private fun fix(t: Long, speedDms: Int) = TrackFix(t, 0, 0, speedDms)

    // prevents: the LOG batch repeating a line (the 16/10 logs have doubled lines) or the watch
    // reopening the app (time goes back) joining two slow stretches into one.
    @Test
    fun `a repeated line and a clock that restarts do not stretch a stop`() {
        val meter = PauseMeter()
        meter.feed(fix(0, 140))
        meter.feed(fix(10, 0))
        meter.feed(fix(100, 0))
        meter.feed(fix(100, 0)) // repeated
        meter.feed(fix(150, 0))
        assertEquals(140, meter.longestS)

        meter.feed(fix(5, 0)) // the watch reopened
        meter.feed(fix(105, 0))
        assertEquals("100 s of the new stretch, not 140 + 100", 140, meter.longestS)
        meter.feed(fix(205, 0))
        assertEquals(200, meter.longestS)

        meter.reset()
        meter.feed(fix(300, 0))
        meter.feed(fix(900, 0))
        assertEquals("after the reset, being stopped before moving does not count", 0, meter.longestS)
    }
}
