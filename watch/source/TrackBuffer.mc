import Toybox.Lang;
import Toybox.Math;

//! The track recorder: one fix every 5 s, kept apart from [Diag].
//!
//! **Why apart.** `Diag` has 24 lines and serves the diagnostic of the
//! moment; a 40 min ride at 1 fix/5 s is 480 track lines, which
//! would push the diagnostic out before the log gets through. Here it is a
//! ring of [CAPACITY] fixes in arrays of primitives (no object per fix), which
//! goes to the phone along with the log (`PhoneLink.flushLog`) and only loses anything
//! if the phone stays more than [CAPACITY] × 5 s = 20 min without listening.
//!
//! **Nothing vanishes silently.** A fix overwritten before it was sent goes to
//! [lost], and the next [take] starts with `trk perdi N`. A fix overwritten after
//! it was sent is not a loss.
//!
//! Line format, the same as `tools/trilha.py` and `sim.py ride --track`:
//! `trk <t s> <lat E5> <lon E5> <velocidade dm/s> <rumo graus | -1>`. A fix from the
//! virtual motorcycle ("Simular trajeto") comes out as `trs`, so a simulated ride never
//! passes for a real track when `trilha.py extrair` reads the log.
class TrackBuffer {

    //! 240 × 5 s = 20 min of slack for the phone to come back. Cost: 5 arrays of 240
    //! Numbers, ~5 KB.
    const CAPACITY = 240;

    //! One fix every 5 s: at 50 km/h that is 70 m between points, enough to
    //! reconstruct the route, and 12 log lines/min instead of 60.
    const INTERVAL_MS = 5000;

    //! Fixes recorded since the start (includes the ones already sent and the lost ones).
    var recorded as Number = 0;

    //! Fixes overwritten **before** being sent.
    var lost as Number = 0;

    private var _t as Array<Number>;
    private var _lat as Array<Number>;
    private var _lon as Array<Number>;
    private var _speed as Array<Number>;
    private var _heading as Array<Number>;
    private var _simulated as Array<Boolean>;

    private var _start as Number = 0;
    private var _size as Number = 0;
    private var _unsent as Number = 0;
    private var _reportedLost as Number = 0;
    private var _lastMs as Number = 0;
    private var _hasLast as Boolean = false;

    function initialize() {
        _t = new [CAPACITY] as Array<Number>;
        _lat = new [CAPACITY] as Array<Number>;
        _lon = new [CAPACITY] as Array<Number>;
        _speed = new [CAPACITY] as Array<Number>;
        _heading = new [CAPACITY] as Array<Number>;
        _simulated = new [CAPACITY] as Array<Boolean>;
    }

    //! Offers a fix; records it if [INTERVAL_MS] have passed since the last recorded one.
    //! `heading` in radians (what `applyFix` receives), `null` = no heading.
    function offer(
        nowMs as Number,
        latE5 as Number,
        lonE5 as Number,
        speed as Float,
        heading as Float?,
        simulated as Boolean
    ) as Boolean {
        // `nowMs < _lastMs` is the virtual clock starting over (new ride): record.
        if (_hasLast && nowMs >= _lastMs && nowMs - _lastMs < INTERVAL_MS) {
            return false;
        }
        _hasLast = true;
        _lastMs = nowMs;

        if (_size == CAPACITY) {
            if (_unsent == _size) {
                _unsent--;
                lost++;
            }
            _start = (_start + 1) % CAPACITY;
            _size--;
        }
        var slot = (_start + _size) % CAPACITY;
        _t[slot] = nowMs / 1000;
        _lat[slot] = latE5;
        _lon[slot] = lonE5;
        _speed[slot] = (speed * 10.0 + 0.5).toNumber();
        _heading[slot] = degrees(heading);
        _simulated[slot] = simulated;
        _size++;
        _unsent++;
        recorded++;
        return true;
    }

    //! How many fixes have not been sent yet.
    function unsent() as Number {
        return _unsent;
    }

    //! The lines not yet sent, whole and in order, up to [maxChars]
    //! characters, separated by `\n`; marks the ones it took as sent. What
    //! did not fit stays for the next send. If there was a loss since the last
    //! send, the first line says how many fixes it was.
    function take(maxChars as Number) as String {
        var text = "";
        if (lost > _reportedLost) {
            var report = "trk lost " + (lost - _reportedLost).toString();
            if (report.length() > maxChars) {
                return "";
            }
            text = report;
            _reportedLost = lost;
        }
        while (_unsent > 0) {
            var slot = (_start + _size - _unsent) % CAPACITY;
            var line = (_simulated[slot] ? "trs " : "trk ") + _t[slot].toString() + " " + _lat[slot].toString()
                + " " + _lon[slot].toString() + " " + _speed[slot].toString()
                + " " + _heading[slot].toString();
            var need = line.length() + (text.length() > 0 ? 1 : 0);
            if (text.length() + need > maxChars) {
                break;
            }
            text += (text.length() > 0 ? "\n" : "") + line;
            _unsent--;
        }
        return text;
    }

    //! Heading in whole degrees from 0 to 359, or -1 without a heading.
    private function degrees(heading as Float?) as Number {
        if (heading == null) {
            return -1;
        }
        var deg = (heading * 180.0 / Math.PI + 0.5).toNumber() % 360;
        return deg < 0 ? deg + 360 : deg;
    }
}
