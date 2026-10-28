import Toybox.Lang;

//! GPS gap detector: a fix that vanishes for 20 s or more has to show up in the
//! log, with the duration, and not as a frozen map nobody can explain.
//!
//! The 20 s threshold is the roadmap's (C3b): at 50 km/h that is 280 m without a position, more
//! than the map-matching window (`MapMatcher.WINDOW_AHEAD`, 50 points) tolerates
//! without a global search. Below that, a motorcycle's GPS in the city fails all the time
//! (short tunnel, overpass) and the line would become noise.
//!
//! Two lines per gap, because each covers a case: [poll] warns **in the
//! middle** of it (the app is still without a fix, which is what a frozen screen shows) and
//! [onFix] reports the total duration when the fix comes back.
class FixGap {

    const THRESHOLD_MS = 20000;

    private var _lastMs as Number = 0;
    private var _seen as Boolean = false;
    private var _flagged as Boolean = false;

    function initialize() {
    }

    //! New or ended route: the previous silence does not count.
    function reset() as Void {
        _seen = false;
        _flagged = false;
    }

    //! A good fix arrived. Returns the silence duration (ms) if it went past the
    //! threshold, otherwise 0.
    function onFix(nowMs as Number) as Number {
        var silence = 0;
        if (_seen && nowMs - _lastMs >= THRESHOLD_MS) {
            silence = nowMs - _lastMs;
        }
        _lastMs = nowMs;
        _seen = true;
        _flagged = false;
        return silence;
    }

    //! Call on every tick, with no new fix. Returns the silence (ms) **once per
    //! gap**, the first time it goes past the threshold; before that, or after
    //! it has already been reported, 0. With no fix at all yet there is no gap to measure.
    function poll(nowMs as Number) as Number {
        if (!_seen || _flagged || nowMs - _lastMs < THRESHOLD_MS) {
            return 0;
        }
        _flagged = true;
        return nowMs - _lastMs;
    }
}
