import Toybox.WatchUi;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Timer;

//! The bridge proof (C7a), only in `watch/ponte.jungle`: the companion on the emulator
//! sends `PONTE:C2R:<id>` over `TETHERED`; here the line comes out on `monkeydo`'s
//! stdout and the `PONTE:R2C:<id>` answer goes back through [phoneTransmit].
//!
//! The text may arrive as a String or inside an Array (Android's `sendMessage`
//! sends a list; see `PhoneData`). Anything else goes on to the
//! app as usual.
function bridgeMessage(data as Object?) as Boolean {
    var text = null;
    if (data instanceof String) {
        text = data as String;
    } else if (data instanceof Array) {
        var list = data as Array;
        if (list.size() > 0 && list[0] instanceof String) {
            text = list[0] as String;
        }
    }
    if (text == null) {
        return false;
    }
    var body = text as String;
    // Command from `tools/e2e.py --detour` (C11): `PONTE:CMD:SIM` turns on the virtual lap
    // and `PONTE:CMD:DETOUR:<m>` puts the bike <m> meters off the route (0 returns).
    if (body.find(BridgeListener.CMD) == 0) {
        System.println(body);
        bridgeCommand(body.substring(BridgeListener.CMD.length(), body.length()) as String);
        return true;
    }
    if (body.find(BridgeListener.C2R) != 0) {
        return false;
    }
    var id = body.substring(BridgeListener.C2R.length(), body.length()) as String;
    System.println(body);
    phoneTransmit(BridgeListener.R2C + id, new BridgeListener(id));
    return true;
}

function bridgeCommand(command as String) as Void {
    var app = getApp() as MotoNavApp;
    if (command.equals("SIM")) {
        app.startReplay();
    } else if (command.find("DETOUR:") == 0) {
        // `DETOUR:<m>` stays off until the next `DETOUR:0`; `DETOUR:<m>:<s>` returns by itself
        // after <s> seconds (C14's `--estresse`: with the companion dead, no
        // bridge command arrives, and the bike must return to the route to warn of a turn).
        var rest = command.substring(7, command.length()) as String;
        var colon = rest.find(":");
        var metres = (colon == null ? rest : rest.substring(0, colon) as String).toFloat();
        app.setReplayDetour(metres == null ? 0.0 : metres);
        if (colon != null) {
            var seconds = rest.substring(colon + 1, rest.length()).toNumber();
            if (seconds != null && seconds > 0) {
                BridgeDetourEnd.start(seconds * 1000);
            }
        }
    } else if (command.find("NOFIX:") == 0) {
        // C13b: `PONTE:CMD:NOFIX:<s>` opens a hole of <s> seconds in the virtual bike's
        // fixes, and `PONTE:CMD:POS` turns on the `PONTE:POS` line of each step.
        var seconds = command.substring(6, command.length()).toNumber();
        app.setReplayHole(seconds == null ? 0 : seconds);
    } else if (command.equals("POS")) {
        app.setReplayReport();
    } else if (command.find("DATA:") == 0) {
        // C16.6: `PONTE:CMD:DATA:<base64>` delivers a protocol message as if it came
        // from the phone. It is how `tools/e2e.py --config` sends the CONFIG: the companion's `sim`
        // variant does not have `ConfigReceiver` (it lives in `src/debug`).
        app.onPhoneData(command.substring(5, command.length()));
    } else if (command.equals("FAV:OPEN")) {
        // C12: the SDK 9.2.0 simulator delivers neither key nor touch to the app (measured on
        // 2026-10-13: Enter by PostMessage, SendKeys and a real click, 0 of 12). The same
        // path as SELECT on Home, only through the command channel.
        pushFavorites();
    } else if (command.find("FAV:PICK:") == 0) {
        var n = command.substring(9, command.length()).toNumber();
        if (n != null && n >= 1 && n <= Favorites.count()) {
            var i = (n as Number) - 1;
            var item = new WatchUi.MenuItem(Favorites.labelAt(i), null, Favorites.ids[i], {});
            new FavoritesDelegate().onSelect(item);
        }
    }
}

//! The virtual bike's position, one step per line: `PONTE:POS:<latE5>,<lonE5>,
//! <m/s>,<heading in degrees>`. `tools/e2e.py --no-fix` reads it and moves the emulator's GPS,
//! so the phone fix is the bike's and not the start line's.
function bridgePosition(latE5 as Number, lonE5 as Number, speed as Float, headingRad as Float) as Void {
    var degrees = (headingRad * 180.0 / Math.PI + 0.5).toNumber() % 360;
    if (degrees < 0) {
        degrees += 360;
    }
    System.println("PONTE:POS:" + latE5.toString() + "," + lonE5.toString() + "," + speed.format("%.1f")
        + "," + degrees.toString());
}

//! The phone fix that moved the map: `PONTE:FIX:<latE5>,<lonE5>,<accuracy m>,
//! <age ms>,<heading in degrees, -1 = unknown>`. The e2e compares it with the last
//! `PONTE:POS` line: how far behind the bike the position is and whether the heading is its.
function bridgePhoneFix(latE5 as Number, lonE5 as Number, accuracyM as Number, ageMs as Number,
        headingDeg as Number) as Void {
    System.println("PONTE:FIX:" + latE5.toString() + "," + lonE5.toString() + "," + accuracyM.toString()
        + "," + ageMs.toString() + "," + headingDeg.toString());
}

class BridgeListener extends Communications.ConnectionListener {

    static const C2R = "PONTE:C2R:";
    static const R2C = "PONTE:R2C:";
    static const CMD = "PONTE:CMD:";

    private var _id as String;

    function initialize(id as String) {
        ConnectionListener.initialize();
        _id = id;
    }

    function onComplete() as Void {
        System.println("bridge r2c " + _id + " transmit ok");
    }

    function onError() as Void {
        System.println("bridge r2c " + _id + " transmit ERROR");
    }
}

//! The real `demoStart` and `phoneTransmit` live in `DemoHook.mc` under the
//! same annotation (`nodemo`), which `ponte.jungle` excludes to swap the second one.
function demoStart() as Void {
}

//! Watch → phone **by relay**: the `PONTE:TX:<texto>` line comes out on the console,
//! and `tools/ponte.py` hands it to the companion through `adb shell am broadcast`.
//!
//! It exists because `Communications.transmit` over `TETHERED` does not work in the
//! SDK 9.2.0 simulator (known bug, CIQQA-4579 / CIQQA-4735, no
//! fix). Measured on the Windows dev PC on 2026-10-09: with the real `transmit` the app
//! printed `PONTE:C2R` and froze right away — 20 s without a tick, with no
//! `onComplete` or `onError`, and nothing on the phone (`DECISIONS.md` §C7a).
(:bridge_relay)
function phoneTransmit(text as String, listener as Communications.ConnectionListener) as Void {
    System.println("PONTE:TX:" + text);
    listener.onComplete();
}

//! The real `transmit`, only in `ponte_socket.jungle` (`ponte.py --socket`):
//! reproduces the freeze, and is how you check whether a new SDK fixed it.
(:bridge_socket)
function phoneTransmit(text as String, listener as Communications.ConnectionListener) as Void {
    Communications.transmit(text, null, listener);
}

//! The end of the detour with a deadline (`DETOUR:<m>:<s>`).
class BridgeDetourEnd {
    private static var _timer as Timer.Timer? = null;

    static function start(ms as Number) as Void {
        var timer = new Timer.Timer();
        _timer = timer;
        timer.start(new BridgeDetourEnd().method(:onEnd), ms, false);
    }

    function onEnd() as Void {
        (getApp() as MotoNavApp).setReplayDetour(0.0);
        _timer = null;
    }
}
