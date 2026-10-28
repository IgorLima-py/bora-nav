import Toybox.Lang;
import Toybox.Test;

//! The home screen list (sheet 1, `docs/design/telas.md` §4.6): the keyframes, the touch, the
//! focus and the step curve. The drawing is left to the `sim.py shots --inicio` prints.
module HomeListTest {

    // prevents: an item jumping out of place mid-step, or the interpolation getting the column wrong with d
    // negative (`toNumber` truncates toward zero, not down).
    (:test)
    function theListInterpolatesBetweenKeyframes(logger as Logger) as Boolean {
        assertNear(HomeList.at(HomeList.TEXT_BASE, 0.0), 250.0, "d 0: the card title");
        assertNear(HomeList.at(HomeList.TEXT_BASE, 2.0), 414.0, "d 2: the second one below");
        assertNear(HomeList.at(HomeList.TEXT_BASE, 0.5), 304.0, "d 0.5: halfway from 250 to 358");
        assertNear(HomeList.at(HomeList.TEXT_BASE, -1.5), 91.5, "d −1.5: halfway from 40 to 143");
        assertNear(HomeList.at(HomeList.ICON_OP, -1.5), 0.275, "d −1.5: the icon above lighting up");
        assertNear(HomeList.at(HomeList.TEXT_BASE, -5.0), 40.0, "below −2 it stays at the end");
        assertNear(HomeList.at(HomeList.TEXT_BASE, 7.0), 470.0, "above 3 it stays at the end");
        Test.assertEqualMessage(HomeList.nearest(0.0), 2, "d 0 is the card column");
        Test.assertEqualMessage(HomeList.nearest(0.49), 2, "the bold only switches at half a step");
        Test.assertEqualMessage(HomeList.nearest(0.51), 3, "past half, it switches");
        Test.assertEqualMessage(HomeList.nearest(-1.6), 0, "d −1.6 is the −2 column");
        return true;
    }

    // prevents: the glove opening the wrong screen: the gap between the card and its neighbors does nothing.
    (:test)
    function theTapTakesTheCardOrANeighbour(logger as Logger) as Boolean {
        Test.assertEqualMessage(HomeList.hit(246), HomeList.HIT_CARD, "the middle of the card");
        Test.assertEqualMessage(HomeList.hit(182), HomeList.HIT_CARD, "the top edge of the card");
        Test.assertEqualMessage(HomeList.hit(347), HomeList.HIT_NEXT, "the neighbor below");
        Test.assertEqualMessage(HomeList.hit(140), HomeList.HIT_PREVIOUS, "the neighbor above");
        Test.assertEqualMessage(HomeList.hit(315), HomeList.HIT_NONE, "the gap below the card");
        Test.assertEqualMessage(HomeList.hit(176), HomeList.HIT_NONE, "the gap above the card");
        Test.assertEqualMessage(HomeList.hit(60), HomeList.HIT_NONE, "the mark at the top");
        Test.assertEqualMessage(HomeList.hit(420), HomeList.HIT_NONE, "the bottom of the glass");
        return true;
    }

    // prevents: the list wrapping around and Enter with a glove opening Ligação (Link) instead of Favoritos (Favorites).
    (:test)
    function theFocusStopsAtBothEnds(logger as Logger) as Boolean {
        Test.assertEqualMessage(HomeList.clampFocus(-1), HomeList.FAVORITES, "from Favorites it does not go up");
        Test.assertEqualMessage(HomeList.clampFocus(4), HomeList.LINK, "from Connection it does not go down");
        Test.assertEqualMessage(HomeList.clampFocus(2), HomeList.SETTINGS, "in the middle it stays");
        return true;
    }

    // prevents: the rule 7 curve moving out of place: it starts still, arrives whole, and at half the time
    // has already covered almost everything (it is a fast-exit curve).
    (:test)
    function theStepFollowsTheLanguageCurve(logger as Logger) as Boolean {
        assertNear(HomeList.ease(0.0), 0.0, "t 0");
        assertNear(HomeList.ease(1.0), 1.0, "t 1");
        var half = HomeList.ease(0.5);
        Test.assertMessage(half > 0.9 && half < 1.0, "t 0.5 gave " + half.toString());
        Test.assertMessage(HomeList.ease(0.1) < HomeList.ease(0.2), "the curve always rises");
        return true;
    }

    // prevents: in `v1.2.0`, "the scroll [...] is kind of clunky and awkward, kind of slow and stiff" (Igor,
    // 2026-10-18). The list only moved at the end of the swipe; now it follows the finger, goes past the end only a
    // little, and on release stops at the neighboring item in the direction the finger went.
    (:test)
    function theListFollowsTheFingerAndSnaps(logger as Logger) as Boolean {
        assertNear(HomeList.rubber(1.4), 1.4, "in the middle, the list is the finger");
        assertNear(HomeList.rubber(-0.5), -0.175, "above the top, a third of the finger");
        assertNear(HomeList.rubber(-3.0), -0.3, "and at most 0.3 of an item");
        assertNear(HomeList.rubber(3.5), 3.175, "below Connection, the same rubber band");
        Test.assertEqualMessage(HomeList.snap(0.2, 0.2), 1, "a short drag up already switches item");
        Test.assertEqualMessage(HomeList.snap(0.05, 0.05), 0, "a shaky finger does not switch");
        Test.assertEqualMessage(HomeList.snap(1.1, 1.1), 1, "a bit past Recent, it stays on Recent");
        Test.assertEqualMessage(HomeList.snap(1.7, 1.7), 2, "close to Settings, it goes to Settings");
        Test.assertEqualMessage(HomeList.snap(0.6, -0.4), 0, "the finger came back, the item goes back");
        Test.assertEqualMessage(HomeList.snap(-0.3, -0.3), 0, "the top rubber band goes back to Favorites");
        Test.assertEqualMessage(HomeList.snap(3.2, 0.5), 3, "the bottom rubber band goes back to Connection");
        return true;
    }

    // prevents: the list jumping and then dragging. At 20 frames per second, the rule 7 curve did
    // ~68% of the step in the first frame; and the text switched from 44 to 32 px at once in the middle.
    (:test)
    function theStepSpreadsOverTheFrames(logger as Logger) as Boolean {
        var first = HomeList.stepEase(50.0 / HomeList.STEP_MS);
        Test.assertMessage(first > 0.45 && first < 0.56, "the first frame moved " + first.toString());
        assertNear(HomeList.stepEase(0.0), 0.0, "t 0");
        assertNear(HomeList.stepEase(1.0), 1.0, "t 1");
        Test.assertMessage(HomeList.stepEase(0.4) < HomeList.stepEase(0.6), "the curve always rises");
        Test.assertEqualMessage(HomeList.textPx(0.0), 44, "the card title");
        Test.assertEqualMessage(HomeList.textPx(1.0), 32, "the one below");
        Test.assertEqualMessage(HomeList.textPx(-1.0), 30, "the one above");
        Test.assertEqualMessage(HomeList.textPx(0.25), 42, "at a quarter of a step, 42 px");
        Test.assertEqualMessage(HomeList.textPx(0.5), 38, "at half, 38 px");
        return true;
    }

    // prevents: the opacity turning into the wrong color: the background is black, so it multiplies the RGB.
    (:test)
    function dimmingMultipliesTheColour(logger as Logger) as Boolean {
        Test.assertEqualMessage(HomeList.dim(0xFFFFFF, 1.0), 0xFFFFFF, "whole");
        Test.assertEqualMessage(HomeList.dim(0xFFFFFF, 0.0), 0, "dimmed");
        Test.assertEqualMessage(HomeList.dim(0x2FD3FF, 0.5), 0x17697F, "half of the cyan");
        Test.assertEqualMessage(HomeList.mix(0x000000, 0xFF0000, 0.5), 0x7F0000, "middle of the red");
        Test.assertEqualMessage(HomeList.textColor(0.0), DesignTokens.PRIMARY, "the card title is white");
        Test.assertEqualMessage(HomeList.textColor(-1.0), DesignTokens.NEAR_TEXT, "the one above is the near gray");
        return true;
    }

    function assertNear(got as Float, want as Float, what as String) as Void {
        var diff = got - want;
        Test.assertMessage(diff < 0.01 && diff > -0.01, what + ": " + got.toString() + " instead of " + want.toString());
    }
}
