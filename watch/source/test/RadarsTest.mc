import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

//! **RADARS** (C16.6, `05 §RADARS`): the route's speed cameras, from the phone to the watch.
//!
//! The bytes come from `TestVectors`. The `RADARS_FIXTURE` there is **`tools/fixtures/radars_00.bin`
//! itself**, the same file as the Kotlin `radarsMatchFixture`; `RADARS` is
//! the same payload on route 7, the vectors' one.
(:test)
module RadarsAssert {

    //! A fake route with speed cameras at `dist` (m along the route) and `limit` (km/h).
    function route(dist as Array<Number>, limit as Array<Number>) as RouteModel {
        var route = new RouteModel();
        route.radarDist = dist;
        route.radarLimit = limit;
        var xs = [] as Array<Float>;
        var flags = [] as Array<Number>;
        for (var i = 0; i < dist.size(); i++) {
            xs.add(0.0);
            flags.add(Protocol.RADAR_FLAG_DIRECTION);
        }
        route.radarX = xs;
        route.radarY = xs;
        route.radarFlags = flags;
        return route;
    }

    //! Would the motor be called on this device? Mirrors the gates of `AlertPolicy.vibrateIf`.
    function canVibrate() as Boolean {
        if (!(Attention has :vibrate)) {
            return false;
        }
        var settings = System.getDeviceSettings();
        return !(settings has :vibrateOn) || settings.vibrateOn;
    }
}

(:test)
module RadarsTest {

    //! The fixture's three cameras enter the live route, in order, with the limit (the unknown one
    //! included), the flags and the position projected onto the route plane.
    // prevents: 0x08 falling into "msgType nao tratado" and the camera never reaching the wrist; or the position
    // coming out of the wrong plane (lat and lon swapped) and the icon showing up far from the street.
    (:test)
    function theFixtureLandsOnTheLiveRoute(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);

        assembler.onData(TestVectors.RADARS);

        Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_COUNT, "how many radars");
        Test.assertEqualMessage(route.radarDist[0], TestVectors.RADAR0_DIST_M, "distance of the 1st");
        Test.assertEqualMessage(route.radarDist[2], TestVectors.RADAR2_DIST_M, "distance of the 3rd");
        Test.assertEqualMessage(route.radarLimit[0], TestVectors.RADAR0_LIMIT, "limit of the 1st");
        Test.assertEqualMessage(route.radarLimit[1], 0, "the 2nd with no known limit");
        Test.assertEqualMessage(route.radarFlags[2], TestVectors.RADAR2_FLAGS, "the 3rd with no known direction");
        var x = Projection.toLocalX(route.lon0 + TestVectors.RADAR1_DLON, route.lon0, route.lonScale);
        var y = Projection.toLocalY(route.lat0 + TestVectors.RADAR1_DLAT, route.lat0);
        Test.assertEqualMessage(route.radarX[1], x, "x of the 2nd in the route plane");
        Test.assertEqualMessage(route.radarY[1], y, "y of the 2nd in the route plane");
        Test.assertEqualMessage(link.lastAckType, Protocol.MSG_RADARS, "ACK of 0x08");
        Test.assertEqualMessage(link.lastBitmap[0], 0x01, "full bitmap");
        Test.assertMessage(SwapAssert.logged("radars 3 route 7"), "the log line");
        SwapAssert.oldRouteIsIntact(route, assembler, "after the radars");
        Diag.clear();
        return true;
    }

    //! What does not close (a short record, one extra byte, out of order, two chunks) is rejected
    //! whole: the previous cameras stay, and the log says why.
    (:test)
    function aBrokenRadarsIsRefusedWhole(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        assembler.onData(TestVectors.RADARS);
        var broken = [TestVectors.RADARS_SHORT, TestVectors.RADARS_LONG, TestVectors.RADARS_OUT_OF_ORDER]
            as Array<ByteArray>;
        for (var i = 0; i < broken.size(); i++) {
            assembler.onData(broken[i]);
            Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_COUNT, "refusal " + i.toString());
            Test.assertMessage(assembler.lastError.find("radars refused") != null,
                "the refusal error " + i.toString() + ": " + assembler.lastError);
        }
        // Two chunks: the block only closes with both, and then it is rejected.
        var two = TestVectors.RADARS_TWO_CHUNKS;
        assembler.onData(two);
        var second = two.slice(0, null);
        second[4] = 1;
        assembler.onData(second);
        Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_COUNT, "two chunks");
        Test.assertMessage(SwapAssert.logged("radars refused: 2 chunks"), "the log of the two chunks");
        Diag.clear();
        return true;
    }

    //! `count = 0` erases the cameras; more than 200 well-formed ones leave the first 200.
    (:test)
    function anEmptyListClearsAndTheCapCuts(logger as Logger) as Boolean {
        Diag.clear();
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        assembler.onData(TestVectors.RADARS);
        assembler.onData(TestVectors.RADARS_EMPTY);
        Test.assertEqualMessage(route.radarDist.size(), 0, "the empty list erases");
        assembler.onData(TestVectors.radarsOverCap());
        Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_MAX, "the ceiling");
        Test.assertMessage(SwapAssert.logged("radars 200 route 7 (of 201)"), "the log of the cut");
        Diag.clear();
        return true;
    }

    //! The new route's cameras arrive before the swap and enter with it; the old route's do not linger.
    // prevents: a recalculation carrying the old route's cameras (another local plane, other distances).
    (:test)
    function theRadarsOfTheNewRouteRideTheSwap(logger as Logger) as Boolean {
        var route = new RouteModel();
        var link = new FakeLink();
        var assembler = new MessageAssembler(route, link);
        SwapAssert.liveRoute(assembler);
        assembler.onData(TestVectors.RADARS);

        assembler.onData(SwapAssert.forRoute(TestVectors.META, SwapAssert.NEW_ID));
        assembler.onData(SwapAssert.forRoute(TestVectors.RADARS_EMPTY, SwapAssert.NEW_ID));
        Test.assertEqualMessage(link.lastAckType, Protocol.MSG_RADARS, "the early radars are acknowledged");
        Test.assertEqualMessage(link.lastBitmap[0], 0x01, "with the chunk marked");
        Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_COUNT, "the live route keeps its own");
        assembler.onData(SwapAssert.forRoute(TestVectors.radarsOverCap(), SwapAssert.NEW_ID));

        assembler.onData(SwapAssert.forRoute(TestVectors.POLY, SwapAssert.NEW_ID));
        assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_0, SwapAssert.NEW_ID));
        assembler.onData(SwapAssert.forRoute(TestVectors.TURNS_1, SwapAssert.NEW_ID));
        Test.assertEqualMessage(route.routeId, SwapAssert.NEW_ID, "the new route went in");
        Test.assertEqualMessage(route.radarDist.size(), TestVectors.RADARS_MAX, "with its own radars");

        route.clear();
        Test.assertEqualMessage(route.radarDist.size(), 0, "the end of the route takes the radars with it");
        return true;
    }

    //! The sign rule (`05 §RADARS`): 10 s at the limit, half a second more per km/h above, floor of
    //! 250 m and ceiling of 1000 m; with an unknown limit, only the 10 s. And only the next one ahead counts.
    (:test)
    function theSignShowsAtTheLeadDistance(logger as Logger) as Boolean {
        Test.assertEqualMessage(Radars.showM(46, 50), 250, "slow, the floor");
        Test.assertEqualMessage(Radars.showM(72, 50), 420, "at 72 in a 50 zone: 21 s");
        Test.assertEqualMessage(Radars.showM(100, 0), 277, "unknown limit at 100: 10 s");
        Test.assertEqualMessage(Radars.showM(200, 40), 1000, "the ceiling");

        var route = RadarsAssert.route([500, 1400, 3000] as Array<Number>, [50, 0, 60] as Array<Number>);
        Test.assertEqualMessage(Radars.ahead(route, 0.0), 0, "the first one ahead");
        Test.assertEqualMessage(Radars.ahead(route, 600.0), 1, "the next at 800 m, within the ceiling");
        Test.assertEqualMessage(Radars.ahead(route, 1500.0), -1, "the next at 1500 m, beyond the ceiling");
        Test.assertEqualMessage(Radars.shown(route, 1140.0, 50), -1, "at 260 m from the one with no limit, at 50 km/h");
        Test.assertEqualMessage(Radars.shown(route, 1160.0, 50), 1, "at 240 m, the sign");
        return true;
    }

    //! The camera vibrates once, when the sign appears, by its own key (CONFIG 22) and not by the
    //! turn warnings' (CONFIG 21); with 22 off, the warning goes to the log and the motor stays idle.
    // prevents: Igor turning off "Vibrar no pulso" (Vibrate on the wrist) and losing the camera along with it, or the camera vibrating on every fix.
    (:test)
    function theRadarVibratesOnceByItsOwnKey(logger as Logger) as Boolean {
        var vibe = Config.values[Config.KEY_VIBE_ON - 1];
        var radarVibe = Config.values[Config.KEY_RADAR_VIBE - 1];
        var route = RadarsAssert.route([500, 1400] as Array<Number>, [50, 0] as Array<Number>);
        var expect = RadarsAssert.canVibrate() ? 1 : 0;

        Config.values[Config.KEY_VIBE_ON - 1] = 0;
        Config.values[Config.KEY_RADAR_VIBE - 1] = 1;
        var alerts = new AlertPolicy();
        alerts.updateRadar(route, 0.0, 50.0 / 3.6);
        Test.assertEqualMessage(alerts.radarAlerts, 0, "at 500 m and 50 km/h the sign does not show yet (250 m)");
        alerts.updateRadar(route, 260.0, 50.0 / 3.6);
        alerts.updateRadar(route, 300.0, 50.0 / 3.6);
        alerts.updateRadar(route, 400.0, 50.0 / 3.6);
        Test.assertEqualMessage(alerts.radarAlerts, 1, "one alert per radar");
        Test.assertEqualMessage(alerts.motorCalls, expect, "the motor with 21 off and 22 on");

        Config.values[Config.KEY_RADAR_VIBE - 1] = 0;
        alerts.updateRadar(route, 1200.0, 50.0 / 3.6);
        Test.assertEqualMessage(alerts.radarAlerts, 2, "the second radar alerts in the log");
        Test.assertEqualMessage(alerts.motorCalls, expect, "and the motor stays still with 22 off");

        Config.values[Config.KEY_VIBE_ON - 1] = vibe;
        Config.values[Config.KEY_RADAR_VIBE - 1] = radarVibe;
        logger.debug("motor in this simulator: " + (expect == 1 ? "yes" : "no"));
        return true;
    }

    //! The cache list swaps for the new search in the middle of the route (`RerouteController`: the cache on the 1st
    //! failure, the fresh answer later), with another number of cameras before the bike. The warning follows
    //! the camera's position on the route, not the index in the list.
    // prevents: the camera not vibrating (the new list has fewer cameras behind) or vibrating twice (it has
    // more), a finding from the second opinion of the C16.6 /tchau.
    (:test)
    function theRadarAlertSurvivesAFreshListMidRoute(logger as Logger) as Boolean {
        var kmh50 = 50.0 / 3.6;
        var limits = [50, 50, 50, 50] as Array<Number>;
        var alerts = new AlertPolicy();
        var cached = RadarsAssert.route([500, 900, 2000, 3000] as Array<Number>, limits);
        alerts.updateRadar(cached, 300.0, kmh50);
        alerts.updateRadar(cached, 700.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 2, "the first two from the cache");

        // The new search does not have the 900 m one: the 2000 m one becomes index 1.
        var fresh = RadarsAssert.route([500, 2000, 3000] as Array<Number>, limits.slice(0, 3));
        alerts.updateRadar(fresh, 1800.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 3, "the 2000 m one vibrates even with the index of one already alerted");

        // Another list, with one more camera at the start: the 2000 m one becomes index 2 and does not vibrate again.
        var longer = RadarsAssert.route([100, 500, 2000, 3000] as Array<Number>, limits);
        alerts.updateRadar(longer, 1850.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 3, "the 2000 m one does not vibrate twice");
        alerts.updateRadar(longer, 2800.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 4, "and the 3000 m one vibrates");
        return true;
    }

    //! Two cameras 50 m apart are two to the phone's `RadarFilter`, which only merges the ones
    //! less than 50 m apart (`kept.distAlongM - last.distAlongM < DEDUP_M`). The watch must
    //! warn about both.
    // prevents: the C16.7 50 m tie (step 4), the phone sending the camera and the watch staying quiet
    // because of `at <= avisado + 50`.
    (:test)
    function twoRadarsFiftyMetresApartBothAlert(logger as Logger) as Boolean {
        var kmh50 = 50.0 / 3.6;
        var alerts = new AlertPolicy();
        var route = RadarsAssert.route([500, 550] as Array<Number>, [50, 50] as Array<Number>);
        alerts.updateRadar(route, 300.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 1, "the 500 m one");
        alerts.updateRadar(route, 510.0, kmh50);
        Test.assertEqualMessage(alerts.radarAlerts, 2, "and the 550 m one, which the phone sent");
        return true;
    }

    //! The warning line carries the camera's distance along the route (`d`), which is the key for
    //! `tools/relatorio.py` to find the OSM id in the phone's `radar i/n` line (C16.7).
    // prevents: the ride log saying `vibra radar 0` without saying which camera it was, and the coverage not
    // telling apart the camera that did not warn from the one that was not on the list (ride of 26/10, DECISIONS).
    (:test)
    function theRadarAlertLogsTheRadarDistance(logger as Logger) as Boolean {
        var alerts = new AlertPolicy();
        var route = RadarsAssert.route([500, 1400] as Array<Number>, [50, 0] as Array<Number>);
        alerts.updateRadar(route, 300.0, 50.0 / 3.6);
        var last = Diag.lines[Diag.lines.size() - 1] as String;
        logger.debug(last);
        Test.assertMessage(last.find("vibe radar 0 at 200m 50km/h d500") != null, "got: " + last);
        return true;
    }

    //! **With turn vibration off (CONFIG 21 at 0) the motor is not called**, and the warning rule
    //! keeps counting (`sim.py ride` reads the log). When on, the motor is called on every warning.
    // prevents: the phone's switch not turning anything off, or also turning off the log that proves the ride.
    (:test)
    function theTurnAlertIsSilentWithVibeOff(logger as Logger) as Boolean {
        var vibe = Config.values[Config.KEY_VIBE_ON - 1];
        var expect = RadarsAssert.canVibrate() ? 1 : 0;

        Config.values[Config.KEY_VIBE_ON - 1] = 0;
        var alerts = new AlertPolicy();
        alerts.update(0, Protocol.TURN_LEFT, 60.0, 10.0);
        Test.assertEqualMessage(alerts.alerts, 1, "the alert counts with vibration off");
        Test.assertEqualMessage(alerts.motorCalls, 0, "and the motor stays still");

        Config.values[Config.KEY_VIBE_ON - 1] = 1;
        alerts = new AlertPolicy();
        alerts.update(0, Protocol.TURN_LEFT, 60.0, 10.0);
        Test.assertEqualMessage(alerts.alerts, 1, "the alert with vibration on");
        Test.assertEqualMessage(alerts.motorCalls, expect, "and the motor is called");

        Config.values[Config.KEY_VIBE_ON - 1] = vibe;
        return true;
    }
}
