import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! The Details screen in the simulator (C9): only enters through `watch/detalhes.jungle`, which
//! `tools/sim.py shots --detalhes` builds. Takes over from `DemoFeed` when the route
//! and the SP corridor have finished going in, walks the virtual bike [FIXES] seconds
//! of bike time through the same GPS door (`applyFix`), opens Details over the map
//! (the same `pushDetails` as the swipe and the menu) and notifies `sim.py`, which photographs.
//!
//! The `[details]` lines are the protocol with `sim.py`.
function demoAfterLoad() as Boolean {
    var run = new DetailsRun();
    _detailsRun = run;
    run.start();
    return true;
}

var _detailsRun as DetailsRun? = null;

class DetailsRun {

    //! Seconds of bike time before opening Details: the bike must be in the middle of the
    //! route so the three maneuvers ahead are the ones in its middle, and not the ones at the
    //! start (where the screen would still say "no GPS").
    const FIXES = 120;
    //! How long the screen stays on the air after `ready`: the capture and the slack.
    const HOLD_S = 12;
    //! Period of the lap timer, in ms (Connect IQ's minimum is 50).
    const PERIOD_MS = 50;

    private var _replay as ReplayRunner?;
    private var _timer as Timer.Timer?;
    private var _steps as Number = 0;
    private var _holdTicks as Number = -1;

    function initialize() {
    }

    function start() as Void {
        var route = getApp().getRoute();
        _replay = new ReplayRunner(route, ReplayProfile.standard(), true);
        getApp().setReplayActive(true);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), PERIOD_MS, true);
        _timer = timer;
    }

    function onTick() as Void {
        if (_holdTicks >= 0) {
            _holdTicks--;
            if (_holdTicks < 0) {
                System.println("[details] end");
                var timer = _timer;
                if (timer != null) {
                    timer.stop();
                }
                System.exit();
            }
            return;
        }

        if (_steps < FIXES) {
            var reason = (_replay as ReplayRunner).tick();
            _steps++;
            if (reason == null) {
                return;
            }
            System.println("[details] the lap ended too early: " + reason);
        }

        // Bike in the middle of the route: opens Details and says what it shows.
        var app = getApp();
        app.pushDetails();
        var model = new DetailsModel(app.getRoute(), app.getMatcher(), System.getSystemStats().battery, false);
        System.println("[details] ready " + model.upcoming.size().toString() + " maneuvers "
            + model.total + " | " + model.left + " | " + model.battery);
        for (var i = 0; i < model.upcoming.size(); i++) {
            System.println("[details] maneuver " + i.toString() + " " + (model.upcoming[i] as String));
        }
        _holdTicks = HOLD_S * 1000 / PERIOD_MS;
    }
}
