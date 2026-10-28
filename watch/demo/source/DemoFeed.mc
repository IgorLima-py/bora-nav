import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The real São Paulo in the simulator (C2b of `docs/ROADMAP.md`).
//!
//! Only exists in the demo build (`watch/demo.jungle`), which only `tools/sim.py demo`
//! builds. Injects, one per second, the messages `DemoFramesTest` recorded
//! from the real Kotlin pipeline — the same Base64 String the phone puts
//! on the air — through `onPhoneData`, so `PhoneData.decode`, `MessageAssembler`,
//! `parseCorridor` and `showNav` run as on the wrist, **with the watchdog in force**
//! (normal run, not `/t`).
//!
//! The `[demo]` lines are the protocol with `sim.py`: `ready` says the last
//! message went in and it is time for the screen capture; `end` says the app reached
//! the end of the window alive and is going to exit by itself.
function demoStart() as Void {
    var feed = new DemoFeed();
    feed.start();
    _demoFeed = feed;
}

//! There is no phone in the simulator: the real `transmit` froze the app on the
//! first ACK. Here the send "succeeds" right away, and `PhoneLink` follows the queue
//! as it would with the phone answering.
function phoneTransmit(text as String, listener as Communications.ConnectionListener) as Void {
    listener.onComplete();
}

//! Keeps `DemoFeed` (and its timer) alive after `demoStart`.
var _demoFeed as DemoFeed? = null;

class DemoFeed {

    //! Seconds between the last message and `System.exit()`. `frameSummary`
    //! comes out every 10 s of the app's timer; 25 s guarantee at least two with the
    //! whole corridor on screen, which is where the `work peak` matters.
    const HOLD_S = 25;

    //! Where the map is centered: the fraction of the route that `preview_map.py` uses
    //! by default (`--at 0.35`), so the simulator's screen and the Python mirror's
    //! are comparable. Without this, with no GPS in the simulator, the map opens outside SP.
    const AT = 0.35;

    private var _frames as Array<ResourceId>;

    //! Messages to inject before the SP route: CONFIG (`sim.py demo --config`,
    //! C5) and the long route (`--rota-longa`, C6a). Empty in the plain demo.
    private var _config as Array<String>;
    private var _nextConfig as Number = 0;
    private var _timer as Timer.Timer?;
    private var _next as Number = 0;
    private var _hold as Number = 0;
    private var _centred as Boolean = false;

    function initialize() {
        _frames = DemoFrames.all();
        _config = demoPreludeFrames();
    }

    function start() as Void {
        // **Every simulator run starts from the default setting.** The simulator's `Storage`
        // survives between executions (measured in C5), and a forgotten `--config`
        // would change `sim.py ride`'s ruler. The opening's `Config.restore`
        // already ran and already logged what it found: `--reabrir` reads that line.
        Config.reset(true);
        // The home screen's timer is borrowed while the messages come in: this feed's would be
        // the fourth (`HomeView.homeTimerLent`).
        homeTimerLent = true;
        System.println("[demo] start " + _config.size().toString() + " config + "
            + _frames.size().toString() + " messages, route "
            + DemoFrames.ROUTE_ID.toString() + ", " + DemoFrames.LOD_COUNT.toString() + " LODs");
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
    }

    function onTick() as Void {
        if (_nextConfig < _config.size()) {
            var frame = _config[_nextConfig];
            // A META waits for the previous route to finish being read, like SP's
            // right below: `--rota-longa` sends the long route twice (C11),
            // and the 2nd's META, arriving with the 1st half read, would restart it instead
            // of opening the preparation. `AQEA` is the Base64 of `01 01 00`: version 1,
            // ROUTE_META, `routeId` below 256.
            var head = frame.substring(0, 4);
            if (head != null && head.equals("AQEA") && getApp().getAssembler().isPolyPending()) {
                return;
            }
            getApp().onPhoneData(frame);
            _nextConfig++;
            return;
        }
        // The `--rota-longa` long route (C6a) finishes being read before SP
        // arrives: SP's META would swap it halfway, and `sim.py` requires its
        // whole `poly route 7 N pts`.
        if (_next == 0 && getApp().getAssembler().isPolyPending()) {
            return;
        }
        if (_next < _frames.size()) {
            var text = WatchUi.loadResource(_frames[_next]) as String;
            _next++;
            getApp().onPhoneData(text);
            centreOnce();
            return;
        }

        // The corridor is read in slices by the app's timer: "ready" only after the
        // last one, which is when the screen has everything and the capture is valid.
        if (_hold == 0 && (getApp().getAssembler().isCorridorPending()
                || getApp().getAssembler().isPolyPending())) {
            return;
        }
        if (_hold == 0) {
            System.println("[demo] ready " + _next.toString() + " messages");
            // The virtual lap (`watch/ride.jungle`) takes over from here with its
            // timer; this one stops before, so the app never has an extra timer.
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            homeTimerLent = false;
            if (demoAfterLoad()) {
                _timer = null;
                return;
            }
            if (timer != null) {
                timer.start(method(:onTick), 1000, true);
            }
        }
        _hold++;
        if (_hold >= HOLD_S) {
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.println("[demo] end " + _next.toString() + " messages");
            System.exit();
        }
    }

    //! Centers the map on point [AT] of the route as soon as it is complete. It is
    //! `seedCentre`, not a fix: the HUD keeps saying there is no GPS, which is the
    //! truth in the simulator.
    //!
    //! Only on the demo route: in `--rota-longa` the long route stays whole on the watch
    //! while SP's is assembled in preparation (atomic swap, C11), and without checking
    //! the id the center would go to the long one and never leave it.
    private function centreOnce() as Void {
        var route = getApp().getRoute();
        if (_centred || !route.isComplete() || route.routeId != DemoFrames.ROUTE_ID) {
            return;
        }
        _centred = true;

        var xs = route.xs;
        var ys = route.ys;
        var n = xs.size();
        var total = 0.0;
        for (var i = 1; i < n; i++) {
            total += distance(xs, ys, i);
        }
        var target = total * AT;
        var run = 0.0;
        var idx = 0;
        for (var i = 1; i < n; i++) {
            run += distance(xs, ys, i);
            if (run > target) {
                break;
            }
            idx = i;
        }
        var nav = getApp().getNav();
        nav.setZoomIndex(NavState.DEFAULT_ZOOM_INDEX);
        nav.seedCentre(xs[idx] as Float, ys[idx] as Float);
        System.println("[demo] center on point " + idx.toString() + " of " + n.toString()
            + " (" + total.format("%.0f") + " m)");
    }

    private function distance(xs as Array<Float>, ys as Array<Float>, i as Number) as Float {
        var dx = xs[i] - xs[i - 1];
        var dy = ys[i] - ys[i - 1];
        return Math.sqrt(dx * dx + dy * dy).toFloat();
    }
}
