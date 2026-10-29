import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;

//! The HUD status icons (C14): **no phone**, **weak GPS**, **recalculating**
//! and, since C15b, **stalled position**, in a row above the bottom card.
//!
//! The design is sheet 4 (2026-10-17): the row only holds no-phone, the faded "?" in the
//! dashed ring (the no-phone icon), on a `#1E252B` bubble, no amber. The other three states moved to
//! the rider's ring ([ROW]). `Dc` primitives, no bitmap: what C14 closes is the rule for
//! when each state shows up, which the street will check and the PC already proves (`StatusIconsTest`).
//!
//! The rule lives here, not in `Hud`, so the test does not need a `Dc`:
//! - **no phone**: the phone link dropped (`phoneConnected` false, RF-15
//!   "link loss shows a discreet icon") **or** off route and the phone did not
//!   answer within 10 s (`OffRoute.NO_PHONE`: the link may be up and the phone
//!   app dead, which the watch cannot tell from the link);
//! - **recalculating**: off route, request sent (`OffRoute.REQUESTED`);
//! - **weak GPS**: there is a position, but it is weak (`NavState.weakFix`). With
//!   no position at all the bottom card already says "no GPS", and the icon would repeat it;
//! - **stalled position** (C15b): no position **and** the phone silent — neither the
//!   watch nor the phone says where the bike is, and the map does not move.
//!
//! Nothing shows outside navigation: idle on the home screen or after arrival
//! the watch is doing nothing the rider needs to check.
module StatusIcons {

    const NO_PHONE = 1;
    const WEAK_GPS = 2;
    const RECALC = 4;
    const POS_STOPPED = 8;

    //! Bubble diameter and gap between two, in reference px (`tokens_waze.json`: `icone_bolha` 34): the
    //! Venu 4 45 mm's. What is drawn and measured is [size] and [gap], through [Screen.px].
    const SIZE = 34;
    const GAP = 8;

    //! The dashed ring and the no-phone "?" inside the 34 bubble (sheet 4): radius 15, stroke 3 and the
    //! 190 `Signs` frame at 23 px (all in reference px, converted when drawn).
    const RING_R = 15;
    const STROKE = 3;
    const DASHES = 24;
    const DASH_DEG = 6;
    const SIGN_PX = 23;

    //! `-1`: reads the device; `0`/`1`: the test forces the link (the simulator does not
    //! control it). Outside `:test` nobody writes here.
    var linkOverride as Number = -1;

    //! Is the watch connected to the phone now? Without the API, loss is not claimed.
    function phoneLinked() as Boolean {
        if (linkOverride >= 0) {
            return linkOverride == 1;
        }
        var settings = System.getDeviceSettings();
        if (settings has :phoneConnected) {
            return settings.phoneConnected;
        }
        return true;
    }

    //! The set of icons the state asks for, as bits.
    function mask(nav as NavState, linked as Boolean) as Number {
        if (nav.phase != NavPhase.NAVIGATING) {
            return 0;
        }
        var bits = 0;
        if (!linked || nav.offRoute == OffRoute.NO_PHONE) {
            bits |= NO_PHONE;
        }
        if (nav.offRoute == OffRoute.REQUESTED) {
            bits |= RECALC;
        }
        if (nav.hasFix && nav.weakFix) {
            bits |= WEAK_GPS;
        }
        if (!nav.hasFix && (!linked || nav.offRoute == OffRoute.NO_PHONE)) {
            bits |= POS_STOPPED;
        }
        return bits;
    }

    function count(bits as Number) as Number {
        var n = 0;
        if ((bits & NO_PHONE) != 0) { n++; }
        if ((bits & WEAK_GPS) != 0) { n++; }
        if ((bits & RECALC) != 0) { n++; }
        if ((bits & POS_STOPPED) != 0) { n++; }
        return n;
    }

    //! **What the row draws** (sheet 4, 2026-10-17): only no-phone. Weak GPS, stalled position
    //! and recalculating stay in [mask] and in the log, but the rider's ring shows them
    //! (`MapRenderer.puckState`): the state sits where the eye already is.
    const ROW = NO_PHONE;

    //! The bubble diameter and the gap between two, in px of this screen.
    function size() as Number {
        return Screen.px(SIZE);
    }

    function gap() as Number {
        return Screen.px(GAP);
    }

    //! Row width for the [mask] bits, in px of this screen.
    function width(bits as Number) as Number {
        var n = count(bits & ROW);
        return n == 0 ? 0 : n * size() + (n - 1) * gap();
    }

    //! The log text (`hud icones ...`), only when it changes: it is what the e2e reads.
    function label(bits as Number) as String {
        if (bits == 0) {
            return "none"; // lang: log
        }
        var text = "";
        if ((bits & NO_PHONE) != 0) { text += "no phone"; } // lang: log
        if ((bits & RECALC) != 0) { text += (text.length() > 0 ? "," : "") + "recalculating"; }
        if ((bits & WEAK_GPS) != 0) { text += (text.length() > 0 ? "," : "") + "weak gps"; }
        if ((bits & POS_STOPPED) != 0) { text += (text.length() > 0 ? "," : "") + "position stopped"; }
        return text;
    }

    //! Draws the row with the top-left corner at `(x, top)`, for the [mask] bits.
    function draw(dc as Dc, bits as Number, x as Number, top as Number) as Void {
        if ((bits & NO_PHONE) != 0) {
            bubble(dc, x, top);
            var half = size() / 2;
            noPhone(dc, x + half, top + half);
        }
        dc.setPenWidth(1);
    }

    function bubble(dc as Dc, x as Number, y as Number) as Void {
        var half = size() / 2;
        dc.setColor(DesignTokens.ICON_BUBBLE, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x + half, y + half, half);
    }

    //! The colors the row uses, so `StatusIconsTest` can check that amber is gone.
    function colours() as Array<Number> {
        return [DesignTokens.ICON_BUBBLE, DesignTokens.RING_OFF, DesignTokens.SIGN_OFF,
            DesignTokens.ARROW_REST] as Array<Number>;
    }

    //! **Where's the phone?**, the no-phone of sheet 4: the faded "?" in the dashed ring, the same as the home
    //! screen and the phone. The ring-with-sign measures (side 34): radius 0.434, stroke 0.092 and
    //! sign 0.684 of the side; the sheet's dashing (stroke 0.45 and gap 0.9 of the stroke) in 24 strokes of
    //! 1.6 px, with butt caps.
    function noPhone(dc as Dc, cx as Number, cy as Number) as Void {
        var radius = Screen.px(RING_R);
        dc.setColor(DesignTokens.RING_OFF, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(Screen.px(STROKE));
        for (var i = 0; i < DASHES; i++) {
            var a = i * 360 / DASHES;
            dc.drawArc(cx, cy, radius, Graphics.ARC_COUNTER_CLOCKWISE, a, a + DASH_DEG);
        }
        Signs.draw(dc, Signs.QUESTION, Signs.QUESTION_DOT, cx, cy, Screen.px(SIGN_PX), DesignTokens.SIGN_OFF,
            DesignTokens.ARROW_REST);
    }
}
