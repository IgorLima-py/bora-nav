#!/usr/bin/env python3
"""The watch's recorded track: generates the test one and extracts the one from a lap (C3b).

The format
----------
The watch records one fix every 5 s (``TrackBuffer.mc``) and sends the phone,
along with the log, one line per fix::

    trk <t s> <lat E5> <lon E5> <speed dm/s> <heading degrees | -1>

``sim.py ride --track`` reads a JSON with the same five fields per fix::

    {"fixture": "tiete_copan", "fixes": [[t, lat, lon, v, h], ...], ...}

``generate`` creates the test track (``trilha_ruidosa``) and its ``.esperado.json``;
``extract`` turns the ``trk`` lines of a ``motonav.log`` into a track that
``sim.py ride --track`` replays in the simulator.

The test track
--------------
The São Paulo lap (``esperado.fixes``, the same bike as C3a) with **15 m of GPS
noise** (radial rms error, AR(1) with ρ 0.9 as in ``ReplaySource``) and a
**25 s hole with no fix** on a straight. The ``.esperado.json`` does not say what the
watch should do: it says what the track *has* (fixes, hole), and
``sim.py`` checks the watch against that and against the recorder's rule
(``recorded``).

Usage::

    python tools/trilha.py generate --fixture tiete_copan --name trilha_ruidosa
    python tools/trilha.py extract --log motonav.log --fixture tiete_copan --out volta.json
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import esperado  # noqa: E402
import packer  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures"

#: The watch recorder's interval (``TrackBuffer.INTERVAL_MS``).
RECORD_INTERVAL_S = 5

#: The GPS gap from which the watch logs ``no fix for`` (``FixGap.THRESHOLD_MS``).
GAP_THRESHOLD_S = 20

#: Radial rms error of the test track's noise, in meters. The roadmap (C3b) asks for
#: "15 m of noise"; it is 5x the 2 m σ of C3a's lap (gps.gov: ~4.9 m under open
#: sky), that of a canyon of buildings in São Paulo.
NOISE_M = 15.0
NOISE_RHO = 0.9
SEED = 7

#: The hole: 25 s with no fix (the threshold is 20), after 500 s of lap and on a straight.
HOLE_S = 25
HOLE_AFTER_S = 500
#: Distance from any maneuver to the hole, in meters: no hidden turn in it.
HOLE_CLEAR_M = 150.0

TRK_LINE = re.compile(r"\btrk (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)\s*$")

METRES_PER_DEGREE = 111194.9  # Projection.METRES_PER_DEGREE


def recorded(fixes: list[list[int]]) -> int:
    """How many fixes the watch's recorder keeps of these (``TrackBuffer.offer``).

    The first, and then every fix at least ``RECORD_INTERVAL_S`` from the last
    recorded. It is ``sim.py``'s ruler: the watch is only checked against it.
    """
    count, last = 0, None
    for t, *_ in fixes:
        if last is None or t - last >= RECORD_INTERVAL_S:
            count += 1
            last = t
    return count


def holes(fixes: list[list[int]]) -> list[dict]:
    """The silences of ``GAP_THRESHOLD_S`` or more between consecutive fixes."""
    out = []
    for before, after in zip(fixes, fixes[1:]):
        if after[0] - before[0] >= GAP_THRESHOLD_S:
            out.append({"after_s": before[0], "silence_s": after[0] - before[0]})
    return out


def position(track: esperado.Track, route: packer.Route, s: float) -> tuple[float, float, float]:
    """``(lat E5, lon E5, heading in rad)`` at ``s`` meters from the start, without noise."""
    cum = track.cum
    seg = 0
    last = len(cum) - 2
    while seg < last and cum[seg + 1] < s:
        seg += 1
    a, b = cum[seg], cum[seg + 1]
    t = (s - a) / (b - a) if b > a else 0.0
    (lat0, lon0), (lat1, lon1) = route.points[seg], route.points[seg + 1]
    dx = track.xs[seg + 1] - track.xs[seg]
    dy = track.ys[seg + 1] - track.ys[seg]
    return lat0 + t * (lat1 - lat0), lon0 + t * (lon1 - lon0), math.atan2(dx, dy)


def generate(route: packer.Route, seed: int = SEED, noise_m: float = NOISE_M) -> tuple[list[list[int]], dict]:
    track = esperado.Track(route)
    profile = dict(esperado.PROFILE)
    samples = esperado.fixes(track, profile)
    rng = random.Random(seed)
    sigma = noise_m / math.sqrt(2.0)  # radial rms = σ·√2 with two axes
    keep = math.sqrt(1.0 - NOISE_RHO ** 2)
    lon_scale = METRES_PER_DEGREE * math.cos(math.radians(route.lat0 * 1e-5))

    ex = ey = 0.0
    rows = []
    for t, (s, v) in enumerate(samples):
        lat, lon, heading = position(track, route, s)
        ex = NOISE_RHO * ex + keep * sigma * rng.gauss(0, 1)
        ey = NOISE_RHO * ey + keep * sigma * rng.gauss(0, 1)
        lat += ey / (METRES_PER_DEGREE * 1e-5)
        lon += ex / (lon_scale * 1e-5)
        bearing = (math.degrees(heading) + rng.gauss(0, 8.0)) % 360.0
        rows.append((t, s, [t, round(lat), round(lon), round(v * 10), round(bearing) % 360]))

    # The hole: the first instant after HOLE_AFTER_S with a straight on both sides.
    start = None
    for t, s, _ in rows:
        if t < HOLE_AFTER_S or t + HOLE_S + 1 >= len(rows):
            continue
        lo, hi = s - HOLE_CLEAR_M, rows[t + HOLE_S + 1][1] + HOLE_CLEAR_M
        if not any(lo <= turn_s <= hi for turn_s in track.turn_s):
            start = t
            break
    if start is None:
        raise SystemExit("no 25 s straight free of maneuvers after 500 s")
    fixes = [row for t, _, row in rows if not (start < t <= start + HOLE_S)]

    result = {
        "fixture": None,  # the caller fills it in
        "route": {
            "points": len(track.xs),
            "maneuvers": len(track.turns),
            "meters": round(track.length, 1),
        },
        "fixes": len(fixes),
        "holes": holes(fixes),
        "recorder": {"interval_s": RECORD_INTERVAL_S, "recorded_if_complete": recorded(fixes)},
        "arrival": {"up_to_m": esperado.ARRIVAL_M},
        # How many fixes fewer than the total the lap can deliver and still count
        # as complete: the arrival at 30 m from the end comes before the last fix.
        "delivered_min": len(fixes) - 20,
        "duration_s": fixes[-1][0],
        "noise_m": noise_m,
        "seed": seed,
    }
    return fixes, result


def cmd_generate(fixture: str, name: str, seed: int) -> int:
    source = FIXTURES / f"route_{fixture}.json"
    route = packer.route_from_mapbox(json.loads(source.read_text(encoding="utf-8")))
    fixes, expected = generate(route, seed)
    expected["fixture"] = fixture
    expected["generated_by"] = "tools/trilha.py generate"

    track_json = {
        "fixture": fixture,
        "generated_by": "tools/trilha.py generate",
        "format": "fixes: [t s, lat E5, lon E5, speed dm/s, heading degrees | -1]",
        "noise_m": expected["noise_m"],
        "seed": seed,
        "fixes": fixes,
    }
    out = FIXTURES / f"{name}.json"
    out.write_text(json.dumps(track_json, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8", newline="\n")
    exp = FIXTURES / f"{name}.esperado.json"
    exp.write_text(json.dumps(expected, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")
    hole = expected["holes"][0]
    print(f"{out.name}: {len(fixes)} fixes, noise {expected['noise_m']:.0f} m, hole of {hole['silence_s']} s "
          f"after {hole['after_s']} s, the recorder keeps {expected['recorder']['recorded_if_complete']}")
    print(f"{exp.name}: written")
    return 0


def cmd_extract(log: Path, fixture: str, out: Path) -> int:
    fixes = []
    for line in log.read_text(encoding="utf-8", errors="replace").splitlines():
        m = TRK_LINE.search(line)
        if m:
            fixes.append([int(g) for g in m.groups()])
    if not fixes:
        print(f"no 'trk' line in {log}")
        return 1
    origin = fixes[0][0]
    for fix in fixes:
        fix[0] -= origin
    track_json = {
        "fixture": fixture,
        "generated_by": f"tools/trilha.py extract {log.name}",
        "format": "fixes: [t s, lat E5, lon E5, speed dm/s, heading degrees | -1]",
        "fixes": fixes,
    }
    out.write_text(json.dumps(track_json, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8", newline="\n")
    print(f"{out}: {len(fixes)} fixes in {fixes[-1][0]} s, holes {holes(fixes)}")
    return 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    generate = sub.add_parser("generate", aliases=["gerar"], help="the test track and its .esperado.json")
    generate.add_argument("--fixture", required=True)
    generate.add_argument("--name", "--nome", dest="name", metavar="NAME", default="trilha_ruidosa")
    generate.add_argument("--seed", "--semente", dest="seed", metavar="SEED", type=int, default=SEED)
    extract = sub.add_parser("extract", aliases=["extrair"], help="the trk lines of a motonav.log become a track")
    extract.add_argument("--log", type=Path, required=True)
    extract.add_argument("--fixture", required=True)
    extract.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if args.command in ("generate", "gerar"):
        return cmd_generate(args.fixture, args.name, args.seed)
    return cmd_extract(args.log, args.fixture, args.out)


if __name__ == "__main__":
    raise SystemExit(main())
