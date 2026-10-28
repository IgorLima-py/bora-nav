import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! With `true`, the home screen does not turn on its timer: it stays still, with no sweep or spinning arc.
//! Only `DemoFeed` turns it on, while it injects the SP messages: its timer, the app's, the
//! `scheduleCatchUp` one and this screen's made four, and the simulator brought the demo down with "Too Many
//! Timers Error" in `scheduleCatchUp` (measured on 2026-10-22, SDK 9.3.0 on macOS). In the real app
//! it is `false`: there is no `DemoFeed` there, and the three fit.
var homeTimerLent as Boolean = false;

//! **The Bora? home screen** (sheet 1, "Header with the ring", approved by Igor on 2026-10-17;
//! spec in `docs/design/telas.md` §4). Before it came the three C16.5 buttons (Favorites,
//! Recents and Settings, in pills), which this screen replaces.
//!
//! - **The edge ring** is the link to the phone: solid cyan when ready, a spinning cyan arc
//!   while requesting a route, dashed gray with no phone. On opening, it sweeps the full turn in 760 ms.
//! - **The header** (only with the list at the top) carries the drawn brand and the status line.
//! - **The list** has four items; the focused item lives in a card that does not move, and the others move
//!   along the [HomeList] keyframes. Link, the last one, keeps the rx, the ack and the version: it is the line
//!   that says which side the silence is on when the transfer fails.
//!
//! Timers: just one, and only on while there is something to animate (the sweep, a list step or the request
//! arc). The app already has three possible timers, and the doc's ceiling is three at the same time ("The number
//! of available timers (default 3)", SDK 9.2.0): with this screen up, the map menu one does not run.
//! The simulator demo has a fourth, `DemoFeed`'s, and so borrows this screen's
//! ([homeTimerLent]).
class HomeView extends WatchUi.View {

    enum {
        RING_READY = 0,
        RING_WORKING = 1,
        RING_NO_PHONE = 2
    }

    //! The timer period: 50 ms is the doc's minimum; the request arc alone runs at 10 frames
    //! per second.
    const FRAME_MS = 50;
    const SPIN_FRAME_MS = 100;

    private var _focus as Number = 0;
    private var _s as Float = 0.0;
    private var _stepFrom as Float = 0.0;
    private var _stepStart as Number = -1;
    private var _sweepStart as Number = -1;
    private var _timer as Timer.Timer?;
    private var _timerMs as Number = 0;
    //! The finger is on the screen and the list follows it ([dragTo]); on release, [release] takes it to the item.
    private var _dragging as Boolean = false;
    //! The frame cost while the list moves, for the log: `home frame avg 31ms peak 48ms n12`.
    private var _frameSum as Number = 0;
    private var _frameMax as Number = 0;
    private var _frames as Number = 0;
    //! The status line measured in the last frame: measuring the text width on every frame is expensive.
    private var _fitText as String = "";
    private var _fit as Array = [] as Array;
    //! The header gradient, computed once: the color of each 2 px band and the half chord of the
    //! circle of radius 207 on each screen row.
    private var _bands as Array<Number> = [] as Array<Number>;
    private var _halfChord as Array<Number> = [] as Array<Number>;

    private var _mark as WatchUi.BitmapResource?;
    private var _fonts as Dictionary<String, Graphics.FontType> = {} as Dictionary<String, Graphics.FontType>;
    private var _ascents as Dictionary<String, Number> = {} as Dictionary<String, Number>;

    private var _ready as String = "";
    private var _noPhone as String = "";
    private var _titles as Array<String> = ["", "", "", ""] as Array<String>;
    private var _settingsHint as String = "";
    private var _openLog as String = "";
    //! "No place", "1 place", "$1$ places" and the same for destinations: loaded once, because
    //! the list redraws at 20 frames per second while it moves.
    private var _counts as Array<String> = [] as Array<String>;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Dc) as Void {
        _mark = WatchUi.loadResource(Rez.Drawables.HeaderMark) as WatchUi.BitmapResource;
        _ready = WatchUi.loadResource(Rez.Strings.WaitingRoute) as String;
        _noPhone = WatchUi.loadResource(Rez.Strings.NoPhone) as String;
        _settingsHint = WatchUi.loadResource(Rez.Strings.SettingsHint) as String;
        _openLog = WatchUi.loadResource(Rez.Strings.OpenLog) as String;
        _counts = [
            WatchUi.loadResource(Rez.Strings.PlacesNone) as String,
            WatchUi.loadResource(Rez.Strings.PlacesOne) as String,
            WatchUi.loadResource(Rez.Strings.PlacesCount) as String,
            WatchUi.loadResource(Rez.Strings.DestinationsNone) as String,
            WatchUi.loadResource(Rez.Strings.DestinationsOne) as String,
            WatchUi.loadResource(Rez.Strings.DestinationsCount) as String,
        ] as Array<String>;
        _titles = [
            WatchUi.loadResource(Rez.Strings.FavoritesItem) as String,
            WatchUi.loadResource(Rez.Strings.RecentsItem) as String,
            WatchUi.loadResource(Rez.Strings.SettingsItem) as String,
            WatchUi.loadResource(Rez.Strings.LinkItem) as String,
        ] as Array<String>;
        _bands = [] as Array<Number>;
        for (var y = 0; y < 205; y += 2) {
            _bands.add(y <= 113
                ? HomeList.mix(DesignTokens.PILL, DesignTokens.HEADER_MID, y / 113.0)
                : HomeList.mix(DesignTokens.HEADER_MID, 0, (y - 113) / 92.0));
        }
        _halfChord = [] as Array<Number>;
        for (var y = 0; y <= 454; y++) {
            _halfChord.add(HomeList.chordAt(y, 207) / 2);
        }
        // The faces the list uses while moving (in steps of 2 px, [HomeList.textPx]): created here, so the
        // first drag does not pay for them in the middle of the movement.
        for (var px = 22; px <= 38; px += 2) {
            font(false, px);
        }
        for (var px = 38; px <= 44; px += 2) {
            font(true, px);
        }
    }

    //! **The focus goes back to Favorites on every `onShow`**, so Enter with a glove keeps opening
    //! Favorites; and the ring sweeps the full turn again, unless there is no phone.
    function onShow() as Void {
        _focus = HomeList.FAVORITES;
        _s = 0.0;
        _stepFrom = 0.0;
        _stepStart = -1;
        _dragging = false;
        _sweepStart = ringState() == RING_READY ? System.getTimer() : -1;
        schedule();
    }

    function onHide() as Void {
        stopTimer();
        _dragging = false;
    }

    //! The focused item (the step's destination, if it is moving).
    function focus() as Number {
        return _focus;
    }

    //! One step down (+1) or up (−1), without wrapping around. Taps in a row during a
    //! step shorten the path, with no queue: the new step starts from where the list is.
    function move(delta as Number) as Void {
        var target = HomeList.clampFocus(_focus + delta);
        if (target == _focus) {
            return;
        }
        advance(System.getTimer());
        _stepFrom = _s;
        _focus = target;
        _stepStart = System.getTimer();
        schedule();
        WatchUi.requestUpdate();
    }

    //! The list position now (`s`, in items), where the drag starts from.
    function position() as Float {
        advance(System.getTimer());
        return _s;
    }

    //! The finger on the screen: the list goes to `s` (already with the rubber band) without animating.
    function dragTo(s as Float) as Void {
        _dragging = true;
        _stepStart = -1;
        _s = s;
        _focus = HomeList.clampFocus(Math.floor(s + 0.5).toNumber());
        WatchUi.requestUpdate();
    }

    //! The finger left: the list moves from where it is to the [HomeList.snap] item. `moved` is how much the
    //! drag moved, in items, and decides the direction.
    function release(moved as Float) as Void {
        _dragging = false;
        _stepFrom = _s;
        _focus = HomeList.snap(_s, moved);
        _stepStart = System.getTimer();
        schedule();
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var now = System.getTimer();
        advance(now);
        var s = _s;
        var ring = ringState();
        var moving = _dragging || _stepStart >= 0;

        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);

        if (s < 0.625) {
            // The top rubber band pulls the list, not the header.
            drawHeader(dc, s < 0.0 ? 0.0 : s, ring);
        }
        if (s > 0.4) {
            var op = (s - 0.4) * 2;
            Signs.draw(dc, Signs.QUESTION, Signs.QUESTION_DOT, 227, 54.5, 44.2,
                HomeList.dim(DesignTokens.PRIMARY, op), HomeList.dim(DesignTokens.ROUTE_AHEAD, op));
        }

        dc.setColor(DesignTokens.CARD, DesignTokens.CARD);
        dc.fillRoundedRectangle(HomeList.CARD_X, HomeList.CARD_Y, HomeList.CARD_W, HomeList.CARD_H, HomeList.CARD_R);
        for (var i = 0; i < HomeList.COUNT; i++) {
            drawItem(dc, i, i - s, ring, now);
        }
        // The card's arrow is the tip of the "?": the focused item is going somewhere.
        dc.setColor(DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[362.9, 230.2], [362.9, 261.8], [383.0, 246.0]] as Array<[Numeric, Numeric]>);

        if (s > 2.5) {
            drawFooter(dc, s);
        }
        drawScroll(dc, s);
        drawRing(dc, ring, now);
        schedule();
        if (moving) {
            var cost = System.getTimer() - now;
            _frameSum += cost;
            _frames++;
            if (cost > _frameMax) {
                _frameMax = cost;
            }
        }
    }

    // --- state --------------------------------------------------------------------------------

    //! No phone beats the request: the request gets nowhere, and the screen says why.
    private function ringState() as Number {
        if (!StatusIcons.phoneLinked()) {
            return RING_NO_PHONE;
        }
        return getApp().getFavoriteAsk().isWaiting() ? RING_WORKING : RING_READY;
    }

    //! Takes `_s` to the instant `now`, by the step curve ([HomeList.stepEase]). With the finger on the
    //! screen, the finger rules.
    private function advance(now as Number) as Void {
        if (_dragging) {
            return;
        }
        if (_stepStart < 0) {
            _s = _focus.toFloat();
            return;
        }
        var t = (now - _stepStart).toFloat() / HomeList.STEP_MS;
        if (t >= 1.0) {
            _s = _focus.toFloat();
            _stepStart = -1;
            logFrames();
            return;
        }
        _s = _stepFrom + (_focus - _stepFrom) * HomeList.stepEase(t);
    }

    //! The cost of the last movement's frame, in the watch log: it is the number that says whether the list
    //! moves smoothly on the wrist.
    private function logFrames() as Void {
        if (_frames >= 3) {
            Diag.add("home frame avg " + (_frameSum / _frames).toString() + "ms peak "
                + _frameMax.toString() + "ms n" + _frames.toString());
        }
        _frameSum = 0;
        _frameMax = 0;
        _frames = 0;
    }

    //! Turns the timer on, swaps it or turns it off according to what is still animating.
    private function schedule() as Void {
        var now = System.getTimer();
        var sweeping = _sweepStart >= 0 && now - _sweepStart < HomeList.SWEEP_MS;
        if (!sweeping) {
            _sweepStart = -1;
        }
        var wanted = 0;
        if (sweeping || _stepStart >= 0) {
            wanted = FRAME_MS;
        } else if (ringState() == RING_WORKING) {
            wanted = SPIN_FRAME_MS;
        }
        if (homeTimerLent) {
            wanted = 0;
        }
        if (wanted == _timerMs) {
            return;
        }
        stopTimer();
        if (wanted > 0) {
            var timer = _timer;
            if (timer == null) {
                timer = new Timer.Timer();
                _timer = timer;
            }
            timer.start(method(:onFrame), wanted, true);
            _timerMs = wanted;
        }
    }

    private function stopTimer() as Void {
        var timer = _timer;
        if (timer != null && _timerMs > 0) {
            timer.stop();
        }
        _timerMs = 0;
    }

    function onFrame() as Void {
        WatchUi.requestUpdate();
    }

    // --- header -------------------------------------------------------------------------------

    //! The gradient, the brand and the status line. They rise `200 × s` px and darken by
    //! `max(0, 1 − 1.6 × s)`; the brand is a bitmap and does not darken, so it vanishes at s > 0.5.
    private function drawHeader(dc as Dc, s as Float, ring as Number) as Void {
        var shift = (200 * s).toNumber();
        var fade = 1.0 - 1.6 * s;
        // One 2 px band per row, clipped to the circle of radius 207: PILL at y 0, HEADER_MID at
        // y 113 and black at y 205.
        for (var i = 0; i < _bands.size(); i++) {
            var sy = i * 2 - shift;
            if (sy + 1 < 0 || sy + 1 >= _halfChord.size()) {
                continue;
            }
            var half = _halfChord[sy + 1] as Number;
            if (half <= 0) {
                continue;
            }
            dc.setColor(HomeList.dim(_bands[i] as Number, fade), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(227 - half, sy, half * 2, 2);
        }
        var mark = _mark;
        if (mark != null && s <= 0.5) {
            dc.drawBitmap(125, 62 - shift, mark);
        }
        drawStateLine(dc, 150 - shift, ring, fade);
    }

    //! The brand dot, 10 px of slack and the text, the whole thing centered on the glass.
    private function drawStateLine(dc as Dc, y as Number, ring as Number, fade as Float) as Void {
        var ask = getApp().getFavoriteAsk();
        var text = _ready;
        var textColor = DesignTokens.SECONDARY;
        var dotColor = DesignTokens.ROUTE_AHEAD;
        if (ring == RING_NO_PHONE) {
            text = _noPhone;
            dotColor = -1;
        } else if (ring == RING_WORKING) {
            text = ask.text();
            textColor = DesignTokens.PILL_TEXT;
        } else if (ask.isSilent()) {
            // The overdue deadline is the only amber on the screen: that one is on you, look at the phone.
            text = ask.text();
            dotColor = DesignTokens.URGENT;
        }
        // The usable width is that of the row at rest (y 150): the text does not change size going up.
        if (!text.equals(_fitText) || _fit.size() < 2) {
            var fonts = [font(false, 24), font(false, 23)] as Array<Graphics.FontType>;
            _fit = HomeList.fitState(dc, text, fonts, HomeList.chordAt(150, 200) - 40);
            _fitText = text;
        }
        var face = _fit[0] as Graphics.FontType;
        var line = _fit[1] as String;
        var width = 12 + 10 + dc.getTextWidthInPixels(line, face);
        var x0 = 227 - width / 2;
        if (dotColor < 0) {
            dc.setColor(HomeList.dim(DesignTokens.ARROW_REST, fade), Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(3);
            dc.drawCircle(x0 + 6, y, 5);
            dc.setPenWidth(1);
        } else {
            dc.setColor(HomeList.dim(dotColor, fade), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x0 + 6, y, 6);
        }
        dc.setColor(HomeList.dim(textColor, fade), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x0 + 22, y, face, line, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // --- list ---------------------------------------------------------------------------------

    private function drawItem(dc as Dc, index as Number, d as Float, ring as Number, now as Number) as Void {
        if (d <= HomeList.D_MIN || d >= 3.0) {
            return;
        }
        var near = HomeList.nearest(d);
        var iconOp = HomeList.at(HomeList.ICON_OP, d);
        if (iconOp > 0.02) {
            // The icon is drawn with primitives: the size moves without steps.
            var px = HomeList.at(HomeList.ICON_PX, d);
            var ix = HomeList.at(HomeList.ICON_X, d);
            var iy = HomeList.at(HomeList.ICON_Y, d);
            drawIcon(dc, index, ix, iy, px, iconOp, ring, now);
        }

        var textOp = HomeList.at(HomeList.TEXT_OP, d);
        if (textOp > 0.02) {
            var bold = near == 2;
            var size = HomeList.textPx(d);
            var face = font(bold, size);
            dc.setColor(HomeList.textColor(d), Graphics.COLOR_TRANSPARENT);
            drawAtBaseline(dc, HomeList.at(HomeList.TEXT_X, d), HomeList.at(HomeList.TEXT_BASE, d), face,
                ascentOf(bold, size), _titles[index] as String, Graphics.TEXT_JUSTIFY_LEFT);
        }

        // The support line only shows at d = 0 and vanishes with |d|.
        var abs = d < 0 ? -d : d;
        var subOp = 1.0 - abs * 2;
        if (subOp > 0.02) {
            dc.setColor(HomeList.dim(DesignTokens.SECONDARY, subOp), Graphics.COLOR_TRANSPARENT);
            drawAtBaseline(dc, HomeList.at(HomeList.TEXT_X, d) + 1, HomeList.at(HomeList.TEXT_BASE, d) + 35,
                font(false, 24), ascentOf(false, 24), subtitle(index), Graphics.TEXT_JUSTIFY_LEFT);
        }
    }

    private function subtitle(index as Number) as String {
        if (index == HomeList.FAVORITES) {
            return counted(Favorites.count(), 0);
        }
        if (index == HomeList.RECENTS) {
            return counted(Recents.count(), 3);
        }
        if (index == HomeList.SETTINGS) {
            return _settingsHint;
        }
        var assembler = getApp().getAssembler();
        var link = assembler.getLink();
        return "rx " + assembler.rawMessages.toString()
            + " · ack " + link.sentCount.toString()
            + "/" + link.failedCount.toString();
    }

    //! "None", "1" or "n", from `first` in [_counts].
    private function counted(n as Number, first as Number) as String {
        if (_counts.size() < first + 3) {
            return n.toString();
        }
        if (n <= 1) {
            return _counts[first + n] as String;
        }
        return Lang.format(_counts[first + 2] as String, [n]);
    }

    //! Below the card, with Link in focus: the version and the log shortcut.
    private function drawFooter(dc as Dc, s as Float) as Void {
        var op = (s - 2.5) * 2;
        dc.setColor(HomeList.dim(DesignTokens.SECONDARY, op), Graphics.COLOR_TRANSPARENT);
        drawAtBaseline(dc, 227, 354, font(false, 24), ascentOf(false, 24), Tr.f(Rez.Strings.WatchVersion, [AppVersion.LABEL]),
            Graphics.TEXT_JUSTIFY_CENTER);
        dc.setColor(HomeList.dim(DesignTokens.ARROW_REST, op), Graphics.COLOR_TRANSPARENT);
        drawAtBaseline(dc, 227, 392, font(false, 22), ascentOf(false, 22), _openLog, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! The scroll arc on the right (radius 196, from −24° to +24°) and the position thumb.
    private function drawScroll(dc as Dc, s as Float) as Void {
        dc.setPenWidth(5);
        dc.setColor(DesignTokens.AFTER_STRIP, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(227, 227, 196, Graphics.ARC_CLOCKWISE, 24, 336);
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(227, 227, 196, Graphics.ARC_CLOCKWISE, degrees(24 - 12 * s), degrees(12 - 12 * s));
        dc.setPenWidth(1);
    }

    // --- ring ---------------------------------------------------------------------------------

    //! The edge ring (radius 214, stroke 8).
    private function drawRing(dc as Dc, ring as Number, now as Number) as Void {
        if (ring == RING_NO_PHONE) {
            // 67 strokes of 6 px with 14 gaps make the full turn.
            dc.setPenWidth(8);
            dc.setColor(DesignTokens.RING_OFF, Graphics.COLOR_TRANSPARENT);
            var step = 360.0 / 67;
            var dash = 6 * 180.0 / (Math.PI * 214);
            for (var i = 0; i < 67; i++) {
                var a = 90 - i * step;
                dc.drawArc(227, 227, 214, Graphics.ARC_CLOCKWISE, degrees(a), degrees(a - dash));
            }
            dc.setPenWidth(1);
            return;
        }
        ringArcs(dc, 227, 227, 214, 8, ring, now, _sweepStart, 1.0);
    }

    //! The full ring, the sweep or the spinning arc: the same drawing on the edge ring and on the Link
    //! icon.
    private function ringArcs(dc as Dc, x as Numeric, y as Numeric, r as Numeric, pen as Number, ring as Number,
            now as Number, sweepStart as Number, op as Float) as Void {
        dc.setPenWidth(pen);
        if (ring == RING_WORKING) {
            dc.setColor(HomeList.dim(DesignTokens.ROUTE_CASING, op), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(x, y, r);
            var start = 90 - 360.0 * (now % HomeList.SPIN_MS) / HomeList.SPIN_MS;
            dc.setColor(HomeList.dim(DesignTokens.ROUTE_AHEAD, op), Graphics.COLOR_TRANSPARENT);
            dc.drawArc(x, y, r, Graphics.ARC_CLOCKWISE, degrees(start), degrees(start - 90));
        } else if (sweepStart >= 0 && now - sweepStart < HomeList.SWEEP_MS) {
            var p = HomeList.ease((now - sweepStart).toFloat() / HomeList.SWEEP_MS);
            dc.setColor(HomeList.dim(DesignTokens.ROUTE_CASING, op), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(x, y, r);
            if (p > 0.003) {
                dc.setColor(HomeList.dim(DesignTokens.ROUTE_AHEAD, op), Graphics.COLOR_TRANSPARENT);
                dc.drawArc(x, y, r, Graphics.ARC_CLOCKWISE, 90, degrees(90 - 360 * p));
            }
        } else {
            dc.setColor(HomeList.dim(DesignTokens.ROUTE_AHEAD, op), Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(x, y, r);
        }
        dc.setPenWidth(1);
    }

    // --- icons --------------------------------------------------------------------------------

    //! The item icons stay white (language rule 3: only state and action have color), except the
    //! Favorites star, yellow at Igor's request (2026-10-18), as on the phone. The Link one is
    //! the ring with the signal, the same as on the phone.
    private function drawIcon(dc as Dc, index as Number, x as Float, y as Float, px as Float, op as Float,
            ring as Number, now as Number) as Void {
        var white = HomeList.dim(DesignTokens.PRIMARY, op);
        var u = px / 42.0;
        if (index == HomeList.FAVORITES) {
            var pts = [0.0, -20.0, 4.94, -6.8, 19.02, -6.18, 7.99, 2.6, 11.76, 16.18, 0.0, 8.4,
                -11.76, 16.18, -7.99, 2.6, -19.02, -6.18, -4.94, -6.8] as Array<Float>;
            var poly = [] as Array<[Numeric, Numeric]>;
            for (var i = 0; i < pts.size(); i += 2) {
                poly.add([x + (pts[i] as Float) * u, y + (pts[i + 1] as Float) * u]);
            }
            dc.setColor(HomeList.dim(DesignTokens.STAR, op), Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon(poly);
        } else if (index == HomeList.RECENTS) {
            dc.setColor(white, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(pen(4 * u));
            dc.drawCircle(x, y, 16 * u);
            dc.drawLine(x, y, x, y - 11 * u);
            dc.drawLine(x, y, x + 9 * u, y);
            dc.setPenWidth(1);
        } else if (index == HomeList.SETTINGS) {
            dc.setColor(white, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(pen(4 * u));
            var knobs = [-6, 7, -1] as Array<Number>;
            for (var i = 0; i < 3; i++) {
                var ly = y + (i - 1) * 10 * u;
                dc.drawLine(x - 16 * u, ly, x + 16 * u, ly);
                dc.fillCircle(x + (knobs[i] as Number) * u, ly, 4.5 * u);
            }
            dc.setPenWidth(1);
        } else {
            drawLinkIcon(dc, x, y, px, op, ring, now);
        }
    }

    //! The ring with the signal (§2: radius 0.434, stroke 0.092 and signal 0.684 of the side).
    private function drawLinkIcon(dc as Dc, x as Float, y as Float, side as Float, op as Float, ring as Number,
            now as Number) as Void {
        var r = 0.434 * side;
        var w = pen(0.092 * side);
        if (ring == RING_NO_PHONE) {
            dc.setPenWidth(w);
            dc.setColor(HomeList.dim(DesignTokens.RING_OFF, op), Graphics.COLOR_TRANSPARENT);
            var dashes = (2 * Math.PI * r / (1.35 * w)).toNumber();
            if (dashes < 6) {
                dashes = 6;
            }
            var step = 360.0 / dashes;
            for (var i = 0; i < dashes; i++) {
                var a = 90 - i * step;
                dc.drawArc(x, y, r, Graphics.ARC_CLOCKWISE, degrees(a), degrees(a - step / 3));
            }
            dc.setPenWidth(1);
            Signs.draw(dc, Signs.QUESTION, Signs.QUESTION_DOT, x, y, 0.684 * side,
                HomeList.dim(DesignTokens.SIGN_OFF, op), HomeList.dim(DesignTokens.ARROW_REST, op));
            return;
        }
        ringArcs(dc, x, y, r, w, ring, now, -1, op);
        Signs.draw(dc, Signs.CHECK, Signs.CHECK_DOT, x, y, 0.684 * side,
            HomeList.dim(DesignTokens.PRIMARY, op), HomeList.dim(DesignTokens.ROUTE_AHEAD, op));
    }

    // --- text ---------------------------------------------------------------------------------

    //! The system vector face at size `px`, created once and kept. Without it (device
    //! without the face), it falls back to the nearest bitmap font.
    private function font(bold as Boolean, px as Number) as Graphics.FontType {
        var key = (bold ? "b" : "r") + px.toString();
        var cached = _fonts.get(key);
        if (cached != null) {
            return cached as Graphics.FontType;
        }
        var face = null as Graphics.VectorFont?;
        if (Graphics has :getVectorFont) {
            var faces = bold
                ? ["RobotoCondensedBold", "RobotoBold"] as Array<String>
                : ["RobotoCondensedRegular", "RobotoRegular"] as Array<String>;
            for (var i = 0; i < faces.size() && face == null; i++) {
                try {
                    face = Graphics.getVectorFont({ :face => faces[i] as String, :size => px });
                } catch (ex) {
                    face = null;
                }
            }
        }
        var result = (face != null ? face : (px >= 40 ? Graphics.FONT_MEDIUM
            : (px >= 28 ? Graphics.FONT_SMALL : Graphics.FONT_TINY))) as Graphics.FontType;
        _fonts.put(key, result);
        var ascent = px * 8 / 10;
        if (Graphics has :getFontAscent) {
            try {
                ascent = Graphics.getFontAscent(result);
            } catch (ex) {
                ascent = px * 8 / 10;
            }
        }
        _ascents.put(key, ascent);
        return result;
    }

    private function ascentOf(bold as Boolean, px as Number) as Number {
        font(bold, px);
        var ascent = _ascents.get((bold ? "b" : "r") + px.toString());
        return ascent != null ? ascent as Number : px * 8 / 10;
    }

    //! The text with the baseline at `baseline`, as the SVG mockup positions each text.
    private function drawAtBaseline(dc as Dc, x as Numeric, baseline as Numeric, face as Graphics.FontType,
            ascent as Number, text as String, justify as Number) as Void {
        dc.drawText(x, baseline - ascent, face, text, justify);
    }

    //! Connect IQ degrees (0 at 3 o'clock, growing counter-clockwise) in 0..359.
    private function degrees(a as Float) as Number {
        var n = Math.floor(a).toNumber() % 360;
        return n < 0 ? n + 360 : n;
    }

    private function pen(width as Float) as Number {
        var n = (width + 0.5).toNumber();
        return n < 1 ? 1 : n;
    }
}
