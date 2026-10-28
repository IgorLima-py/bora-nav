package dev.igor.motonav.nav

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rule for when the phone GPS turns on and off, with a fake Android and the test clock. */
class PhoneFixStreamerTest {

    private class FakePhone : PhoneFixStreamer.Port {
        var now = 0L
        var whyNot: String? = null
        var starts = 0
        var stops = 0
        val log = mutableListOf<String>()

        /** The phone GPS is on (location request open). */
        val gpsOn: Boolean get() = starts > stops

        override fun unavailable(): String? = whyNot

        override fun startLocation() {
            starts++
        }

        override fun stopLocation() {
            stops++
        }

        override fun nowMs(): Long = now

        override fun log(line: String) {
            log += line
        }
    }

    // prevents: the watch asking for the phone GPS in a tunnel and the phone turning nothing on; or the
    // phone continuing to transmit (and draining battery) after the watch dismissed it.
    @Test
    fun theWatchTurnsThePhoneGpsOnAndOff() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)
        assertFalse("before the watch asks, no fix goes out", streamer.onLocation())

        streamer.onFixReq(on = true)
        assertTrue(phone.gpsOn)
        assertTrue(streamer.onLocation())
        assertTrue(streamer.onLocation())

        phone.now = 12_000
        streamer.onFixReq(on = false)
        assertFalse(phone.gpsOn)
        assertFalse("after it is dismissed, a fix that still arrives does not go out", streamer.onLocation())
        assertEquals(
            listOf("PHONE_FIX on", "PHONE_FIX off: the watch dismissed it, 2 fixes in 12 s"),
            phone.log,
        )
    }

    // prevents: the watch's 20 s renewal asking Android for a position again each time
    // (two open requests, the second never removed) or restarting the phone GPS.
    @Test
    fun aRenewalOnlyExtendsTheLease() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)

        streamer.onFixReq(on = true)
        phone.now = 20_000
        streamer.onFixReq(on = true)
        phone.now = 40_000
        streamer.onFixReq(on = true)

        assertEquals("a single position request", 1, phone.starts)
        phone.now = 79_000
        assertTrue("39 s after the last renewal it still holds", streamer.onLocation())
        assertEquals(listOf("PHONE_FIX on"), phone.log)
    }

    // prevents: a single FIX_REQ lost on the radio turning off the phone GPS in the middle of the tunnel.
    // The watch renews on a 1 s tick (20 to 21 s), so with one request lost the next
    // arrives at 41 s or more: with a 40 s deadline the phone stopped and cold-restarted.
    @Test
    fun oneLostRenewalDoesNotTurnThePhoneOff() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)
        streamer.onFixReq(on = true)

        // The 20.5 s renewal was lost; the next one only arrives at 42 s.
        phone.now = 41_900
        assertTrue("a lost request: the fix keeps going out", streamer.onLocation())
        streamer.onTick()
        assertTrue(phone.gpsOn)
        phone.now = 42_000
        streamer.onFixReq(on = true)

        assertEquals("the GPS was not turned on again", 1, phone.starts)
        assertEquals(listOf("PHONE_FIX on"), phone.log)
    }

    // prevents: FIX_REQ 0 being lost (or the watch being turned off in the middle of the tunnel) and the phone
    // GPS staying on for the rest of the day. Holds with fixes arriving and with no fix at all.
    @Test
    fun fiftySecondsWithoutRenewalTurnThePhoneOff() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)
        streamer.onFixReq(on = true)

        phone.now = 50_000
        assertTrue("at exactly 50 s the request still holds", streamer.onLocation())
        streamer.onTick()
        assertTrue(phone.gpsOn)

        phone.now = 50_001
        assertFalse("past the deadline: the fix does not go out", streamer.onLocation())
        assertFalse(phone.gpsOn)
        assertEquals("PHONE_FIX off: 50 s without the request being renewed, 1 fixes in 50 s", phone.log.last())

        // No GPS (garage): no fix arrives, and what sees the deadline expire is the tick.
        val indoors = FakePhone()
        val silent = PhoneFixStreamer(indoors)
        silent.onFixReq(on = true)
        indoors.now = 50_001
        silent.onTick()
        assertFalse(indoors.gpsOn)
        assertFalse(silent.active)

        // And a new request turns it on again, from scratch.
        silent.onFixReq(on = true)
        assertTrue(indoors.gpsOn)
        assertEquals(2, indoors.starts)
    }

    // prevents: the watch arriving (or the session dropping) with the phone GPS on and it continuing
    // to send position to a watch that no longer navigates.
    @Test
    fun theEndOfTheNavigationTurnsThePhoneOff() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)
        streamer.onFixReq(on = true)
        streamer.onLocation()

        phone.now = 3_000
        streamer.onSessionEnded()

        assertFalse(phone.gpsOn)
        assertEquals("PHONE_FIX off: navigation ended, 1 fixes in 3 s", phone.log.last())
        streamer.onSessionEnded()
        assertEquals("the end of navigation with the GPS off does nothing", 1, phone.stops)
    }

    // prevents: the phone turning on the GPS without navigation, without permission or without the service of type
    // `location` (Android would deliver nothing with the screen off), and the log not saying
    // why the watch was left without a backup.
    @Test
    fun withoutSessionPermissionOrServiceThePhoneDoesNotStart() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)

        for (reason in listOf("no navigation in progress", "no location permission", "the foreground service does not have the location type")) {
            phone.whyNot = reason
            streamer.onFixReq(on = true)
            assertFalse(reason, phone.gpsOn)
            assertEquals("PHONE_FIX unavailable: $reason", phone.log.last())
        }
        assertEquals(0, phone.starts)

        // It was on and stopped being allowed (permission removed): the renewal turns it off.
        phone.whyNot = null
        streamer.onFixReq(on = true)
        assertTrue(phone.gpsOn)
        phone.whyNot = "no location permission"
        phone.now = 20_000
        streamer.onFixReq(on = true)
        assertFalse(phone.gpsOn)
        assertEquals("PHONE_FIX off: no location permission, 0 fixes in 20 s", phone.log.last())
    }

    // prevents: Android dropping the location request (SecurityException) and the phone thinking
    // it is still transmitting, without turning on again at the next renewal.
    @Test
    fun aLocationFailureTurnsThePhoneOffAndTheNextRequestTriesAgain() {
        val phone = FakePhone()
        val streamer = PhoneFixStreamer(phone)
        streamer.onFixReq(on = true)

        streamer.onFailure("Android refused the location (SecurityException)")
        assertFalse(streamer.active)

        phone.now = 20_000
        streamer.onFixReq(on = true)
        assertTrue(phone.gpsOn)
        assertEquals(2, phone.starts)
    }
}
