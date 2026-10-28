package dev.igor.motonav.nav

/**
 * The phone's GPS as a backup for the watch's (`05 §FIX_REQ` and `§PHONE_FIX`, C13b): the
 * rule for when it turns on and off.
 *
 * **The watch is in charge.** It turns on at `FIX_REQ 1`; off at `FIX_REQ 0`, at the end of
 * navigation, or by itself after [LEASE_MS] without a renewal of the request, which is what protects
 * the battery when `FIX_REQ 0` is lost or the watch is turned off. The watch renews
 * every 20 s: one lost request fits in the deadline, two in a row do not.
 *
 * Only the rule lives here, with no Android or coroutine, so it can be tested; whoever really turns on the GPS and
 * sends the fix is the [Port] (`PhoneFixFeed`).
 */
class PhoneFixStreamer(private val port: Port) {

    interface Port {
        /** Why the phone's GPS cannot be read right now, or `null` if it can. */
        fun unavailable(): String?

        /** Starts asking Android for position. */
        fun startLocation()

        /** Stops asking for position and drops the fix still waiting for its turn. */
        fun stopLocation()

        fun nowMs(): Long

        fun log(line: String)
    }

    /** The phone is transmitting. */
    var active = false
        private set

    private var renewedMs = 0L
    private var startedMs = 0L
    private var fixes = 0

    /** The watch's `FIX_REQ`: [on] = send, otherwise stop. A renewal only stretches the deadline. */
    fun onFixReq(on: Boolean) {
        if (!on) {
            stop("the watch dismissed it")
            return
        }
        val reason = port.unavailable()
        if (reason != null) {
            // No refusal reply in the protocol: the watch keeps asking and carries on
            // without the backup. The line is what tells, afterwards, why it went without.
            port.log("PHONE_FIX unavailable: $reason")
            stop(reason)
            return
        }
        renewedMs = port.nowMs()
        if (active) {
            return
        }
        active = true
        startedMs = renewedMs
        fixes = 0
        port.log("PHONE_FIX on")
        port.startLocation()
    }

    /** Android gave a position. `true` = it goes to the watch. */
    fun onLocation(): Boolean {
        if (!active) {
            return false
        }
        if (expired()) {
            stop(NOT_RENEWED)
            return false
        }
        fixes++
        return true
    }

    /** From time to time, with or without a position arriving: without GPS the deadline also expires. */
    fun onTick() {
        if (active && expired()) {
            stop(NOT_RENEWED)
        }
    }

    /** The navigation ended (the watch arrived, ended it, or the session dropped). */
    fun onSessionEnded() = stop("navigation ended")

    /** Android refused or dropped the position request. */
    fun onFailure(reason: String) = stop(reason)

    private fun expired(): Boolean = port.nowMs() - renewedMs > LEASE_MS

    private fun stop(reason: String) {
        if (!active) {
            return
        }
        active = false
        port.stopLocation()
        port.log("PHONE_FIX off: $reason, $fixes fixes in ${(port.nowMs() - startedMs) / 1000} s")
    }

    companion object {
        /**
         * Two and a half intervals of the watch's request (`FixFallback.RENEW_MS`, 20 s). With
         * exactly 40 s a single lost request already took down the backup: the watch decides
         * on a 1 s tick, so it renews every 20 to 21 s, and with one lost the next
         * arrives at 41 s or more, not counting radio time.
         */
        const val LEASE_MS = 50_000L

        private const val NOT_RENEWED = "50 s without the request being renewed"
    }
}
