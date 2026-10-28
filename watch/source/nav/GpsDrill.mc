import Toybox.Lang;

//! The GPS dropout drill (C16, the rides of 2026-10-19 and 20): once per
//! trip, [Config.gpsDrillMin] minutes after the route appears, the watch
//! pretends for [LENGTH_MS] that its GPS is weak. The fix enters `applyFix`
//! with null quality, which is the path of a tunnel, and [FixFallback] asks for the phone
//! GPS. It proves on the wrist, with real Bluetooth and the phone's GPS, the
//! switch to the phone and back, which the PC only proved with `fix replay`. What it
//! does not prove is how the watch GPS behaves in a real tunnel
//! (`DECISIONS.md` §2026-10-18, the C16 rides).
//!
//! Pure like [FixFallback]: it receives `nowMs` from outside, and the caller logs what
//! [poll] returns. The trip is the destination, not the route: a recalculation does not re-arm.
class GpsDrill {

    //! 90 s: nine telemetry lines (`phone fix`, one every 10 s) and slack
    //! for the first `PHONE_FIX` to arrive, which takes a request and a response.
    const LENGTH_MS = 90000;

    enum {
        EVENT_NONE = 0,
        //! Started pretending: log.
        EVENT_START = 1,
        //! Stopped pretending: log.
        EVENT_END = 2
    }

    //! While true, the watch GPS fix enters as weak.
    var muting as Boolean = false;

    //! When the trip started, or `null` outside a trip.
    private var _tripStartMs as Number? = null;
    //! When it started pretending.
    private var _muteStartMs as Number = 0;
    //! This trip already had the drill.
    private var _done as Boolean = false;

    //! A new trip (a new destination, not a recalculation): the drill re-arms.
    function begin(nowMs as Number) as Void {
        _tripStartMs = nowMs;
        _done = false;
        muting = false;
    }

    //! The trip ended: no pretending until the next.
    function end() as Void {
        _tripStartMs = null;
        muting = false;
    }

    //! On every GPS fix. `minutes` is the current [Config.gpsDrillMin]: 0 turns it off,
    //! and turning it off mid-drill stops the pretending immediately.
    function poll(nowMs as Number, minutes as Number) as Number {
        var start = _tripStartMs;
        if (start == null) {
            return EVENT_NONE;
        }
        if (muting) {
            if (minutes <= 0 || nowMs - _muteStartMs >= LENGTH_MS) {
                muting = false;
                return EVENT_END;
            }
            return EVENT_NONE;
        }
        if (_done || minutes <= 0 || nowMs - start < minutes * 60000) {
            return EVENT_NONE;
        }
        _done = true;
        muting = true;
        _muteStartMs = nowMs;
        return EVENT_START;
    }
}
