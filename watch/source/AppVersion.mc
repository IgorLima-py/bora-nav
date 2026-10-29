import Toybox.Lang;

//! Build tag drawn on every screen of the app.
//!
//! It exists for a practical reason: a sideloaded app has no visual hint
//! of which build is on the watch — the F0 home screen and the F1 one were identical
//! byte for byte, so you could spend an hour debugging BLE with the old
//! `.prg` installed. Here the screen answers "did it update?" by itself.
//!
//! **Bump on every new `.prg` copied to the watch.** This version is
//! independent from the companion's: they need not match, each screen only has to
//! prove which build is running on that device (docs/ESTADO.md §Versioning).
module AppVersion {

    const LABEL = "v1.5.0";
}
