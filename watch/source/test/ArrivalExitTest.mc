import Toybox.Lang;
import Toybox.Test;

//! The app's deadline after arrival (C16.5, `ArrivalExit`): 5 min with no touch,
//! the log line, 3 s for it to go out, and the app closes.
// prevents: on an October ride the app sat 4 h on the arrival screen and used 4 battery points of the
// watch (59 -> 55%), more than the 31 min trip (DECISIONS §2026-10-16).
(:test)
function theAppClosesFiveMinutesAfterArrivingUntouched(logger as Logger) as Boolean {
    var exit = new ArrivalExit();
    Test.assertEqualMessage(exit.poll(10000000), ArrivalExit.NONE, "no arrival, nothing");

    exit.arrived(0);
    exit.arrived(50000);
    Test.assertEqualMessage(exit.poll(299999), ArrivalExit.NONE, "before 5 min");
    exit.touched(100000);
    Test.assertEqualMessage(exit.poll(399999), ArrivalExit.NONE, "the tap restarted the count");
    Test.assertEqualMessage(exit.poll(400000), ArrivalExit.ANNOUNCE, "5 min after the tap, the notice");
    exit.touched(400500);
    Test.assertEqualMessage(exit.poll(402999), ArrivalExit.NONE, "the log has 3 s to go out");
    Test.assertEqualMessage(exit.poll(403000), ArrivalExit.EXIT, "and the app exits, a tap after the notice does not hold it");

    exit.reset();
    Test.assertEqualMessage(exit.poll(900000), ArrivalExit.NONE, "a new route resets");
    return true;
}
