package dev.igor.motonav.proto

/**
 * NAV_START_REQ (0x83): Igor picked a favorite or a recent destination on the watch
 * (`05 §NAV_START_REQ`, C12 and C16.5). `routeId` 0.
 *
 * The mirror is `nav_start_req_frame` in `tools/packer.py`; the fixtures
 * `nav_start_req_00.bin` (favorite, 1 byte) and `nav_start_req_01.bin` (recent, 2 bytes)
 * are the same ones the watch reproduces byte for byte.
 *
 * @property favId the item's id in the list the phone sent (FAVORITES or RECENTS). The
 *   phone looks it up in its own storage: coordinates never come from the watch.
 * @property kind which list: [Protocol.NAV_START_KIND_FAVORITE] (C12's 1-byte frame)
 *   or [Protocol.NAV_START_KIND_RECENT].
 */
data class NavStartReq(val favId: Int, val kind: Int = Protocol.NAV_START_KIND_FAVORITE) {

    val recent: Boolean get() = kind == Protocol.NAV_START_KIND_RECENT

    companion object {
        /** C12's frame: just the `favId`, always a favorite. */
        const val PAYLOAD_SIZE = 1

        /** With the `kind` byte (C16.5). */
        const val PAYLOAD_SIZE_KIND = 2

        /**
         * Reads the whole frame, header included. `null` for anything that is
         * not a well-formed NAV_START_REQ (`05 §Robustness rules 4`), including
         * a `kind` that is neither 0 nor 1.
         */
        fun parse(frame: ByteArray): NavStartReq? {
            val payload = frame.size - Protocol.HEADER_SIZE
            if (payload != PAYLOAD_SIZE && payload != PAYLOAD_SIZE_KIND) {
                return null
            }
            if (u8(frame, 0) != Protocol.VERSION || u8(frame, 1) != Protocol.MSG_NAV_START_REQ) {
                return null
            }
            if (((u8(frame, 6) shl 8) or u8(frame, 7)) != payload) {
                return null
            }
            val favId = u8(frame, Protocol.HEADER_SIZE)
            if (payload == PAYLOAD_SIZE) {
                return NavStartReq(favId = favId)
            }
            val kind = u8(frame, Protocol.HEADER_SIZE + 1)
            if (kind != Protocol.NAV_START_KIND_FAVORITE && kind != Protocol.NAV_START_KIND_RECENT) {
                return null
            }
            return NavStartReq(favId = favId, kind = kind)
        }

        private fun u8(data: ByteArray, offset: Int): Int = data[offset].toInt() and 0xFF
    }
}
