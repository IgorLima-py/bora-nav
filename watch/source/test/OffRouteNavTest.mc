import Toybox.Lang;
import Toybox.Test;

//! Off route, the map-matching (C11).
//!
//! More than 100 m from the route the local window loses the rider and `MapMatcher` does the
//! global search. Until C11 it measured **all** segments, on every fix, while
//! the rider was far: on a route at the protocol ceiling that is 4,000 segments
//! per second inside the GPS callback, the same cost pattern that already killed
//! the app by watchdog twice (corridor on 2026-08-01, POLY in C6a). Before
//! C11 this almost never happened; now it is the state the watch spends 10 s in on
//! every wrong turn.
(:test)
module OffRouteNavAssert {

    //! A zigzag route of `points` points: goes up 100 m per point and goes back and
    //! forth 300 m sideways every 40 points, with a block index like the real one
    //! (`PolyParseJob`).
    function zigzag(points as Number) as RouteModel {
        var route = new RouteModel();
        var xs = new [points] as Array<Float>;
        var ys = new [points] as Array<Float>;
        var cum = new [points] as Array<Float>;
        var total = 0.0;
        for (var i = 0; i < points; i++) {
            var phase = i % 40;
            xs[i] = (phase < 20 ? phase * 15 : (40 - phase) * 15).toFloat();
            ys[i] = (i * 100).toFloat();
            if (i > 0) {
                total += Projection.distance(xs[i - 1] as Float, ys[i - 1] as Float, xs[i] as Float, ys[i] as Float);
            }
            cum[i] = total.toFloat();
        }
        route.xs = xs;
        route.ys = ys;
        route.cum = cum;
        route.blockBox = RouteModel.boxesOf(xs, ys);
        return route;
    }

    //! The same route without the index: `MapMatcher` falls back to the full sweep, which is
    //! the reference for the indexed search.
    function withoutIndex(route as RouteModel) as RouteModel {
        var plain = new RouteModel();
        plain.xs = route.xs;
        plain.ys = route.ys;
        plain.cum = route.cum;
        return plain;
    }

    //! The work ceiling of a fix off a **straight** route: the local window, one
    //! box test in each of the two passes, and up to 4 blocks opened point by point (the rider's and the
    //! neighbors that touch the same distance). It comes from the `MapMatcher` constants
    //! and the block size, not from a chosen number.
    function ceiling(matcher as MapMatcher, route as RouteModel) as Number {
        return matcher.WINDOW_BACK + matcher.WINDOW_AHEAD + 1
            + 2 * (route.blockBox.size() / 4)
            + 4 * RouteModel.BLOCK_POINTS;
    }
}

//! Far from a route at the protocol ceiling, the fix cost does not follow the
//! route length, and the matching stays correct.
(:test)
function farFromALongRouteTheMatchCostStaysBounded(logger as Logger) as Boolean {
    var points = Protocol.MAX_POLY_POINTS;
    var route = NavAssert.straightRoute(points);
    var matcher = new MapMatcher(route);
    var ceiling = OffRouteNavAssert.ceiling(matcher, route);
    Test.assertMessage(ceiling < points / 4, "the test ceiling must be well below the route");

    // On the route, in the middle of it (point 2,000 is at y = 200,000 m).
    matcher.update(0.0, 200000.0);
    var onRoute = matcher.work;

    // 500 m to the side: off the route and beyond the local search.
    var worst = 0;
    for (var s = 1; s <= 15; s++) {
        matcher.update(500.0, 200000.0 + s * 15);
        if (matcher.work > worst) {
            worst = matcher.work;
        }
        Test.assertMessage(NavAssert.near(matcher.crossTrack, 500.0, 0.5), "500 m from the route");
        Test.assertEqualMessage(matcher.segmentIdx, 2000 + (s * 15) / 100, "matched on the stretch next to it");
    }

    // And a jump to another stretch, 15 km from there: the global search finds it.
    matcher.update(500.0, 350020.0);
    if (matcher.work > worst) {
        worst = matcher.work;
    }
    Test.assertEqualMessage(matcher.segmentIdx, 3500, "the jump was found");
    Test.assertMessage(NavAssert.near(matcher.crossTrack, 500.0, 0.5), "500 m from the new stretch");

    logger.debug("work per fix: " + onRoute.toString() + " on route, " + worst.toString()
        + " at the worst off-route fix, ceiling " + ceiling.toString() + ", route of " + points.toString() + " pts");
    Test.assertMessage(worst <= ceiling,
        "off route the fix measured " + worst.toString() + " (ceiling " + ceiling.toString() + "): the global search "
        + "is sweeping the whole route on every fix");
    return true;
}

//! The index is a shortcut, not an approximation: on a route that goes back and forth, the indexed
//! search finds the same segment, at the same distance, as the full sweep.
(:test)
function theIndexedSearchFindsWhatTheFullScanFinds(logger as Logger) as Boolean {
    var route = OffRouteNavAssert.zigzag(1200);
    var plain = OffRouteNavAssert.withoutIndex(route);
    var probes = 0;

    for (var i = 0; i < 60; i++) {
        // Points spread on both sides of the route, from ~120 m to 900 m from it.
        var y = (i * 2917) % 119000 + 300;
        var side = i % 2 == 0 ? 1 : -1;
        var x = side * (420 + (i * 131) % 780) + 150;

        var indexed = new MapMatcher(route);
        var full = new MapMatcher(plain);
        indexed.update(x.toFloat(), y.toFloat());
        full.update(x.toFloat(), y.toFloat());
        if (full.crossTrack <= indexed.GLOBAL_SEARCH_M) {
            continue;
        }
        probes++;
        var where = "point (" + x.toString() + ", " + y.toString() + ")";
        Test.assertMessage(NavAssert.near(indexed.crossTrack, full.crossTrack, 0.01),
            where + ": with index " + indexed.crossTrack.format("%.2f") + " m, sweep "
            + full.crossTrack.format("%.2f") + " m");
        Test.assertEqualMessage(indexed.segmentIdx, full.segmentIdx, where + ": segment");
    }
    Test.assertMessage(probes >= 20, "too few probe points fell far from the route: " + probes.toString());
    return true;
}
