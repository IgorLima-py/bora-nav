import Toybox.Lang;
import Toybox.Test;

//! **ROUTE_UPDATE** (C13a, `05 §ROUTE_UPDATE`): the phone redoes the route time
//! calculation every 10 min and sends the new duration.
//!
//! The bytes come from `TestVectors`; the `ROUTE_UPDATE` there is **the very
//! `tools/fixtures/route_update_00.bin`**, the same file the Kotlin
//! `routeUpdateMatchesFixture` compares the packer against, and it is about route 7,
//! which is the vectors' one.
(:test)
module RouteUpdateAssert {

    //! The 0x06 ACK that says "applied" (full bitmap).
    function accepted(link as FakeLink, when as String) as Void {
        Test.assertEqualMessage(link.lastAckType, Protocol.MSG_ROUTE_UPDATE, when + ": ACK of 0x06");
        Test.assertEqualMessage(link.lastBitmap.size(), 1, when + ": one bitmap byte");
        Test.assertEqualMessage(link.lastBitmap[0], 0x01, when + ": full bitmap");
    }

    //! The 0x06 ACK that says "it is not the route I am navigating" (empty bitmap).
    function refused(link as FakeLink, when as String) as Void {
        Test.assertEqualMessage(link.lastAckType, Protocol.MSG_ROUTE_UPDATE, when + ": ACK of 0x06");
        Test.assertEqualMessage(link.lastBitmap.size(), 1, when + ": one bitmap byte");
        Test.assertEqualMessage(link.lastBitmap[0], 0x00, when + ": empty bitmap");
    }
}

(:test)
module RouteUpdateTest {

    //! The packer.py `route_update_00.bin` swaps the live route's duration, with a full
    //! ACK, no transfer screen (`lastWasRouteUpdate`) and without touching the
    //! points, maneuvers or statistics.
    // prevents: the watch ETA stuck on the META one for the whole trip (0x06 used to fall into
    // "msgType nao tratado"), or coming out absurd from reading 2 of the 4 bytes or the wrong end.
    (:test)
    function appliesTheFixtureToTheLiveRoute(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        var chunks = assembler.chunksReceived;
        var revision = route.revision;
        Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, "the META duration, before");

        assembler.onData(TestVectors.ROUTE_UPDATE);

        Test.assertEqualMessage(route.durationS, TestVectors.ROUTE_UPDATE_DURATION_S, "the new duration");
        RouteUpdateAssert.accepted(link, "fixture");
        Test.assertMessage(assembler.lastWasRouteUpdate, "the app needs to know it was a ROUTE_UPDATE");
        Test.assertMessage(!assembler.lastWasRouteBlock, "nor as a route piece, which would bring up the waiting screen");
        Test.assertEqualMessage(assembler.chunksReceived, chunks, "does not count as a route chunk");
        Test.assertEqualMessage(route.revision, revision, "the geometry did not change: the drawing is not rebuilt");
        SwapAssert.oldRouteIsIntact(route, assembler, "after the update");
        Test.assertMessage(
            SwapAssert.logged("eta route 7: " + TestVectors.DURATION_S.toString() + " -> "
                + TestVectors.ROUTE_UPDATE_DURATION_S.toString() + " s"),
            "the log line the e2e counts"
        );

        // The next message, of another type, clears the mark.
        assembler.onData(TestVectors.CORRIDOR);
        assembler.drainJobs();
        Test.assertMessage(!assembler.lastWasRouteUpdate, "the mark belongs only to the last message");
        Test.assertMessage(assembler.lastWasRouteBlock, "the corridor is a route piece");

        // The refused one is not: with the route half-way, it goes to the `DebugView` with the error.
        assembler.onData([Protocol.VERSION]b);
        Test.assertMessage(!assembler.lastWasRouteBlock, "a short header is not a route piece");
        Diag.clear();
        return true;
    }

    //! Update for a route that is not the live one, or with no route at all: refused, with an
    //! **empty** ACK, and the duration stays as it was.
    // prevents: a late update of the previous route swapping the new route's ETA; and the phone
    // thinking the navigation holds (full ACK) when the watch no longer has that route.
    (:test)
    function anUpdateAboutAnotherRouteIsRefused(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);

        assembler.onData(TestVectors.ROUTE_UPDATE);
        RouteUpdateAssert.refused(link, "no route on the watch");
        Test.assertMessage(SwapAssert.logged("eta refused route 7: active route is none"), "the why, in the log");

        SwapAssert.liveRoute(assembler);
        assembler.onData(SwapAssert.forRoute(TestVectors.ROUTE_UPDATE, SwapAssert.NEW_ID));
        RouteUpdateAssert.refused(link, "of another route");
        Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, "the live route duration stays");
        Test.assertMessage(SwapAssert.logged("eta refused route 8: active route is 7"), "the why, in the log");
        Diag.clear();
        return true;
    }

    //! What is not a whole ROUTE_UPDATE (`05 §Regras de robustez 4`): one byte
    //! short, one extra, zero, the sign bit, and the message in two chunks.
    // prevents: a corrupted frame zeroing the ETA (duration 0 becomes "0 min" on screen) or putting a
    // negative number in it; and the watch reading beyond the payload.
    (:test)
    function malformedUpdatesAreRefused(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);

        var bad = [
            TestVectors.ROUTE_UPDATE_SHORT,
            TestVectors.ROUTE_UPDATE_LONG,
            TestVectors.ROUTE_UPDATE_ZERO,
            TestVectors.ROUTE_UPDATE_NEGATIVE,
            TestVectors.ROUTE_UPDATE_TWO_CHUNKS
        ];
        var names = ["short", "long", "zero", "negative", "two chunks"];
        for (var i = 0; i < bad.size(); i++) {
            var acks = link.ackCount;
            assembler.onData(bad[i] as ByteArray);
            Test.assertEqualMessage(link.ackCount, acks + 1, names[i] + ": the ACK goes out");
            RouteUpdateAssert.refused(link, names[i]);
            Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, names[i] + ": the duration stays");
        }
        Diag.clear();
        return true;
    }

    //! With the navigation off the air (arrived), the route stays loaded with the same
    //! `routeId`, but the update is refused: that is how the phone finds out.
    // prevents: the `NAV_ENDED` getting lost on arrival and the watch answering "applied" every
    // 10 min forever, with the phone service alive and the CPU awake until the battery runs out.
    (:test)
    function anUpdateAfterArrivalIsRefused(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        var nav = new NavState();
        assembler.nav = nav;
        SwapAssert.liveRoute(assembler);

        nav.phase = NavPhase.ARRIVED;
        assembler.onData(TestVectors.ROUTE_UPDATE);
        RouteUpdateAssert.refused(link, "after arrival");
        Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, "the duration stays");
        Test.assertMessage(SwapAssert.logged("eta refused route 7: navigation not active"), "the why, in the log");

        nav.phase = NavPhase.NAVIGATING;
        assembler.onData(TestVectors.ROUTE_UPDATE);
        RouteUpdateAssert.accepted(link, "navigating");
        Test.assertEqualMessage(route.durationS, TestVectors.ROUTE_UPDATE_DURATION_S, "navigating, applies");
        Diag.clear();
        return true;
    }

    //! The update for the route **being prepared** is accepted and holds after the swap: the phone
    //! counts the route as delivered at the last block's ACK, before the watch swaps.
    // prevents: the phone ending the session as "refused" when the watch just did not finish
    // swapping routes (the swap waits for the last POLY slice).
    (:test)
    function anUpdateAboutTheRouteInStagingIsKept(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);

        assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.NEW_ID));
        Test.assertMessage(assembler.isSwapPending(), "the new route is being staged");

        assembler.onData(SwapAssert.forRoute(TestVectors.ROUTE_UPDATE, SwapAssert.NEW_ID));
        RouteUpdateAssert.accepted(link, "route staging");
        Test.assertEqualMessage(route.durationS, TestVectors.DURATION_S, "the live route is not touched");
        Test.assertEqualMessage(route.routeId, TestVectors.ROUTE_ID, "nor swapped");

        assembler.onData(SwapAssert.forRoute(TestVectors.POLY, SwapAssert.NEW_ID));
        assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.NEW_ID));
        assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.NEW_ID));
        assembler.drainJobs();

        Test.assertEqualMessage(route.routeId, SwapAssert.NEW_ID, "the new route went in");
        Test.assertEqualMessage(route.durationS, TestVectors.ROUTE_UPDATE_DURATION_S, "with the duration of the update");
        Diag.clear();
        return true;
    }

    //! **Igor's pace reaches the screen** (C16). Mapbox only has a car profile; the phone learns
    //! how much of its time Igor takes by motorcycle (`PersonalPace.kt`) and multiplies the duration before
    //! sending, in the META and the ROUTE_UPDATE, without changing the format. The update here carries the
    //! `watch_s` of `tools/fixtures/ritmo.json`, the same number `PersonalPaceTest` in Kotlin
    //! gets from the fixture's trips: 1710 s from Mapbox, factor 0.8, 1368 s.
    // prevents: the watch redoing the math on top of what the phone corrected, and the bottom card
    // staying on car time ("29 min") after the phone has learned the pace ("23 min").
    (:test)
    function thePacedDurationIsWhatTheHudShows(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        Test.assertEqualMessage(route.durationS, TestVectors.PACE_MAPBOX_S, "the META is the Mapbox time");

        // At the start, stopped: with no average speed, the time left is the whole duration.
        var nav = new NavState();
        var matcher = new MapMatcher(route);
        nav.applyFix(route.xs[0] as Float, route.ys[0] as Float, 0.0, null);
        matcher.update(route.xs[0] as Float, route.ys[0] as Float);
        var hud = new Hud();
        hud.draw(Rnf05Assert.canvas(BurnInAssert.SIZE), route, nav, matcher);
        var car = NavEngine.formatDuration(TestVectors.PACE_MAPBOX_S) + " · ";
        logger.debug("before pace: " + hud.restShown);
        Test.assertEqualMessage(hud.restShown.find(car), 0, "the card wrote '" + hud.restShown + "'");

        assembler.onData(TestVectors.ROUTE_UPDATE_PACE);
        RouteUpdateAssert.accepted(link, "pace");
        Test.assertEqualMessage(route.durationS, TestVectors.PACE_WATCH_S, "the duration with pace, as it came");
        hud.draw(Rnf05Assert.canvas(BurnInAssert.SIZE), route, nav, matcher);
        var paced = NavEngine.formatDuration(TestVectors.PACE_WATCH_S) + " · ";
        logger.debug("with pace: " + hud.restShown);
        Test.assertEqualMessage(hud.restShown.find(paced), 0, "the card wrote '" + hud.restShown + "'");
        Test.assertMessage(!paced.equals(car), "the fixture pace must change the minute on screen");
        BurnInAssert.done();
        Diag.clear();
        return true;
    }
}
