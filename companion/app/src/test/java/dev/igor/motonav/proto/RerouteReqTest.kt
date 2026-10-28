package dev.igor.motonav.proto

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The REROUTE_REQ reader against `reroute_req_00.bin`, the fixture that
 * `tools/packer.py` generates and the watch reproduces byte by byte. The expected
 * values are those of the `REROUTE_REQ_SAMPLE` there.
 */
class RerouteReqTest {

    private val fixture = File("../../tools/fixtures/reroute_req_00.bin")

    @Test
    fun rerouteReqMatchesFixture() {
        val req = RerouteReq.parse(fixture.readBytes())!!

        assertEquals(7, req.routeId)
        assertEquals(-2362660, req.latE5)
        assertEquals(-4665640, req.lonE5)
        assertEquals(87, req.headingDeg)
        assertEquals(10432, req.distAlongM)
    }

    /** `heading` ≥ 360 means "the watch does not know": it becomes `null`, never a heading. */
    @Test
    fun `a heading of 360 or more is unknown`() {
        val frame = fixture.readBytes()
        frame[Protocol.HEADER_SIZE + 8] = 0xFF.toByte()
        frame[Protocol.HEADER_SIZE + 9] = 0xFF.toByte()

        val req = RerouteReq.parse(frame)!!

        assertNull(req.headingDeg)
        assertEquals("the neighboring field was not touched", 10432, req.distAlongM)
    }

    @Test
    fun `anything that is not a whole reroute request is refused`() {
        val frame = fixture.readBytes()

        assertNull("frame curto", RerouteReq.parse(frame.copyOf(frame.size - 1)))
        assertNull("frame with extra bytes", RerouteReq.parse(frame + 0))
        assertNull("another type", RerouteReq.parse(frame.clone().also { it[1] = Protocol.MSG_ACK.toByte() }))
        assertNull("another version", RerouteReq.parse(frame.clone().also { it[0] = (Protocol.VERSION + 1).toByte() }))
        assertNull("length mentiroso", RerouteReq.parse(frame.clone().also { it[7] = 13 }))
    }
}
