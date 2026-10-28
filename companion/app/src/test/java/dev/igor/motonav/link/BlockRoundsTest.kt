package dev.igor.motonav.link

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The send rounds of a block against a fake watch that does what the real one does
 * (`MessageAssembler.checkTimeouts`): full ACK when the block closes,
 * bitmap of what arrived after 30 s of silence, and block dropped at 60 s. The test
 * clock is the fake's: nothing here sleeps.
 */
class BlockRoundsTest {

    private class FakeWatch(private val chunkCount: Int) : BlockRounds.Port {
        var now = 0L

        /** The link is down in `[downFrom, downUntil)`: `send` fails right away, like the dead socket of `TETHERED`. */
        var downFrom = Long.MAX_VALUE
        var downUntil = Long.MAX_VALUE

        /** The watch app is closed: `send` succeeds and nobody answers. */
        var deaf = false

        /** Chunks whose `send` returns failure **after** the watch has received them. */
        var failsButDelivers = emptySet<Int>()

        /** When not null, the ACKs come from here, in order, one per round, and the simulated watch stays out. */
        var scriptedAcks: ArrayDeque<ByteArray?>? = null

        /** What left the phone successfully, round by round. */
        val rounds = mutableListOf<MutableList<Int>>()
        val log = mutableListOf<String>()

        private var buffer = BooleanArray(chunkCount)
        private var lastChunkAt = 0L
        private var partialAcked = false
        private var pendingAck: ByteArray? = null
        private var open = false

        val delivered: List<Int> get() = rounds.flatten()

        override fun openAck() {
            open = true
            rounds += mutableListOf<Int>()
        }

        override suspend fun send(index: Int): Boolean {
            if (now in downFrom until downUntil) {
                advance(now + FAIL_MS)
                return false
            }
            advance(now + SEND_MS)
            if (!deaf) {
                receive(index)
            }
            if (index in failsButDelivers) {
                return false
            }
            rounds.last() += index
            return true
        }

        override suspend fun awaitAck(timeoutMs: Long): ByteArray? {
            check(open) { "ACK wait with no open round" }
            scriptedAcks?.let {
                advance(now + 1)
                return it.removeFirst()
            }
            val deadline = now + timeoutMs
            if (pendingAck == null && buffer.any { it } && !partialAcked && lastChunkAt + WATCH_TIMEOUT_MS < deadline) {
                advance(lastChunkAt + WATCH_TIMEOUT_MS + 1)
            }
            pendingAck?.let {
                pendingAck = null
                return it
            }
            advance(deadline)
            return null
        }

        override fun closeAck() {
            open = false
        }

        override fun nowMs(): Long = now

        override fun log(line: String) {
            log += line
        }

        private fun receive(index: Int) {
            buffer[index] = true
            lastChunkAt = now
            partialAcked = false
            if (buffer.all { it }) {
                pendingAck = bitmapOf(buffer)
                buffer = BooleanArray(chunkCount)
            }
        }

        /** Time moves on, and the watch checks its deadlines, as in the 1 s tick. */
        private fun advance(to: Long) {
            now = to
            if (buffer.any { it } && now - lastChunkAt > WATCH_TIMEOUT_MS) {
                if (partialAcked) {
                    buffer = BooleanArray(chunkCount)
                    partialAcked = false
                } else {
                    pendingAck = bitmapOf(buffer)
                    partialAcked = true
                    lastChunkAt += WATCH_TIMEOUT_MS
                }
            }
        }
    }

    private val watch = FakeWatch(CHUNKS)

    private fun run(): BlockRounds.Outcome = runBlocking { BlockRounds(0x04, CHUNKS, watch).run() }

    // prevents: the line that `e2e.py --queda` reads coming out different from what it looks for, or not coming out in the normal case.
    @Test
    fun aCleanBlockCompletesInOneRound() {
        assertEquals(BlockRounds.Outcome.Complete(1), run())
        assertEquals((0 until CHUNKS).toList(), watch.delivered)
        assertTrue(watch.log.toString(), "block 0x04 complete after 1 rounds" in watch.log)
    }

    // prevents: a link drop in the middle of the block killing the transfer ("Falha ao enviar") instead of
    // waiting for the link to return; and the drop rounds counting as a deaf watch and aborting after two.
    @Test
    fun aDropInTheMiddleOfTheBlockOpensAnotherRound() {
        // Chunk 0 goes out (t = 1 s), the link drops and comes back 15 s later.
        watch.downFrom = 500
        watch.downUntil = 15_500

        assertEquals(BlockRounds.Outcome.Complete(3), run())
        assertTrue(watch.log.toString(), "block 0x04 round 1: drop at chunk 2/$CHUNKS" in watch.log)
        assertTrue(watch.log.toString(), "block 0x04 complete after 3 rounds" in watch.log)
        assertEquals("the last round resends the block: nothing was confirmed", (0 until CHUNKS).toList(), watch.rounds.last())
    }

    // prevents: after the watch sends the bitmap (30 s of silence), the phone resending the whole block
    // instead of only what is missing, or giving up before the link returns.
    @Test
    fun aLongDropResendsOnlyWhatTheBitmapSaysIsMissing() {
        watch.downFrom = 500
        watch.downUntil = 45_500

        val outcome = run()
        assertTrue("$outcome\n${watch.log}", outcome is BlockRounds.Outcome.Complete)
        assertTrue(watch.log.toString(), watch.log.any { "drop at chunk" in it && it.endsWith("ACK 01") })
        assertEquals("only the complement goes out in the last round", (1 until CHUNKS).toList(), watch.rounds.last())
        assertEquals("chunk 0 went out only once", 1, watch.delivered.count { it == 0 })
    }

    // prevents: insisting with no deadline on a downed link, holding up the reroute with a stale position.
    @Test
    fun aDropLongerThanTheBudgetFailsWithTheReason() {
        watch.downFrom = 500

        assertEquals(BlockRounds.Outcome.Failed(BlockRounds.OUT_OF_REACH), run())
        assertTrue("gave up after ${watch.now} ms", watch.now in 60_000..75_000)
        assertTrue(watch.log.toString(), watch.log.none { "complete" in it })
    }

    // prevents: the drop deadline counting from the start of the block instead of the last delivered chunk: a
    // long block that arrives slowly would be abandoned with the link alive.
    @Test
    fun theDropBudgetCountsFromTheLastDeliveredChunk() {
        // Drops after chunk 5 goes out (t = 6 s) and comes back 50 s later.
        watch.downFrom = 5_500
        watch.downUntil = 55_500

        val outcome = run()
        assertTrue("$outcome\n${watch.log}", outcome is BlockRounds.Outcome.Complete)
    }

    // prevents: the `send` that returns failure with the chunk already delivered (the socket died after writing)
    // becoming a resend of the whole block: the full ACK arrives during the wait, and the block is complete.
    @Test
    fun aFailedSendWhoseChunkArrivedStillCompletes() {
        watch.failsButDelivers = setOf(CHUNKS - 1)

        assertEquals(BlockRounds.Outcome.Complete(1), run())
        assertTrue(watch.log.toString(), "block 0x04 complete after 1 rounds" in watch.log)
    }

    // prevents: the deaf watch rule (app closed on the watch) getting lost in the refactor: it remains
    // two silent rounds and the error that tells to open the app.
    @Test
    fun twoSilentRoundsStillAbort() {
        watch.deaf = true

        assertEquals(BlockRounds.Outcome.Failed(BlockRounds.WATCH_SILENT), run())
        assertEquals(2, watch.rounds.size)
        assertEquals(2 * CHUNKS, watch.delivered.size)
    }

    // prevents: a watch that always answers the same incomplete bitmap holding up the send forever.
    @Test
    fun threePartialRoundsStillAbort() {
        watch.scriptedAcks = ArrayDeque(List(5) { byteArrayOf(0x03) })

        assertEquals(BlockRounds.Outcome.Failed(BlockRounds.NOT_CONFIRMED), run())
        assertEquals(3, watch.rounds.size)
        assertEquals("from the second round on, only what is missing", (2 until CHUNKS).toList(), watch.rounds.last())
    }

    private companion object {
        const val CHUNKS = 7

        /** A 4 KB chunk on `TETHERED` takes ~9 s; here 1 s, so the test's math fits in your head. */
        const val SEND_MS = 1_000L

        /** Dead socket: the 3 attempts of `sendOne` fail in milliseconds (`DECISIONS` §C11). */
        const val FAIL_MS = 1L

        /** The watch's `Protocol.BLOCK_TIMEOUT_MS`. */
        const val WATCH_TIMEOUT_MS = 30_000L

        fun bitmapOf(received: BooleanArray): ByteArray {
            val bytes = ByteArray((received.size + 7) / 8)
            received.forEachIndexed { index, got ->
                if (got) {
                    bytes[index / 8] = (bytes[index / 8].toInt() or (1 shl (index % 8))).toByte()
                }
            }
            return bytes
        }
    }
}
