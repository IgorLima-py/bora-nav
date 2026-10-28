import Toybox.Lang;
import Toybox.Test;

//! **The canary: a test that fails on purpose.**
//!
//! A test command that has never been seen failing proves nothing — it may be
//! reading the wrong line, running the old binary or swallowing the exit code.
//! This test only enters the build with `python tools/sim.py test --canary` (the
//! `watch/canary.jungle` removes `canary` from the exclusion list of
//! `monkey.jungle`), and with it `sim.py` **must** exit ≠ 0. If it exits 0, the
//! instrument is blind and no "passed" from it is worth anything.
(:test :canary)
function canaryMustFail(logger as Logger) as Boolean {
    Test.assertMessage(false, "canary: fails on purpose (sim.py test --canary)");
    return true;
}
