import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

//! **The home screen list** (sheet 1, "Header with the ring", approved by Igor on 2026-10-17;
//! spec in `docs/design/telas.md` §4.3). Pure: the list's keyframes, the step curve, the focus and
//! the touch. [HomeView] draws and `HomeListTest` covers the rest.
//!
//! The items move by `d = index − s`, where `s` is the list position (0 with Favorites in focus and 3
//! with Link). Each table column is a `d` from −2 to 3, and between them everything is linear.
//!
//! **The numbers here are px of the reference screen** (the 454 px Venu 4 45 mm): the tables, the card, the
//! drag distances. [HomeView] scales what it draws and [HomeDelegate] what it measures, both with [Screen];
//! only [hit] and [chordAt], which take a coordinate of the touch or of the screen, work in px of this screen.
module HomeList {
    const FAVORITES = 0;
    const RECENTS = 1;
    const SETTINGS = 2;
    const LINK = 3;
    const COUNT = 4;

    //! The three motions of the language (rule 7): the list moves 240 ms per step, the ring closes in
    //! 760 ms and the request arc makes one turn every 1.6 s. The step was 280 ms until `v1.2.0`.
    const STEP_MS = 240;
    const SWEEP_MS = 760;
    const SPIN_MS = 1600;

    //! **The list follows the finger** (Igor, 2026-10-18, on `v1.2.0`: "the scroll [...] is kind of clunky and
    //! awkward, kind of slow and stiff"). The finger moves 110 px per item, the gap between the focused text
    //! (y 250) and the one below (y 358); under 10 px is a tap. Past the end, the list moves one
    //! third of the finger, up to 0.3 of an item, and goes back on release.
    const DRAG_PX = 110;
    const DRAG_SLOP_PX = 10;
    const RUBBER = 0.35;
    const OVERSCROLL = 0.3;

    //! The `d` of the first column of the tables.
    const D_MIN = -2;
    const ICON_X = [100, 100, 100, 112, 128, 140] as Array<Number>;
    const ICON_Y = [30, 132, 246, 347, 405, 460] as Array<Number>;
    const ICON_PX = [24, 30, 50, 32, 26, 20] as Array<Number>;
    const ICON_OP = [0.0, 0.55, 1.0, 1.0, 0.0, 0.0] as Array<Float>;
    const TEXT_X = [136, 136, 140, 148, 160, 168] as Array<Number>;
    const TEXT_BASE = [40, 143, 250, 358, 414, 470] as Array<Number>;
    const TEXT_PX = [24, 30, 44, 32, 26, 22] as Array<Number>;
    const TEXT_OP = [0.0, 1.0, 1.0, 1.0, 1.0, 0.0] as Array<Float>;
    //! Only the `d` = 0 column is bold, and only it is white.
    const TEXT_COLOR = [DesignTokens.NEAR_TEXT, DesignTokens.NEAR_TEXT, DesignTokens.PRIMARY,
        DesignTokens.SECONDARY, DesignTokens.ARROW_REST, DesignTokens.ARROW_REST] as Array<Number>;

    //! The focused card, which does not move.
    const CARD_X = 45;
    const CARD_Y = 182;
    const CARD_W = 358;
    const CARD_H = 128;
    const CARD_R = 22;

    //! What the touch hit: the focused card, the neighbor below or the one above.
    const HIT_NONE = -9;
    const HIT_PREVIOUS = -1;
    const HIT_CARD = 0;
    const HIT_NEXT = 1;

    //! The value of table `table` at `d`, linear between the columns and clamped at the ends.
    function at(table as Array, d as Float) as Float {
        var x = d - D_MIN;
        var last = table.size() - 1;
        if (x <= 0.0) {
            return (table[0] as Numeric).toFloat();
        }
        if (x >= last) {
            return (table[last] as Numeric).toFloat();
        }
        var i = x.toNumber();
        var t = x - i;
        var a = (table[i] as Numeric).toFloat();
        var b = (table[i + 1] as Numeric).toFloat();
        return a + (b - a) * t;
    }

    //! The column nearest to `d`: decides the bold, which only the focused item has.
    function nearest(d as Float) as Number {
        var i = (d - D_MIN + 0.5).toNumber();
        if (d - D_MIN + 0.5 < 0.0) {
            i = 0;
        }
        return i < 0 ? 0 : (i > 5 ? 5 : i);
    }

    //! The text size at `d`, in steps of 2 px. Until `v1.2.0` it switched at half the step (from
    //! 44 to 32 px at once); in steps of 2 it moves with the list, and the faces created are few
    //! (22 to 44 px) and kept in [HomeView].
    function textPx(d as Float) as Number {
        return ((at(TEXT_PX, d) / 2.0 + 0.5).toNumber()) * 2;
    }

    //! The text color at `d`: the mix of the two neighboring columns, darkened by the opacity.
    function textColor(d as Float) as Number {
        var x = d - D_MIN;
        var i = x <= 0.0 ? 0 : (x >= 5.0 ? 4 : x.toNumber());
        var t = x <= 0.0 ? 0.0 : (x >= 5.0 ? 1.0 : x - i);
        var color = mix(TEXT_COLOR[i] as Number, TEXT_COLOR[i + 1] as Number, t);
        return dim(color, at(TEXT_OP, d));
    }

    //! Channel-by-channel mix from `a` (t = 0) to `b` (t = 1).
    function mix(a as Number, b as Number, t as Float) as Number {
        var r = ((a >> 16) & 0xFF) + ((((b >> 16) & 0xFF) - ((a >> 16) & 0xFF)) * t).toNumber();
        var g = ((a >> 8) & 0xFF) + ((((b >> 8) & 0xFF) - ((a >> 8) & 0xFF)) * t).toNumber();
        var bl = (a & 0xFF) + (((b & 0xFF) - (a & 0xFF)) * t).toNumber();
        return (r << 16) | (g << 8) | bl;
    }

    //! Opacity over black: multiply the RGB by the factor. The background is black, so no alpha
    //! is needed.
    function dim(color as Number, factor as Float) as Number {
        if (factor >= 1.0) {
            return color;
        }
        if (factor <= 0.0) {
            return 0;
        }
        return mix(0, color, factor);
    }

    //! The language's curve, `cubic-bezier(.16, .84, .24, 1)`, with `t` from 0 to 1. Bisection finds the
    //! curve parameter whose x is `t` and returns its y.
    function ease(t as Float) as Float {
        if (t <= 0.0) {
            return 0.0;
        }
        if (t >= 1.0) {
            return 1.0;
        }
        var lo = 0.0;
        var hi = 1.0;
        var u = t;
        for (var i = 0; i < 14; i++) {
            u = (lo + hi) / 2;
            if (bezier(u, 0.16, 0.24) < t) {
                lo = u;
            } else {
                hi = u;
            }
        }
        return bezier((lo + hi) / 2, 0.84, 1.0);
    }

    //! A coordinate of the cubic from (0, 0) to (1, 1) with the two control points `p1` and `p2`.
    function bezier(u as Float, p1 as Float, p2 as Float) as Float {
        var v = 1.0 - u;
        return 3 * v * v * u * p1 + 3 * v * u * u * p2 + u * u * u;
    }

    //! The list step: cubic ease-out, `1 − (1 − t)³`. The rule 7 curve ([ease]) did 68% of the
    //! way in the first 50 ms frame and spent the other four on the remaining 32%: the list
    //! jumped and then dragged. This one, in 240 ms, does 50%, 80%, 95% and 99.5% on each frame.
    function stepEase(t as Float) as Float {
        if (t <= 0.0) {
            return 0.0;
        }
        if (t >= 1.0) {
            return 1.0;
        }
        var v = 1.0 - t;
        return 1.0 - v * v * v;
    }

    //! The list position for the finger at `raw`, unclamped: between 0 and 3 it is `raw` itself; outside, the
    //! rubber band ([RUBBER], up to [OVERSCROLL]).
    function rubber(raw as Float) as Float {
        var top = (COUNT - 1).toFloat();
        if (raw < 0.0) {
            var over = -raw * RUBBER;
            return -(over > OVERSCROLL ? OVERSCROLL : over);
        }
        if (raw > top) {
            var over = (raw - top) * RUBBER;
            return top + (over > OVERSCROLL ? OVERSCROLL : over);
        }
        return raw;
    }

    //! Where the list stops when the finger lifts: the nearest item, pulled 0.35 of a step in the direction of the
    //! drag (`moved`, in items), so a short drag already switches item.
    function snap(s as Float, moved as Float) as Number {
        var bias = moved > 0.08 ? 0.35 : (moved < -0.08 ? -0.35 : 0.0);
        return clampFocus(Math.floor(s + bias + 0.5).toNumber());
    }

    //! The focus without wrapping around: from Favorites it does not go up, from Link it does not go down.
    function clampFocus(focus as Number) as Number {
        return focus < 0 ? 0 : (focus >= COUNT ? COUNT - 1 : focus);
    }

    //! What the touch at `y` (px of this screen) hit (§4.4): the card opens the focused item; the neighbor below
    //! and the one above move one step. The gap between them does nothing, so a glove does not open the wrong
    //! screen. The card edges are those [HomeView] draws, scaled the same way.
    function hit(y as Number) as Number {
        var cardTop = Screen.px(CARD_Y);
        if (y >= cardTop && y <= cardTop + Screen.px(CARD_H)) {
            return HIT_CARD;
        }
        if (y >= Screen.px(320) && y <= Screen.px(380)) {
            return HIT_NEXT;
        }
        if (y >= Screen.px(110) && y <= Screen.px(170)) {
            return HIT_PREVIOUS;
        }
        return HIT_NONE;
    }

    //! **The status line fits the glass** (C16, 2026-10-17 bench: "the requesting-route text gets
    //! cut off"). "Requesting route · " plus the favorite's name went past the chord of the round screen. It tries
    //! the fonts in order, and only then cuts the end with "…". Returns `[font, text]`.
    function fitState(dc as Dc, text as String, fonts as Array<Graphics.FontType>, maxWidth as Number) as Array {
        for (var i = 0; i < fonts.size(); i++) {
            if (dc.getTextWidthInPixels(text, fonts[i]) <= maxWidth) {
                return [fonts[i], text];
            }
        }
        var font = fonts[fonts.size() - 1];
        var keep = text.length();
        while (keep > 1 && dc.getTextWidthInPixels(text.substring(0, keep) + "…", font) > maxWidth) {
            keep--;
        }
        return [font, text.substring(0, keep) + "…"];
    }

    //! Width of the circle of radius `r`, centered on the glass, at height `y`; `y` and `r` in px of this screen.
    function chordAt(y as Numeric, r as Number) as Number {
        var dy = y - Screen.half;
        var squared = r * r - dy * dy;
        return squared > 0 ? (Math.sqrt(squared.toFloat()) * 2).toNumber() : 0;
    }
}
