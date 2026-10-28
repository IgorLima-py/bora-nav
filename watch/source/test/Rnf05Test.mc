import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Test;

//! **RNF-05 locked in by a test** (C4): the distance and the maneuver arrow ≥ 55 px
//! (12% of 454), and all text ≥ 20 px (`01 §RNF-05`).
//!
//! Draws on a `BufferedBitmap` `Dc`, the same kind of surface `NavEngineTest` draws
//! on. Without `createBufferedBitmap` the test **fails loudly**:
//! a silent `return true` would be a test that never measured anything.
//!
//! **Connect IQ does not return pixels** (`getPixel` does not exist in SDK 9.2.0, measured
//! in C4), so nothing here is "count the lit pixels". The measurements are these, and the
//! test says which is which:
//! - **the arrow** is measured by the box that `tools/glifos.py` saved along with the
//!   polygons (`TurnGlyphs`, C16.5): the box and the drawing come from the same points,
//!   so they cannot disagree. The test also draws the glyph on the `Dc`, to
//!   prove the drawing runs without error. It is the largest dimension of the narrowest glyph
//!   that counts (the start, 62 px at 100%);
//! - **the text** is the font size the Hud **asked** the system for (the `px` in
//!   `tokens.json`, the same one `design_tokens.py --check` verifies), and the test
//!   checks that the `Dc` delivered a real font, with a line height
//!   (`getTextDimensions`) of at least that size. **It is not the height of the
//!   digit** (~70% of the body): RNF-05 has always been read as font body size.
//!
//! The canary (`sim.py test --canary`) makes the Hud ask for 54 px of distance, and
//! `distanceAndTextMeetTheMinimum` has to fail.
//!
//! **There is also the photo check:** `sim.py shots` photographs the screen in the
//! simulator, and `docs/STATUS.md` keeps the side-by-side with the mockup.

(:test)
module Rnf05Assert {

    const MIN_CRITICAL_PX = 55;
    const MIN_TEXT_PX = 20;
    //! The HUD scale floor (C16.5): `TEXT_FLOOR_PX` from `tools/design_tokens.py`, the smallest
    //! text of the watchface Igor uses every day (Montserrat 13 px).
    const MIN_FLOOR_TEXT_PX = 13;

    //! A `Dc` of `size` × `size`, or fails loudly.
    function canvas(size as Number) as Dc {
        Test.assertMessage(Graphics has :createBufferedBitmap,
            "no createBufferedBitmap: Rnf05Test measures nothing on this device");
        var buffer = Graphics.createBufferedBitmap({ :width => size, :height => size });
        var dc = buffer.get().getDc();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        return dc;
    }
}

//! The arrow of each maneuver type (the 31 in `05 §TURNS`, C16.5) has its largest
//! dimension ≥ 55 px, and the drawing runs on the `Dc` without error.
(:test)
function everyArrowIsAtLeast55PixelsAcross(logger as Logger) as Boolean {
    var size = 150;
    var dc = Rnf05Assert.canvas(size);
    var smallest = 1000.0;
    var smallestType = 0;

    for (var type = 0; type < TurnGlyphs.ICON_OF_TYPE.size(); type++) {
        TurnArrow.draw(dc, size / 2, size / 2, type, Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

        var bounds = TurnArrow.bounds(type);
        var width = bounds[2] - bounds[0];
        var height = bounds[3] - bounds[1];
        var across = width > height ? width : height;
        if (across < smallest) {
            smallest = across;
            smallestType = type;
        }
    }

    logger.debug("smallest arrow: type " + smallestType.toString() + " with " + smallest.format("%.1f") + " px");
    Test.assertMessage(smallest >= Rnf05Assert.MIN_CRITICAL_PX.toFloat(),
        "RNF-05: the arrow of type " + smallestType.toString() + " measures " + smallest.format("%.1f")
        + " px, the floor is " + Rnf05Assert.MIN_CRITICAL_PX.toString());
    return true;
}

//! The distance the Hud asks for is ≥ 55 px, the secondary text ≥ 20 px, and the `Dc`
//! delivered fonts with at least that body size (it did not fall back to a smaller
//! system font). It is the test the canary knocks down.
(:test)
function distanceAndTextMeetTheMinimum(logger as Logger) as Boolean {
    var dc = Rnf05Assert.canvas(200);
    var hud = new Hud();
    hud.prepare(dc);

    logger.debug("distance " + hud.requestedDistPx().toString() + " px, text "
        + hud.requestedTextPx().toString() + " px");
    Test.assertMessage(hud.requestedDistPx() >= Rnf05Assert.MIN_CRITICAL_PX,
        "RNF-05: the distance asks for " + hud.requestedDistPx().toString() + " px, the floor is "
        + Rnf05Assert.MIN_CRITICAL_PX.toString());
    Test.assertMessage(hud.requestedTextPx() >= Rnf05Assert.MIN_TEXT_PX,
        "RNF-05: the secondary text asks for " + hud.requestedTextPx().toString() + " px, the floor is "
        + Rnf05Assert.MIN_TEXT_PX.toString());

    var line = dc.getTextDimensions("8", hud.distFont());
    Test.assertMessage((line[1] as Number) >= hud.requestedDistPx(),
        "the Dc gave a font of " + (line[1] as Number).toString() + " px for the distance, asked for "
        + hud.requestedDistPx().toString());
    return true;
}

//! **The return arrow** (C11) rotates with the heading, and so has two extra rulers
//! compared to the maneuver arrows, at the 8 headings and both ends of the HUD scale:
//! what is drawn fits in the **fixed** box the card reserves for it (otherwise
//! the arrow would invade the number while rotating), and, at 100%, the tail–tip length is
//! ≥ 55 px (RNF-05; below 100% is the rider's choice, C16.5). The axis-aligned box
//! is no measure: on the diagonal it shrinks without the arrow changing size.
(:test)
function theWayBackArrowFitsItsBoxAndIsAtLeast55PixelsLong(logger as Logger) as Boolean {
    var size = 150;
    var dc = Rnf05Assert.canvas(size);
    var scales = [DesignTokens.HUD_SCALE_MIN_PCT, 100, DesignTokens.HUD_SCALE_MAX_PCT] as Array<Number>;

    for (var s = 0; s < scales.size(); s++) {
        BurnInAssert.begin(scales[s] as Number);
        var fixed = TurnArrow.bearingBounds();
        var length = TurnArrow.bearingLength();
        logger.debug("scale " + (scales[s] as Number).toString() + "%: way-back arrow of "
            + length.format("%.1f") + " px in a box of " + (fixed[2] - fixed[0]).format("%.1f") + " px");
        Test.assertMessage((scales[s] as Number) < 100 || length >= Rnf05Assert.MIN_CRITICAL_PX.toFloat(),
            "RNF-05: the way-back arrow measures " + length.format("%.1f") + " px at "
            + (scales[s] as Number).toString() + "%, the floor is " + Rnf05Assert.MIN_CRITICAL_PX.toString());

        for (var step = 0; step < 8; step++) {
            var rad = (step * Math.PI / 4).toFloat();
            TurnArrow.drawBearing(dc, size / 2, size / 2, rad, Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);

            var drawn = TurnArrow.bearingBox(rad);
            // Half a pixel of slack: the math is in 32-bit Float.
            Test.assertMessage(drawn[0] >= fixed[0] - 0.5 && drawn[1] >= fixed[1] - 0.5
                && drawn[2] <= fixed[2] + 0.5 && drawn[3] <= fixed[3] + 0.5,
                "the arrow at " + (step * 45).toString() + " degrees leaves the fixed box: ["
                + drawn[0].format("%.1f") + "," + drawn[1].format("%.1f") + ","
                + drawn[2].format("%.1f") + "," + drawn[3].format("%.1f") + "]");
        }
    }

    // The fixed box is no larger than that of the widest glyph the card already had.
    BurnInAssert.begin(100);
    var widest = 0.0;
    for (var type = 0; type < TurnGlyphs.ICON_OF_TYPE.size(); type++) {
        var bounds = TurnArrow.bounds(type);
        if (bounds[2] - bounds[0] > widest) {
            widest = bounds[2] - bounds[0];
        }
    }
    var box = TurnArrow.bearingBounds();
    Test.assertMessage(box[2] - box[0] <= widest + 0.5,
        "the way-back arrow box (" + (box[2] - box[0]).format("%.1f")
        + " px) exceeds the widest glyph one (" + widest.format("%.1f") + " px)");
    BurnInAssert.done();
    return true;
}
