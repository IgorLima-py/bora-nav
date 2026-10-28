import Toybox.Lang;
import Toybox.Position;
import Toybox.System;

//! A virtual ride in progress: the step the virtual bike takes on each tick
//! (C3b). It serves the two rides that exist:
//!
//! - the release menu's "Simular trajeto", which walks the phone's route in
//!   real time, on the app's own 1 s tick (no extra timer: Connect IQ
//!   has few and the app already uses the tick one and the menu one);
//! - the simulator ride (`tools/sim.py ride`, `watch/demo/ride/RideStart.mc`),
//!   which runs on its own timer and with compressed time, and therefore turns on
//!   [virtualClock].
//!
//! Each step delivers **one fix per bike second** to `applyFix`, the same
//! door as the GPS, so what the ride proves is the path a real fix
//! takes. It knows nothing about timers.
class ReplayRunner {

    private var _source as ReplaySource;
    private var _profile as Dictionary;
    private var _virtualClock as Boolean;
    private var _clockMs as Number;

    //! Fixes of the previous routes of this ride (see [rebind]).
    private var _fixesBefore as Number = 0;

    //! Steps still left of the fix hole (see [setHole]).
    private var _holeLeft as Number = 0;

    //! Each step says where the bike is through [bridgePosition] (C13b). Only the bridge
    //! turns it on; in the real app the hook is empty.
    var reportPosition as Boolean = false;

    //! `virtualClock`: each step advances the [Clock] by 1 bike second, even if the step
    //! arrives faster (compressed ride). Without this the track recorder and the
    //! "no fix" detector would measure wall-clock seconds.
    function initialize(route as RouteModel, profile as Dictionary, virtualClock as Boolean) {
        _source = new ReplaySource(route, profile);
        _profile = profile;
        _virtualClock = virtualClock;
        _clockMs = System.getTimer();
    }

    function fixes() as Number {
        return _fixesBefore + _source.fixes;
    }

    //! The route changed mid-ride (recalculation, C11): the virtual bike restarts
    //! from the start of the new route, which is where it asked from. **Without the
    //! profile deviation:** it is a fraction of the length of the route it was requested on, and
    //! applied again on the new route the bike would leave it by itself once more.
    function rebind(route as RouteModel) as Void {
        _fixesBefore += _source.fixes;
        var profile = {} as Dictionary;
        var keys = _profile.keys();
        for (var i = 0; i < keys.size(); i++) {
            profile.put(keys[i], _profile.get(keys[i]));
        }
        profile.put("detour_m", 0.0);
        _source = new ReplaySource(route, profile);
    }

    //! Turns on (or, with 0, off) the virtual bike's live deviation.
    function setDetour(metres as Float) as Void {
        _source.liveDetourM = metres;
    }

    //! A tunnel (C13b): for the next `seconds` steps the bike keeps moving and
    //! the fix is not delivered. It is the GPS hole that `tools/e2e.py --no-fix` uses
    //! to prove the phone backup.
    function setHole(seconds as Number) as Void {
        _holeLeft = seconds > 0 ? seconds : 0;
    }

    //! One step. `null` = the ride goes on; text = the reason for the end (`arrival`, the
    //! phase where navigation stopped, or the end of the route without arriving).
    function tick() as String? {
        var app = getApp();
        var nav = app.getNav();
        if (nav.phase != NavPhase.NAVIGATING) {
            release();
            return nav.phase == NavPhase.ARRIVED ? "arrival" : "phase " + nav.phase.toString();
        }

        var fix = _source.step();
        if (fix == null) {
            release();
            return "route end without arrival"; // lang: log
        }
        if (_virtualClock) {
            _clockMs += 1000;
            Clock.virtualMs = _clockMs;
        }
        if (reportPosition) {
            bridgePosition(fix[0] as Number, fix[1] as Number, fix[2] as Float, fix[3] as Float);
        }
        if (_holeLeft > 0) {
            _holeLeft--;
            return null;
        }
        nav.fixSource = FixSource.REPLAY;
        app.applyFix(
            fix[0] as Number,
            fix[1] as Number,
            fix[2] as Float,
            fix[3] as Float,
            Position.QUALITY_GOOD
        );
        return null;
    }

    //! Gives the [Clock] back to the wall when the ride ends or is dropped.
    function release() as Void {
        if (_virtualClock) {
            Clock.virtualMs = null;
        }
    }
}
