package dev.igor.motonav.proto

/**
 * REROUTE_REQ (0x82): the watch left the route and asks for another (`05 §REROUTE_REQ`, C11).
 *
 * It is the first watch -> phone message with a real payload, and therefore the
 * first with a reader on this side. The mirror is `unpack_reroute_req` in
 * `tools/packer.py`; the fixture `reroute_req_00.bin` is the same one the watch
 * has to reproduce byte for byte (`rerouteReqMatchesTheFixture`).
 *
 * @property routeId from the header: the route [distAlongM] refers to.
 * @property headingDeg heading in degrees, or `null` if the watch did not have one yet.
 * @property distAlongM meters along the route at the last fix where the watch
 *   was on it — this is how we know which stops are already behind.
 */
data class RerouteReq(
    val routeId: Int,
    val latE5: Int,
    val lonE5: Int,
    val headingDeg: Int?,
    val distAlongM: Int,
) {
    companion object {
        const val PAYLOAD_SIZE = 14

        /**
         * Reads the whole frame, header included. `null` for anything that is not
         * a well-formed REROUTE_REQ: what comes from the watch is as
         * untrustworthy as what goes to it (`05 §Robustness rules 4`).
         */
        fun parse(frame: ByteArray): RerouteReq? {
            if (frame.size != Protocol.HEADER_SIZE + PAYLOAD_SIZE) {
                return null
            }
            if (u8(frame, 0) != Protocol.VERSION || u8(frame, 1) != Protocol.MSG_REROUTE_REQ) {
                return null
            }
            if (u16(frame, 6) != PAYLOAD_SIZE) {
                return null
            }
            val body = Protocol.HEADER_SIZE
            val heading = u16(frame, body + 8)
            val distAlong = s32(frame, body + 10)
            if (distAlong < 0) {
                // uint32 above 2^31 m: no route is 2 million km long.
                return null
            }
            return RerouteReq(
                routeId = u16(frame, 2),
                latE5 = s32(frame, body),
                lonE5 = s32(frame, body + 4),
                headingDeg = heading.takeIf { it < 360 },
                distAlongM = distAlong,
            )
        }

        private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF

        private fun u16(data: ByteArray, offset: Int): Int = (u8(data, offset) shl 8) or u8(data, offset + 1)

        private fun s32(data: ByteArray, offset: Int): Int =
            (u8(data, offset) shl 24) or (u8(data, offset + 1) shl 16) or
                (u8(data, offset + 2) shl 8) or u8(data, offset + 3)
    }
}
