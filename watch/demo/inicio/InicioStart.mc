import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The home screen in the simulator (sheet 1, 2026-10-18): only enters through `watch/inicio.jungle`, which
//! `tools/sim.py shots --inicio` builds. Puts the screen in each sheet state (ready, no phone,
//! asking for a route, the phone silent, Recents in focus and Call in focus), waits for the animations
//! to finish and notifies `sim.py`, which photographs. The favorites and recents are public places.
//!
//! The `[home]` lines are the protocol with `sim.py`.
function demoStart() as Void {
    var run = new HomeRun();
    _homeRun = run;
    run.start();
}

//! There is no phone in the simulator: the send "succeeds" right away, as in `DemoFeed`.
function phoneTransmit(text as String, listener as Communications.ConnectionListener) as Void {
    listener.onComplete();
}

var _homeRun as HomeRun? = null;

class HomeRun {

    const SCENES = ["pronto", "cade", "pedindo", "silencio", "recentes", "ligacao"] as Array<String>;
    //! Half a second per tick; each scene is 8 s: 2 s for the sweep and the step to finish, and the
    //! rest for `sim.py` to photograph. With 4 s the photo came out in the next scene: `println` reaches
    //! `sim.py` up to 1 s late, and the capture takes another 1 s (`shots --inicio`, 2026-10-18).
    const PERIOD_MS = 500;
    const SCENE_TICKS = 16;
    const READY_TICK = 4;

    private var _timer as Timer.Timer?;
    private var _tick as Number = 0;

    function initialize() {
    }

    function start() as Void {
        Favorites.ids = [1, 2, 3, 4, 5, 6] as Array<Number>;
        Favorites.names = ["MASP", "Copan", "Ibirapuera", "Pinacoteca", "Mercadão", "Paulista"] as Array<String>;
        Recents.ids = [0, 1, 2, 3, 4] as Array<Number>;
        Recents.names = ["Sé", "Liberdade", "Luz", "Pacaembu", "Consolação"] as Array<String>;
        var timer = new Timer.Timer();
        timer.start(method(:onTick), PERIOD_MS, true);
        _timer = timer;
    }

    function onTick() as Void {
        var scene = _tick / SCENE_TICKS;
        var step = _tick % SCENE_TICKS;
        _tick++;
        if (scene >= SCENES.size()) {
            System.println("[home] end");
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.exit();
        }
        var name = SCENES[scene] as String;
        if (step == 0) {
            enter(name);
        } else if (step == READY_TICK) {
            System.println("[home] ready " + name);
        }
    }

    private function enter(name as String) as Void {
        var current = WatchUi.getCurrentView();
        var view = current[0];
        if (!(view instanceof HomeView)) {
            System.println("[home] the top screen is not the home screen");
            return;
        }
        var home = view as HomeView;
        var ask = getApp().getFavoriteAsk();
        ask.clear();
        StatusIcons.linkOverride = name.equals("cade") ? 0 : 1;
        if (name.equals("pedindo")) {
            ask.start(1, "MASP", System.getTimer());
        } else if (name.equals("silencio")) {
            ask.start(1, "MASP", System.getTimer() - FavoriteAsk.TIMEOUT_MS - 1);
            ask.update(System.getTimer());
        }
        home.onShow();
        if (name.equals("recentes")) {
            home.move(1);
        } else if (name.equals("ligacao")) {
            home.move(3);
        }
        WatchUi.requestUpdate();
    }
}
