import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Test;

//! F3a tests: local ETA, arrival, vibration policy and the corridor's cut by
//! rectangle.
//!
//! Everything here is pure logic, exercisable without GPS, without a phone and without a screen — which is
//! precisely what can be proven before getting on the bike. What **cannot**
//! be proven here (is the arrow legible? does the warning arrive in time at 80 km/h?) is
//! on the look-at list in `STATUS.md`, not faked as a test.

(:test)
module F3Assert {

    //! Straight route to the north, 100 m per point, with maneuvers where asked.
    function routeWithTurns(points as Number, turns as Array<Number>) as RouteModel {
        var route = NavAssert.straightRoute(points);
        var types = new [turns.size()] as Array<Number>;
        var names = new [turns.size()] as Array<String>;
        var exits = new [turns.size()] as Array<Number>;
        for (var i = 0; i < turns.size(); i++) {
            types[i] = Protocol.TURN_RIGHT;
            names[i] = "Rua " + i.toString();
            exits[i] = 0;
        }
        route.turnPointIdx = turns;
        route.turnType = types;
        route.turnName = names;
        route.turnExit = exits;
        return route;
    }
}

//! Distance as the rider reads it: close becomes "AGORA" (NOW) because there is nothing left to
//! anticipate, and the middle ground rounds by 10 — the units digit changes
//! on every reading and tells nothing.
(:test)
function distanceReadsLikeTheRiderNeeds(logger as Logger) as Boolean {
    Test.assertEqualMessage(NavEngine.formatDistance(8.0), "AGORA", "right at the turn");
    Test.assertEqualMessage(NavEngine.formatDistance(347.0), "340 m", "rounds down in steps of 10");
    // The decimal separator and the rounding of `.format` come from the **watch**,
    // not from here: on the Venu 4 in Portuguese it gives "1,3 km" and on the simulator "1.3".
    // Fixing the comma would be testing the build machine's locale. What is ours is
    // where the unit becomes kilometers and that exactly one decimal place remains — that is what
    // the test asserts.
    Test.assertEqualMessage(NavEngine.formatDistance(999.0), "990 m", "below 1 km it is still meters");

    var km = NavEngine.formatDistance(1280.0);
    Test.assertEqualMessage(km.substring(km.length() - 3, km.length()), " km", "becomes kilometers at 1,000 m");
    Test.assertEqualMessage(km.length(), 6, "one digit, separator, one decimal place and the suffix: " + km);
    return true;
}

//! The time left, as the C4 mockup writes it: `22 min`, `1 h 34 min`.
//! The same numbers that `format_time` in `tools/design_tokens.py` uses
//! (94 min = `1 h 34 min`, 22 min = `22 min`).
(:test)
function formatDurationReadsLikeTheMockup(logger as Logger) as Boolean {
    Test.assertEqualMessage(NavEngine.formatDuration(22 * 60), "22 min", "below 1 h");
    Test.assertEqualMessage(NavEngine.formatDuration(94 * 60), "1 h 34 min", "with hour and minute");
    Test.assertEqualMessage(NavEngine.formatDuration(120 * 60), "2 h", "a full hour has no minutes");
    Test.assertEqualMessage(NavEngine.formatDuration(65 * 60), "1 h 05 min", "minute with a leading zero");
    Test.assertEqualMessage(NavEngine.formatDuration(20), "1 min", "never 0 min with route ahead");
    Test.assertEqualMessage(NavEngine.formatDuration(89), "1 min", "rounds to the nearest minute");
    return true;
}

//! The arrival delta (C16.5): always signed, only hours and minutes rounded like the time
//! left, and nothing below 30 s on either side.
// prevents: the delta flickering "+0:01" with one second of estimate noise, or coming out unsigned and the
// rider reading slack as delay (Igor's request in C16: red when it worsens, green when it improves);
// and the seconds that Igor found too much on 2026-10-17 ("+14:26" instead of "+14 min").
(:test)
function arrivalDeltaReadsWithSignAndHidesNoise(logger as Logger) as Boolean {
    Test.assertEqualMessage(NavEngine.formatDelta(0), "", "on plan");
    Test.assertEqualMessage(NavEngine.formatDelta(29), "", "below 30 s it does not show");
    Test.assertEqualMessage(NavEngine.formatDelta(-29), "", "nor ahead");
    Test.assertEqualMessage(NavEngine.formatDelta(30), "+1 min", "from 30 s on, already a minute");
    Test.assertEqualMessage(NavEngine.formatDelta(-45), "-1 min", "ahead takes less");
    Test.assertEqualMessage(NavEngine.formatDelta(200), "+3 min", "without the seconds");
    Test.assertEqualMessage(NavEngine.formatDelta(866), "+14 min", "the +14:26 from the photo");
    Test.assertEqualMessage(NavEngine.formatDelta(-90), "-2 min", "rounds to the nearest minute");
    Test.assertEqualMessage(NavEngine.formatDelta(4500), "+1 h 15 min", "with hour");
    return true;
}

//! The planned arrival is the one from the start of the trip: the recalculation (route end less than
//! 150 m from the previous) keeps it; a new destination and an ended route reset it; the
//! first estimate sets the plan.
// prevents: the delta resetting on every recalculation (C11 swaps the whole route) and hiding the detour delay,
// or inheriting the previous trip's plan and opening the new route already at "+40:00".
(:test)
function arrivalPlanSurvivesRerouteAndResetsOnNewDestination(logger as Logger) as Boolean {
    var nav = new NavState();
    nav.beginTrip(-2356145, -4665432);
    Test.assertEqualMessage(nav.arrivalDelta(1000, 1800), 0, "the 1st estimate sets the plan");
    Test.assertEqualMessage(nav.arrivalDelta(1300, 1700), 200, "ran 200 s late");

    // Recalculation: the route end 50 m to the north (45 units of 1e-5 degree).
    nav.beginTrip(-2356100, -4665432);
    Test.assertEqualMessage(nav.arrivalDelta(1400, 1500), 100, "the recalculation keeps the plan");

    // New destination, 2 km from there.
    nav.beginTrip(-2338145, -4665432);
    Test.assertEqualMessage(nav.arrivalDelta(2000, 600), 0, "a new destination sets the plan again");
    Test.assertEqualMessage(nav.arrivalDelta(2100, 400), -100, "and it moves ahead against it");

    // Ended and reopened for the same destination: new trip.
    nav.endTrip();
    nav.beginTrip(-2338145, -4665432);
    Test.assertEqualMessage(nav.arrivalDelta(5000, 600), 0, "ended route resets the plan");
    return true;
}

//! The delta reaches the screen: with the plan 1 h 34 min before the estimate of now, the bottom
//! card writes `+1 h 34 min`, the widest delta that fits in the `BurnInTest` math.
// prevents: the math existing and the Hud not drawing it (the delta only shows on the stacked card).
(:test)
function arrivalDeltaReachesTheTimeCard(logger as Logger) as Boolean {
    var scene = BurnInAssert.scene(1);
    var hud = new Hud();
    hud.draw(Rnf05Assert.canvas(BurnInAssert.SIZE), scene.route, scene.nav, scene.matcher);
    logger.debug("delta on screen: " + hud.deltaShown);
    Test.assertEqualMessage(hud.deltaShown, "+1 h 34 min", "the card wrote '" + hud.deltaShown + "'");

    var fresh = BurnInAssert.scene(1);
    fresh.nav.plannedArrivalS = -1;
    hud.draw(Rnf05Assert.canvas(BurnInAssert.SIZE), fresh.route, fresh.nav, fresh.matcher);
    Test.assertEqualMessage(hud.deltaShown, "", "with no plan, the 1st estimate sets it and there is no delta");
    BurnInAssert.done();
    return true;
}

//! The distance in two pieces, so the number gets bigger than the unit.
(:test)
function distancePartsSplitNumberAndUnit(logger as Logger) as Boolean {
    var near = NavEngine.distanceParts(45.0);
    Test.assertEqualMessage(near[0], "40", "number");
    Test.assertEqualMessage(near[1], "m", "unit");
    var now = NavEngine.distanceParts(8.0);
    Test.assertEqualMessage(now[0], "AGORA", "right at the turn");
    Test.assertEqualMessage(now[1], "", "NOW has no unit");
    var far = NavEngine.distanceParts(1280.0);
    Test.assertEqualMessage(far[1], "km", "becomes kilometers");
    return true;
}

//! The ETA is the average of two estimates wrong in different ways. With no useful moving
//! average, only the API's counts.
(:test)
function etaFallsBackToTheApiWhenThereIsNoUsefulAverage(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(11); // 1,000 m
    route.durationS = 600; // 10 min for the whole route
    var matcher = new MapMatcher(route);
    var nav = new NavState();

    matcher.update(0.0, 500.0); // half
    Test.assertMessage(NavAssert.near(matcher.remainingM(), 500.0, 0.1), "half remaining");

    // Stopped: the moving average says nothing, so the ETA is the API's.
    Test.assertEqualMessage(NavEngine.remainingSeconds(route, matcher, nav), 300, "half of the API duration");
    return true;
}

//! The bike of the arrival time tests: goes north on a straight route, one
//! fix per second, with the fix clock in the test's hands.
(:test)
class TripRider {
    var nav as NavState;
    var matcher as MapMatcher;
    var y as Float = 0.0;
    var ms as Number = 0;

    function initialize(route as RouteModel) {
        nav = new NavState();
        matcher = new MapMatcher(route);
    }

    function fix(x as Float, speed as Float) as Void {
        ms += 1000;
        nav.applyFix(x, y, speed, null);
        nav.tickTrip(ms);
        matcher.update(x, y);
    }

    function ride(speed as Float, seconds as Number) as Void {
        for (var i = 0; i < seconds; i++) {
            y += speed;
            fix(0.0, speed);
        }
    }

    //! Stopped, with the GPS wandering 3 m to each side, as on the wrist.
    function stop(seconds as Number) as Void {
        for (var i = 0; i < seconds; i++) {
            fix(i % 2 == 0 ? 3.0 : -3.0, 0.3);
        }
    }

    function eta(route as RouteModel) as Number {
        return NavEngine.remainingSeconds(route, matcher, nav);
    }
}

//! Past the launch, the two estimates enter half and half: the API's and the
//! trip's average speed.
(:test)
function etaBlendsTheApiWithHowFastYouAreActuallyGoing(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(101); // 10 km
    route.durationS = 2000; // the API counts on 5 m/s
    var rider = new TripRider(route);

    rider.ride(10.0, 700); // 7 km at 10 m/s, past the ramp's 10 min
    Test.assertMessage(NavAssert.near(rider.nav.tripSpeedMps, 10.0, 0.1),
        "the trip average: " + rider.nav.tripSpeedMps.toString());
    Test.assertEqualMessage(rider.nav.tripWeight, 1.0, "full weight after the ramp");

    // 3 km remaining: 600 s by the API, 300 s by the average, 450 s in the average of the two.
    var eta = rider.eta(route);
    Test.assertMessage(eta > 440 && eta < 460, "average of the two, not one of them: " + eta.toString());
    return true;
}

//! **A slow start does not inflate the arrival time** (on an October ride, the trip
//! began at 23 km/h and the remainder was born at 4750 s, with Mapbox saying 2736).
//! In the first 2 minutes only the API counts; then, the trip average enters
//! gradually, with no step, and the start weighs by how long it lasted.
// prevents: the first slow sample becoming the average and the ETA dropping 45 min in 4 min.
(:test)
function aSlowStartDoesNotInflateTheEta(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(101); // 10 km
    route.durationS = 1200;
    var rider = new TripRider(route);

    for (var i = 0; i < 120; i++) {
        rider.ride(2.5, 1); // 9 km/h, the slow start
        var byApi = (route.durationS * (rider.matcher.remainingM() / route.lengthM())).toNumber();
        Test.assertEqualMessage(rider.eta(route), byApi, "only the API at second " + i.toString());
    }

    // 4 min at 54 km/h: the trip average enters with no step (without the ramp, the
    // first fix after the 2 min jumped from ~1200 s to ~2600 s).
    var last = rider.eta(route);
    for (var i = 0; i < 240; i++) {
        rider.ride(15.0, 1);
        var now = rider.eta(route);
        var step = now - last;
        Test.assertMessage(step > -15 && step < 15, "no step at second " + i.toString()
            + ": " + last.toString() + " -> " + now.toString());
        last = now;
    }
    // 297.5 m of start + 3600 m of the avenue in 359 s: 10.9 m/s, far from the start's 2.5.
    var speed = rider.nav.tripSpeedMps;
    Test.assertMessage(speed > 10.5 && speed < 11.2, "the output diluted over its time: " + speed.toString());
    return true;
}

//! **A stop at a traffic light does not freeze the remainder.** With stops counted, the
//! stopped time lowers the trip average and the remainder grows slowly; and the GPS
//! wandering idly with the bike stopped does not add kilometers.
// prevents: the remainder stuck at the traffic light for 3 min on an October ride, at 1066 s.
(:test)
function aStopAtALightKeepsTheEtaMoving(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(201); // 20 km
    route.durationS = 2000;
    var rider = new TripRider(route);

    rider.ride(10.0, 700); // after the ramp, with the whole trip's average counted
    var moved = rider.nav.tripMovedM;
    var before = rider.eta(route); // 13 km: 1300 s by both sides
    Test.assertMessage(before > 1290 && before < 1310, "moving: " + before.toString());

    var last = before;
    for (var i = 0; i < 6; i++) {
        rider.stop(10);
        var now = rider.eta(route);
        Test.assertMessage(now >= last, "stopped, the remainder does not go back: " + now.toString());
        last = now;
    }
    Test.assertMessage(NavAssert.near(rider.nav.tripMovedM, moved, 0.1),
        "a stopped GPS does not move: " + rider.nav.tripMovedM.toString());
    // 6990 m in 759 s: 9.2 m/s, 1412 s by the average, 1356 s in the average of the two.
    Test.assertMessage(last > before + 40 && last < before + 70,
        "1 min stopped weighs on the remainder: " + before.toString() + " -> " + last.toString());
    return true;
}

//! The GPS jump does not become kilometers, the recalculation (which swaps the local plane via
//! [NavState.rebase]) does not reset the average, and [NavState.invalidateFix] does.
(:test)
function theTripOdometerSkipsJumpsAndSurvivesTheReroute(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(101);
    var rider = new TripRider(route);
    rider.ride(10.0, 150);
    var moved = rider.nav.tripMovedM;

    // A fix 5 km from there, and back: both legs stay out.
    rider.y += 5000.0;
    rider.fix(0.0, 10.0);
    rider.y -= 4990.0;
    rider.fix(0.0, 10.0);
    Test.assertMessage(NavAssert.near(rider.nav.tripMovedM, moved, 0.1),
        "jump discarded: " + rider.nav.tripMovedM.toString());

    // Recalculation: the same point, in the plane of another route.
    rider.nav.rebase(500.0, 500.0);
    rider.ms += 1000;
    rider.nav.applyFix(500.0, 510.0, 10.0, null);
    rider.nav.tickTrip(rider.ms);
    Test.assertMessage(NavAssert.near(rider.nav.tripMovedM, moved + 10.0, 0.1),
        "10 m on the new plan: " + rider.nav.tripMovedM.toString());
    Test.assertMessage(rider.nav.tripSpeedMps > 2.0, "the average stayed");

    rider.nav.invalidateFix();
    Test.assertEqualMessage(rider.nav.tripMovedM, 0.0, "new route, odometer reset");
    Test.assertEqualMessage(rider.nav.tripSpeedMps, 0.0, "and the average too");
    Test.assertEqualMessage(rider.nav.tripWeight, 0.0, "and its weight");
    return true;
}

//! Arrival requires matching the route: without it, `remainingM()` is the remainder of a
//! progress that was not measured on this route.
(:test)
function arrivalNeedsBothProximityAndAMatch(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(11);
    var matcher = new MapMatcher(route);

    Test.assertMessage(!NavEngine.hasArrived(matcher), "with no match it has not arrived");

    matcher.update(0.0, 500.0);
    Test.assertMessage(!NavEngine.hasArrived(matcher), "halfway it has not arrived");

    matcher.update(0.0, 985.0); // 15 m from the end
    Test.assertMessage(NavEngine.hasArrived(matcher), "within 30 m it arrived");
    return true;
}

//! prevents: the "Você chegou" (You have arrived) with the bike stopped ~400 m from Copan (launch session, 26/10).
//! A fix far from everything matches the last segment with `remainingM()` 0, and the `ARRIVED` phase
//! gets stuck: a single fix ended navigation, before `OffRoute` (>40 m for >5 s) could see.
(:test)
function arrivalIgnoresAMatchFarFromTheRoute(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(11); // 1000 m to the north

    var far = new MapMatcher(route);
    far.update(400.0, 1000.0); // 400 m beside the end
    Test.assertMessage(far.matched, "it matched anyway");
    Test.assertEqualMessage(far.remainingM(), 0.0, "at the last point");
    Test.assertMessage(!NavEngine.hasArrived(far), "400 m from the route it has not arrived");

    var beside = new MapMatcher(route);
    beside.update(35.0, 990.0); // on the sidewalk on the other side, 10 m before the end
    Test.assertMessage(NavEngine.hasArrived(beside), "35 m from the route, within the OffRoute threshold, it arrived");
    return true;
}

//! Proportional lead: at 100 km/h, a fixed 80 m would arrive with less than 3 s
//! to spare — the warning would come together with the turn.
(:test)
function alertLeadGrowsWithSpeed(logger as Logger) as Boolean {
    var policy = new AlertPolicy();

    Test.assertMessage(NavAssert.near(policy.leadDistance(2.0), 80.0, 0.1),
        "slow, the 80 m floor applies");
    Test.assertMessage(NavAssert.near(policy.leadDistance(28.0), 224.0, 0.1),
        "100 km/h = 8 s of lead = 224 m");
    return true;
}

//! At most two warnings per maneuver, and the next maneuver restarts the count.
(:test)
function atMostTwoAlertsPerTurn(logger as Logger) as Boolean {
    var policy = new AlertPolicy();

    // Approach from 300 m to 5 m, at 15 m/s (lead = 120 m).
    for (var d = 300; d > 0; d -= 5) {
        policy.update(0, Protocol.TURN_RIGHT, d.toFloat(), 15.0);
    }
    Test.assertEqualMessage(policy.alerts, 2, "one alert far and one close, and that is all");

    // Next maneuver: the count restarts.
    for (var d = 300; d > 0; d -= 5) {
        policy.update(1, Protocol.TURN_LEFT, d.toFloat(), 15.0);
    }
    Test.assertEqualMessage(policy.alerts, 4, "two more at the next maneuver");
    return true;
}

//! Matching with a noisy GPS crosses a turn's point back and forth:
//! a maneuver that becomes the "next" again through one fix must not be warned about again
//! (C3b, noisy 15 m track).
(:test)
function aTurnThatFlickersBackIsNotAlertedAgain(logger as Logger) as Boolean {
    var policy = new AlertPolicy();

    policy.update(6, Protocol.TURN_SLIGHT_LEFT, 60.0, 15.0);
    policy.update(6, Protocol.TURN_SLIGHT_LEFT, 20.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 2, "maneuver 6 was alerted twice");

    // Past the 6th: the 7th is the next and is warned.
    policy.update(7, Protocol.TURN_LEFT, 70.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 3, "1st alert of 7");

    // The noisy fix goes back to before the 6th, and then to the 7th again.
    policy.update(6, Protocol.TURN_SLIGHT_LEFT, 9.0, 15.0);
    policy.update(6, Protocol.TURN_SLIGHT_LEFT, 60.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 3, "6 is not alerted again");
    policy.update(7, Protocol.TURN_LEFT, 20.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 4, "7 resumes where it stopped: only the 2nd alert");
    policy.update(7, Protocol.TURN_LEFT, 15.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 4, "and never goes past two");

    // New route: the count restarts from zero.
    policy.reset();
    policy.update(0, Protocol.TURN_RIGHT, 60.0, 15.0);
    Test.assertEqualMessage(policy.alerts, 1, "the reset frees the low index");
    return true;
}

//! Slowly, the second warning does not go out: stopped or nearly, the corner is already in sight
//! and the extra pulse only spends attention.
(:test)
function theSecondAlertIsSkippedWhenCrawling(logger as Logger) as Boolean {
    var policy = new AlertPolicy();
    for (var d = 300; d > 0; d -= 5) {
        policy.update(0, Protocol.TURN_RIGHT, d.toFloat(), 2.0);
    }
    Test.assertEqualMessage(policy.alerts, 1, "only the far alert");
    return true;
}

//! Arrival, "keep straight" and departure do not vibrate like a turn: arrival has its
//! own pattern, and straight is not a turn (Igor's decisions, DECISIONS §C3a).
(:test)
function silentManeuversDoNotVibrate(logger as Logger) as Boolean {
    var policy = new AlertPolicy();
    // prevents: the arrival with the destination side (19 and 20, C16.5) vibrating like a turn before the
    // arrival pattern.
    var silent = [Protocol.TURN_ARRIVE, Protocol.TURN_STRAIGHT, Protocol.TURN_NEW_NAME, Protocol.TURN_DEPART,
        Protocol.TURN_ARRIVE_LEFT, Protocol.TURN_ARRIVE_RIGHT] as Array<Number>;
    for (var i = 0; i < silent.size(); i++) {
        for (var d = 300; d > 0; d -= 5) {
            policy.update(i, silent[i], d.toFloat(), 15.0);
        }
    }
    Test.assertEqualMessage(policy.alerts, 0, "no turn alert");
    return true;
}

//! Tight turn: if the 1st warning already went out within 25 m, it is the "close" warning and
//! no other comes on the next fix, with the first still vibrating.
(:test)
function aGluedTurnGetsOneAlert(logger as Logger) as Boolean {
    var policy = new AlertPolicy();
    for (var d = 20; d > 0; d -= 5) {
        policy.update(0, Protocol.TURN_SLIGHT_LEFT, d.toFloat(), 10.0);
    }
    Test.assertEqualMessage(policy.alerts, 1, "a single alert");
    return true;
}

//! Left and right are told apart by **pulse count**, which is what
//! can still be counted inside the glove.
(:test)
function leftAndRightVibrateDifferently(logger as Logger) as Boolean {
    var policy = new AlertPolicy();

    Test.assertEqualMessage(policy.patternFor(Protocol.TURN_LEFT).size(), 3, "2 pulses + 1 pause");
    Test.assertEqualMessage(policy.patternFor(Protocol.TURN_RIGHT).size(), 5, "3 pulses + 2 pauses");
    Test.assertEqualMessage(policy.patternFor(Protocol.TURN_STRAIGHT).size(), 1, "a single long pulse");
    // prevents: the fork losing the side count. Until C16.5 it arrived as slight
    // left/right (2 and 3 pulses); with its own type it would fall to the long pulse.
    Test.assertEqualMessage(policy.patternFor(Protocol.TURN_FORK_LEFT).size(), 3, "fork left: 2 pulses");
    Test.assertEqualMessage(policy.patternFor(Protocol.TURN_FORK_RIGHT).size(), 5, "fork right: 3 pulses");
    return true;
}

//! The bounding rectangle of each way is what makes the corridor drawable.
(:test)
function corridorWayBoxesWrapEachWay(logger as Logger) as Boolean {
    var xs = [0.0, 10.0, 5.0, 100.0, 120.0] as Array<Float>;
    var ys = [0.0, -4.0, 8.0, 50.0, 40.0] as Array<Float>;
    var starts = [0, 3, 5] as Array<Number>;

    var boxes = CorridorModel.boxesOf(xs, ys, starts);

    Test.assertEqualMessage(boxes.size(), 8, "four floats per way");
    Test.assertMessage(NavAssert.near(boxes[0] as Float, 0.0, 0.001), "minX of way 0");
    Test.assertMessage(NavAssert.near(boxes[1] as Float, 10.0, 0.001), "maxX of way 0");
    Test.assertMessage(NavAssert.near(boxes[2] as Float, -4.0, 0.001), "minY of way 0");
    Test.assertMessage(NavAssert.near(boxes[3] as Float, 8.0, 0.001), "maxY of way 0");
    Test.assertMessage(NavAssert.near(boxes[4] as Float, 100.0, 0.001), "minX of way 1");
    Test.assertMessage(NavAssert.near(boxes[7] as Float, 50.0, 0.001), "maxY of way 1");
    return true;
}

//! **The test that was always missing: actually drawing.**
//!
//! All the render tests so far checked *math* — the transform, the
//! cut, the ranges. None called `MapRenderer.draw`, and so none
//! would have caught an exception inside the drawing loop. And that is exactly what
//! happened twice in a row on the street: the watch received the route, went mute,
//! and the corridor arrived at an app that no longer existed.
//!
//! A 454×454 `BufferedBitmap` gives a real `Dc`, so this test walks the
//! whole path — corridor, traveled route, route ahead, arrow, HUD — with
//! **a route the size of real ones** (800 points, which is what Igor's log
//! shows) and a corridor of hundreds of ways.
(:test)
function drawingARealSizedRouteDoesNotBlowUp(logger as Logger) as Boolean {
    if (!(Graphics has :createBufferedBitmap)) {
        return true;
    }
    var buffer = Graphics.createBufferedBitmap({ :width => 454, :height => 454 });
    var dc = buffer.get().getDc();

    var route = NavAssert.straightRoute(800);
    route.turnPointIdx = [10, 120, 400, 799] as Array<Number>;
    route.turnType = [
        Protocol.TURN_RIGHT, Protocol.TURN_ROUNDABOUT, Protocol.TURN_LEFT, Protocol.TURN_ARRIVE
    ] as Array<Number>;
    route.turnExit = [0, 3, 0, 0] as Array<Number>;
    route.turnName = ["Rua A", "Rotatória", "Avenida Muito Comprida Que Não Cabe", ""] as Array<String>;
    route.durationS = 2340;

    // Corridor with 300 ways of 4 points, spread along the route.
    var xs = [] as Array<Float>;
    var ys = [] as Array<Float>;
    var starts = [] as Array<Number>;
    for (var w = 0; w < 300; w++) {
        starts.add(xs.size());
        for (var p = 0; p < 4; p++) {
            xs.add((-200 + p * 100).toFloat());
            ys.add((w * 260 + p * 30).toFloat());
        }
    }
    starts.add(xs.size());

    var corridor = new CorridorModel();
    for (var lod = 0; lod < Protocol.CORRIDOR_LOD_COUNT; lod++) {
        corridor.setLod(lod, xs, ys, starts);
    }

    var nav = new NavState();
    var matcher = new MapMatcher(route);
    var map = new MapRenderer();
    var hud = new Hud();

    // Three situations the street produces and that the math tests did not cover:
    // no fix (indoors), matched mid-route, and at its end.
    map.draw(dc, route, nav, matcher, corridor);
    hud.draw(dc, route, nav, matcher);

    nav.applyFix(0.0, 40000.0, 18.0, 1.2);
    matcher.update(0.0, 40000.0);
    map.draw(dc, route, nav, matcher, corridor);
    hud.draw(dc, route, nav, matcher);

    nav.applyFix(0.0, 79900.0, 2.0, 0.3);
    matcher.update(0.0, 79900.0);
    nav.phase = NavPhase.ARRIVED;
    map.draw(dc, route, nav, matcher, corridor);
    hud.draw(dc, route, nav, matcher);

    Test.assertMessage(map.segmentsDrawn >= 0, "drew without blowing up");
    return true;
}

//! The same path, now **at the edges**: a two-point route, an empty
//! corridor, and the route changing size under the range cache — which is the
//! case that an index kept between frames may not survive.
(:test)
function drawingSurvivesDegenerateRoutes(logger as Logger) as Boolean {
    if (!(Graphics has :createBufferedBitmap)) {
        return true;
    }
    var buffer = Graphics.createBufferedBitmap({ :width => 454, :height => 454 });
    var dc = buffer.get().getDc();

    var nav = new NavState();
    var map = new MapRenderer();
    var hud = new Hud();
    var empty = new CorridorModel();

    var tiny = NavAssert.straightRoute(2);
    var tinyMatcher = new MapMatcher(tiny);
    map.draw(dc, tiny, nav, tinyMatcher, empty);
    hud.draw(dc, tiny, nav, tinyMatcher);

    // Long route drawn, and then a short one on the **same** renderer: if the
    // range cache does not react to the new size, the stored indices
    // point outside the new route's array.
    var big = NavAssert.straightRoute(500);
    var bigMatcher = new MapMatcher(big);
    nav.applyFix(0.0, 20000.0, 15.0, 0.0);
    bigMatcher.update(0.0, 20000.0);
    map.draw(dc, big, nav, bigMatcher, empty);

    var small = NavAssert.straightRoute(30);
    var smallMatcher = new MapMatcher(small);
    smallMatcher.update(0.0, 1000.0);
    map.draw(dc, small, nav, smallMatcher, empty);
    hud.draw(dc, small, nav, smallMatcher);

    Test.assertMessage(true, "none of the degenerate cases blew up");
    return true;
}

//! **The cache test that saved the app from closing.** Walking every way on
//! each frame cost 106 ms measured on the Venu 4 and blew the watchdog when the
//! corridor arrived. The visible list started being reused between frames
//! — and a cache that does not invalidate at the right time draws old streets or drops new
//! ones, which is worse than the original problem. These are the three triggers.
(:test)
function visibleWayCacheRefreshesOnlyWhenItMust(logger as Logger) as Boolean {
    var corridor = new CorridorModel();
    // Three ways: one on top of the center, one at 300 m and one at 50 km.
    corridor.setLod(
        Protocol.LOD_ARTERIAL,
        [0.0, 10.0, 300.0, 310.0, 50000.0, 50010.0] as Array<Float>,
        [0.0, 10.0, 0.0, 10.0, 0.0, 10.0] as Array<Float>,
        [0, 2, 4, 6] as Array<Number>
    );

    var map = new MapRenderer();
    var nav = new NavState();
    nav.metersPerPx = 1.2; // cut radius ~539 m
    map.begin(nav);
    map.refreshVisible(corridor);
    Test.assertEqualMessage(map.visibleWays(), 2, "the two nearby are in, the 50 km one is not");

    // Moving a little does **not** rebuild the list: that is precisely the saving.
    nav.seedCentre(10.0, 0.0);
    map.begin(nav);
    map.refreshVisible(corridor);
    Test.assertEqualMessage(map.visibleWays(), 2, "10 m do not trigger a recalculation");

    // Changing the scale rebuilds: the cut radius is different.
    nav.metersPerPx = 0.1; // radius ~45 m
    map.begin(nav);
    map.refreshVisible(corridor);
    Test.assertEqualMessage(map.visibleWays(), 1, "zooming in, only the one on top of the rider");

    // A new corridor rebuilds, even stopped and at the same scale.
    corridor.setLod(
        Protocol.LOD_ARTERIAL,
        [0.0, 10.0] as Array<Float>,
        [0.0, 10.0] as Array<Float>,
        [0, 2] as Array<Number>
    );
    map.refreshVisible(corridor);
    Test.assertEqualMessage(map.visibleWays(), 1, "the corridor revision invalidates the cache");
    return true;
}

//! The cut margin has to be greater than how far the map moves between two
//! recalculations — otherwise a street enters the screen before the cache is rebuilt and
//! shows up late, which is the same as showing up wrong.
(:test)
function cullMarginCoversTheCacheDrift(logger as Logger) as Boolean {
    var map = new MapRenderer();
    var slack = map.CORNER_PX * (map.CULL_MARGIN - 1.0);

    Test.assertMessage(slack > map.CACHE_REBUILD_M,
        "slack of " + slack.format("%.0f") + " px-scale vs " + map.CACHE_REBUILD_M.format("%.0f") + " m");
    return true;
}

//! And the rectangle cut has to agree with the point cut: a far way
//! dies in four comparisons, one touching the view survives.
(:test)
function farAwayWaysAreCulledByTheirBox(logger as Logger) as Boolean {
    var map = new MapRenderer();
    var nav = new NavState();
    nav.metersPerPx = 1.2;
    map.begin(nav); // center at (0, 0)

    Test.assertMessage(map.boxVisible(-50.0, 50.0, -50.0, 50.0), "on top of the rider, visible");
    Test.assertMessage(!map.boxVisible(50000.0, 50100.0, 0.0, 10.0), "50 km east, culled");
    Test.assertMessage(!map.boxVisible(-100.0, 100.0, 50000.0, 50100.0), "50 km north, culled");

    // A huge way crossing the view must not be cut by the rectangle.
    Test.assertMessage(map.boxVisible(-50000.0, 50000.0, -10.0, 10.0), "crosses the center, visible");
    return true;
}
