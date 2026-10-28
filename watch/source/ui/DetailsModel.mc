import Toybox.Lang;
import Toybox.Math;

//! What the Details screen shows (C9, `01 §Watch screens`), built without touching
//! a `Dc`: the screen only draws these lines, and `DetailsTest` checks each one
//! without needing pixels (Connect IQ does not return pixels).
//!
//! Content: the next [MAX_UPCOMING] maneuvers with distance and street, the
//! route's **total** distance and time, what is left, the battery and the
//! end button.
class DetailsModel {

    const MAX_UPCOMING = 3;

    //! The "End route" button, in px of the 454 screen: 220 wide, centered,
    //! from y 326 to 396. It fits in the chord of the round screen (at 396 the chord is 303 px).
    static const BTN_LEFT = 117;
    static const BTN_RIGHT = 337;
    static const BTN_TOP = 326;
    static const BTN_BOTTOM = 396;

    var destination as String = "";
    //! One string per maneuver: `150 m · Direita · Rua 0`.
    var upcoming as Array<String> = [] as Array<String>;
    //! The types of the [upcoming] maneuvers, in the same order (the screen uses them for
    //! the color).
    var upcomingTypes as Array<Number> = [] as Array<Number>;
    var total as String = "";
    var left as String = "";
    var battery as String = "";
    var endLabel as String = "";

    //! `batteryPct` in %, like `System.getSystemStats().battery`.
    function initialize(route as RouteModel, matcher as MapMatcher, batteryPct as Float, armed as Boolean) {
        destination = route.destName;

        var index = matcher.nextTurnIndex();
        var count = 0;
        if (index >= 0) {
            for (var i = index; i < route.turnPointIdx.size() && count < MAX_UPCOMING; i++) {
                var pointIdx = route.turnPointIdx[i] as Number;
                if (pointIdx >= route.cum.size()) {
                    continue;
                }
                var ahead = (route.cum[pointIdx] as Float) - matcher.distAlong;
                if (ahead < 0.0) {
                    ahead = 0.0;
                }
                var type = i < route.turnType.size() ? route.turnType[i] as Number : Protocol.TURN_STRAIGHT;
                var street = i < route.turnName.size() ? route.turnName[i] as String : "";
                var text = NavEngine.formatDistance(ahead) + " · " + turnWord(type, route, i);
                if (street.length() > 0) {
                    text += " · " + street;
                }
                upcoming.add(text);
                upcomingTypes.add(type);
                count++;
            }
        }
        if (count == 0) {
            upcoming.add(Tr.s(Rez.Strings.NoTurnsAhead));
            upcomingTypes.add(-1);
        }

        total = Fmt.km(route.distanceM / 1000.0) + " km · "
            + NavEngine.formatDuration(route.durationS);
        left = Tr.f(Rez.Strings.DistanceLeft, [NavEngine.formatDistance(matcher.remainingM())]);
        battery = Tr.f(Rez.Strings.BatteryPct, [Math.round(batteryPct).toNumber()]);
        endLabel = Tr.s(Rez.Strings.MenuEndRoute);
        if (armed) {
            endLabel = Tr.s(Rez.Strings.TapAgain);
        }
    }

    //! The maneuver in words, without the street name.
    static function turnWord(type as Number, route as RouteModel, index as Number) as String {
        if (type == Protocol.TURN_STRAIGHT || type == Protocol.TURN_NEW_NAME) {
            return Tr.s(Rez.Strings.TurnStraight);
        }
        if (type == Protocol.TURN_SLIGHT_RIGHT) { return Tr.s(Rez.Strings.TurnSlightRight); }
        if (type == Protocol.TURN_RIGHT) { return Tr.s(Rez.Strings.TurnRight); }
        if (type == Protocol.TURN_SHARP_RIGHT) { return Tr.s(Rez.Strings.TurnSharpRight); }
        if (type == Protocol.TURN_UTURN) { return Tr.s(Rez.Strings.TurnUTurn); }
        if (type == Protocol.TURN_SHARP_LEFT) { return Tr.s(Rez.Strings.TurnSharpLeft); }
        if (type == Protocol.TURN_LEFT) { return Tr.s(Rez.Strings.TurnLeft); }
        if (type == Protocol.TURN_SLIGHT_LEFT) { return Tr.s(Rez.Strings.TurnSlightLeft); }
        if (Protocol.hasExitNum(type)) {
            if (index < route.turnExit.size()) {
                var exit = route.turnExit[index] as Number;
                if (exit > 0) {
                    return Tr.f(Rez.Strings.TurnRoundaboutExit, [exit]);
                }
            }
            return Tr.s(Rez.Strings.TurnRoundabout);
        }
        if (type == Protocol.TURN_HIGHWAY_ENTER) { return Tr.s(Rez.Strings.TurnHighwayEnter); }
        if (type == Protocol.TURN_HIGHWAY_EXIT) { return Tr.s(Rez.Strings.TurnHighwayExit); }
        if (type == Protocol.TURN_HIGHWAY_ENTER_LEFT) { return Tr.s(Rez.Strings.TurnHighwayEnterLeft); }
        if (type == Protocol.TURN_HIGHWAY_EXIT_LEFT) { return Tr.s(Rez.Strings.TurnHighwayExitLeft); }
        if (type == Protocol.TURN_FORK_LEFT) { return Tr.s(Rez.Strings.TurnForkLeft); }
        if (type == Protocol.TURN_FORK_RIGHT) { return Tr.s(Rez.Strings.TurnForkRight); }
        if (type == Protocol.TURN_MERGE) { return Tr.s(Rez.Strings.TurnMerge); }
        if (type == Protocol.TURN_MERGE_LEFT) { return Tr.s(Rez.Strings.TurnMergeLeft); }
        if (type == Protocol.TURN_MERGE_RIGHT) { return Tr.s(Rez.Strings.TurnMergeRight); }
        if (type == Protocol.TURN_ARRIVE_LEFT) { return Tr.s(Rez.Strings.TurnArriveLeft); }
        if (type == Protocol.TURN_ARRIVE_RIGHT) { return Tr.s(Rez.Strings.TurnArriveRight); }
        if (type == Protocol.TURN_ARRIVE) { return Tr.s(Rez.Strings.TurnArrive); }
        if (type == Protocol.TURN_DEPART) { return Tr.s(Rez.Strings.TurnDepart); }
        return Tr.s(Rez.Strings.TurnContinue);
    }

    //! Did the touch land on the end button?
    static function hitsEnd(x as Number, y as Number) as Boolean {
        return x >= BTN_LEFT && x <= BTN_RIGHT && y >= BTN_TOP && y <= BTN_BOTTOM;
    }
}

//! The two-tap confirmation of "End route". On a motorcycle, with gloves and
//! vibration, a single tap would erase the route by accident: the first arms, the
//! second within [WINDOW_MS] confirms. **Only this ends the route** —
//! BACK remains what leaves the screen (`NavView.mc`, the trap from
//! `v0.9.0-f2`).
class EndConfirm {

    //! 4 s: time to watch the label change and tap again with the glove.
    const WINDOW_MS = 4000;

    private var _armedAt as Number = -1;

    //! A tap on the button. `true` = confirmed (and the state goes back to disarmed).
    function tap(nowMs as Number) as Boolean {
        if (isArmed(nowMs)) {
            _armedAt = -1;
            return true;
        }
        _armedAt = nowMs;
        return false;
    }

    function isArmed(nowMs as Number) as Boolean {
        return _armedAt >= 0 && nowMs - _armedAt <= WINDOW_MS;
    }
}
