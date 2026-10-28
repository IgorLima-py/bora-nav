import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;

//! The radar scenes (C16.6) on the SP route, only through `watch/radar.jungle`. It is
//! C4's `ShotStart` with the scenes written here: a 50 km/h radar in the middle of the route and the bike at
//! three points and three speeds. The `[shot] ready <scene>` and
//! `[shot] end` lines are the same as `sim.py shots`'s.
function demoAfterLoad() as Boolean {
    var run = new RadarShotRun();
    _radarRun = run;
    run.start();
    return true;
}

var _radarRun as RadarShotRun? = null;
class RadarShotRun {

    //! Far (at 700 m and 38, nothing on screen), near at the limit (at 230 m and 46: the sign shows up at
    //! 250 m) and well above while still far (at 400 m and 72: the sign already shows up, at 420 m, with the ring).
    const NAMES = ["radar_longe", "radar_perto", "radar_acima"] as Array<String>;
    //! Meters before the radar where the bike is.
    const BEFORE_M = [700, 230, 400] as Array<Number>;
    const SPEED_KMH = [38, 46, 72] as Array<Number>;
    const ZOOM_INDEX = 2;
    const RADAR_KMH = 50;

    const SETTLE_S = 3;
    //! 20 s per scene: enough time to look at the simulator live.
    const HOLD_S = 20;
    const IMAGE_WAIT_S = 20;
    const SETTLE_FIXES = 12;

    private var _timer as Timer.Timer?;
    private var _scene as Number = 0;
    private var _seconds as Number = 0;
    private var _readyAt as Number = -1;
    private var _radarM as Number = 0;

    function initialize() {
    }

    function start() as Void {
        var route = getApp().getRoute();
        _radarM = (route.lengthM() / 2.0).toNumber();
        // A 50 km/h radar in the middle of the route, placed on the route the way the phone's RADARS would place it.
        var at = pointAt(route, _radarM.toFloat());
        route.radarDist = [_radarM] as Array<Number>;
        route.radarX = [at[0]] as Array<Float>;
        route.radarY = [at[1]] as Array<Float>;
        route.radarLimit = [RADAR_KMH] as Array<Number>;
        route.radarFlags = [Protocol.RADAR_FLAG_DIRECTION] as Array<Number>;
        getApp().setReplayActive(true);
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
        System.println("[shot] start " + NAMES.size().toString() + " scenes · radar at "
            + _radarM.toString() + " m of " + route.lengthM().toNumber().toString());
    }

    function onTick() as Void {
        if (_scene >= NAMES.size()) {
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.println("[shot] end");
            System.exit();
            return;
        }
        var nav = getApp().getNav();
        if (_seconds == 0) {
            nav.setZoomIndex(ZOOM_INDEX);
        }
        var map = getApp().getMap();
        map.corridorBudget = map.WORK_MAX;
        var speed = (SPEED_KMH[_scene] as Number).toFloat() / 3.6;
        var s = (_radarM - (BEFORE_M[_scene] as Number)).toFloat();
        var heading = placeAt(s < 0.0 ? 0.0 : s, speed);
        if (_seconds == 0) {
            for (var i = 0; i < SETTLE_FIXES; i++) {
                nav.applyFix(nav.x, nav.y, speed, heading);
            }
        }
        _seconds++;
        if (_readyAt < 0 && _seconds >= SETTLE_S) {
            var image = !map.streetCache || (!map.streetsBuilding() && map.streets().covers());
            if (image || _seconds >= SETTLE_S + IMAGE_WAIT_S) {
                _readyAt = _seconds;
                System.println("[shot] ready " + (NAMES[_scene] as String));
            }
        }
        if (_readyAt >= 0 && _seconds >= _readyAt + HOLD_S) {
            _scene++;
            _seconds = 0;
            _readyAt = -1;
        }
    }

    //! A good fix at `s` meters along the route, in the segment's heading (like `ShotRun.placeAt`).
    private function placeAt(s as Float, speed as Float) as Float {
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
        var lat0 = (route.lats[seg] as Number).toDouble();
        var lon0 = (route.lons[seg] as Number).toDouble();
        var lat = lat0 + t * ((route.lats[seg + 1] as Number) - lat0);
        var lon = lon0 + t * ((route.lons[seg + 1] as Number) - lon0);

        var nav = getApp().getNav();
        nav.fixSource = FixSource.REPLAY;
        getApp().applyFix(
            (lat >= 0 ? lat + 0.5 : lat - 0.5).toNumber(),
            (lon >= 0 ? lon + 0.5 : lon - 0.5).toNumber(),
            speed,
            heading,
            Position.QUALITY_GOOD
        );
        return heading;
    }
}

//! The route point at `s` meters from the start, in local meters `[x, y]` (it was `RadarDraft.pointAt`).
function pointAt(route as RouteModel, s as Float) as Array<Float> {
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
    var x0 = route.xs[seg] as Float;
    var y0 = route.ys[seg] as Float;
    return [x0 + t * ((route.xs[seg + 1] as Float) - x0), y0 + t * ((route.ys[seg + 1] as Float) - y0)]
        as Array<Float>;
}
