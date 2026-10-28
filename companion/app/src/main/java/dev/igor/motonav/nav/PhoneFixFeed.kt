package dev.igor.motonav.nav

import android.os.SystemClock
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.geo.PhoneFix
import dev.igor.motonav.link.PhoneFixSent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

/**
 * The [PhoneFixStreamer] wired to Android (C13b): the position request to Fused, the
 * send to the watch and the deadline clock. The rule is in `PhoneFixStreamer`; this is
 * only wiring, and that is why it has no JVM test (what proves it is `tools/e2e.py --sem-fix`).
 *
 * Everything on the main thread, like `RerouteController`.
 *
 * @param updates one fix per second while someone collects (`LocationSource.updates`).
 * @param whyNot why the GPS cannot be read right now, or `null`.
 * @param send sends the watch the fix that `take` returns when its turn on the link
 *   comes (`WatchLink.sendPhoneFix`); `null` = there was nothing to send.
 * @param keepCoordinates the coordinate only goes to the log in the `sim` variant: on the S25 it
 *   is Igor's position (08 §Conventions).
 */
class PhoneFixFeed(
    private val scope: CoroutineScope,
    private val updates: () -> Flow<PhoneFix>,
    private val whyNot: () -> String?,
    private val send: suspend (take: () -> PhoneFix?) -> PhoneFixSent?,
    private val keepCoordinates: Boolean,
) : PhoneFixStreamer.Port {

    private val streamer = PhoneFixStreamer(this)
    private val sender = LatestSender<PhoneFix>(scope) { take -> deliver(take) }
    private var job: Job? = null

    fun onFixReq(on: Boolean) = streamer.onFixReq(on)

    fun onSessionEnded() = streamer.onSessionEnded()

    override fun unavailable(): String? = whyNot()

    override fun startLocation() {
        job = scope.launch {
            launch {
                while (true) {
                    delay(LEASE_CHECK_MS)
                    streamer.onTick()
                }
            }
            try {
                updates().collect { fix ->
                    if (streamer.onLocation()) {
                        sender.offer(fix)
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // `SecurityException` (the permission dropped) or Play Services refusing.
                streamer.onFailure("Android refused the location (${e.javaClass.simpleName})")
            }
        }
    }

    override fun stopLocation() {
        job?.cancel()
        job = null
        sender.clear()
    }

    override fun nowMs(): Long = SystemClock.elapsedRealtime()

    override fun log(line: String) = EventLog.i(TAG, line)

    private suspend fun deliver(take: () -> PhoneFix?) {
        // `active` is read already holding the link's turn: a fix that waited behind a
        // chunk does not go out after the watch has dismissed the phone.
        val sent = send { if (streamer.active) take() else null } ?: return
        val place = if (keepCoordinates) {
            ", at ${sent.fix.latE5},${sent.fix.lonE5} at ${sent.fix.speedDms} dm/s heading ${sent.fix.headingDeg ?: "?"}"
        } else {
            ""
        }
        if (sent.ok) {
            log("PHONE_FIX sent: age ${sent.ageMs} ms, accuracy ${sent.fix.accuracyM} m$place")
        } else {
            log("PHONE_FIX not sent: age ${sent.ageMs} ms")
        }
    }

    private companion object {
        const val TAG = "PhoneFix"

        /** How often the request's deadline is checked with no position arriving. */
        const val LEASE_CHECK_MS = 5_000L
    }
}
