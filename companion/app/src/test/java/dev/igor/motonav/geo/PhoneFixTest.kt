package dev.igor.motonav.geo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/** What Android's `Location` becomes on its way to the watch. The place is MASP. */
class PhoneFixTest {

    // prevents: the phone fix reaching the watch in another unit (m/s where it reads dm/s, the
    // heading in radians) or rounded the wrong way in the southern hemisphere, and the watch
    // arrow showing up meters away from where the bike is.
    @Test
    fun aLocationBecomesProtocolUnits() {
        val fix = PhoneFix.of(-23.561414, -46.655882, speedMps = 13.94f, bearingDeg = 270.6f, accuracyM = 11.2f, fixElapsedMs = 5_000)

        assertEquals(PhoneFix(-2356141, -4665588, speedDms = 139, headingDeg = 271, accuracyM = 12, fixElapsedMs = 5_000), fix)
    }

    // prevents: a stopped phone sending heading 0 (north) and accuracy 0 (perfect) when Android
    // reported neither: the watch would rotate the map and trust a fix with no accuracy.
    @Test
    fun whatAndroidDidNotSayIsNotInvented() {
        val fix = PhoneFix.of(-23.561414, -46.655882, speedMps = null, bearingDeg = null, accuracyM = null, fixElapsedMs = 0)!!

        assertEquals(0, fix.speedDms)
        assertNull(fix.headingDeg)
        assertEquals("no accuracy is the worst accuracy", 0xFFFF, fix.accuracyM)
        assertEquals("360 degrees is north", 0, PhoneFix.of(0.0, 0.0, 1f, 359.7f, 5f, 0)!!.headingDeg)
        assertEquals("negative speed is noise", 0, PhoneFix.of(0.0, 0.0, -0.4f, null, 5f, 0)!!.speedDms)
        assertEquals("what does not fit saturates", 0xFFFF, PhoneFix.of(0.0, 0.0, 1f, null, 1e9f, 0)!!.accuracyM)
    }

    // prevents: a `Location` with garbage (NaN, latitude 91) becoming a PHONE_FIX that the packer
    // refuses with an exception mid-send, or that the watch accepts as a position.
    @Test
    fun whatIsNotAPlaceIsNotAFix() {
        assertNull(PhoneFix.of(Double.NaN, -46.6, null, null, null, 0))
        assertNull(PhoneFix.of(-23.5, Double.NaN, null, null, null, 0))
        assertNull(PhoneFix.of(90.001, 0.0, null, null, null, 0))
        assertNull(PhoneFix.of(0.0, -180.001, null, null, null, 0))
        assertNotNull(PhoneFix.of(-90.0, 180.0, null, null, null, 0))
    }

    // prevents: a `$fix` in a log line carrying Igor's position into `motonav.log`.
    @Test
    fun theTextOfAFixHasNoCoordinates() {
        val text = PhoneFix.of(-23.561414, -46.655882, 13.94f, 270.6f, 11.2f, 5_000).toString()

        assertFalse(text, text.contains("2356") || text.contains("4665") || text.contains("23.5") || text.contains("46.6"))
    }
}
