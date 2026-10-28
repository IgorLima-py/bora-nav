import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The arrows sheet in the simulator (C16.5): only enters through `watch/setas.jungle`, which
//! `tools/sim.py shots --setas` builds. Igor found on the street that "a good part of the
//! arrow symbols" looks broken, without saying which; the sheet shows **all** of them, through the
//! same `TurnArrow` and `StatusIcons` as the HUD, so he can point by number.
//!
//! Pages: 0 to 4, the maneuver types of `05-PROTOCOL.md` (0..30, C16.5) at the size of the
//! top card, each on the slate card; 5, the same types at the size of the
//! "then" strip; 6, the 4 status icons and the back arrow in 4 headings.
//!
//! **No number on the watch.** The 1st sheet wrote the number under each arrow, and it
//! fell on top of the glyph: Igor could not tell which photo was which. Now `sim.py` crops
//! each symbol by the positions here (`SETAS_*` there, the same ones) and builds a table with
//! number and name. If a position changes here, it changes there.
//!
//! The `[arrows]` lines are the protocol with `sim.py`: `ready <page>` says that the
//! page is on screen; `end` says it is over.
function demoAfterLoad() as Boolean {
    var view = new ArrowsView();
    WatchUi.switchToView(view, new WatchUi.BehaviorDelegate(), WatchUi.SLIDE_IMMEDIATE);
    var run = new ArrowsRun(view);
    _arrowsRun = run;
    run.start();
    return true;
}

var _arrowsRun as ArrowsRun? = null;

class ArrowsRun {

    //! 5 pages of cards (7 types each, 31 types), the strip one and the icons one.
    const PAGES = 7;
    //! Seconds each page stays on the air: 1 to draw, the rest for `sim.py` to photograph.
    //! They were 4, and the page 1 photo of the 1st sheet (2026-10-16) came out with page 2: the
    //! `[arrows] ready` reaches `sim.py` some 2 s after the page is on screen. With
    //! 8 there is double that slack left. `sim.py` also refuses two identical photos.
    const HOLD_S = 8;

    private var _view as ArrowsView;
    private var _timer as Timer.Timer?;
    private var _seconds as Number = 0;

    function initialize(view as ArrowsView) {
        _view = view;
    }

    function start() as Void {
        var timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
        _timer = timer;
        System.println("[arrows] start " + PAGES.toString() + " pages");
    }

    function onTick() as Void {
        _seconds++;
        if (_seconds == 1) {
            System.println("[arrows] ready " + _view.page.toString());
        }
        if (_seconds < HOLD_S) {
            return;
        }
        _seconds = 0;
        _view.page++;
        if (_view.page >= PAGES) {
            var timer = _timer;
            if (timer != null) {
                timer.stop();
            }
            System.println("[arrows] end");
            System.exit();
        }
        WatchUi.requestUpdate();
    }
}

class ArrowsView extends WatchUi.View {

    var page as Number = 0;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        if (page < 5) {
            bigPage(dc, page * 7);
        } else if (page == 5) {
            smallPage(dc);
        } else {
            iconPage(dc);
        }
    }

    //! Up to 7 types starting at `first`, on a 3 × 3 grid without the two bottom corners. The widest
    //! glyph at 100% (the roundabout on the left) measures 84 px: the 96 card contains it, and
    //! `sim.py` crops 100 × 100 around each center.
    private function bigPage(dc as Dc, first as Number) as Void {
        var cells = [[127, 117], [227, 117], [327, 117], [127, 232], [227, 232], [327, 232], [227, 347]];
        var types = TurnGlyphs.ICON_OF_TYPE.size();
        for (var i = 0; i < 7 && first + i < types; i++) {
            var cell = cells[i] as Array<Number>;
            var x = cell[0] as Number;
            var y = cell[1] as Number;
            dc.setColor(DesignTokens.CARD, DesignTokens.CARD);
            dc.fillRoundedRectangle(x - 48, y - 48, 96, 96, DesignTokens.CARD_RADIUS);
            TurnArrow.draw(dc, x, y, first + i, DesignTokens.PRIMARY, DesignTokens.CARD);
        }
    }

    //! The 31 types on the "then" strip (half-height 13, that of `Hud.drawAfter` at 100%), 8 per
    //! row every 44 px: the widest glyph there measures 29 px.
    private function smallPage(dc as Dc) as Void {
        dc.setColor(DesignTokens.AFTER_STRIP, DesignTokens.AFTER_STRIP);
        dc.fillRoundedRectangle(50, 88, 354, 176, 12);
        TurnArrow.halfOverride = 13;
        for (var type = 0; type < TurnGlyphs.ICON_OF_TYPE.size(); type++) {
            var x = 73 + (type % 8) * 44;
            var y = 110 + (type / 8) * 44;
            TurnArrow.draw(dc, x, y, type, DesignTokens.PRIMARY, DesignTokens.AFTER_STRIP);
        }
        TurnArrow.halfOverride = -1;
    }

    //! The 4 states in the row slots and the back arrow in 4 headings. Since sheet 4 only the no
    //! phone one draws (`StatusIcons.ROW`); the other three slots stay empty, and their state is
    //! in the rider's ring.
    private function iconPage(dc as Dc) as Void {
        var bits = [StatusIcons.NO_PHONE, StatusIcons.WEAK_GPS, StatusIcons.RECALC, StatusIcons.POS_STOPPED];
        var left = 227 - (4 * StatusIcons.SIZE + 3 * StatusIcons.GAP) / 2;
        for (var i = 0; i < bits.size(); i++) {
            StatusIcons.draw(dc, bits[i] as Number, left + i * (StatusIcons.SIZE + StatusIcons.GAP), 228);
        }

        // The back arrow at 100% fits within ±32 px of the center (BEARING_RADIUS 18.5 at the 38/22 scale):
        // 84 cards every 90 px, which `sim.py` crops at ±45.
        for (var step = 0; step < 4; step++) {
            var x = 92 + step * 90;
            dc.setColor(DesignTokens.CARD, DesignTokens.CARD);
            dc.fillRoundedRectangle(x - 42, 275, 84, 84, DesignTokens.CARD_RADIUS);
            TurnArrow.drawBearing(dc, x, 317, (step * Math.PI / 4).toFloat(), DesignTokens.URGENT, DesignTokens.CARD);
        }
    }
}
