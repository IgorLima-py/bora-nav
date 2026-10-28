package dev.igor.motonav.link

/**
 * The send rounds for **one block** (05 §Framing): sends the chunks, waits for the watch's
 * ACK and resends what the bitmap says is missing.
 *
 * Outside `WatchLink` so it can be tested: that class does not instantiate on the JVM, and until
 * C13b the bitmap resend had only run on paper.
 */
class BlockRounds(
    private val msgType: Int,
    private val chunkCount: Int,
    private val port: Port,
) {

    /** What the rounds need from the link. In the app, `WatchLink`; in the test, a fake watch. */
    interface Port {
        /** Opens the wait for this round's ACK, before the first chunk: the watch answers as soon as the block closes. */
        fun openAck()

        /** Sends chunk [index]. `false` = it did not leave the phone. */
        suspend fun send(index: Int): Boolean

        /** The ACK's bitmap, or `null` if none arrived within [timeoutMs]. */
        suspend fun awaitAck(timeoutMs: Long): ByteArray?

        /** Closes the wait, with or without an ACK: whatever arrives later is not from this round. */
        fun closeAck()

        fun nowMs(): Long

        fun log(line: String)
    }

    sealed interface Outcome {
        /** The watch confirmed the whole block, in [rounds] rounds. */
        data class Complete(val rounds: Int) : Outcome

        /** The block was not delivered; [reason] is what the screen shows. */
        data class Failed(val reason: String) : Outcome
    }

    /**
     * A **link drop** (the `send` did not leave the phone) ends the round, not the
     * transfer (C13b): it waits for the ACK for the usual deadline, which becomes the interval
     * between attempts, and opens another round with what the watch did not confirm.
     * A round with a drop counts toward neither [MAX_BLOCK_ROUNDS] nor [MAX_SILENT_ROUNDS]:
     * those two guard against a deaf watch, not a dropped link. What
     * limits the drop is time, [DROP_BUDGET_MS] since the last chunk delivered.
     */
    suspend fun run(): Outcome {
        var missing = (0 until chunkCount).toList()
        var rounds = 0
        var countedRounds = 0
        var silentRounds = 0
        var lastDeliveredMs = port.nowMs()
        while (missing.isNotEmpty()) {
            if (countedRounds >= MAX_BLOCK_ROUNDS) {
                return Outcome.Failed(NOT_CONFIRMED)
            }
            rounds++
            var droppedAt = -1
            port.openAck()
            // `finally`: a new share cancels this send in the middle of the
            // wait, and the pending ACK must not be left for the next one.
            val bitmap = try {
                for (index in missing) {
                    if (!port.send(index)) {
                        droppedAt = index
                        break
                    }
                    lastDeliveredMs = port.nowMs()
                }
                // With a drop we also wait: the chunk may have arrived before the
                // send failed, and then the full ACK comes; or the watch hit
                // its deadline and sends the bitmap of what it has.
                port.awaitAck(ACK_TIMEOUT_MS)
            } finally {
                port.closeAck()
            }
            if (bitmap != null) {
                missing = (0 until chunkCount).filterNot { bitmap.hasChunk(it) }
            }
            if (droppedAt >= 0) {
                port.log(
                    "block 0x%02X round %d: drop at chunk %d/%d%s".format(
                        msgType,
                        rounds,
                        droppedAt + 1,
                        chunkCount,
                        if (bitmap == null) "" else ", ACK ${bitmap.hexPrefix()}",
                    ),
                )
                if (missing.isNotEmpty() && port.nowMs() - lastDeliveredMs > DROP_BUDGET_MS) {
                    return Outcome.Failed(OUT_OF_REACH)
                }
                continue
            }
            port.log(
                "block 0x%02X round %d: %s".format(
                    msgType,
                    rounds,
                    if (bitmap == null) "no ACK in $ACK_TIMEOUT_MS ms" else "ACK ${bitmap.hexPrefix()}",
                ),
            )
            if (bitmap == null) {
                // Silence is different from a partial ACK: nobody is
                // listening on the other side (app closed on the watch, or an old
                // `.prg` without registerForPhoneAppMessages). GCM's
                // sendMessage returns SUCCESS anyway — the
                // message sits in the Connect IQ mailbox. One more attempt
                // covers a lost chunk; beyond that it is just dead time,
                // and the generic error sent people hunting in the wrong place.
                silentRounds++
                if (silentRounds >= MAX_SILENT_ROUNDS) {
                    return Outcome.Failed(WATCH_SILENT)
                }
                // `missing` intact: resend the whole block.
            } else {
                silentRounds = 0
            }
            countedRounds++
        }
        // The line that `tools/e2e.py --queda` reads: with N >= 2 the block went through a drop.
        port.log("block 0x%02X complete after %d rounds".format(msgType, rounds))
        return Outcome.Complete(rounds)
    }

    companion object {
        /** The watch ACKs as soon as the block closes; 8 s is already slack over BLE. */
        const val ACK_TIMEOUT_MS = 8_000L

        const val MAX_BLOCK_ROUNDS = 3

        /** Rounds without any ACK before giving up and saying why. */
        const val MAX_SILENT_ROUNDS = 2

        /**
         * How long the link drop may last, counted from the last chunk delivered: two
         * watch block deadlines (`Protocol.BLOCK_TIMEOUT_MS`, 30 s). That is its
         * memory: at the first deadline it sends the bitmap and keeps the block, at the second it drops it.
         */
        const val DROP_BUDGET_MS = 60_000L

        const val NOT_CONFIRMED = "Watch did not confirm the block"

        /** The link dropped and did not come back within [DROP_BUDGET_MS]. */
        const val OUT_OF_REACH = "Watch out of reach"

        const val WATCH_SILENT =
            "Watch did not respond. Open MotoNav on the watch and check that the version on screen is the same as here."
    }
}

/** The first bytes in hex, for the log. */
internal fun ByteArray.hexPrefix(): String =
    take(12).joinToString(" ") { "%02X".format(it) }

/** The bit of chunk [index] in an ACK bitmap (LSB first, 05 §ACK). */
internal fun ByteArray.hasChunk(index: Int): Boolean {
    val byteIndex = index / 8
    if (byteIndex >= size) {
        return false
    }
    return (this[byteIndex].toInt() shr (index % 8)) and 1 == 1
}
