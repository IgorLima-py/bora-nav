import Toybox.Communications;
import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.System;

//! Outbound side of the link: one message in flight at a time, gated by the
//! transmit callback, with a small retry budget (docs/05-PROTOCOL.md §Transport).
class PhoneLink {

    const MAX_ATTEMPTS = 3;
    const MAX_QUEUE = 8;

    var sentCount as Number = 0;
    var failedCount as Number = 0;
    var lastError as String = "";

    //! The track recorder, if any: goes along with the log in [flushLog].
    var track as TrackBuffer? = null;

    //! Characters per log message. 1,000 characters are at most ~1,100 B in
    //! UTF-8 (the telemetry uses `·`, 2 B), below the 1,200 B of
    //! [Protocol.MAX_LOG_BYTES]. The diagnostic takes up to 800 of them.
    const LOG_CHARS = 1000;
    const DIAG_CHARS = 800;

    private var _queue as Array<ByteArray> = [] as Array<ByteArray>;
    private var _inFlight as Boolean = false;
    private var _attempts as Number = 0;

    function initialize() {
    }

    //! Called when a new route starts, so the screen shows only this one.
    function resetStats() as Void {
        sentCount = 0;
        failedCount = 0;
        lastError = "";
    }

    //! ACK payload: block msgType, its chunk total and the received bitmap.
    //! The routeId travels in the frame header.
    function sendAck(msgType as Number, routeId as Number, total as Number, bitmap as ByteArray) as Void {
        var payload = [msgType, total]b;
        payload = payload.addAll(bitmap);
        Diag.add("ack-> 0x" + msgType.format("%02X"));
        send(frame(Protocol.MSG_ACK, routeId, payload));
    }

    //! NAV_ENDED (0x84): navigation ended and why (`05 §Message types`).
    //!
    //! The phone needs to know so it stops treating this route as active — today
    //! that only feeds the log, but F4 uses it so as not to recalculate a
    //! route the rider already abandoned.
    function sendNavEnded(routeId as Number, reason as Number) as Void {
        Diag.add("nav-ended reason " + reason.toString());
        send(frame(Protocol.MSG_NAV_ENDED, routeId, [reason]b));
        // The end of navigation is a good moment for the log to get through: it is when the
        // watch has something to tell and the phone is still nearby.
        flushLog();
    }

    //! REROUTE_REQ (0x82): the rider left the route and the watch asks for another
    //! (`05 §REROUTE_REQ`, C11). `routeId` is the route that `distAlongM` refers to;
    //! `headingDeg` is [Protocol.HEADING_UNKNOWN] when the watch has no heading.
    //!
    //! **Cuts the queue.** A 1.3 KB LOG in front would delay by seconds the only
    //! request with a deadline (RF-11's 10 s), and an old request still in the queue would only
    //! tell the phone a position the rider has already left: it leaves, this one goes in.
    function sendRerouteReq(routeId as Number, latE5 as Number, lonE5 as Number, headingDeg as Number, distAlongM as Number) as Void {
        Diag.add("reroute req route " + routeId.toString() + " dist " + distAlongM.toString() + "m heading "
            + (headingDeg < 360 ? headingDeg.toString() : "?"));
        sendFirst(rerouteReqFrame(routeId, latE5, lonE5, headingDeg, distAlongM));
    }

    //! The REROUTE_REQ frame, 8 + 14 bytes, big-endian. Public so the test
    //! can compare it with the `tools/packer.py` vector.
    function rerouteReqFrame(routeId as Number, latE5 as Number, lonE5 as Number, headingDeg as Number, distAlongM as Number) as ByteArray {
        var payload = [
            (latE5 >> 24) & 0xFF, (latE5 >> 16) & 0xFF, (latE5 >> 8) & 0xFF, latE5 & 0xFF,
            (lonE5 >> 24) & 0xFF, (lonE5 >> 16) & 0xFF, (lonE5 >> 8) & 0xFF, lonE5 & 0xFF,
            (headingDeg >> 8) & 0xFF, headingDeg & 0xFF,
            (distAlongM >> 24) & 0xFF, (distAlongM >> 16) & 0xFF, (distAlongM >> 8) & 0xFF, distAlongM & 0xFF
        ]b;
        return frame(Protocol.MSG_REROUTE_REQ, routeId, payload);
    }

    //! NAV_START_REQ (0x83): the rider picked a favorite (`05 §NAV_START_REQ`,
    //! C12). 1 byte, `routeId` 0. Cuts the queue like REROUTE_REQ: a 1.3 KB LOG
    //! in front would delay the only request the rider is watching the screen waiting for.
    function sendNavStartReq(favId as Number) as Void {
        Diag.add("nav start req fav " + favId.toString());
        sendFirst(navStartReqFrame(favId));
    }

    //! The NAV_START_REQ frame, 8 + 1 bytes. Public so the test can compare it with the
    //! `tools/packer.py` vector.
    function navStartReqFrame(favId as Number) as ByteArray {
        return frame(Protocol.MSG_NAV_START_REQ, 0, [favId & 0xFF]b);
    }

    //! NAV_START_REQ for a recent destination (C16.5): the RECENTS id and `kind` 1, 8 + 2 bytes.
    function sendRecentStartReq(id as Number) as Void {
        Diag.add("nav start req recent " + id.toString());
        sendFirst(recentStartReqFrame(id));
    }

    //! The NAV_START_REQ frame for a recent. Public for the test, like [navStartReqFrame].
    function recentStartReqFrame(id as Number) as ByteArray {
        return frame(Protocol.MSG_NAV_START_REQ, 0, [id & 0xFF, Protocol.NAV_START_KIND_RECENT]b);
    }

    //! FIX_REQ (0x86): the watch requests (`on`) or dismisses the phone's GPS
    //! (`05 §FIX_REQ`, C13b). 1 byte, `routeId` 0. Cuts the queue like REROUTE_REQ,
    //! and the newest request takes the place of the one still waiting: "on" followed by
    //! "off" before the first goes out sends only the "off".
    function sendFixReq(on as Boolean) as Void {
        Diag.add("fix req " + (on ? "on" : "off"));
        sendFirst(fixReqFrame(on));
    }

    //! The FIX_REQ frame, 8 + 1 bytes. Public so the test can compare it with the vector
    //! from `tools/packer.py`.
    function fixReqFrame(on as Boolean) as ByteArray {
        return frame(Protocol.MSG_FIX_REQ, 0, [on ? 1 : 0]b);
    }

    //! Sends to the phone what has not yet been sent from [Diag] and the track,
    //! so the watch's log ends up in the same file as the companion's (05 §Diagnostic\1 messages). Without this, reading the watch screen means transcribing by hand.
    //!
    //! **The send cuts on whole lines, not bytes.** The byte cut that
    //! used to be here (the [Protocol.MAX_LOG_BYTES] ceiling) threw away the start of the
    //! message when the log went past 1,200 B, and that showed up nowhere.
    //! Now what does not fit stays pending for the next send, and what
    //! the ring lost before that `Diag` and the track report on a line of their own.
    //!
    //! The diagnostic has priority: it takes up to [DIAG_CHARS], and the track gets
    //! what is left of [LOG_CHARS]. The track never pushes out the diagnostic; the
    //! diagnostic only delays the track, which has 20 min of slack in its buffer.
    function flushLog() as Void {
        var text = Diag.take(DIAG_CHARS);
        var recorder = track;
        if (recorder != null) {
            var points = recorder.take(LOG_CHARS - text.length() - 1);
            if (!points.equals("")) {
                text += (text.equals("") ? "" : "
") + points;
            }
        }
        if (text.equals("")) {
            return;
        }
        var payload = StringUtil.convertEncodedString(
            text,
            {
                :fromRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
                :toRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :encoding => StringUtil.CHAR_ENCODING_UTF8
            }
        );
        if (!(payload instanceof ByteArray)) {
            return;
        }
        send(frame(Protocol.MSG_LOG, 0, payload as ByteArray));
    }

    function send(message as ByteArray) as Void {
        if (_queue.size() >= MAX_QUEUE) {
            // Dropping the oldest keeps the newest state flowing when the link
            // is down; ACKs are idempotent, so a lost one costs a resend.
            _queue = _queue.slice(1, null);
            lastError = "queue full";
        }
        _queue.add(message);
        pump();
    }

    //! Like [send], but at the front of the queue, right behind what is already in flight
    //! (that one cannot be taken out: its callback is still coming), and in place of
    //! any message of the same type that was still waiting its turn.
    function sendFirst(message as ByteArray) as Void {
        var msgType = message[1] as Number;
        var head = _inFlight && _queue.size() > 0 ? 1 : 0;
        var next = [] as Array<ByteArray>;
        if (head == 1) {
            next.add(_queue[0]);
        }
        next.add(message);
        for (var i = head; i < _queue.size(); i++) {
            if (((_queue[i] as ByteArray)[1] as Number) != msgType) {
                next.add(_queue[i]);
            }
        }
        if (next.size() > MAX_QUEUE) {
            next = next.slice(0, MAX_QUEUE);
            lastError = "queue full";
        }
        _queue = next;
        pump();
    }

    //! How many messages are waiting, the in-flight one included (for the tests).
    function queued() as Number {
        return _queue.size();
    }

    function onTransmitDone(ok as Boolean) as Void {
        _inFlight = false;
        Diag.add(ok ? "tx ok" : "tx failed " + (_attempts + 1).toString());
        if (ok) {
            sentCount++;
            _queue = _queue.slice(1, null);
            _attempts = 0;
        } else {
            _attempts++;
            failedCount++;
            lastError = "transmit failed";
            if (_attempts >= MAX_ATTEMPTS) {
                _queue = _queue.slice(1, null);
                _attempts = 0;
            }
        }
        pump();
    }

    private function pump() as Void {
        if (_inFlight || _queue.size() == 0) {
            return;
        }
        _inFlight = true;
        phoneTransmit(encode(_queue[0]), new TransmitListener(self));
    }

    //! The frame goes in Base64 in a String, same as the phone -> watch direction.
    //!
    //! A raw ByteArray `transmit` reaches the companion as
    //! `status=FAILURE_INVALID_FORMAT itens=0`: the `transmit` "succeeds" here
    //! (`ack 2/0` on the screen), but the Android SDK discards the message, and the phone
    //! kept waiting for an ACK that was never going to arrive. Public so the test
    //! can close the cycle with the `PhoneData` on the other side.
    function encode(message as ByteArray) as String {
        var text = StringUtil.convertEncodedString(
            message,
            {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
            }
        );
        return text instanceof String ? text as String : "";
    }

    //! Same 8-byte header as the phone side (05 §Framing); watch -> phone
    //! messages always fit one chunk.
    private function frame(msgType as Number, routeId as Number, payload as ByteArray) as ByteArray {
        var size = payload.size();
        var message = [
            Protocol.VERSION,
            msgType,
            (routeId >> 8) & 0xFF,
            routeId & 0xFF,
            0,
            1,
            (size >> 8) & 0xFF,
            size & 0xFF
        ]b;
        return message.addAll(payload);
    }
}

class TransmitListener extends Communications.ConnectionListener {

    private var _link as PhoneLink;

    function initialize(link as PhoneLink) {
        ConnectionListener.initialize();
        _link = link;
    }

    function onComplete() as Void {
        _link.onTransmitDone(true);
    }

    function onError() as Void {
        _link.onTransmitDone(false);
    }
}
