import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! Helper for the atomic route swap tests (C11, `05 §Regras de robustez 2`).
(:test)
module SwapAssert {

    //! The routes that arrive on top of the [TestVectors] one (route 7).
    const NEW_ID = 8;
    const THIRD_ID = 9;
    const FOURTH_ID = 10;

    //! The same frame, for another route: only the header's `routeId` changes.
    function forRoute(frame as ByteArray, routeId as Number) as ByteArray {
        var copy = frame.slice(0, null);
        copy[2] = (routeId >> 8) & 0xFF;
        copy[3] = routeId & 0xFF;
        return copy;
    }

    //! The whole [TestVectors] route on the watch, with its corridor: it is the
    //! **live** route, the one the rider is following when the new one starts to arrive.
    function liveRoute(assembler as MessageAssembler) as Void {
        assembler.onData(TestVectors.META);
        assembler.onData(TestVectors.POLY);
        assembler.onData(TestVectors.TURNS_0);
        assembler.onData(TestVectors.TURNS_1);
        assembler.onData(TestVectors.CORRIDOR);
        assembler.drainJobs();
    }

    //! The live route is still route 7, whole, with its corridor. `when` says
    //! at which point of the new route's transfer this was checked.
    function oldRouteIsIntact(route as RouteModel, assembler as MessageAssembler, when as String) as Void {
        Test.assertEqualMessage(route.routeId, TestVectors.ROUTE_ID, when + ": the live route changed id");
        Test.assertMessage(route.isComplete(), when + ": the live route stopped being complete");
        Test.assertEqualMessage(route.lats.size(), TestVectors.POINT_COUNT, when + ": points of the live route");
        Test.assertEqualMessage(route.xs.size(), TestVectors.POINT_COUNT, when + ": projection of the live route");
        Test.assertEqualMessage(route.turnType.size(), TestVectors.TURN_COUNT, when + ": maneuvers of the live route");
        Test.assertEqualMessage(
            assembler.getCorridor().wayCount(TestVectors.CORRIDOR_LOD),
            TestVectors.CORRIDOR_WAY_COUNT,
            when + ": corridor of the live route"
        );
    }

    //! Does some `Diag` line contain `fragment`?
    function logged(fragment as String) as Boolean {
        var lines = Diag.lines;
        for (var i = 0; i < lines.size(); i++) {
            if (lines[i].find(fragment) != null) {
                return true;
            }
        }
        return false;
    }
}

//! **The old route holds until the new one is complete.** The recalculation arrives with the
//! rider moving: if the new META erased the route (as up to C11), he would be left
//! without a map and without an arrow during the whole transfer, which is exactly when he
//! just took a wrong turn. The swap happens all at once, on the last slice.
(:test)
function theOldRouteStaysWholeUntilTheNewOneIsComplete(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    SwapAssert.liveRoute(assembler);
    SwapAssert.oldRouteIsIntact(route, assembler, "before the new route");
    var revision = route.revision;

    // More than one slice, so the new route goes through ticks half-way.
    var points = assembler.POLY_SLICE_POINTS + 100;
    assembler.onData(SwapAssert.forRoute(PolyAssert.metaWithPoints(points), SwapAssert.NEW_ID));
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_ROUTE_META, "the new META is acknowledged");
    SwapAssert.oldRouteIsIntact(route, assembler, "after the new META");
    Test.assertMessage(assembler.isSwapPending(), "the new route is being staged");

    assembler.onData(SwapAssert.forRoute(PolyAssert.longPolyFrame(points), SwapAssert.NEW_ID));
    Test.assertMessage(assembler.isPolyPending(), "the new POLY must be half done");
    SwapAssert.oldRouteIsIntact(route, assembler, "with the new POLY half done");

    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.NEW_ID));
    SwapAssert.oldRouteIsIntact(route, assembler, "with the new TURNS and the POLY still being read");

    var finished = false;
    while (assembler.isPolyPending()) {
        finished = assembler.stepJobs();
    }
    Test.assertMessage(finished, "the last slice signals: it is the `showNav` hook");
    Test.assertEqualMessage(route.routeId, SwapAssert.NEW_ID, "the new route went in");
    Test.assertEqualMessage(route.lats.size(), points, "with all the points");
    Test.assertEqualMessage(route.cum.size(), points, "with the cumulative distances");
    Test.assertMessage(route.isComplete(), "and complete");
    Test.assertMessage(route.revision != revision, "the revision changes: it is the key of the drawing cache");
    Test.assertMessage(assembler.getCorridor().isEmpty(), "the old corridor goes with it: it belongs to another plan");
    Test.assertMessage(!assembler.isSwapPending(), "nothing left staging");
    Test.assertMessage(
        SwapAssert.logged("route swapped " + TestVectors.ROUTE_ID.toString() + " -> " + SwapAssert.NEW_ID.toString()),
        "the swap goes to the log"
    );
    return true;
}

//! The new route's POLY is read in slices, tick by tick, and none of them touches the
//! live route. A third route in the middle of the way drops the second without touching the
//! first, and the swap also happens when the last to arrive is the TURNS.
(:test)
function aHalfReadPolyOfTheNewRouteNeverReachesTheLiveOne(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    SwapAssert.liveRoute(assembler);

    var points = Protocol.MAX_POLY_POINTS;
    assembler.onData(SwapAssert.forRoute(PolyAssert.metaWithPoints(points), SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(PolyAssert.longPolyFrame(points), SwapAssert.NEW_ID));
    for (var tick = 0; tick < 3; tick++) {
        Test.assertMessage(!assembler.stepJobs(), "the POLY at the ceiling does not finish in 3 slices");
        SwapAssert.oldRouteIsIntact(route, assembler, "slice " + tick.toString() + " of the new POLY");
    }
    Test.assertMessage(assembler.isPolyPending(), "the new POLY stays half done");

    // Another recalculation arrives before the first finishes: the route being prepared is
    // the one that is dropped, and the live one stays the same.
    assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.THIRD_ID));
    Test.assertMessage(!assembler.isPolyPending(), "the META of the third drops the POLY of the second");
    SwapAssert.oldRouteIsIntact(route, assembler, "after the META of the third");

    // The third with the TURNS last: the swap happens in the block that completes it.
    assembler.onData(SwapAssert.forRoute(TestVectors.POLY, SwapAssert.THIRD_ID));
    SwapAssert.oldRouteIsIntact(route, assembler, "with the POLY of the third read and the TURNS still to come");
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.THIRD_ID));
    SwapAssert.oldRouteIsIntact(route, assembler, "with half the TURNS of the third");
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.THIRD_ID));
    Test.assertEqualMessage(route.routeId, SwapAssert.THIRD_ID, "the third went in on the last block");
    Test.assertMessage(route.isComplete(), "complete");

    // "End route" with a fourth being prepared: the preparation disappears, and its block
    // that arrives later is refused as a block without META.
    assembler.onData(SwapAssert.forRoute(PolyAssert.metaWithPoints(points), SwapAssert.FOURTH_ID));
    assembler.onData(SwapAssert.forRoute(PolyAssert.longPolyFrame(points), SwapAssert.FOURTH_ID));
    Test.assertMessage(assembler.isSwapPending() && assembler.isPolyPending(), "the fourth is being staged");
    assembler.cancelRouteJobs();
    Test.assertMessage(!assembler.isSwapPending() && !assembler.isPolyPending(), "ending drops the staging");
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.FOURTH_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.FOURTH_ID));
    Test.assertEqualMessage(link.lastBitmap[0], 0x00, "the orphan TURNS comes back with an empty ACK");
    Test.assertEqualMessage(route.routeId, SwapAssert.THIRD_ID, "and the live route does not change");
    return true;
}

//! The phone vanishes in the middle of the recalculation (battery, range, dead process). The
//! route being prepared cannot stay forever: it takes memory, and the off-route check
//! waits while a response is arriving, so it would never say "No phone".
(:test)
function aNewRouteThatStopsArrivingIsDropped(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    SwapAssert.liveRoute(assembler);

    assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.NEW_ID));
    var now = System.getTimer();
    assembler.dropStaleStaging(now + Protocol.BLOCK_TIMEOUT_MS - 1000);
    Test.assertMessage(assembler.isSwapPending(), "within the deadline the staging stays");

    assembler.dropStaleStaging(now + Protocol.BLOCK_TIMEOUT_MS + 1000);
    Test.assertMessage(!assembler.isSwapPending(), "past the deadline, the staging is dropped");
    SwapAssert.oldRouteIsIntact(route, assembler, "after dropping the staging");

    assembler.onData(SwapAssert.forRoute(TestVectors.POLY, SwapAssert.NEW_ID));
    Test.assertEqualMessage(link.lastBitmap[0], 0x00, "the rest of it comes back with an empty ACK: the phone restarts from the META");
    SwapAssert.oldRouteIsIntact(route, assembler, "with the late block refused");

    // And a repeated META of the live route, with another being prepared, does not restart it.
    assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.NEW_ID));
    assembler.onData(TestVectors.META);
    SwapAssert.oldRouteIsIntact(route, assembler, "after the repeated META of the live route");
    Test.assertMessage(assembler.isSwapPending(), "and the staging goes on");
    return true;
}

//! The phone sends the corridor right behind the route. If it arrives before the swap,
//! it cannot be drawn (the local plane is still the old route's) nor refused
//! (the phone would give up after 3 rounds and the new route would have no streets):
//! it is kept, with ACK, and goes in after the swap.
(:test)
function theCorridorOfTheNewRouteWaitsForTheSwap(logger as Logger) as Boolean {
    var route = new RouteModel();
    var link = new FakeLink();
    var assembler = new MessageAssembler(route, link);
    SwapAssert.liveRoute(assembler);
    var corridor = assembler.getCorridor();

    // The new route's corridor at a different LOD from the old one, so it is possible
    // to tell whose each way is.
    var newLod = Protocol.LOD_EXPRESS;
    Test.assertMessage(newLod != TestVectors.CORRIDOR_LOD, "the test LODs must differ");
    var newCorridor = SwapAssert.forRoute(TestVectors.CORRIDOR, SwapAssert.NEW_ID);
    newCorridor[Protocol.HEADER_SIZE] = newLod;

    assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.NEW_ID));
    assembler.onData(newCorridor);
    Test.assertEqualMessage(link.lastAckType, Protocol.MSG_CORRIDOR, "the early corridor is acknowledged");
    Test.assertEqualMessage(link.lastBitmap[0], 0x01, "with the chunk marked, not an empty ACK");
    Test.assertEqualMessage(corridor.wayCount(newLod), 0, "and it does not enter the plan of the old route");
    SwapAssert.oldRouteIsIntact(route, assembler, "with the new corridor stored");

    assembler.onData(SwapAssert.forRoute(TestVectors.POLY, SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.NEW_ID));
    Test.assertEqualMessage(route.routeId, SwapAssert.NEW_ID, "the new route went in");
    Test.assertEqualMessage(corridor.wayCount(TestVectors.CORRIDOR_LOD), 0, "the old one's corridor went out");
    Test.assertMessage(assembler.isCorridorPending(), "and the stored one is queued");

    assembler.drainCorridor();
    Test.assertEqualMessage(
        corridor.wayCount(newLod), TestVectors.CORRIDOR_WAY_COUNT, "the stored corridor went in after the swap");

    // A late block from the old route does not come back to the new one's map.
    assembler.onData(TestVectors.CORRIDOR);
    assembler.drainCorridor();
    Test.assertEqualMessage(link.lastBitmap[0], 0x00, "the corridor of the old route comes back with an empty ACK");
    Test.assertEqualMessage(corridor.wayCount(TestVectors.CORRIDOR_LOD), 0, "and it is not drawn");
    return true;
}

//! The drawing keeps which stretches of the route appear on screen and only redoes the math
//! when the center moves, the scale changes **or the route changes**. Up to C11 "the route
//! changed" was "the number of points changed": a recalculation with the same number of
//! points, with the rider stopped, would keep drawing the old route's stretches
//! with the new one's coordinates.
(:test)
function aSwappedRouteOfTheSameSizeIsDrawnAnew(logger as Logger) as Boolean {
    if (!(Graphics has :createBufferedBitmap)) {
        return true;
    }
    var buffer = Graphics.createBufferedBitmap({ :width => 454, :height => 454 });
    var dc = buffer.get().getDc();

    var route = NavAssert.straightRoute(800);
    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    var corridor = new CorridorModel();
    nav.applyFix(0.0, 40000.0, 10.0, 0.0);
    matcher.update(0.0, 40000.0);
    map.draw(dc, route, nav, matcher, corridor);
    Test.assertMessage(map.routeRanges().size() > 0, "the old route crosses the screen");

    // The new route: the same 800 points, 50 km to the east. Rider, center and scale
    // do not change, so only the swap can redo the visible stretches.
    var other = NavAssert.straightRoute(800);
    var xs = other.xs;
    for (var i = 0; i < xs.size(); i++) {
        xs[i] = 50000.0;
    }
    other.blockBox = RouteModel.boxesOf(other.xs, other.ys);
    route.adopt(other);

    map.draw(dc, route, nav, matcher, corridor);
    Test.assertEqualMessage(map.routeRanges().size(), 0, "the new route is off screen: no stretch of the old one is left");
    return true;
}

//! The worst memory case of the swap: a route at the protocol ceiling being swapped
//! for another at the ceiling. During the transfer the watch holds the live route, the
//! one being prepared, the POLY block and the `PolyParseJob`'s reserved arrays; if that
//! did not fit, the app would die of out-of-memory exactly on the recalculation of
//! a long trip. Here the swap has to finish, and the test log keeps
//! the measured memory (`DECISIONS.md` §C11).
(:test)
function aRouteAtTheCeilingIsSwappedForAnotherAtTheCeiling(logger as Logger) as Boolean {
    var points = Protocol.MAX_POLY_POINTS;
    var route = new RouteModel();
    var assembler = new MessageAssembler(route, new FakeLink());
    assembler.onData(PolyAssert.metaWithPoints(points));
    assembler.onData(PolyAssert.longPolyFrame(points));
    assembler.onData(TestVectors.TURNS_0);
    assembler.onData(TestVectors.TURNS_1);
    assembler.drainJobs();
    Test.assertMessage(route.isComplete(), "the live route at the ceiling is whole");
    var before = System.getSystemStats().usedMemory;

    assembler.onData(SwapAssert.forRoute(PolyAssert.metaWithPoints(points), SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.NEW_ID));
    assembler.onData(SwapAssert.forRoute(PolyAssert.longPolyFrame(points), SwapAssert.NEW_ID));
    var peak = System.getSystemStats().usedMemory;
    while (assembler.isPolyPending()) {
        assembler.stepJobs();
        var used = System.getSystemStats().usedMemory;
        if (used > peak) {
            peak = used;
        }
    }
    var after = System.getSystemStats().usedMemory;

    Test.assertEqualMessage(route.routeId, SwapAssert.NEW_ID, "the new route at the ceiling went in");
    Test.assertEqualMessage(route.lats.size(), points, "whole");
    logger.debug("swap " + points.toString() + " -> " + points.toString() + " pts: before "
        + (before / 1024).toString() + " KB, largest seen between slices " + (peak / 1024).toString()
        + " KB, after " + (after / 1024).toString() + " KB of "
        + (System.getSystemStats().totalMemory / 1024).toString() + " KB");
    return true;
}
