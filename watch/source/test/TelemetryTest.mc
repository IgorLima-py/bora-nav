import Toybox.Lang;
import Toybox.Test;

//! The telemetry line is what `sim.py`, the bench (C6) and the ride report
//! (C7) read. A field that disappears from it breaks nothing on screen — a
//! diagnostic vanishes, silently. This test is what makes the disappearance fail loudly.

(:test)
module TelemetryAssert {
    function contains(text as String, piece as String) as Boolean {
        return text.find(piece) != null;
    }
}

//! The C2a fields: memory, ETA and fix source in the status line, and the
//! work **peak** (not the last frame) in the frame summary.
(:test)
function telemetryLineCarriesTheNewFields(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(11); // 1,000 m to the north
    route.durationS = 600;
    var matcher = new MapMatcher(route);
    var nav = new NavState();
    var corridor = new CorridorModel();

    // Before navigating: no fix and no ETA, and the line says so instead of
    // making up a number.
    var idle = Telemetry.line("idle", "initial", route, corridor, 0, nav, matcher, 102400, 204800, 87.6);
    Test.assertMessage(TelemetryAssert.contains(idle, " · mem 100/200KB"), "memory in KB: " + idle);
    Test.assertMessage(TelemetryAssert.contains(idle, " · bat 88% · eta"), "battery rounded, between mem and eta: " + idle);
    Test.assertMessage(TelemetryAssert.contains(idle, " · eta -"), "not navigating, eta empty: " + idle);
    Test.assertMessage(TelemetryAssert.contains(idle, " · fix -"), "no fix, source empty: " + idle);

    // Navigating at 10 m/s halfway along the route, at the trip's first fix: before the
    // 2 min from the start only the API counts, 300 s.
    nav.phase = NavPhase.NAVIGATING;
    nav.fixSource = FixSource.GPS;
    nav.applyFix(0.0, 500.0, 10.0, null);
    matcher.update(0.0, 500.0);
    var riding = Telemetry.line("navigating", "map", route, corridor, 0, nav, matcher, 102400, 204800, 87.6);
    Test.assertMessage(TelemetryAssert.contains(riding, " · eta 300s"), "eta in seconds: " + riding);
    Test.assertMessage(TelemetryAssert.contains(riding, " · fix gps"), "fix source: " + riding);

    // The frame summary carries the window's worst frame, not the last.
    var map = new MapRenderer();
    map.work = 500;
    map.noteFrame(10);
    map.work = 100;
    map.noteFrame(10);
    var summary = map.frameSummary();
    Test.assertMessage(TelemetryAssert.contains(summary, "work peak 500/"), "peak, not the last one: " + summary);

    // And the window resets: the previous window's peak does not contaminate the next.
    map.resetFrameStats();
    map.work = 50;
    map.noteFrame(10);
    var fresh = map.frameSummary();
    var reset = TelemetryAssert.contains(fresh, "work peak 50/");
    Test.assertMessage(reset, "new window, new peak: " + fresh);
    return true;
}
