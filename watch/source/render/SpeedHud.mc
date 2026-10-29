import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;

//! **The route's speed cameras** (C16.6, 05 §RADARS): the phone searches OSM, filters by route and
//! direction, and sends; the watch stores them in the route (`RouteModel.radar*`) and here decides when to show and
//! warn. Only those in the direction the route passes (Igor, 2026-10-22: a camera that only catches the other
//! direction does not warn): the phone does the filtering. In the RMSP OSM (2026-10-22), 1112 of the 1430 are
//! on a one-way road (the direction is the road's), 129 have `direction` and 36 are in an
//! `enforcement` relation: 1243 (87%) with a known direction. The other 188 warn in both.
module Radars {

    //! Lead at the limit: 10 s to the camera, never less than [MIN_M].
    const LEAD_S = 10;
    //! Each km/h above the limit adds half a second of lead (Igor, 2026-10-22: «if I'm
    //! way over, show it earlier»). At 72 on a 50 camera it is 21 s, about 420 m.
    const LEAD_PER_KMH_X2 = 1;
    const MIN_M = 250;
    //! Never farther than this: it is Organic Maps' `kShowCameraDistanceM`.
    const MAX_M = 1000;

    //! From how many km/h above the limit the edge ring turns red (Igor, 2026-10-22:
    //! «5 km/h over already counts as over»).
    const OVER_KMH = 5;

    //! The nearest camera ahead of `distAlong`, up to [MAX_M]: the index in the route, or −1. The list
    //! comes in distance order, so the first one ahead is the nearest.
    function ahead(route as RouteModel, distAlong as Float) as Number {
        var dist = route.radarDist;
        var here = distAlong.toNumber();
        for (var i = 0; i < dist.size(); i++) {
            var gap = (dist[i] as Number) - here;
            if (gap > 0) {
                return gap <= MAX_M ? i : -1;
            }
        }
        return -1;
    }

    //! At what distance from the camera the sign appears, riding at `kmh` toward a camera of `limit` (0 =
    //! unknown: only the 10 s).
    function showM(kmh as Number, limit as Number) as Number {
        var over = limit > 0 && kmh > limit ? kmh - limit : 0;
        var seconds = LEAD_S + over * LEAD_PER_KMH_X2 / 2.0;
        var metres = (kmh / 3.6 * seconds).toNumber();
        return metres < MIN_M ? MIN_M : (metres > MAX_M ? MAX_M : metres);
    }

    //! The camera whose sign is on screen now, or −1: the next one ahead, within [showM].
    function shown(route as RouteModel, distAlong as Float, kmh as Number) as Number {
        var i = ahead(route, distAlong);
        if (i < 0) {
            return -1;
        }
        var gap = (route.radarDist[i] as Number) - distAlong.toNumber();
        return gap <= showM(kmh, route.radarLimit[i] as Number) ? i : -1;
    }

    //! The camera icon's sizes in px of this screen ([SpeedHud.camera]): the black edge and red disc radii, the
    //! body's back, the lens joint, the lens tip and the small pad (15, 13, 8, 5, 9 and 2 reference px). Made on
    //! the first icon and kept: the glass does not change while the app runs.
    var iconPx as Array<Number>? = null;

    function cameraPx() as Array<Number> {
        var px = iconPx;
        if (px == null) {
            px = [Screen.px(15), Screen.px(13), Screen.px(8), Screen.px(5), Screen.px(9), Screen.px(2)]
                as Array<Number>;
            iconPx = px;
        }
        return px;
    }

    //! The icon of each camera on the map, above the route and below the rider.
    function drawMarkers(dc as Dc, map as MapRenderer, route as RouteModel) as Void {
        var xs = route.radarX;
        // A camera is skipped when its icon is fully off the glass: 20 reference px of slack around it.
        var slack = Screen.pxf(20);
        var far = Screen.size + slack;
        for (var i = 0; i < xs.size(); i++) {
            var x = map.screenX(xs[i] as Float, route.radarY[i] as Float);
            var y = map.screenY(xs[i] as Float, route.radarY[i] as Float);
            if (x < -slack || x > far || y < -slack || y > far) {
                continue;
            }
            SpeedHud.camera(dc, x, y);
        }
    }
}

//! Near a camera, its sign (R-19: red rim, black number) and the distance; with unknown limit,
//! the camera instead of the number. Well above the limit, the edge ring turns red. Far from a camera, nothing.
//! The bike's speed never appears: the bike's speedometer already shows it (Igor, 2026-10-22).
class SpeedHud {

    //! The sign, to the left of the rider, where the glass is still wide. Sizes and positions of this class
    //! are in reference px (the Venu 4 45 mm), converted with `Screen.px` where they are drawn.
    const SIGN_X = 74;
    const SIGN_Y = 238;
    const SIGN_R = 30;
    const SIGN_RING = 7;

    const RED = 0xE53935;

    //! The ring: a thin stroke hugging the screen edge (radius 227 at 454) that fades toward the center over
    //! [RING_FADE_PX] (Igor, 2026-10-22: «thinner and fading a bit»; at radius 214
    //! of the home screen ring a black band was left outside).
    const RING_R = 226;
    const RING_FADE_PX = 26;
    const RING_ALPHA = 150;

    private var _signFont = Graphics.FONT_MEDIUM;
    private var _distFont = Graphics.FONT_SMALL;
    //! The camera of the last sign written to the log, to write only on change.
    private var _said as Number = -1;

    function initialize() {
        if (Graphics has :getVectorFont) {
            _signFont = face(DesignTokens.FACE_NUMBER, Screen.px(30), _signFont);
            _distFont = face(DesignTokens.FACE_NUMBER, Screen.px(26), _distFont);
        }
    }

    private function face(name as String, px as Number, fallback) {
        try {
            var font = Graphics.getVectorFont({ :face => name, :size => px });
            if (font != null) {
                return font;
            }
        } catch (ex) {
        }
        return fallback;
    }

    function draw(dc as Dc, nav as NavState, matcher as MapMatcher, route as RouteModel) as Void {
        if (route.radarDist.size() == 0 || !nav.hasFix || nav.phase == NavPhase.ARRIVED || !matcher.matched) {
            return;
        }
        var kmh = (nav.speedMps * 3.6 + 0.5).toNumber();
        // Far from the camera, nothing: the sign only appears within the lead, which grows with
        // the speed and with how far it exceeds the limit.
        var i = Radars.shown(route, matcher.distAlong, kmh);
        if (i != _said) {
            _said = i;
            if (i >= 0) {
                Diag.add("radar " + i.toString() + " on screen: " + (route.radarLimit[i] as Number).toString()
                    + " km/h at " + ((route.radarDist[i] as Number) - matcher.distAlong.toNumber()).toString()
                    + " m, " + kmh.toString() + " km/h d" + (route.radarDist[i] as Number).toString());
            }
        }
        if (i < 0) {
            return;
        }
        var limit = route.radarLimit[i] as Number;
        var gap = (route.radarDist[i] as Number) - matcher.distAlong.toNumber();
        if (limit > 0 && kmh >= limit + Radars.OVER_KMH) {
            drawRing(dc);
        }
        drawSign(dc, limit);
        drawDistance(dc, gap);
    }

    //! The thin edge stroke and, inward, 2 px rings with less and less alpha. Without alpha
    //! (API Level < 4), only the stroke.
    private function drawRing(dc as Dc) as Void {
        var centre = Screen.half;
        var edge = Screen.px(RING_R);
        var fade = Screen.px(RING_FADE_PX);
        // The pens (3 and 2) and the 2 px step between the rings stay: the rings must touch, whatever the glass.
        dc.setPenWidth(3);
        dc.setColor(RED, Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(centre, centre, edge);
        if (Graphics has :createColor && dc has :setStroke) {
            dc.setPenWidth(2);
            for (var d = 2; d < fade; d += 2) {
                var alpha = RING_ALPHA * (fade - d) / fade;
                dc.setStroke(Graphics.createColor(alpha, 0xE5, 0x39, 0x35));
                dc.drawCircle(centre, centre, edge - 1 - d);
            }
        }
        dc.setPenWidth(1);
    }

    private function drawSign(dc as Dc, limit as Number) as Void {
        var x = Screen.px(SIGN_X);
        var y = Screen.px(SIGN_Y);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, Screen.px(SIGN_R + 3));
        dc.setColor(RED, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, Screen.px(SIGN_R));
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, Screen.px(SIGN_R - SIGN_RING));
        if (limit <= 0) {
            // No `maxspeed` in OSM: the sign carries the camera, not an invented number.
            camera(dc, x, y);
            return;
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, _signFont, limit.toString(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! The distance to the camera, below the sign, on a black cutout (Igor, 2026-10-22: without the
    //! camera symbol beside the sign).
    private function drawDistance(dc as Dc, metres as Number) as Void {
        var text = (metres / 10 * 10).toString() + " m";
        var w = dc.getTextWidthInPixels(text, _distFont);
        var x = Screen.px(SIGN_X);
        var y = Screen.px(SIGN_Y) + Screen.px(SIGN_R) + Screen.px(20);
        var padX = Screen.px(8);
        var halfH = Screen.px(16);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x - w / 2 - padX, y - halfH, w + 2 * padX, 2 * halfH, padX);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, _distFont, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    //! The camera icon: a white camera on a red disc with a black border (15 px of radius at 454).
    static function camera(dc as Dc, x as Numeric, y as Numeric) as Void {
        // The body ends where the lens starts (`join`), whatever the rounding of each size.
        var px = Radars.cameraPx();
        var back = px[2] as Number;
        var join = px[3] as Number;
        var tip = px[4] as Number;
        var small = px[5] as Number;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, px[0] as Number);
        dc.setColor(0xE53935, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y, px[1] as Number);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x - back, y - join, back + join, 2 * join, small);
        dc.fillPolygon([[x + join, y - small], [x + tip, y - join], [x + tip, y + join], [x + join, y + small]]
            as Array<[Numeric, Numeric]>);
        dc.setColor(0xE53935, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x - small, y, small);
    }
}
