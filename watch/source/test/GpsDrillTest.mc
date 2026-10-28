import Toybox.Lang;
import Toybox.Test;

//! The GPS gap drill (C16): waits the requested minutes, pretends for 90 s once
//! per trip, and stops pretending when the phone turns the drill off.

// prevents: the drill pretending the whole trip (without the end, the watch would stay on the phone's
// GPS until arrival) or repeating on every fix after the first.
(:test)
function theGpsDrillWaitsThenMutesOnceForNinetySeconds(logger as Logger) as Boolean {
    var drill = new GpsDrill();
    drill.begin(0);
    Test.assertEqualMessage(drill.poll(8 * 60000 - 1, 8), GpsDrill.EVENT_NONE, "nothing before 8 min");
    Test.assertMessage(!drill.muting, "before 8 min the GPS counts");
    Test.assertEqualMessage(drill.poll(8 * 60000, 8), GpsDrill.EVENT_START, "starts at 8 min");
    Test.assertMessage(drill.muting, "started pretending");
    Test.assertEqualMessage(drill.poll(8 * 60000 + 89999, 8), GpsDrill.EVENT_NONE, "still pretending");
    Test.assertMessage(drill.muting, "still pretending at 89 s");
    Test.assertEqualMessage(drill.poll(8 * 60000 + 90000, 8), GpsDrill.EVENT_END, "ends at 90 s");
    Test.assertMessage(!drill.muting, "ended");
    Test.assertEqualMessage(drill.poll(30 * 60000, 8), GpsDrill.EVENT_NONE, "once per trip");
    Test.assertMessage(!drill.muting, "does not pretend again");
    logger.debug("drill: 8 min wait, 90 s pretending, once");
    return true;
}

// prevents: the watch pretending to have no GPS with the drill off (the default) or outside a trip.
(:test)
function theGpsDrillIsOffAtZeroAndOutsideATrip(logger as Logger) as Boolean {
    var drill = new GpsDrill();
    Test.assertEqualMessage(drill.poll(60 * 60000, 8), GpsDrill.EVENT_NONE, "no trip, nothing");
    drill.begin(0);
    Test.assertEqualMessage(drill.poll(60 * 60000, 0), GpsDrill.EVENT_NONE, "0 switches it off");
    Test.assertMessage(!drill.muting, "switched off, does not pretend");
    drill.end();
    Test.assertEqualMessage(drill.poll(60 * 60000, 8), GpsDrill.EVENT_NONE, "trip ended, nothing");
    return true;
}

// prevents: turning the drill off on the phone and the watch going on without its GPS until the end of the 90 s.
(:test)
function turningTheGpsDrillOffMidWayEndsItNow(logger as Logger) as Boolean {
    var drill = new GpsDrill();
    drill.begin(0);
    drill.poll(5 * 60000, 5);
    Test.assertMessage(drill.muting, "started");
    Test.assertEqualMessage(drill.poll(5 * 60000 + 10000, 0), GpsDrill.EVENT_END, "switched off midway ends it");
    Test.assertMessage(!drill.muting, "back to the GPS");
    return true;
}

// prevents: the day's second trip having no drill because the first already had its own.
(:test)
function aNewTripRearmsTheGpsDrill(logger as Logger) as Boolean {
    var drill = new GpsDrill();
    drill.begin(0);
    drill.poll(2 * 60000, 2);
    drill.poll(2 * 60000 + 90000, 2);
    drill.end();
    drill.begin(60 * 60000);
    Test.assertEqualMessage(drill.poll(61 * 60000, 2), GpsDrill.EVENT_NONE, "counts for the new trip");
    Test.assertEqualMessage(drill.poll(62 * 60000, 2), GpsDrill.EVENT_START, "the new trip gets its own");
    return true;
}
