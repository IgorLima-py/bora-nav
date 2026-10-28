import Toybox.Lang;
import Toybox.Math;

//! The virtual bike: fixes along the route, one per simulated second (C3a).
//!
//! It knows nothing about timers or the app — it receives the route and the profile and returns the next
//! fix. The caller (`ReplayRunner`) decides the pace and hands it to
//! `MotoNavApp.applyFix`, the same door as the GPS. Since C3b it lives in the main code:
//! the release menu's "Simular trajeto" redoes, on the wrist, the route that
//! came from the phone.
//!
//! **Time is compressed with more frequent fixes, not with bigger steps.**
//! Each fix moves `v × 1 s`, like the GPS's 1 Hz; the `--speed` of `sim.py ride` only
//! shortens the timer interval. A bigger step would skip the 1st warning and leave the
//! map-matching window, and the ride would prove something else.
//!
//! The profile (the constructor's dictionary) comes from the `profile` block of
//! `tools/fixtures/<fixture>.esperado.json` in the simulator ride
//! (`RideParams`) and from `ReplayProfile.standard()` in the menu, both generated from the
//! `PROFILE` of `tools/esperado.py`; `speedAt` is the same computation as
//! `speed_at` of `tools/esperado.py`, and `sim.py ride` checks one against the
//! other through the speed logged on each warning.
class ReplaySource {

    private var _route as RouteModel;

    private var _cruiseMps as Float;
    private var _turnMps as Array<Float>;
    private var _holdM as Float;
    private var _brake as Float;
    private var _accel as Float;
    private var _sigma as Float;
    private var _rho as Float;
    private var _detourM as Float;
    private var _detourFrom as Float;
    private var _detourTo as Float;

    //! Where the bike is, in meters along the route, and in which segment.
    private var _s as Float = 0.0;
    private var _seg as Number = 0;

    //! Current GPS error, in meters (AR(1): moves slowly, does not jump on every fix).
    private var _ex as Float = 0.0;
    private var _ey as Float = 0.0;

    private var _done as Boolean = false;

    var fixes as Number = 0;

    //! **Live** deviation, in meters to the right of the route (C11): turned on from outside
    //! (`tools/e2e.py --desvio`, through the bridge channel) and valid until zeroed, or
    //! until the route changes (the new route's bike is a new source, with 0). The
    //! profile deviation is per stretch and needs the whole route in advance; this one is valid "now".
    var liveDetourM as Float = 0.0;

    function initialize(route as RouteModel, profile as Dictionary) {
        _route = route;
        _cruiseMps = (profile["cruise_kmh"] as Float) / 3.6;
        var kmh = profile["turn_kmh"] as Array<Float>;
        _turnMps = new [kmh.size()] as Array<Float>;
        for (var i = 0; i < kmh.size(); i++) {
            _turnMps[i] = kmh[i] / 3.6;
        }
        _holdM = profile["hold_m"] as Float;
        _brake = profile["brake_mps2"] as Float;
        _accel = profile["accel_mps2"] as Float;
        _sigma = profile["noise_m"] as Float;
        _rho = profile["noise_rho"] as Float;
        var total = route.lengthM();
        _detourM = profile["detour_m"] as Float;
        _detourFrom = (profile["detour_from"] as Float) * total;
        _detourTo = (profile["detour_to"] as Float) * total;
        Math.srand(profile["seed"] as Number);
    }

    //! The next fix, `[latE5, lonE5, speed m/s, heading rad]`, or `null`
    //! when the route ended. The last fix is the exact end of the route.
    function step() as Array? {
        if (_done) {
            return null;
        }
        var total = _route.lengthM();
        var s = _s < total ? _s : total;
        var v = speedAt(s);

        var cum = _route.cum;
        var last = cum.size() - 2;
        while (_seg < last && (cum[_seg + 1] as Float) < s) {
            _seg++;
        }
        var a = cum[_seg] as Float;
        var b = cum[_seg + 1] as Float;
        var t = b > a ? (s - a) / (b - a) : 0.0;

        var dx = (_route.xs[_seg + 1] as Float) - (_route.xs[_seg] as Float);
        var dy = (_route.ys[_seg + 1] as Float) - (_route.ys[_seg] as Float);
        var heading = Math.atan2(dx, dy).toFloat();

        // In Double: SP's E5 exceeds 2 million, and the 32-bit Float would err by
        // a quarter of a unit (~0.3 m) before any noise.
        var lat0 = (_route.lats[_seg] as Number).toDouble();
        var lon0 = (_route.lons[_seg] as Number).toDouble();
        var lat = lat0 + t * ((_route.lats[_seg + 1] as Number) - lat0);
        var lon = lon0 + t * ((_route.lons[_seg + 1] as Number) - lon0);

        var keep = Math.sqrt(1.0 - _rho * _rho);
        _ex = (_rho * _ex + keep * _sigma * gauss()).toFloat();
        _ey = (_rho * _ey + keep * _sigma * gauss()).toFloat();
        var offX = _ex;
        var offY = _ey;
        var detour = 0.0;
        if (liveDetourM != 0.0) {
            detour = liveDetourM;
        } else if (_detourM != 0.0 && s >= _detourFrom && s <= _detourTo) {
            detour = _detourM;
        }
        if (detour != 0.0) {
            // Lateral deviation to the right of the route direction.
            var len = Math.sqrt(dx * dx + dy * dy);
            if (len > 0) {
                offX += (dy / len * detour).toFloat();
                offY += (-dx / len * detour).toFloat();
            }
        }
        lat += offY / (Projection.METRES_PER_DEGREE * Projection.E5_TO_DEGREE);
        lon += offX / (_route.lonScale * Projection.E5_TO_DEGREE);

        fixes++;
        if (_s >= total) {
            _done = true;
        } else {
            _s += v;
        }
        return [round(lat), round(lon), v, heading] as Array;
    }

    //! `v(s)` in m/s: the minimum of the cruise and, for each maneuver, the
    //! braking down to [_holdM] before it, the turn speed within those
    //! meters and the acceleration after it.
    function speedAt(s as Float) as Float {
        var v = _cruiseMps;
        var points = _route.turnPointIdx;
        var types = _route.turnType;
        for (var i = 0; i < points.size(); i++) {
            var type = types[i] as Number;
            var vt = type < _turnMps.size() ? _turnMps[type] as Float : _cruiseMps;
            if (vt >= v) {
                continue;
            }
            var turnS = _route.cum[points[i] as Number] as Float;
            var limit;
            if (s <= turnS) {
                var gap = turnS - _holdM - s;
                limit = gap <= 0.0 ? vt : Math.sqrt(vt * vt + 2.0 * _brake * gap);
            } else {
                limit = Math.sqrt(vt * vt + 2.0 * _accel * (s - turnS));
            }
            if (limit < v) {
                v = limit.toFloat();
            }
        }
        return v;
    }

    //! Standard normal via Box–Muller, over `Math.rand` with a fixed seed.
    private function gauss() as Float {
        // `rand` goes from 0 to 0x7FFFFFFF; the +1 in Float removes the zero from `ln`.
        var u1 = (Math.rand().toDouble() + 1.0) / 2147483649.0d;
        var u2 = Math.rand().toDouble() / 2147483648.0d;
        return (Math.sqrt(-2.0 * Math.ln(u1)) * Math.cos(2.0 * Math.PI * u2)).toFloat();
    }

    private function round(value as Double) as Number {
        return (value >= 0 ? value + 0.5 : value - 0.5).toNumber();
    }
}
