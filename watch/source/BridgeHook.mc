import Toybox.Lang;

//! Hook for the bridge proof (C7a).
//!
//! In the real app it is empty and returns `false`: every message goes on to
//! `PhoneData`. `watch/ponte.jungle` excludes the `nobridge` annotation and adds
//! `watch/ponte/source`, where the code that recognizes `PONTE:C2R:<id>`, prints and
//! replies `PONTE:R2C:<id>` lives. `sim.py tudo` checks in the release
//! `.prg.debug.xml` that nothing from `watch/ponte` got in.
(:nobridge)
function bridgeMessage(data as Object?) as Boolean {
    return false;
}

//! Where the virtual motorcycle is, at each step (C13b). In the real app it does
//! nothing; on the bridge it prints `PONTE:POS:...` so `tools/e2e.py --no-fix` carries
//! the emulator's GPS along with the motorcycle.
(:nobridge)
function bridgePosition(latE5 as Number, lonE5 as Number, speed as Float, headingRad as Float) as Void {
}

//! The phone fix that the watch just used (C13b). In the real app it does
//! nothing; on the bridge it prints `PONTE:FIX:...` so `tools/e2e.py --no-fix`
//! measures how far behind the motorcycle that position is.
(:nobridge)
function bridgePhoneFix(latE5 as Number, lonE5 as Number, accuracyM as Number, ageMs as Number,
        headingDeg as Number) as Void {
}
