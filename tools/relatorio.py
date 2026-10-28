"""Report on a ``motonav.log`` (or on a ``sim.py`` log): what the watch said.

    python tools/relatorio.py motonav.log            # full report
    python tools/relatorio.py motonav.log --summary  # numbers only, no destinations: safe to paste
    python tools/relatorio.py motonav.log --png corridas/volta.png   # plus the track as a PNG

Reads the two formats that exist: the phone's
(``MM-dd HH:mm:ss.SSS I Tag: WATCH| 123s frame avg ...``) and the simulator's
(``[diag] 123s frame avg ...``), in English or in the Portuguese of v1.4.0 and older (``logphrases.py``).
Reuses ``sim.py``'s regexes for the lines the watch writes, so a line that changes there changes here too.

**It proves the parser, not the hardware:** ``tools/fixtures/log_exemplo.txt`` is a
simulator lap. What it does not have — battery, for example — the report says
it does not have, instead of making it up.

Exits 0 with a report; 2 if the file does not exist or has no watch line at all.
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from logphrases import to_english  # noqa: E402  (same folder)
from sim import ALERT_LINE, ARRIVED_LINE, WORK_PEAK  # noqa: E402

#: A watch line, with or without the phone prefix: ``123s text``.
WATCH_LINE = re.compile(
    r"^(?:\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} [IWE] [^:]+: )?(?:WATCH\| ?|\[diag\] )(\d+)s (.*)$")
FRAME_LINE = re.compile(r"frame avg (\d+)ms peak (\d+)ms n(\d+)")
MEM_LINE = re.compile(r"mem (\d+)/(\d+)KB")
ETA_LINE = re.compile(r"eta (\d+)s")
BATTERY_LINE = re.compile(r"\bbat (\d+)%")
TRACK_LINE = re.compile(r"\btr[ks] (-?\d+) (-?\d+) (-?\d+) (-?\d+) (-?\d+)\s*$")
START_LINE = re.compile(r"\bstart (v\S+)")
CRASH_MARKS = ("Watchdog Tripped", "Out Of Memory", "Unhandled Exception")

#: Minimum window to give battery in %/h, in seconds. The level comes in whole
#: points: 1 point in 600 s is already 6 %/h of uncertainty. Measured in C6b: below
#: that the report shows the points and does not compute the rate.
BATTERY_MIN_WINDOW_S = 600

#: The odometer (C16.5), mirror of the phone's ``TrackOdometer.kt``, so the two numbers match:
#: below 1 m/s at both fixes the stretch is a stopped bike (GPS jumps at the traffic light), above
#: 60 m/s it is a GPS jump. A choice, not a measurement.
STOPPED_DMS = 10
MAX_MPS = 60.0


def km_ridden(lines: list[str]) -> tuple[float, int]:
    """The meters ridden in the ``trk`` lines (the simulated lap, ``trs``, stays out), and how many
    simulated fixes were left out. The same computation as ``TrackOdometer.kt``."""
    total, simulated, last = 0.0, 0, None
    for line in lines:
        m = TRACK_LINE.search(line)
        if not m:
            continue
        if line[m.start():m.start() + 4] == "trs ":
            simulated += 1
            continue
        t, lat, lon, speed, _ = map(int, m.groups())
        prev, last = last, (t, lat, lon, speed)
        if prev is None or t - prev[0] <= 0 or (speed < STOPPED_DMS and prev[3] < STOPPED_DMS):
            continue
        p1, p2 = math.radians(prev[1] / 1e5), math.radians(lat / 1e5)
        dl = math.radians((lon - prev[2]) / 1e5)
        h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        d = 2 * 6_371_000.0 * math.asin(math.sqrt(h))
        if d / (t - prev[0]) <= MAX_MPS:
            total += d
    return total, simulated

#: C16.7. The phone's line with each radar sent (``RadarClient.radarLine``; changed there, changes here).
RADAR_PHONE = re.compile(
    r"RadarClient: radar (\d+)/(\d+) route (\d+) osm (-?\d+) d (\d+) e5 (-?\d+),(-?\d+) lim (\d+) "
    r"bearing (\d+) direction (\S+) source (\S+)")
#: The watch's alert with the radar's ``d`` (``AlertPolicy.updateRadar``, ``SpeedHud``), since v1.3.3.
RADAR_WATCH = re.compile(
    r"(?:vibe radar \d+ at -?\d+m \d+km/h|radar \d+ on screen: \d+ km/h at -?\d+ m, \d+ km/h) d(\d+)")
VIBE_WATCH = "vibe radar "
#: The route the watch is following: ``radars N route R`` and the ``phase`` line.
ROUTE_WATCH = re.compile(r"\broute (\d+)\b")

#: Radius of the pass by the radar, from C16.7's ``sai`` in ``ROADMAP.md``: a choice, not a measurement.
PASS_M = 30.0
#: cos 60°: the track's heading and the route's at the radar agree, the same 60° as ``RadarFilter``.
PASS_COS = 0.5
#: The track records one fix every 5 s (``TrackBuffer.mc``); two fixes farther apart than this do not
#: become a segment, so a GPS gap does not draw a pass across a city block. A choice.
TRACK_GAP_S = 30
#: How long before the pass an alert still counts for it: the sign shows up to 1000 m before
#: (``SpeedHud.mc`` ``MAX_M``), which at 10 km/h is 360 s. Two passes of the same radar less
#: than this apart become one.
ALERT_WINDOW_S = 360


def _bearing_cos(dx: float, dy: float, bearing_deg: int) -> float:
    rad = math.radians(bearing_deg)
    return (dx * math.sin(rad) + dy * math.cos(rad)) / math.hypot(dx, dy)


def radar_passes(lines: list[str]) -> dict:
    """**Every pass by a radar on the lists, with an alert or without** (C16.7).

    The radars come from the phone's ``radar i/n`` lines; the alerts, from the watch's lines, which say
    the radar's ``d`` and match the list by the route the watch was following. A pass is a segment
    of the track within [PASS_M] of the radar, going in the heading of the route it came in. The reason
    for a pass without an alert is what the log says: the radar was not on the list of the route at the time, or it was.
    """
    radars: dict[int, dict] = {}
    by_route: dict[tuple[int, int], int] = {}
    routes: list[tuple[int, int]] = []
    alerts: list[tuple[int, int | None, int, bool]] = []
    track: list[tuple[int, int, int]] = []
    route = None
    for line in lines:
        if m := RADAR_PHONE.search(line):
            _, _, rid, osm, d, lat, lon, _, heading, _, _ = m.groups()
            radar = radars.setdefault(int(osm), {"lat": int(lat), "lon": int(lon), "headings": set(), "routes": set()})
            radar["headings"].add(int(heading))
            radar["routes"].add(int(rid))
            by_route[(int(rid), int(d))] = int(osm)
            continue
        if t := TRACK_LINE.search(line):
            fix = tuple(map(int, t.groups()))
            track.append((fix[0], fix[1], fix[2]))
            continue
        w = WATCH_LINE.match(line)
        if not w:
            continue
        at, text = int(w.group(1)), w.group(2)
        if r := ROUTE_WATCH.search(text):
            if route != int(r.group(1)):
                route = int(r.group(1))
                routes.append((at, route))
        if a := RADAR_WATCH.search(text):
            alerts.append((at, route, int(a.group(1)), text.startswith(VIBE_WATCH)))

    warned: dict[int, list[tuple[int, bool]]] = {}
    for at, rid, d, vibe in alerts:
        osm = by_route.get((rid, d)) if rid is not None else None
        if osm is not None:
            warned.setdefault(osm, []).append((at, vibe))

    def route_at(t: float) -> int | None:
        current = None
        for at, rid in routes:
            if at > t:
                break
            current = rid
        return current

    listed = {(rid, osm) for (rid, _), osm in by_route.items()}
    passes = []
    for osm, radar in radars.items():
        scale = math.cos(math.radians(radar["lat"] / 1e5))
        last_pass = None
        for (t1, la1, lo1), (t2, la2, lo2) in zip(track, track[1:]):
            if not 0 < t2 - t1 <= TRACK_GAP_S:
                continue
            x1, y1 = (lo1 - radar["lon"]) * 1.11320 * scale, (la1 - radar["lat"]) * 1.11320
            x2, y2 = (lo2 - radar["lon"]) * 1.11320 * scale, (la2 - radar["lat"]) * 1.11320
            dx, dy = x2 - x1, y2 - y1
            length_sq = dx * dx + dy * dy
            if length_sq < 1.0:
                continue
            u = max(0.0, min(1.0, -(x1 * dx + y1 * dy) / length_sq))
            if math.hypot(x1 + u * dx, y1 + u * dy) > PASS_M:
                continue
            if not any(_bearing_cos(dx, dy, b) >= PASS_COS for b in radar["headings"]):
                continue
            t = t1 + u * (t2 - t1)
            if last_pass is not None and t - last_pass < ALERT_WINDOW_S:
                continue
            last_pass = t
            said = [(at, vibe) for at, vibe in warned.get(osm, []) if t - ALERT_WINDOW_S <= at <= t + 1]
            rid = route_at(t)
            if said:
                cause = "vibrated" if any(vibe for _, vibe in said) else "sign only"
            elif rid is None:
                cause = "no route on the watch"
            elif (rid, osm) in listed:
                cause = f"on the list of route {rid}, no alert"
            else:
                cause = f"not on the list of route {rid}"
            passes.append({"osm": osm, "t": round(t), "alerted": bool(said), "cause": cause})
    passes.sort(key=lambda p: p["t"])
    return {"radars": len(radars), "alerts": len(alerts), "passes": passes}


#: Watch drop between two lines that counts as the app having restarted, in
#: seconds: ``t`` is since start, so it only decreases if the app started over.
RESTART_DROP_S = 5

#: Gap between two watch lines that counts as the app being closed, in seconds.
#: ``t`` is since the watch booted, so time with the app closed does not make ``t`` go back:
#: it shows up as a gap. Measured in the 2026-10-16 ``motonav.log.1`` (telemetry every
#: 10 s): the largest gap with the app open was 137 s, and the three with it closed, 7574 s
#: or more. Without this the report gave 0.6 %/h, counting 38 h with the app closed (C16.5).
CLOSED_GAP_S = 300


def parse(text: str) -> dict:
    lines = to_english(text).splitlines()
    watch = [(int(m.group(1)), m.group(2)) for m in (WATCH_LINE.match(l) for l in lines) if m]
    frames = [tuple(map(int, m.groups())) for _, l in watch if (m := FRAME_LINE.search(l))]
    mems = [tuple(map(int, m.groups())) for _, l in watch if (m := MEM_LINE.search(l))]
    etas = [int(m.group(1)) for _, l in watch if (m := ETA_LINE.search(l))]
    # Each line's stretch: changes on a new ``start``, a ``t`` that went back or a gap
    # of closed app. Battery and time only add up within the same stretch.
    pieces: list[int] = []
    piece = 0
    for i, (t, l) in enumerate(watch):
        if i > 0:
            before = watch[i - 1][0]
            if START_LINE.search(l) or t < before or t - before > CLOSED_GAP_S:
                piece += 1
        pieces.append(piece)
    batts = [(t, int(m.group(1)), pieces[i]) for i, (t, l) in enumerate(watch) if (m := BATTERY_LINE.search(l))]
    starts = [m.group(1) for _, l in watch if (m := START_LINE.search(l))]

    alerts: dict[int, list[tuple[int, float, float, int]]] = {}
    for line in lines:
        m = ALERT_LINE.search(line)
        if m:
            alerts.setdefault(int(m.group(1)), []).append(
                (int(m.group(2)), float(m.group(3)), float(m.group(4)), int(m.group(5))))

    # A restart shows up two ways (``t`` goes back and a new ``start``): they are the
    # same event, so the larger of the two counts, not the sum.
    drops = sum(before - after > RESTART_DROP_S for (before, _), (after, _) in zip(watch, watch[1:]))
    restarts = max(len(starts) - 1, drops)
    # Watch seconds with the app open: each stretch, without the gaps between them.
    span = sum(watch[i + 1][0] - watch[i][0] for i in range(len(watch) - 1) if pieces[i] == pieces[i + 1])
    crashes = sum(any(mark in l for mark in CRASH_MARKS) for l in lines)

    return {
        "watch_lines": len(watch),
        "versions": sorted(set(starts)),
        "span_s": span,
        "frames": frames,
        "work_peaks": [int(p) for p in WORK_PEAK.findall("\n".join(lines))],
        "capped": sum("CAPPED" in l for _, l in watch),
        "mems": mems,
        "etas": etas,
        "batts": batts,
        "alerts": alerts,
        "arrivals": [int(m.group(1)) for l in lines if (m := ARRIVED_LINE.search(l))],
        "arrival_vibes": sum("vibe arrival" in l for l in lines),
        "restarts": restarts,
        "crashes": crashes,
        "crash_lines": [l for l in lines if any(mark in l for mark in CRASH_MARKS)],
        "track": [tuple(map(int, m.groups())) for l in lines if (m := TRACK_LINE.search(l))],
        "ridden": km_ridden(lines),
        "radar": radar_passes(lines),
    }


def battery_line(batts: list[tuple[int, int, int]]) -> str:
    """Battery: first → last level and %/h. Only adds pairs from the same stretch with the app open:
    what the watch spent with the app closed (or charged) is left out."""
    if not batts:
        return "battery: no sample (the watch does not log the level)"
    same = [(a, b) for a, b in zip(batts, batts[1:]) if a[2] == b[2]]
    seconds = sum(b[0] - a[0] for a, b in same)
    drop = sum(a[1] - b[1] for a, b in same)
    pieces = len({b[2] for b in batts})
    head = (f"battery: {batts[0][1]}% → {batts[-1][1]}% ({drop} points in {seconds} s with the app open"
            + (f", {pieces} stretches)" if pieces > 1 else ")"))
    if seconds < BATTERY_MIN_WINDOW_S:
        return head + f" · short window, no %/h (minimum {BATTERY_MIN_WINDOW_S} s)"
    return head + f" · {drop * 3600 / seconds:.1f} %/h"


def render(data: dict, summary: bool) -> list[str]:
    out = [f"watch lines: {data['watch_lines']} · {data['span_s']} s of watch time"
           + (f" · build {', '.join(data['versions'])}" if data["versions"] else "")]

    frames = data["frames"]
    if frames:
        samples = sum(n for _, _, n in frames)
        mean = sum(med * n for med, _, n in frames) / samples
        out.append(f"frame: mean {mean:.0f} ms · peak {max(p for _, p, _ in frames)} ms · "
                   f"{samples} frames in {len(frames)} summaries")
    else:
        out.append("frame: no sample")

    peaks = data["work_peaks"]
    out.append(f"work peak: {max(peaks)} ({len(peaks)} samples, capped in {data['capped']})"
               if peaks else "work peak: no sample")

    if data["mems"]:
        used, total = max(data["mems"], key=lambda m: m[0])
        out.append(f"memory: peak {used}/{total} KB ({used / total:.0%}) in {len(data['mems'])} samples")
    else:
        out.append("memory: no sample")

    out.append(battery_line(data["batts"]))

    etas = data["etas"]
    out.append(f"eta: {len(etas)} samples, from {etas[0]} s to {etas[-1]} s" if etas else "eta: no sample")

    alerts = data["alerts"]
    total_alerts = sum(len(a) for a in alerts.values())
    out.append(f"alerts: {total_alerts} in {len(alerts)} maneuvers · arrival: "
               + (f"at {data['arrivals'][0]} m, {data['arrival_vibes']} vibration(s)"
                  if data["arrivals"] else "did not arrive"))
    out.append(f"crashes: {data['crashes']} crash mark(s) · {data['restarts']} restart(s)")

    track = data["track"]
    out.append(f"track: {len(track)} fixes recorded" if track else "track: no fix recorded")
    metres, simulated = data["ridden"]
    out.append(f"km ridden: {metres / 1000:.1f} km on the real track"
               + (f" ({simulated} simulated fixes left out)" if simulated else ""))

    radar = data["radar"]
    passes = radar["passes"]
    if radar["radars"]:
        out.append(f"radars: {len(passes)} passed, {sum(p['alerted'] for p in passes)} alerted"
                   f" · {radar['radars']} on the lists, {radar['alerts']} alerts on the watch")
    else:
        out.append("radars: no list in the log (phone older than 1.3.0)")

    if not summary:
        if passes:
            out += ["", "radar (osm)      watch t       alert"]
            for p in passes:
                out.append(f"{p['osm']:>12d}  {p['t']:12d}  {p['cause']}")
        if alerts:
            out += ["", "maneuver alert  lead          speed       pulses"]
            for turn in sorted(alerts):
                for stage, distance, speed, pulses in alerts[turn]:
                    out.append(f"{turn:7d}  {stage:5d}  {distance:9.1f} m  {speed:6.1f} km/h  {pulses:6d}")
        if data["crash_lines"]:
            out += ["", "crash lines:"] + [f"  {l}" for l in data["crash_lines"]]
    return out


def write_png(track: list[tuple[int, ...]], path: Path) -> str:
    """The track (``lat, lon`` in E5) as an image. No map background: it is the shape."""
    from PIL import Image, ImageDraw

    lats = [t[1] for t in track]
    lons = [t[2] for t in track]
    side, margin = 800, 30
    span = max(max(lats) - min(lats), max(lons) - min(lons), 1)
    scale = (side - 2 * margin) / span

    def point(fix: tuple[int, ...]) -> tuple[float, float]:
        # North up: latitude grows upward, the pixel downward.
        return (margin + (fix[2] - min(lons)) * scale, side - margin - (fix[1] - min(lats)) * scale)

    image = Image.new("RGB", (side, side), (250, 250, 250))
    draw = ImageDraw.Draw(image)
    points = [point(f) for f in track]
    if len(points) > 1:
        draw.line(points, fill=(90, 40, 200), width=4)
    x0, y0 = points[0]
    x1, y1 = points[-1]
    draw.ellipse((x0 - 8, y0 - 8, x0 + 8, y0 + 8), fill=(30, 160, 60))
    draw.ellipse((x1 - 8, y1 - 8, x1 + 8, y1 + 8), fill=(200, 40, 40))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    return f"track in {path}"


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace", newline="\n")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", type=Path, help="motonav.log or a sim.py log")
    parser.add_argument("--summary", "--resumo", dest="summary", action="store_true",
                        help="numbers only: no alerts table, no raw lines, no PNG")
    parser.add_argument("--png", type=Path, default=None, help="where to write the track (e.g. corridas/volta.png)")
    args = parser.parse_args()

    if not args.log.exists():
        print(f"FAILED: {args.log} does not exist")
        return 2
    data = parse(args.log.read_text(encoding="utf-8-sig", errors="replace").replace("\r\n", "\n"))
    if data["watch_lines"] == 0:
        print(f"FAILED: no watch line in {args.log}")
        return 2
    print("\n".join(render(data, args.summary)))
    if args.png is not None and not args.summary:
        print(write_png(data["track"], args.png) if data["track"] else "no track for the PNG")
    return 0


if __name__ == "__main__":
    sys.exit(main())
