package dev.igor.motonav.proto

/**
 * FIX_REQ (0x86): the watch is navigating without a fix of its own and asks for the phone's GPS,
 * or dismisses it (`05 §FIX_REQ`, C13b). One payload byte, `routeId` 0.
 *
 * The mirror is `fix_req_frame` in `tools/packer.py`; the fixture `fix_req_00.bin`
 * is the same one the watch reproduces byte for byte (`fixReqMatchesTheFixture`).
 *
 * @property on `true` = send PHONE_FIX; `false` = stop.
 */
data class FixReq(val on: Boolean) {
    companion object {
        const val PAYLOAD_SIZE = 1

        /**
         * Reads the whole frame, header included. `null` for anything that is
         * not a well-formed FIX_REQ (`05 §Robustness rules 4`), which includes a
         * byte that is neither 0 nor 1: turning the GPS on because of garbage costs battery, and
         * turning it off because of garbage removes the fallback for whoever has no fix.
         */
        fun parse(frame: ByteArray): FixReq? {
            if (frame.size != Protocol.HEADER_SIZE + PAYLOAD_SIZE) {
                return null
            }
            if (u8(frame, 0) != Protocol.VERSION || u8(frame, 1) != Protocol.MSG_FIX_REQ) {
                return null
            }
            if (((u8(frame, 6) shl 8) or u8(frame, 7)) != PAYLOAD_SIZE) {
                return null
            }
            return when (u8(frame, Protocol.HEADER_SIZE)) {
                1 -> FixReq(on = true)
                0 -> FixReq(on = false)
                else -> null
            }
        }

        private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    }
}
