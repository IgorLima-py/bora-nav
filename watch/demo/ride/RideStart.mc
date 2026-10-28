import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! The virtual lap in the simulator (C3a): only enters through `watch/ride.jungle`, which
//! `tools/sim.py ride` builds. Takes over from `DemoFeed` when the route and the corridor
//! of SP have finished going in and walks the whole route through `applyFix`, the same
//! GPS door, with the real GPS mute.
//!
//! The `[ride]` lines are the protocol with `sim.py`: `start` and `maneuver`
//! say which route the watch has (`sim.py` checks it against `.esperado.json`,
//! so Kotlin and `packer.py` do not diverge silently) and `end` says how the
//! lap ended. The alerts come out through `Diag` (`vibra curva ...`).
function demoAfterLoad() as Boolean {
    var run = new RideRun();
    _rideRun = run;
    run.start();
    return true;
}

//! Keeps the lap (and its timer) alive after `demoAfterLoad`.
var _rideRun as RideRun? = null;

class RideRun {

    //! Seconds between `[ride] end` and `System.exit()`: the last drawn frame
    //! and the last telemetry line come out before the app closes.
    const EXIT_AFTER_S = 3;

    private var _replay as ReplayRunner?;
    private var _timer as Timer.Timer?;
    private var _exitTicks as Number = -1;

    function initialize() {
    }

    function start() as Void {
        var route = getApp().getRoute();
        // Virtual clock: the lap runs compressed and the track recorder and the
        // "no fix" detector must measure bike seconds, not wall-clock.
        var replay = new ReplayRunner(route, RideParams.profile(), true);
        _replay = replay;

        System.println("[ride] start " + route.xs.size().toString() + " pts "
            + route.turnPointIdx.size().toString() + " maneuvers "
            + route.lengthM().format("%.1f") + " m period " + RideParams.PERIOD_MS.toString() + " ms");
        for (var i = 0; i < route.turnPointIdx.size(); i++) {
            System.println("[ride] maneuver " + i.toString() + " type "
                + (route.turnType[i] as Number).toString() + " at "
                + (route.cum[route.turnPointIdx[i] as Number] as Float).format("%.1f") + " m");
        }

        // The simulator has no weather cache: the lap injects a value for the HUD to
        // show and log (`hud clima 24C nublado`, C9).
        WeatherInfo.inject(24, 1);
        // Streets as an image on or off (`sim.py ride --sem-cache`), to compare the two
        // paths on the same lap.
        getApp().getMap().setStreetCache(RideParams.STREET_CACHE);
        System.println("[ride] streets as image " + (RideParams.STREET_CACHE ? "on" : "off"));
        getApp().setReplayActive(true);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), RideParams.PERIOD_MS, true);
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

        var reason = (_replay as ReplayRunner).tick();
        if (reason != null) {
            finish(reason);
        }
    }

    private function finish(reason as String) as Void {
        var replay = _replay as ReplayRunner;
        System.println("[ride] end " + reason + " in " + replay.fixes().toString() + " fixes");
        getApp().setReplayActive(false);
        _exitTicks = EXIT_AFTER_S * 1000 / RideParams.PERIOD_MS;
    }
}
