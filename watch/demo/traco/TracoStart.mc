import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The stroke bench in the simulator (C16.5): only enters through `watch/traco.jungle`, which
//! `tools/sim.py shots --traco` builds. Igor found the route "torta e feia" and the streets "muito
//! feias"; the enlarged photo showed lumps on the route's edge and wedges at the street bends. This
//! bench draws the same lines the old way (on the left, code copied here) and the
//! new way (on the right, the real `MapRenderer`), for `sim.py` to crop and enlarge.
//!
//! Pages: 0, the ruler (a line of each width, at whole y and at y + 0.5, and the disc of each radius:
//! `sim.py` measures how many pixels each one lights); 1, the route on an S curve with a vertex every
//! 2.5 px; 2, the streets (14 px zigzag, 7 px curve and a T).
//!
//! The `[trace]` lines are the protocol with `sim.py`: `ready <page>` and `end`.
function demoAfterLoad() as Boolean {
    var view = new TraceView();
    WatchUi.switchToView(view, new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_IMMEDIATE);
    var run = new TraceRun(view);
    _traceRun = run;
    run.start();
    return true;
}

var _traceRun as TraceRun? = null;

class TraceRun {

    const PAGES = 3;
    //! The same slack as the arrows sheet: `ready` reaches `sim.py` ~2 s after the screen.
    const HOLD_S = 8;

    private var _view as TraceView;
    private var _timer as Timer.Timer?;
    private var _seconds as Number = 0;

    function initialize(view as TraceView) {
        _view = view;
    }

    function start() as Void {
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
        System.println("[trace] start " + PAGES.toString() + " pages");
    }

    function onTick() as Void {
        _seconds++;
        if (_seconds == 1) {
            System.println("[trace] ready " + _view.page.toString());
        }
        if (_seconds < HOLD_S) {
            return;
        }
        _seconds = 0;
        _view.page++;
        if (_view.page >= PAGES) {
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.println("[trace] end");
            System.exit();
        }
        WatchUi.requestUpdate();
    }
}

class TraceView extends WatchUi.View {

    var page as Number = 0;

    //! Ruler widths: the streets' (14/11/9/7), the route's (12) and its edge's (18).
    static const WIDTHS = [7, 9, 11, 12, 14, 18] as Array<Number>;

    private var _map as MapRenderer;

    function initialize() {
        View.initialize();
        _map = new MapRenderer();
        // 1 m per pixel, heading zero, center at the origin: screen = (227 + x, 276 − y).
        _map.beginAt(0.0, 0.0, 1.0, 0.0);
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);
        if (page == 0) {
            rulerPage(dc);
        } else if (page == 1) {
            routePage(dc);
        } else {
            streetPage(dc);
        }
        dc.setPenWidth(1);
    }

    //! One row per width at y = 90 + 50k: line at whole y (x 70..170), line at y + 0.5
    //! (x 190..290), disc of radius w/2 (x 330) and of radius (w − 1)/2 (x 380). White on black.
    private function rulerPage(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        for (var k = 0; k < WIDTHS.size(); k++) {
            var w = WIDTHS[k] as Number;
            var y = 90 + 50 * k;
            dc.setPenWidth(w);
            dc.drawLine(70, y, 170, y);
            dc.drawLine(190.0, y + 0.5, 290.0, y + 0.5);
            dc.fillCircle(330, y, w / 2);
            dc.fillCircle(380, y, (w - 1) / 2);
        }
    }

    //! The route on an S curve, a vertex every 2.5 px (the map's decimation at riding zoom),
    //! before on the left and after on the right, each with the edge and the cyan.
    private function routePage(dc as Dc) as Void {
        for (var side = 0; side < 2; side++) {
            var ox = side == 0 ? 0 : 227;
            var pts = sCurve(ox);
            var sx = pts[0] as Array<Float>;
            var sy = pts[1] as Array<Float>;
            for (var pass = 0; pass < 2; pass++) {
                var casing = pass == 0;
                dc.setColor(casing ? DesignTokens.ROUTE_CASING : DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
                var width = casing ? DesignTokens.ROUTE_PX + 2 * DesignTokens.ROUTE_CASING_PX : DesignTokens.ROUTE_PX;
                dc.setPenWidth(width);
                if (side == 0) {
                    oldRange(dc, sx, sy, width / 2);
                } else {
                    var radius = _map.capRadius(width);
                    _map.drawRange(dc, worldX(sx), worldY(sy), 0, sx.size() - 1, radius,
                        _map.joinLimit(radius), null, null, true, true);
                }
            }
        }
    }

    //! The streets: 14 px zigzag (bends of ~10°, 45° and 90°), 7 px curve with a vertex every
    //! 12 px, and a T of two 11 px ways. Before on the left (antialiasing only on the 14 px, as it was),
    //! after on the right.
    private function streetPage(dc as Dc) as Void {
        var shapes = [
            [[30.0, 90.0, 150.0, 175.0, 120.0, 60.0] as Array<Float>,
             [110.0, 100.0, 140.0, 200.0, 245.0, 230.0] as Array<Float>, 14, 0],
            [arcXs(), arcYs(), 7, 3],
            [[35.0, 200.0] as Array<Float>, [330.0, 330.0] as Array<Float>, 11, 1],
            [[115.0, 115.0] as Array<Float>, [330.0, 400.0] as Array<Float>, 11, 1]
        ] as Array<Array>;
        for (var side = 0; side < 2; side++) {
            var ox = side == 0 ? 0.0 : 227.0;
            for (var k = 0; k < shapes.size(); k++) {
                var shape = shapes[k] as Array;
                var xs = shift(shape[0] as Array<Float>, ox);
                var ys = shape[1] as Array<Float>;
                var width = shape[2] as Number;
                var lod = shape[3] as Number;
                dc.setColor(DesignTokens.ROAD_COLORS[lod] as Number, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(width);
                if (side == 0) {
                    dc.setAntiAlias(lod == 0);
                    oldWay(dc, xs, ys);
                } else {
                    dc.setAntiAlias(lod <= _map.ANTIALIAS_MAX_LOD);
                    var radius = _map.capRadius(width);
                    _map.drawWay(dc, worldX(xs), worldY(ys), 0, xs.size(), radius, _map.joinLimit(radius));
                }
                dc.setAntiAlias(true);
            }
        }
    }

    //! The `drawRange` from before C16.5: truncated vertex and a disc at every vertex.
    private function oldRange(dc as Dc, sx as Array<Float>, sy as Array<Float>, capRadius as Number) as Void {
        var ax = (sx[0] as Float).toNumber();
        var ay = (sy[0] as Float).toNumber();
        for (var i = 1; i < sx.size(); i++) {
            var bx = (sx[i] as Float).toNumber();
            var by = (sy[i] as Float).toNumber();
            dc.drawLine(ax, ay, bx, by);
            if (capRadius > 1) {
                dc.fillCircle(bx, by, capRadius);
            }
            ax = bx;
            ay = by;
        }
    }

    //! The `drawWay` from before C16.5: truncated vertex, with no cap or join.
    private function oldWay(dc as Dc, sx as Array<Float>, sy as Array<Float>) as Void {
        for (var i = 1; i < sx.size(); i++) {
            dc.drawLine((sx[i - 1] as Float).toNumber(), (sy[i - 1] as Float).toNumber(),
                (sx[i] as Float).toNumber(), (sy[i] as Float).toNumber());
        }
    }

    //! S curve from y = 390 to y = 70, centered at x = ox + 113, 2.5 px step.
    private function sCurve(ox as Number) as Array<Array<Float> > {
        var xs = [] as Array<Float>;
        var ys = [] as Array<Float>;
        var y = 390.0;
        while (y >= 70.0) {
            var t = (390.0 - y) / 320.0;
            xs.add((ox + 113 + 55.0 * Math.sin(t * 2.0 * Math.PI)).toFloat());
            ys.add(y);
            y -= 2.5;
        }
        return [xs, ys] as Array<Array<Float> >;
    }

    private function arcXs() as Array<Float> {
        var xs = [] as Array<Float>;
        for (var i = 0; i <= 12; i++) {
            xs.add((60.0 + 120.0 * Math.cos(Math.PI * (1.0 + i / 24.0))).toFloat() + 120.0);
        }
        return xs;
    }

    private function arcYs() as Array<Float> {
        var ys = [] as Array<Float>;
        for (var i = 0; i <= 12; i++) {
            ys.add((300.0 + 120.0 * Math.sin(Math.PI * (1.0 + i / 24.0))).toFloat());
        }
        return ys;
    }

    private function shift(xs as Array<Float>, ox as Float) as Array<Float> {
        var out = [] as Array<Float>;
        for (var i = 0; i < xs.size(); i++) {
            out.add((xs[i] as Float) + ox);
        }
        return out;
    }

    //! From the screen to the bench's world (`beginAt(0, 0, 1, 0)`): x = sx − 227, y = 276 − sy.
    private function worldX(sx as Array<Float>) as Array<Float> {
        var out = [] as Array<Float>;
        for (var i = 0; i < sx.size(); i++) {
            out.add((sx[i] as Float) - _map.ANCHOR_X);
        }
        return out;
    }

    private function worldY(sy as Array<Float>) as Array<Float> {
        var out = [] as Array<Float>;
        for (var i = 0; i < sy.size(); i++) {
            out.add(_map.ANCHOR_Y - (sy[i] as Float));
        }
        return out;
    }
}
