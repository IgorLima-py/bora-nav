import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;

//! C4's three screens in the simulator: only enters through `watch/shots.jungle`, which
//! `tools/sim.py shots` builds. When the SP route and corridor have finished
//! going in, puts the bike in each `ShotParams` scene (generated from `tokens.json`: the
//! maneuver and the distance of each state) through `applyFix`, the same GPS door,
//! with the real GPS mute.
//!
//! The `[shot]` lines are the protocol with `sim.py`: `ready <scene>` says that the
//! screen is set up and can be photographed; `end` says it is over.
function demoAfterLoad() as Boolean {
    var run = new ShotRun();
    _shotRun = run;
    run.start();
    return true;
}

//! Keeps the sequence (and its timer) alive after `demoAfterLoad`.
var _shotRun as ShotRun? = null;

class ShotRun {

    //! Seconds with the fix repeated before `ready`: the match with the route and the
    //! redraw are not instantaneous, and `sim.py` only photographs after the line.
    const SETTLE_S = 3;

    //! Seconds the scene stays still for `sim.py` to photograph.
    const HOLD_S = 7;

    //! Extra seconds, after [SETTLE_S], waiting for the streets image to cover the glass (v1.1.5).
    //! Without it, the photo comes out with the street-by-street drawing, which has neither the black edge nor the antialiasing
    //! of the small streets, and is not the map the rider sees. `ready` says whether the image arrived.
    const IMAGE_WAIT_S = 20;

    //! Repeated heading samples in the scene's first second: with `HEADING_ALPHA` at 0.4, 12
    //! leave 0.2% of the old heading.
    const SETTLE_FIXES = 12;

    private var _timer as Timer.Timer?;
    private var _scene as Number = 0;
    private var _seconds as Number = 0;
    //! The second of the scene in which `ready` came out; -1 while it is not ready.
    private var _readyAt as Number = -1;

    function initialize() {
    }

    function start() as Void {
        // C16.5 (`sim.py shots --config`): the group sizes at the ends, before the 1st scene.
        for (var i = 0; i < ShotParams.CONFIG_KEYS.size(); i++) {
            Config.values[(ShotParams.CONFIG_KEYS[i] as Number) - 1] = ShotParams.CONFIG_VALUES[i] as Number;
        }
        if (ShotParams.CONFIG_KEYS.size() > 0) {
            Config.revision++;
            System.println("[shot] config " + ShotParams.CONFIG_KEYS.toString() + " = "
                + ShotParams.CONFIG_VALUES.toString());
        }
        getApp().setReplayActive(true);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
        System.println("[shot] start " + ShotParams.NAMES.size().toString() + " scenes");
    }

    function onTick() as Void {
        if (_scene >= ShotParams.NAMES.size()) {
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.println("[shot] end");
            System.exit();
            return;
        }

        if (_seconds == 0) {
            var nav = getApp().getNav();
            nav.setZoomIndex(ShotParams.ZOOM_INDEX[_scene] as Number);
        }
        // The leash at the ceiling every second (C16.5): in the simulator `getTimer` advances in steps of 15.6
        // ms, and a corridor that costs 16 ms or 17 ms falls on one step or the other. That is what
        // decided how many streets the photo showed (the same scene came out with the leash at 834 in one run
        // and at 220 in the next, 2026-10-17). The photo is of the drawing; the cost is measured in `work`.
        var map = getApp().getMap();
        map.corridorBudget = map.WORK_MAX;
        var state = ShotParams.STATE[_scene] as Number;
        // v1.1.5: the route edge is the default, and state 4 is the test setting that turns it off.
        map.routeCasing = state != 4;
        var heading = placeAt(sceneMetres(_scene));
        if (_seconds == 0) {
            // The app's heading is an average that takes some 10 s to turn from one scene to the next, and
            // the laid-back glass sits 143 px ahead of the rider: the streets image made in the middle of
            // the turn is born already not covering the glass (v1.1.5). In the photo, the heading arrives settled. Only the
            // `NavState` average, at the same point: the whole app's `applyFix`, 40 times in one
            // callback, blew the watchdog.
            var settle = getApp().getNav();
            for (var i = 0; i < SETTLE_FIXES; i++) {
                settle.applyFix(settle.x, settle.y, 12.0, heading);
            }
        }
        // The sheet 4 scenes (`sim.py shots --folha4`): the state goes after the fix, which would redo it.
        var nav = getApp().getNav();
        if (state == 1) {
            nav.offRoute = OffRoute.REQUESTED;
        } else if (state == 2) {
            nav.weakFix = true;
        } else if (state == 3) {
            nav.hasFix = false;
        }
        _seconds++;
        if (_readyAt < 0 && _seconds >= SETTLE_S) {
            var image = !map.streetCache || (!map.streetsBuilding() && map.streets().covers());
            if (image || _seconds >= SETTLE_S + IMAGE_WAIT_S) {
                _readyAt = _seconds;
                System.println("[shot] ready " + (ShotParams.NAMES[_scene] as String)
                    + (image ? "" : " · without the streets image"));
            }
        }
        if (_readyAt >= 0 && _seconds >= _readyAt + HOLD_S) {
            _scene++;
            _seconds = 0;
            _readyAt = -1;
        }
    }

    //! Meters along the route where the scene lives: the maneuver minus the requested
    //! distance; the arrival (`turn` < 0) is the end of the route.
    private function sceneMetres(scene as Number) as Float {
        var route = getApp().getRoute();
        var turn = ShotParams.TURN[scene] as Number;
        if (turn < 0) {
            return route.lengthM();
        }
        var at = route.cum[route.turnPointIdx[turn] as Number] as Float;
        var s = at - (ShotParams.DIST_M[scene] as Number).toFloat();
        return s < 0.0 ? 0.0 : s;
    }

    //! A good fix exactly at `s` meters along the route, in the segment's heading. Returns the heading.
    private function placeAt(s as Float) as Float {
        var route = getApp().getRoute();
        var cum = route.cum;
        var seg = 0;
        var last = cum.size() - 2;
        while (seg < last && (cum[seg + 1] as Float) < s) {
            seg++;
        }
        var a = cum[seg] as Float;
        var b = cum[seg + 1] as Float;
        var t = b > a ? (s - a) / (b - a) : 0.0;
        if (t > 1.0) {
            t = 1.0;
        }
        var dx = (route.xs[seg + 1] as Float) - (route.xs[seg] as Float);
        var dy = (route.ys[seg + 1] as Float) - (route.ys[seg] as Float);
        var heading = Math.atan2(dx, dy).toFloat();
        // In Double: SP's E5 goes past 2 million, and the 32-bit Float would be off by
        // a quarter unit before any computation.
        var lat0 = (route.lats[seg] as Number).toDouble();
        var lon0 = (route.lons[seg] as Number).toDouble();
        var lat = lat0 + t * ((route.lats[seg + 1] as Number) - lat0);
        var lon = lon0 + t * ((route.lons[seg + 1] as Number) - lon0);

        var nav = getApp().getNav();
        nav.fixSource = FixSource.REPLAY;
        getApp().applyFix(
            (lat >= 0 ? lat + 0.5 : lat - 0.5).toNumber(),
            (lon >= 0 ? lon + 0.5 : lon - 0.5).toNumber(),
            12.0,
            heading,
            Position.QUALITY_GOOD
        );
        return heading;
    }
}
