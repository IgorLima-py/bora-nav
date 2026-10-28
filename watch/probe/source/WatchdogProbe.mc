import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! **Does the simulator apply the watchdog?** (C2a in `ROADMAP.md`)
//!
//! In a unit test (`monkeydo … /t`) the watchdog has been off since SDK
//! 2.3.1 — which is why the 61 tests never caught the two deaths of
//! 2026-08-01. This probe is a **normal run**: each timer callback runs
//! a loop bigger than the previous one and only prints `ok` after finishing it. If the
//! simulator applies the `venu445mm` `watchdogCount: 240000`, the app dies in the
//! middle of a step and the last `start` line without `ok` says which.
//!
//! One loop iteration is a few bytecode instructions (load, add,
//! multiply, modulo, compare, jump), so the steps go from well
//! below to well above 240 thousand instructions.
class WatchdogProbeApp extends Application.AppBase {

    //! Iterations of each step. The first run (2026-09-29) doubled from 5 thousand
    //! to 640 thousand and died at 20 thousand with 10 thousand passing; the 10%
    //! steps between the two narrow the boundary, and the last three confirm that
    //! above it is death, not chance.
    const STEPS = [5000, 10000, 11000, 12000, 13000, 14000, 15000, 16000, 17000, 18000, 20000, 40000] as Array<Number>;

    private var _step as Number = 0;
    private var _timer as Timer.Timer?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        System.println("probe start");
        scheduleNext();
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [new WatchdogProbeView()];
    }

    private function scheduleNext() as Void {
        var timer = new Timer.Timer();
        timer.start(method(:onStep), 300, false);
        _timer = timer;
    }

    //! One step per callback: the watchdog counts instructions **per callback**, so
    //! each step is measured on its own, without inheriting the cost of the previous one.
    function onStep() as Void {
        if (_step >= STEPS.size()) {
            System.println("probe end alive");
            System.exit();
        }
        var n = STEPS[_step] as Number;
        System.println("probe " + n.toString() + " start");
        var t0 = System.getTimer();
        var acc = 0;
        for (var i = 0; i < n; i++) {
            acc = (acc + i * 7) % 1000003;
        }
        var ms = System.getTimer() - t0;
        System.println("probe " + n.toString() + " ok " + ms.toString() + "ms acc " + acc.toString());
        _step++;
        scheduleNext();
    }
}

class WatchdogProbeView extends WatchUi.View {

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();
        dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2, Graphics.FONT_SMALL,
            "sonda watchdog", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
