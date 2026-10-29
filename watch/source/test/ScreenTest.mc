import Toybox.Lang;
import Toybox.Test;

//! **The conversion from the Venu 4 45 mm to the other screens** (C16.12, `Screen`).
//!
//! The first test is the promise that keeps the reference watch untouched: at 454 px every px is
//! itself, negatives included. The second puts the module on a 390 px glass for a moment (the
//! tests never call `Screen.init`) and checks the rounding at the center, the edge and a small pad.

(:test)
function screenPxIsTheIdentityOnTheReference(logger as Logger) as Boolean {
    Test.assertEqualMessage(Screen.size, Screen.REF, "the tests run at the reference size");
    for (var n = -500; n <= 500; n++) {
        if (Screen.px(n) != n) {
            Test.assertEqualMessage(Screen.px(n), n, "px(" + n + ") at 454");
        }
    }
    Test.assertEqualMessage(Screen.pxf(227.5), 227.5, "pxf at 454 returns the value");
    return true;
}

(:test)
function screenPxScalesToASmallerGlass(logger as Logger) as Boolean {
    var size = Screen.size;
    var half = Screen.half;
    Screen.size = 390;
    Screen.half = 195;
    try {
        Test.assertEqualMessage(Screen.px(227), 195, "the center lands on the center");
        Test.assertEqualMessage(Screen.px(454), 390, "the edge lands on the edge");
        Test.assertEqualMessage(Screen.px(6), 5, "6 x 390 / 454 = 5.15");
        Test.assertEqualMessage(Screen.px(-6), -5, "the same rounding below zero");
        Test.assertEqualMessage(Screen.px(330), 283, "the puck: 330 x 390 / 454 = 283.48");
        Test.assertMessage((Screen.pxf(454) - 390.0).abs() < 0.001, "pxf: " + Screen.pxf(454));
    } finally {
        Screen.size = size;
        Screen.half = half;
    }
    return true;
}
