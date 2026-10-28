import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The anti burn-in orbit in the simulator (C10): only enters through `watch/burnin.jungle`,
//! which `tools/sim.py shots --burnin` builds. Takes over from `DemoFeed` when the
//! SP route and corridor have finished going in, walks the bike [FIXES] seconds
//! of bike time through the same GPS door, and then:
//!
//! 1. **measures** (the source of `DECISIONS.md`'s amplitude): for each amplitude from
//!    0 to [SWEEP_MAX] px, how many SP route street names the HUD would cut,
//!    with the name measured in `Dc`'s source of truth font;
//! 2. holds the orbit at point 0 and at point 4 of the ring (`BurnIn.forced`), with the
//!    weather injected so the time is wide, and notifies `sim.py`, which photographs.
//!
//! The `[burnin]` lines are the protocol with `sim.py`.
function demoAfterLoad() as Boolean {
    var run = new BurnInRun();
    _burnInRun = run;
    run.start();
    return true;
}

var _burnInRun as BurnInRun? = null;

class BurnInRun {

    //! Seconds of bike time before the measurement: in the middle of the route, like Details.
    const FIXES = 120;
    //! Largest amplitude of the sweep, in px.
    const SWEEP_MAX = 10;
    //! How long each orbit point stays on the air: the capture and the slack.
    const HOLD_S = 6;
    const PERIOD_MS = 50;

    private var _replay as ReplayRunner?;
    private var _timer as Timer.Timer?;
    private var _steps as Number = 0;
    private var _phase as Number = 0;
    private var _holdTicks as Number = 0;

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
        if (_holdTicks > 0) {
            _holdTicks--;
            return;
        }

        if (_phase == 0) {
            if (_steps < FIXES) {
                var reason = (_replay as ReplayRunner).tick();
                _steps++;
                if (reason == null) {
                    return;
                }
                System.println("[burnin] the lap ended too early: " + reason);
            }
            sweep();
            hold(0);
            _phase = 1;
        } else if (_phase == 1) {
            hold(4);
            _phase = 2;
        } else {
            BurnIn.forced = -1;
            System.println("[burnin] end");
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.exit();
        }
    }

    //! Holds the orbit at `point` and notifies. `a` is point 0 and `b` is 4.
    private function hold(point as Number) as Void {
        BurnIn.forced = point;
        Config.reset(false);
        WeatherInfo.inject(24, 2);
        WatchUi.requestUpdate();
        System.println("[burnin] ready " + (point == 0 ? "a" : "b") + " point " + point.toString()
            + " dx " + BurnIn.dx(point, Config.orbitPx()).toString()
            + " dy " + BurnIn.dy(point, Config.orbitPx()).toString()
            + " amplitude " + Config.orbitPx().toString());
        _holdTicks = HOLD_S * 1000 / PERIOD_MS;
    }

    //! For each amplitude, how many route street names go past the budget of the
    //! screen's chord. The width is that of the HUD font in `Dc`; the height is the one at which
    //! Hud drew the name at that amplitude.
    private function sweep() as Void {
        var app = getApp();
        var route = app.getRoute();
        var dc = Graphics.createBufferedBitmap({ :width => 454, :height => 454 }).get().getDc();
        WeatherInfo.inject(24, 2);

        var names = [] as Array<String>;
        for (var i = 0; i < route.turnName.size(); i++) {
            var name = route.turnName[i] as String;
            if (name.length() > 0) {
                names.add(name);
            }
        }
        System.println("[burnin] streets " + names.size().toString());

        for (var amp = 0; amp <= SWEEP_MAX; amp++) {
            Config.reset(false);
            Config.values[Config.KEY_ORBIT_PX - 1] = amp;
            Config.revision++;
            var hud = new Hud();
            hud.orbitOverride = 0;
            hud.draw(dc, route, app.getNav(), app.getMatcher());
            var budget = hud.streetBudget(hud.lastStreetMidY());
            var cut = 0;
            var widest = 0;
            for (var i = 0; i < names.size(); i++) {
                var width = hud.streetWidth(dc, names[i] as String);
                if (width > widest) {
                    widest = width;
                }
                if (width > budget) {
                    cut++;
                }
            }
            System.println("[burnin] cut amplitude " + amp.toString() + " cut " + cut.toString()
                + " of " + names.size().toString() + " budget " + budget.toString()
                + " widest " + widest.toString());
        }
        Config.reset(false);
    }
}
