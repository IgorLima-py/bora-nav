import Toybox.Lang;

//! **The app closes by itself after arrival** (C16.5).
//!
//! On an October 2026 ride the app stayed 4 h on the arrival screen after the
//! destination, with GPS already off (the telemetry repeated the same speed
//! the whole time): the 4 h cost 4 battery points on the watch
//! (59 → 55%), more than the 31 min trip that had just ended (61 → 59%). What
//! drains is the open app: the 1 Hz redraw and the telemetry over BLE
//! (`DECISIONS.md` §2026-10-16).
//!
//! [CLOSE_AFTER_MS] after arrival, with no screen touch, the app writes the
//! log line, waits [GRACE_MS] for the `LOG` to go out over BLE, and exits to the
//! watch face. A touch restarts the count; a new or ended route zeroes it.
class ArrivalExit {

    //! 5 min: time to park, take off the glove and look at the screen one last time.
    //! A choice, not a measurement.
    const CLOSE_AFTER_MS = 300000;
    //! Between the log line and the exit: sending the `LOG` is asynchronous, and leaving
    //! right after requesting the send could cut it off. A choice, not a measurement.
    const GRACE_MS = 3000;

    //! What [poll] just decided. `enum`, not `const`: only then can the caller
    //! read it by class name (`ArrivalExit.EXIT`), as in `FixFallback`.
    enum {
        NONE = 0,
        //! The deadline passed: the log line, and sending it.
        ANNOUNCE = 1,
        //! The log had its time: exit.
        EXIT = 2
    }

    private var _since as Number = -1;
    private var _announcedAt as Number = -1;

    function initialize() {
    }

    //! Really arrived (not in the simulation). Only the first call counts.
    function arrived(nowMs as Number) as Void {
        if (_since < 0) {
            _since = nowMs;
            _announcedAt = -1;
        }
    }

    //! The rider touched the screen: the count restarts (before the announcement).
    function touched(nowMs as Number) as Void {
        if (_since >= 0 && _announcedAt < 0) {
            _since = nowMs;
        }
    }

    function reset() as Void {
        _since = -1;
        _announcedAt = -1;
    }

    //! [ANNOUNCE] once, when the deadline passes; [EXIT] [GRACE_MS] later.
    function poll(nowMs as Number) as Number {
        if (_since < 0) {
            return NONE;
        }
        if (_announcedAt < 0) {
            if (nowMs - _since >= CLOSE_AFTER_MS) {
                _announcedAt = nowMs;
                return ANNOUNCE;
            }
            return NONE;
        }
        return nowMs - _announcedAt >= GRACE_MS ? EXIT : NONE;
    }
}
