import Toybox.Lang;

//! The favorite navigation request the watch sent and that has not had an answer yet
//! (C12). Pure, in the `FixGap` style: time comes from outside.
//!
//! The phone's answer is a **new route**, and whoever receives it is `showNav`, which
//! switches screens and calls [clear]. With no route after [TIMEOUT_MS], the Home screen
//! says the phone did not answer instead of staying on «Pedindo rota» forever
//! (phone off, far away, or without position/internet).
class FavoriteAsk {

    //! 20 s: the phone needs a position (up to 8 s), Mapbox (~1 s) and the route
    //! transfer (~7 s measured in F1, `DECISIONS.md`), so the RF-01 of 10 s is already
    //! tight; 20 s is double it, and it is the same spacing as ADR-4.
    static const TIMEOUT_MS = 20000;

    //! The `favId` of the wait with no request (see [noteRouteChunk]): outside the 16 bits of the
    //! protocol, it is nobody's favorite or recent.
    static const SHARED_ID = 65536;

    private var _favId as Number = -1;
    private var _name as String = "";
    private var _askedMs as Number = 0;
    private var _timedOut as Boolean = false;

    function start(favId as Number, name as String, nowMs as Number) as Void {
        _favId = favId;
        _name = name;
        _askedMs = nowMs;
        _timedOut = false;
    }

    //! Is there a request in progress (waiting or already unanswered)?
    function isActive() as Boolean {
        return _favId >= 0;
    }

    //! Called on every tick. Returns `true` on the turn when the deadline expires, so
    //! the caller requests the redraw only once.
    function update(nowMs as Number) as Boolean {
        if (_favId < 0 || _timedOut || nowMs - _askedMs < TIMEOUT_MS) {
            return false;
        }
        _timedOut = true;
        return true;
    }

    //! Request in flight, still within the deadline: the home screen ring spins.
    function isWaiting() as Boolean {
        return _favId >= 0 && !_timedOut;
    }

    //! The deadline expired with no route: the status line goes amber, because from there it is up to the rider.
    function isSilent() as Boolean {
        return _favId >= 0 && _timedOut;
    }

    //! **A piece of a new, still incomplete route arrived** (C16): the home
    //! screen spins the ring until `showNav`, in place of the F1 `DebugView`, whose
    //! numbers the rider saw for about 3 s on every route. With a
    //! request in flight, the route is its answer; with no request (the route came from the phone's
    //! share), it opens an unnamed wait. Each piece renews the deadline: the ring stops
    //! and the line goes amber only when the route stopped arriving.
    function noteRouteChunk(nowMs as Number) as Void {
        if (_favId < 0) {
            _favId = SHARED_ID;
            _name = "";
        }
        _askedMs = nowMs;
        _timedOut = false;
    }

    //! Is the wait for a route the watch did not request ([noteRouteChunk])?
    function isShared() as Boolean {
        return _favId == SHARED_ID;
    }

    function clear() as Void {
        _favId = -1;
        _name = "";
        _timedOut = false;
    }

    //! The Home screen line; empty if there is no request.
    function text() as String {
        if (_favId < 0) {
            return "";
        }
        if (_timedOut) {
            // The watch did not request the share route: the route went quiet, not the answer.
            return Tr.s(isShared() ? Rez.Strings.AskRouteStopped : Rez.Strings.AskNoAnswer);
        }
        if (isShared()) {
            return Tr.s(Rez.Strings.AskReceiving);
        }
        return Tr.f(Rez.Strings.AskRequesting, [_name]);
    }
}
