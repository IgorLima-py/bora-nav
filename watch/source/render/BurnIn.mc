import Toybox.Lang;
import Toybox.System;

//! The HUD's slow orbit against burn-in (C10).
//!
//! **What Garmin requires and what this is.** The official pixel rule
//! (`DeviceSettings.requiresBurnInProtection`: at most 10% of the screen lit and
//! no pixel for more than 3 cycles of 1 min) applies to the watch face's **low-power
//! mode** (`onEnterSleep`). A foreground app like this one stays in high power
//! and the system does not force anything on it; the documentation also does
//! not tell the app to shift its content (`DECISIONS.md` §2026-10-10 — C10, with the
//! URLs). The orbit is therefore **our own caution**: the HUD stays lit for hours in the
//! same place (time, arrow, cards) with the map moving underneath, and what stays
//! still is what marks the panel.
//!
//! **The shape.** The HUD visits 8 points of a ring of radius `orbit_px` (Chebyshev),
//! one every `orbit_s` seconds, in ring order. Maximum step of 60 s: so the
//! shift of one minute is never that of the next minute. The shift is a
//! function of the clock time (seconds of the day), not of the time the app has been open,
//! so opening the app does not always restart at the same point.
//!
//! This **spreads** the wear, it does not eliminate it: a stroke wider than the
//! amplitude still has a lit core. It is mitigation, and the real effect can only be
//! confirmed over weeks of use (the C16 rides do not prove burn-in).
module BurnIn {

    //! Ring points, in amplitude units (-1, 0 or 1 on each axis).
    const POINTS = 8;
    const RING_X = [1, 1, 0, -1, -1, -1, 0, 1] as Array<Number>;
    const RING_Y = [0, 1, 1, 1, 0, -1, -1, -1] as Array<Number>;

    //! Fixed ring point (0..7) imposed from outside, or -1 to follow the time. Only
    //! `sim.py shots --burnin` touches this (`demo/burnin/BurnInStart.mc`): the photo
    //! needs two known points of the orbit.
    var forced as Number = -1;

    //! Seconds since midnight, on the device clock.
    function secondsOfDay() as Number {
        var now = System.getClockTime();
        return now.hour * 3600 + now.min * 60 + now.sec;
    }

    //! The ring point (0..7) at `seconds`, with `stepS` seconds per point. If
    //! `stepS` does not divide the day into multiples of 8, midnight repeats a point
    //! once; it is harmless and not worth a 64-bit clock.
    function index(seconds as Number, stepS as Number) as Number {
        var step = stepS < 1 ? 1 : stepS;
        return (seconds / step) % POINTS;
    }

    //! Shift in x of point `index` with amplitude `amp` px.
    function dx(index as Number, amp as Number) as Number {
        return (RING_X[index % POINTS] as Number) * amp;
    }

    function dy(index as Number, amp as Number) as Number {
        return (RING_Y[index % POINTS] as Number) * amp;
    }
}
