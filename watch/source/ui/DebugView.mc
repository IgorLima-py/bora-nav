import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! F1 screen: proves the route arrived and how fast (docs/07-ROADMAP.md §F1).
//! F2 replaces it with the real map; the numbers here are what gets recorded in
//! docs/DECISIONS.md as the BLE measurements.
class DebugView extends WatchUi.View {

    private const MAX_ERROR_CHARS = 26;

    private var _assembler as MessageAssembler;

    function initialize(assembler as MessageAssembler) {
        View.initialize();
        _assembler = assembler;
    }

    function onUpdate(dc as Dc) as Void {
        var route = _assembler.getRoute();
        var cx = dc.getWidth() / 2;

        dc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_BLACK);
        dc.clear();

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 56, Graphics.FONT_TINY, AppVersion.LABEL, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, 92, Graphics.FONT_SMALL, routeTitle(route), Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var y = 140;
        var lines = [
            route.destName,
            Tr.f(Rez.Strings.PointsTurns, [route.polyPointCount, route.turnCount]),
            formatDistance(route.distanceM) + " · " + formatDuration(route.durationS),
            Tr.f(Rez.Strings.BytesChunks, [_assembler.bytesReceived, _assembler.chunksReceived]),
            formatTransfer(),
            formatLink()
        ] as Array<String>;
        for (var i = 0; i < lines.size(); i++) {
            dc.drawText(cx, y, Graphics.FONT_TINY, lines[i], Graphics.TEXT_JUSTIFY_CENTER);
            y += 34;
        }

        if (!_assembler.lastError.equals("")) {
            dc.setColor(0xFFB300, Graphics.COLOR_TRANSPARENT);
            drawWrapped(dc, cx, y + 6, _assembler.lastError);
        }
    }

    //! Breaks into up to two lines. The error message used to come cut off by the edge of the
    //! round screen ("...ato inesperado do c..."), which cost a round of
    //! street testing just to find out which error it was.
    private function drawWrapped(dc as Dc, cx as Number, y as Number, text as String) as Void {
        if (text.length() <= MAX_ERROR_CHARS) {
            dc.drawText(cx, y, Graphics.FONT_XTINY, text, Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Cuts at the last space that fits, so as not to split a word in the middle.
        var cut = MAX_ERROR_CHARS;
        for (var i = MAX_ERROR_CHARS; i > 8; i--) {
            var candidate = text.substring(i - 1, i);
            if (candidate != null && candidate.equals(" ")) {
                cut = i - 1;
                break;
            }
        }

        var first = text.substring(0, cut);
        var rest = text.substring(cut, text.length());
        dc.drawText(cx, y, Graphics.FONT_XTINY, first != null ? first : "", Graphics.TEXT_JUSTIFY_CENTER);
        if (rest != null) {
            dc.drawText(cx, y + 24, Graphics.FONT_XTINY, rest, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    private function routeTitle(route as RouteModel) as String {
        if (!route.hasMeta) {
            return Tr.s(Rez.Strings.AwaitingRoute);
        }
        var mark = route.isComplete() ? "✓" : "…";
        return Tr.f(Rez.Strings.RouteNumber, [route.routeId]) + " " + mark;
    }

    private function formatDistance(metres as Number) as String {
        if (metres < 1000) {
            return metres.toString() + " m";
        }
        return Fmt.km(metres / 1000.0) + " km";
    }

    private function formatDuration(seconds as Number) as String {
        return (seconds / 60).toString() + " min";
    }

    //! Messages received from the phone and ACKs the watch managed to send —
    //! it is what says which side of the link the problem is on.
    private function formatLink() as String {
        var link = _assembler.getLink();
        var line = "rx " + _assembler.rawMessages.toString()
            + " · ack " + link.sentCount.toString()
            + "/" + link.failedCount.toString();
        if (!link.lastError.equals("")) {
            line += " · " + link.lastError;
        }
        return line;
    }

    private function formatTransfer() as String {
        var start = _assembler.transferStartMs;
        var end = _assembler.transferEndMs;
        if (start == 0) {
            return "—";
        }
        if (end == 0) {
            return Tr.s(Rez.Strings.Receiving);
        }
        var elapsed = end - start;
        var rate = elapsed > 0 ? (_assembler.bytesReceived * 1000.0) / (elapsed * 1024.0) : 0.0;
        return elapsed.toString() + " ms · " + rate.format("%.1f") + " KB/s";
    }
}

//! ESC leaves the debug screen; the app keeps receiving in the background.
//! SELECT opens the event log.
class DebugDelegate extends WatchUi.BehaviorDelegate {

    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() as Boolean {
        return pushLogView();
    }
}
