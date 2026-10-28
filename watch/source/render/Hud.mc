import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

//! The HUD over the map (`03 §HUD`, `01 §Screens`), in variant **v4 "Warning sign"** (v1.1.5: sheet 6,
//! option 12, chosen by Igor on 2026-10-17; `docs/design/relogio/ESCOLHA.md`).
//!
//! At the top, the **time** in a black cutout. Just below, the **street sign**, with two lines separated
//! by a rule and a 2 px frame: the arrow and the distance on top, the name of the maneuver's street
//! below. At the bottom, the **arrival** in another black cutout: the arrival time, large, and the time and
//! distance remaining. No speed (the rider looks at the bike's speedometer). Colors, sizes and
//! gaps come from `DesignTokens.mc`, generated from `tokens.json` — none of it is typed here. The
//! `build_plate` of `tools/design_tokens.py` is the mirror of this layout, and it is how the mockups and
//! the HUD scale range are checked.
//!
//! **The sign is petrol (`PLATE`) with white ink, and amber with black ink** at 60 m from the turn and in
//! "get back to the route": amber keeps a single role ("turn now", "go back"), and now covers the
//! whole sign. It is the only black text in Bora? (`DECISIONS.md` §2026-10-18). With no maneuver to show
//! (no route, no GPS, looking for the route), the sign is slate (`CARD`): there is nothing to follow.
//!
//! **The cutouts are black with sharp corners** and may go past the edge of the glass (black over the
//! black bezel of the watch): what has to fit is the text inside them. The sign does not: a frame cut by the
//! round edge would stop being a sign, so it moves down until all 4 corners fit.
//!
//! **The font is a system vector font** (`getVectorFont`, faces from `DesignTokens`), and the size is
//! chosen at run time: each HUD group (distance, arrival, texts, arrow) scales by the
//! `CONFIG` (C16.5, `Config.groupPx`).
//!
//! **The screen is round, and that rules the layout.** Each piece moves down (the top ones) or up (the bottom one)
//! until the corners fit inside the glass minus the margin, in closed form (a square root, no
//! loop) and with the text width **measured** by the `Dc`. No coordinate is chosen by eye.
//!
//! **Every line of text is lost map**, so no line exists just for debug (the frame
//! measurement goes to the phone, `MapRenderer.frameSummary`), and a line with nothing to say is not
//! drawn: with no street name, the sign has a single line.
class Hud {

    //! System vector faces of the `venu445mm` (`simulator.json` of SDK 9.2.0, type `system_ttf`),
    //! in the order in which they serve as backup when the requested one is missing. `tools/design_tokens.py --check` reads
    //! this list from the file and checks that the two faces of `tokens.json` are in it.
    static const FACES = ["RobotoCondensedBold", "RobotoCondensedRegular", "BionicBold", "BionicMedium",
        "RobotoMedium", "RobotoRegular"] as Array<String>;

    //! A distance up to 60 m from the turn makes the sign amber: it is the near-warning window.
    const URGENT_M = 60.0;

    // Fonts resolved once, not per frame (`getVectorFont` is costly): only a change of
    // `Config.revision` redoes them, and then once. Without a vector font, the system ones below remain.
    // `_text` serves the time and the "time · distance"; `_note`, the loose lines of the bottom cutout
    // ("arrived at 11:43", "no GPS"). The street name has variable size ([nameFont]).
    private var _text = Graphics.FONT_XTINY;
    private var _status = Graphics.FONT_XTINY;
    private var _note = Graphics.FONT_XTINY;
    private var _small = Graphics.FONT_XTINY;
    private var _time = Graphics.FONT_NUMBER_MILD;
    private var _dist = Graphics.FONT_NUMBER_MILD;
    private var _unit = Graphics.FONT_XTINY;
    private var _arrival = Graphics.FONT_XTINY;

    // The ascent (baseline minus the top of the line) of each font: `drawText` asks for the top, and the
    // layout thinks in baseline. `Graphics.getFontAscent`, or 80% of the body if missing.
    private var _ascText as Number = 0;
    private var _ascStatus as Number = 0;
    private var _ascNote as Number = 0;
    private var _ascSmall as Number = 0;
    private var _ascTime as Number = 0;
    private var _ascDist as Number = 0;
    private var _ascUnit as Number = 0;
    private var _ascArrival as Number = 0;

    //! The street name fonts, one per size of the ladder (from 28 to 22, and 20 on two lines), and their
    //! ascents: created when the ladder reaches them, cleared on a change of `Config.revision`.
    private var _nameFonts = {};
    private var _nameAsc as Dictionary<Number, Number> = {} as Dictionary<Number, Number>;

    //! The `Config.revision` with which the fonts were resolved: the HUD scale
    //! changes from the phone (C5), and then the fonts are redone on the next frame.
    private var _revision as Number = -1;

    // The `DesignTokens` sizes already with each one's group scale (`Config.groupPx`).
    private var _clockPx as Number = 0;
    private var _restPx as Number = 0;
    private var _statusPx as Number = 0;
    private var _notePx as Number = 0;
    private var _smallPx as Number = 0;
    private var _timePx as Number = 0;
    private var _unitPx as Number = 0;
    private var _arrivalPx as Number = 0;
    private var _nameStartPx as Number = 0;
    private var _nameDestPx as Number = 0;
    private var _nameMinPx as Number = 0;
    private var _nameTwoPx as Number = 0;
    //! The arrival mark (the check in the ring) scales with the arrow group.
    private var _doneH as Number = 0;
    //! The height of the tallest glyph of the 31 maneuvers, at the arrow scale: the top line of the sign
    //! always has this height, so the sign does not jump in size when the maneuver changes.
    private var _glyphH as Number = 0;
    //! The sign's breathing room (v1.1.5, `Config.plateWidePct`/`plateTallPct`): the gap from the text to the sign
    //! edge, on the sides, already in px, and the % of the breathing room above and below.
    private var _plateSide as Number = DesignTokens.PLATE_SIDE;
    private var _plateTall as Number = 0;

    //! What was **requested** of each font, in px (what RNF-05 measures). The
    //! `Rnf05Test` reads these fields: if the Hud stops using the token, the test sees it.
    private var _distPx as Number = 0;
    private var _textPx as Number = 0;

    //! The last name that fit on the sign ([fitPlateName]): the ladder measures the text up to 5 times, and the
    //! name only changes at the next maneuver. The key joins the name, the starting size and the width.
    private var _fitKey as String = "";
    private var _fitPx as Number = 0;
    private var _fitW as Number = 0;
    private var _fitLines as Array<String> = [] as Array<String>;

    //! The time when the phase became arrival, so the "arrived at 11:43" does not move with the clock.
    private var _arrivedAt as String = "";

    //! The last weather line that went to the log (see [logWeather]).
    private var _weatherLogged as String = "";

    //! The anti burn-in orbit (C10, `BurnIn`): the frame's shift, and the px
    //! that the layout **reserved** in the margins for that shift to fit. The
    //! layout is always computed without shift and the reserved margin is that of
    //! `Config.orbitPx()`; whoever shifts more than reserved leaves the RNF-05
    //! area — which is exactly what `BurnInTest` and the canary measure.
    private var _dx as Number = 0;
    private var _dy as Number = 0;
    private var _reserve as Number = 0;
    //! The **radial** reserve: the ring moves diagonally, and the corner (A, A) is at
    //! A·1.4143 from the ring center. It is what enters the fit by the glass
    //! circle (`topFit`/`bottomFit`); the axes (top, bottom) use A.
    private var _radial as Number = 0;
    private var _streetMidY as Number = 0;

    //! Fixed ring point (0..7) for the photos and tests; -1 = by the time.
    var orbitOverride as Number = -1;

    //! What the last `draw` drew, already shifted: one `[type, left, top, right,
    //! bottom]` per element (`BOX_*`). It is what `BurnInTest` checks.
    var boxes as Array<Array<Number>> = [] as Array<Array<Number>>;

    //! The arrival delta that the last [draw] wrote (C16.5), "" with no delta. It is what
    //! `NavEngineTest` reads to prove that it reaches the screen.
    var deltaShown as String = "";

    //! The remaining time and distance line ("23 min · 12,4 km") that the last [draw]
    //! wrote, "" without it. It is what `RouteUpdateTest` reads to prove that the duration with
    //! Igor's pace (C16) reaches the screen as the phone sent it.
    var restShown as String = "";

    //! The sign color and the name that the last [draw] drew (the lines and their body): it is what
    //! `PlateTest` reads to prove the color switch at 60 m and the name ladder.
    var plateShown as Number = 0;
    var nameShown as Array<String> = [] as Array<String>;
    var namePxShown as Number = 0;

    //! The time (the text, not the cutout); the top line of the sign (or the whole sign, when it
    //! has a single line); the name line; the bottom cutout text; the no-phone icon; the "then".
    const BOX_CLOCK = 0;
    const BOX_ROW = 1;
    const BOX_STREET = 2;
    const BOX_TIME = 3;
    const BOX_ICONS = 4;
    const BOX_AFTER = 5;

    // What the top line of the sign carries before the text.
    private const MARK_NONE = 0;
    private const MARK_GLYPH = 1;
    private const MARK_BEARING = 2;
    private const MARK_DONE = 3;

    //! Gap of the no-phone icon's black square around the `StatusIcons` bubble.
    const ICON_PAD = 4;

    //! The state icons (C14) of the last frame, so the `hud icones ...` log
    //! is written only on change.
    private var _iconsShown as Number = -1;

    function initialize() {
    }

    //! Distance font size, in px. Outside the canary build it is the
    //! `DesignTokens` one at the distance group scale; `watch/canary.jungle` puts the
    //! twin below, with 54, for `sim.py test --canary` to prove that `Rnf05Test` bites.
    (:no_canary)
    function distancePx() as Number {
        return Config.groupPx(DesignTokens.DIST_PX, Config.KEY_DIST_PCT);
    }

    (:canary)
    function distancePx() as Number {
        return 54;
    }

    //! **Drawn** orbit amplitude, in px. Outside the canary it is the reserved one;
    //! `watch/canary.jungle` puts the twin below, with 40, for `sim.py test
    //! --canary` to prove that `BurnInTest` bites (it shifts more than the margin).
    (:no_canary)
    function orbitAmplitude() as Number {
        return Config.orbitPx();
    }

    (:canary)
    function orbitAmplitude() as Number {
        return 40;
    }

    //! Prepares the fonts without drawing (`Rnf05Test` measures before drawing).
    function prepare(dc as Dc) as Void {
        resolveFonts(dc);
    }

    function requestedDistPx() as Number {
        return _distPx;
    }

    //! The smallest secondary text size requested (time, two-line name, rest, delta,
    //! "then"): it is what `01 §RNF-05` calls 20 px.
    function requestedTextPx() as Number {
        return _textPx;
    }

    function distFont() {
        return _dist;
    }

    //! The weather that goes after the time (` · 24° nublado`), or `""` when the
    //! watch has no weather: with no data the block disappears and the cutout does not grow (RF-10).
    function weatherSuffix() as String {
        var text = WeatherInfo.hudText();
        return text == null ? "" : " · " + text;
    }

    //! Says in the log what the HUD started showing of the weather — only on change, so the
    //! line does not repeat per frame. `hud clima 24C nublado` or `hud clima oculto`.
    private function logWeather() as Void {
        var now = WeatherInfo.logText();
        if (!now.equals(_weatherLogged)) {
            _weatherLogged = now;
            Diag.add("hud weather " + now);
        }
    }

    //! What the sign shows of off-route, only on change: `hud Recalculating`, `hud No
    //! phone`, and `hud arrow back 60m` on entry. It is what `sim.py ride --desvio` reads to
    //! prove that the screen changed.
    private var _wayBackState as Number = -1;

    private function logWayBack(metres as Float, state as Number) as Void {
        if (state == _wayBackState) {
            return;
        }
        if (_wayBackState < 0) {
            Diag.add("hud arrow back " + (metres + 0.5).toNumber().toString() + "m");
        }
        _wayBackState = state;
        Diag.add(state == OffRoute.NO_PHONE ? "hud No phone" : "hud Recalculating");
    }

    function draw(dc as Dc, route as RouteModel, nav as NavState, matcher as MapMatcher) as Void {
        if (nav.offRoute == OffRoute.ON_ROUTE) {
            _wayBackState = -1;
        }
        if (nav.phase != NavPhase.ARRIVED) {
            _arrivedAt = "";
        } else if (_arrivedAt.length() == 0) {
            _arrivedAt = clock();
        }
        resolveFonts(dc);
        logWeather();
        orbit();
        boxes = [] as Array<Array<Number>>;
        var tabBottom = drawClockTab(dc);
        drawPlate(dc, route, nav, matcher, tabBottom);
        drawArrivalTab(dc, route, nav, matcher);
    }

    //! This frame's shift and the margin reserved for it.
    private function orbit() as Void {
        setReserve(Config.orbitPx());
        var amp = orbitAmplitude();
        var index = orbitOverride;
        if (index < 0) {
            index = BurnIn.forced >= 0 ? BurnIn.forced
                : BurnIn.index(BurnIn.secondsOfDay(), Config.orbitStepS());
        }
        _dx = BurnIn.dx(index, amp);
        _dy = BurnIn.dy(index, amp);
    }

    //! Glass margin for the circle fit: the RNF-05 one plus the orbit's
    //! radial reserve (`_radial`, A·√2 rounded up).
    private function margin() as Number {
        return DesignTokens.EDGE_MARGIN + _radial;
    }

    //! Loads the fonts on the first pass and when `Config.revision` changes. If the vector
    //! face is missing, it falls back to the equivalent system font: the app has to keep drawing.
    private function resolveFonts(dc as Dc) as Void {
        if (_revision == Config.revision) {
            return;
        }
        _revision = Config.revision;

        // Each size at its group's scale (C16.5). `RNF-05` measures what the Hud asks for at 100%:
        // dist 60 (>= 55) and text >= 20; below that it is the rider's choice, with a 13 px floor.
        var text = Config.KEY_TEXT_PCT;
        _clockPx = Config.groupPx(DesignTokens.CLOCK_PX, text);
        _restPx = Config.groupPx(DesignTokens.REST_PX, text);
        _statusPx = Config.groupPx(DesignTokens.STATUS_PX, text);
        _notePx = Config.groupPx(DesignTokens.ARRIVED_AT_PX, text);
        _smallPx = Config.groupPx(DesignTokens.AFTER_PX, text);
        _nameStartPx = Config.groupPx(DesignTokens.STREET_PX, text);
        _nameDestPx = Config.groupPx(DesignTokens.DEST_PX, text);
        _nameMinPx = Config.groupPx(DesignTokens.STREET_MIN_PX, text);
        _nameTwoPx = Config.groupPx(DesignTokens.STREET_TWO_PX, text);
        _timePx = Config.groupPx(DesignTokens.TIME_PX, Config.KEY_ETA_PCT);
        _unitPx = Config.groupPx(DesignTokens.UNIT_PX, Config.KEY_DIST_PCT);
        _arrivalPx = Config.groupPx(DesignTokens.ARRIVAL_PX, Config.KEY_DIST_PCT);
        _doneH = Config.groupPx(DesignTokens.DONE_PX, Config.KEY_ARROW_PCT);
        _glyphH = tallestGlyph();
        // The side gap goes from the usual (100%) to the text 2 px from the frame (0%).
        var tight = DesignTokens.PLATE_INSET + DesignTokens.PLATE_LINE + DesignTokens.PLATE_ROW_PAD;
        _plateSide = tight + ((DesignTokens.PLATE_SIDE - tight) * Config.plateWidePct() + 50) / 100;
        _plateTall = Config.plateTallPct();

        _distPx = distancePx();
        _textPx = _nameTwoPx;
        var others = [_clockPx, _restPx, _statusPx, _notePx, _smallPx, _nameMinPx] as Array<Number>;
        for (var i = 0; i < others.size(); i++) {
            if ((others[i] as Number) < _textPx) {
                _textPx = others[i] as Number;
            }
        }

        _nameFonts = {};
        _nameAsc = {} as Dictionary<Number, Number>;
        _fitKey = "";
        if (Graphics has :getVectorFont) {
            _text = vectorFont(DesignTokens.FACE_TEXT, _clockPx, _text);
            _status = vectorFont(DesignTokens.FACE_TEXT, _statusPx, _status);
            _note = vectorFont(DesignTokens.FACE_TEXT, _notePx, _note);
            _small = vectorFont(DesignTokens.FACE_TEXT, _smallPx, _small);
            _time = vectorFont(DesignTokens.FACE_NUMBER, _timePx, _time);
            _dist = vectorFont(DesignTokens.FACE_NUMBER, _distPx, _dist);
            _unit = vectorFont(DesignTokens.FACE_NUMBER, _unitPx, _unit);
            _arrival = vectorFont(DesignTokens.FACE_NUMBER, _arrivalPx, _arrival);
        }

        _ascText = ascent(_text, _clockPx);
        _ascStatus = ascent(_status, _statusPx);
        _ascNote = ascent(_note, _notePx);
        _ascSmall = ascent(_small, _smallPx);
        _ascTime = ascent(_time, _timePx);
        _ascDist = ascent(_dist, _distPx);
        _ascUnit = ascent(_unit, _unitPx);
        _ascArrival = ascent(_arrival, _arrivalPx);
    }

    //! The tallest maneuver glyph of [TurnGlyphs] at the current arrow scale, rounded
    //! up: the `glyph_max_height` of `tools/design_tokens.py`.
    private function tallestGlyph() as Number {
        var u = TurnArrow.unit();
        var top = 0.0;
        for (var i = 0; i < TurnGlyphs.DATA.size(); i++) {
            var data = TurnGlyphs.DATA[i] as ByteArray;
            var h = (data[3] - data[1]) * u;
            if (h > top) {
                top = h;
            }
        }
        return Math.ceil(top).toNumber();
    }

    //! The face requested at size `pixels`, or those of [FACES] in order, or `fallback`. The
    //! `getVectorFont` **throws** `InvalidValueException` when the face does not exist on the device
    //! (`DECISIONS.md` §2026-08, the crash in the `NavView` constructor): each attempt in a `try`.
    private function vectorFont(preferred as String, pixels as Number, fallback) {
        var faces = [preferred] as Array<String>;
        for (var i = 0; i < FACES.size(); i++) {
            faces.add(FACES[i] as String);
        }
        for (var i = 0; i < faces.size(); i++) {
            try {
                var font = Graphics.getVectorFont({ :face => faces[i] as String, :size => pixels });
                if (font != null) {
                    return font;
                }
            } catch (ex) {
                Diag.add("font " + (faces[i] as String) + " refused");
            }
        }
        return fallback;
    }

    private function ascent(face, px as Number) as Number {
        if (Graphics has :getFontAscent) {
            try {
                return Graphics.getFontAscent(face);
            } catch (ex) {
                Diag.add("ascent refused");
            }
        }
        return px * 8 / 10;
    }

    //! The bold street name font at `px`, created the first time the ladder reaches it.
    private function nameFont(px as Number) {
        var font = _nameFonts.get(px);
        if (font == null) {
            font = Graphics.FONT_XTINY;
            if (Graphics has :getVectorFont) {
                font = vectorFont(DesignTokens.FACE_NUMBER, px, font);
            }
            _nameFonts.put(px, font);
            _nameAsc.put(px, ascent(font, px));
        }
        return font;
    }

    private function nameAscent(px as Number) as Number {
        var asc = _nameAsc.get(px);
        return asc == null ? px * 8 / 10 : asc as Number;
    }

    //! Draws `text` with the baseline at `baseline` (not the top of the line): it is how the
    //! C15a prototype positions each text.
    private function put(dc as Dc, face, ascent as Number, x as Number, baseline as Number, text as String,
                         justify as Number) as Void {
        dc.drawText(x, baseline - ascent, face, text, justify);
    }

    //! Usable half-width of the screen at height `y`, in pixels.
    function halfChord(y as Number) as Number {
        var dy = y - 227;
        var squared = 227 * 227 - dy * dy;
        if (squared <= 0) {
            return 0;
        }
        return Math.sqrt(squared.toFloat()).toNumber();
    }

    //! The largest half-width of a box with the top at `y`, above the center, with the top corners
    //! on the glass minus the margin: the `meia_largura_topo` of `tools/design_tokens.py`.
    private function halfAtTop(y as Number) as Number {
        var limit = 227 - margin();
        var dy = 227 - y;
        var squared = limit * limit - dy * dy;
        if (squared <= 0) {
            return 0;
        }
        return Math.sqrt(squared.toFloat()).toNumber();
    }

    //! Smallest `y` at which a box of half-width `halfW` fits the glass at the
    //! top (the top corners are the first to go out). Rounds up.
    private function topFit(halfW as Number) as Number {
        var limit = 227 - margin();
        var squared = limit * limit - halfW * halfW;
        if (squared <= 0) {
            return 227;
        }
        return 227 - Math.sqrt(squared.toFloat()).toNumber();
    }

    //! Largest `y` at which the bottom of a box of half-width `halfW` fits the
    //! glass at the bottom.
    private function bottomFit(halfW as Number) as Number {
        var limit = 227 - margin();
        var squared = limit * limit - halfW * halfW;
        if (squared <= 0) {
            return 227;
        }
        return 227 + Math.sqrt(squared.toFloat()).toNumber();
    }

    //! `from`, or the first `y` below it, in steps of 2 px, that reaches `fit` (the mockup's step).
    private function descend(from as Number, fit as Number) as Number {
        return fit <= from ? from : fit + (fit - from) % 2;
    }

    //! The same, upward: `from`, or the first `y` above it, in steps of 2 px, that reaches `fit`.
    private function rise(from as Number, fit as Number) as Number {
        return fit >= from ? from : fit - (from - fit) % 2;
    }

    //! Are all 4 corners inside the glass minus the margin (the RNF-05 one and the orbit one)?
    private function fitsGlass(left as Number, top as Number, right as Number, bottom as Number) as Boolean {
        var limit = 227 - margin();
        var xs = [left - 227, right - 227] as Array<Number>;
        var ys = [top - 227, bottom - 227] as Array<Number>;
        for (var i = 0; i < 2; i++) {
            for (var j = 0; j < 2; j++) {
                var x = xs[i] as Number;
                var y = ys[j] as Number;
                if (x * x + y * y > limit * limit) {
                    return false;
                }
            }
        }
        return true;
    }

    //! A black cutout with sharp corners, already shifted by the orbit. It may go past the glass edge.
    private function tab(dc as Dc, left as Number, top as Number, right as Number, bottom as Number) as Void {
        dc.setColor(DesignTokens.BACKGROUND, DesignTokens.BACKGROUND);
        dc.fillRectangle(left + _dx, top + _dy, right - left, bottom - top);
    }

    //! The time (and the weather) in a black cutout, at the top. Returns the cutout base, where the sign
    //! can start.
    private function drawClockTab(dc as Dc) as Number {
        var cx = dc.getWidth() / 2;
        var text = clock() + weatherSuffix();
        var w = dc.getTextWidthInPixels(text, _text);
        var pad = DesignTokens.TAB_EXTRA / 2;
        // The time moves down `_reserve` px: the orbit's upward shift does not take it above
        // `TAB_TOP`. And, if it is wide (with weather, at 112%), it moves down until the corners fit.
        var top = descend(DesignTokens.TAB_TOP + _reserve + pad, topFit(w / 2));
        var bottom = top + _clockPx + pad;
        tab(dc, cx - w / 2 - DesignTokens.TAB_PAD, top - pad, cx + w / 2 + DesignTokens.TAB_PAD, bottom);
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        put(dc, _text, _ascText, cx + _dx, top + _clockPx * 8 / 10 + _dy, text, Graphics.TEXT_JUSTIFY_CENTER);
        note(BOX_CLOCK, cx - w / 2, top, cx + w / 2, top + _clockPx);
        return bottom;
    }

    //! The street sign: the arrow and the distance on top, the street name below (sheet 6, option 12).
    private function drawPlate(dc as Dc, route as RouteModel, nav as NavState, matcher as MapMatcher,
                               tabBottom as Number) as Void {
        var cx = dc.getWidth() / 2;
        var index = matcher.nextTurnIndex();
        var arrived = nav.phase == NavPhase.ARRIVED;
        var hasTurn = !arrived && index >= 0 && matcher.matched && index < route.turnType.size();
        // Off-route (C11): the arrow points at the route, the number is how far to it, and the name
        // line says what the watch is doing. The maneuver that matters now is getting back.
        var wayBack = !arrived && nav.phase == NavPhase.NAVIGATING && nav.hasFix
            && nav.offRoute != OffRoute.ON_ROUTE && matcher.matched;

        var plate = DesignTokens.PLATE;
        var ink = DesignTokens.PRIMARY;
        var type = Protocol.TURN_ARRIVE;
        var mark = MARK_GLYPH;
        var mainText = "";
        var unitText = "";
        var mainFont = _dist;
        var mainAsc = _ascDist;
        var mainPx = _distPx;
        var rowH = _glyphH > _distPx ? _glyphH : _distPx;
        var name = "";
        var nameStart = _nameStartPx;
        var turnDistance = -1.0;
        var bearingRad = 0.0;

        if (wayBack) {
            var toRoute = matcher.crossTrack;
            var parts = NavEngine.distanceParts(toRoute < 20.0 ? 20.0 : toRoute);
            mainText = parts[0] as String;
            unitText = parts[1] as String;
            plate = DesignTokens.URGENT;
            ink = DesignTokens.WARN_INK;
            mark = MARK_BEARING;
            name = Tr.s(nav.offRoute == OffRoute.NO_PHONE ? Rez.Strings.NoPhone : Rez.Strings.Recalculating);
            // Track-up: the top of the screen is the bike's heading, so the arrow is the heading
            // to the nearest route point minus the bike's heading.
            var absolute = Math.atan2(matcher.snapX - nav.x, matcher.snapY - nav.y);
            bearingRad = (absolute - nav.headingRad).toFloat();
            logWayBack(toRoute, nav.offRoute);
        } else if (arrived) {
            // The Ready check in the cyan ring in place of the arrow, and the destination on the bottom line.
            mainText = Tr.s(Rez.Strings.Arrived);
            mainFont = _arrival;
            mainAsc = _ascArrival;
            mainPx = _arrivalPx;
            mark = MARK_DONE;
            rowH = _doneH > _arrivalPx ? _doneH : _arrivalPx;
            name = Fmt.plate(route.destName);
            nameStart = _nameDestPx;
        } else if (hasTurn) {
            type = route.turnType[index] as Number;
            var distance = matcher.distToNextTurnM();
            turnDistance = distance;
            var parts = NavEngine.distanceParts(distance);
            mainText = parts[0] as String;
            unitText = parts[1] as String;
            if (distance >= 0.0 && distance <= URGENT_M) {
                plate = DesignTokens.URGENT;
                ink = DesignTokens.WARN_INK;
            }
            name = streetName(route, index);
        } else {
            // With no maneuver ahead the sign is not left empty lying that it ended: it says **why** there is no
            // maneuver, in a single line. Slate when there is nothing to follow; waiting for the GPS or the
            // route is gray (sheet 4: the rider's ring already says the position is missing).
            mark = MARK_NONE;
            mainText = waitingReason(route, nav, matcher);
            mainPx = _nameStartPx;
            mainFont = nameFont(mainPx);
            mainAsc = nameAscent(mainPx);
            rowH = mainPx;
            var following = route.xs.size() >= 2 && nav.hasFix && matcher.matched;
            plate = following ? DesignTokens.PLATE : DesignTokens.CARD;
            if (route.xs.size() >= 2 && !following) {
                ink = DesignTokens.SECONDARY;
            }
        }

        // The top line: [mark][gap][number][gap][unit], centered.
        var bounds = [0.0, 0.0, 0.0, 0.0] as Array<Float>;
        if (mark == MARK_DONE) {
            bounds = [0.0, 0.0, _doneH.toFloat(), _doneH.toFloat()] as Array<Float>;
        } else if (mark == MARK_BEARING) {
            bounds = TurnArrow.bearingBounds();
        } else if (mark == MARK_GLYPH) {
            bounds = TurnArrow.bounds(type);
        }
        var markW = (bounds[2] - bounds[0]).toNumber();
        var markGap = mark == MARK_DONE ? DesignTokens.GAP_DONE : DesignTokens.GAP_ARROW;
        var mainW = dc.getTextWidthInPixels(mainText, mainFont);
        var unitW = unitText.length() > 0 ? dc.getTextWidthInPixels(unitText, _unit) : 0;
        var total = mainW + (unitW > 0 ? DesignTokens.GAP_UNIT + unitW : 0);
        if (mark != MARK_NONE) {
            total += markW + markGap;
        }

        // The sign starts right below the time, and the name fits the glass chord at its top edge.
        var py = DesignTokens.PLATE_TOP + _reserve;
        if (tabBottom + DesignTokens.TAB_GAP > py) {
            py = tabBottom + DesignTokens.TAB_GAP;
        }
        var lines = [] as Array<String>;
        var namePx = 0;
        var nameW = 0;
        if (name.length() > 0) {
            fitPlateName(dc, name, nameStart, 2 * halfAtTop(py) - 2 * _plateSide);
            lines = _fitLines;
            namePx = _fitPx;
            nameW = _fitW;
        }
        var two = lines.size() > 0;
        plateShown = plate;
        nameShown = lines;
        namePxShown = namePx;

        var line = DesignTokens.PLATE_LINE;
        var inset = DesignTokens.PLATE_INSET;
        var h1 = rowH + 2 * DesignTokens.PLATE_ROW_PAD + line;
        if (mark == MARK_NONE) {
            h1 = rowH + DesignTokens.PLATE_NAME_EXTRA + line;
        } else if (h1 < DesignTokens.PLATE_ROW_MIN) {
            h1 = DesignTokens.PLATE_ROW_MIN;
        }
        var h2 = two ? nameStart + DesignTokens.PLATE_NAME_EXTRA : 0;
        if (_plateTall < 100) {
            // The top and bottom breathing room (v1.1.5): below 100% each line shrinks toward
            // what it **actually** has, 2 px from the frame and the rule. On top: this arrow (not the
            // tallest of the 31) or the height of the digits, which is 72% of the body and sits centered on the line
            // (`baseline` below); "You're here" (in Portuguese "Você chegou") has an accent and a descender, 57% of the body on each side.
            // At the bottom, the name's body. No font changes.
            var pad = 2 * DesignTokens.PLATE_ROW_PAD + line;
            var textH = mainPx * 72 / 100;
            var markH = (bounds[3] - bounds[1] + 0.999).toNumber();
            if (mark == MARK_NONE) {
                textH = rowH;
            } else if (mark == MARK_DONE) {
                textH = 2 * (mainPx * 57 / 100);
            }
            var row = (markH > textH ? markH : textH) + pad + (two ? 0 : line);
            h1 = squeeze(h1, row);
            if (two) {
                h2 = squeeze(h2, (lines.size() == 1 ? namePx : 2 * namePx + 4) + pad);
            }
        }
        var height = inset + h1 + (two ? line + h2 : 0) + inset;
        var wide = (total > nameW ? total : nameW) + 2 * _plateSide;
        wide += wide % 2;
        // Moves down until the 4 corners fit: only happens when the top line is wider than the
        // glass at the usual height (the name was already cut to fit).
        py = descend(py, topFit(wide / 2));
        var left = cx - wide / 2;
        var right = left + wide;
        var bottom = py + height;
        var divY = py + inset + h1;

        dc.setColor(plate, plate);
        dc.fillRectangle(left + _dx, py + _dy, wide, height);
        // The 2 px frame, 5 px inside the edge, and the rule between the lines, in the ink color.
        dc.setColor(ink, ink);
        var fx = left + inset + _dx;
        var fy = py + inset + _dy;
        var fw = wide - 2 * inset;
        var fh = height - 2 * inset;
        dc.fillRectangle(fx, fy, fw, line);
        dc.fillRectangle(fx, fy + fh - line, fw, line);
        dc.fillRectangle(fx, fy, line, fh);
        dc.fillRectangle(fx + fw - line, fy, line, fh);
        if (two) {
            dc.fillRectangle(fx, divY + _dy, fw, line);
            note(BOX_ROW, left, py, right, divY);
            note(BOX_STREET, left, divY, right, bottom);
        } else {
            note(BOX_ROW, left, py, right, bottom);
        }

        var cy1 = py + inset + line + (h1 - line) / 2;
        var x0 = cx - total / 2;
        var textX = x0;
        if (mark == MARK_DONE) {
            drawDone(dc, x0 + _doneH / 2 + _dx, cy1 + _dy, _doneH);
            textX = x0 + _doneH + markGap;
        } else if (mark != MARK_NONE) {
            var arrowCx = (x0 - bounds[0]).toNumber() + _dx;
            var arrowCy = (cy1 - (bounds[1] + bounds[3]) / 2).toNumber() + _dy;
            if (mark == MARK_BEARING) {
                TurnArrow.drawBearing(dc, arrowCx, arrowCy, bearingRad, ink, plate);
            } else {
                TurnArrow.draw(dc, arrowCx, arrowCy, type, ink, plate);
            }
            textX = x0 + markW + markGap;
        }
        dc.setColor(ink, Graphics.COLOR_TRANSPARENT);
        // The number and the unit share the baseline: 86% of the number's body, centered on the line.
        var baseline = cy1 + mainPx * 36 / 100;
        put(dc, mainFont, mainAsc, textX + _dx, baseline + _dy, mainText, Graphics.TEXT_JUSTIFY_LEFT);
        if (unitW > 0) {
            put(dc, _unit, _ascUnit, textX + mainW + DesignTokens.GAP_UNIT + _dx, baseline + _dy, unitText,
                Graphics.TEXT_JUSTIFY_LEFT);
        }
        if (two) {
            var cy2 = divY + line + h2 / 2;
            _streetMidY = cy2;
            var font = nameFont(namePx);
            var asc = nameAscent(namePx);
            if (lines.size() == 1) {
                put(dc, font, asc, cx + _dx, cy2 - namePx / 2 + namePx * 82 / 100 + _dy, lines[0] as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                put(dc, font, asc, cx + _dx, cy2 - namePx - 2 + namePx * 82 / 100 + _dy, lines[0] as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
                put(dc, font, asc, cx + _dx, cy2 + 2 + namePx * 82 / 100 + _dy, lines[1] as String,
                    Graphics.TEXT_JUSTIFY_CENTER);
            }
        }

        // "then": near the maneuver, with the next one right behind it (Waze does the same).
        if (hasTurn && !wayBack && turnDistance >= 0.0 && turnDistance <= URGENT_M
                && index + 1 < route.turnType.size()) {
            drawAfterStrip(dc, route.turnType[index + 1] as Number, cx, bottom + 4);
        }
        drawStatusIcons(dc, nav, right, bottom);
    }

    //! The height `full` of a sign line with the rider's breathing room: 100% is `full`, 0% is `tight`
    //! (the content 2 px from the frame). A line that is already tight does not grow.
    private function squeeze(full as Number, tight as Number) as Number {
        if (full <= tight) {
            return full;
        }
        return tight + ((full - tight) * _plateTall + 50) / 100;
    }

    //! The Ready check (`Signs.CHECK`, white with the cyan dot) in the cyan ring, centered at
    //! (`cx`, `cy`) in a square of `side` px: the stroke-4 ring touches the edge, and the check keeps the
    //! sheet's proportion (30 px in a ring of radius 19).
    private function drawDone(dc as Dc, cx as Number, cy as Number, side as Number) as Void {
        var pen = (side * 4 + DesignTokens.DONE_PX / 2) / DesignTokens.DONE_PX;
        if (pen < 2) {
            pen = 2;
        }
        var r = (side - pen) / 2;
        dc.setColor(DesignTokens.ROUTE_AHEAD, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(pen);
        dc.drawCircle(cx, cy, r);
        dc.setPenWidth(1);
        Signs.draw(dc, Signs.CHECK, Signs.CHECK_DOT, cx, cy, r * 30 / 19, DesignTokens.PRIMARY,
            DesignTokens.ROUTE_AHEAD);
    }

    //! The "then" with the next maneuver, in a black cutout right below the sign: the text in
    //! gray and the small arrow, in white.
    private function drawAfterStrip(dc as Dc, nextType as Number, cx as Number, top as Number) as Void {
        var label = Tr.s(Rez.Strings.AndThen);
        // The small arrow: half-height 13 for the 20 px text (C15b), in the same proportion.
        var arrowHalf = (_smallPx * 13 + 10) / 20;
        var stripH = _smallPx + 8;
        if (stripH < 2 * arrowHalf + 4) {
            stripH = 2 * arrowHalf + 4;
        }
        var textW = dc.getTextWidthInPixels(label, _small);
        var inner = textW + 10 + 2 * arrowHalf + 4;
        var left = cx - inner / 2 - DesignTokens.TAB_PAD;
        var right = left + inner + 2 * DesignTokens.TAB_PAD;
        note(BOX_AFTER, left, top, right, top + stripH);
        tab(dc, left, top, right, top + stripH);
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        put(dc, _small, _ascSmall, left + DesignTokens.TAB_PAD + _dx, top + stripH / 2 + _smallPx * 32 / 100 + _dy,
            label, Graphics.TEXT_JUSTIFY_LEFT);
        TurnArrow.halfOverride = arrowHalf;
        TurnArrow.draw(dc, right - DesignTokens.TAB_PAD - arrowHalf - 2 + _dx, top + stripH / 2 + _dy, nextType,
            DesignTokens.PRIMARY, DesignTokens.BACKGROUND);
        TurnArrow.halfOverride = -1;
    }

    //! The arrival, in a black cutout at the bottom, on two lines: the **arrival time**, large, with the
    //! delta beside it, and below "time · distance". Without GPS, off-route or after arriving, a
    //! single line says the reason, or the time of arrival.
    private function drawArrivalTab(dc as Dc, route as RouteModel, nav as NavState, matcher as MapMatcher) as Void {
        var cx = dc.getWidth() / 2;
        var main = "";
        var rest = "";
        var colour = DesignTokens.PRIMARY;
        var stacked = false;
        var delta = 0;
        if (!nav.hasFix) {
            // Gray: the rider's dashed ring already says it (sheet 4).
            main = Tr.s(Rez.Strings.NoGps);
            colour = DesignTokens.SECONDARY;
        } else if (nav.phase == NavPhase.ARRIVED) {
            main = Tr.f(Rez.Strings.ArrivedAt, [_arrivedAt]);
            colour = DesignTokens.SECONDARY;
        } else if (!matcher.matched) {
            main = Tr.s(Rez.Strings.OffRoute);
            colour = DesignTokens.URGENT;
        } else {
            var seconds = NavEngine.remainingSeconds(route, matcher, nav);
            main = arrivalClock(seconds);
            rest = NavEngine.formatDuration(seconds) + " · " + remaining(matcher);
            delta = nav.arrivalDelta(Time.now().value(), seconds);
            stacked = true;
        }

        // C16.5: the delta against the arrival at the start of the trip, to the right of the time.
        var deltaText = stacked ? NavEngine.formatDelta(delta) : "";
        deltaShown = deltaText;
        restShown = rest;
        var end = DesignTokens.ARRIVAL_END_Y - _reserve;

        if (!stacked) {
            var pad = DesignTokens.TAB_EXTRA / 2;
            var w = dc.getTextWidthInPixels(main, _note);
            var bottom = rise(end - pad, bottomFit(w / 2));
            var top = bottom - _notePx;
            tab(dc, cx - w / 2 - DesignTokens.TAB_PAD, top - pad, cx + w / 2 + DesignTokens.TAB_PAD, bottom + pad);
            note(BOX_TIME, cx - w / 2, top, cx + w / 2, bottom);
            dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
            put(dc, _note, _ascNote, cx + _dx, top + _notePx * 80 / 100 + _dy, main, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var pad = DesignTokens.ARRIVAL_EXTRA / 2;
        var clockW = dc.getTextWidthInPixels(main, _time);
        var deltaW = deltaText.length() > 0 ? dc.getTextWidthInPixels(deltaText, _status) : 0;
        var mainW = clockW + (deltaW > 0 ? DesignTokens.DELTA_GAP + deltaW : 0);
        var restW = dc.getTextWidthInPixels(rest, _text);
        var w = mainW > restW ? mainW : restW;
        var bottom = rise(end - pad, bottomFit(w / 2));
        var top = bottom - _timePx - _restPx;
        tab(dc, cx - w / 2 - DesignTokens.TAB_PAD, top - pad, cx + w / 2 + DesignTokens.TAB_PAD, bottom + pad);
        note(BOX_TIME, cx - w / 2, top, cx + w / 2, bottom);

        var base = top + _timePx * 84 / 100 + _dy;
        var left = cx - mainW / 2 + _dx;
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        put(dc, _time, _ascTime, left, base, main, Graphics.TEXT_JUSTIFY_LEFT);
        if (deltaW > 0) {
            dc.setColor(delta > 0 ? DesignTokens.LATE : DesignTokens.ARRIVED, Graphics.COLOR_TRANSPARENT);
            put(dc, _status, _ascStatus, left + clockW + DesignTokens.DELTA_GAP, base, deltaText,
                Graphics.TEXT_JUSTIFY_LEFT);
        }
        dc.setColor(DesignTokens.SECONDARY, Graphics.COLOR_TRANSPARENT);
        put(dc, _text, _ascText, cx + _dx, bottom - _restPx * 16 / 100 + _dy, rest, Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! The arrival time: now plus `seconds`, without a leading zero on the hour (`15:46`, `7:05`).
    private function arrivalClock(seconds as Number) as String {
        var now = System.getClockTime();
        var minutes = (now.hour * 60 + now.min + (seconds + 30) / 60) % 1440;
        return (minutes / 60).toString() + ":" + (minutes % 60).format("%02d");
    }

    //! The no-phone icon (`StatusIcons`) in a black square attached to the right of the sign, flush with its base, where
    //! the glass is wider. If the sign is too wide for it to fit beside: below it, in the right corner.
    private function drawStatusIcons(dc as Dc, nav as NavState, plateRight as Number, plateBottom as Number) as Void {
        var bits = StatusIcons.mask(nav, StatusIcons.phoneLinked());
        if (bits != _iconsShown) {
            _iconsShown = bits;
            Diag.add("hud icons " + StatusIcons.label(bits));
        }
        // The log says all the states; the sign carries only those of the row (sheet 4: only no phone).
        if ((bits & StatusIcons.ROW) == 0) {
            return;
        }
        var w = StatusIcons.width(bits);
        var side = (w > StatusIcons.SIZE ? w : StatusIcons.SIZE) + 2 * ICON_PAD;
        var left = plateRight;
        var top = plateBottom - side;
        if (!fitsGlass(left, top, left + side, top + side)) {
            left = plateRight - side;
            top = plateBottom + 4;
        }
        note(BOX_ICONS, left, top, left + side, top + side);
        tab(dc, left, top, left + side, top + side);
        StatusIcons.draw(dc, bits, left + (side - w) / 2 + _dx, top + ICON_PAD + _dy);
    }

    //! Stores an element's box, **already shifted**, for `BurnInTest`.
    private function note(kind as Number, left as Number, top as Number, right as Number, bottom as Number) as Void {
        boxes.add([kind, left + _dx, top + _dy, right + _dx, bottom + _dy] as Array<Number>);
    }

    //! Why there is no maneuver on screen yet. Each state has its own phrase
    //! because each asks something different of the rider: wait for the sky, go back
    //! to the route, or nothing.
    private function waitingReason(route as RouteModel, nav as NavState, matcher as MapMatcher) as String {
        if (route.xs.size() < 2) {
            return Tr.s(Rez.Strings.NoRoute);
        }
        if (!nav.hasFix) {
            return Tr.s(Rez.Strings.WaitingGps);
        }
        if (!matcher.matched) {
            return Tr.s(Rez.Strings.FindingRoute);
        }
        return Tr.s(Rez.Strings.GoStraight);
    }

    //! Street name of the maneuver as the sign writes it (`Fmt.plate`), with the roundabout exit
    //! in front when there is one.
    private function streetName(route as RouteModel, index as Number) as String {
        var name = index < route.turnName.size() ? Fmt.plate(route.turnName[index] as String) : "";
        var type = route.turnType[index] as Number;

        if (Protocol.hasExitNum(type) && index < route.turnExit.size()) {
            var exit = route.turnExit[index] as Number;
            if (exit > 0) {
                name = Tr.f(Rez.Strings.ExitN, [exit]) + (name.length() > 0 ? " · " + name : "");
            }
        }
        return name;
    }

    //! The size and lines of the name on the sign, in [_fitPx], [_fitLines] and [_fitW]: from `start` px
    //! descending by `PLATE_NAME_STEP` down to `STREET_MIN_PX` on a single line; if it does
    //! not fit, two lines of `STREET_TWO_PX`, each one cut if it still exceeds `limit`. It is the
    //! ladder of `fit_name` in `tools/design_tokens.py`, with the width measured.
    private function fitPlateName(dc as Dc, name as String, start as Number, limit as Number) as Void {
        var key = name + "|" + start.toString() + "|" + limit.toString();
        if (key.equals(_fitKey)) {
            return;
        }
        _fitKey = key;
        for (var px = start; px >= _nameMinPx; px -= DesignTokens.PLATE_NAME_STEP) {
            var w = dc.getTextWidthInPixels(name, nameFont(px));
            if (w <= limit) {
                _fitPx = px;
                _fitW = w;
                _fitLines = [name] as Array<String>;
                return;
            }
        }
        var font = nameFont(_nameTwoPx);
        var halves = twoLines(name);
        _fitPx = _nameTwoPx;
        _fitW = 0;
        _fitLines = [] as Array<String>;
        for (var i = 0; i < halves.size(); i++) {
            var line = cut(dc, halves[i] as String, font, limit);
            var w = dc.getTextWidthInPixels(line, font);
            if (w > _fitW) {
                _fitW = w;
            }
            _fitLines.add(line);
        }
    }

    //! Breaks at the space nearest the middle: "Av. Moreira Guimarães" becomes "Av. Moreira" / "Guimarães".
    //! With no space, a single line (which [cut] cuts).
    private function twoLines(name as String) as Array<String> {
        var chars = name.toCharArray();
        var n = chars.size();
        var best = -1;
        for (var i = 0; i < n; i++) {
            if (chars[i] == ' ' && (best < 0 || (2 * i - n).abs() < (2 * best - n).abs())) {
                best = i;
            }
        }
        if (best < 0) {
            return [name] as Array<String>;
        }
        return [name.substring(0, best) as String, name.substring(best + 1, n) as String] as Array<String>;
    }

    //! `text` cut with "…" until it fits in `limit` px. Proportional cut instead of removing letter by
    //! letter: measuring the width is expensive. One measurement, one estimate, and at most a few more adjustments.
    private function cut(dc as Dc, text as String, font, limit as Number) as String {
        var width = dc.getTextWidthInPixels(text, font);
        if (width <= limit) {
            return text;
        }
        var keep = (text.length() * limit) / width;
        if (keep < 1) {
            keep = 1;
        }
        text = text.substring(0, keep) as String;
        while (text.length() > 1 && dc.getTextWidthInPixels(text + "…", font) > limit) {
            text = text.substring(0, text.length() - 1) as String;
        }
        return text + "…";
    }

    //! Width the street name may have at height `midY`: the screen chord
    //! minus 16 px of slack and minus the orbit's `2 x reserve` (the text moves
    //! `reserve` to each side). The chord is that of the **highest** point of the orbit
    //! (`midY - reserve`): going up, the screen narrows. The C10 measurement compares with it.
    function streetBudget(midY as Number) as Number {
        return halfChord(midY - _reserve) * 2 - 16 - 2 * _reserve;
    }

    //! Width of the street name at the sign's starting size (the C10 measurement compares with
    //! [streetBudget]).
    function streetWidth(dc as Dc, name as String) as Number {
        resolveFonts(dc);
        return dc.getTextWidthInPixels(name, nameFont(_nameStartPx));
    }

    //! Orbit reserve only for the measurement (the [streetBudget] computation) without
    //! going through `Config`.
    function setReserve(px as Number) as Void {
        _reserve = px;
        // 1414/1000 = √2 to 4 digits, rounded up: never under-reserves.
        _radial = (px * 1414 + 999) / 1000;
    }

    //! Height (center) at which the sign's street name was last drawn: the one the
    //! C10 measurement uses in [streetBudget].
    function lastStreetMidY() as Number {
        return _streetMidY;
    }

    private function clock() as String {
        var now = System.getClockTime();
        return now.hour.format("%02d") + ":" + now.min.format("%02d");
    }

    //! Remaining distance, without the word "restantes".
    private function remaining(matcher as MapMatcher) as String {
        var metres = matcher.remainingM();
        if (metres < 1000.0) {
            return (metres.toNumber()).toString() + " m";
        }
        return Fmt.km(metres / 1000.0) + " km";
    }
}
