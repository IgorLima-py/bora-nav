import Toybox.Lang;
import Toybox.System;

//! Navigation math that is not geometry: local ETA and arrival
//! (`03 §Map-matching`, RF-08 and RF-12).
//!
//! A module of deliberately pure functions — everything here is testable without GPS, without
//! a wall clock and without a screen, which is the only way to prove an ETA before
//! getting on the bike.
module NavEngine {

    //! Arrived (RF-12). 30 m is what `01` asks for; it is also roughly the
    //! uncertainty of an urban fix, so requiring less would be pretending precision.
    const ARRIVAL_M = 30.0;

    //! Below this the trip average says nothing useful about how much is left: it is
    //! a test on foot or stopped traffic, not a trip.
    const MIN_USEFUL_SPEED_MPS = 2.0;

    //! Seconds left to arrive.
    //!
    //! Two estimates, each wrong in a different way:
    //!
    //! - **from the API**: `durationS × (remaining / total)`. It knows about traffic and
    //!   traffic lights, but it is the average of *another* trip, not yours.
    //! - **from the trip average**: `remaining / NavState.tripSpeedMps`, with the
    //!   stops. It knows how *you* are going today, but extrapolates avenue traffic
    //!   into the city center.
    //!
    //! The average of the two errs less than either alone, and errs in a
    //! stable way — which on a screen read at a glance matters more than precision:
    //! an ETA that jumps 10 min every block is used by nobody. In the
    //! first 2 min of the trip ([NavState.TRIP_WARMUP_MS]) only the API counts, and the
    //! trip average gradually enters until 10 min ([NavState.tripWeight]).
    function remainingSeconds(route as RouteModel, matcher as MapMatcher, nav as NavState) as Number {
        var total = route.lengthM();
        var left = matcher.remainingM();
        if (total <= 0.0 || left <= 0.0) {
            return 0;
        }

        var byApi = route.durationS * (left / total);
        if (nav.tripSpeedMps < MIN_USEFUL_SPEED_MPS) {
            return byApi.toNumber();
        }

        var bySpeed = left / nav.tripSpeedMps;
        return (byApi + (bySpeed - byApi) * nav.tripWeight / 2.0).toNumber();
    }

    //! Below this the arrival delta does not show (C16.5). The screen's arrival time
    //! is rounded to the minute (`(s + 30) / 60`): a delta under 30 s does not change the
    //! minute the rider reads, and showing it would make the number blink with the one-second
    //! noise of the estimate. A choice, not a measurement.
    const DELTA_MIN_S = 30;

    //! The arrival delta (C16.5) as the rider reads it: `+7 min` (will arrive 7 min later than
    //! predicted at the start of the trip), `-1 min`, `+1 h 15 min`, and nothing below [DELTA_MIN_S]
    //! on either side. Only hours and minutes, in the remaining-time format ([formatDuration]):
    //! Igor found the seconds too much (2026-10-17, "if it's only min, show only 7 min").
    function formatDelta(seconds as Number) as String {
        var abs = seconds < 0 ? -seconds : seconds;
        if (abs < DELTA_MIN_S) {
            return "";
        }
        return (seconds < 0 ? "-" : "+") + formatDuration(abs);
    }

    //! Arrival time as "HH:MM", already added to the wrist clock.
    function arrivalClock(secondsAhead as Number) as String {
        var now = System.getClockTime();
        var minutes = now.hour * 60 + now.min + ((secondsAhead + 30) / 60);
        minutes = minutes % (24 * 60);
        return (minutes / 60).format("%02d") + ":" + (minutes % 60).format("%02d");
    }

    //! Remaining time as the rider reads it (C4): `22 min`, `1 h 34 min`, `2 h`.
    //! Rounds to the nearest minute and never says `0 min` with a route
    //! ahead. It is the `format_time` of `tools/design_tokens.py`, and
    //! `formatDurationReadsLikeTheMockup` proves the two are equal.
    function formatDuration(seconds as Number) as String {
        var minutes = (seconds + 30) / 60;
        if (minutes < 1) {
            minutes = 1;
        }
        if (minutes >= 60) {
            var hours = minutes / 60;
            var rest = minutes % 60;
            return hours.toString() + " h" + (rest > 0 ? " " + rest.format("%02d") + " min" : "");
        }
        return minutes.toString() + " min";
    }

    //! Arrived at the destination? Requires a match with the route: without it, `remainingM()` is
    //! the remainder of a progress that was not measured on this route.
    //!
    //! And it requires the bike near the route (C16.6). `matched` is true at any
    //! distance: a fix far from everything matches the last segment with `remainingM()` 0,
    //! and the `ARRIVED` phase gets stuck before `OffRoute` sees it (it asks for >40 m for
    //! >5 s). The threshold is its own: if it would find the bike off the route, it is not arrival.
    function hasArrived(matcher as MapMatcher) as Boolean {
        return matcher.matched && matcher.remainingM() <= ARRIVAL_M
            && matcher.crossTrack <= offRouteThresholdM();
    }

    //! Distance formatted as the rider reads it (`03 §HUD`): round meters in steps of 10
    //! when near, kilometers with one decimal when far, and "AGORA" when there is nothing
    //! left to anticipate.
    function formatDistance(metres as Float) as String {
        if (metres < 20.0) {
            return Tr.s(Rez.Strings.Now);
        }
        if (metres < 1000.0) {
            return (((metres / 10.0).toNumber()) * 10).toString() + " m";
        }
        return Fmt.km(metres / 1000.0) + " km";
    }

    //! The same distance in two pieces, `[number, unit]`, so the new screen can
    //! draw the unit smaller than the number (C4). "AGORA" has no unit.
    function distanceParts(metres as Float) as Array<String> {
        var text = formatDistance(metres);
        var space = text.find(" ");
        if (space == null) {
            return [text, ""] as Array<String>;
        }
        return [
            text.substring(0, space) as String,
            text.substring(space + 1, text.length()) as String
        ] as Array<String>;
    }
}
