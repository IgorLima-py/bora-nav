import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Test;

//! **The warning sign** (v1.1.5, sheet 6, option 12): the sign fits the glass chord with any
//! name, the name steps down the size ladder before breaking into two lines, and the sign turns amber
//! at 60 m from the turn and on "volte para a rota" (back to the route).

(:test)
module PlateAssert {

    //! A name of `n` characters, with no trailing space, cut from a really long name.
    function name(n as Number) as String {
        var base = "Rua Doutor Arnaldo Vieira de Carvalho Mesquita Barbosa";
        var cut = base.substring(0, n) as String;
        while (cut.length() > 1 && cut.substring(cut.length() - 1, cut.length()).equals(" ")) {
            cut = cut.substring(0, cut.length() - 1) as String;
        }
        return cut;
    }

    //! The scene with the rider matched on the route, `metres` before the 3rd maneuver (the left one at y 40 km).
    function before(metres as Float) as BurnInScene {
        var scene = BurnInAssert.scene(0);
        scene.nav.phase = NavPhase.NAVIGATING;
        scene.nav.applyFix(0.0, 40000.0 - metres, 18.0, 1.2);
        scene.matcher.update(0.0, 40000.0 - metres);
        return scene;
    }
}

// prevents: a long name pushing the frame out of the round glass (a sign cut by the edge
// stops being a sign), or the name going past the sign, at both ends of the HUD scale and the middle, with
// the tight sign (the default) and the tall one (100% height, the largest the breathing room allows).
(:test)
function thePlateFitsTheGlassForAnyName(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var scales = [DesignTokens.HUD_SCALE_MIN_PCT, 100, DesignTokens.HUD_SCALE_MAX_PCT] as Array<Number>;
    var talls = [0, 100] as Array<Number>;
    var checked = 0;
    for (var t = 0; t < talls.size(); t++) {
    for (var s = 0; s < scales.size(); s++) {
        for (var n = 5; n <= 40; n += 5) {
            BurnInAssert.begin(scales[s] as Number);
            Config.values[Config.KEY_PLATE_H_PCT - 1] = talls[t] as Number;
            Config.revision++;
            var scene = PlateAssert.before(800.0);
            var text = PlateAssert.name(n);
            scene.route.turnName = [text, text, text, text] as Array<String>;
            var hud = new Hud();
            hud.orbitOverride = 0;
            hud.draw(dc, scene.route, scene.nav, scene.matcher);
            var where = (scales[s] as Number).toString() + "% height " + (talls[t] as Number).toString()
                + "% name of " + n.toString();
            var plate = 0;
            for (var i = 0; i < hud.boxes.size(); i++) {
                var box = hud.boxes[i] as Array<Number>;
                var kind = box[0] as Number;
                if (kind == hud.BOX_ROW || kind == hud.BOX_STREET) {
                    plate++;
                    Test.assertMessage(BurnInAssert.cornersInside(box),
                        "the plate leaves the glass at " + where + " (element " + kind.toString() + ")");
                }
            }
            Test.assertEqualMessage(plate, 2, "the plate has both lines at " + where);
            Test.assertMessage(hud.nameShown.size() >= 1, "the name vanishes at " + where);
            for (var i = 0; i < hud.nameShown.size(); i++) {
                Test.assertMessage((hud.nameShown[i] as String).length() > 0, "empty line at " + where);
            }
            checked++;
        }
    }
    }
    logger.debug("plates checked: " + checked.toString());
    BurnInAssert.done();
    return true;
}

// prevents: the name shrinking below the sign floor (22 px on one line) instead of breaking, or breaking
// into two lines a short name that fit whole.
(:test)
function theStreetNameStepsDownThenBreaksInTwo(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    var start = Config.groupPx(DesignTokens.STREET_PX, Config.KEY_TEXT_PCT);
    var floor = Config.groupPx(DesignTokens.STREET_MIN_PX, Config.KEY_TEXT_PCT);
    var two = Config.groupPx(DesignTokens.STREET_TWO_PX, Config.KEY_TEXT_PCT);
    var last = start;
    var sawOne = false;
    var sawTwo = false;
    for (var n = 5; n <= 40; n++) {
        var scene = PlateAssert.before(800.0);
        var text = PlateAssert.name(n);
        scene.route.turnName = [text, text, text, text] as Array<String>;
        var hud = new Hud();
        hud.draw(dc, scene.route, scene.nav, scene.matcher);
        var px = hud.namePxShown;
        var lines = hud.nameShown.size();
        var where = " with \"" + text + "\"";
        if (n == 5) {
            Test.assertEqualMessage(px, start, "a short name goes at the starting size" + where);
            Test.assertEqualMessage(lines, 1, "a short name goes on one line" + where);
        }
        if (lines == 2) {
            sawTwo = true;
            Test.assertEqualMessage(px, two, "two lines go at the two-line size" + where);
        } else {
            sawOne = true;
            Test.assertMessage(!sawTwo, "went back to one line after wrapping" + where);
            Test.assertMessage(px >= floor && px <= start, "one line outside the ladder" + where);
            Test.assertMessage(px <= last, "the name grew with more letters" + where);
            last = px;
        }
    }
    Test.assertMessage(sawOne && sawTwo, "the ladder did not reach two lines with 40 characters");
    BurnInAssert.done();
    return true;
}

// prevents: the sign turning petrol in the "vire agora" (turn now) window, or amber far from it: amber is only at 60 m
// from the turn and on "volte para a rota" (sheet 6), and its ink is black.
(:test)
function thePlateTurnsAmberOnlyWhenItMatters(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    var hud = new Hud();

    var far = PlateAssert.before(75.0);
    hud.draw(dc, far.route, far.nav, far.matcher);
    Test.assertEqualMessage(hud.plateShown, DesignTokens.PLATE, "at 75 m the plate is petrol");

    var near = PlateAssert.before(55.0);
    hud.draw(dc, near.route, near.nav, near.matcher);
    Test.assertEqualMessage(hud.plateShown, DesignTokens.URGENT, "at 55 m the plate is amber");

    var off = BurnInAssert.scene(3);
    hud.draw(dc, off.route, off.nav, off.matcher);
    Test.assertEqualMessage(hud.plateShown, DesignTokens.URGENT, "on the return-to-route the plate is amber");
    Test.assertEqualMessage(hud.nameShown[0], "Recalculando…", "the bottom line says what the watch is doing");

    var waiting = BurnInAssert.scene(0);
    hud.draw(dc, waiting.route, waiting.nav, waiting.matcher);
    Test.assertEqualMessage(hud.plateShown, DesignTokens.CARD, "with no GPS the plate is slate");
    Test.assertEqualMessage(hud.nameShown.size(), 0, "with no GPS the plate has a single line");

    var arrived = BurnInAssert.scene(2);
    hud.draw(dc, arrived.route, arrived.nav, arrived.matcher);
    Test.assertEqualMessage(hud.plateShown, DesignTokens.PLATE, "on arrival the plate is petrol");
    Test.assertEqualMessage(hud.nameShown[0], "Aeroporto de Congonhas", "the destination on the bottom line");
    BurnInAssert.done();
    return true;
}

// prevents: the sign writing "Avenida" in full and wasting the glass (sheet 6): the abbreviation reaches the screen.
(:test)
function thePlateWritesAvenueShort(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    BurnInAssert.begin(100);
    var scene = PlateAssert.before(800.0);
    scene.route.turnName = ["Avenida Paulista", "Avenida Paulista", "Avenida Paulista", "Avenida Paulista"]
        as Array<String>;
    var hud = new Hud();
    hud.draw(dc, scene.route, scene.nav, scene.matcher);
    Test.assertEqualMessage(hud.nameShown[0], "Av. Paulista", "the plate abbreviates");
    Test.assertEqualMessage(scene.route.turnName[2], "Avenida Paulista", "the route keeps the full name");
    BurnInAssert.done();
    return true;
}

// prevents: the sign's breathing room (v1.1.5, CONFIG 14 and 15) changing the size of any letter, one axis
// squeezing the other, or the tight sign leaving the glass. Each axis only shrinks its own side of the sign.
(:test)
function thePlateSqueezesEachWayWithoutTouchingTheFonts(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(BurnInAssert.SIZE);
    var cases = [[100, 100], [0, 100], [100, 0], [0, 0]] as Array<Array<Number>>;
    var sizes = [] as Array<Array<Number>>;
    for (var c = 0; c < cases.size(); c++) {
        var wide = (cases[c] as Array<Number>)[0] as Number;
        var tall = (cases[c] as Array<Number>)[1] as Number;
        BurnInAssert.begin(100);
        Config.values[Config.KEY_PLATE_W_PCT - 1] = wide;
        Config.values[Config.KEY_PLATE_H_PCT - 1] = tall;
        Config.revision++;
        var scene = PlateAssert.before(800.0);
        scene.route.turnName = ["Rua Augusta", "Rua Augusta", "Rua Augusta", "Rua Augusta"] as Array<String>;
        var hud = new Hud();
        hud.orbitOverride = 0;
        hud.draw(dc, scene.route, scene.nav, scene.matcher);
        var row = [] as Array<Number>;
        var street = [] as Array<Number>;
        for (var i = 0; i < hud.boxes.size(); i++) {
            var box = hud.boxes[i] as Array<Number>;
            if ((box[0] as Number) == hud.BOX_ROW) {
                row = box;
            } else if ((box[0] as Number) == hud.BOX_STREET) {
                street = box;
            }
        }
        var where = "width " + wide.toString() + "% height " + tall.toString() + "%";
        Test.assertMessage(row.size() == 5 && street.size() == 5, "the plate has both lines at " + where);
        Test.assertMessage(BurnInAssert.cornersInside(row) && BurnInAssert.cornersInside(street),
            "the plate leaves the glass at " + where);
        Test.assertEqualMessage(hud.nameShown[0], "R. Augusta", "the full name, abbreviated, at " + where);
        sizes.add([(row[3] as Number) - (row[1] as Number), (row[4] as Number) - (row[2] as Number),
            (street[4] as Number) - (street[2] as Number), hud.namePxShown] as Array<Number>);
        logger.debug(where + ": plate " + (sizes[c] as Array<Number>)[0].toString() + " x "
            + ((sizes[c] as Array<Number>)[1] + (sizes[c] as Array<Number>)[2]).toString() + " px (lines "
            + (sizes[c] as Array<Number>)[1].toString() + " and " + (sizes[c] as Array<Number>)[2].toString() + ")");
        BurnInAssert.done();
    }
    var full = sizes[0] as Array<Number>;
    var narrow = sizes[1] as Array<Number>;
    var low = sizes[2] as Array<Number>;
    var both = sizes[3] as Array<Number>;
    Test.assertMessage((narrow[0] as Number) < (full[0] as Number), "width at 0% did not narrow the plate");
    Test.assertEqualMessage(narrow[1], full[1], "width changed the height of the top line");
    Test.assertEqualMessage(narrow[2], full[2], "width changed the height of the name line");
    Test.assertEqualMessage(low[0], full[0], "height changed the width");
    Test.assertMessage((low[1] as Number) < (full[1] as Number), "height at 0% did not lower the top line");
    Test.assertMessage((low[2] as Number) < (full[2] as Number), "height at 0% did not lower the name line");
    Test.assertEqualMessage(both[0], narrow[0], "both at 0%: the width is the one of its own axis");
    Test.assertEqualMessage(both[1], low[1], "both at 0%: the height is the one of its own axis");
    for (var c = 1; c < sizes.size(); c++) {
        Test.assertEqualMessage((sizes[c] as Array<Number>)[3], full[3], "the name size changed with the breathing room");
    }
    return true;
}
