import Toybox.Attention;
import Toybox.Lang;
import Toybox.System;

//! When to vibrate and with which pattern (`03 §Vibration`, RF-07).
//!
//! **Vibration is the only channel that works on a motorcycle.** Sound does not get through the
//! helmet and looking at the screen costs a second of road, so the turn warning is the moment
//! this app stops being a pretty map and becomes navigation.
//!
//! Two rules drive the design:
//!
//! 1. **The lead time is proportional to speed**, not fixed: 80 m at 30 km/h is almost 10 s
//!    to spare; at 100 km/h it is under 3 s, and the warning arrives together with the turn.
//!    Hence `max(80 m, speed × 8 s)`.
//! 2. **At most two warnings per maneuver.** One extra pulse becomes background noise, and
//!    background noise is ignored exactly when it matters.
class AlertPolicy {

    // The lead seconds of the 1st warning (8 s), its floor in meters (80 m: when slow, time is
    // plentiful and what is missing is distance, so the warning does not coincide with the corner)
    // and the distance of the 2nd warning, right at the turn (25 m), come from the fine tuning
    // (`Config`, C5): the rider changes them from the phone, without a sideload.

    //! Below this the second warning is pointless: when slow, the rider already sees the
    //! corner. The 20 km/h of `03 §Vibration`; it was 5.5 m/s (19.8 km/h), and the C3a virtual
    //! ride checks against the rule, not against the rounding.
    const NEAR_MIN_SPEED_MPS = 20.0 / 3.6;

    //! Which maneuver was already warned, and up to which stage (1 = far, 2 = near).
    private var _turnIndex as Number = -1;
    private var _stage as Number = 0;

    private var _arrivalAlerted as Boolean = false;

    //! How many warnings went out since the last [reset]. It exists so the test can
    //! assert "at most two per maneuver" without depending on the vibration motor,
    //! and so the log can say whether silence on the road was policy or a defect.
    var alerts as Number = 0;

    //! Where, in meters along the route, the last warned speed camera is (C16.6): each one vibrates once,
    //! when its sign appears. The position, not the index: the cache list is swapped by the new search
    //! in the middle of the route, and the same index becomes another camera.
    private var _radarWarnedM as Number = -1;

    //! A camera closer than this to the last warned one is the same, recomputed in the new list: it is the
    //! distance at which the phone's `RadarFilter` merges duplicates (50 m).
    const RADAR_SAME_M = 50;
    var radarAlerts as Number = 0;

    //! How many times the motor was actually called, after all the switches (C16.6). The
    //! vibration-off test reads from here, because the simulator has no motor to check.
    var motorCalls as Number = 0;

    function initialize() {
    }

    //! New route, or route ended: nothing has been warned yet.
    function reset() as Void {
        _turnIndex = -1;
        _stage = 0;
        _arrivalAlerted = false;
        alerts = 0;
        _radarWarnedM = -1;
        radarAlerts = 0;
    }

    //! **The speed camera warning** (C16.6): on every fix, a long buzz when a camera sign appears
    //! (`Radars.shown`), once per camera. It vibrates through its own switch, `Config.radarVibrate`
    //! (CONFIG 22, Igor's choice), not the turn-warning one. The log is written with or without a motor.
    function updateRadar(route as RouteModel, distAlong as Float, speedMps as Float) as Void {
        var kmh = (speedMps * 3.6 + 0.5).toNumber();
        var i = Radars.shown(route, distAlong, kmh);
        if (i < 0) {
            return;
        }
        var at = route.radarDist[i] as Number;
        // `<`, like `RadarFilter`: two cameras exactly 50 m apart are two there (C16.7, the 50 m tie).
        if (_radarWarnedM >= 0 && at < _radarWarnedM + RADAR_SAME_M) {
            return;
        }
        _radarWarnedM = at;
        radarAlerts++;
        // `d` is the camera's distance along the route, the same as the phone's `radar i/n` line: it is
        // how `tools/relatorio.py` finds the OSM id (C16.7). The index changes with the list.
        Diag.add("vibe radar " + i.toString() + " at " + (at - distAlong.toNumber()).toString()
            + "m " + kmh.toString() + "km/h d" + at.toString());
        vibrateIf(Config.radarVibrate(), [new Attention.VibeProfile(100, 600)] as Array<Attention.VibeProfile>);
    }

    //! Call on every fix. Negative `turnIndex` = there is no next maneuver.
    function update(
        turnIndex as Number,
        turnType as Number,
        distanceM as Float,
        speedMps as Float
    ) as Void {
        if (turnIndex < 0 || !vibrates(turnType)) {
            return;
        }
        // **The maneuver only moves forward.** With 15 m of GPS noise the match crosses the
        // point of a turn back and forth, and the "next maneuver" goes back to the previous one for a
        // fix: without this guard, it got both warnings again. Measured on the noisy C3b track
        // (`sim.py ride --track`): turn 6 warned again after 7, and 11 after 12. A new route resets it
        // through [reset].
        if (turnIndex < _turnIndex) {
            return;
        }
        if (turnIndex != _turnIndex) {
            _turnIndex = turnIndex;
            _stage = 0;
        }

        if (_stage == 0 && distanceM >= 0.0 && distanceM <= leadDistance(speedMps)) {
            _stage = 1;
            fire(turnIndex, turnType, distanceM, speedMps);
            // Tight turn: the 1st warning already went out within 25 m, so it is the
            // "near" warning. A 2nd on the next fix would arrive while the first is
            // still vibrating (Igor's decision, DECISIONS §C3a).
            if (distanceM <= Config.nearM()) {
                _stage = 2;
            }
            return;
        }

        if (_stage == 1 && nearAlertOn()
                && distanceM >= 0.0 && distanceM <= Config.nearM() && speedMps > NEAR_MIN_SPEED_MPS) {
            _stage = 2;
            fire(turnIndex, turnType, distanceM, speedMps);
        }
    }

    //! Vibrates and logs **both** warnings, with what the rule used to decide. The
    //! second did not log, and without it the virtual ride (C3a) could not tell
    //! whether silence at 25 m was the rule or a defect. `sim.py ride` reads this line.
    private function fire(turnIndex as Number, turnType as Number, distanceM as Float, speedMps as Float) as Void {
        alerts++;
        var profile = patternFor(turnType);
        vibrate(profile);
        Diag.add("vibe turn " + turnIndex.toString() + " alert " + _stage.toString()
            + " at " + distanceM.format("%.1f") + "m " + (speedMps * 3.6).format("%.1f") + "km/h "
            + ((profile.size() + 1) / 2).toString() + "p");
    }

    //! The second warning exists. The twin `(:no_near_alert)` is the canary of
    //! `tools/sim.py ride --canary`: without the 2nd warning, the ride MUST fail.
    (:near_alert)
    function nearAlertOn() as Boolean {
        return true;
    }

    (:no_near_alert)
    function nearAlertOn() as Boolean {
        return false;
    }

    //! Maneuver that gets a turn warning. Left out are the start (it is never the
    //! next), the arrival, with or without the side (C16.5), which has its own pattern in
    //! [alertArrival], and "go straight", which is not a turn (Igor's decisions, DECISIONS §C3a).
    function vibrates(turnType as Number) as Boolean {
        return turnType != Protocol.TURN_DEPART
            && turnType != Protocol.TURN_STRAIGHT
            && turnType != Protocol.TURN_NEW_NAME
            && !Protocol.isArrival(turnType);
    }

    //! Arrival (RF-12): once only, in a pattern that is not mistaken for a turn.
    function alertArrival() as Void {
        if (_arrivalAlerted) {
            return;
        }
        _arrivalAlerted = true;
        vibrate([
            new Attention.VibeProfile(100, 500),
            new Attention.VibeProfile(0, 200),
            new Attention.VibeProfile(100, 200),
            new Attention.VibeProfile(0, 200),
            new Attention.VibeProfile(100, 500)
        ] as Array<Attention.VibeProfile>);
        Diag.add("vibe arrival");
    }

    //! Left the route (RF-11): one long 600 ms pulse, the "off-route" of
    //! `03 §Vibration`. Fixed, outside the fine tuning's `pulse_ms`: it is the only warning
    //! that is not a turn, and it must not be mistaken for any of the turn ones. Once
    //! per exit (the detector only fires on the exit, not on new attempts).
    function alertOffRoute() as Void {
        vibrate([new Attention.VibeProfile(100, 600)] as Array<Attention.VibeProfile>);
        Diag.add("vibe off route");
    }

    function leadDistance(speedMps as Float) as Float {
        var bySpeed = speedMps * Config.leadSeconds();
        var floor = Config.leadMinM();
        return bySpeed > floor ? bySpeed : floor;
    }

    //! Left and right have **different pulse counts** (2 and 3), not
    //! different durations: inside the glove and with the bike vibrating, counting pulses
    //! is what can still be told apart. A non-side turn gets a single long
    //! pulse, meaning "look at the screen". The short pulse is the fine tuning's `pulse_ms`
    //! (`Config`, default 200 ms) and the long one is double it (Igor's decision,
    //! DECISIONS §C5). The fork takes a side like a turn (C16.5: until then it
    //! arrived as slight left/right); junction, ramp and roundabout stay on the long pulse.
    function patternFor(turnType as Number) as Array<Attention.VibeProfile> {
        var pulses = 1;
        var length = 2 * Config.pulseMs();

        if (turnType == Protocol.TURN_LEFT
                || turnType == Protocol.TURN_SLIGHT_LEFT
                || turnType == Protocol.TURN_SHARP_LEFT
                || turnType == Protocol.TURN_FORK_LEFT) {
            pulses = 2;
            length = Config.pulseMs();
        } else if (turnType == Protocol.TURN_RIGHT
                || turnType == Protocol.TURN_SLIGHT_RIGHT
                || turnType == Protocol.TURN_SHARP_RIGHT
                || turnType == Protocol.TURN_FORK_RIGHT) {
            pulses = 3;
            length = Config.pulseMs();
        }

        var profile = [] as Array<Attention.VibeProfile>;
        for (var i = 0; i < pulses; i++) {
            if (i > 0) {
                profile.add(new Attention.VibeProfile(0, 150));
            }
            profile.add(new Attention.VibeProfile(100, length));
        }
        return profile;
    }

    //! **On and off from the phone** (`Config.vibrateOn`, CONFIG 21, C16 v1.2.7; off
    //! since the C6b bench, 2026-10-02). The warning rule runs and logs (`vibra curva ...`,
    //! which `sim.py ride` reads to prove the ride) with vibration on or not; only the motor stays idle.
    //!
    //! Respects the watch setting: whoever turned vibration off on the device does not
    //! want a sideloaded app deciding otherwise. And the `has` covers the case of
    //! a device with no motor at all.
    function vibrate(profile as Array<Attention.VibeProfile>) as Void {
        vibrateIf(Config.vibrateOn(), profile);
    }

    //! The [vibrate] with the given switch: the turn-warning one or the speed camera one.
    function vibrateIf(on as Boolean, profile as Array<Attention.VibeProfile>) as Void {
        if (!on) {
            return;
        }
        if (!(Attention has :vibrate)) {
            return;
        }
        var settings = System.getDeviceSettings();
        if ((settings has :vibrateOn) && !settings.vibrateOn) {
            return;
        }
        try {
            motorCalls++;
            Attention.vibrate(profile);
        } catch (ex) {
            // A profile refused by the hardware must not take navigation down
            // (`03 §Vibration`: degrade, never crash).
            Diag.add("vibration refused");
        }
    }
}
