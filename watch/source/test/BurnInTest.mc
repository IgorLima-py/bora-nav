import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Test;
import Toybox.Time;

//! **The HUD anti burn-in orbit** (C10, `BurnIn`, `Hud`).
//!
//! What is proven here, on the simulator `Dc` (the SDK returns no pixels; see
//! `Rnf05Test`): the `Hud` keeps the box of each element it drew **already
//! shifted** (`Hud.boxes`), and that is what is checked against the glass. The layout is
//! computed with no shift and with a margin reserved of `Config.orbitPx()`;
//! whatever draws more shifted than it reserved (the canary puts 40 px) leaves the
//! RNF-05 area and the test fails.
//!
//! What is **not** proven: that the panel ages less. Burn-in is only
//! confirmed over weeks of use, and that is said in `DECISIONS.md`.
//! One scenario: what `Hud.draw` needs.
(:test)
class BurnInScene {
    var route as RouteModel;
    var nav as NavState;
    var matcher as MapMatcher;

    function initialize(route as RouteModel, nav as NavState, matcher as MapMatcher) {
        self.route = route;
        self.nav = nav;
        self.matcher = matcher;
    }
}

(:test)
module BurnInAssert {

    const SIZE = 454;

    //! 0: no fix (the card says why there is no maneuver); 1: matched mid-route,
    //! maneuver with a long name, weather injected (the time gets wide) and the
    //! arrival delta at `+1 h 34 min`; 2: arrived.
    function scene(kind as Number) as BurnInScene {
        var route = NavAssert.straightRoute(800);
        route.turnPointIdx = [10, 120, 400, 799] as Array<Number>;
        route.turnType = [
            Protocol.TURN_RIGHT, Protocol.TURN_ROUNDABOUT, Protocol.TURN_LEFT, Protocol.TURN_ARRIVE
        ] as Array<Number>;
        route.turnExit = [0, 3, 0, 0] as Array<Number>;
        route.turnName = [
            "Rua A", "Rotatória", "Avenida Doutor Francisco Mesquita Muito Comprida", "Aeroporto de Congonhas"
        ] as Array<String>;
        route.destName = "Aeroporto de Congonhas";
        route.durationS = 2340;

        var nav = new NavState();
        var matcher = new MapMatcher(route);
        if (kind >= 1) {
            nav.applyFix(0.0, 20000.0, 18.0, 1.2);
            matcher.update(0.0, 20000.0);
            // C16.5: the widest arrival delta, with time (+1 h 34 min), next to the time.
            nav.plannedArrivalS = Time.now().value() + NavEngine.remainingSeconds(route, matcher, nav) - 5640;
        }
        if (kind == 2) {
            nav.applyFix(0.0, 79900.0, 2.0, 0.3);
            matcher.update(0.0, 79900.0);
            nav.phase = NavPhase.ARRIVED;
        }
        if (kind == 3) {
            // Off route (C11): 60 m east of it, recalculation request made.
            nav.phase = NavPhase.NAVIGATING;
            nav.applyFix(60.0, 20000.0, 18.0, 1.2);
            matcher.update(60.0, 20000.0);
            nav.offRoute = OffRoute.REQUESTED;
        }
        return new BurnInScene(route, nav, matcher);
    }

    //! Is the corner `(x, y)` inside the glass minus the RNF-05 margin?
    function insideGlass(x as Number, y as Number) as Boolean {
        var limit = 227 - DesignTokens.EDGE_MARGIN;
        var dx = x - 227;
        var dy = y - 227;
        return dx * dx + dy * dy <= limit * limit;
    }

    //! **The `Hud`'s own two rulers**, applied after the shift and
    //! with the plain RNF-05 margin (the layout reserved `orbit_px` extra):
    //! - maneuver line and bottom card: all 4 corners inside the glass
    //!   (`topFit`/`bottomFit`);
    //! - time and street name: the width fits in the screen chord at the height of the middle
    //!   of the line, with the same 8 px of slack on each side as `fitStreet`. The
    //!   time was never fitted by the corner: the font body box (with the
    //!   weather line) already went past the circle at 100% before C10, and what counts
    //!   is where the ink lands.
    function boxInside(hud as Hud, box as Array<Number>) as Boolean {
        var kind = box[0] as Number;
        if (kind == hud.BOX_CLOCK || kind == hud.BOX_STREET) {
            var mid = ((box[2] as Number) + (box[4] as Number)) / 2;
            var half = hud.halfChord(mid) - 8;
            return (box[1] as Number) >= 227 - half && (box[3] as Number) <= 227 + half;
        }
        return cornersInside(box);
    }

    //! The four corners of a box `[type, left, top, right, bottom]`.
    function cornersInside(box as Array<Number>) as Boolean {
        var l = box[1] as Number;
        var t = box[2] as Number;
        var r = box[3] as Number;
        var b = box[4] as Number;
        return insideGlass(l, t) && insideGlass(r, t) && insideGlass(l, b) && insideGlass(r, b);
    }

    //! Clean HUD scale and Config; a test that touches them ends with [done].
    function begin(scalePct as Number) as Void {
        Config.reset(false);
        Config.values[Config.KEY_HUD_PCT - 1] = scalePct;
        Config.revision++;
    }

    function done() as Void {
        WeatherInfo.clear();
        Config.reset(false);
    }

    //! Do two boxes `[type, left, top, right, bottom]` share area? Touching does not count.
    function overlap(a as Array<Number>, b as Array<Number>) as Boolean {
        return (a[1] as Number) < (b[3] as Number) && (b[1] as Number) < (a[3] as Number)
            && (a[2] as Number) < (b[4] as Number) && (b[2] as Number) < (a[4] as Number);
    }

    //! Payload of a single-key `CONFIG` (`count`, `key`, `value` uint16).
    function one(key as Number, value as Number) as ByteArray {
        var payload = new [4]b;
        payload[0] = 1;
        payload[1] = key;
        payload[2] = (value >> 8) & 0xFF;
        payload[3] = value & 0xFF;
        return payload;
    }
}

//! Over a whole orbit (the 8 points), in 3 scenarios and at both ends of the HUD
//! scale, no element goes past the RNF-05 area; and the HUD shifts exactly
//! what it reserved. **The canary** (`sim.py test --canary`) shifts 40 px against the
//! margin of `Config.orbitPx()`: it must fail here.
(:test)
function hudOrbitStaysInsideSafeArea(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var scales = [100, DesignTokens.HUD_SCALE_MAX_PCT] as Array<Number>;
    var checked = 0;

    for (var s = 0; s < scales.size(); s++) {
        for (var kind = 0; kind <= 2; kind++) {
            var scene = BurnInAssert.scene(kind);
            for (var point = 0; point < BurnIn.POINTS; point++) {
                BurnInAssert.begin(scales[s] as Number);
                WeatherInfo.clear();
                if (kind == 1) {
                    WeatherInfo.inject(24, 2);
                }
                var hud = new Hud();
                hud.orbitOverride = point;
                hud.draw(dc, scene.route, scene.nav, scene.matcher);

                Test.assertMessage(hud.orbitAmplitude() <= Config.orbitPx(),
                    "the HUD shifts " + hud.orbitAmplitude().toString() + " px and reserved only "
                    + Config.orbitPx().toString());
                Test.assertMessage(hud.boxes.size() >= 2, "the HUD drew (scene " + kind.toString() + ")");

                for (var i = 0; i < hud.boxes.size(); i++) {
                    var box = hud.boxes[i] as Array<Number>;
                    var where = "scale " + (scales[s] as Number).toString() + "% scene " + kind.toString()
                        + " point " + point.toString() + " element " + (box[0] as Number).toString()
                        + " [" + (box[1] as Number).toString() + "," + (box[2] as Number).toString()
                        + "," + (box[3] as Number).toString() + "," + (box[4] as Number).toString() + "]";
                    Test.assertMessage((box[1] as Number) >= 0 && (box[3] as Number) <= BurnInAssert.SIZE
                        && (box[2] as Number) >= DesignTokens.TOP_Y,
                        "off screen: " + where);
                    Test.assertMessage(BurnInAssert.boxInside(hud, box),
                        "the shift takes it off the glass (RNF-05): " + where);
                    checked++;
                }
            }
        }
    }
    logger.debug("boxes checked: " + checked.toString() + " (amplitude " + Config.orbitPx().toString() + " px)");
    BurnInAssert.done();
    return true;
}

//! **The size groups at the ends, mixed** (C16.5): each of the 4 groups
//! (`dist_pct`, `eta_pct`, `text_pct`, `arrow_pct`) at the floor or the ceiling of the scale,
//! in the 16 combinations and the 3 scenarios. No element leaves the glass and no pair
//! of elements overlaps. The orbit is not included: it moves everything together, and the ceiling
//! of each group is already that of everything together with the orbit (`hudOrbitStaysInsideSafeArea`).
// prevents: the rider putting distance at the ceiling with text at the floor via the app (Igor's request, C16.5)
// and the layout, which until C16 knew only one % for everything, overlapping the time, the maneuver and the street.
(:test)
function groupExtremesStayInsideAndApart(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var keys = [Config.KEY_DIST_PCT, Config.KEY_ETA_PCT, Config.KEY_TEXT_PCT, Config.KEY_ARROW_PCT] as Array<Number>;
    var checked = 0;

    for (var combo = 0; combo < 16; combo++) {
        for (var kind = 0; kind <= 2; kind++) {
            BurnInAssert.begin(100);
            var label = "";
            for (var k = 0; k < keys.size(); k++) {
                var key = keys[k] as Number;
                var pct = ((combo >> k) & 1) == 1 ? DesignTokens.HUD_SCALE_MAX_PCT : DesignTokens.HUD_SCALE_MIN_PCT;
                Config.values[key - 1] = pct;
                label += (Config.NAMES[key - 1] as String) + "=" + pct.toString() + " ";
            }
            Config.revision++;
            WeatherInfo.clear();
            if (kind == 1) {
                WeatherInfo.inject(24, 2);
            }
            var scene = BurnInAssert.scene(kind);
            var hud = new Hud();
            hud.orbitOverride = 0;
            hud.draw(dc, scene.route, scene.nav, scene.matcher);

            for (var i = 0; i < hud.boxes.size(); i++) {
                var box = hud.boxes[i] as Array<Number>;
                var where = label + "scene " + kind.toString() + " element " + (box[0] as Number).toString();
                Test.assertMessage(BurnInAssert.boxInside(hud, box), "off the glass: " + where);
                for (var j = i + 1; j < hud.boxes.size(); j++) {
                    var other = hud.boxes[j] as Array<Number>;
                    Test.assertMessage(!BurnInAssert.overlap(box, other),
                        "overlapped: " + where + " with element " + (other[0] as Number).toString());
                }
                checked++;
            }
        }
    }
    logger.debug("boxes checked at the group ends: " + checked.toString());
    BurnInAssert.done();
    return true;
}

//! The orbit moves: the 8 points of the ring are distinct, the amplitude is the requested one, and
//! **one minute's shift is never the next minute's**, for any
//! step in the range (10..60 s) and at any minute of the day.
(:test)
function orbitNeverRepeatsThePixelTwoMinutesInARow(logger as Logger) as Boolean {
    for (var a = 0; a < BurnIn.POINTS; a++) {
        for (var b = a + 1; b < BurnIn.POINTS; b++) {
            Test.assertMessage(BurnIn.dx(a, 1) != BurnIn.dx(b, 1) || BurnIn.dy(a, 1) != BurnIn.dy(b, 1),
                "points " + a.toString() + " and " + b.toString() + " of the ring are equal");
        }
        var reach = BurnIn.dx(a, 3);
        Test.assertMessage(reach >= -3 && reach <= 3, "the ring exceeds the amplitude");
    }

    var steps = [10, 12, 15, 20, 30, 60] as Array<Number>;
    for (var s = 0; s < steps.size(); s++) {
        var step = steps[s] as Number;
        for (var minute = 0; minute < 1440; minute++) {
            var now = minute * 60 + 7;
            var here = BurnIn.index(now, step);
            var next = BurnIn.index(now + 60, step);
            Test.assertMessage(
                BurnIn.dx(here, 1) != BurnIn.dx(next, 1) || BurnIn.dy(here, 1) != BurnIn.dy(next, 1),
                "step " + step.toString() + " s: minute " + minute.toString() + " repeats the pixel");
        }
    }
    return true;
}

//! The two new `CONFIG` keys: the range belongs to the watch. 0 turns the orbit off,
//! one px above the ceiling and a step outside 10..60 reject the whole message.
(:test)
function orbitConfigIsBoundedByTheWatch(logger as Logger) as Boolean {
    var top = Config.MAXS[Config.KEY_ORBIT_PX - 1] as Number;
    Config.reset(false);
    Diag.clear();

    var ok = Config.applyPayload(BurnInAssert.one(Config.KEY_ORBIT_PX, top), false);
    Test.assertMessage(ok && Config.orbitPx() == top, "the ceiling applies");
    ok = Config.applyPayload(BurnInAssert.one(Config.KEY_ORBIT_PX, 0), false);
    Test.assertMessage(ok && Config.orbitPx() == 0, "0 switches the orbit off");

    ok = Config.applyPayload(BurnInAssert.one(Config.KEY_ORBIT_PX, top + 1), false);
    Test.assertMessage(!ok && Config.orbitPx() == 0, "one px above the ceiling is refused");
    ok = Config.applyPayload(BurnInAssert.one(Config.KEY_ORBIT_S, 9), false);
    Test.assertMessage(!ok, "a 9 s step is refused");
    ok = Config.applyPayload(BurnInAssert.one(Config.KEY_ORBIT_S, 61), false);
    Test.assertMessage(!ok, "a 61 s step is refused (two minutes on the same pixel)");
    Test.assertMessage(ConfigAssert.logged("config refused orbit_s=61 outside 10..60"), "the refusal line");

    BurnInAssert.done();
    Diag.clear();
    return true;
}

//! With `orbit_px = 0` the HUD is the one from before C10: no ring point moves a
//! box, and the margin reserve goes away too.
(:test)
function orbitOffDrawsEveryPointInTheSamePlace(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    Config.values[Config.KEY_ORBIT_PX - 1] = 0;

    var scene = BurnInAssert.scene(1);
    var first = new Hud();
    first.orbitOverride = 0;
    first.draw(dc, scene.route, scene.nav, scene.matcher);
    var other = new Hud();
    other.orbitOverride = 5;
    other.draw(dc, scene.route, scene.nav, scene.matcher);

    Test.assertEqualMessage(other.boxes.size(), first.boxes.size(), "same elements");
    for (var i = 0; i < first.boxes.size(); i++) {
        var a = first.boxes[i] as Array<Number>;
        var b = other.boxes[i] as Array<Number>;
        for (var j = 0; j < 5; j++) {
            Test.assertEqualMessage(b[j], a[j], "orbit_px 0: element " + i.toString() + " moved");
        }
    }
    BurnInAssert.done();
    return true;
}

//! **The off-route card** (C11): the return arrow, the meters to the route and
//! "Recalculating…" or "Where's the phone?" in amber. At both ends of the HUD scale and
//! at the 8 orbit points, nothing leaves the RNF-05 area; and the HUD says in the log what it
//! put on the screen, which is what `sim.py ride --desvio` reads.
(:test)
function theWayBackCardStaysInsideSafeArea(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var scales = [DesignTokens.HUD_SCALE_MIN_PCT, DesignTokens.HUD_SCALE_MAX_PCT] as Array<Number>;
    var states = [OffRoute.REQUESTED, OffRoute.NO_PHONE] as Array<Number>;
    var checked = 0;
    Diag.clear();

    for (var s = 0; s < scales.size(); s++) {
        for (var st = 0; st < states.size(); st++) {
            var scene = BurnInAssert.scene(3);
            scene.nav.offRoute = states[st] as Number;
            for (var point = 0; point < BurnIn.POINTS; point++) {
                BurnInAssert.begin(scales[s] as Number);
                WeatherInfo.clear();
                WeatherInfo.inject(24, 2);
                var hud = new Hud();
                hud.orbitOverride = point;
                hud.draw(dc, scene.route, scene.nav, scene.matcher);

                var hasText = false;
                for (var i = 0; i < hud.boxes.size(); i++) {
                    var box = hud.boxes[i] as Array<Number>;
                    if ((box[0] as Number) == hud.BOX_STREET) {
                        hasText = true;
                    }
                    var where = "scale " + (scales[s] as Number).toString() + "% state "
                        + (states[st] as Number).toString() + " point " + point.toString()
                        + " element " + (box[0] as Number).toString()
                        + " [" + (box[1] as Number).toString() + "," + (box[2] as Number).toString()
                        + "," + (box[3] as Number).toString() + "," + (box[4] as Number).toString() + "]";
                    Test.assertMessage((box[1] as Number) >= 0 && (box[3] as Number) <= BurnInAssert.SIZE
                        && (box[2] as Number) >= DesignTokens.TOP_Y,
                        "off screen: " + where);
                    Test.assertMessage(BurnInAssert.boxInside(hud, box),
                        "the off-route card leaves the glass (RNF-05): " + where);
                    checked++;
                }
                Test.assertMessage(hasText, "the card has no warning line (scale "
                    + (scales[s] as Number).toString() + "%)");
                // The `Diag` ring holds 24 lines: checked every frame.
                var said = (states[st] as Number) == OffRoute.NO_PHONE ? "hud No phone" : "hud Recalculating";
                Test.assertMessage(ConfigAssert.logged(said), "the log does not say '" + said + "'");
                Test.assertMessage(ConfigAssert.logged("hud arrow back 60m"), "the log does not say the arrow back");
                Diag.clear();
            }
        }
    }
    logger.debug("boxes checked: " + checked.toString());
    BurnInAssert.done();
    Diag.clear();
    return true;
}

// prevents: the rider lighting up too much in the same place. It does not move with the HUD orbit (stays at the
// anchor the whole trip), and the sheet 4 ring lights up more than the old chevron; the math
// keeps the ring and the arrow under 1% of the glass, a tenth of the low-power mode's 10%
// rule. The halo is dark and the destination dot moves with the map: they stay out.
(:test)
function thePuckLightsLittleOfTheGlass(logger as Logger) as Boolean {
    var glass = Math.PI * 227 * 227;
    var lit = MapRenderer.puckLitPx();
    logger.debug("puck: " + lit.toString() + " px lit while still, " + (lit * 100.0 / glass).format("%.2f")
        + "% of the glass");
    Test.assertMessage(lit < glass / 100, "the puck lights " + lit.toString() + " px while still");
    Test.assertMessage(MapRenderer.PUCK_RING_R + MapRenderer.PUCK_RING_W / 2 <= DesignTokens.HALO_RADIUS,
        "the ring fits in the halo");
    Test.assertMessage(MapRenderer.DEST_EDGE_R < MapRenderer.PUCK_RING_R - MapRenderer.PUCK_RING_W / 2,
        "at arrival, the dot fits inside the ring");
    return true;
}
