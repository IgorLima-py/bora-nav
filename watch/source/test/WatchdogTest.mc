import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! **The tests that were missing: the frame that kills the app.**
//!
//! The app died on 2026-08-01 with `Watchdog Tripped Error` and a stack that
//! points at `onUpdate → draw → drawRoute → refreshRouteRanges → visible`. No
//! test in the repository could have caught it, and it is worth understanding why before reading
//! what comes below:
//!
//! - the drawing test existed, but its corridor had **300 ways spread
//!   over 78 km** — half a dozen inside the view on each frame. It proved that the
//!   code does not throw; it never came near the cost of a city;
//! - no test measured **how much** a frame costs. "Passed" meant
//!   "finished", and a frame that finishes in 200 ms finishes — and is killed.
//!
//! So these tests assert what the others did not: with a corridor the
//! size of what Overpass returns in São Paulo, **no frame goes past what the
//! watch can take**, and the streets still show up. The unit is the *work
//! point* of [MapRenderer] — rectangle test, point test or segment
//! drawn —, which is hardware-independent and so valid in the simulator.

(:test)
module CityAssert {

    //! Meters of route covered by the synthetic corridor.
    const ALONG_M = 10000.0;

    //! Block size of each LOD, in meters: expressway, arterial, collector, local.
    //! The 80 m of the local LOD is São Paulo's grid.
    const BLOCK_M = [1600.0, 800.0, 240.0, 80.0] as Array<Float>;

    //! A corridor with the density of a real city: ~920 ways and ~3,700
    //! points, which is the order of magnitude of what reached the watch on the day of the
    //! crash (`STATUS.md`: 3,971 Overpass ways → 1,842 segments → 5 chunks) and
    //! touches the [Protocol.MAX_CORRIDOR_POINTS] ceiling.
    //!
    //! Each way is a four-point "L" — one stretch across and one
    //! along —, which is the shape of a street simplified by Douglas-Peucker.
    //! Five streets per row, rows at every block, all within the ±300 m
    //! of corridor that the companion clips.
    function cityCorridor() as CorridorModel {
        var corridor = new CorridorModel();

        for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
            var blockM = BLOCK_M[lod] as Float;
            var rows = (ALONG_M / blockM).toNumber();
            var xs = [] as Array<Float>;
            var ys = [] as Array<Float>;
            var starts = [] as Array<Number>;

            for (var row = 0; row < rows; row++) {
                var y = row * blockM;
                for (var col = 0; col < 5; col++) {
                    var x = -300.0 + col * 150.0;
                    starts.add(xs.size());
                    xs.add(x);
                    ys.add(y);
                    xs.add(x + 150.0);
                    ys.add(y);
                    xs.add(x + 150.0);
                    ys.add(y + blockM);
                    xs.add(x + 300.0);
                    ys.add(y + blockM);
                }
            }
            starts.add(xs.size());
            corridor.setLod(lod, xs, ys, starts);
        }
        return corridor;
    }

    //! How many route segments the visible intervals cover **ahead of the `split` segment** (the
    //! rider's), summing the `[from, to]` pairs. It is the decimation's denominator: how many existed
    //! to draw. Until sheet 4 it counted the whole span, and the route's two passes (edge and
    //! cyan, front only) added up to that number by coincidence.
    function aheadSpan(ranges as Array<Number>, split as Number) as Number {
        var total = 0;
        for (var i = 0; i + 1 < ranges.size(); i += 2) {
            var from = ranges[i] as Number;
            var to = ranges[i + 1] as Number;
            from = from > split ? from : split;
            if (to > from) {
                total += to - from;
            }
        }
        return total;
    }

    //! A complete CORRIDOR message (header + payload) with `ways` streets of
    //! `points` points each, ready for `MessageAssembler.onData`.
    //!
    //! Built in an **already sized** `ByteArray`: building the frame with `add`
    //! would fall into the same trap the test exists to catch.
    function corridorFrame(lod as Number, ways as Number, points as Number) as ByteArray {
        var perWay = 9 + (points - 1) * 4;
        var payload = 1 + ways * perWay;
        var frame = new [Protocol.HEADER_SIZE + payload]b;

        frame[0] = Protocol.VERSION;
        frame[1] = Protocol.MSG_CORRIDOR;
        frame[2] = (TestVectors.ROUTE_ID >> 8) & 0xFF;
        frame[3] = TestVectors.ROUTE_ID & 0xFF;
        frame[4] = 0;
        frame[5] = 1;
        frame[6] = (payload >> 8) & 0xFF;
        frame[7] = payload & 0xFF;

        var at = Protocol.HEADER_SIZE;
        frame[at] = lod;
        at++;

        for (var w = 0; w < ways; w++) {
            frame[at] = points;
            at++;
            // First point of the way: int32 delta from (lat0, lon0), as
            // `05 §CORRIDOR` dictates — each way restarts the chain.
            putS32(frame, at, w * 120);
            putS32(frame, at + 4, 150);
            at += 8;
            for (var i = 1; i < points; i++) {
                putS16(frame, at, 20);
                putS16(frame, at + 2, 20);
                at += 4;
            }
        }
        return frame;
    }

    function putS32(b as ByteArray, at as Number, v as Number) as Void {
        b[at] = (v >> 24) & 0xFF;
        b[at + 1] = (v >> 16) & 0xFF;
        b[at + 2] = (v >> 8) & 0xFF;
        b[at + 3] = v & 0xFF;
    }

    function putS16(b as ByteArray, at as Number, v as Number) as Void {
        b[at] = (v >> 8) & 0xFF;
        b[at + 1] = v & 0xFF;
    }

    //! Milliseconds to receive and parse a CORRIDOR of this size, measured
    //! as the watch pays for them: inside an `onData`. Repeats a few times
    //! because the simulator clock has 1 ms resolution and a single measurement
    //! does not tell 0 from 1.
    function timeParse(ways as Number, points as Number) as Number {
        var frame = corridorFrame(Protocol.LOD_LOCAL, ways, points);
        var started = System.getTimer();
        for (var i = 0; i < 4; i++) {
            var route = new RouteModel();
            var assembler = new MessageAssembler(route, new FakeLink());
            assembler.onData(TestVectors.META);
            assembler.onData(frame);
            // The corridor is read in slices; the test measures the whole parse.
            assembler.drainCorridor();
        }
        return System.getTimer() - started;
    }

    //! The smallest of three [timeParse]. The simulator shares the machine with the rest of
    //! Windows, and a GC or a neighboring process in the middle of a measurement changes the ratio
    //! without the code changing: measured in C5, the 4× ratio oscillated between 2.1 and 6.9 in the
    //! code from before it and between 4.9 and 12.7 in the code from after, run after run. The
    //! smallest time is what the parse costs; the rest is the neighbor.
    function fastestParse(ways as Number, points as Number) as Number {
        var best = timeParse(ways, points);
        for (var i = 1; i < 3; i++) {
            var time = timeParse(ways, points);
            if (time < best) {
                best = time;
            }
        }
        return best;
    }

    //! A real `Dc`, the size of the Venu 4 screen. `null` when the device
    //! offers no off-screen bitmap — then the test is content instead
    //! of lying.
    function screenDc() as Dc? {
        if (!(Graphics has :createBufferedBitmap)) {
            return null;
        }
        var buffer = Graphics.createBufferedBitmap({ :width => 454, :height => 454 });
        return buffer.get().getDc();
    }
}

//! **The crash test.** Forty frames walking inside the dense city, with the
//! watch always reporting a frame at the target limit — that is, with the leash
//! never allowed to grow. None of them can come near the cost that killed
//! the app.
//!
//! This test fails on the version that died: there the frame swept the ~920 ways and the 800
//! route points **every time**, and the cost was that of the whole map, not that of what
//! fits on the screen.
(:test)
function aDenseCityNeverBlowsTheFrameBudget(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();

    // The route with and without the edge (on by default since v1.1.5), and the map flat and tilted: the
    // tilted one clips to a larger square (CORNER_PX / K), and the four mixes fit.
    for (var combo = 0; combo < 4; combo++) {
        var casing = combo % 2;
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        var map = new MapRenderer();
        map.routeCasing = casing == 1;
        map.tilt = combo >= 2;
        var label = (map.routeCasing ? " with casing" : "") + (map.tilt ? " tilted" : "");
        var safe = map.WORK_FATAL * 2 / 3;
        var worst = 0;

        for (var f = 0; f < 40; f++) {
            // 20 m per frame: more than the cache recalculation trigger, so that the
            // expensive case — recalculating **and** drawing in the same frame — is the normal one
            // in this test and not the exception.
            var y = 4000.0 + f * 20.0;
            nav.metersPerPx = 1.2;
            nav.applyFix(0.0, y, 16.0, 0.0);
            matcher.update(0.0, y);
            map.draw(dc as Dc, route, nav, matcher, corridor);

            if (map.work > worst) {
                worst = map.work;
            }
            Test.assertMessage(map.work <= safe,
                "frame " + f.toString() + label + " cost "
                    + map.work.toString() + " points, ceiling " + safe.toString());

            // The watch reports a frame glued to the target: the leash neither shrinks nor
            // grows, which is the worst case of the adaptive loop.
            map.noteFrame(map.FRAME_TARGET_MS);
        }

        logger.debug("worst frame" + label + ": " + worst.toString() + " work points");
    }
    return true;
}

//! **The route edge is the second pass** (sheet 4, option 2; default since v1.1.5, sheet 8): on,
//! the route is drawn twice, and the test setting turns it off for one. The frame summary says
//! when it and the tilted map are on, so `frames.py` can separate the `frame med` on the wrist.
(:test)
function theCasingIsTheSecondRoutePass(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }
    var route = NavAssert.straightRoute(800);
    var empty = new CorridorModel();
    var drawn = [0, 0] as Array<Number>;
    for (var casing = 0; casing < 2; casing++) {
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        var map = new MapRenderer();
        map.routeCasing = casing == 1;
        nav.metersPerPx = 1.2;
        nav.applyFix(0.0, 4000.0, 16.0, 0.0);
        matcher.update(0.0, 4000.0);
        map.draw(dc as Dc, route, nav, matcher, empty);
        drawn[casing] = map.segmentsDrawn;
        map.noteFrame(map.FRAME_TARGET_MS);
        Test.assertEqualMessage(map.frameSummary().find(" · casing") != null, casing == 1,
            "the frame summary says when the casing is on");
        Test.assertMessage(map.frameSummary().find(" · tilted") == null, "the flat map says it is tilted");
    }
    Test.assertMessage((drawn[0] as Number) > 0, "the route showed up");
    Test.assertEqualMessage(drawn[1], 2 * (drawn[0] as Number), "the casing is the second pass");
    Test.assertMessage(new MapRenderer().routeCasing, "the casing is the renderer default");

    var tilted = new MapRenderer();
    tilted.tilt = true;
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 16.0, 0.0);
    matcher.update(0.0, 4000.0);
    tilted.draw(dc as Dc, route, nav, matcher, empty);
    tilted.noteFrame(tilted.FRAME_TARGET_MS);
    Test.assertMessage(tilted.frameSummary().find(" · tilted") != null, "the summary does not say tilted");
    return true;
}

//! The other side of the same coin, and what Igor actually sees: **the street has to
//! show up.** A leash that holds the watchdog by drawing a black screen would
//! trade one bug for another — which is why the previous drawing test passed
//! without proving anything.
//!
//! With time to spare, the map has to fill in a few frames: the sweep of the
//! ways finishes, the four LODs get a list and the segment count goes up.
(:test)
function theStreetsActuallyShowUpWhenThereIsHeadroom(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();

    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 16.0, 0.0);
    matcher.update(0.0, 4000.0);

    var best = 0;
    for (var f = 0; f < 8; f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        if (map.segmentsDrawn > best) {
            best = map.segmentsDrawn;
        }
        // Relaxed clock: corridor in 5 ms, frame in 10, against a target of 45/90.
        // The two numbers are **injected** on purpose: if the test used the
        // time measured here, it would pass or fail depending on the machine that
        // runs the simulator, and a test that depends on the CI's mood is not a test.
        map.msCorridor = 5;
        map.noteFrame(10);
    }

    Test.assertMessage(!map.scanPending(),
        "the ways scan finished within eight frames");
    Test.assertMessage(map.visibleWays() > 20,
        "ways on screen: " + map.visibleWays().toString());
    Test.assertMessage(best > 150,
        "street segments drawn: " + best.toString());
    logger.debug("full city: " + map.visibleWays().toString() + " ways, "
        + best.toString() + " segments, budget " + map.corridorBudget.toString());
    return true;
}

//! The leash obeys the clock, in both directions. This is the difference between a
//! limit that ages badly and one that corrects itself — and it is what keeps
//! the number chosen today from becoming the next city's bug.
//! **The 2026-08-01 regression, turned into a test.** Igor's watch log said
//! `frame med 143ms · corr 45 rota 89 hud 8` and `work 1239/220 CORTOU`: the frame
//! overshot the target because of the **route**, and the leash shrank the **corridor**
//! down to the floor — of 262 visible streets, about 17 drawn.
//!
//! A controller has to measure the variable it controls. This test pins
//! that down: a cheap corridor does not get beaten for an expensive frame, and an expensive corridor shrinks
//! even with the whole frame inside the target.
(:test)
function theLeashMeasuresTheCorridorNotTheWholeFrame(logger as Logger) as Boolean {
    var map = new MapRenderer();

    // Cheap corridor (10 ms), frame above the target but below the hard ceiling.
    // Before, this shrank the corridor on every frame down to the floor.
    map.corridorBudget = 800;
    map.corridorCapped = true;
    map.msCorridor = 10;
    map.noteFrame(100);
    Test.assertMessage(map.corridorBudget >= 800,
        "a cheap corridor is not caught by an expensive frame: " + map.corridorBudget.toString());

    // Expensive corridor, whole frame inside the target: now it does shrink, because the
    // fault is its own. Compared with the value **immediately** before: the step
    // above may have made the budget grow, and comparing with the literal 800
    // would test the growth arithmetic, not the shrinking.
    var grown = map.corridorBudget;
    map.msCorridor = map.CORRIDOR_TARGET_MS + 10;
    map.noteFrame(map.FRAME_TARGET_MS - 10);
    Test.assertMessage(map.corridorBudget < grown,
        "an expensive corridor shrinks: " + grown.toString() + " -> " + map.corridorBudget.toString());

    // And the hard frame ceiling still holds, whoever's fault it is: near
    // the watchdog the only belt available is cutting corridor. The ceiling is in
    // work, the watchdog's ruler (C16.6), not in time.
    var before = map.corridorBudget;
    map.msCorridor = 1;
    map.work = map.WORK_HARD + 1;
    map.noteFrame(map.FRAME_TARGET_MS);
    Test.assertMessage(map.corridorBudget < before,
        "a frame near the watchdog shrinks it anyway");
    map.work = 0;

    // **The ratchet.** The log case: expensive route, cheap corridor, frame above the
    // 90 target but with room to the 130 ceiling. If growth demanded the
    // whole frame's target, the budget would enter a state it never leaves —
    // and that is why it stayed pinned at 220 for the whole session.
    map.corridorBudget = map.WORK_MIN;
    for (var i = 0; i < 10; i++) {
        map.corridorCapped = true;
        map.msCorridor = 5;
        map.noteFrame(100);
    }
    Test.assertMessage(map.corridorBudget > map.WORK_MIN,
        "with an expensive route and a cheap corridor the budget still rises: "
            + map.corridorBudget.toString());
    return true;
}

//! **The ratchet again, now above 130 ms** (C16.6). On the wrist, `v1.2.9` made frames of
//! 158–208 ms with the route at ~86 ms and the HUD at ~35, and a cheap corridor: the leash spent the night at
//! `work pico 1017/220 CORTOU`. The whole frame's time does not say whether the watchdog is close: frames
//! of 208 ms lived, and what died on 2026-08-01 cost ~3000 work points
//! ([MapRenderer.WORK_FATAL]). What decides the lower safety net is the counted work.
// prevents: leash stuck at 220 with a 160–208 ms frame pulled by the route (23/10 log, v1.2.9), the
// empty street-by-street on the wrist.
(:test)
function theLeashGrowsWhenTheSlowFrameIsTheRoutesFault(logger as Logger) as Boolean {
    var map = new MapRenderer();
    map.corridorBudget = map.WORK_MIN;
    for (var i = 0; i < 10; i++) {
        map.corridorCapped = true;
        map.msCorridor = 5;
        // The log's peak: 1017 route and corridor points together, far from what kills.
        map.work = 1017;
        map.noteFrame(170);
    }
    logger.debug("170 ms frame pulled by the route: leash " + map.corridorBudget.toString());
    Test.assertMessage(map.corridorBudget > map.WORK_MIN,
        "a slow frame caused by the route pinned the leash at the floor: " + map.corridorBudget.toString());
    return true;
}

//! **Street-by-street with slow frames from the route** (C16.6): the wrist's lever 1, really drawing
//! the `CityAssert` city. With the leash stuck at the floor the screen was left almost without streets; with the
//! lower safety net in work, the leash grows in a few frames and the streets show up.
// prevents: lever 1 (street-by-street) with no street at all on the wrist with v1.2.9 (2026-10-23).
(:test)
function theLiveLeverFillsTheCityWithSlowFrames(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    // The same frame with the leash pinned at the floor, which is what the wrist showed.
    var floor = new MapRenderer();
    map.streets().diag = StreetCache.DIAG_LIVE;
    floor.streets().diag = StreetCache.DIAG_LIVE;
    map.corridorBudget = map.WORK_MIN;
    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 0.0, 0.0);
    matcher.update(0.0, 4000.0);

    for (var f = 0; f < 30; f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        // The wrist's frame: 170 ms, almost all of it route and HUD; the cheap corridor.
        map.msCorridor = 5;
        map.noteFrame(170);
        floor.corridorBudget = floor.WORK_MIN;
        floor.draw(dc as Dc, route, nav, matcher, corridor);
    }
    var floorSegments = floor.corridorSegments;
    logger.debug("street by street at 170 ms: leash " + map.corridorBudget.toString() + ", segments "
        + map.corridorSegments.toString() + " (at the floor: " + floorSegments.toString() + "), work "
        + map.work.toString());
    Test.assertMessage(!map.scanPending(), "the list did not close in 30 frames");
    Test.assertMessage(map.corridorBudget > map.WORK_MIN, "the leash did not leave the floor");
    Test.assertMessage(map.corridorSegments > floorSegments,
        "the streets did not increase: " + map.corridorSegments.toString() + " vs " + floorSegments.toString()
            + " at the floor");
    Test.assertMessage(map.work < map.WORK_HARD, "the frame went past the lower safety net");
    return true;
}

(:test)
function theLeashFollowsTheWatchNotTheGuess(logger as Logger) as Boolean {
    var map = new MapRenderer();

    // Expensive frames: shrinks down to the floor and stays there.
    map.work = map.WORK_HARD + 1;
    for (var i = 0; i < 20; i++) {
        map.noteFrame(map.FRAME_TARGET_MS * 2);
    }
    Test.assertEqualMessage(map.corridorBudget, map.WORK_MIN, "shrank to the floor");
    map.work = 0;

    // Cheap frames **with no street missing**: does not grow. Open country is no reason
    // to loosen the leash before the next dense block.
    map.corridorCapped = false;
    for (var i = 0; i < 20; i++) {
        map.noteFrame(1);
    }
    Test.assertEqualMessage(map.corridorBudget, map.WORK_MIN, "with no street missing, it does not grow");

    // Cheap frames **with a street missing**: grows up to the ceiling and stays there.
    for (var i = 0; i < 40; i++) {
        map.corridorCapped = true;
        map.noteFrame(1);
    }
    Test.assertEqualMessage(map.corridorBudget, map.WORK_MAX, "grew to the ceiling");

    // And the ceiling has to fit in the watchdog together with what the route spends.
    Test.assertMessage(map.WORK_MAX + 600 < map.WORK_FATAL,
        "the leash ceiling plus the route still fit in the watchdog");
    return true;
}

//! The block index is an optimization, and an optimization that changes the drawing is a bug. The
//! intervals it produces have to be **exactly** those of the point-by-point sweep —
//! including the extra point at each end, which is what keeps the line from
//! starting in the middle of the screen.
(:test)
function theBlockIndexDrawsExactlyWhatPointByPointWould(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var map = new MapRenderer();
    var nav = new NavState();
    var empty = new CorridorModel();

    // Zigzag route: it enters and leaves the view several times, which is the case in
    // which an interval list differs from a single index — and the case that a
    // straight route never produces.
    var count = 401;
    var xs = new [count] as Array<Float>;
    var ys = new [count] as Array<Float>;
    var cum = new [count] as Array<Float>;
    for (var i = 0; i < count; i++) {
        xs[i] = (i % 2 == 0 ? -900.0 : 900.0);
        ys[i] = (i * 25).toFloat();
        cum[i] = (i * 1800).toFloat();
    }
    var route = new RouteModel();
    route.xs = xs;
    route.ys = ys;
    route.cum = cum;
    route.blockBox = RouteModel.boxesOf(xs, ys);

    var matcher = new MapMatcher(route);

    for (var step = 0; step < 12; step++) {
        var y = 1000.0 + step * 140.0;
        nav.metersPerPx = 1.2;
        nav.applyFix(0.0, y, 12.0, 0.0);
        matcher.update(0.0, y);
        map.draw(dc as Dc, route, nav, matcher, empty);

        // The reference: the loop that existed before the index, written out in full here
        // on purpose — comparing against itself proves nothing.
        var expected = [] as Array<Number>;
        var open = -1;
        for (var i = 0; i < count; i++) {
            if (map.visible(xs[i] as Float, ys[i] as Float)) {
                if (open < 0) {
                    open = i > 0 ? i - 1 : 0;
                }
            } else if (open >= 0) {
                expected.add(open);
                expected.add(i);
                open = -1;
            }
        }
        if (open >= 0) {
            expected.add(open);
            expected.add(count - 1);
        }

        var actual = map.routeRanges();
        Test.assertEqualMessage(actual.size(), expected.size(),
            "step " + step.toString() + ": " + actual.size().toString()
                + " vs " + expected.size().toString() + " indices");
        for (var i = 0; i < expected.size(); i++) {
            Test.assertEqualMessage(actual[i] as Number, expected[i] as Number,
                "step " + step.toString() + ", index " + i.toString());
        }
    }
    return true;
}

//! **A 200 km trip cannot cost more per frame than a 20 km one.** That was
//! the underlying defect: the drawing cost followed the route length, and
//! not what fits on the screen. The block index leaves only the count of the
//! blocks themselves, which is the length divided by sixteen.
(:test)
function frameCostDoesNotFollowRouteLength(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var nav = new NavState();
    var empty = new CorridorModel();
    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 16.0, 0.0);

    var shortRoute = NavAssert.straightRoute(100);   // 10 km
    var longRoute = NavAssert.straightRoute(2000);   // 200 km

    var mapShort = new MapRenderer();
    var shortMatcher = new MapMatcher(shortRoute);
    shortMatcher.update(0.0, 4000.0);
    mapShort.draw(dc as Dc, shortRoute, nav, shortMatcher, empty);

    var mapLong = new MapRenderer();
    var longMatcher = new MapMatcher(longRoute);
    longMatcher.update(0.0, 4000.0);
    mapLong.draw(dc as Dc, longRoute, nav, longMatcher, empty);

    var extra = mapLong.work - mapShort.work;
    // 1,900 more route points come in as ~119 more blocks. Before the
    // index they would come in as 1,900 point tests.
    Test.assertMessage(extra < 200,
        "20× the route cost " + extra.toString() + " more points ("
            + mapShort.work.toString() + " → " + mapLong.work.toString() + ")");
    logger.debug("route 100 pts: " + mapShort.work.toString()
        + " · route 2000 pts: " + mapLong.work.toString());
    return true;
}

//! **Decimation by scale: do not pay for pixels that do not exist.**
//!
//! The Mapbox route has a point every ~25 m. At 1.2 m/px that is 21 px between
//! vertices — all of them need to be drawn. At 20 m/px it is **1.3 px**, and
//! drawing both produces the same pixel as drawing one. Those were the 89 ms of
//! route that Igor's telemetry showed at the open zoom.
//!
//! The test asserts both halves: at the riding zoom **nothing** is discarded
//! (an optimization that changes the map where it is looked at is not worth it), and at the
//! browsing zoom about half goes away.
(:test)
function wideZoomDoesNotPayForPixelsItCannotShow(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    // Route with Mapbox's real spacing: 25 m between points.
    var count = 1200;
    var xs = new [count] as Array<Float>;
    var ys = new [count] as Array<Float>;
    var cum = new [count] as Array<Float>;
    for (var i = 0; i < count; i++) {
        xs[i] = 0.0;
        ys[i] = (i * 25).toFloat();
        cum[i] = (i * 25).toFloat();
    }
    var route = new RouteModel();
    route.xs = xs;
    route.ys = ys;
    route.cum = cum;
    route.blockBox = RouteModel.boxesOf(xs, ys);

    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var empty = new CorridorModel();
    nav.applyFix(0.0, 15000.0, 16.0, 0.0);
    matcher.update(0.0, 15000.0);

    // A single pass: decimation is per pass, and the edge (the second one, v1.1.5) is counted in
    // `theCasingIsTheSecondRoutePass`.
    var tight = new MapRenderer();
    tight.routeCasing = false;
    nav.metersPerPx = 1.2;
    tight.draw(dc as Dc, route, nav, matcher, empty);
    var tightSpan = CityAssert.aheadSpan(tight.routeRanges(), matcher.segmentIdx);
    var tightDrawn = tight.segmentsDrawn;

    var wide = new MapRenderer();
    wide.routeCasing = false;
    nav.metersPerPx = 20.0;
    wide.draw(dc as Dc, route, nav, matcher, empty);
    var wideSpan = CityAssert.aheadSpan(wide.routeRanges(), matcher.segmentIdx);
    var wideDrawn = wide.segmentsDrawn;

    Test.assertMessage(tightDrawn * 10 >= tightSpan * 9,
        "at riding zoom nothing is discarded: " + tightDrawn.toString()
            + " of " + tightSpan.toString());
    Test.assertMessage(wideDrawn * 10 <= wideSpan * 6,
        "at browse zoom about half is left: " + wideDrawn.toString()
            + " of " + wideSpan.toString());
    logger.debug("decimation: 1.2 m/px " + tightDrawn.toString() + "/" + tightSpan.toString()
        + " · 20 m/px " + wideDrawn.toString() + "/" + wideSpan.toString());
    return true;
}

//! **The second watchdog death, and it was not in the drawing.**
//!
//! `CIQ_LOG.BAK` from 2026-08-01T23:54Z: `onPhoneMessage → onData → apply →
//! parseCorridor → readS32`. The app died **receiving** the corridor, not
//! drawing — and the reason is Monkey C's most classic gotcha: arrays have a
//! fixed size, `add` allocates a new array and copies the whole old one. Building
//! 1,500 points with `add` is ~1.1 **million** copies, against a budget of
//! 240,000 instructions per callback.
//!
//! And the cost is **quadratic in the corridor size**, so it blew up
//! exactly when the ceiling went up and the local LOD — the largest of all — started
//! to arrive. The fix that brought the streets back created the next death.
//!
//! The test does not count instructions (there is no way to, from inside Monkey C): it measures
//! **growth**. Quadrupling the corridor has to quadruple the time, not
//! multiply it by sixteen. The margin is wide on purpose — what is asserted
//! here is the order of magnitude, and it separates linear from quadratic with room to spare.
(:test)
function parsingTheCorridorIsLinearNotQuadratic(logger as Logger) as Boolean {
    var base = CityAssert.fastestParse(1, 2);      // fixed cost only (META + objects)
    var small = CityAssert.fastestParse(60, 5);    // 300 points
    var big = CityAssert.fastestParse(240, 5);     // 1,200 points — 4×

    // Subtracting the fixed cost is what makes the ratio honest: without it, the META
    // repeated in every measurement flattens the growth and the test would pass even with
    // a quadratic loop.
    var smallNet = small - base;
    var bigNet = big - base;
    if (smallNet < 1) {
        smallNet = 1;
    }

    // Quadratic would give 16×; linear gives 4×. The 8× ceiling decides between the two without
    // depending on the speed of the machine that runs the simulator.
    Test.assertMessage(bigNet <= smallNet * 8,
        "4x the corridor cost " + bigNet.toString() + " ms vs " + smallNet.toString()
            + " ms — smells quadratic");
    logger.debug("corridor parse (net of " + base.toString() + " ms fixed): 300 pts "
        + smallNet.toString() + " ms · 1200 pts " + bigNet.toString() + " ms · ratio "
        + (bigNet * 10 / smallNet).toString() + "/10 for 4x the size");
    return true;
}

//! And the parse result has to stay correct after swapping `add` for a
//! cursor: way count, sentinel at the end and points in place.
(:test)
function theResizedParseStillProducesTheSameCorridor(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(TestVectors.META);
    assembler.onData(CityAssert.corridorFrame(Protocol.LOD_LOCAL, 7, 4));

    var corridor = assembler.getCorridor();
    Test.assertEqualMessage(corridor.wayCount(Protocol.LOD_LOCAL), 7, "seven ways");

    var starts = corridor.wayStart[Protocol.LOD_LOCAL] as Array<Number>;
    var xs = corridor.xs[Protocol.LOD_LOCAL] as Array<Float>;
    Test.assertEqualMessage(starts.size(), 8, "seven starts plus the sentinel");
    Test.assertEqualMessage(xs.size(), 28, "seven ways of four points");
    Test.assertEqualMessage(starts[7] as Number, 28, "the sentinel is the end of the points");
    Test.assertEqualMessage(starts[0] as Number, 0, "the first way starts at zero");
    Test.assertEqualMessage(starts[1] as Number, 4, "and the second four points later");

    // The derived rectangle and block also have to come out coherent, otherwise the
    // drawing reads an index outside the array.
    Test.assertEqualMessage((corridor.wayBox[Protocol.LOD_LOCAL] as Array<Float>).size(), 28,
        "four floats per way");
    Test.assertEqualMessage((corridor.blockBox[Protocol.LOD_LOCAL] as Array<Float>).size(), 4,
        "seven ways fit in a single block");
    return true;
}

//! The scale cutoff still holds, and now it matters more: with the leash, the
//! LOD that is not cut by scale is the one that consumes the others' budget.
(:test)
function zoomingOutDropsTheLocalMesh(logger as Logger) as Boolean {
    var corridor = CityAssert.cityCorridor();
    var map = new MapRenderer();
    var nav = new NavState();

    nav.seedCentre(0.0, 4000.0);
    nav.metersPerPx = 1.2;
    map.corridorBudget = map.WORK_MAX;
    map.begin(nav);
    map.refreshVisible(corridor);
    var tight = map.visibleWays();

    nav.metersPerPx = 30.0; // above the ceiling of the local and collector LODs
    map.begin(nav);
    map.refreshVisible(corridor);
    // A sweep can be left half-done when the budget runs out; here it is the
    // ceiling, so it finishes — but the test says so out loud instead of assuming.
    Test.assertMessage(!map.scanPending(), "the scan finished");
    var wide = map.visibleWays();

    Test.assertMessage(wide < tight,
        "opening the zoom leaves fewer ways: " + wide.toString() + " vs " + tight.toString());
    return true;
}

//! **The large corridor is read in slices, and sliced gives the same corridor.**
//!
//! Read whole on arrival, SP's LOD 0 (1,378 points) blew the watchdog
//! in a normal run (DECISIONS §2026-09-29 C2b). Here: a block larger than
//! one slice does **not** go all into `onData`, and after being read to the end it has the
//! same ways and the same boxes that `CorridorModel.boxesOf` would compute in
//! a single pass.
(:test)
function aBigCorridorIsReadInSlicesAndEndsTheSame(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(TestVectors.META);
    var ways = 400;
    var points = 5;
    Test.assertMessage(ways * points > assembler.CORRIDOR_SLICE_POINTS,
        "the test block must be larger than a slice");
    assembler.onData(CityAssert.corridorFrame(Protocol.LOD_LOCAL, ways, points));
    Test.assertMessage(assembler.isCorridorPending(), "the whole block went in on a single callback");

    var steps = 0;
    while (assembler.isCorridorPending()) {
        assembler.stepCorridor();
        steps++;
    }
    logger.debug(ways.toString() + " ways in " + (steps + 1).toString() + " slices of "
        + assembler.CORRIDOR_SLICE_POINTS.toString() + " points");

    var corridor = assembler.getCorridor();
    var lod = Protocol.LOD_LOCAL;
    Test.assertEqualMessage(corridor.wayCount(lod), ways, "all the ways");
    var xs = corridor.xs[lod] as Array<Float>;
    Test.assertEqualMessage(xs.size(), ways * points, "all the points");

    var expected = CorridorModel.boxesOf(xs, corridor.ys[lod] as Array<Float>,
        corridor.wayStart[lod] as Array<Number>);
    var boxes = corridor.wayBox[lod] as Array<Float>;
    Test.assertEqualMessage(boxes.size(), expected.size(), "one box per way");
    for (var i = 0; i < expected.size(); i++) {
        Test.assertEqualMessage(boxes[i] as Float, expected[i] as Float, "box " + i.toString());
    }
    return true;
}

//! Ending the route in the middle of the sliced read cannot let the corridor
//! come back by itself on the next tick (finding from C2b's review).
(:test)
function cancellingTheCorridorStopsTheSlices(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(TestVectors.META);
    assembler.onData(CityAssert.corridorFrame(Protocol.LOD_LOCAL, 400, 5));
    Test.assertMessage(assembler.isCorridorPending(), "the block must be half done");

    assembler.cancelCorridor();
    assembler.getCorridor().clear();
    assembler.stepCorridor();
    Test.assertMessage(!assembler.isCorridorPending(), "nothing left to read");
    Test.assertEqualMessage(assembler.getCorridor().wayCount(Protocol.LOD_LOCAL), 0,
        "the LOD of the ended route does not come back");
    return true;
}

//! Helpers for the sliced POLY tests (C6a).
(:test)
module PolyAssert {

    //! A complete ROUTE_POLY (header + payload) of `points` points for the
    //! [TestVectors] route, ready for `MessageAssembler.onData`. The deltas change
    //! sign and size, and point 1000 comes through the escape pair (int32), which is
    //! the path most likely to diverge among the three sides.
    function longPolyFrame(points as Number) as ByteArray {
        var escapeAt = 1000;
        var payload = 8 + (points - 1) * 4 + (points > escapeAt ? 8 : 0);
        var frame = new [Protocol.HEADER_SIZE + payload]b;
        frame[0] = Protocol.VERSION;
        frame[1] = Protocol.MSG_ROUTE_POLY;
        frame[2] = (TestVectors.ROUTE_ID >> 8) & 0xFF;
        frame[3] = TestVectors.ROUTE_ID & 0xFF;
        frame[4] = 0;
        frame[5] = 1;
        frame[6] = (payload >> 8) & 0xFF;
        frame[7] = payload & 0xFF;

        // First point: int32 delta from (lat0, lon0), as in the packer.
        var at = Protocol.HEADER_SIZE + 8;
        for (var i = 1; i < points; i++) {
            if (i == escapeAt) {
                CityAssert.putS16(frame, at, Protocol.DELTA_ESCAPE);
                CityAssert.putS16(frame, at + 2, Protocol.DELTA_ESCAPE);
                CityAssert.putS32(frame, at + 4, 40000);
                CityAssert.putS32(frame, at + 8, -40000);
                at += 12;
            } else {
                CityAssert.putS16(frame, at, (i * 37) % 61 - 30);
                CityAssert.putS16(frame, at + 2, (i * 53) % 71 - 35);
                at += 4;
            }
        }
        return frame;
    }

    //! The [TestVectors] META saying the POLY has `points` points: without it the
    //! route never completes with the [longPolyFrame]. The `polyPointCount` sits right
    //! after the name (`05 §ROUTE_META`).
    function metaWithPoints(points as Number) as ByteArray {
        var meta = TestVectors.META.slice(0, null);
        var at = Protocol.HEADER_SIZE + 17 + (meta[Protocol.HEADER_SIZE + 16] as Number);
        meta[at] = (points >> 8) & 0xFF;
        meta[at + 1] = points & 0xFF;
        return meta;
    }

    function sameFloats(got as Array<Float>, want as Array<Float>, what as String) as Void {
        Test.assertEqualMessage(got.size(), want.size(), what + ": size");
        for (var i = 0; i < want.size(); i++) {
            if ((got[i] as Float) != (want[i] as Float)) {
                Test.assertEqualMessage(got[i] as Float, want[i] as Float, what + " " + i.toString());
            }
        }
    }
}

//! **The long POLY is read in slices, and sliced gives the same route.**
//!
//! Read whole on arrival, the POLY of a 16 km route blew the watchdog on the
//! wrist (DECISIONS §C6a: the pre-flight). Here: the POLY at the protocol ceiling does **not**
//! go all into `onData`, and after being read to the end it has the same points,
//! the same projection, the same accumulated values and the same boxes that
//! `RouteModel.project()` would compute in a single pass — number by number.
(:test)
function aLongPolyIsReadInSlicesAndEndsTheSame(logger as Logger) as Boolean {
    var points = Protocol.MAX_POLY_POINTS;
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(TestVectors.META);
    Test.assertMessage(points > assembler.POLY_SLICE_POINTS, "the test POLY must be larger than a slice");
    assembler.onData(PolyAssert.longPolyFrame(points));
    Test.assertMessage(assembler.isPolyPending(), "the whole POLY went in on a single callback");
    Test.assertMessage(!route.hasPoly, "route usable before the end of the POLY");

    var steps = 1;
    while (assembler.isPolyPending()) {
        assembler.stepJobs();
        steps++;
    }
    logger.debug(points.toString() + " points in " + steps.toString() + " slices of "
        + assembler.POLY_SLICE_POINTS.toString());
    Test.assertEqualMessage(route.lats.size(), points, "all the points");
    Test.assertEqualMessage(assembler.lastError, "", "no error");

    var lat = TestVectors.LAT0;
    var lon = TestVectors.LON0;
    for (var i = 1; i < points; i++) {
        lat += i == 1000 ? 40000 : (i * 37) % 61 - 30;
        lon += i == 1000 ? -40000 : (i * 53) % 71 - 35;
    }
    Test.assertEqualMessage(route.lats[points - 1], lat, "last lat");
    Test.assertEqualMessage(route.lons[points - 1], lon, "last lon");

    var expected = new RouteModel();
    expected.lat0 = route.lat0;
    expected.lon0 = route.lon0;
    expected.lats = route.lats;
    expected.lons = route.lons;
    expected.project();
    Test.assertEqualMessage(route.lonScale, expected.lonScale, "lonScale");
    PolyAssert.sameFloats(route.xs, expected.xs, "x");
    PolyAssert.sameFloats(route.ys, expected.ys, "y");
    PolyAssert.sameFloats(route.cum, expected.cum, "cum");
    PolyAssert.sameFloats(route.blockBox, expected.blockBox, "box");
    return true;
}

//! New route in the middle of the sliced read: the half-read POLY belongs to the old route and
//! cannot come back on the next tick. The same goes for "End route", which
//! calls `cancelRouteJobs`.
(:test)
function aNewRouteDropsTheHalfReadPoly(logger as Logger) as Boolean {
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(TestVectors.META);
    assembler.onData(PolyAssert.longPolyFrame(Protocol.MAX_POLY_POINTS));
    Test.assertMessage(assembler.isPolyPending(), "the POLY must be half done");

    assembler.onData(TestVectors.META);
    Test.assertMessage(!assembler.isPolyPending(), "the new META drops the POLY");
    Test.assertMessage(!assembler.stepJobs(), "no slice left");
    Test.assertEqualMessage(route.lats.size(), 0, "the new route does not inherit points");

    assembler.onData(PolyAssert.longPolyFrame(Protocol.MAX_POLY_POINTS));
    assembler.cancelRouteJobs();
    Test.assertMessage(!assembler.stepJobs() && !route.hasPoly, "ending also drops it");
    return true;
}

//! The TURNS arrives while the POLY is still being read (the POLY's ACK goes out on arrival, and
//! the phone keeps sending). The route completes on the **last slice**, and
//! `stepJobs` says so with `true`: it is the `MotoNavApp.onTick` hook to put the
//! map on the screen.
(:test)
function theRouteCompletesOnTheLastPolySlice(logger as Logger) as Boolean {
    var points = Protocol.MAX_POLY_POINTS;
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    assembler.onData(PolyAssert.metaWithPoints(points));
    assembler.onData(PolyAssert.longPolyFrame(points));
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_ROUTE_POLY, "the POLY ACK goes out on arrival");
    assembler.onData(TestVectors.TURNS_0);
    assembler.onData(TestVectors.TURNS_1);
    Test.assertMessage(route.hasTurns && !route.isComplete(), "complete before the end of the POLY");

    var finished = false;
    while (assembler.isPolyPending()) {
        finished = assembler.stepJobs();
    }
    Test.assertMessage(finished, "the last slice did not signal");
    Test.assertMessage(route.isComplete(), "the route did not complete");
    Test.assertMessage(assembler.transferEndMs > 0, "end of transfer not marked");
    return true;
}

//! **The streets do not flicker with the leash at the floor** (C16.5, `MapRenderer.drawCorridor`).
//! At 108 km/h at 1 Hz the center moves 30 m per frame, more than [CACHE_REBUILD_M]: the
//! way list is rebuilt all the time, and each frame has to draw some street even
//! so. A corridor costing 50 ms is what the Venu 4 measured at the floor on 2026-10-16
//! (`corr 47–64`, `work pico 234/220`), and it is what holds the leash down there.
// prevents: in C16 the streets flickered on the watch (README "Estado atual"): at the floor, the frame that rebuilt the
// list spent the whole budget on the sweep and drew no street at all.
(:test)
function streetsStayOnScreenWhileTheListIsRebuiltAtTheFloor(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.corridorBudget = map.WORK_MIN;
    nav.metersPerPx = 1.2;

    // Stopped until the first list closes.
    nav.applyFix(0.0, 4000.0, 0.0, 0.0);
    matcher.update(0.0, 4000.0);
    for (var f = 0; f < 20 && (f == 0 || map.scanPending()); f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        map.msCorridor = 50;
        map.noteFrame(120);
    }
    Test.assertMessage(!map.scanPending(), "the first list closed");

    var blank = 0;
    for (var f = 0; f < 20; f++) {
        var y = 4000.0 + (f + 1) * 30.0;
        nav.applyFix(0.0, y, 30.0, 0.0);
        matcher.update(0.0, y);
        map.draw(dc as Dc, route, nav, matcher, corridor);
        if (map.corridorSegments == 0) {
            blank++;
        }
        Test.assertMessage(map.corridorBudget == map.WORK_MIN, "the leash stayed at the floor");
        map.msCorridor = 50;
        map.noteFrame(120);
    }
    logger.debug("frames without street at the floor: " + blank.toString() + " of 20");
    Test.assertMessage(blank == 0, blank.toString() + " of 20 frames with no street at all at the leash floor");
    return true;
}

//! **Zoom in the middle of the sweep redoes all the LODs, and asks for extra frames** (C16). Stopped, nothing
//! asks for another list afterwards: the one that closes is the one that stays on screen.
// prevents: on the 2026-10-17 bench, "every time the zoom changes it seems to reset the streets
// appearing": the sweep in progress went on with the LODs already swept at the old scale, and the stopped map never
// asked for another. And the sweep of someone who only moves around the map cannot ask for extra frames (the CPU of
// someone riding).
(:test)
function aZoomMidScanRebuildsEveryLayer(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.corridorBudget = map.WORK_MIN;
    nav.metersPerPx = 1.2;

    nav.applyFix(0.0, 4000.0, 0.0, 0.0);
    matcher.update(0.0, 4000.0);
    for (var f = 0; f < 40 && (f == 0 || map.scanPending()); f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
    }
    Test.assertMessage(!map.scanPending(), "the first list closed");

    // Moves enough for a new list, which at the floor is left half-done in one frame.
    nav.applyFix(0.0, 4040.0, 0.0, 0.0);
    matcher.update(0.0, 4040.0);
    map.draw(dc as Dc, route, nav, matcher, corridor);
    Test.assertMessage(map.scanPending(), "the movement scan closed in a single frame: the test proves nothing");
    Test.assertMessage(!map.wantsCatchUp(), "moving over the map asked for extra frames");

    // The zoom opens in the middle of it.
    nav.metersPerPx = 5.0;
    map.draw(dc as Dc, route, nav, matcher, corridor);
    Test.assertMessage(map.wantsCatchUp(), "the zoom did not ask for extra frames");
    for (var f = 0; f < 80 && map.scanPending(); f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
    }
    Test.assertMessage(!map.scanPending(), "the new zoom list did not close in 80 frames");
    Test.assertMessage(!map.wantsCatchUp(), "the list closed and the extra frames went on");

    var truth = new MapRenderer();
    truth.corridorBudget = truth.WORK_MAX;
    truth.begin(nav);
    truth.refreshVisible(corridor);
    Test.assertMessage(!truth.scanPending(), "the reference list closed");
    for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
        Test.assertEqualMessage(map.visibleIn(lod), truth.visibleIn(lod),
            "LOD " + lod.toString() + " with the old-scale list");
    }
    return true;
}

//! **The avenue on top of the local street** (C16.5), as in Maps and Waze. What comes last
//! stays on top, so the drawing goes from the fine LOD to the coarse; and the budget cut, which
//! only the plan decides, still takes the local street first.
// prevents: the local street running over the avenue at the intersection (Igor, in the simulator photo,
// 2026-10-17): the corridor was drawn from expressway to local, and the local one ended up on top.
(:test)
function theAvenueIsDrawnOverTheLocalStreets(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 0.0, 0.0);
    matcher.update(0.0, 4000.0);

    // With headroom, as in `theStreetsActuallyShowUpWhenThereIsHeadroom`: the four lists close.
    for (var f = 0; f < 8; f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        map.msCorridor = 5;
        map.noteFrame(10);
    }
    map.corridorBudget = map.WORK_MAX;
    map.draw(dc as Dc, route, nav, matcher, corridor);
    Test.assertEqualMessage(map.firstLodDrawn, Protocol.CORRIDOR_LOD_COUNT - 1, "the local street first, underneath");
    Test.assertEqualMessage(map.lastLodDrawn, 0, "the expressway last, on top");

    // At the floor, the cut is the local street's, and the avenue that is left stays on top.
    map.corridorBudget = map.WORK_MIN;
    map.draw(dc as Dc, route, nav, matcher, corridor);
    Test.assertMessage(map.corridorCapped, "the floor caps");
    var cut = false;
    for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
        var got = map.planned[lod] as Number;
        Test.assertMessage(!cut || got == 0,
            "LOD " + lod.toString() + " with " + got.toString() + " ways after a coarser LOD was cut");
        if (got < map.visibleIn(lod)) {
            cut = true;
        }
    }
    Test.assertMessage((map.planned[0] as Number) > 0, "the expressway survives the floor");
    Test.assertEqualMessage(map.lastLodDrawn, 0, "and stays on top");
    logger.debug("floor: plan " + map.planned.toString() + " of " + map.visibleWays().toString()
        + " ways, work " + map.work.toString());
    return true;
}

//! The corridor plan ([MapRenderer.planCorridor]) cannot leave the leash floor
//! half-done: after one frame, it counts what each LOD really paid, not the ceiling.
// prevents: C16.5's 1st plan, by the cost ceiling, closing this city's whole frame at 134 with
// the floor at 220 (job 386): less street in the watch's most common case in São Paulo, the leash at the floor.
(:test)
function theFloorPlanSpendsTheFloor(logger as Logger) as Boolean {
    var dc = CityAssert.screenDc();
    if (dc == null) {
        return true;
    }

    var route = NavAssert.straightRoute(800);
    var corridor = CityAssert.cityCorridor();
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    map.corridorBudget = map.WORK_MIN;
    nav.metersPerPx = 1.2;
    nav.applyFix(0.0, 4000.0, 0.0, 0.0);
    matcher.update(0.0, 4000.0);

    // The list closes at the floor, and three more frames with it ready.
    for (var f = 0; f < 23 && (f < 3 || map.scanPending()); f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        map.msCorridor = 50;
        map.noteFrame(120);
    }
    for (var f = 0; f < 3; f++) {
        map.draw(dc as Dc, route, nav, matcher, corridor);
        map.msCorridor = 50;
        map.noteFrame(120);
    }
    Test.assertMessage(!map.scanPending(), "the list closed");
    Test.assertEqualMessage(map.corridorBudget, map.WORK_MIN, "the leash at the floor");
    logger.debug("floor: corridor " + map.corridorWork.toString() + " of " + map.WORK_MIN.toString()
        + ", plan " + map.planned.toString());
    Test.assertMessage(map.corridorWork >= map.WORK_MIN * 3 / 4,
        "the corridor spent " + map.corridorWork.toString() + " of the floor of " + map.WORK_MIN.toString());
    Test.assertMessage(map.corridorWork <= map.WORK_MAX, "never goes past the ceiling");
    return true;
}
