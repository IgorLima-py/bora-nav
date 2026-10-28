import Toybox.Lang;
import Toybox.Test;

//! A GPS gap of 20 s or more is logged, once in the middle of it and once when the
//! fix returns; anything shorter is motorcycle GPS in a city and is not a line.
(:test)
function aGapOfTwentySecondsIsReportedOnceAndOnReturn(logger as Logger) as Boolean {
    var gap = new FixGap();
    Test.assertEqualMessage(gap.poll(50000), 0, "no fix yet, so no gap to measure");
    Test.assertEqualMessage(gap.onFix(0), 0, "the first fix has no silence before it");

    Test.assertEqualMessage(gap.poll(19999), 0, "19.9 s is still city GPS");
    Test.assertEqualMessage(gap.poll(20000), 20000, "20 s is a gap");
    Test.assertEqualMessage(gap.poll(25000), 0, "reports once per gap");
    Test.assertEqualMessage(gap.onFix(31000), 31000, "the fix coming back reports the whole duration");
    Test.assertEqualMessage(gap.onFix(32000), 0, "next fix, no gap");

    Test.assertEqualMessage(gap.onFix(51000), 0, "19 s between fixes is not a gap");
    Test.assertEqualMessage(gap.poll(70999), 0, "nor 19.9 s later");
    Test.assertEqualMessage(gap.poll(71000), 20000, "new gap, new report");

    gap.reset();
    Test.assertEqualMessage(gap.poll(999999), 0, "a new route resets the silence");
    return true;
}
