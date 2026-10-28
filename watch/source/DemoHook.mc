import Toybox.Communications;
import Toybox.Lang;

//! Hooks of the simulator demo build (C2b).
//!
//! In the real app it is empty. `watch/demo.jungle` excludes the `nodemo` annotation
//! and adds `watch/demo/source`, where `demoStart` lives, injecting the route and
//! the São Paulo corridor. `monkey.jungle` never sees that folder, and
//! `sim.py tudo` checks in the release `.prg.debug.xml` that `DemoFeed` did not
//! get in.
(:nodemo)
function demoStart() as Void {
}

//! The real `transmit`. In the demo build it is swapped for one that confirms
//! immediately: in the simulator without a phone, the `transmit` of the first ACK froze the
//! whole app (measured on 2026-09-29: after `ack-> 0x01`, not even the 10 s telemetry
//! went out anymore, for 120 s).
(:nodemo)
function phoneTransmit(text as String, listener as Communications.ConnectionListener) as Void {
    Communications.transmit(text, null, listener);
}
