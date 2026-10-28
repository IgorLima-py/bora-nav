#!/usr/bin/env python3
"""The warnings the virtual ride MUST give, computed by the rule (C3a).

Why this script exists
----------------------
``tools/sim.py ride`` makes the motorcycle ride the whole route in the simulator and reads each
vibration the watch gave. To tell whether a vibration was right, it needs a yardstick that is
**not the watch code**: checking the watch against itself always passes. The yardstick is the
rule written in ``docs/03-WATCH-APP.md`` §Vibration, applied here in Python over the same route
and the same speed profile the watch will run:

* 1st warning when ``distToNextTurn ≤ max(80 m, speed × 8 s)``;
* 2nd warning at 25 m, if the speed is still above 20 km/h;
* never more than 2 per maneuver.

And Igor's decisions of 2026-09-29 (``docs/DECISIONS.md`` §C3a):

* arrival vibrates only the arrival pattern, at 30 m, and not the turn one;
* "keep straight" (``STRAIGHT``, ``NEW_NAME``) does not vibrate;
* stuck turn: if the 1st warning already went out at ≤ 25 m, it is the "near" warning and
  there is no 2nd.

**The ride profile lives here.** ``sim.py ride`` writes the ``profile`` block of
``.esperado.json`` into a ``RideParams.mc`` on every run; the watch's ``ReplaySource`` only
executes it. Both sides implement the same function ``v(s)``, and ``sim.py`` checks the speed the
watch logged at each warning against the one computed here — that is what catches the two
profiles diverging.

Usage::

    python tools/esperado.py --fixture tiete_copan
    # writes tools/fixtures/tiete_copan.esperado.json
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import packer  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"

# --------------------------------------------------------------------------- #
# The rule (03 §Vibration), with the C3a decisions
# --------------------------------------------------------------------------- #

LEAD_S = 8.0          # 03 §Vibration: speed × 8 s
LEAD_MIN_M = 80.0     # 03 §Vibration: floor of 80 m
NEAR_M = 25.0         # 03 §Vibration: 2nd warning at 25 m
NEAR_MIN_KMH = 20.0   # 03 §Vibration: only above 20 km/h
ARRIVAL_M = 30.0      # 01 / RF-12: arrived at 30 m from the end

#: The fork takes one side as the turn (C16.5): until C16.5 it came through `modifier` as a
#: slight left/right, with the same count. Merge, ramp and roundabout: 1 long pulse.
LEFT = {packer.TURN_LEFT, packer.TURN_SLIGHT_LEFT, packer.TURN_SHARP_LEFT, packer.TURN_FORK_LEFT}
RIGHT = {packer.TURN_RIGHT, packer.TURN_SLIGHT_RIGHT, packer.TURN_SHARP_RIGHT, packer.TURN_FORK_RIGHT}

#: Types that do not vibrate as a turn: departure is never "next", arrival has its own
#: pattern and "keep straight" is not a turn (Igor's decisions, 2026-09-29). Arrival
#: with the side (19 and 20, C16.5) is arrival.
SILENT = {packer.TURN_DEPART, packer.TURN_STRAIGHT, packer.TURN_NEW_NAME, packer.TURN_ARRIVE,
          packer.TURN_ARRIVE_LEFT, packer.TURN_ARRIVE_RIGHT}

TURN_NAMES = {
    packer.TURN_DEPART: "departure", packer.TURN_STRAIGHT: "straight",
    packer.TURN_SLIGHT_RIGHT: "slight_right", packer.TURN_RIGHT: "right",
    packer.TURN_SHARP_RIGHT: "sharp_right", packer.TURN_UTURN: "u_turn",
    packer.TURN_SHARP_LEFT: "sharp_left", packer.TURN_LEFT: "left",
    packer.TURN_SLIGHT_LEFT: "slight_left", packer.TURN_ROUNDABOUT: "roundabout",
    packer.TURN_HIGHWAY_ENTER: "highway_enter", packer.TURN_HIGHWAY_EXIT: "highway_exit",
    packer.TURN_ARRIVE: "arrive", packer.TURN_NEW_NAME: "new_name",
    packer.TURN_FORK_LEFT: "fork_left", packer.TURN_FORK_RIGHT: "fork_right",
    packer.TURN_MERGE: "merge", packer.TURN_MERGE_LEFT: "merge_left",
    packer.TURN_MERGE_RIGHT: "merge_right", packer.TURN_ARRIVE_LEFT: "arrive_left",
    packer.TURN_ARRIVE_RIGHT: "arrive_right",
    packer.TURN_ROUNDABOUT_SHARP_RIGHT: "roundabout_sharp_right",
    packer.TURN_ROUNDABOUT_RIGHT: "roundabout_right",
    packer.TURN_ROUNDABOUT_SLIGHT_RIGHT: "roundabout_slight_right",
    packer.TURN_ROUNDABOUT_STRAIGHT: "roundabout_straight",
    packer.TURN_ROUNDABOUT_SLIGHT_LEFT: "roundabout_slight_left",
    packer.TURN_ROUNDABOUT_LEFT: "roundabout_left",
    packer.TURN_ROUNDABOUT_SHARP_LEFT: "roundabout_sharp_left",
    packer.TURN_ROUNDABOUT_UTURN: "roundabout_u_turn",
    packer.TURN_HIGHWAY_ENTER_LEFT: "highway_enter_left", packer.TURN_HIGHWAY_EXIT_LEFT: "highway_exit_left",
}


def pulses_for(turn_type: int) -> int:
    """Left 2, right 3, the rest 1 long pulse (03 §Vibration, DECISIONS §F3a)."""
    if turn_type in LEFT:
        return 2
    if turn_type in RIGHT:
        return 3
    return 1


# --------------------------------------------------------------------------- #
# The ride profile
# --------------------------------------------------------------------------- #

CRUISE_KMH = 50.0
SLOW_TURN_KMH = 15.0
SOFT_TURN_KMH = 30.0

PROFILE = {
    # Puts the `max(80, 8v)` at 111 m: without a speed above 36 km/h the speed branch
    # of the rule would never be exercised, only the floor.
    "cruise_kmh": CRUISE_KMH,
    # Speed in the turn, by maneuver type (index = type in 05 §TURNS).
    # 15 and 30 km/h sit 5 and 10 km/h from the 2nd warning's 20 threshold: far
    # enough that rounding does not flip the side. Departure is the initial
    # "rolling"; straight and new name do not brake.
    "turn_kmh": [
        SLOW_TURN_KMH,   # 0 departure
        CRUISE_KMH,      # 1 straight
        SOFT_TURN_KMH,   # 2 slight right
        SLOW_TURN_KMH,   # 3 right
        SLOW_TURN_KMH,   # 4 sharp right
        SLOW_TURN_KMH,   # 5 u-turn
        SLOW_TURN_KMH,   # 6 sharp left
        SLOW_TURN_KMH,   # 7 left
        SOFT_TURN_KMH,   # 8 slight left
        SLOW_TURN_KMH,   # 9 roundabout
        SOFT_TURN_KMH,   # 10 highway entry
        SOFT_TURN_KMH,   # 11 highway exit
        SLOW_TURN_KMH,   # 12 arrival
        CRUISE_KMH,      # 13 new name
        SOFT_TURN_KMH,   # 14 fork left (before C16.5: slight left)
        SOFT_TURN_KMH,   # 15 fork right
        SOFT_TURN_KMH,   # 16 merge
        SOFT_TURN_KMH,   # 17 merge from the left
        SOFT_TURN_KMH,   # 18 merge from the right
        SLOW_TURN_KMH,   # 19 arrival on the left
        SLOW_TURN_KMH,   # 20 arrival on the right
        SLOW_TURN_KMH,   # 21 roundabout, sharp right exit
        SLOW_TURN_KMH,   # 22 roundabout, right exit
        SLOW_TURN_KMH,   # 23 roundabout, slight right exit
        SLOW_TURN_KMH,   # 24 roundabout, straight on
        SLOW_TURN_KMH,   # 25 roundabout, slight left exit
        SLOW_TURN_KMH,   # 26 roundabout, left exit
        SLOW_TURN_KMH,   # 27 roundabout, sharp left exit
        SLOW_TURN_KMH,   # 28 roundabout, u-turn
        SOFT_TURN_KMH,   # 29 highway entry from the left
        SOFT_TURN_KMH,   # 30 highway exit from the left
    ],
    # Drawing values, not measured: they only change how much of the ride is spent
    # braking. What the test needs is `hold_m`.
    "brake_mps2": 2.0,
    "accel_mps2": 1.5,
    # The turn speed holds for the last 30 m before it: at 25 m, where the
    # rule decides the 2nd warning, the speed is exactly the table's.
    "hold_m": 30.0,
    # GPS noise per axis, Igor's decision (2026-09-29): σ 2 m gives a 95% radius
    # of ~4.9 m, the gps.gov number for phones under open sky. AR(1) with
    # ρ 0.9: the GPS error drifts slowly, it does not jump at every fix.
    "noise_m": 2.0,
    "noise_rho": 0.9,
    "seed": 3,
    # Optional lateral offset (meters, and the fraction of the route where it starts and ends).
    # Off in C3a's `verificar:`.
    "detour_m": 0.0,
    "detour_from": 0.0,
    "detour_to": 0.0,
}


class Track:
    """The route as the watch sees it: points in local meters and accumulated distance."""

    def __init__(self, route: packer.Route) -> None:
        lat0, lon0 = route.lat0, route.lon0
        # Same equirectangular as `Projection.mc` (ADR-6).
        metres_per_degree = 111194.9
        lon_scale = metres_per_degree * math.cos(math.radians(lat0 * 1e-5))
        self.xs = [(lon - lon0) * 1e-5 * lon_scale for _, lon in route.points]
        self.ys = [(lat - lat0) * 1e-5 * metres_per_degree for lat, _ in route.points]
        self.cum = [0.0]
        for i in range(1, len(self.xs)):
            self.cum.append(self.cum[-1] + math.hypot(self.xs[i] - self.xs[i - 1],
                                                      self.ys[i] - self.ys[i - 1]))
        self.turns = route.turns
        self.turn_s = [self.cum[t.point_idx] for t in route.turns]

    @property
    def length(self) -> float:
        return self.cum[-1]


def speed_at(track: Track, s: float, profile: dict) -> float:
    """``v(s)`` in m/s: the same calculation as ``ReplaySource.speedAt``.

    The minimum of cruise and, for each maneuver, the braking curve down to
    ``hold_m`` before it, the turn speed within those meters, and the
    acceleration after it.
    """
    v = profile["cruise_kmh"] / 3.6
    hold = profile["hold_m"]
    brake = profile["brake_mps2"]
    accel = profile["accel_mps2"]
    for turn, turn_s in zip(track.turns, track.turn_s):
        vt = profile["turn_kmh"][turn.type] / 3.6
        if vt >= v:
            continue
        if s <= turn_s:
            gap = turn_s - hold - s
            limit = vt if gap <= 0 else math.sqrt(vt * vt + 2.0 * brake * gap)
        else:
            limit = math.sqrt(vt * vt + 2.0 * accel * (s - turn_s))
        if limit < v:
            v = limit
    return v


def fixes(track: Track, profile: dict) -> list[tuple[float, float]]:
    """The ride's fixes without noise: ``(s, v)``, one per simulated second.

    The same step as ``ReplaySource``: emits at ``s`` and advances ``v × 1 s``. The
    last fix is the end of the route.
    """
    out = []
    s = 0.0
    while s < track.length:
        v = speed_at(track, s, profile)
        out.append((s, v))
        s += v
    out.append((track.length, speed_at(track, track.length, profile)))
    return out


def next_turn(track: Track, s: float) -> int:
    """The next maneuver: the first whose point is still ahead."""
    for i, turn_s in enumerate(track.turn_s):
        if track.turns[i].point_idx > 0 and turn_s > s:
            return i
    return -1


def speed_window(samples: list[tuple[float, float]], turn_s: float, lo: float, hi: float) -> list[float]:
    """Speeds (km/h) of every fix whose true position falls in the distance
    window ``[lo, hi]`` before the maneuver.

    By position, not by "next maneuver": with noise, the match can
    pass the previous turn one fix earlier, and the warning goes out with the speed of
    a point that, without noise, still belonged to the other turn. Measured on the 1st ride of
    2026-09-29 (turn 12, stuck 35 m after 11: 15.0 km/h against 18.2).
    """
    speeds = [v for s, v in samples if lo <= turn_s - s <= hi]
    if not speeds:
        return []
    return [round(min(speeds) * 3.6, 1), round(max(speeds) * 3.6, 1)]


def lead(v: float) -> float:
    return max(LEAD_MIN_M, v * LEAD_S)


def expect(track: Track, profile: dict) -> dict:
    samples = fixes(track, profile)
    # Distance tolerance: the noise is isotropic with σ per axis; 3σ√2 is the
    # radius that covers the error the route matching can inherit.
    tol = 3.0 * profile["noise_m"] * math.sqrt(2.0)
    near_v = NEAR_MIN_KMH / 3.6

    by_turn: dict[int, list[tuple[float, float]]] = {}
    arrived_at = None
    for s, v in samples:
        if track.length - s <= ARRIVAL_M:
            # Arrival is tested before the turn (MotoNavApp.checkNavEvents): from there
            # on no turn warning goes out.
            arrived_at = s
            break
        i = next_turn(track, s)
        if i >= 0:
            by_turn.setdefault(i, []).append((track.turn_s[i] - s, v))

    maneuvers = []
    for i, turn in enumerate(track.turns):
        entry = {
            "i": i,
            "type": TURN_NAMES.get(turn.type, str(turn.type)),
            "street": turn.street_name,
            "at_m": round(track.turn_s[i], 1),
        }
        if turn.type in SILENT:
            entry.update(alerts=[0], reason="no_vibration")
            maneuvers.append(entry)
            continue
        seen = by_turn.get(i, [])
        entry["pulses"] = pulses_for(turn.type)

        first = next((k for k, (d, v) in enumerate(seen) if d <= lead(v)), None)
        if first is None:
            entry.update(alerts=[0], reason="no_fix_in_window")
            maneuvers.append(entry)
            continue
        d1, v1 = seen[first]
        earliest = next(k for k, (d, v) in enumerate(seen) if d - tol <= lead(v))
        latest = next((k for k, (d, v) in enumerate(seen) if d + tol <= lead(v)), first)
        lo1, hi1 = seen[latest][0] - tol, seen[earliest][0] + tol
        entry["alert1_m"] = [round(max(0.0, lo1), 1), round(hi1, 1)]
        entry["alert1_kmh"] = speed_window(samples, track.turn_s[i], lo1, hi1)

        after = seen[first + 1:]
        near = [(d, v) for d, v in after if 0.0 <= d <= NEAR_M + tol]
        fast = [(d, v) for d, v in after if 0.0 <= d <= NEAR_M and v > near_v]
        speed_edge = any(abs(v - near_v) * 3.6 < 1.0 for _, v in near)

        if d1 <= NEAR_M:
            entry.update(alerts=[1], reason="stuck")
        elif fast:
            entry["alerts"] = [2]
            # The watch only fires with its distance ≤ 25 m, so the ceiling is
            # 25; the floor is the fix where even the noise would already have put the
            # motorcycle within 25 m.
            sure = next((d for d, v in fast if d + tol <= NEAR_M), None)
            lo2 = 0.0 if sure is None else max(0.0, sure - tol)
            entry["alert2_m"] = [round(lo2, 1), NEAR_M]
            entry["alert2_kmh"] = speed_window(samples, track.turn_s[i], lo2, NEAR_M + tol)
        else:
            entry.update(alerts=[1], reason="speed")

        # The noise can put the 1st warning on either side of 25 m, or the speed
        # less than 1 km/h from 20: then the rule accepts both counts. It only
        # counts when it changes the answer — too slow, stuck or not, is 1.
        if fast and (lo1 <= NEAR_M < hi1 or speed_edge):
            entry["alerts"] = [1, 2]
            entry["ambiguous"] = "stuck" if lo1 <= NEAR_M < hi1 else "speed"
            entry.pop("reason", None)
        maneuvers.append(entry)

    return {
        "route": {
            "points": len(track.xs),
            "maneuvers": len(track.turns),
            "meters": round(track.length, 1),
        },
        "profile": profile,
        "tolerance_m": round(tol, 1),
        "maneuvers": maneuvers,
        "arrival": {"up_to_m": ARRIVAL_M, "at_s": round(arrived_at, 1) if arrived_at is not None else None},
        "duration_s": len(samples),
    }


WATCH_PROFILE = Path(__file__).resolve().parent.parent / "watch" / "source" / "nav" / "ReplayProfile.mc"


def monkey_literal(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(float(value))
    if isinstance(value, list):
        return "[" + ", ".join(monkey_literal(v) for v in value) + "] as Array<Float>"
    raise TypeError(f"no Monkey C literal for {value!r}")


def write_watch_profile(profile: dict) -> None:
    """The "Simulate ride" profile of the release menu (C3b) is this ride's.

    The watch does not read JSON; the ``PROFILE`` here becomes code, so the
    "Simulate ride" on the wrist and the simulator ride run with the same motorcycle.
    """
    entries = ",\n".join(f'            "{k}" => {monkey_literal(v)}' for k, v in profile.items())
    WATCH_PROFILE.write_text(
        "// GENERATED by tools/esperado.py (PROFILE), do not edit; regenerate with\n"
        "// python tools/esperado.py --fixture tiete_copan\n"
        "import Toybox.Lang;\n\n"
        "//! The speed and noise profile of the virtual motorcycle of \"Simulate ride\".\n"
        "module ReplayProfile {\n\n"
        "    function standard() as Dictionary {\n"
        "        return {\n"
        f"{entries}\n"
        "        };\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
        newline="\n",
    )


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", required=True, help="ex.: tiete_copan")
    args = parser.parse_args()

    source = FIXTURES / f"route_{args.fixture}.json"
    route = packer.route_from_mapbox(json.loads(source.read_text(encoding="utf-8")))
    result = {
        "fixture": args.fixture,
        "generated_by": "tools/esperado.py (rule of 03 §Vibration + C3a decisions)",
        **expect(Track(route), dict(PROFILE)),
    }
    out = FIXTURES / f"{args.fixture}.esperado.json"
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    write_watch_profile(dict(PROFILE))

    print(f"{out.relative_to(FIXTURES.parent.parent)}: {result['route']['maneuvers']} maneuvers, "
          f"{result['route']['meters']:.0f} m, {result['duration_s']} fixes")
    for m in result["maneuvers"]:
        extra = f" reason {m['reason']}" if "reason" in m else ""
        extra += f" AMBIGUOUS ({m['ambiguous']})" if "ambiguous" in m else ""
        window = f" 1st {m['alert1_m']}" if "alert1_m" in m else ""
        window += f" 2nd {m['alert2_m']}" if "alert2_m" in m else ""
        print(f"  {m['i']:2d} {m['type']:<16} {m['at_m']:8.0f} m  alerts {m['alerts']}{window}{extra}  {m['street']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
