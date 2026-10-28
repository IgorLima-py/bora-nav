import Toybox.Lang;
import Toybox.Test;

//! Helper for the off-route tests (C11): one fix per second, like the GPS.
(:test)
module OffRouteAssert {

    //! A detector already **armed**: a fix on top of the route at instant `atMs`.
    function armed(atMs as Number) as OffRoute {
        var off = new OffRoute();
        off.update(atMs, 0.0, 0.0, false);
        return off;
    }

    //! `seconds + 1` fixes at `crossM` from the route, one per second, from `fromMs`
    //! on: the first opens the count and the last is `seconds` s later.
    //! Returns `true` if any of them fired the off-route.
    function ride(off as OffRoute, fromMs as Number, seconds as Number, crossM as Float) as Boolean {
        var fired = false;
        for (var s = 0; s <= seconds; s++) {
            if (off.update(fromMs + s * 1000, crossM, 0.0, false) == OffRoute.EVENT_TRIGGERED) {
                fired = true;
            }
        }
        return fired;
    }
}

//! RF-11: more than 40 m. At 39 m the rider is on the next lane, not off the route.
(:test)
function thirtyNineMetersForSixSecondsDoesNotTrigger(logger as Logger) as Boolean {
    var off = OffRouteAssert.armed(0);

    Test.assertMessage(!OffRouteAssert.ride(off, 1000, 6, 39.0), "39 m for 6 s does not trigger");
    Test.assertEqualMessage(off.state, OffRoute.ON_ROUTE, "and the state stays on route");
    return true;
}

//! RF-11: more than 40 m for more than 5 s.
(:test)
function fortyOneMetersForSixSecondsTriggers(logger as Logger) as Boolean {
    var off = OffRouteAssert.armed(0);

    Test.assertMessage(OffRouteAssert.ride(off, 1000, 6, 41.0), "41 m for 6 s triggers");
    Test.assertEqualMessage(off.state, OffRoute.REQUESTED, "and the request went out");
    return true;
}

//! RF-11: 5 s is what separates a detour from a fix that jumped.
(:test)
function fortyOneMetersForFourSecondsDoesNotTrigger(logger as Logger) as Boolean {
    var off = OffRouteAssert.armed(0);

    Test.assertMessage(!OffRouteAssert.ride(off, 1000, 4, 41.0), "41 m for 4 s does not trigger");
    // Back on the route, the count restarts from zero: 4 s + 4 s are not 8 s.
    off.update(6000, 0.0, 0.0, false);
    Test.assertMessage(!OffRouteAssert.ride(off, 7000, 4, 41.0), "two 4 s stretches do not add up");
    Test.assertEqualMessage(off.state, OffRoute.ON_ROUTE, "on route");
    return true;
}

//! The start: the rider leaves home hundreds of meters from the start of the route. That
//! is normal and **not** a detour. Without the arming rule, every start would become a
//! recalculation request in a loop (finding from the second opinion, C11).
(:test)
function startingFarFromTheRouteOnlyTriggersWhenMovingAway(logger as Logger) as Boolean {
    var off = new OffRoute();

    // Approaching: 300 m, 290 m, ... 50 m, one fix per second.
    var t = 0;
    for (var cross = 300.0; cross >= 50.0; cross -= 10.0) {
        Test.assertEqualMessage(
            off.update(t, cross, 0.0, false), OffRoute.EVENT_NONE, "approaching does not trigger");
        t += 1000;
    }
    Test.assertMessage(!off.armed, "has not touched the route yet");

    // Stopped at 50 m for half a minute: still not a detour.
    Test.assertMessage(!OffRouteAssert.ride(off, t, 30, 50.0), "stopped far away does not trigger");
    t += 31000;

    // Moving away: only starts counting above the minimum seen + 40 m (50 + 40 = 90).
    Test.assertMessage(!OffRouteAssert.ride(off, t, 8, 89.0), "89 m is still within the slack");
    t += 9000;
    Test.assertMessage(OffRouteAssert.ride(off, t, 6, 91.0), "91 m for 6 s is leaving the route");

    // And whoever touched the route is judged by the usual threshold.
    var later = new OffRoute();
    later.update(0, 200.0, 0.0, false);
    later.update(1000, 12.0, 0.0, false);
    Test.assertMessage(later.armed, "armed on touching");
    Test.assertMessage(OffRouteAssert.ride(later, 2000, 6, 41.0), "armed, 41 m for 6 s triggers");
    return true;
}

//! "Continuous" means fix by fix. Two fixes at 41 m with an 8 s tunnel in the
//! middle do not prove 5 s off the route: they prove two instants.
(:test)
function aGapLongerThanTheWindowRestartsTheCount(logger as Logger) as Boolean {
    var off = OffRouteAssert.armed(0);

    off.update(1000, 41.0, 0.0, false);
    Test.assertEqualMessage(
        off.update(9000, 41.0, 0.0, false), OffRoute.EVENT_NONE, "an 8 s gap does not count");
    Test.assertMessage(!OffRouteAssert.ride(off, 10000, 3, 41.0), "the count restarted at the 2nd fix");
    Test.assertMessage(OffRouteAssert.ride(off, 14000, 2, 41.0), "and closes 5 s after it");
    return true;
}

//! The request carries the progress of the **last fix on the route**. Far from it, the
//! map-matching may match a stretch ahead, and the phone would discard a
//! stop that nobody visited (`05 §REROUTE_REQ`).
(:test)
function theRequestCarriesTheProgressOfTheLastFixOnTheRoute(logger as Logger) as Boolean {
    var off = new OffRoute();
    off.update(0, 5.0, 1200.0, false);
    off.update(1000, 38.0, 1215.0, false);

    // Off the route the matching jumps 9 km ahead.
    for (var s = 2; s <= 8; s++) {
        off.update(s * 1000, 150.0, 9000.0, false);
    }

    Test.assertEqualMessage(off.state, OffRoute.REQUESTED, "triggered");
    Test.assertMessage(NavAssert.near(off.lastOnRouteM, 1215.0, 0.01), "the progress is the one from before the detour");

    var never = new OffRoute();
    never.update(0, 500.0, 7000.0, false);
    Test.assertMessage(NavAssert.near(never.lastOnRouteM, 0.0, 0.01), "one who was never on the route sends 0");
    return true;
}

//! ADR-4: one request every 20 s. RF-11: 10 s without the new route is "no phone".
//! And the new route starting to arrive cancels both things.
(:test)
function theRequestRepeatsEveryTwentySecondsAndGivesUpOnThePhoneAfterTen(logger as Logger) as Boolean {
    var off = OffRouteAssert.armed(0);
    OffRouteAssert.ride(off, 1000, 6, 60.0);
    Test.assertEqualMessage(off.state, OffRoute.REQUESTED, "request at 7 s");

    Test.assertEqualMessage(off.update(16000, 60.0, 0.0, false), OffRoute.EVENT_NONE, "9 s later it still waits");
    Test.assertEqualMessage(off.update(17000, 60.0, 0.0, false), OffRoute.EVENT_NO_PHONE, "10 s: no phone");
    Test.assertEqualMessage(off.state, OffRoute.NO_PHONE, "no-phone state");
    Test.assertEqualMessage(off.update(26000, 60.0, 0.0, false), OffRoute.EVENT_NONE, "19 s: nothing yet");
    Test.assertEqualMessage(off.update(27000, 60.0, 0.0, false), OffRoute.EVENT_RETRY, "20 s: asks again");
    Test.assertEqualMessage(off.state, OffRoute.NO_PHONE, "the new attempt is silent");
    Test.assertEqualMessage(off.update(46000, 60.0, 0.0, false), OffRoute.EVENT_NONE, "39 s");
    Test.assertEqualMessage(off.update(47000, 60.0, 0.0, false), OffRoute.EVENT_RETRY, "40 s: again");

    // The phone answered (the new route is arriving): goes back to "recalculating" and
    // stops asking, even past 20 s.
    Test.assertEqualMessage(off.update(48000, 60.0, 0.0, true), OffRoute.EVENT_ANSWERING, "reply on its way");
    Test.assertEqualMessage(off.state, OffRoute.REQUESTED, "recalculating again");
    Test.assertEqualMessage(off.update(70000, 60.0, 0.0, true), OffRoute.EVENT_NONE, "no request during the reply");

    // Returned to the route on its own.
    Test.assertEqualMessage(off.update(71000, 10.0, 0.0, false), OffRoute.EVENT_BACK, "back");
    Test.assertEqualMessage(off.state, OffRoute.ON_ROUTE, "on route");

    off.reset();
    Test.assertMessage(!off.armed, "a new route disarms");
    return true;
}
