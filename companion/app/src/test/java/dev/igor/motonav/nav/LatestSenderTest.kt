package dev.igor.motonav.nav

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Test

/** "Last one wins": what goes out is the newest value at the moment the turn on the link arrives. */
class LatestSenderTest {

    // prevents: with a corridor chunk in the air (about 9 s on the simulator, 5 s on Bluetooth), the
    // GPS fixes that waited all going out afterwards, queued, and the watch moving
    // backwards in a burst before reaching the current position.
    @Test
    fun whoWaitsForTheLinkSendsTheNewestValue() = runBlocking {
        val sent = mutableListOf<Int>()
        val turns = mutableListOf<CompletableDeferred<Unit>>()
        val sender = LatestSender<Int>(this) { take ->
            // The turn on the link: WatchLink's `sendMutex`, stuck behind a chunk.
            val turn = CompletableDeferred<Unit>().also { turns += it }
            turn.await()
            take()?.let { sent += it }
        }

        sender.offer(1)
        settle()
        assertEquals("the send waits its turn", 1, turns.size)
        sender.offer(2)
        sender.offer(3)
        settle()

        turns[0].complete(Unit)
        settle()
        assertEquals("the newest went out, not the first", listOf(3), sent)

        // The notices for 2 and 3 open on the link again, which has nothing to send.
        assertEquals(2, turns.size)
        turns[1].complete(Unit)
        settle()
        assertEquals(listOf(3), sent)

        sender.offer(4)
        settle()
        turns[2].complete(Unit)
        settle()
        assertEquals(listOf(3, 4), sent)
        coroutineContext.cancelChildren()
    }

    // prevents: the watch dismissing the phone and, seconds later, the fix that waited
    // behind a chunk still reaching it.
    @Test
    fun aClearedValueIsNotSent() = runBlocking {
        val sent = mutableListOf<Int>()
        val turn = CompletableDeferred<Unit>()
        val sender = LatestSender<Int>(this) { take ->
            turn.await()
            take()?.let { sent += it }
        }

        sender.offer(1)
        settle()
        sender.clear()
        turn.complete(Unit)
        settle()

        assertEquals(emptyList<Int>(), sent)
        coroutineContext.cancelChildren()
    }

    /** Lets the test coroutines run until they stop again (everything runs on the `runBlocking` thread). */
    private suspend fun settle() = repeat(10) { yield() }
}
