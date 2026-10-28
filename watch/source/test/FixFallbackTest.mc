import Toybox.Lang;
import Toybox.Test;

//! Helper for the GPS fallback tests (C13b): one tick per second, like the app.
(:test)
module FixFallbackAssert {

    //! Navigating, with an own fix at instant `atMs`.
    function riding(atMs as Number) as FixFallback {
        var fallback = new FixFallback();
        fallback.poll(atMs, true);
        fallback.onOwnFix(atMs);
        return fallback;
    }

    //! One tick per second from `fromMs` to `toMs`, both included, with no own
    //! fix. Returns how many gave `event`.
    function silence(fallback as FixFallback, fromMs as Number, toMs as Number, event as Number) as Number {
        var count = 0;
        for (var t = fromMs; t <= toMs; t += 1000) {
            if (fallback.poll(t, true) == event) {
                count++;
            }
        }
        return count;
    }

    //! An own fix and one tick per second from `fromMs` to `toMs`, both
    //! included: the GPS is back. Returns how many ticks gave `event`.
    function fixes(fallback as FixFallback, fromMs as Number, toMs as Number, event as Number) as Number {
        var count = 0;
        for (var t = fromMs; t <= toMs; t += 1000) {
            fallback.onOwnFix(t);
            if (fallback.poll(t, true) == event) {
                count++;
            }
        }
        return count;
    }
}

//! The phone GPS as a fallback (C13b, `05 §FIX_REQ`): the watch asks when it
//! has no own fix, renews the request, uses the phone fix only while it
//! needs to and dismisses it when the GPS really comes back.
(:test)
module FixFallbackTest {

    // prevents: the watch leaving the map frozen in a tunnel without ever asking the phone for the position,
    // which is in the pocket with GPS; or asking on every tick and flooding the link.
    (:test)
    function fiveSecondsWithoutFixAsksThePhone(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);

        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "at 5 s with no fix, it asks");
        Test.assertMessage(fallback.asking, "and keeps asking");
        Test.assertEqualMessage(fallback.poll(6000, true), FixFallback.EVENT_NONE, "one request, not one per tick");

        // No fix at all since navigation started: counts from its start.
        var cold = new FixFallback();
        Test.assertEqualMessage(cold.poll(100000, true), FixFallback.EVENT_NONE, "navigation just started");
        Test.assertEqualMessage(cold.poll(104000, true), FixFallback.EVENT_NONE, "4 s later not yet");
        Test.assertEqualMessage(cold.poll(105000, true), FixFallback.EVENT_ASK, "5 s without the first fix: it asks");

        // Idle on the home screen, not navigating, nobody asks for anything.
        var idle = new FixFallback();
        for (var t = 0; t <= 60000; t += 1000) {
            Test.assertEqualMessage(idle.poll(t, false), FixFallback.EVENT_NONE, "outside navigation");
        }
        Test.assertMessage(!idle.asking, "no request outside navigation");
        return true;
    }

    //! The threshold: 4 s is an overpass, not a gap. The canary (`sim.py test
    //! --canary`) sets the threshold to 4 s, and this test must fail.
    // prevents: the phone turning the GPS on and off the whole trip, at every overpass and every
    // lost fix, spending the battery that the fallback exists to not spend.
    (:test)
    function fourSecondsWithoutFixDoesNotAsk(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);

        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 1000, 4000, FixFallback.EVENT_NONE), 4, "4 s with no fix does not ask");
        Test.assertMessage(!fallback.asking, "and it is not asking");

        // One fix every 4 s, for a minute: sparse, but not a gap.
        for (var t = 4000; t <= 60000; t += 4000) {
            fallback.onOwnFix(t);
            Test.assertEqualMessage(
                FixFallbackAssert.silence(fallback, t, t + 3000, FixFallback.EVENT_NONE), 4,
                "thin fix at " + (t / 1000).toString() + " s");
        }
        Test.assertMessage(!fallback.asking, "a thin GPS does not turn the phone on");
        return true;
    }

    // prevents: a FIX_REQ lost in the PhoneLink queue leaving the watch with no fallback the whole tunnel,
    // and the phone (which stops by itself after 40 s without renewal) turning off in the middle of it.
    (:test)
    function theRequestIsRepeatedEveryTwentySeconds(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);

        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "the first request");
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 6000, 24000, FixFallback.EVENT_ASK), 0, "none before 20 s");
        Test.assertEqualMessage(fallback.poll(25000, true), FixFallback.EVENT_ASK, "20 s later, again");
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 26000, 65000, FixFallback.EVENT_ASK), 2, "at 45 and at 65 s");
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 66000, 84000, FixFallback.EVENT_STOP), 0, "and it never dismisses without a fix");
        return true;
    }

    // prevents: the phone fix, which keeps arriving for a few seconds after the watch GPS
    // is back, competing for the position with the watch's (the arrow jumping between the two);
    // and a phone fix with 80 m of error declaring the bike off route.
    (:test)
    function aPhoneFixIsIgnoredWhileTheWatchHasItsOwn(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);

        Test.assertEqualMessage(fallback.acceptPhoneFix(1000, 10), FixFallback.PHONE_NOT_NEEDED, "own fix from 1 s ago");
        Test.assertEqualMessage(fallback.acceptPhoneFix(4999, 10), FixFallback.PHONE_NOT_NEEDED, "4.999 s old still counts");
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");
        Test.assertEqualMessage(fallback.acceptPhoneFix(5500, 10), FixFallback.PHONE_USED, "now the phone one counts");
        Test.assertEqualMessage(fallback.acceptPhoneFix(6500, 41), FixFallback.PHONE_WEAK, "41 m is a weak fix");
        Test.assertEqualMessage(fallback.acceptPhoneFix(7500, 40), FixFallback.PHONE_USED, "40 m still works");
        Test.assertEqualMessage(fallback.phoneFixes, 2, "two used");
        Test.assertEqualMessage(fallback.weakFixes, 1, "one weak");
        Test.assertMessage(!fallback.takeEnded(), "the episode has not ended yet");

        // The GPS is back: the own fix counts at once, before the phone is dismissed.
        fallback.onOwnFix(8000);
        Test.assertMessage(fallback.takeEnded(), "the phone episode ended");
        Test.assertMessage(!fallback.takeEnded(), "and it is counted only once");
        Test.assertEqualMessage(fallback.endedFixes, 2, "with the two fixes used");
        Test.assertEqualMessage(fallback.endedMs, 2500, "in 2.5 s, from the first used until the own fix");
        Test.assertMessage(fallback.asking, "the request stays open for 5 s more");
        Test.assertEqualMessage(fallback.acceptPhoneFix(8500, 10), FixFallback.PHONE_NOT_NEEDED, "but the phone one no longer counts");

        // Outside navigation the phone fix belongs to nobody.
        var idle = new FixFallback();
        idle.poll(0, false);
        Test.assertEqualMessage(idle.acceptPhoneFix(60000, 5), FixFallback.PHONE_NOT_NEEDED, "not navigating");
        return true;
    }

    // prevents: the phone GPS staying on the rest of the trip after a 30 s tunnel (the
    // FIX_REQ 0 never going out), or turning off at the first fix that shows up between two buildings.
    (:test)
    function thePhoneIsToldToStopFiveSecondsAfterTheFixIsBack(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");

        Test.assertEqualMessage(
            FixFallbackAssert.fixes(fallback, 10000, 14000, FixFallback.EVENT_NONE), 5, "4 s of fix back: not yet");
        fallback.onOwnFix(15000);
        Test.assertEqualMessage(fallback.poll(15000, true), FixFallback.EVENT_STOP, "5 s in a row: dismisses");
        Test.assertMessage(!fallback.asking, "and stops asking");
        Test.assertEqualMessage(
            FixFallbackAssert.fixes(fallback, 16000, 60000, FixFallback.EVENT_NONE), 45, "one dismissal, not one per tick");

        // And the cycle restarts at the next gap.
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 61000, 64000, FixFallback.EVENT_NONE), 4, "4 s of the next gap");
        Test.assertEqualMessage(fallback.poll(65000, true), FixFallback.EVENT_ASK, "asks again");
        return true;
    }

    // prevents: a GPS that fails for 3 s and comes back dismissing the phone at once, with 1 s of consecutive
    // fix, just because the first fix after the tunnel was more than 5 s ago.
    (:test)
    function aGapInsideTheFiveSecondsStartsThemAgain(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");

        // Fixes at 10, 11 and 12 s, three silent seconds, and the fix returns at 16 s.
        FixFallbackAssert.fixes(fallback, 10000, 12000, FixFallback.EVENT_NONE);
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 13000, 15000, FixFallback.EVENT_NONE), 3, "3 s silent: keeps asking");
        fallback.onOwnFix(16000);
        Test.assertEqualMessage(
            fallback.poll(16000, true), FixFallback.EVENT_NONE, "6 s after the 1st fix, but only 1 fix in a row");
        Test.assertEqualMessage(
            FixFallbackAssert.fixes(fallback, 17000, 20000, FixFallback.EVENT_NONE), 4, "4 s in a row: not yet");
        fallback.onOwnFix(21000);
        Test.assertEqualMessage(fallback.poll(21000, true), FixFallback.EVENT_STOP, "5 s in a row since 16 s");
        return true;
    }

    // prevents: the phone going quiet in the middle of the tunnel (radio dropped, Android cut the GPS) and the
    // watch going on without lighting the "weak GPS", with the map frozen at its last fix.
    (:test)
    function aSilentPhoneIsNoLongerGivingThePosition(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");
        Test.assertMessage(!fallback.phoneGiving(6000), "it asked, but no phone fix arrived");

        Test.assertEqualMessage(fallback.acceptPhoneFix(7000, 10), FixFallback.PHONE_USED, "phone fix");
        Test.assertMessage(fallback.phoneGiving(7000), "the phone is giving the position");
        Test.assertMessage(fallback.phoneGiving(11999), "4.999 s later it still counts");
        Test.assertMessage(!fallback.phoneGiving(12000), "5 s without a phone fix: it went quiet");

        Test.assertEqualMessage(fallback.acceptPhoneFix(13000, 10), FixFallback.PHONE_USED, "came back");
        Test.assertMessage(fallback.phoneGiving(13000), "and counts again");
        // The imprecise fix does not move the map, so it does not count as a position.
        Test.assertEqualMessage(fallback.acceptPhoneFix(19000, 90), FixFallback.PHONE_WEAK, "90 m: weak");
        Test.assertMessage(!fallback.phoneGiving(19000), "the weak one does not renew");
        return true;
    }

    // prevents: two loose fixes in the middle of the tunnel dismissing the phone, which turns its GPS back on
    // from scratch on the next request (seconds without position that the fallback existed to cover).
    (:test)
    function aFixThatVanishesAgainDoesNotReleaseThePhone(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");

        // Two fixes, at 10 and 11 s, and the GPS vanishes again.
        FixFallbackAssert.fixes(fallback, 10000, 11000, FixFallback.EVENT_NONE);
        Test.assertEqualMessage(
            FixFallbackAssert.silence(fallback, 12000, 24000, FixFallback.EVENT_STOP), 0,
            "5 s after the first, but the last is already 4 old: does not dismiss");
        Test.assertMessage(fallback.asking, "keeps asking");
        Test.assertEqualMessage(fallback.acceptPhoneFix(24500, 10), FixFallback.PHONE_USED, "and the phone one counts again");

        // The GPS returns at 30 s: the 5 s count from this fix, not from those before the gap.
        Test.assertEqualMessage(
            FixFallbackAssert.fixes(fallback, 30000, 34000, FixFallback.EVENT_STOP), 0, "4 s since the return");
        fallback.onOwnFix(35000);
        Test.assertEqualMessage(fallback.poll(35000, true), FixFallback.EVENT_STOP, "5 s since the return: dismisses");
        return true;
    }

    // prevents: the rider arriving (or ending the route) with the phone GPS requested and the phone
    // still streaming position to a watch that already stopped navigating.
    (:test)
    function theRequestStopsWhenTheNavigationEnds(logger as Logger) as Boolean {
        var fallback = FixFallbackAssert.riding(0);
        Test.assertEqualMessage(fallback.poll(5000, true), FixFallback.EVENT_ASK, "asks");
        Test.assertEqualMessage(fallback.acceptPhoneFix(6000, 10), FixFallback.PHONE_USED, "uses the phone one");

        Test.assertEqualMessage(fallback.poll(9000, false), FixFallback.EVENT_STOP, "navigation ended: dismisses");
        Test.assertMessage(fallback.takeEnded(), "and the phone episode closes");
        Test.assertEqualMessage(fallback.endedFixes, 1, "with the fix used");
        Test.assertEqualMessage(fallback.poll(10000, false), FixFallback.EVENT_NONE, "only once");
        Test.assertEqualMessage(fallback.acceptPhoneFix(10500, 10), FixFallback.PHONE_NOT_NEEDED, "a late fix does not count");

        // The next route starts counting from its own start, not from the fix 100 s ago.
        Test.assertEqualMessage(fallback.poll(100000, true), FixFallback.EVENT_NONE, "new route");
        Test.assertEqualMessage(fallback.poll(104000, true), FixFallback.EVENT_NONE, "4 s");
        Test.assertEqualMessage(fallback.poll(105000, true), FixFallback.EVENT_ASK, "5 s with no fix on the new route");
        return true;
    }
}

//! The `phone` origin in the telemetry line (C13b): it is what `tools/e2e.py
//! --sem-fix` looks for to know the map moved with the phone GPS.
// prevents: the telemetry saying `fix gps` (or `?`) with the position coming from the phone, and a street log
// with the watch GPS mute looking like a good GPS log.
(:test)
function telemetrySaysWhenTheFixIsThePhones(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(11);
    route.durationS = 600;
    var matcher = new MapMatcher(route);
    var nav = new NavState();
    nav.phase = NavPhase.NAVIGATING;
    nav.fixSource = FixSource.PHONE;
    nav.applyFix(0.0, 500.0, 10.0, null);
    matcher.update(0.0, 500.0);

    var line = Telemetry.line("navigating", "map", route, new CorridorModel(), 0, nav, matcher, 102400, 204800, 87.6);
    Test.assertMessage(line.find(" · fix phone") != null, "fix source: " + line);
    return true;
}
