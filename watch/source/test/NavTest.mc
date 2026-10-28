import Toybox.Lang;
import Toybox.Math;
import Toybox.Test;

//! F2 math tests: local projection (ADR-6) and map-matching
//! (`03 §Map-matching`). Everything here runs on the simulator, without GPS and without a phone —
//! it is what can be proven before getting on the bike.

(:test)
module NavAssert {

    function near(actual as Float, expected as Float, tolerance as Float) as Boolean {
        var diff = actual - expected;
        return (diff < 0 ? -diff : diff) <= tolerance;
    }

    //! Straight route going north, one point every 100 m, already projected.
    function straightRoute(points as Number) as RouteModel {
        var route = new RouteModel();
        var xs = new [points] as Array<Float>;
        var ys = new [points] as Array<Float>;
        var cum = new [points] as Array<Float>;
        for (var i = 0; i < points; i++) {
            xs[i] = 0.0;
            ys[i] = (i * 100).toFloat();
            cum[i] = (i * 100).toFloat();
        }
        route.xs = xs;
        route.ys = ys;
        route.cum = cum;
        // The block index is built here for the same reason `project()` builds it
        // in production: without it, every drawing test would exercise the compatibility
        // path instead of the real one.
        route.blockBox = RouteModel.boxesOf(xs, ys);
        return route;
    }
}

//! **The trap that erased Igor's streets.** The top button cycles six
//! levels; the last two (10 and 20 m/px) are "look at the whole route". They
//! should expire — but only the automatic zoom consulted `manualZoomHolds`,
//! and it is off by default. Anyone going past index 4 stayed
//! at 20 m/px forever, and at 20 m/px each LOD's scale ceiling erases
//! collectors and local streets on purpose: a map with no streets, nothing on screen explaining.
//!
//! The 2026-08-01 log shows `zoom 20.0` in the whole session.
(:test)
function browseZoomComesBackOnItsOwn(logger as Logger) as Boolean {
    var nav = new NavState();
    Test.assertEqualMessage(nav.zoomIndex, NavState.DEFAULT_ZOOM_INDEX, "starts at 1.2 m/px");

    // Four touches: 1.2 → 2.5 → 5 → 10 → 20. The last is a lookup level.
    var now = 1000;
    for (var i = 0; i < 4; i++) {
        nav.cycleZoom(now);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 20.0, 0.001),
        "reached the browse level: " + nav.metersPerPx.format("%.1f"));

    // Before the deadline, what the rider chose holds.
    nav.tickBrowse(now + nav.BROWSE_ZOOM_HOLD_MS - 1);
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 20.0, 0.001), "within the deadline, it stays");

    // After it, it goes back by itself — **with the automatic off**, which is the
    // default and was exactly the case nobody covered.
    Test.assertMessage(!nav.autoZoom, "auto zoom off, as in production");
    nav.tickBrowse(now + nav.BROWSE_ZOOM_HOLD_MS + 1);
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2, 0.001),
        "went back to the riding level: " + nav.metersPerPx.format("%.1f"));
    return true;
}

//! And it goes back to the riding level the rider **was** on, not to the
//! default: whoever prefers 5 m/px does not lose the preference for having peeked at the route.
//!
//! The difference between the two tests is the **time between touches**, and it is what
//! defines what counts as a choice: here each level stays 5 s on screen.
(:test)
function browseZoomComesBackToTheChosenRidingLevel(logger as Logger) as Boolean {
    var nav = new NavState();
    var now = 1000;

    nav.cycleZoom(now);           // 1.2 → 2.5
    now += 5000;
    nav.cycleZoom(now);           // 2.5 → 5.0, after 5 s settled
    now += 5000;
    nav.cycleZoom(now);           // 5.0 → 10.0 (lookup), after 5 s
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 10.0, 0.001), "entered browse");

    nav.tickBrowse(now + nav.BROWSE_ZOOM_HOLD_MS + 1);
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 5.0, 0.001),
        "went back to where he was riding, not to the default: "
            + nav.metersPerPx.format("%.1f"));
    return true;
}

//! A degree of latitude is ~111.19 km anywhere; one of longitude
//! shrinks with the cosine of the latitude — in São Paulo, to ~102 km.
(:test)
function projectionScalesLatitudeAndLongitude(logger as Logger) as Boolean {
    var lat0 = -2350000; // -23.5°
    var lon0 = -4660000; // -46.6°
    var scale = Projection.lonScale(lat0);

    var north = Projection.toLocalY(lat0 + 100000, lat0); // +1°
    var east = Projection.toLocalX(lon0 + 100000, lon0, scale); // +1°

    Test.assertMessage(NavAssert.near(north, 111194.9, 1.0), "1° of latitude ≈ 111.19 km");
    Test.assertMessage(NavAssert.near(east, 101979.0, 50.0), "1° of longitude at -23.5° ≈ 102 km");
    Test.assertMessage(east < north, "longitude shrinks away from the equator");
    return true;
}

//! The GPS fix has to fall on the same plane as the route, with the same rounding
//! as the packer (`DECISIONS.md` §Quantização).
(:test)
function projectionRoundsDegreesLikeThePacker(logger as Logger) as Boolean {
    Test.assertEqualMessage(Projection.degreesToE5(-23.5505047d), -2355050, "negative rounds away from zero");
    Test.assertEqualMessage(Projection.degreesToE5(23.500005d), 2350001, "half rounds up");
    Test.assertEqualMessage(Projection.degreesToE5(0.0d), 0, "zero");
    return true;
}

//! The rider 5 m beside the track, between the second and third points.
(:test)
function matcherFindsSegmentAndProgress(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(20);
    var matcher = new MapMatcher(route);

    Test.assert(matcher.update(5.0, 150.0));

    Test.assertEqualMessage(matcher.segmentIdx, 1, "segment between points 1 and 2");
    Test.assertMessage(NavAssert.near(matcher.distAlong, 150.0, 0.1), "progress along the route");
    Test.assertMessage(NavAssert.near(matcher.crossTrack, 5.0, 0.1), "perpendicular offset");
    Test.assertMessage(NavAssert.near(matcher.remainingM(), 1750.0, 0.1), "remaining = total − covered");
    return true;
}

//! A jump larger than the local window: the global search must recover the rider,
//! otherwise he is stuck at the end of the window and progress freezes.
(:test)
function matcherFallsBackToGlobalSearch(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(200);
    var matcher = new MapMatcher(route);

    // In the middle of the segment, not on the vertex: on a vertex the two neighboring
    // segments tie at distance zero and either one will do.
    matcher.update(0.0, 150.0);
    Test.assertEqualMessage(matcher.segmentIdx, 1, "matched near the start");

    // 15 km ahead — well beyond [last−10, last+50].
    matcher.update(0.0, 15050.0);

    Test.assertEqualMessage(matcher.segmentIdx, 150, "global search found the distant segment");
    Test.assertMessage(NavAssert.near(matcher.distAlong, 15050.0, 0.1), "progress followed the jump");
    return true;
}

//! Before the end of the route the rider is glued to the last segment, and the remainder
//! is never negative.
(:test)
function matcherClampsAtTheEnd(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(10);
    var matcher = new MapMatcher(route);

    matcher.update(0.0, 99999.0);

    Test.assertEqualMessage(matcher.segmentIdx, 8, "last segment");
    Test.assertMessage(NavAssert.near(matcher.remainingM(), 0.0, 0.01), "remaining does not go below zero");
    return true;
}

//! The next maneuver is the first ahead of the current segment; once passed, it leaves.
(:test)
function matcherTracksNextTurn(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(20);
    route.turnPointIdx = [3, 10, 17] as Array<Number>;
    var matcher = new MapMatcher(route);

    matcher.update(0.0, 50.0);
    Test.assertEqualMessage(matcher.nextTurnIndex(), 0, "first maneuver ahead");
    Test.assertMessage(NavAssert.near(matcher.distToNextTurnM(), 250.0, 0.1), "300 m − 50 m");

    matcher.update(0.0, 1150.0);
    Test.assertEqualMessage(matcher.nextTurnIndex(), 2, "the first two are behind");

    matcher.update(0.0, 1850.0);
    Test.assertEqualMessage(matcher.nextTurnIndex(), -1, "no next maneuver");
    Test.assertMessage(matcher.distToNextTurnM() < 0.0, "negative distance signals the end");
    return true;
}

//! **The default is a fixed zoom at 1.2 m/px.** With the rider at the center of a
//! 454 px screen this gives ~270 m ahead — the "three streets" that Igor asked for after
//! riding with the automatic. The automatic still exists, but off: this
//! test is what stops someone from "fixing" this without noticing it is a decision.
(:test)
function zoomIsFixedByDefault(logger as Logger) as Boolean {
    var nav = new NavState();

    Test.assertMessage(!nav.autoZoom, "auto zoom starts off");
    Test.assertEqualMessage(nav.zoomIndex, NavState.DEFAULT_ZOOM_INDEX, "initial riding level");
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2, 0.001), "1,2 m/px");

    // Accelerating to highway speed must not open the map by itself.
    nav.applyFix(0.0, 0.0, 25.0, null);
    for (var i = 0; i < 60; i++) {
        nav.updateAutoZoom(1000 + i * 1000, 120.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2, 0.001),
        "neither speed nor turn changes the scale with auto zoom off");
    return true;
}

//! Turning the automatic off returns the scale to a **named** level: otherwise the map
//! would freeze at the intermediate value of the interpolation, which is not reproducible.
(:test)
function turningAutoZoomOffSnapsBackToTheChosenLevel(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.setAutoZoom(true);
    nav.applyFix(0.0, 0.0, 25.0, null);

    nav.updateAutoZoom(1000, -1.0); // a single step: the scale is left midway
    Test.assertMessage(!NavAssert.near(nav.metersPerPx, 1.2, 0.001), "auto zoom changed the scale");

    nav.setAutoZoom(false);
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2, 0.001), "went back to the level of the current index");

    nav.updateAutoZoom(9999, -1.0);
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2, 0.001), "and auto zoom does not touch it again");
    return true;
}

//! Automatic zoom **on**: stopped zooms in, fast zooms out, and a close turn pulls
//! back (`03 §Renderização`). The transition is smooth, so the test iterates until
//! it settles. The targets come out tightened by [NavState.ZOOM_TIGHTEN] — ~15% closer
//! than the nominal levels, Igor's request after riding with the map
//! centered.
(:test)
function autoZoomFollowsSpeedAndTurns(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.setAutoZoom(true);
    var tighten = nav.ZOOM_TIGHTEN;

    nav.applyFix(0.0, 0.0, 0.0, null);
    for (var i = 0; i < 40; i++) {
        nav.updateAutoZoom(1000, -1.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 0.6 * tighten, 0.05), "stopped uses the closest level");

    nav.applyFix(0.0, 0.0, 25.0, null); // 90 km/h
    for (var i = 0; i < 40; i++) {
        nav.updateAutoZoom(1000, -1.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 5.0 * tighten, 0.05), "fast pulls the camera back");

    for (var i = 0; i < 40; i++) {
        nav.updateAutoZoom(1000, 120.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 1.2 * tighten, 0.05), "a turn at 120 m forces the zoom in");
    return true;
}

//! Zoom chosen by hand at the riding levels is a preference, not a lookup:
//! the automatic cannot undo it after N seconds.
(:test)
function manualZoomStaysUntilTheRiderChangesItAgain(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.setAutoZoom(true);
    nav.applyFix(0.0, 0.0, 25.0, null); // fast: the automatic would want to open

    nav.cycleZoom(1000); // index 1 -> 2 = 2.5 m/px, still a riding level
    Test.assertEqualMessage(nav.zoomIndex, 2, "cycled to the next level");

    // An hour later, the automatic is still out of command.
    for (var i = 0; i < 60; i++) {
        nav.updateAutoZoom(3600000, -1.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 2.5, 0.001), "the manual value stayed");
    return true;
}

//! The **very wide** zoom, on the other hand, is a look at the whole route, not a way of riding:
//! that one goes back to the automatic by itself.
(:test)
function wideManualZoomGivesTheControlBack(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.setAutoZoom(true);
    nav.applyFix(0.0, 0.0, 25.0, null);

    nav.cycleZoom(1000);
    nav.cycleZoom(1000);
    nav.cycleZoom(1000); // index 4 = 10.0 m/px, lookup level
    Test.assertEqualMessage(nav.zoomIndex, nav.BROWSE_ZOOM_INDEX, "reached the first browse level");

    nav.updateAutoZoom(5000, -1.0); // 4 s later: still the rider's
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 10.0, 0.001), "within the window, it does not move");

    // After the 10 s, the automatic resumes and converges to the speed target.
    for (var i = 0; i < 80; i++) {
        nav.updateAutoZoom(20000, -1.0);
    }
    Test.assertMessage(NavAssert.near(nav.metersPerPx, 5.0 * nav.ZOOM_TIGHTEN, 0.05),
        "after the window it goes back to the auto target");
    return true;
}

//! Heading smoothed in components: the turn from 350° to 10° must not make the
//! map spin all the way around the wrong way.
(:test)
function headingSmoothingCrossesNorthWithoutSpinning(logger as Logger) as Boolean {
    var nav = new NavState();
    var almostNorth = (350.0 * Math.PI / 180.0).toFloat();
    var justPastNorth = (10.0 * Math.PI / 180.0).toFloat();

    for (var i = 0; i < 30; i++) {
        nav.applyFix(0.0, 0.0, 10.0, almostNorth);
    }
    var before = nav.headingRad;

    for (var i = 0; i < 30; i++) {
        nav.applyFix(0.0, 0.0, 10.0, justPastNorth);
    }
    var after = nav.headingRad;

    Test.assertMessage(NavAssert.near(before, -0.1745, 0.02), "350° is -10° in radians");
    Test.assertMessage(NavAssert.near(after, 0.1745, 0.02), "reached +10°");
    return true;
}

//! **The test that was missing.** Track-up was only exercised with heading zero — stopped
//! and on foot, where `R(+h)` and `R(−h)` give exactly the same result — and so
//! the inverted rotation went through the whole F2 without anyone seeing. Heading east is the
//! minimal case that separates the two signs.
(:test)
function rendererTurnsTheDirectionOfTravelUpwards(logger as Logger) as Boolean {
    var map = new MapRenderer();
    var nav = new NavState();
    nav.metersPerPx = 1.0;
    nav.headingRad = (Math.PI / 2.0).toFloat(); // east
    map.begin(nav);

    // 100 m east = 100 m ahead: must go up 100 px above the anchor.
    var aheadX = map.screenX(100.0, 0.0);
    var aheadY = map.screenY(100.0, 0.0);
    Test.assertMessage(NavAssert.near(aheadY.toFloat(), (map.ANCHOR_Y - 100).toFloat(), 1.0),
        "heading east, what is to the east goes up");
    Test.assertMessage(NavAssert.near(aheadX.toFloat(), map.ANCHOR_X.toFloat(), 1.0),
        "and stays vertical from the anchor, without sliding sideways");

    // With the same heading, north is on the left.
    var northX = map.screenX(0.0, 100.0);
    var northY = map.screenY(0.0, 100.0);
    Test.assertMessage(NavAssert.near(northX.toFloat(), (map.ANCHOR_X - 100).toFloat(), 1.0),
        "facing east, north falls to the left");
    Test.assertMessage(NavAssert.near(northY.toFloat(), map.ANCHOR_Y.toFloat(), 1.0),
        "at the same height as the anchor");
    return true;
}

//! Heading zero is the degenerate case: north up, east to the right.
(:test)
function rendererKeepsNorthUpWhenHeadingIsZero(logger as Logger) as Boolean {
    var map = new MapRenderer();
    var nav = new NavState();
    nav.metersPerPx = 1.0;
    map.begin(nav);

    Test.assertMessage(NavAssert.near(map.screenY(0.0, 100.0).toFloat(), (map.ANCHOR_Y - 100).toFloat(), 1.0),
        "north up");
    Test.assertMessage(NavAssert.near(map.screenX(100.0, 0.0).toFloat(), (map.ANCHOR_X + 100).toFloat(), 1.0),
        "east to the right");

    var north = map.northOnScreen();
    Test.assertMessage(NavAssert.near(north[0] as Float, 0.0, 0.001), "needle with no horizontal component");
    Test.assertMessage(NavAssert.near(north[1] as Float, -1.0, 0.001), "needle pointing up");
    return true;
}

//! Dragging the finger has to move the map in the finger's direction even with the map
//! rotated: `screenDeltaToWorld` is the exact inverse of the frame's transform.
(:test)
function screenDragInvertsTheFrameRotation(logger as Logger) as Boolean {
    var map = new MapRenderer();
    var nav = new NavState();
    nav.metersPerPx = 2.0;
    nav.headingRad = (Math.PI / 2.0).toFloat();
    map.begin(nav);

    // A 50 px drag up on the screen = 100 m forward, and east
    // is where we are going.
    var world = map.screenDeltaToWorld(0, -50);
    Test.assertMessage(NavAssert.near(world[0] as Float, 100.0, 0.5), "up on the screen = east in the world");
    Test.assertMessage(NavAssert.near(world[1] as Float, 0.0, 0.5), "no north component");
    return true;
}

//! A new route has another local plane; the previous route's fix does not hold in it.
(:test)
function invalidateFixDropsThePreviousPlane(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.applyFix(1234.0, 5678.0, 20.0, 1.0);
    nav.pan(300.0, 300.0, 1000);
    Test.assert(nav.hasFix);

    nav.invalidateFix();

    Test.assertMessage(!nav.hasFix, "no fix after switching routes");
    Test.assertMessage(NavAssert.near(nav.centreX(), 0.0, 0.001), "center reset in x");
    Test.assertMessage(NavAssert.near(nav.centreY(), 0.0, 0.001), "center reset in y");
    Test.assertMessage(!nav.browsing, "and the pan of the previous route does not linger");

    // The last known position moves the map without inventing a fix.
    nav.seedCentre(10.0, 20.0);
    Test.assertMessage(!nav.hasFix, "seeding the center does not become a fix");
    Test.assertMessage(NavAssert.near(nav.centreX(), 10.0, 0.001), "but the map centers there");
    return true;
}

//! Stopped, the GPS heading spins by itself: freezing it avoids the map shaking in the hand.
(:test)
function headingFreezesWhenStopped(logger as Logger) as Boolean {
    var nav = new NavState();

    for (var i = 0; i < 30; i++) {
        nav.applyFix(0.0, 0.0, 10.0, 1.0);
    }
    var moving = nav.headingRad;

    nav.applyFix(0.0, 0.0, 0.5, 3.0); // crazy heading, almost stopped
    Test.assertMessage(NavAssert.near(nav.headingRad, moving, 0.001), "heading did not change while stopped");
    return true;
}
