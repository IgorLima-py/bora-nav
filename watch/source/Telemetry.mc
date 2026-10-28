import Toybox.Lang;

//! lang: log file
//! The telemetry state line (`phase … · fix gps`), assembled outside the app.
//!
//! It used to live inline in `MotoNavApp.sendTelemetry`, where no test reaches. As a
//! pure function, with no `System.getSystemStats()` or `Position` inside, it is
//! testable in the simulator (`TelemetryTest.mc`) — and it is the line that `sim.py`, the
//! bench and the ride report read, so a field that vanishes from it is a
//! diagnostic that vanishes silently.
module Telemetry {

    //! `usedBytes`/`totalBytes`/`battery` come from `System.getSystemStats()`, read by the
    //! caller. The rest is the app's live state.
    function line(
        phase as String,
        screen as String,
        route as RouteModel,
        corridor as CorridorModel,
        visibleWays as Number,
        nav as NavState,
        matcher as MapMatcher,
        usedBytes as Number,
        totalBytes as Number,
        battery as Float
    ) as String {
        return "phase " + phase
            + " · screen " + screen
            + " · route " + route.routeId.toString()
            + " " + route.xs.size().toString() + "pts"
            + " · corridor " + corridor.lodsReceived.toString() + " lods "
            + corridor.pointCount().toString() + " pts "
            + visibleWays.toString() + " on screen"
            + " · zoom " + nav.metersPerPx.format("%.1f")
            + " · " + (matcher.matched && nav.offRoute == OffRoute.ON_ROUTE ? "on route" : "off")
            + " · " + (nav.hasFix ? (nav.speedMps * 3.6).toNumber().toString() + "km/h" : "no fix")
            // Memory in KB: the São Paulo corridor is the largest block on the heap, and
            // this is where a corridor that is too big shows up before the crash.
            + " · mem " + (usedBytes / 1024).toString() + "/" + (totalBytes / 1024).toString() + "KB"
            // Level in %, integer: the bench's relatorio.py (C6b) takes the %/h from here.
            + " · bat " + (battery + 0.5).toNumber().toString() + "%"
            + " · eta " + eta(route, matcher, nav)
            + " · fix " + fixName(nav);
    }

    //! Seconds remaining, or `-` when there is nothing to estimate: without navigating or
    //! without matching the route, the matcher's `remainingM()` does not measure this trip.
    function eta(route as RouteModel, matcher as MapMatcher, nav as NavState) as String {
        if (nav.phase != NavPhase.NAVIGATING || !matcher.matched) {
            return "-";
        }
        return NavEngine.remainingSeconds(route, matcher, nav).toString() + "s";
    }

    function fixName(nav as NavState) as String {
        if (!nav.hasFix) {
            return "-";
        }
        if (nav.fixSource == FixSource.GPS) { return "gps"; }
        if (nav.fixSource == FixSource.REPLAY) { return "replay"; }
        if (nav.fixSource == FixSource.PHONE) { return "phone"; }
        return "?";
    }
}
