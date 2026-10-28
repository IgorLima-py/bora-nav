import Toybox.Lang;
import Toybox.System;

//! The watch's event trail, visible on the screen itself (SELECT button).
//!
//! The watch has no logcat: when the link to the phone fails, the only diagnostic
//! channel left is the screen. It keeps the last [CAPACITY] lines with the
//! time of each, so the sequence can be reconstructed — "arrived,
//! decoded, applied, ACK went out" — instead of just seeing the final number.
//!
//! Rules: short line (fits in ~26 characters on the screen) and no allocating per
//! event beyond the line itself.
module Diag {

    const CAPACITY = 24;

    var lines as Array<String> = [] as Array<String>;

    //! How many lines have already been sent to the phone, so each flush carries only
    //! what is new instead of repeating the whole screen.
    var sent as Number = 0;

    //! Lines that left the ring **before** being sent: an `add` that goes
    //! past [CAPACITY] with the phone not listening. The next [take] starts with a
    //! line saying how many there were, instead of the loss being indistinguishable from
    //! "nothing happened".
    var lost as Number = 0;
    var _reportedLost as Number = 0;

    //! `t` is seconds since the app's start, enough to order and measure.
    function add(line as String) as Void {
        var seconds = System.getTimer() / 1000;
        var stamped = seconds.toString() + "s " + line;
        echo(stamped);
        lines.add(stamped);
        if (lines.size() > CAPACITY) {
            lines = lines.slice(1, null);
            if (sent > 0) {
                sent--;
            } else {
                lost++;
            }
        }
    }

    //! In the debug build, each line also goes to the simulator console, where
    //! `tools/sim.py` reads it — until C2a no `System.println` got there,
    //! and the simulator ran mute. The `[diag]` prefix separates these lines from the output
    //! of the tests. In release (`-r` excludes `:debug`) the function is empty and the
    //! watch pays nothing.
    (:debug)
    function echo(line as String) as Void {
        System.println("[diag] " + line);
    }

    (:release)
    function echo(line as String) as Void {
    }

    //! The lines not yet sent, whole, up to [maxChars] characters, joined
    //! by newlines; marks the ones it took as sent. Empty string = nothing new. What
    //! did not fit stays for the next send: the byte cut that `PhoneLink` used to have
    //! threw away the start of the message without saying so.
    function take(maxChars as Number) as String {
        var text = "";
        if (lost > _reportedLost) {
            var report = "log lost " + (lost - _reportedLost).toString() + " lines";
            if (report.length() <= maxChars) {
                text = report;
                _reportedLost = lost;
            }
        }
        while (sent < lines.size()) {
            var line = lines[sent];
            var need = line.length() + (text.length() > 0 ? 1 : 0);
            if (text.length() + need > maxChars) {
                break;
            }
            text += (text.length() > 0 ? "\n" : "") + line;
            sent++;
        }
        return text;
    }

    function clear() as Void {
        lines = [] as Array<String>;
        sent = 0;
        lost = 0;
        _reportedLost = 0;
    }
}
