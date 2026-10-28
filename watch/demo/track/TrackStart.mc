import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! A recorded track, replayed in the simulator (C3b): only enters through
//! `watch/track.jungle`, which `tools/sim.py ride --track` builds. Takes over from
//! `DemoFeed` when the SP route and corridor have finished going in and delivers
//! the track's fixes to `applyFix`, the same GPS door, with the real GPS
//! mute and **the track's own instants** (with its hole).
//!
//! Unlike C3a's lap (`RideStart.mc`), which walks the route at 1 fix per
//! second, here the fixes come ready-made, with the noise and the holes the GPS
//! gave: the test track (`tools/trilha.py gerar`) or a real lap
//! (`tools/trilha.py extrair`). Time is compressed with the shorter timer and the
//! virtual [Clock], not with bigger steps.
//!
//! The `[track]` lines are the protocol with `sim.py`; the rest (`no fix for`,
//! `fix back after`, `vibe ...`, `arrived at destination`) comes out through the app's `Diag`.
function demoAfterLoad() as Boolean {
    var run = new TrackRun();
    _trackRun = run;
    run.start();
    return true;
}

var _trackRun as TrackRun? = null;

class TrackRun {

    const EXIT_AFTER_S = 3;

    //! Fields per fix in the flattened vector: t, lat E5, lon E5, speed dm/s, heading.
    const FIELDS = 5;

    private var _flat as Array<Number> = [] as Array<Number>;
    private var _count as Number = 0;
    private var _next as Number = 0;
    private var _virtualMs as Number = 0;
    private var _timer as Timer.Timer?;
    private var _exitTicks as Number = -1;

    function initialize() {
    }

    function start() as Void {
        var data = WatchUi.loadResource(Rez.JsonData.TrackFixes) as Dictionary;
        _flat = data["f"] as Array<Number>;
        _count = _flat.size() / FIELDS;
        _virtualMs = ((_flat[0] as Number) - 1) * 1000;

        var route = getApp().getRoute();
        System.println("[track] start " + _count.toString() + " fixes route "
            + route.xs.size().toString() + " pts " + route.turnPointIdx.size().toString()
            + " maneuvers " + route.lengthM().format("%.1f") + " m period "
            + TrackParams.PERIOD_MS.toString() + " ms");

        getApp().setReplayActive(true);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), TrackParams.PERIOD_MS, true);
        _timer = timer;
    }

    function onTick() as Void {
        if (_exitTicks >= 0) {
            _exitTicks--;
            if (_exitTicks < 0) {
                var timer = _timer;
                if (timer != null) {
                    timer.stop();
                }
                System.exit();
            }
            return;
        }

        var app = getApp();
        var nav = app.getNav();
        if (nav.phase != NavPhase.NAVIGATING) {
            finish(nav.phase == NavPhase.ARRIVED ? "arrival" : "phase " + nav.phase.toString());
            return;
        }
        if (_next >= _count) {
            finish("trail ended without arrival");
            return;
        }

        // One bike second per tick; delivers what the track has up to it. With no
        // fix in the window (the hole), time passes and nothing is delivered.
        _virtualMs += 1000;
        Clock.virtualMs = _virtualMs;
        while (_next < _count && (_flat[_next * FIELDS] as Number) * 1000 <= _virtualMs) {
            var at = _next * FIELDS;
            Clock.virtualMs = (_flat[at] as Number) * 1000;
            var heading = _flat[at + 4] as Number;
            nav.fixSource = FixSource.REPLAY;
            app.applyFix(
                _flat[at + 1] as Number,
                _flat[at + 2] as Number,
                (_flat[at + 3] as Number) / 10.0,
                heading < 0 ? null : (heading * Math.PI / 180.0).toFloat(),
                Position.QUALITY_GOOD
            );
            _next++;
            if (nav.phase != NavPhase.NAVIGATING) {
                break;
            }
        }
        Clock.virtualMs = _virtualMs;
    }

    private function finish(reason as String) as Void {
        var track = getApp().getTrack();
        System.println("[track] end " + reason + " in " + _next.toString() + " fixes");
        System.println("[track] recorder " + track.recorded.toString() + " lost " + track.lost.toString());
        Clock.virtualMs = null;
        getApp().setReplayActive(false);
        _exitTicks = EXIT_AFTER_S * 1000 / TrackParams.PERIOD_MS;
    }
}
