import Toybox.Lang;
import Toybox.Test;

//! The Details screen (C9): the next 3 maneuvers, the total distance and time,
//! the battery and the end button. Tests [DetailsModel], which is what the screen
//! draws; the screen's picture is `sim.py shots --detalhes`.

(:test)
module DetailsAssert {

    //! Straight route of 20 points (1,900 m), maneuvers at points 3, 8, 12 and 16
    //! (300, 800, 1,200 and 1,600 m), 10 min long, and the rider at 150 m.
    function modelAt150m(armed as Boolean) as DetailsModel {
        var route = F3Assert.routeWithTurns(20, [3, 8, 12, 16] as Array<Number>);
        route.destName = "Praça Teste";
        route.distanceM = 1900;
        route.durationS = 600;
        var matcher = new MapMatcher(route);
        matcher.update(0.0, 150.0);
        return new DetailsModel(route, matcher, 87.6, armed);
    }
}

//! Of the 4 maneuvers ahead, 3 appear, in order, with the distance **to each
//! one** (the first from the matcher, the others from the route's running total).
(:test)
function detailsShowsTheNextThreeManeuvers(logger as Logger) as Boolean {
    var model = DetailsAssert.modelAt150m(false);

    Test.assertEqualMessage(model.upcoming.size(), 3, "three maneuvers, not four");
    Test.assertEqualMessage(model.upcoming[0], "150 m · Direita · Rua 0", "at 150 m, first");
    Test.assertEqualMessage(model.upcoming[1], "650 m · Direita · Rua 1", "800 − 150");
    // 1,200 − 150 = 1,050 m: already in kilometers (the decimal separator is the locale's).
    Test.assertMessage(model.upcoming[2].find(" km · Direita · Rua 2") != null,
        "the third, at 1,050 m, is Rua 2, not the 4th: " + model.upcoming[2]);
    Test.assertMessage(model.upcoming[2].find("Rua 3") == null, "the fourth is left out");
    return true;
}

//! **Total** distance and time of the route, what is left, the battery and the button.
(:test)
function detailsShowsTotalsBatteryAndEndButton(logger as Logger) as Boolean {
    var model = DetailsAssert.modelAt150m(false);

    Test.assertMessage(model.total.find(" km · ") != null, "total distance in km: " + model.total);
    Test.assertMessage(model.total.find("10 min") != null, "total time, 600 s = 10 min: " + model.total);
    Test.assertMessage(model.left.find("faltam") == 0, "what is left: " + model.left);
    Test.assertEqualMessage(model.battery, "bateria 88%", "87.6 rounds to 88");
    Test.assertEqualMessage(model.endLabel, "Encerrar rota", "the button");
    Test.assertEqualMessage(DetailsAssert.modelAt150m(true).endLabel, "Toque de novo", "armed");

    Test.assertMessage(DetailsModel.hitsEnd(227, 360), "center of the button");
    Test.assertMessage(!DetailsModel.hitsEnd(227, 100), "outside the button: the maneuvers");
    Test.assertMessage(!DetailsModel.hitsEnd(60, 360), "outside the button: to the left");
    return true;
}

//! With no maneuvers ahead the screen says so, instead of being empty.
(:test)
function detailsWithoutManeuversSaysSo(logger as Logger) as Boolean {
    var route = F3Assert.routeWithTurns(20, [] as Array<Number>);
    var matcher = new MapMatcher(route);
    matcher.update(0.0, 150.0);
    var model = new DetailsModel(route, matcher, 50.0, false);
    Test.assertEqualMessage(model.upcoming.size(), 1, "one warning line");
    Test.assertEqualMessage(model.upcoming[0], "sem manobras à frente", "the warning");
    return true;
}

//! Ending requires two touches inside the window: a single touch, or the second
//! too late, does not end it.
(:test)
function endRouteNeedsTwoTapsInsideTheWindow(logger as Logger) as Boolean {
    var confirm = new EndConfirm();
    Test.assertMessage(!confirm.tap(1000), "the first tap only arms");
    Test.assertMessage(confirm.isArmed(2000), "armed within the window");
    Test.assertMessage(confirm.tap(2000), "the second one, within the window, confirms");
    Test.assertMessage(!confirm.isArmed(2100), "after confirming, it goes back to disarmed");

    var late = new EndConfirm();
    Test.assertMessage(!late.tap(1000), "arms");
    Test.assertMessage(!late.isArmed(1000 + late.WINDOW_MS + 1), "the window closed");
    Test.assertMessage(!late.tap(1000 + late.WINDOW_MS + 1), "the late tap only rearms");
    Test.assertMessage(late.tap(1000 + late.WINDOW_MS + 500), "and the next one confirms");
    return true;
}
