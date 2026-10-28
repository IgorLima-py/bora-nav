import Toybox.Lang;
import Toybox.Test;
import Toybox.WatchUi;

//! **A gesture on the map does not close the app** (C16.5, `NavDelegate`).
//!
//! The SDK does not let you create a `SwipeEvent` or a `FlickEvent` (they have no public
//! constructor), so the test hands the delegate an object that answers the same
//! `getDirection()`. What is proven is what `BehaviorDelegate` does with the
//! answer: `false` becomes BACK, and BACK on the map leaves the app.
(:test)
class FakeGesture {
    private var _direction as Number;

    function initialize(direction as Number) {
        _direction = direction;
    }

    function getDirection() as Number {
        return _direction;
    }
}

// prevents: in C16, "almost any touch closes the app; pinch closes it" (Igor, at the bench): `onSwipe`
// returned `false` for everything but "up", and the right swipe became BACK.
(:test)
function noSwipeOrFlickOnTheMapFallsThroughToBack(logger as Logger) as Boolean {
    var route = NavAssert.straightRoute(800);
    var delegate = new NavDelegate(route, new NavState(), new MapRenderer());
    // Up opens Details (`pushDetails`, which needs the real app): left out of here.
    var directions = [WatchUi.SWIPE_DOWN, WatchUi.SWIPE_LEFT, WatchUi.SWIPE_RIGHT] as Array<Number>;
    for (var i = 0; i < directions.size(); i++) {
        var swipe = new FakeGesture(directions[i] as Number);
        Test.assertMessage(delegate.onSwipe(swipe as WatchUi.SwipeEvent),
            "the swipe " + (directions[i] as Number).toString() + " went through and would become BACK");
    }
    for (var degrees = 0; degrees < 360; degrees += 90) {
        Test.assertMessage(delegate.onFlick(new FakeGesture(degrees) as WatchUi.FlickEvent),
            "the flick at " + degrees.toString() + " degrees went through");
    }
    return true;
}


// prevents: at the 2026-10-17 bench, "I open the side menu, ultra mega slow to scroll it": the map
// redrew under the action menu on every GPS and phone position.
(:test)
function theActionMenuHoldsTheMapUntilItCloses(logger as Logger) as Boolean {
    var nav = new NavState();
    Test.assertMessage(!nav.menuHoldsTheMap(1000), "no menu, the map holds nothing");
    nav.menuOpened(1000);
    Test.assertMessage(nav.menuHoldsTheMap(1500), "with the menu open, the map kept redrawing");
    new NavMenuDelegate(nav).onBack();
    Test.assertMessage(!nav.menuHoldsTheMap(1600), "BACK closed the menu and the map stayed frozen");
    nav.menuOpened(2000);
    Test.assertMessage(!nav.menuHoldsTheMap(2000 + nav.MENU_FREEZE_MS), "a menu closed from outside held the map");
    return true;
}
