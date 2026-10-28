package dev.igor.motonav.proto

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The FIX_REQ reader against `fix_req_00.bin`, the fixture of `FIX_REQ_SAMPLE` in
 * `tools/packer.py` (the request that turns it on). The watch builds the same frame byte
 * by byte (`PhoneFixTest.fixReqMatchesTheFixture`, Monkey C).
 */
class FixReqTest {

    private val fixture = File("../../tools/fixtures/fix_req_00.bin")

    // prevents: reading the byte at the wrong offset (the header is 8 B) and never turning on the phone GPS
    // when the watch loses the fix, or reading "on" where it wrote "off" and draining the
    // phone battery for the whole trip.
    @Test
    fun fixReqMatchesFixture() {
        val frame = fixture.readBytes()

        assertEquals(FixReq(on = true), FixReq.parse(frame))
        assertEquals(FixReq(on = false), FixReq.parse(frame.clone().also { it[Protocol.HEADER_SIZE] = 0 }))
    }

    // prevents: the phone obeying BLE garbage (05 §Robustness rules 4): a short frame, with
    // leftovers, of another type, of another version, with a lying `length` or with a byte that is
    // neither 0 nor 1 neither turns the phone GPS on nor off.
    @Test
    fun `anything that is not a whole fix request is refused`() {
        val frame = fixture.readBytes()

        assertNull("frame curto", FixReq.parse(frame.copyOf(frame.size - 1)))
        assertNull("frame with extra bytes", FixReq.parse(frame + 0))
        assertNull("another type", FixReq.parse(frame.clone().also { it[1] = Protocol.MSG_NAV_START_REQ.toByte() }))
        assertNull("another version", FixReq.parse(frame.clone().also { it[0] = (Protocol.VERSION + 1).toByte() }))
        assertNull("length mentiroso", FixReq.parse(frame.clone().also { it[7] = 2 }))
        assertNull("nem liga nem desliga", FixReq.parse(frame.clone().also { it[Protocol.HEADER_SIZE] = 2 }))
    }
}
