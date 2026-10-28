package dev.igor.motonav.link

import org.junit.Assert.assertEquals
import org.junit.Test

/** The `ROUTE_UPDATE` ACK read as a response (05 §ROUTE_UPDATE). */
class UpdateResultTest {

    // prevents: the empty bitmap (the watch refused: it no longer navigates this route) read as
    // delivered just because an ACK arrived, and the phone never learning that navigation ended.
    @Test
    fun theAckBitmapSaysWhetherTheWatchAppliedTheUpdate() {
        assertEquals(UpdateResult.DELIVERED, updateResultOf(byteArrayOf(0x01)))
        assertEquals(UpdateResult.REFUSED, updateResultOf(byteArrayOf(0x00)))
        assertEquals("an ACK with no bitmap confirms nothing", UpdateResult.REFUSED, updateResultOf(byteArrayOf()))
        assertEquals("no ACK in time", UpdateResult.SILENT, updateResultOf(null))
    }
}
