import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! Watch log screen (SELECT on the home screen or the debug one, BACK goes back).
//!
//! Shows the last [Diag] lines centered: on a round screen of
//! 454 px, centered text is what survives on the top and bottom lines,
//! where the usable width drops.
class LogView extends WatchUi.View {

    //! In px of the reference screen (454), scaled to this one at each draw.
    private const TOP = 70;
    private const LINE_HEIGHT = 24;
    private const MAX_LINES = 13;

    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        var cx = dc.getWidth() / 2;

        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        var lines = Diag.lines;
        var first = lines.size() > MAX_LINES ? lines.size() - MAX_LINES : 0;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        if (lines.size() == 0) {
            dc.drawText(cx, Screen.px(TOP), Graphics.FONT_XTINY, Tr.s(Rez.Strings.NoEvents),
                Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var y = TOP;
        for (var i = first; i < lines.size(); i++) {
            dc.drawText(cx, Screen.px(y), Graphics.FONT_XTINY, lines[i], Graphics.TEXT_JUSTIFY_CENTER);
            y += LINE_HEIGHT;
        }
    }
}

class LogDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}

//! SELECT opens the log from any screen (used by both delegates).
function pushLogView() as Boolean {
    WatchUi.pushView(new LogView(), new LogDelegate(), WatchUi.SLIDE_LEFT);
    return true;
}
