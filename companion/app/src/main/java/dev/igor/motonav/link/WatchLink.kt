package dev.igor.motonav.link

import android.content.Context
import android.content.pm.PackageManager
import android.os.SystemClock
import android.util.Base64
import com.garmin.android.connectiq.ConnectIQ
import com.garmin.android.connectiq.IQApp
import com.garmin.android.connectiq.IQDevice
import com.garmin.android.connectiq.exception.InvalidStateException
import com.garmin.android.connectiq.exception.ServiceUnavailableException
import dev.igor.motonav.BuildConfig
import dev.igor.motonav.MotoNavIds
import dev.igor.motonav.diag.EventLog
import dev.igor.motonav.geo.PhoneFix
import dev.igor.motonav.proto.FixReq
import dev.igor.motonav.proto.NavStartReq
import dev.igor.motonav.proto.PackableCorridor
import dev.igor.motonav.proto.PackableRoute
import dev.igor.motonav.proto.Protocol
import dev.igor.motonav.proto.ProtocolPacker
import dev.igor.motonav.proto.RerouteReq
import dev.igor.motonav.proto.WireFavorite
import dev.igor.motonav.proto.WireRadar
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.resume
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

/** A PHONE_FIX that got its turn on the link: what it was, how old it was when it went out, and whether `sendMessage` worked. */
data class PhoneFixSent(val fix: PhoneFix, val ageMs: Int, val ok: Boolean)

/** Why the SDK cannot talk to the watch. Each maps to a hint on screen. */
enum class SdkProblem {
    GCM_NOT_INSTALLED,
    GCM_NEEDS_UPGRADE,
    SERVICE_ERROR,
    SDK_SHUT_DOWN,
}

/** A watch known to Garmin Connect Mobile. [appInstalled] is null while unknown. */
data class WatchDevice(
    val id: Long,
    val name: String,
    val connected: Boolean,
    val appInstalled: Boolean? = null,
)

data class LinkState(
    val initializing: Boolean = true,
    val problem: SdkProblem? = null,
    val devices: List<WatchDevice> = emptyList(),
)

/** The [TransferProgress.error] for when there is no watch: the screen swaps it for the text in its language. */
const val NOT_CONNECTED = "Watch not connected"

/** Progress of one route transfer, for the UI and for the F1 measurements. */
data class TransferProgress(
    val sentChunks: Int = 0,
    val totalChunks: Int = 0,
    val sentBytes: Int = 0,
    val elapsedMs: Long = 0,
    val done: Boolean = false,
    val error: String? = null,
)

/**
 * Wrapper around the Connect IQ Android SDK (docs/04-COMPANION-APP.md §4).
 *
 * Sends one message at a time, gated by the send callback, and only moves to
 * the next block once the watch ACKs the current one. The ACK carries a bitmap
 * of the chunks that arrived, so a dropped chunk costs a resend of that chunk
 * and not of the whole route (docs/05-PROTOCOL.md §Framing).
 *
 * **One instance per process** — use [WatchLink.of]. `ConnectIQ.getInstance`
 * returns a singleton, so two instances fought over the same SDK: the share screen's
 * `onDestroy` called `unregisterAllForEvents` +
 * `shutdown` and also took down `MainActivity`'s link. Practical effect: with the
 * app open, the second share did not work until the process was killed.
 */
class WatchLink private constructor(private val context: Context) {

    private val connectIQ: ConnectIQ = ConnectIQ.getInstance(
        context,
        if (BuildConfig.CIQ_TETHERED) ConnectIQ.IQConnectType.TETHERED else ConnectIQ.IQConnectType.WIRELESS,
    )

    private val watchApp = IQApp(MotoNavIds.WATCH_APP_UUID)

    /**
     * The app as it appears **in incoming messages**. On `TETHERED` the
     * simulator sends an empty app ID, and `registerForAppEvents` with the UUID
     * never fires (known bug; workaround `IQApp("")`, `DECISIONS.md`
     * §2026-09-11). **Not exercised in C7a**: in the SDK 9.2.0 simulator the watch's
     * `transmit` freezes the app before any byte gets here, and
     * watch → phone goes through [relayFromWatch]. Left for the day the
     * simulator is fixed. The send carries no ID at all on `TETHERED`.
     */
    private val eventsApp = if (BuildConfig.CIQ_TETHERED) IQApp("") else watchApp

    /**
     * Where `sendMessage` is called. On `TETHERED` the SDK writes to the adb
     * socket **on the calling thread**, and the main one dies with
     * `NetworkOnMainThreadException` (measured in C7a, 2026-10-09). On `WIRELESS`
     * the sender is the Garmin Connect service, and nothing changes.
     */
    private val sendContext: CoroutineContext =
        if (BuildConfig.CIQ_TETHERED) Dispatchers.IO else EmptyCoroutineContext

    private val _state = MutableStateFlow(LinkState())
    val state: StateFlow<LinkState> = _state.asStateFlow()

    private var started = false
    private var target: IQDevice? = null

    /**
     * Pending ACKs keyed by the block msgType. Each one keeps the block's `routeId`:
     * a late ACK from the old route arriving in the middle of the new one (C11) would complete the
     * wrong block and the new route would carry on without having been confirmed.
     */
    private class PendingAck(val routeId: Int, val deferred: CompletableDeferred<ByteArray>)

    private val pendingAcks = mutableMapOf<Int, PendingAck>()

    /** Who holds the `sendMessage` turn ([sendAwait]). */
    private val sendMutex = Mutex()

    /**
     * Who handles what only the watch sends (C11). Wired by `RerouteHub`; null
     * where it does not exist (test), and the message only goes to the log.
     */
    @Volatile
    var onRerouteReq: ((RerouteReq) -> Unit)? = null

    /** Each line of the watch's `LOG`, after going to `motonav.log` (C16.5: the trips' battery). */
    @Volatile
    var onWatchLog: ((String) -> Unit)? = null

    /** The watch ended the navigation; the argument is the reason (`Protocol.NAV_ENDED_*`, -1 with no payload). */
    @Volatile
    var onNavEnded: ((Int) -> Unit)? = null

    /** Igor chose a favorite on the watch (C12). */
    @Volatile
    var onNavStartReq: ((NavStartReq) -> Unit)? = null

    /** The watch asks for or dismisses the phone's GPS (C13b). */
    @Volatile
    var onFixReq: ((FixReq) -> Unit)? = null

    /**
     * The watch showed up connected and with MotoNav installed: time to send again
     * what it keeps on its own (FAVORITES on every connection, `04 §Favorites`).
     */
    @Volatile
    var onWatchReady: (() -> Unit)? = null

    /**
     * Devices already registered in `registerForAppEvents`. Without this control, every
     * `sendRoute` registered again and the same ACK arrived several times — that is the
     * "known pending item" in STATUS, which only goes away with the single instance.
     */
    private val listening = mutableSetOf<Long>()

    fun start() {
        if (started) {
            return
        }
        started = true
        // showErrorDialogs = false: the UI explains what is missing instead.
        connectIQ.initialize(context, false, object : ConnectIQ.ConnectIQListener {
            override fun onSdkReady() {
                refreshDevices()
            }

            override fun onInitializeError(status: ConnectIQ.IQSdkErrorStatus?) {
                _state.value = LinkState(initializing = false, problem = status.toProblem())
            }

            override fun onSdkShutDown() {
                _state.value = _state.value.copy(problem = SdkProblem.SDK_SHUT_DOWN)
            }
        })
    }

    /**
     * Takes the SDK down. **No Activity should call this**: `ConnectIQ` is a
     * process singleton, so shutting it down here kills every screen's link —
     * it was what forced closing the app between one share and the next. The link
     * lives as long as the process; Android reclaims everything together when it kills
     * the process. It stays public only for a future explicit shutdown.
     */
    fun stop() {
        if (!started) {
            return
        }
        started = false
        listening.clear()
        try {
            connectIQ.unregisterAllForEvents()
            connectIQ.shutdown(context)
        } catch (e: InvalidStateException) {
            EventLog.w(TAG, "shutdown on a non-initialized SDK", e)
        }
    }

    /** Re-reads the paired devices; safe to call from the UI. */
    fun refreshDevices() {
        val known = try {
            connectIQ.knownDevices ?: emptyList()
        } catch (e: InvalidStateException) {
            EventLog.w(TAG, "knownDevices before the SDK was ready", e)
            _state.value = LinkState(initializing = false, problem = SdkProblem.SERVICE_ERROR)
            return
        } catch (e: ServiceUnavailableException) {
            EventLog.w(TAG, "Garmin Connect service unavailable", e)
            _state.value = LinkState(initializing = false, problem = SdkProblem.SERVICE_ERROR)
            return
        }

        _state.value = LinkState(
            initializing = false,
            problem = null,
            devices = known.map { WatchDevice(it.deviceIdentifier, it.friendlyName ?: "", isConnected(it)) },
        )

        known.forEach { device ->
            connectIQ.registerForDeviceEvents(device) { changed, status ->
                // Same care as the message callback: it comes from an
                // SDK BroadcastReceiver and whatever escapes takes the app down.
                try {
                    val connected = status == IQDevice.IQDeviceStatus.CONNECTED
                    // C16: Bluetooth dropping and coming back stays in `motonav.log` without Igor having to report it.
                    EventLog.i(TAG, "watch ${changed?.friendlyName ?: device.friendlyName}: $status")
                    updateDevice(changed?.deviceIdentifier ?: device.deviceIdentifier) {
                        it.copy(connected = connected)
                    }
                    if (connected) {
                        queryAppInstalled(changed ?: device)
                    }
                } catch (e: Exception) {
                    EventLog.e(TAG, "failed to handle device event", e)
                }
            }
            if (isConnected(device)) {
                target = device
                listenForWatchMessages(device)
                queryAppInstalled(device)
            }
        }
    }

    /**
     * Sends META, POLY and TURNS in order (ADR-3), resending only the chunks the
     * watch reports as missing. Returns true when the whole route landed.
     */
    suspend fun sendRoute(
        route: PackableRoute,
        corridor: PackableCorridor? = null,
        onProgress: (TransferProgress) -> Unit,
    ): Boolean = sendBlocks(
        ProtocolPacker.buildRouteBlocks(route, corridor = corridor),
        route.routeId,
        onProgress,
    )

    /**
     * Only the corridor, for a route that is **already on the watch**.
     *
     * It exists because the corridor stopped blocking the route: public Overpass
     * answered **once in six** in Igor's tests, and each failure cost
     * 25–27 s of waiting *before* the route left the phone. Now the route goes
     * first and the scenery arrives when (and if) it arrives — which is exactly what
     * `01 §RNF-02` always asked for: "usable route ≤10 s; corridor may keep
     * arriving in the background".
     *
     * The watch already accepted this with no change at all: it applies a CORRIDOR for a
     * `routeId` that has a META, and redraws.
     */
    suspend fun sendCorridor(
        route: PackableRoute,
        corridor: PackableCorridor,
        onProgress: (TransferProgress) -> Unit = {},
    ): Boolean = sendBlocks(
        ProtocolPacker.buildCorridorBlocks(route, corridor),
        route.routeId,
        onProgress,
    )

    /**
     * The route's speed cameras (05 §RADARS, C16.6), after the corridor and the same way: by `routeId`, and
     * the watch keeps those of a route still being prepared until the swap.
     */
    suspend fun sendRadars(route: PackableRoute, radars: List<WireRadar>): Boolean = sendBlocks(
        listOf(ProtocolPacker.buildRadarsBlock(route.routeId, radars)),
        route.routeId,
    ) { }

    /**
     * Wireless fine-tuning (05 §CONFIG): entries (key id, value) from
     * [ConfigKey.parse]. An empty list returns the watch to its defaults. The ACK only says that
     * the message arrived; if the watch refused a value, the line
     * `WATCH|config refused ...` appears in `motonav.log`.
     */
    suspend fun sendConfig(
        entries: List<Pair<Int, Int>>,
        onProgress: (TransferProgress) -> Unit = {},
    ): Boolean = sendBlocks(listOf(ProtocolPacker.buildConfigBlock(entries)), 0, onProgress)

    /**
     * FAVORITES (05 §FAVORITES, C12): the whole list replaces the watch's. An empty
     * list empties the Favorites screen. The ACK only says the message arrived; if the
     * watch refused it, the line `WATCH|favorites refused ...` appears in the log.
     */
    suspend fun sendFavorites(
        items: List<WireFavorite>,
        onProgress: (TransferProgress) -> Unit = {},
    ): Boolean = sendBlocks(listOf(ProtocolPacker.buildFavoritesBlock(items)), 0, onProgress)

    /**
     * RECENTS (05 §RECENTS, C16.5): the latest destinations, for the watch's "Recent" screen. Like
     * FAVORITES, the whole list replaces the previous one.
     */
    suspend fun sendRecents(items: List<WireFavorite>): Boolean =
        sendBlocks(listOf(ProtocolPacker.buildRecentsBlock(items)), 0) { }

    /**
     * ROUTE_UPDATE (05 §ROUTE_UPDATE, C13a): the new duration of route [routeId].
     *
     * **One send and one wait, no rounds**: an empty-bitmap ACK here is not
     * "chunk missing", it is the watch saying it is not navigating this route, and resending
     * does not change the answer. The next tick of the loop is what tries again.
     *
     * It also does not go through [sendBlocks] because of the log: that send line and
     * the missing-ACK one are what `tools/e2e.py` reads to judge the route send.
     */
    suspend fun sendRouteUpdate(routeId: Int, durationS: Int): UpdateResult {
        val device = target ?: connectedDevice() ?: return UpdateResult.NOT_CONNECTED
        listenForWatchMessages(device)
        val block = ProtocolPacker.buildRouteUpdateBlock(routeId, durationS)
        val ack = CompletableDeferred<ByteArray>()
        pendingAcks[block.msgType] = PendingAck(routeId, ack)
        val bitmap = try {
            if (!sendOne(device, block.chunks[0])) {
                return UpdateResult.SEND_FAILED
            }
            withTimeoutOrNull(BlockRounds.ACK_TIMEOUT_MS) { ack.await() }
        } finally {
            pendingAcks.remove(block.msgType)
        }
        return updateResultOf(bitmap)
    }

    /**
     * PHONE_FIX (05 §PHONE_FIX, C13b): a position from the phone's GPS.
     *
     * **One `sendMessage`, no ACK, no retry and no `chunk` line in the log**:
     * one goes out per second, and the next one is the retry. The fix is chosen by
     * [take] **already holding the link's turn** ([sendMutex]): with a corridor chunk in the air
     * the wait is seconds, and what goes out must be the position of now, not the one from
     * when the wait began. The age is also that of the moment it goes out.
     *
     * `null` = there was no watch, or [take] had nothing to send.
     */
    suspend fun sendPhoneFix(take: () -> PhoneFix?): PhoneFixSent? {
        val device = target ?: connectedDevice() ?: return null
        return sendMutex.withLock {
            val fix = take() ?: return@withLock null
            val ageMs = (SystemClock.elapsedRealtime() - fix.fixElapsedMs).coerceIn(0L, 0xFFFFL).toInt()
            val block = ProtocolPacker.buildPhoneFixBlock(
                fix.latE5, fix.lonE5, fix.speedDms, fix.headingDeg, fix.accuracyM, ageMs,
            )
            val status = withTimeoutOrNull(SEND_TIMEOUT_MS) { sendLocked(device, wire(block.chunks[0])) }
            PhoneFixSent(fix, ageMs, status == ConnectIQ.IQMessageStatus.SUCCESS)
        }
    }

    /**
     * A raw String, outside the protocol: the bridge's proof message (C7a,
     * `tools/ponte.py`). Returns the status of `sendMessage`, without waiting for an ACK.
     */
    suspend fun sendProbe(text: String): Boolean {
        val device = target ?: connectedDevice()
        if (device == null) {
            EventLog.w(TAG, "probe not sent: no watch connected")
            return false
        }
        listenForWatchMessages(device)
        val status = sendAwait(device, listOf(text))
        EventLog.i(TAG, "probe $text to ${device.friendlyName}: $status")
        return status == ConnectIQ.IQMessageStatus.SUCCESS
    }

    private suspend fun sendBlocks(
        blocks: List<ProtocolPacker.Block>,
        routeId: Int,
        onProgress: (TransferProgress) -> Unit,
    ): Boolean {
        if (blocks.isEmpty()) {
            onProgress(TransferProgress(done = true))
            return true
        }
        val device = target ?: connectedDevice()
        if (device == null) {
            onProgress(TransferProgress(error = NOT_CONNECTED))
            return false
        }
        listenForWatchMessages(device)

        val totalChunks = blocks.sumOf { it.chunks.size }
        EventLog.i(
            TAG,
            "sending route $routeId to ${device.friendlyName}: " +
                blocks.joinToString(", ") { "0x%02X=%d chunk(s)".format(it.msgType, it.chunks.size) },
        )
        val startedAt = System.currentTimeMillis()
        var sentChunks = 0
        var sentBytes = 0

        for (block in blocks) {
            var ack: CompletableDeferred<ByteArray>? = null
            val port = object : BlockRounds.Port {
                override fun openAck() {
                    val deferred = CompletableDeferred<ByteArray>()
                    ack = deferred
                    pendingAcks[block.msgType] = PendingAck(routeId, deferred)
                }

                override suspend fun send(index: Int): Boolean {
                    val chunk = block.chunks[index]
                    if (!sendOne(device, chunk)) {
                        return false
                    }
                    sentChunks++
                    sentBytes += chunk.size
                    onProgress(
                        TransferProgress(
                            sentChunks = sentChunks,
                            totalChunks = totalChunks,
                            sentBytes = sentBytes,
                            elapsedMs = System.currentTimeMillis() - startedAt,
                        ),
                    )
                    return true
                }

                override suspend fun awaitAck(timeoutMs: Long): ByteArray? =
                    withTimeoutOrNull(timeoutMs) { ack?.await() }

                override fun closeAck() {
                    pendingAcks.remove(block.msgType)
                }

                override fun nowMs(): Long = SystemClock.elapsedRealtime()

                override fun log(line: String) = EventLog.i(TAG, line)
            }
            val outcome = BlockRounds(block.msgType, block.chunks.size, port).run()
            if (outcome is BlockRounds.Outcome.Failed) {
                onProgress(TransferProgress(sentChunks, totalChunks, sentBytes, error = outcome.reason))
                return false
            }
        }

        onProgress(
            TransferProgress(
                sentChunks = sentChunks,
                totalChunks = totalChunks,
                sentBytes = sentBytes,
                elapsedMs = System.currentTimeMillis() - startedAt,
                done = true,
            ),
        )
        return true
    }

    /**
     * The binary frame travels **in Base64 inside a String**.
     *
     * `sendMessage(..., listOf(byteArray))` reached the watch in a format that
     * Monkey C could not read: `PhoneAppMessage.data` was neither a ByteArray nor an Array of
     * ByteArray, and the app silently discarded the message (attempt 2 on the road:
     * `rx 2 · ack 0/0`, "formato inesperado", i.e. unexpected format). String is the only type that both
     * SDKs carry without ambiguity. Cost: +33% bytes on the air, irrelevant for
     * the ~2.4 KB of an urban route. The binary format of `05-PROTOCOL.md` and the
     * fixtures do not change — this is the transport layer, not the protocol.
     */
    private fun wire(payload: ByteArray): List<String> =
        listOf(Base64.encodeToString(payload, Base64.NO_WRAP))

    /**
     * A `sendMessage`, waiting for the SDK callback. `null` = the SDK threw.
     *
     * **One message in flight at a time** (05 §Transport), guaranteed here by
     * [sendMutex] and no longer only by the caller's discipline (C13b): the corridor
     * takes close to a minute, and whatever needs to go out in the middle of it waits its turn
     * between one chunk and the next instead of going in alongside.
     */
    private suspend fun sendAwait(device: IQDevice, message: List<String>): ConnectIQ.IQMessageStatus? =
        sendMutex.withLock { sendLocked(device, message) }

    /** The `sendMessage` itself. The caller **already holds** [sendMutex]. */
    private suspend fun sendLocked(device: IQDevice, message: List<String>): ConnectIQ.IQMessageStatus? =
        withContext(sendContext) {
            suspendCancellableCoroutine { continuation ->
                try {
                    connectIQ.sendMessage(device, watchApp, message) { _, _, status ->
                        if (continuation.isActive) {
                            continuation.resume(status)
                        }
                    }
                } catch (e: Exception) {
                    EventLog.w(TAG, "sendMessage failed", e)
                    if (continuation.isActive) {
                        continuation.resume(null)
                    }
                }
            }
        }

    /** One message in flight, resolved by the SDK callback (05 §Transport). */
    private suspend fun sendOne(device: IQDevice, payload: ByteArray): Boolean =
        withTimeoutOrNull(SEND_TIMEOUT_MS) {
            repeat(MAX_SEND_ATTEMPTS) { attempt ->
                val startedAt = System.currentTimeMillis()
                val status = sendAwait(device, wire(payload))
                // The time per chunk is the F1 measurement and also what explains a
                // 1-minute send: here you can see whether the cost is in BLE or in the
                // ACK timeouts. The type has been in the line since C13b: with
                // [sendMutex], chunks from different sends alternate in the log (the
                // favorites resent on reconnect go out in the middle of the corridor), and
                // without it you could not tell which block each one belonged to.
                EventLog.i(
                    TAG,
                    "chunk 0x%02X ${payload.size} B (${wire(payload).first().length} b64):".format(payload.getOrNull(1) ?: 0) +
                        " $status in ${System.currentTimeMillis() - startedAt} ms" +
                        " (attempt ${attempt + 1}/$MAX_SEND_ATTEMPTS)",
                )
                if (status == ConnectIQ.IQMessageStatus.SUCCESS) {
                    return@withTimeoutOrNull true
                }
            }
            false
        } ?: false

    /**
     * Without this registration the watch's ACK never arrives and the transfer dies by
     * timeout without saying why — the failures here are `Log.e` on purpose.
     */
    private fun listenForWatchMessages(device: IQDevice) {
        if (!listening.add(device.deviceIdentifier)) {
            return
        }
        try {
            connectIQ.registerForAppEvents(device, eventsApp) { _, _, message, status ->
                // This callback runs inside an SDK BroadcastReceiver: whatever
                // escapes from here takes the whole app down. And the SDK delivers `message`
                // **null** on events that are just status — that is what crashed the
                // app on every share (NPE in `message.size`).
                try {
                    val items: List<Any?> = message ?: emptyList()
                    if (status != ConnectIQ.IQMessageStatus.SUCCESS) {
                        // FAILURE_INVALID_FORMAT here = GCM could not read what
                        // the watch sent; the message dies before becoming an ACK.
                        EventLog.w(TAG, "watch event refused: status=$status items=${items.size}")
                    } else {
                        EventLog.i(TAG, "watch event: status=$status items=${items.size}")
                    }
                    items.forEach { onWatchItem(it) }
                } catch (e: Exception) {
                    EventLog.e(TAG, "failed to handle watch event", e)
                }
            }
            EventLog.i(TAG, "listening to events from ${device.friendlyName}")
        } catch (e: InvalidStateException) {
            listening.remove(device.deviceIdentifier)
            EventLog.e(TAG, "registerForAppEvents before the SDK was ready - the ACK will not arrive", e)
        } catch (e: ServiceUnavailableException) {
            listening.remove(device.deviceIdentifier)
            EventLog.e(TAG, "registerForAppEvents without the Garmin Connect service - the ACK will not arrive", e)
        }
    }

    /** An item of a watch message: the Base64 frame, or the bridge's proof. */
    private fun onWatchItem(item: Any?) {
        // The bridge proof's reply (C7a) is not Base64: the line goes raw
        // to logcat, where `ponte.py` looks for it.
        if (item is String && item.startsWith(PROBE_PREFIX)) {
            EventLog.i(TAG, item)
            return
        }
        val bytes = asBytes(item)
        if (bytes == null) {
            EventLog.w(TAG, "unreadable watch item: ${item?.javaClass?.simpleName}")
        } else {
            EventLog.i(TAG, "from watch: ${bytes.size} B ${bytes.hexPrefix()}")
            onWatchMessage(bytes)
        }
    }

    /**
     * What the watch would send through `transmit`, delivered **outside the SDK**:
     * the relay in `tools/ponte.py` (C7a), which reads the line on the simulator's console
     * and brings it in through `adb`. It follows the same path as a message that arrived through
     * `registerForAppEvents`. Only the `sim` variant's `BridgeReceiver` calls this.
     */
    fun relayFromWatch(text: String) {
        EventLog.i(TAG, "watch event via relay: ${text.length} characters")
        onWatchItem(text)
    }

    /** Watch -> phone messages: ACK today, REROUTE_REQ and friends in F4. */
    private fun onWatchMessage(data: ByteArray) {
        if (data.size < Protocol.HEADER_SIZE || data[0].toInt() != Protocol.VERSION) {
            EventLog.w(TAG, "watch message outside the protocol: ${data.size} B ${data.hexPrefix()}")
            return
        }
        val msgType = data[1].toInt() and 0xFF
        val length = ((data[6].toInt() and 0xFF) shl 8) or (data[7].toInt() and 0xFF)
        // `length < 2` applied to all and dropped NAV_ENDED (1 B of reason): the
        // 2 B floor belongs to the ACK, which has the block type and the `total`.
        if (data.size < Protocol.HEADER_SIZE + length) {
            EventLog.w(TAG, "watch message with inconsistent length: $length in ${data.size} B")
            return
        }
        val routeId = ((data[2].toInt() and 0xFF) shl 8) or (data[3].toInt() and 0xFF)
        if (msgType == Protocol.MSG_ACK) {
            if (length < 2) {
                EventLog.w(TAG, "ACK too short: $length B")
                return
            }
            val blockType = data[Protocol.HEADER_SIZE].toInt() and 0xFF
            val bitmap = data.copyOfRange(Protocol.HEADER_SIZE + 2, Protocol.HEADER_SIZE + length)
            val waiting = pendingAcks[blockType]
            val mine = waiting != null && waiting.routeId == routeId
            EventLog.i(
                TAG,
                "ACK of block 0x%02X route %d, someone waiting=%s".format(blockType, routeId, mine),
            )
            if (mine) {
                waiting?.deferred?.complete(bitmap)
            }
        } else if (msgType == Protocol.MSG_REROUTE_REQ) {
            val req = RerouteReq.parse(data.copyOfRange(0, Protocol.HEADER_SIZE + length))
            if (req == null) {
                EventLog.w(TAG, "REROUTE_REQ malformed: ${data.size} B ${data.hexPrefix()}")
            } else {
                // The position only goes to the log in the `sim` variant: on the S25 it is where Igor goes.
                val place = if (BuildConfig.CIQ_TETHERED) "at ${req.latE5},${req.lonE5} " else ""
                EventLog.i(
                    TAG,
                    "REROUTE_REQ route ${req.routeId} ${place}heading ${req.headingDeg} dist ${req.distAlongM} m",
                )
                onRerouteReq?.invoke(req)
            }
        } else if (msgType == Protocol.MSG_NAV_START_REQ) {
            val req = NavStartReq.parse(data.copyOfRange(0, Protocol.HEADER_SIZE + length))
            if (req == null) {
                EventLog.w(TAG, "NAV_START_REQ malformed: ${data.size} B ${data.hexPrefix()}")
            } else {
                // Only the id: a favorite's name and coordinate are sensitive data.
                EventLog.i(TAG, "NAV_START_REQ ${if (req.recent) "recent" else "favId"} ${req.favId}")
                onNavStartReq?.invoke(req)
            }
        } else if (msgType == Protocol.MSG_NAV_ENDED) {
            val reason = if (length >= 1) data[Protocol.HEADER_SIZE].toInt() and 0xFF else -1
            EventLog.i(TAG, "NAV_ENDED route $routeId reason $reason")
            onNavEnded?.invoke(reason)
        } else if (msgType == Protocol.MSG_FIX_REQ) {
            val req = FixReq.parse(data.copyOfRange(0, Protocol.HEADER_SIZE + length))
            if (req == null) {
                EventLog.w(TAG, "FIX_REQ malformed: ${data.size} B ${data.hexPrefix()}")
            } else {
                EventLog.i(TAG, "FIX_REQ ${if (req.on) "on" else "off"}")
                onFixReq?.invoke(req)
            }
        } else if (msgType == Protocol.MSG_LOG) {
            // The watch's log goes into the phone's file, line by line,
            // marked — that way both sides of the same transfer stay together.
            val text = String(
                data.copyOfRange(Protocol.HEADER_SIZE, Protocol.HEADER_SIZE + length),
                Charsets.UTF_8,
            )
            text.lineSequence().filter { it.isNotBlank() }.forEach { line ->
                EventLog.i(TAG, "WATCH| $line")
                onWatchLog?.invoke(line)
            }
        } else {
            EventLog.i(TAG, "msgType 0x%02X from watch, ignored in this phase".format(msgType))
        }
    }

    private fun asBytes(item: Any?): ByteArray? = when (item) {
        is ByteArray -> item
        // The watch sends the frame in Base64 in a String — a raw ByteArray from
        // `Communications.transmit` arrives here as FAILURE_INVALID_FORMAT.
        is String -> decodeBase64(item)
        is List<*> -> item.filterIsInstance<Number>()
            .map { it.toInt().toByte() }
            .toByteArray()
            .takeIf { it.size == item.size }

        else -> null
    }

    private fun decodeBase64(text: String): ByteArray? = try {
        Base64.decode(text, Base64.DEFAULT)
    } catch (e: IllegalArgumentException) {
        EventLog.w(TAG, "String from watch is not Base64: ${text.take(32)}")
        null
    }

    private fun connectedDevice(): IQDevice? = try {
        connectIQ.connectedDevices?.firstOrNull()?.also { target = it }
    } catch (e: Exception) {
        EventLog.w(TAG, "connectedDevices failed", e)
        null
    }

    private fun isConnected(device: IQDevice): Boolean = try {
        connectIQ.getDeviceStatus(device) == IQDevice.IQDeviceStatus.CONNECTED
    } catch (e: InvalidStateException) {
        false
    } catch (e: ServiceUnavailableException) {
        false
    }

    /** Asks the watch whether MotoNav is sideloaded on it. */
    private fun queryAppInstalled(device: IQDevice) {
        try {
            connectIQ.getApplicationInfo(
                watchApp.applicationId,
                device,
                object : ConnectIQ.IQApplicationInfoListener {
                    override fun onApplicationInfoReceived(app: IQApp?) {
                        updateDevice(device.deviceIdentifier) { it.copy(appInstalled = true) }
                        try {
                            onWatchReady?.invoke()
                        } catch (e: Exception) {
                            EventLog.e(TAG, "failed to sync the watch that appeared", e)
                        }
                    }

                    override fun onApplicationNotInstalled(applicationId: String?) {
                        updateDevice(device.deviceIdentifier) { it.copy(appInstalled = false) }
                    }
                },
            )
        } catch (e: InvalidStateException) {
            EventLog.w(TAG, "getApplicationInfo before the SDK was ready", e)
        } catch (e: ServiceUnavailableException) {
            EventLog.w(TAG, "getApplicationInfo without the Garmin Connect service", e)
        }
    }

    private fun updateDevice(id: Long, transform: (WatchDevice) -> WatchDevice) {
        _state.value = _state.value.copy(
            devices = _state.value.devices.map { if (it.id == id) transform(it) else it },
        )
    }

    private fun ConnectIQ.IQSdkErrorStatus?.toProblem(): SdkProblem = when (this) {
        ConnectIQ.IQSdkErrorStatus.GCM_NOT_INSTALLED -> SdkProblem.GCM_NOT_INSTALLED
        ConnectIQ.IQSdkErrorStatus.GCM_UPGRADE_NEEDED -> SdkProblem.GCM_NEEDS_UPGRADE
        else -> SdkProblem.SERVICE_ERROR
    }

    companion object {
        private const val TAG = "WatchLink"

        /** Prefix of the bridge proof. `:` is not Base64, so it is never a frame. */
        const val PROBE_PREFIX = "PONTE:"

        @Volatile
        private var instance: WatchLink? = null

        /**
         * The process's link, created and started on the first call. Every
         * screen uses this same object — see the class note on why two
         * instances cannot coexist.
         */
        fun of(context: Context): WatchLink =
            instance ?: synchronized(this) {
                instance ?: WatchLink(context.applicationContext).also {
                    it.start()
                    instance = it
                }
            }
        private const val SEND_TIMEOUT_MS = 10_000L
        private const val MAX_SEND_ATTEMPTS = 3

        fun isGcmInstalled(context: Context): Boolean = try {
            context.packageManager.getPackageInfo(MotoNavIds.GCM_PACKAGE, 0)
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }
}
