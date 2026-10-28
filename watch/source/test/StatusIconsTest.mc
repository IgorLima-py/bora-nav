import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Test;

//! **The HUD status icons** (C14, `StatusIcons`, `Hud`).
//!
//! The rule for when each icon shows up is a pure function of `NavState`; the
//! drawing is provisional (C15a/b) and is only checked by where it lands.
(:test)
module StatusIconsAssert {

    function navigating() as NavState {
        var nav = new NavState();
        nav.phase = NavPhase.NAVIGATING;
        nav.hasFix = true;
        return nav;
    }
}

// prevents: the watch off the route without telling the rider what it is doing (the
// C14 `verificar:`: "no phone, weak GPS, recalculating"); each state
// has to light its icon and only its icon.
(:test)
function statusIconsFollowTheState(logger as Logger) as Boolean {
    var nav = StatusIconsAssert.navigating();
    Test.assertEqualMessage(StatusIcons.mask(nav, true), 0, "on route, good fix: no icon");

    nav.offRoute = OffRoute.REQUESTED;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), StatusIcons.RECALC, "request sent: recalculating");

    nav.offRoute = OffRoute.NO_PHONE;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), StatusIcons.NO_PHONE, "phone silent: no phone");

    nav.offRoute = OffRoute.ON_ROUTE;
    nav.weakFix = true;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), StatusIcons.WEAK_GPS, "weak fix: weak GPS");

    nav.offRoute = OffRoute.REQUESTED;
    Test.assertEqualMessage(
        StatusIcons.mask(nav, true), StatusIcons.WEAK_GPS | StatusIcons.RECALC, "both together");
    Test.assertEqualMessage(StatusIcons.count(StatusIcons.mask(nav, true)), 2, "count");
    return true;
}

// prevents: the phone vanishing (Bluetooth off, companion dead, out of range) with the rider
// on the route and the watch saying nothing until the next off-route + 10 s (RF-15,
// finding from C14's second opinion); and the icon outside navigation.
(:test)
function statusIconsShowALostLinkOnTheRoute(logger as Logger) as Boolean {
    var nav = StatusIconsAssert.navigating();
    Test.assertEqualMessage(StatusIcons.mask(nav, false), StatusIcons.NO_PHONE, "link down on route");
    nav.weakFix = true;
    Test.assertEqualMessage(
        StatusIcons.mask(nav, false), StatusIcons.NO_PHONE | StatusIcons.WEAK_GPS, "link down and weak GPS");
    nav.phase = NavPhase.IDLE;
    Test.assertEqualMessage(StatusIcons.mask(nav, false), 0, "stopped: nothing, even with no link");
    return true;
}

// prevents: an icon repeating what the card already says ("no GPS") or showing up on the
// home screen and after arrival, where the rider has nothing to act on.
(:test)
function statusIconsStayQuietOutsideNavigation(logger as Logger) as Boolean {
    var nav = StatusIconsAssert.navigating();
    nav.weakFix = true;
    nav.offRoute = OffRoute.NO_PHONE;

    nav.hasFix = false;
    Test.assertEqualMessage(
        StatusIcons.mask(nav, true), StatusIcons.NO_PHONE | StatusIcons.POS_STOPPED,
        "no fix and phone quiet: \"position stopped\"; \"weak GPS\" does not repeat \"no GPS\"");

    // prevents: the stopped-position icon lighting up just because the GPS is slow (phone talking, the map
    // still locating itself): with no fix but the phone responding, the bottom card already says "no GPS".
    nav.offRoute = OffRoute.ON_ROUTE;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), 0, "no fix, phone responding: no icon");
    Test.assertEqualMessage(
        StatusIcons.mask(nav, false), StatusIcons.NO_PHONE | StatusIcons.POS_STOPPED, "no fix and no link");
    nav.offRoute = OffRoute.NO_PHONE;

    nav.hasFix = true;
    nav.phase = NavPhase.ARRIVED;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), 0, "arrived: nothing");
    nav.phase = NavPhase.IDLE;
    Test.assertEqualMessage(StatusIcons.mask(nav, true), 0, "stopped: nothing");
    return true;
}

// prevents: the icon leaving the glass with the anti burn-in orbit, or the Hud not
// drawing what the rule says (`hud icones` is what the e2e reads).
(:test)
function statusIconsAreDrawnInsideTheGlass(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    Diag.clear();
    // No phone: since sheet 4 it is the only one the row draws.
    StatusIcons.linkOverride = 0;
    var hud = new Hud();
    var scene = BurnInAssert.scene(3);
    scene.nav.weakFix = true;
    var seen = 0;
    for (var index = 0; index < 8; index++) {
        hud.orbitOverride = index;
        hud.draw(dc, scene.route, scene.nav, scene.matcher);
        for (var i = 0; i < hud.boxes.size(); i++) {
            var box = hud.boxes[i] as Array<Number>;
            if ((box[0] as Number) == hud.BOX_ICONS) {
                seen++;
                Test.assertMessage(BurnInAssert.cornersInside(box),
                    "icons outside the glass at point " + index.toString());
            }
        }
    }
    Test.assertEqualMessage(seen, 8, "one row of icons per frame");
    Test.assertMessage(FavoritesAssert.logged("hud icons no phone,recalculating,weak gps"),
        "the log says every state, not only the row's");
    StatusIcons.linkOverride = -1;
    BurnInAssert.done();
    Diag.clear();
    return true;
}

// prevents: the Cadê covering the plate or the time (v1.1.5, sheet 6: "in a black square stuck to the right of the
// plate"), with the longest name in the scene and at both ends of the HUD scale. The current street pill
// left with the plate: the current street stays in Details.
(:test)
function theMissingPhoneSitsBesideThePlate(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var scales = [DesignTokens.HUD_SCALE_MIN_PCT, 100, DesignTokens.HUD_SCALE_MAX_PCT] as Array<Number>;
    for (var s = 0; s < scales.size(); s++) {
        BurnInAssert.begin(scales[s] as Number);
        StatusIcons.linkOverride = 0;
        var hud = new Hud();
        hud.orbitOverride = 0;
        var scene = BurnInAssert.scene(1);
        scene.nav.phase = NavPhase.NAVIGATING;
        hud.draw(dc, scene.route, scene.nav, scene.matcher);
        var icons = null;
        for (var i = 0; i < hud.boxes.size(); i++) {
            var box = hud.boxes[i] as Array<Number>;
            if ((box[0] as Number) == hud.BOX_ICONS) { icons = box; }
        }
        var where = " at " + (scales[s] as Number).toString() + "%";
        Test.assertMessage(icons != null, "the dropped phone lights the icon" + where);
        Test.assertMessage(BurnInAssert.cornersInside(icons as Array<Number>), "the no-phone icon leaves the glass" + where);
        for (var i = 0; i < hud.boxes.size(); i++) {
            var box = hud.boxes[i] as Array<Number>;
            if ((box[0] as Number) != hud.BOX_ICONS) {
                Test.assertMessage(!BurnInAssert.overlap(icons as Array<Number>, box),
                    "the no-phone icon covers element " + (box[0] as Number).toString() + where);
            }
        }
    }
    StatusIcons.linkOverride = -1;
    BurnInAssert.done();
    return true;
}

// prevents: amber back in the row (sheet 4: amber is only "turn now" and "go back to the route") and
// weak GPS, stopped position and recalculating drawn twice, in the row and in the rider's
// ring.
(:test)
function onlyTheMissingPhoneIsDrawnInTheRow(logger as Logger) as Boolean {
    var all = StatusIcons.NO_PHONE | StatusIcons.WEAK_GPS | StatusIcons.RECALC | StatusIcons.POS_STOPPED;
    Test.assertEqualMessage(StatusIcons.ROW, StatusIcons.NO_PHONE, "the row is only the no-phone icon");
    Test.assertEqualMessage(StatusIcons.width(all), StatusIcons.SIZE, "one bubble with everything lit");
    Test.assertEqualMessage(StatusIcons.width(all & ~StatusIcons.NO_PHONE), 0, "the rest goes to the ring");
    var colours = StatusIcons.colours();
    for (var i = 0; i < colours.size(); i++) {
        Test.assertMessage((colours[i] as Number) != DesignTokens.URGENT, "amber in the row");
    }

    // With weak GPS and the phone on, nothing next to the plate.
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    StatusIcons.linkOverride = 1;
    var hud = new Hud();
    var scene = BurnInAssert.scene(1);
    scene.nav.phase = NavPhase.NAVIGATING;
    scene.nav.weakFix = true;
    hud.draw(dc, scene.route, scene.nav, scene.matcher);
    for (var i = 0; i < hud.boxes.size(); i++) {
        var box = hud.boxes[i] as Array<Number>;
        Test.assertMessage((box[0] as Number) != hud.BOX_ICONS, "weak GPS does not light the row");
    }
    StatusIcons.linkOverride = -1;
    BurnInAssert.done();
    return true;
}

// prevents: the rider's ring lying about the position state (sheet 4, rider 6): full with weak GPS,
// the recalculation arc on top of the dashes, or the arrow in place of the "?" with no position at all.
(:test)
function thePuckRingFollowsThePosition(logger as Logger) as Boolean {
    var nav = StatusIconsAssert.navigating();
    Test.assertEqualMessage(MapRenderer.puckState(nav), MapRenderer.PUCK_OK, "good position: full ring");
    nav.offRoute = OffRoute.REQUESTED;
    Test.assertEqualMessage(MapRenderer.puckState(nav), MapRenderer.PUCK_RECALC, "new route on its way: the arc");
    nav.weakFix = true;
    Test.assertEqualMessage(MapRenderer.puckState(nav), MapRenderer.PUCK_WEAK, "weak GPS beats the arc");
    nav.hasFix = false;
    Test.assertEqualMessage(MapRenderer.puckState(nav), MapRenderer.PUCK_LOST, "no position: the \"?\"");
    nav.hasFix = true;
    nav.phase = NavPhase.ARRIVED;
    Test.assertEqualMessage(MapRenderer.puckState(nav), MapRenderer.PUCK_ARRIVED, "arrived: the dot in the ring");
    return true;
}
