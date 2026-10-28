import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.System;

//! Chunks of one block, indexed by seq (docs/05-PROTOCOL.md §Framing).
class BlockBuffer {

    var msgType as Number;
    var routeId as Number;
    var total as Number;
    var chunks as Array<ByteArray?>;
    var received as Number = 0;

    //! The watch already sent this block's bitmap due to the timeout, and no chunk arrived
    //! afterwards ([MessageAssembler.checkTimeouts]).
    var partialAcked as Boolean = false;
    var lastMs as Number;

    function initialize(type as Number, route as Number, totalChunks as Number) {
        msgType = type;
        routeId = route;
        total = totalChunks;
        chunks = new [totalChunks] as Array<ByteArray?>;
        lastMs = System.getTimer();
    }

    //! Late duplicates are ignored, so a retransmission never corrupts a block.
    function put(seq as Number, payload as ByteArray) as Void {
        if (chunks[seq] == null) {
            received++;
        }
        chunks[seq] = payload;
        lastMs = System.getTimer();
        partialAcked = false;
    }

    function isComplete() as Boolean {
        return received == total;
    }

    //! Bit `seq` set means chunk `seq` arrived; LSB first inside each byte.
    function bitmap() as ByteArray {
        var bytes = new [(total + 7) / 8]b;
        for (var i = 0; i < total; i++) {
            if (chunks[i] != null) {
                var index = i / 8;
                bytes[index] = (bytes[index] as Number) | (1 << (i % 8));
            }
        }
        return bytes;
    }

    function join() as ByteArray {
        var payload = []b;
        for (var i = 0; i < total; i++) {
            var part = chunks[i];
            if (part != null) {
                payload = payload.addAll(part);
            }
        }
        return payload;
    }
}

//! Reassembles phone messages into route blocks, validates them and ACKs.
//!
//! Everything here treats the incoming bytes as hostile: lengths, counts and
//! offsets are checked before use and anything past a cap is dropped with a log
//! instead of crashing (05 §Robustness rules).
class MessageAssembler {

    // Stats for the F1 debug screen.
    //! Every message delivered by Connect IQ, including the ones that could not be read.
    //! It separates "nothing reached the watch" from "it arrived and the watch could not
    //! use it" — without this, the two failures look exactly the same on the screen.
    var rawMessages as Number = 0;
    var bytesReceived as Number = 0;
    var chunksReceived as Number = 0;
    var transferStartMs as Number = 0;
    var transferEndMs as Number = 0;
    var lastError as String = "";
    var lastMsgType as Number = 0;

    private var _route as RouteModel;
    private var _link as PhoneLink;
    private var _corridor as CorridorModel;
    private var _blocks as Dictionary<Number, BlockBuffer> = {} as Dictionary<Number, BlockBuffer>;

    //! POLY arriving in slices (see [parsePoly]), and the route it fills: the
    //! live one or the staging one.
    private var _polyJob as PolyParseJob? = null;
    private var _polyTarget as RouteModel;

    //! The new route **being staged** (C11, `05 §Robustness rules 2`). With a complete
    //! route on the watch, another route's META does not erase it: the new one is assembled here,
    //! block by block, and only takes the live one's place once whole ([adopt]).
    //! Until C11 the new META erased the route on arrival, and a recalculation left
    //! the rider without a map and without an arrow during the whole transfer.
    private var _staging as RouteModel? = null;
    private var _stagingLastMs as Number = 0;

    //! CORRIDOR blocks of the staging route, kept until the swap: the local
    //! plane is still the old route's, and refusing them would make the phone give up on the
    //! corridor after 3 rounds. At most one per LOD.
    private var _heldCorridor as Array<ByteArray> = [] as Array<ByteArray>;

    //! When the watch requested the recalculation ([noteRerouteRequest]); only valid with
    //! [_rerouteAsked]. It is where the `in N ms` of the `route swapped` line is measured from.
    private var _rerouteAsked as Boolean = false;
    private var _rerouteAskedMs as Number = 0;

    //! Corridor arriving in slices (see [parseCorridor]).
    private var _corridorJob as CorridorParseJob? = null;
    private var _corridorQueue as Array<ByteArray> = [] as Array<ByteArray>;

    //! Size of the corridor block payload already accepted, one per LOD
    //! (`Protocol.CORRIDOR_LOD_COUNT`); 0 = none ([corridorKnown]). Applies to the
    //! live route and is zeroed with its corridor.
    private var _corridorBytes as Array<Number> = [0, 0, 0, 0] as Array<Number>;

    //! Corridor points read per callback. Measured on 2026-09-29 in
    //! `sim.py demo` with the SP corridor, in a normal run (watchdog of
    //! 240,000 instructions in force): slices of 900 points passed and of 1,100
    //! died by `Watchdog Tripped` in the callback that also decodes and joins
    //! the chunk. 450 is half of the largest that passed. SP's LOD 1 (1,490 points)
    //! goes in in 4 ticks.
    const CORRIDOR_SLICE_POINTS = 450;

    //! POLY points read per callback ([PolyParseJob]). Measured on 2026-10-02
    //! in `sim.py demo --rota-longa 4000` (Windows dev PC, normal run, watchdog of
    //! 240,000 in force): slices of 700 and 1,000 points passed, of 1,500 and 2,000
    //! died in the slice that runs in the arrival callback of the last chunk. 500 is
    //! half of the largest that passed, as with the corridor. The 16 km route of the pre-flight
    //! (~780 points) goes in in 2 slices; the protocol's ceiling (4,000), in 8.
    const POLY_SLICE_POINTS = 500;

    //! The last message was a CONFIG: the app does not change screens because of it.
    var lastWasConfig as Boolean = false;

    //! The tests turn it off: the simulator's `Storage` is the same between runs
    //! (measured in C5), and a test cannot leave a saved adjustment for the demo.
    var persistConfig as Boolean = true;

    //! The last message was a FAVORITES (C12) or a RECENTS (C16.5): like CONFIG,
    //! it is not a route one and the app does not change screens because of it.
    var lastWasFavorites as Boolean = false;

    //! The tests turn it off, for the same reason as [persistConfig].
    var persistFavorites as Boolean = true;

    //! The last message was a ROUTE_UPDATE (C13a): only the ETA changed, and the app does not
    //! change screens nor restart navigation because of it.
    var lastWasRouteUpdate as Boolean = false;

    //! The last message was a **valid** PHONE_FIX (C13b), and the position is in
    //! [phoneFix]. A refused one does not set the flag: for the app it is as if it never came.
    var lastWasPhoneFix as Boolean = false;

    //! The last message was an **accepted** piece of a route (META, POLY, TURNS or
    //! corridor). With the new route half-received, the app shows the home screen
    //! waiting; a refused one shows the error in the `DebugView` (C16).
    var lastWasRouteBlock as Boolean = false;

    //! The position of the last valid PHONE_FIX. Only valid together with [lastWasPhoneFix].
    var phoneFix as PhoneFix? = null;

    //! PHONE_FIX accepted and refused since the app opened. It is what is left of them in the
    //! diagnostic, because they have no log line per message.
    var phoneFixes as Number = 0;
    var phoneFixesRefused as Number = 0;

    //! How many PHONE_FIX refusals between each log line.
    const REFUSED_FIX_LOG_EVERY = 30;

    //! The navigation state, so ROUTE_UPDATE knows whether it still applies (C13a).
    //! The app sets it; `null` (the assembler tests) does not check the phase.
    var nav as NavState? = null;

    function initialize(route as RouteModel, link as PhoneLink) {
        _route = route;
        _polyTarget = route;
        _link = link;
        // The corridor lives here and not in the constructor: whoever fills it is the
        // assembler, and none of the dozens of existing calls needs to change.
        _corridor = new CorridorModel();
    }

    function getRoute() as RouteModel {
        return _route;
    }

    function getCorridor() as CorridorModel {
        return _corridor;
    }

    //! For the screen to show whether the watch's ACKs went out (05 §Transport).
    function getLink() as PhoneLink {
        return _link;
    }

    //! Counters of the current transfer. `rawMessages` goes back to 1, not 0: the
    //! message that triggered the reset was already counted in `onPhoneMessage`.
    function resetStats() as Void {
        rawMessages = 1;
        bytesReceived = 0;
        chunksReceived = 0;
        transferStartMs = 0;
        transferEndMs = 0;
        lastError = "";
        _link.resetStats();
        Diag.add("new route, stats reset");
    }

    //! Entry point for every message coming from the companion.
    function onData(data as ByteArray) as Void {
        lastWasConfig = false;
        lastWasFavorites = false;
        lastWasRouteUpdate = false;
        lastWasPhoneFix = false;
        lastWasRouteBlock = false;
        if (data.size() < Protocol.HEADER_SIZE) {
            lastError = "short header";
            Diag.add("rej header " + data.size().toString() + "B");
            return;
        }
        if ((data[0] as Number) != Protocol.VERSION) {
            lastError = "protoVersion " + (data[0] as Number).toString();
            Diag.add("rej version " + (data[0] as Number).toString());
            return;
        }

        var msgType = data[1] as Number;
        var routeId = Protocol.readU16(data, 2);
        var seq = data[4] as Number;
        var total = data[5] as Number;
        var length = Protocol.readU16(data, 6);

        if (total == 0 || seq >= total) {
            lastError = "invalid seq/total";
            Diag.add("rej seq " + seq.toString() + "/" + total.toString());
            return;
        }
        if (!Protocol.hasBytes(data, Protocol.HEADER_SIZE, length)) {
            lastError = "truncated payload";
            Diag.add("rej trunc len " + length.toString());
            return;
        }
        // Before `blk`: the PHONE_FIX arrives once a second, and a line for each
        // one would push the rest of the diagnostic out of the 24-line ring in 24 s.
        if (msgType == Protocol.MSG_PHONE_FIX) {
            onPhoneFix(data, total, length);
            return;
        }
        Diag.add("blk 0x" + msgType.format("%02X") + " " + seq.toString() + "/" + total.toString()
            + " " + length.toString() + "B");

        if (msgType == Protocol.MSG_CONFIG) {
            onConfig(data, routeId, total, length);
            return;
        }
        if (msgType == Protocol.MSG_FAVORITES || msgType == Protocol.MSG_RECENTS) {
            onFavorites(data, routeId, total, length);
            return;
        }
        if (msgType == Protocol.MSG_ROUTE_UPDATE) {
            onRouteUpdate(data, routeId, total, length);
            return;
        }

        // The META of a new route zeroes the statistics: without this the screen's numbers
        // add up different transfers and there is no telling whether what is there is
        // from this route or left over from the previous one. "New" is relative to the one
        // arriving: with one in staging, it is its id that counts, not the live one's.
        var staging = _staging;
        if (msgType == Protocol.MSG_ROUTE_META
                && routeId != (staging != null ? staging.routeId : _route.routeId)) {
            resetStats();
        }
        if (staging != null && routeId == staging.routeId) {
            _stagingLastMs = System.getTimer();
        }

        bytesReceived += data.size();
        chunksReceived++;
        lastWasRouteBlock = true;
        lastMsgType = msgType;
        if (transferStartMs == 0) {
            transferStartMs = System.getTimer();
            transferEndMs = 0;
        }

        var key = msgType * 65536 + routeId;
        var buffer = _blocks.get(key) as BlockBuffer?;
        if (buffer == null || buffer.total != total) {
            buffer = new BlockBuffer(msgType, routeId, total);
            _blocks.put(key, buffer);
        }
        buffer.put(seq, data.slice(Protocol.HEADER_SIZE, Protocol.HEADER_SIZE + length));

        if (buffer.isComplete()) {
            _blocks.remove(key);
            apply(buffer);
        }
    }

    //! A block that stopped arriving (05 §Framing). On the first timeout without a new
    //! chunk the watch sends the bitmap of what arrived **and keeps the block**: the phone
    //! resends only what is missing, and what is missing only closes the block if the rest is
    //! still here. Until C13b the partial ACK threw the block away, and the bitmap
    //! resend could never complete it. On the second consecutive timeout, with no new chunk, the
    //! block is dropped: the phone has already given up (`BlockRounds`, 60 s).
    //!
    //! `now` comes from outside so the test can say what time it is.
    function checkTimeouts(now as Number) as Void {
        var keys = _blocks.keys();
        for (var i = 0; i < keys.size(); i++) {
            var key = keys[i] as Number;
            var buffer = _blocks.get(key) as BlockBuffer?;
            if (buffer != null && now - buffer.lastMs > Protocol.BLOCK_TIMEOUT_MS) {
                if (buffer.partialAcked) {
                    Diag.add("block 0x" + buffer.msgType.format("%02X") + " abandoned");
                    _blocks.remove(key);
                } else {
                    lastError = "block 0x" + buffer.msgType.format("%02X") + " incomplete";
                    Diag.add("timeout 0x" + buffer.msgType.format("%02X"));
                    _link.sendAck(buffer.msgType, buffer.routeId, buffer.total, buffer.bitmap());
                    buffer.partialAcked = true;
                    buffer.lastMs = now;
                }
                // A failure is precisely the case where you want the log on the phone.
                _link.flushLog();
            }
        }
        dropStaleStaging(now);
    }

    //! Drops the staging route that stopped arriving: the phone died, or went out of
    //! range, in the middle of the recalculation. Without this it would sit in memory
    //! forever, and the off-route logic, which waits while an answer is arriving
    //! (`OffRoute.update`, `answering`), would never say "Where's the phone?" nor ask
    //! again. The deadline is the same silence that already drops a half-received block
    //! (`Protocol.BLOCK_TIMEOUT_MS`), counted from its last chunk or the last
    //! POLY slice. `now` comes from outside so the test can say what time it is.
    function dropStaleStaging(now as Number) as Void {
        var staging = _staging;
        if (staging == null || _polyJob != null || now - _stagingLastMs <= Protocol.BLOCK_TIMEOUT_MS) {
            return;
        }
        lastError = "route " + staging.routeId.toString() + " stopped arriving"; // lang: log
        Diag.add("staging of route " + staging.routeId.toString() + " abandoned");
        dropStaging();
        _link.flushLog();
    }

    //! Drops the staging route and what was part of it: the POLY reading and the kept
    //! corridor. The live route is not touched.
    private function dropStaging() as Void {
        if (_staging != null) {
            _polyJob = null;
        }
        _staging = null;
        _heldCorridor = [] as Array<ByteArray>;
    }

    //! Is there a new route in staging, waiting to become whole to replace the live one?
    function isSwapPending() as Boolean {
        return _staging != null;
    }

    //! The recalculation ended without a new route (the rider came back, or the route changed): the
    //! next swap is not a response to any request.
    function noteRerouteOver() as Void {
        _rerouteAsked = false;
    }

    //! The watch just requested a recalculation (`REROUTE_REQ`): the next route
    //! swap logs how long it took since here. Only the first request of each
    //! departure from the route counts; the retries every 20 s do not restart the
    //! count, because what the rider waits for is counted from when they left.
    function noteRerouteRequest() as Void {
        _rerouteAsked = true;
        _rerouteAskedMs = System.getTimer();
    }

    //! PHONE_FIX (`05 §PHONE_FIX`, C13b): the phone's GPS position. One chunk,
    //! 16 bytes, outside the route check and the statistics, like CONFIG, and
    //! **no ACK**: one goes out per second, and the next one is the retry.
    //!
    //! A refused one has no effect at all. It logs on the first refusal and then one every
    //! [REFUSED_FIX_LOG_EVERY], for the same reason there is no `blk` line.
    private function onPhoneFix(data as ByteArray, total as Number, length as Number) as Void {
        var fix = total == 1 ? PhoneFix.parse(data, Protocol.HEADER_SIZE, length) : null;
        if (fix == null) {
            if (phoneFixesRefused % REFUSED_FIX_LOG_EVERY == 0) {
                Diag.add("rej fix " + total.toString() + " chunk(s) " + length.toString() + "B, "
                    + (phoneFixesRefused + 1).toString() + "x refusal");
            }
            phoneFixesRefused++;
            return;
        }
        phoneFix = fix;
        phoneFixes++;
        lastWasPhoneFix = true;
    }

    //! CONFIG (`05 §CONFIG`, C5): one chunk, `routeId` 0, **outside the
    //! route check** — valid with or without a route on the watch — and outside the
    //! transfer statistics, which belong to the route. The ACK goes out even when `Config` refuses a
    //! value: it says the message arrived, and the refusal goes to the phone through the log.
    private function onConfig(data as ByteArray, routeId as Number, total as Number, length as Number) as Void {
        lastWasConfig = true;
        lastMsgType = Protocol.MSG_CONFIG;
        if (total != 1) {
            Config.lastKeys = [] as Array<Number>;
            lastError = "config in " + total.toString() + " chunks";
            Diag.add("config refused: " + total.toString() + " chunks");
            _link.sendAck(Protocol.MSG_CONFIG, routeId, total, new [(total + 7) / 8]b);
            return;
        }
        Config.applyPayload(data.slice(Protocol.HEADER_SIZE, Protocol.HEADER_SIZE + length), persistConfig);
        _link.sendAck(Protocol.MSG_CONFIG, routeId, 1, [0x01]b);
        // Whoever sent the adjustment is looking at `motonav.log`: "applied" or
        // "refused" gets there now, not on the next periodic send.
        _link.flushLog();
    }

    //! FAVORITES (`05 §FAVORITES`, C12): one chunk, `routeId` 0, **outside the route
    //! check** and the transfer statistics, like CONFIG. The ACK always
    //! goes out (it is transport); the refusal, and why, go to the phone through the log.
    //! RECENTS (`05 §RECENTS`, C16.5) has the same format and goes through here.
    private function onFavorites(data as ByteArray, routeId as Number, total as Number, length as Number) as Void {
        var msgType = data[1] as Number;
        var recents = msgType == Protocol.MSG_RECENTS;
        var what = recents ? "recents" : "favorites"; // lang: log
        lastWasFavorites = true;
        lastMsgType = msgType;
        if (total != 1) {
            lastError = what + " in " + total.toString() + " chunks";
            Diag.add(what + " refused: " + total.toString() + " chunks");
            _link.sendAck(msgType, routeId, total, new [(total + 7) / 8]b);
            return;
        }
        var payload = data.slice(Protocol.HEADER_SIZE, Protocol.HEADER_SIZE + length);
        if (recents) {
            Recents.applyPayload(payload, persistFavorites);
        } else {
            Favorites.applyPayload(payload, persistFavorites);
        }
        _link.sendAck(msgType, routeId, 1, [0x01]b);
        _link.flushLog();
    }

    //! ROUTE_UPDATE (`05 §ROUTE_UPDATE`, C13a): the phone redid the route's time
    //! calculation and sends the new duration. One chunk, 4 bytes, outside the transfer
    //! statistics.
    //!
    //! **The ACK here is an answer, not just transport.** Full means "applied";
    //! empty, "it is not the route I am navigating". It is how the phone
    //! finds out that navigation ended when the `NAV_ENDED` got lost (the
    //! `PhoneLink` queue discards and gives up after 3 attempts): without the refusal, the phone's
    //! service would stay alive, with the CPU awake, until someone killed it.
    //!
    //! The route **in staging** also accepts: the phone considers the route delivered at the
    //! ACK of the last block, and the swap only happens at the last POLY slice.
    private function onRouteUpdate(data as ByteArray, routeId as Number, total as Number, length as Number) as Void {
        lastWasRouteUpdate = true;
        lastMsgType = Protocol.MSG_ROUTE_UPDATE;

        var target = null as RouteModel?;
        var reason = "";
        var seconds = 0;
        var staging = _staging;
        var state = nav;
        if (total != 1) {
            reason = total.toString() + " chunks";
        } else if (length != 4) {
            reason = length.toString() + " B";
        } else {
            // The field is uint32 in the contract; read signed, the high bit becomes
            // negative and falls into the same refusal as zero. Zero would zero the ETA.
            seconds = Protocol.readS32(data, Protocol.HEADER_SIZE);
            if (seconds <= 0) {
                reason = "duration " + seconds.toString();
            } else if (staging != null && routeId == staging.routeId) {
                target = staging;
            } else if (!_route.hasMeta || routeId != _route.routeId) {
                reason = "active route is " + (_route.hasMeta ? _route.routeId.toString() : "none"); // lang: log
            } else if (state != null && state.phase != NavPhase.NAVIGATING) {
                reason = "navigation not active";
            } else {
                target = _route;
            }
        }

        if (target == null) {
            lastError = "eta refused: " + reason;
            Diag.add("eta refused route " + routeId.toString() + ": " + reason);
            _link.sendAck(Protocol.MSG_ROUTE_UPDATE, routeId, total, new [(total + 7) / 8]b);
        } else {
            Diag.add("eta route " + routeId.toString() + ": " + target.durationS.toString()
                + " -> " + seconds.toString() + " s");
            target.durationS = seconds;
            _link.sendAck(Protocol.MSG_ROUTE_UPDATE, routeId, 1, [0x01]b);
        }
        // The phone's loop is looking at `motonav.log`: the line gets there now.
        _link.flushLog();
    }

    private function apply(buffer as BlockBuffer) as Void {
        var payload = buffer.join();
        var msgType = buffer.msgType;
        var routeId = buffer.routeId;

        // The route this block fills: the live one, or the staging one.
        var target = _route;
        var staged = false;
        var staging = _staging;

        if (msgType == Protocol.MSG_ROUTE_META) {
            if (staging != null && routeId == _route.routeId) {
                // Repeated META of the live route (a lost ACK) with another in
                // staging: restarting it would erase the route the rider is
                // following. It is already whole; just the ACK.
            } else if (_route.isComplete() && routeId != _route.routeId) {
                // There is already a whole route on the watch: the new one is assembled alongside and
                // the live one stays as it is until the swap (05 §Robustness rules 2). A previous
                // half-received staging is dropped here.
                dropStaging();
                _polyJob = null;
                staging = new RouteModel();
                staging.beginRoute(routeId);
                _staging = staging;
                _stagingLastMs = System.getTimer();
                target = staging;
                staged = true;
                parseMeta(payload, staging);
                if (!staging.hasMeta) {
                    // An unreadable META does not open a staging: the blocks that come
                    // after it fall into "block without META", as always.
                    dropStaging();
                }
            } else {
                _route.beginRoute(routeId);
                // The old corridor is in the old route's local plane: keeping it
                // would draw random streets over the new route (05 §Robustness rules 2).
                _corridor.clear();
                cancelRouteJobs();
                parseMeta(payload, _route);
            }
        } else if (staging != null && routeId == staging.routeId) {
            target = staging;
            staged = true;
            if (msgType == Protocol.MSG_ROUTE_POLY) {
                parsePoly(payload, staging);
            } else if (msgType == Protocol.MSG_TURNS) {
                parseTurns(payload, staging);
            } else if (msgType == Protocol.MSG_CORRIDOR) {
                holdCorridor(payload);
            } else if (msgType == Protocol.MSG_RADARS) {
                // The radars go straight to the staging route: the swap carries them along (`RouteModel.adopt`).
                parseRadars(payload, buffer.total, staging);
            } else {
                lastError = "msgType 0x" + msgType.format("%02X") + " not handled";
            }
        } else if (routeId != _route.routeId || !_route.hasMeta) {
            // No META for this routeId yet: drop and let the companion restart.
            lastError = "block without META (route " + routeId.toString() + ")"; // lang: log
            _link.sendAck(msgType, routeId, buffer.total, new [(buffer.total + 7) / 8]b);
            return;
        } else if (staging != null && msgType != Protocol.MSG_CORRIDOR && msgType != Protocol.MSG_RADARS) {
            // Retransmission of POLY or TURNS of the live route with another in staging:
            // the live one is already whole (otherwise there would be no staging), and rereading its
            // POLY would take the turn of the new POLY's reading. Just the ACK.
        } else if (msgType == Protocol.MSG_ROUTE_POLY) {
            parsePoly(payload, _route);
        } else if (msgType == Protocol.MSG_TURNS) {
            parseTurns(payload, _route);
        } else if (msgType == Protocol.MSG_CORRIDOR) {
            parseCorridor(payload);
        } else if (msgType == Protocol.MSG_RADARS) {
            parseRadars(payload, buffer.total, _route);
        } else {
            lastError = "msgType 0x" + msgType.format("%02X") + " not handled";
        }

        Diag.add("applied 0x" + msgType.format("%02X") + " pts " + target.lats.size().toString()
            + " trn " + target.turnType.size().toString() + (staged ? " (staging)" : ""));
        _link.sendAck(msgType, routeId, buffer.total, buffer.bitmap());
        settle(staged);
    }

    //! After each applied block and the last POLY slice: if what just
    //! came in completed the staging route, it is time for the swap; and if the route
    //! (the live one, or the one that just became live) is complete, the transfer
    //! is over. A block of the live route with another in staging is not the end of anything: the
    //! statistics already belong to the new transfer.
    private function settle(staged as Boolean) as Void {
        var staging = _staging;
        if (!staged) {
            if (staging == null) {
                noteIfComplete();
            }
            return;
        }
        if (staging != null && staging.isComplete()) {
            adopt(staging);
            noteIfComplete();
        }
    }

    //! **The atomic swap** (C11, `05 §Robustness rules 2`): the staging route
    //! became whole and becomes the live one, all at once, in a single callback. The old
    //! route's corridor goes out with it (it is from another local plane, and drawn over the new one
    //! it would become streets in no place), including what was still being read; the
    //! new one's corridor that arrived early goes into the queue and is read by the app's timer,
    //! one slice per tick, never in this callback (which may be the one of the last POLY
    //! slice).
    //!
    //! The line `route swapped A -> B in N ms` is the RF-11 measurement (new route in
    //! up to 10 s): N counts from the watch's request to here. It is where
    //! `tools/e2e.py --desvio` reads the interval from. With no request (the phone sent another
    //! route on its own) the line says so instead of inventing an N.
    private function adopt(staging as RouteModel) as Void {
        var oldId = _route.routeId;
        _staging = null;
        cancelCorridor();
        _corridor.clear();
        _route.adopt(staging);
        _corridorQueue = _heldCorridor;
        for (var i = 0; i < _corridorQueue.size(); i++) {
            var held = _corridorQueue[i];
            noteCorridor(Protocol.readU8(held, 0), held.size());
        }
        _heldCorridor = [] as Array<ByteArray>;

        var line = "route swapped " + oldId.toString() + " -> " + _route.routeId.toString(); // lang: log
        if (_rerouteAsked) {
            line += " in " + (System.getTimer() - _rerouteAskedMs).toString() + " ms";
        } else {
            line += " unrequested"; // lang: log
        }
        _rerouteAsked = false;
        Diag.add(line);
    }

    //! **RADARS** (05 §RADARS, C16.6): `count uint16` and 14 B records in `distAlong` order. What
    //! does not add up refuses the whole message and the earlier radars stay; above
    //! [Protocol.MAX_RADARS], it reads the first ones (robustness rule 3). Cheap enough for the
    //! callback: 200 records are about 1,400 accesses, far from the watchdog.
    private function parseRadars(payload as ByteArray, chunks as Number, route as RouteModel) as Void {
        var why = null;
        var count = 0;
        if (chunks != 1) {
            why = chunks.toString() + " chunks";
        } else if (!Protocol.hasBytes(payload, 0, 2)) {
            why = "short";
        } else {
            count = Protocol.readU16(payload, 0);
            if (payload.size() != 2 + Protocol.RADAR_RECORD_BYTES * count) {
                why = payload.size().toString() + " B for " + count.toString();
            }
        }
        var keep = count > Protocol.MAX_RADARS ? Protocol.MAX_RADARS : count;
        var dist = new [keep] as Array<Number>;
        var xs = new [keep] as Array<Float>;
        var ys = new [keep] as Array<Float>;
        var limits = new [keep] as Array<Number>;
        var flags = new [keep] as Array<Number>;
        var last = 0;
        for (var i = 0; why == null && i < keep; i++) {
            var at = 2 + i * Protocol.RADAR_RECORD_BYTES;
            // `distAlong` is uint32 on the wire; above 2^31 m it is not a route, and the sign refuses it as out of order.
            var d = Protocol.readS32(payload, at);
            if (d < last) {
                why = "out of order at " + i.toString();
                break;
            }
            last = d;
            dist[i] = d;
            xs[i] = Projection.toLocalX(route.lon0 + Protocol.readS32(payload, at + 8), route.lon0, route.lonScale);
            ys[i] = Projection.toLocalY(route.lat0 + Protocol.readS32(payload, at + 4), route.lat0);
            limits[i] = Protocol.readU8(payload, at + 12);
            flags[i] = Protocol.readU8(payload, at + 13);
        }
        if (why != null) {
            lastError = "radars refused: " + why;
            Diag.add(lastError as String);
            return;
        }
        route.radarDist = dist;
        route.radarX = xs;
        route.radarY = ys;
        route.radarLimit = limits;
        route.radarFlags = flags;
        Diag.add("radars " + keep.toString() + " route " + route.routeId.toString()
            + (keep < count ? " (of " + count.toString() + ")" : ""));
    }

    //! CORRIDOR of the staging route: checks the LOD, like [parseCorridor], and
    //! keeps the block for after the swap. The ACK goes out on arrival (in [apply]).
    private function holdCorridor(payload as ByteArray) as Void {
        if (!Protocol.hasBytes(payload, 0, 1)) {
            lastError = "CORRIDOR empty";
            return;
        }
        var lod = Protocol.readU8(payload, 0);
        if (lod >= Protocol.CORRIDOR_LOD_COUNT) {
            lastError = "LOD " + lod.toString() + " invalid";
            return;
        }
        // One block per LOD is what the protocol sends; anything beyond is
        // a retransmission or garbage, and the watch's memory does not grow because of it.
        for (var i = 0; i < _heldCorridor.size(); i++) {
            var held = _heldCorridor[i];
            if (Protocol.readU8(held, 0) == lod && held.size() == payload.size()) {
                return;
            }
        }
        if (_heldCorridor.size() >= Protocol.CORRIDOR_LOD_COUNT) {
            lastError = "corridor too large while staging";
            return;
        }
        _heldCorridor.add(payload);
    }

    //! End of the transfer, if the route just became complete. Called after
    //! each applied block and the last POLY slice, which may arrive after
    //! the TURNS.
    private function noteIfComplete() as Void {
        if (_route.isComplete()) {
            transferEndMs = System.getTimer();
            var elapsed = transferEndMs - transferStartMs;
            Diag.add("complete " + bytesReceived.toString() + "B " + elapsed.toString() + "ms");
            // End of the transfer: sends the log to the phone, where it stays
            // recorded together with the other side of the same story.
            _link.flushLog();
        }
    }

    //! `route` is the route the block fills: the live one or the staging one ([apply]).
    private function parseMeta(payload as ByteArray, route as RouteModel) as Void {
        if (!Protocol.hasBytes(payload, 0, 17)) {
            lastError = "short META";
            return;
        }
        route.lat0 = Protocol.readS32(payload, 0);
        route.lon0 = Protocol.readS32(payload, 4);
        route.distanceM = Protocol.readS32(payload, 8);
        route.durationS = Protocol.readS32(payload, 12);

        var nameLen = Protocol.readU8(payload, 16);
        var offset = 17;
        if (!Protocol.hasBytes(payload, offset, nameLen + 5)) {
            lastError = "truncated META";
            return;
        }
        route.destName = decodeUtf8(payload.slice(offset, offset + nameLen));
        offset += nameLen;

        route.polyPointCount = Protocol.readU16(payload, offset);
        route.turnCount = Protocol.readU8(payload, offset + 2);
        route.corridorLodCount = Protocol.readU8(payload, offset + 3);
        route.flags = Protocol.readU8(payload, offset + 4);
        // Here already, not at the end of the POLY: the corridor is projected with it and may
        // start arriving while the POLY is still being read in slices.
        route.lonScale = Projection.lonScale(route.lat0);
        route.hasMeta = true;
    }

    //! POLY (0x02): keeps the block and reads it in slices ([PolyParseJob]). The first
    //! slice runs right here, so a short route goes in at once; the rest comes from the app's
    //! timer ([stepJobs]). The ACK goes out right away, on the block's arrival: it says
    //! the bytes arrived, and the phone keeps sending TURNS and corridor while the
    //! watch reads.
    //!
    //! Read whole here, as until `v0.18.0`, the POLY of a 16 km route
    //! (3,136 B) blew the watchdog on the wrist (`DECISIONS.md` §C6a: the pre-flight).
    private function parsePoly(payload as ByteArray, route as RouteModel) as Void {
        _polyJob = new PolyParseJob(payload, route);
        _polyTarget = route;
        stepPoly();
    }

    //! A slice of at most [POLY_SLICE_POINTS] POLY points. `true` when
    //! this slice finished the block. If the block was the staging route's and
    //! completed it, the swap happens here ([settle]).
    private function stepPoly() as Boolean {
        var job = _polyJob;
        if (job == null) {
            return false;
        }
        var staging = _staging;
        var staged = staging != null && job.routeId == staging.routeId;
        if (staged) {
            // Reading is arriving: the staging route is not stalled ([dropStaleStaging]).
            _stagingLastMs = System.getTimer();
        }
        if (!job.step(POLY_SLICE_POINTS)) {
            return false;
        }
        _polyJob = null;
        var n = job.finish(_polyTarget);
        if (job.error != null) {
            lastError = job.error as String;
        }
        Diag.add("poly route " + job.routeId.toString() + " " + n.toString() + " pts");
        settle(staged);
        return true;
    }

    //! A slice of whatever is being read: the POLY before the corridor, and never
    //! both in the same callback. Called on every app tick. `true` when the POLY
    //! ended in this call, which is when the route may have become complete.
    function stepJobs() as Boolean {
        if (_polyJob != null) {
            return stepPoly();
        }
        stepCorridor();
        return false;
    }

    //! Is the POLY still being read?
    function isPolyPending() as Boolean {
        return _polyJob != null;
    }

    //! Drops what was being read of the route, POLY and corridor, and the staging
    //! route, if any. Mandatory when ending the route and on every META that
    //! restarts the live route (see [cancelCorridor]).
    function cancelRouteJobs() as Void {
        _polyJob = null;
        dropStaging();
        _rerouteAsked = false;
        cancelCorridor();
    }

    //! Reads all the pending POLY and all the pending corridor at once. **Only for unit
    //! tests**, where the watchdog is off.
    function drainJobs() as Void {
        while (_polyJob != null) {
            stepPoly();
        }
        drainCorridor();
    }

    //! CORRIDOR (0x04): validates the LOD and **queues** the block for reading in
    //! slices ([CorridorParseJob]). The first slice runs right here, so a small
    //! LOD goes in at once; the rest comes from the app's timer ([stepCorridor]).
    //!
    //! `linear_parse` exists for the demo canary (`watch/demo_canary.jungle`)
    //! to be able to swap this version for the quadratic twin right below, which reads the whole
    //! block in a single callback, as on 2026-08-01.
    (:linear_parse)
    private function parseCorridor(payload as ByteArray) as Void {
        if (!Protocol.hasBytes(payload, 0, 1)) {
            lastError = "CORRIDOR empty";
            return;
        }
        var lod = Protocol.readU8(payload, 0);
        if (lod >= Protocol.CORRIDOR_LOD_COUNT) {
            lastError = "LOD " + lod.toString() + " invalid";
            return;
        }
        // The same block again: the full ACK got lost and the phone resent it
        // (C13b). Reading it again would put two of this LOD in memory at the same time;
        // the ACK goes out anyway, in [apply].
        if (corridorKnown(lod, payload.size())) {
            Diag.add("lod " + lod.toString() + " of corridor repeated: ignored");
            return;
        }
        noteCorridor(lod, payload.size());
        // At most one block per LOD: the queue has 4 positions, and the `add` here is
        // not the per-point `add` that killed the app.
        _corridorQueue.add(payload);
        // One slice on arrival, but only if the POLY is not being read: two
        // slices in the same callback would add up the costs that each one limits.
        if (_corridorJob == null && _polyJob == null) {
            stepCorridor();
        }
    }

    //! A slice of at most [CORRIDOR_SLICE_POINTS] corridor points of the one
    //! arriving. Called on the arrival of each block and on every app tick.
    function stepCorridor() as Void {
        var job = _corridorJob;
        if (job == null) {
            if (_corridorQueue.size() == 0) {
                return;
            }
            var payload = _corridorQueue[0];
            _corridorQueue = _corridorQueue.slice(1, null);
            job = new CorridorParseJob(payload, _route.lat0, _route.lon0, _route.lonScale);
            _corridorJob = job;
        }
        if (job.step(CORRIDOR_SLICE_POINTS)) {
            _corridorJob = null;
            job.finish(_corridor);
            if (job.error != null) {
                lastError = job.error as String;
            }
        }
    }

    //! Drops the corridor that was being read. Mandatory when ending the route:
    //! without this, the next slice handed the model the LOD of the ended route,
    //! and a block still in the queue was projected with `lat0 = lon0 = 0`, because
    //! `RouteModel.clear` zeroes them. Finding from the C2b review.
    function cancelCorridor() as Void {
        _corridorJob = null;
        _corridorQueue = [] as Array<ByteArray>;
        _corridorBytes = [0, 0, 0, 0] as Array<Number>;
    }

    //! Has this corridor block already entered this route? The identity is the LOD and the
    //! payload size: the phone builds the corridor once per route, so the
    //! same LOD with the same size is the same block resent. With a different size
    //! it is a correction, and the [CorridorModel] swaps the LOD for the new one. Checking
    //! the bytes would cost, in the arrival callback, what the slices exist
    //! not to spend.
    private function corridorKnown(lod as Number, bytes as Number) as Boolean {
        return (_corridorBytes[lod] as Number) == bytes;
    }

    private function noteCorridor(lod as Number, bytes as Number) as Void {
        _corridorBytes[lod] = bytes;
    }

    //! Is there still corridor to read?
    function isCorridorPending() as Boolean {
        return _corridorJob != null || _corridorQueue.size() > 0;
    }

    //! Reads all the pending corridor at once. **Only for unit tests**, where
    //! the watchdog is off: in the app, the timer reads, slice by slice.
    function drainCorridor() as Void {
        while (isCorridorPending()) {
            stepCorridor();
        }
    }

    //! **Sabotage, never compiled into the app.** The `parseCorridor` as it was until
    //! 2026-08-01: `add` per point, which in Monkey C copies the whole array on every
    //! call (~1.1 million copies for 1,500 points) and killed the app by
    //! watchdog on the wrist (`DECISIONS.md` §2026-08-01). Only
    //! `watch/demo_canary.jungle` turns it on, so `tools/sim.py demo --canary`
    //! proves that the simulator catches that death with the real SP corridor.
    //! `monkey.jungle` and `demo.jungle` exclude `quadratic_parse`, and
    //! `sim.py tudo` checks the release.
    (:quadratic_parse)
    private function parseCorridor(payload as ByteArray) as Void {
        if (!Protocol.hasBytes(payload, 0, 1)) {
            return;
        }
        var lod = Protocol.readU8(payload, 0);
        if (lod >= Protocol.CORRIDOR_LOD_COUNT) {
            return;
        }
        var xs = [] as Array<Float>;
        var ys = [] as Array<Float>;
        var starts = [] as Array<Number>;
        var offset = 1;
        var size = payload.size();
        while (offset < size) {
            var pointCount = Protocol.readU8(payload, offset);
            offset += 1;
            if (pointCount < 2 || !Protocol.hasBytes(payload, offset, 8)) {
                break;
            }
            starts.add(xs.size());
            var lat = _route.lat0;
            var lon = _route.lon0;
            for (var i = 0; i < pointCount && offset < size; i++) {
                var dLat;
                var dLon;
                if (i == 0) {
                    dLat = Protocol.readS32(payload, offset);
                    dLon = Protocol.readS32(payload, offset + 4);
                    offset += 8;
                } else {
                    dLat = Protocol.readS16(payload, offset);
                    dLon = Protocol.readS16(payload, offset + 2);
                    offset += 4;
                    if (dLat == Protocol.DELTA_ESCAPE && dLon == Protocol.DELTA_ESCAPE) {
                        dLat = Protocol.readS32(payload, offset);
                        dLon = Protocol.readS32(payload, offset + 4);
                        offset += 8;
                    }
                }
                lat += dLat;
                lon += dLon;
                xs.add(Projection.toLocalX(lon, _route.lon0, _route.lonScale));
                ys.add(Projection.toLocalY(lat, _route.lat0));
            }
        }
        if (starts.size() == 0) {
            return;
        }
        var wayCount = starts.size();
        starts.add(xs.size());
        _corridor.setLod(lod, xs, ys, starts);
        Diag.add("corridor lod " + lod.toString() + " " + wayCount.toString()
            + " ways " + xs.size().toString() + " pts (quadratic)");
    }

    private function parseTurns(payload as ByteArray, route as RouteModel) as Void {
        var idx = [] as Array<Number>;
        var types = [] as Array<Number>;
        var exits = [] as Array<Number>;
        var names = [] as Array<String>;
        var offset = 0;

        while (Protocol.hasBytes(payload, offset, 3) && idx.size() < Protocol.MAX_TURNS) {
            var pointIdx = Protocol.readU16(payload, offset);
            var type = Protocol.readU8(payload, offset + 2);
            offset += 3;

            var exit = 0;
            if (Protocol.hasExitNum(type)) {
                if (!Protocol.hasBytes(payload, offset, 1)) {
                    break;
                }
                exit = Protocol.readU8(payload, offset);
                offset += 1;
            }

            if (!Protocol.hasBytes(payload, offset, 1)) {
                break;
            }
            var nameLen = Protocol.readU8(payload, offset);
            offset += 1;
            if (!Protocol.hasBytes(payload, offset, nameLen)) {
                break;
            }
            var name = nameLen > 0 ? decodeUtf8(payload.slice(offset, offset + nameLen)) : "";
            offset += nameLen;

            idx.add(pointIdx);
            types.add(type);
            exits.add(exit);
            names.add(name);
        }

        route.turnPointIdx = idx;
        route.turnType = types;
        route.turnExit = exits;
        route.turnName = names;
        route.hasTurns = true;
    }

    //! Invalid UTF-8 yields an empty string instead of an exception.
    private function decodeUtf8(bytes as ByteArray) as String {
        var text = StringUtil.convertEncodedString(
            bytes,
            {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
                :encoding => StringUtil.CHAR_ENCODING_UTF8
            }
        );
        return text instanceof String ? text as String : "";
    }
}
