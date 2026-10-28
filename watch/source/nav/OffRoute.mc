import Toybox.Lang;

//! Off-route detector (RF-11, ADR-4, C11).
//!
//! On every good fix it receives the perpendicular distance to the route (`MapMatcher.
//! crossTrack`) and the instant, and says when the rider left, when it is time to
//! ask again, when to give up on the phone and when the rider came back. It knows nothing about
//! GPS, the link or the screen: the caller (`MotoNavApp.applyFix`) does what the
//! event says. It receives `nowMs` instead of reading the clock, like `FixGap`,
//! so the test can say what time it is and the compressed `sim.py ride` ride
//! counts by the bike clock (`Clock.nowMs()`), not the wall clock.
//!
//! **It is not a phase.** `NavPhase` stays `NAVIGATING` off the route: the virtual
//! ride, the arrival, the GPS dropout and the per-fix redraw depend on it, and
//! none of them changes just because the rider missed a turn (`DECISIONS.md` §C11).
//!
//! **No heading condition.** ADR-4 spoke of "diverging heading"; RF-11
//! does not, and the most common deviation in São Paulo is the same-heading one: the
//! local marginal road when the route takes the expressway, at 40-odd meters.
class OffRoute {

    //! RF-11: more than 40 m… The distance lives in [offRouteThresholdM], which has a
    //! twin in the canary build.

    //! …for more than 5 s (RF-11). It is also the largest gap between two fixes that
    //! still counts as "continuous": with a silence longer than the window one cannot
    //! claim that the rider spent the whole window outside.
    const WINDOW_MS = 5000;

    //! One request every 20 s while outside (ADR-4, `05 §REROUTE_REQ`).
    const RETRY_MS = 20000;

    //! Without the new route in 10 s, it is "no phone": 10 s is the deadline RF-11 gives
    //! for the new route to replace the old one, so going past it means the answer did
    //! not come, not that it is on its way.
    const NO_PHONE_MS = 10000;

    //! The substate (not the phase). `NavState.offRoute` mirrors this value for the
    //! `Hud` and the telemetry.
    enum {
        ON_ROUTE = 0,
        //! Off the route, request sent, waiting for the new route ("Recalculando…").
        REQUESTED = 1,
        //! Off the route and the phone did not answer ("Where's the phone?").
        NO_PHONE = 2
    }

    //! What [update] just decided. At most one per fix.
    enum {
        EVENT_NONE = 0,
        //! Just left the route: vibrate, send the request.
        EVENT_TRIGGERED = 1,
        //! Still outside and 20 s passed since the last request: send another.
        EVENT_RETRY = 2,
        //! 10 s without an answer: switch the text to "Where's the phone?".
        EVENT_NO_PHONE = 3,
        //! The new route started arriving after "no phone": "Recalculando…"
        //! comes back.
        EVENT_ANSWERING = 4,
        //! The rider came back to the route on their own.
        EVENT_BACK = 5
    }

    var state as Number = ON_ROUTE;

    //! Has it been within 40 m of **this** route? Before that the start rule applies
    //! (see [update]).
    var armed as Boolean = false;

    //! `distAlong` of the last fix on the route, in meters; 0 if it was never on it. It is the
    //! `distAlongRoute` of the request (`05 §REROUTE_REQ`).
    var lastOnRouteM as Float = 0.0;

    private var _seen as Boolean = false;
    private var _lastFixMs as Number = 0;

    //! Since when it has been above the limit without interruption; only valid with [_over].
    private var _over as Boolean = false;
    private var _overSinceMs as Number = 0;

    //! The smallest distance seen before arming (the start).
    private var _hasMin as Boolean = false;
    private var _minM as Float = 0.0;

    private var _triggerMs as Number = 0;
    private var _lastRequestMs as Number = 0;

    function initialize() {
    }

    //! New route, ended route, virtual ride starting or ending: nothing
    //! that was measured is valid for the next route.
    function reset() as Void {
        state = ON_ROUTE;
        armed = false;
        lastOnRouteM = 0.0;
        _seen = false;
        _over = false;
        _hasMin = false;
    }

    function isOff() as Boolean {
        return state != ON_ROUTE;
    }

    //! A good fix. `answering` = the new route is already arriving from the phone (the
    //! assembler has one in preparation): meanwhile there is no "no phone" nor
    //! repeated request, however long the transfer takes.
    //!
    //! **The start.** The rider leaves home hundreds of meters from the start of the
    //! route, and that is not a deviation. So the 40 m threshold only applies after they
    //! touched the route once ([armed]). Before that the limit is the smallest
    //! distance seen so far plus the same 40 m: getting closer never triggers, and going
    //! away does. Without this every start becomes a recalculation request in a loop.
    function update(nowMs as Number, crossTrackM as Float, distAlongM as Float, answering as Boolean) as Number {
        // Gap larger than the window, or the clock went backwards (the virtual
        // ride gives the `Clock` back to the wall when it ends): the count restarts.
        if (_seen && (nowMs < _lastFixMs || nowMs - _lastFixMs > WINDOW_MS)) {
            _over = false;
        }
        _seen = true;
        _lastFixMs = nowMs;

        var threshold = offRouteThresholdM();
        var limit = threshold;
        if (!armed) {
            if (crossTrackM <= threshold) {
                armed = true;
            } else {
                if (!_hasMin || crossTrackM < _minM) {
                    _minM = crossTrackM;
                    _hasMin = true;
                }
                limit = _minM + threshold;
            }
        }

        if (crossTrackM <= limit) {
            _over = false;
            if (armed && crossTrackM <= threshold) {
                lastOnRouteM = distAlongM;
            }
            if (state != ON_ROUTE) {
                state = ON_ROUTE;
                return EVENT_BACK;
            }
            return EVENT_NONE;
        }

        if (state == ON_ROUTE) {
            if (!_over) {
                _over = true;
                _overSinceMs = nowMs;
                return EVENT_NONE;
            }
            if (nowMs - _overSinceMs > WINDOW_MS) {
                state = REQUESTED;
                _triggerMs = nowMs;
                _lastRequestMs = nowMs;
                return EVENT_TRIGGERED;
            }
            return EVENT_NONE;
        }

        // Already off the route.
        if (answering) {
            // The answer in progress also holds the next request: the 20 s
            // count again from when it stops arriving.
            _lastRequestMs = nowMs;
            _triggerMs = nowMs;
            if (state == NO_PHONE) {
                state = REQUESTED;
                return EVENT_ANSWERING;
            }
            return EVENT_NONE;
        }
        if (nowMs < _lastRequestMs) {
            // The clock went back with a pending request: recount from now.
            _lastRequestMs = nowMs;
            _triggerMs = nowMs;
        }
        if (state == REQUESTED && nowMs - _triggerMs >= NO_PHONE_MS) {
            state = NO_PHONE;
            return EVENT_NO_PHONE;
        }
        if (nowMs - _lastRequestMs >= RETRY_MS) {
            _lastRequestMs = nowMs;
            return EVENT_RETRY;
        }
        return EVENT_NONE;
    }
}

//! The RF-11 threshold, in meters: more than 40 m is off the route. Outside the
//! canary build it is this one; `watch/canary.jungle` puts the twin below, with 35, for
//! `sim.py test --canary` to prove that `OffRouteTest` bites (at 39 m it
//! would trigger, and `thirtyNineMetersForSixSecondsDoesNotTrigger` must fail).
(:no_canary)
function offRouteThresholdM() as Float {
    return 40.0;
}

(:canary)
function offRouteThresholdM() as Float {
    return 35.0;
}
