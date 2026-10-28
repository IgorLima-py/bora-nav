package dev.igor.motonav.proto

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The NAV_START_REQ reader against `nav_start_req_00.bin`, the fixture of
 * `NAV_START_REQ_SAMPLE` in `tools/packer.py` (favId 2). The watch builds the
 * same frame byte by byte (`NavStartReqTest.buildsTheFixture`, Monkey C).
 */
class NavStartReqTest {

    private val fixture = File("../../tools/fixtures/nav_start_req_00.bin")

    // prevents: reading the favId at the wrong offset (the header is 8 B) and starting navigation to
    // another favorite — the watch picks "Casa" and the phone routes to "Escritório".
    @Test
    fun navStartReqMatchesFixture() {
        assertEquals(2, NavStartReq.parse(fixture.readBytes())!!.favId)
    }

    // prevents: the phone obeying BLE garbage (05 §Robustness rules 4): a short frame, with
    // leftovers, of another type, of another version or with a lying `length` does not become navigation.
    @Test
    fun `anything that is not a whole nav start request is refused`() {
        val frame = fixture.readBytes()

        assertNull("frame curto", NavStartReq.parse(frame.copyOf(frame.size - 1)))
        assertNull("frame with extra bytes", NavStartReq.parse(frame + 0))
        assertNull("another type", NavStartReq.parse(frame.clone().also { it[1] = Protocol.MSG_ACK.toByte() }))
        assertNull("another version", NavStartReq.parse(frame.clone().also { it[0] = (Protocol.VERSION + 1).toByte() }))
        assertNull("length mentiroso", NavStartReq.parse(frame.clone().also { it[7] = 2 }))
    }

    // prevents: the watch picking a destination from "Recentes" (C16.5) and the phone routing to the favorite
    // with the same number; and an unknown `kind` becoming navigation to some place.
    @Test
    fun `a recent carries its kind and an unknown kind is refused`() {
        val recent = File("../../tools/fixtures/nav_start_req_01.bin").readBytes()
        val req = NavStartReq.parse(recent)!!
        assertEquals(3, req.favId)
        assertEquals(Protocol.NAV_START_KIND_RECENT, req.kind)
        assertEquals(Protocol.NAV_START_KIND_FAVORITE, NavStartReq.parse(fixture.readBytes())!!.kind)
        assertNull("kind 2", NavStartReq.parse(recent.clone().also { it[recent.size - 1] = 2 }))
    }
}
