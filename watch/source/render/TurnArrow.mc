import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

//! Maneuver glyphs (`01 §Screens`, `05 §TURNS`): **the Google Navigation SDK icons**
//! (C16.5), traced as polygons by `tools/glifos.py` and stored in [TurnGlyphs].
//!
//! Origin: `github.com/googlemaps-samples/android-navigation-samples` @ a73bfba, Apache
//! License 2.0 (`tools/glifos/google/LICENSE`, `docs/DECISIONS.md` §2026-10-17). Until C16.5
//! they were strokes drawn here (foot -> knee -> arm); Igor found the tight curve unreadable and
//! the roundabout "horrible", and Google's design already covers the 31 maneuvers, including the
//! roundabout exit at the right angle.
//!
//! Each icon has up to three colors: the **path** (the color the caller asks for, white or the
//! urgency one), the **rest** (`DesignTokens.ARROW_REST`: the roundabout ring, the other road of
//! the fork) and the **background** (holes: `fillPolygon` cannot punch a hole, so the hole is a polygon
//! in the color behind it). That is why `draw` takes both colors: `Dc` does not say which is active.
//!
//! **The size comes from `DesignTokens.ARROW_HALF`** (C4) with the arrow group's scale
//! (`Config.groupPx`, C5 and C16.5): "straight" is `2 × half` tall, and the other icons
//! keep Google's proportion relative to it. `tools/design_tokens.py` reads the same
//! polygons from `tools/glifos/glifos.json` and checks the RNF-05 floor on the mockups;
//! `Rnf05Test` checks it here.
module TurnArrow {

    //! Half-height at which the return arrow was measured until C16.5. Only the return arrow and
    //! `scale()` still use it: its fixed box is the same as before. It is in reference px (the Venu 4 45 mm):
    //! the screen scale reaches the return arrow through [half], which is already in px of this screen.
    const BASE = 22;

    //! Temporary half-height, for the small glyph of the "and then" strip (C15b). `-1`: the
    //! token's with the HUD scale. Whoever sets it resets it to `-1` right after drawing.
    var halfOverride as Number = -1;

    function half() as Number {
        return halfOverride > 0 ? halfOverride : Config.groupPx(DesignTokens.ARROW_HALF, Config.KEY_ARROW_PCT);
    }

    //! The icon index for a maneuver type; a type outside the table draws "straight".
    function icon(type as Number) as Number {
        var table = TurnGlyphs.ICON_OF_TYPE;
        if (type < 0 || type >= table.size()) {
            return table[Protocol.TURN_STRAIGHT];
        }
        return table[type];
    }

    //! Px per unit of the 0..255 frame of [TurnGlyphs].
    function unit() as Float {
        return 2.0 * half() / TurnGlyphs.REF_H;
    }

    //! Draws the glyph of type `type` centered at (`cx`, `cy`): the path in `fg`, the holes in
    //! `bg` (the color behind the glyph).
    function draw(dc as Dc, cx as Number, cy as Number, type as Number, fg as Number, bg as Number) as Void {
        paint(dc, TurnGlyphs.DATA[icon(type)], cx, cy, unit(), 1.0, 0.0, fg, bg);
    }

    //! Box of the glyph centered at (0, 0): `[x0, y0, x1, y1]`. The Hud centers the maneuver
    //! line by it and `Rnf05Test` measures the floor by it.
    function bounds(type as Number) as Array<Float> {
        var data = TurnGlyphs.DATA[icon(type)];
        var u = unit();
        var w = (data[2] - data[0]) * u / 2.0;
        var h = (data[3] - data[1]) * u / 2.0;
        return [-w, -h, w, h] as Array<Float>;
    }

    //! Radius of the **return arrow** box (C11), at the [BASE] scale: 18.5 was the half-width
    //! of the arrival target, the widest glyph the card drew. The return arrow rotates with
    //! the bearing, so its box is a fixed square: the card does not change width on every fix.
    const BEARING_RADIUS = 18.5;

    //! Tail-to-tip length of the return arrow at the [BASE] scale. It was 33.25 (2 × 18.5 minus the
    //! half thickness of the 7.5 stroke it had), which gave 55 px with v3's half-height 38.
    //! The v1.1.5 sign draws the arrow with half-height 34, and 33.25 would give 51 px: below the
    //! RNF-05 floor. With 36 it measures 55.6 px and, rotated to any bearing, still fits the 18.5 box.
    const BEARING_LENGTH = 36.0;

    //! Glyph scale: the token's `ARROW_HALF`, with the arrow group's scale, over [BASE].
    function scale() as Float {
        return half().toFloat() / BASE;
    }

    //! **Fixed** box of the return arrow centered at (0, 0): `[x0, y0, x1, y1]`. What is
    //! drawn fits in it at any bearing (`Rnf05Test` checks all 8).
    function bearingBounds() as Array<Float> {
        var r = BEARING_RADIUS * scale();
        return [-r, -r, r, r] as Array<Float>;
    }

    //! Length of the return arrow, tail to tip, in px. It is its measure for RNF-05:
    //! the axis-aligned box shrinks on the diagonal without the arrow changing size.
    function bearingLength() as Float {
        return BEARING_LENGTH * scale();
    }

    //! Px per frame unit for the return arrow: "straight" with the height of [bearingLength].
    function bearingUnit() as Float {
        var data = TurnGlyphs.DATA[icon(Protocol.TURN_STRAIGHT)];
        return bearingLength() / (data[3] - data[1]);
    }

    //! The return arrow: "straight" rotated to `rad` (0 = up, growing to the right),
    //! centered at (`cx`, `cy`). It says "the route is that way", a different sentence from the maneuver
    //! glyph's, which is why it is the straight arrow (RF-11: "straight direction to the nearest point of the route").
    function drawBearing(dc as Dc, cx as Number, cy as Number, rad as Float, fg as Number, bg as Number) as Void {
        paint(dc, TurnGlyphs.DATA[icon(Protocol.TURN_STRAIGHT)], cx, cy, bearingUnit(),
            Math.cos(rad).toFloat(), Math.sin(rad).toFloat(), fg, bg);
    }

    //! The box of what the return arrow draws at `rad`, centered at (0, 0), from the same points
    //! that [paint] rotates: the measure cannot disagree with the drawing.
    function bearingBox(rad as Float) as Array<Float> {
        var data = TurnGlyphs.DATA[icon(Protocol.TURN_STRAIGHT)];
        var u = bearingUnit();
        var cos = Math.cos(rad).toFloat();
        var sin = Math.sin(rad).toFloat();
        var ox = (data[0] + data[2]) / 2.0;
        var oy = (data[1] + data[3]) / 2.0;
        var box = [100000.0, 100000.0, -100000.0, -100000.0] as Array<Float>;
        var at = 5;
        for (var p = 0; p < data[4]; p++) {
            var count = data[at + 1];
            at += 2;
            for (var i = 0; i < count; i++) {
                var x = (data[at] - ox) * u;
                var y = (data[at + 1] - oy) * u;
                at += 2;
                var rx = x * cos - y * sin;
                var ry = x * sin + y * cos;
                if (rx < box[0]) { box[0] = rx; }
                if (ry < box[1]) { box[1] = ry; }
                if (rx > box[2]) { box[2] = rx; }
                if (ry > box[3]) { box[3] = ry; }
            }
        }
        return box;
    }

    //! Paints an icon's polygons: center of its box at (`cx`, `cy`), `u` px per unit,
    //! rotated by (`cos`, `sin`) clockwise on the screen.
    function paint(dc as Dc, data as ByteArray, cx as Number, cy as Number, u as Float,
            cos as Float, sin as Float, fg as Number, bg as Number) as Void {
        if (dc has :setAntiAlias) {
            // MapRenderer ends with anti-aliasing on; the small arrow of the "and then" strip
            // (26 px) turns into stairs without it.
            dc.setAntiAlias(true);
        }
        var ox = (data[0] + data[2]) / 2.0;
        var oy = (data[1] + data[3]) / 2.0;
        var at = 5;
        for (var p = 0; p < data[4]; p++) {
            var colour = data[at];
            var count = data[at + 1];
            at += 2;
            var points = new [count] as Array<[Numeric, Numeric]>;
            for (var i = 0; i < count; i++) {
                var x = (data[at] - ox) * u;
                var y = (data[at + 1] - oy) * u;
                at += 2;
                points[i] = [cx + round(x * cos - y * sin), cy + round(x * sin + y * cos)];
            }
            dc.setColor(colour == 0 ? fg : (colour == 1 ? DesignTokens.ARROW_REST : bg), Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon(points);
        }
    }

    function round(value as Float) as Number {
        return (value >= 0.0 ? value + 0.5 : value - 0.5).toNumber();
    }
}
