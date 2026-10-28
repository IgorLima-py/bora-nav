import Toybox.Lang;
import Toybox.System;

//! The clock that the track recorder and the "no fix" detector read.
//!
//! On the real watch it is `System.getTimer()` and nothing else (`virtualMs` stays
//! `null`). The simulator's compressed virtual ride (`--speed 4`) runs 4 s of
//! motorcycle per wall-clock second; if the recorder and the detector read the wall clock, the
//! recorder's 5 s interval would become 20 s of motorcycle and a 25 s GPS gap
//! would pass in 6 s, never reaching the 20 s threshold. Whoever compresses time
//! (`ReplayRunner` with a virtual clock, the demo's `TrackPlayer`) pins
//! `virtualMs` to the motorcycle's time. Pinned, not added to the wall clock: with a jitter of
//! a few ms between one fix and the next the recorder sometimes recorded and sometimes skipped a 5,000 ms
//! fix, and the expected count stopped being exact.
module Clock {

    var virtualMs as Number? = null;

    function nowMs() as Number {
        var virtual = virtualMs;
        return virtual != null ? virtual : System.getTimer();
    }
}
