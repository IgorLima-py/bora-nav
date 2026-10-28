#!/usr/bin/env python3
"""The Connect IQ simulator as an instrument: runs, reads and says pass or fail.

Why this script exists
----------------------
Of the 20 rounds of testing on the watch in July and August, 16 failed from a cause that
could be caught on the PC (``docs/DECISIONS.md`` §2026-09-11). The tests existed,
but running them meant opening the simulator, building, calling ``monkeydo`` and reading
256 lines of console looking for a ``FAIL``. Nobody does that on every change.

This script does it, and answers with the exit code:

* ``0`` only with **all** assertions passing;
* ``1`` on anything else, including output it does not recognize.
  "I did not find the summary line" is a failure, never a silent pass.

**``monkeydo``'s exit code is ignored on purpose.** The 2026-09-11 research
said it exits 1 even when passing; measured on 2026-09-29 on SDK 9.2.0,
it exited 0. Neither is reliable for deciding: what decides is the
``PASSED (passed=N, failed=0, errors=0)`` line.

Usage::

    python tools/sim.py test            # the unit tests, 0 = all passed
    python tools/sim.py test --canary   # turns on a failing test: MUST exit 1
    python tools/sim.py watchdog        # the probe: does the simulator apply the watchdog?
    python tools/sim.py all             # test + debug build + release build (alias: tudo)
    python tools/sim.py demo --fixture tiete_copan            # real SP in the app
    python tools/sim.py demo --fixture tiete_copan --canary   # MUST exit 1
    python tools/sim.py demo --fixture tiete_copan --long-route 4000   # POLY at the ceiling, no watchdog
    python tools/sim.py shot [--out X.png]   # captures the screen and measures the % lit
    python tools/sim.py shots                # C4's 3 screens: shots/tela_{far,near,arrival}.png
    python tools/sim.py shots --trace        # C16.5: the route and the streets before/after, enlarged
    python tools/sim.py shots --home        # sheet 1's home screen, in each state
    python tools/sim.py ride --fixture tiete_copan --speed 4            # the virtual lap
    python tools/sim.py ride --fixture tiete_copan --speed 4 --canary   # MUST exit 1
    python tools/sim.py ride --track tools/fixtures/trilha_ruidosa.json    # recorded track, with noise and a gap
    python tools/sim.py ride --fixture tiete_copan --detour 1 --no-phone   # C11: leaves the route, no reply
    python tools/sim.py ride --fixture tiete_copan --no-cache   # streets without the image, to compare

The raw outputs stay in ``shots/`` with fixed names (``sim_test.log``,
``sim_watchdog.log``, ``demo_<fixture>.log`` and ``.png``, ``ride_<fixture>.log``, ``track_<stem>.log``),
overwritten on every run. The folder is local, outside git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_watch import BIN, DEVICE, JUNGLE, ROOT, app_version, developer_key, monkeyc  # noqa: E402
import trilha as trilha_tool  # noqa: E402
from logphrases import to_english  # noqa: E402

SHOTS = ROOT / "shots"
CANARY_JUNGLE = ROOT / "watch" / "canary.jungle"
PROBE_JUNGLE = ROOT / "watch" / "probe.jungle"
DEMO_JUNGLE = ROOT / "watch" / "demo.jungle"
DEMO_CANARY_JUNGLE = ROOT / "watch" / "demo_canary.jungle"
DEMO_CONFIG_JUNGLE = ROOT / "watch" / "demo_config.jungle"
CONFIG_PARAMS = ROOT / "watch" / "bin" / "config" / "ConfigParams.mc"
RIDE_JUNGLE = ROOT / "watch" / "ride.jungle"
RIDE_CANARY_JUNGLE = ROOT / "watch" / "ride_canary.jungle"
TRACK_JUNGLE = ROOT / "watch" / "track.jungle"
TRACK_DIR = ROOT / "watch" / "bin" / "track"
SHOTS_JUNGLE = ROOT / "watch" / "shots.jungle"
DETAILS_JUNGLE = ROOT / "watch" / "detalhes.jungle"
HOME_JUNGLE = ROOT / "watch" / "inicio.jungle"
BURNIN_JUNGLE = ROOT / "watch" / "burnin.jungle"
ARROWS_JUNGLE = ROOT / "watch" / "setas.jungle"
TRACE_JUNGLE = ROOT / "watch" / "traco.jungle"
SHOT_PARAMS = ROOT / "watch" / "bin" / "shots" / "ShotParams.mc"
TOKENS_JSON = ROOT / "docs" / "design" / "relogio" / "tokens.json"
SHOT_SCRIPT = ROOT / "tools" / "shot_simulator.ps1"

#: Fixtures that became demo resources (``DemoFramesTest``). Only ``tiete_copan``,
#: which starts from a public place: a demo resource goes into git.
DEMO_FIXTURES = {
    "tiete_copan": ROOT / "watch" / "demo" / "resources" / "strings" / "demo_frames.xml",
}

#: Test floor. 61 is the count measured on 2026-09-29 before C2a
#: (``Ran 61 tests``), plus C2a's ``TelemetryTest``, the two for C2b's sliced parse, the two
#: C3a alerts (a maneuver that does not vibrate, a glued turn), the two for formatting and the two for RNF-05
#: from C4, the seven of C5's ``ConfigTest`` and the three of C6a's sliced POLY. A
#: test file that disappears from the build brings the command down instead of "passing" with
#: fewer tests. Raise it together when adding a test. Then came C9 and C10 (96, ``Ran 96
#: tests`` on 2026-10-10) and C11: the ``REROUTE_REQ`` frame and the seven of ``OffRouteTest`` (104),
#: and the six of ``RouteSwapTest`` for the atomic swap (110), and the four for the off-route screen and cost (114).
#: C12 took it to 121 (``sim.py test`` 121/121 on 2026-10-13) without raising the floor; C13a adds the five
#: of ``RouteUpdateTest`` (126) and C13b the four for the block that survives the link dropping (130)
#: and the three of ``PhoneFixTest``, the phone GPS contract (133), plus the seven of
#: ``FixFallbackTest`` and the one for the ``phone`` origin in telemetry (141). C15b closed at 149, and
#: C16.5 adds the one for size groups at the ends (``groupExtremesStayInsideAndApart``, 150) and the
#: three for the arrival delta in ``NavEngineTest`` (153), the one for the gesture that does not close the app (154), the one for the Favorites button (155)
#: and the one for the app that closes 5 min after arrival (156), and the one for the streets that do not blink at the leash floor (157).
#: The new home screen swaps the Favorites button one for the four of ``RecentsTest`` (the three buttons, the
#: RECENTS, the request for a recent and the Settings steps): 160. The avenue over the local street
#: (``theAvenueIsDrawnOverTheLocalStreets``) and the floor the plan spends entirely
#: (``theFloorPlanSpendsTheFloor``): 162.
#: The home screen tap that ``onSelect`` must not consume (``homeSelectLeavesTheTapToTheButtons``)
#: and the state line that fits the glass (``homeStateLineFitsTheGlass``), and the map held under the action
#: menu (``theActionMenuHoldsTheMapUntilItCloses``): 165. The zoom mid-sweep
#: (``aZoomMidScanRebuildsEveryLayer``): 166. v1.1.3 to v1.1.5 took it to 186 without raising the floor, and the
#: four for C16's GPS drill (``GpsDrillTest``) to 190.
#: v1.2.4 swaps the ETA average for the trip's: the slow start (``aSlowStartDoesNotInflateTheEta``),
#: the trip odometer (``theTripOdometerSkipsJumpsAndSurvivesTheReroute``) and the route wait in
#: place of the ``DebugView`` (``aRouteChunkSpinsTheRingUntilItStops``): 200.
#: v1.2.5 brings the street diagnostic levers: the API matrix (``theApiMatrixIsTheSetMatrix``)
#: and the seven levers building and pasting (``everyStreetLeverBuildsAndPastes``): 202. v1.2.6 swaps the
#: levers (the API matrix goes out, ``isCached`` comes into the log, ``theImageCacheCheckIsLogged``): 202.
#: v1.2.9 brings the streets in tiles: each tile in place (``everyTileLandsWhereTheLiveStreetsWould``),
#: the grid following the rider (``theGridFollowsTheRider``) and the grids in the pool (``everyGridFitsThePool``): 205.
#: And the radar (``RadarsTest``: the RADARS on the live route and on the swap, the refusals, the sign and the vibration through
#: CONFIG 22, and CONFIG 21 at 0 with no motor): 212.
#: And the leash that grows with the slow frame along the route, and street by street with it (C16.6): 214.
#: And the arrival that does not accept a match far from the route (``arrivalIgnoresAMatchFarFromTheRoute``): 215.
#: And the radar alert that survives the swap of the list (``theRadarAlertSurvivesAFreshListMidRoute``): 216.
#: And the alert line with the radar's ``d``, the key of C16.7's crossing
#: (``theRadarAlertLogsTheRadarDistance``): 217.
#: And the two radars 50 m apart, which the phone sends and the watch alerts (``twoRadarsFiftyMetresApartBothAlert``): 218.
MIN_TESTS = 218

#: Port of the simulator's TCP shell (``shot_simulator.ps1``, notes). Accepting a
#: connection on it is the signal that the simulator is ready for ``monkeydo``.
SIM_PORT = 1234

#: Timeout for the simulator to open. Measured on 2026-09-29 on the Windows dev PC: the port opened
#: in 3.7 s; 30 s is slack for a slower machine or a cold disk. On macOS
#: (SDK 9.3.0, 2026-10-22) the opening went past 30 s twice in a row: there the timeout is 90 s.
SIM_START_TIMEOUT_S = 30 if os.name == "nt" else 90

#: Timeout for the unit tests. Measured on 2026-09-29: 61 tests in 42.6 s,
#: with `WatchdogTest` drawing whole cities. On the Windows dev PC, 197 tests in
#: 237 s (2026-10-20, job 867); on 2026-10-24 (job 953) C16.6's 213, with
#: `StreetCacheTest`'s tiles walking 90 s of street, were still at the 190th
#: when the old 300 s ran out. 10 min is more than double 237 s.
TEST_TIMEOUT_S = 600

#: Probe timeout. It dies (or ends) in ~5 s; 90 s catches the simulator
#: hung on an error dialog without holding up the session.
PROBE_TIMEOUT_S = 90

#: The budget that `venu445mm`'s `simulator.json` declares.
WATCHDOG_COUNT = 240000

#: Demo timeout. `DemoFeed` sends 11 messages, one per second, and holds
#: 25 s before exiting, so the run takes about 40 s. 120 s is triple; going past
#: that is a hang.
DEMO_TIMEOUT_S = 120

#: Seconds between ``[demo] ready`` and the capture. With no fix, the app redraws at
#: 1 Hz, and 5 frames are enough for the last LOD to be drawn.
SHOT_DELAY_S = 5

#: Ceiling of the demo's ``work peak``. It is ``WatchdogTest.mc``'s ``safe = WORK_FATAL * 2 / 3``,
#: where ``WORK_FATAL = 3000`` is the work of the frame that killed the
#: app on the wrist (DECISIONS §2026-08-01).
WORK_CEILING = 2000

#: Minimum fraction of lit pixels in the capture: the floor of C2b's ``verify:``.
#: The background is pure ``#000000`` (C1 exception), so only what was drawn counts.
LIT_MIN = 0.05

#: Luma above which a pixel counts as lit: above the background's pure black,
#: below the corridor's darkest gray.
LIT_LUMA = 16


def sdk_bin() -> Path:
    return monkeyc().parent


def tool(name: str) -> Path:
    """An SDK executable. On Windows it is the ``.bat`` (see ``build_watch.monkeyc``)."""
    return sdk_bin() / (f"{name}.bat" if os.name == "nt" else name)


def simulator_ready() -> bool:
    try:
        with socket.create_connection(("127.0.0.1", SIM_PORT), timeout=1):
            return True
    except OSError:
        return False


def simulator_hung() -> bool:
    """Has the simulator window stopped pumping messages?

    Measured on 2026-09-29: after a ``monkeydo`` killed in the middle of a
    normal run, port 1234 kept accepting connections, but the process
    stayed ``Responding = False`` and the following tests blew through 300 s without
    a line of output. An open port is not enough to say it is alive.
    """
    if os.name != "nt":
        return False
    probe = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         "@(Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { -not $_.Responding }).Count"],
        capture_output=True, text=True,
    )
    return probe.stdout.strip() not in ("", "0")


#: Windows' ``simulator.ini``, where the simulator stores the watch's language (``Language=``).
SIM_INI = Path(os.environ.get("APPDATA", "")) / "Garmin" / "ConnectIQ" / "simulator.ini"

#: The ``Language=`` of each app language. They are the numbers of the FIT ``language`` enum
#: (english 0, portuguese 14). Measured on 2026-10-28 (C16.8a, job 1043): with ``Language=14`` the
#: 218 tests, which check Portuguese text, passed with English in the default ``resources/``.
SIM_LANGUAGES = {"eng": 0, "por": 14}

#: This run's language (``--language``). The tests and laps check Portuguese texts,
#: so it is the default; English is for the photos.
LANGUAGE = "por"


def pin_language() -> None:
    """Puts the simulator in language [LANGUAGE] before opening it (C16.8a).

    The simulator reads ``simulator.ini`` only on opening, so if the language changes it is closed.
    Outside Windows there is no ``simulator.ini`` here, and whatever language is set applies."""
    if os.name != "nt" or not SIM_INI.exists():
        return
    text = SIM_INI.read_text(encoding="utf-8", errors="replace")
    line = f"Language={SIM_LANGUAGES[LANGUAGE]}"
    if re.search(rf"^{line}$", text, re.MULTILINE):
        return
    if simulator_ready() or simulator_hung():
        print(f"simulator in another language: closing it to reopen in {LANGUAGE}")
        subprocess.run(["taskkill", "/IM", "simulator.exe", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
    if re.search(r"^Language=\d+$", text, re.MULTILINE):
        text = re.sub(r"^Language=\d+$", line, text, flags=re.MULTILINE)
    else:
        text = text.rstrip("\n") + f"\n{line}\n"
    SIM_INI.write_text(text, encoding="utf-8")


def ensure_simulator() -> None:
    """Opens the simulator if it is closed (or hung) and waits for the port, in language
    [LANGUAGE]."""
    pin_language()
    if simulator_hung():
        print("simulator hung: closing it to reopen")
        subprocess.run(["taskkill", "/IM", "simulator.exe", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(2)
    if simulator_ready():
        return
    print("simulator closed: opening")
    flags = 0
    if os.name == "nt":
        # Detached from this script's console: the simulator outlives it and stays
        # open for the next run, which then does not pay for the opening.
        flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    subprocess.Popen(
        [str(tool("connectiq"))],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        creationflags=flags,
    )
    deadline = time.monotonic() + SIM_START_TIMEOUT_S
    while time.monotonic() < deadline:
        if simulator_ready():
            return
        time.sleep(0.5)
    sys.exit(f"the simulator did not open port {SIM_PORT} in {SIM_START_TIMEOUT_S} s")


def compile_prg(jungles: list[Path], output: Path, unit_test: bool) -> bool:
    command = [
        str(monkeyc()),
        "-f", ";".join(str(j) for j in jungles),
        "-o", str(output),
        "-y", str(developer_key()),
        "-d", DEVICE,
        "-l", "2",
    ]
    if unit_test:
        command.append("--unit-test")
    print(f"compiling {output.name}")
    return subprocess.run(command).returncode == 0


def kill_tree(process: subprocess.Popen) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(process.pid)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        process.kill()


def run_monkeydo(prg: Path, unit_test: bool, timeout_s: int) -> tuple[str, bool]:
    """Runs the ``.prg`` in the simulator and returns (output, timed out)."""
    command = [str(tool("monkeydo")), str(prg), DEVICE]
    if unit_test:
        # Windows' `monkeydo.bat` accepts `/t`; the macOS script only `-t` ("ILLEGAL ARGUMENT: /t").
        command.append("/t" if os.name == "nt" else "-t")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = process.communicate(timeout=timeout_s)
        timed_out = False
    except subprocess.TimeoutExpired:
        # Killing only `monkeydo.bat` is not enough: its child `java.exe` keeps
        # holding the pipe, and the next `communicate` waits forever
        # (measured on 2026-09-29: the 15 s timeout became a stuck session). That is
        # why the whole tree, with `taskkill /T`.
        kill_tree(process)
        out, err = process.communicate()
        timed_out = True
    raw = out + b"\n" + err
    # The simulator's output starts with a BOM. A log from the Portuguese-logging watch (up to
    # v1.4.0) is turned into the English one, so the rest of the file matches English only.
    return to_english(raw.decode("utf-8-sig", errors="replace").replace("\r\n", "\n")), timed_out


def save(name: str, text: str) -> Path:
    SHOTS.mkdir(exist_ok=True)
    path = SHOTS / name
    path.write_text(text, encoding="utf-8")
    return path


# --------------------------------------------------------------------------- #
# test
# --------------------------------------------------------------------------- #

SUMMARY = re.compile(r"^(PASSED|FAILED) \(passed=(\d+), failed=(\d+), errors=(\d+)\)", re.M)
RAN = re.compile(r"^Ran (\d+) tests?", re.M)
#: A line of the final table. The test that lives in a module comes out as ``Module.name``: without the
#: dot in the class, the line did not match and its failure vanished from the names list (the tally
#: was still right, so only the canary with a name inside a module showed it, in C13b).
ROW = re.compile(r"^([\w.]+)\s+(PASS|FAIL|ERROR)\s*$", re.M)


def judge_tests(text: str, canary: bool) -> tuple[int, str]:
    """Reads the output of ``monkeydo /t`` and returns (exit code, verdict)."""
    ran = RAN.search(text)
    summary = SUMMARY.search(text)
    if not ran or not summary:
        return 1, "did not find monkeydo's summary (Ran N tests / PASSED|FAILED): unrecognized output"

    total = int(ran.group(1))
    status, passed, failed, errors = summary.group(1), *map(int, summary.groups()[1:])
    broken = [name.rsplit(".", 1)[-1] for name, state in ROW.findall(text) if state != "PASS"]
    line = f"{passed}/{total}"
    if broken:
        line += " · failed: " + ", ".join(broken)

    if canary:
        # The canary must have run **and** failed: if it did not even show up, the
        # overlay did not get in and the test that the instrument bites did not happen.
        if "canaryMustFail" not in broken:
            return 1, line + " · the canary did NOT run or did not fail: the instrument is blind"
        if "distanceAndTextMeetTheMinimum" not in broken:
            return 1, line + " · the 54 px distance did NOT fail Rnf05Test: RNF-05 is blind"
        if "thirtyNineMetersForSixSecondsDoesNotTrigger" not in broken:
            return 1, line + " · the 35 m threshold did NOT fail OffRouteTest: off-route is blind"
        if "fourSecondsWithoutFixDoesNotAsk" not in broken:
            return 1, line + " · the request at 4 s did NOT fail FixFallbackTest: the GPS fallback is blind"
        return 1, (
            line + " · canary bit, including the 54 px distance, the 35 m threshold"
            " and the GPS request at 4 s (exiting 1 here is expected)"
        )

    if status != "PASSED" or failed or errors or passed != total:
        return 1, line
    if total < MIN_TESTS:
        return 1, f"{line} · only {total} tests, floor {MIN_TESTS}: a test file left the build"
    return 0, line


def cmd_test(canary: bool) -> int:
    ensure_simulator()
    jungles = [JUNGLE, CANARY_JUNGLE] if canary else [JUNGLE]
    prg = BIN / ("MotoNavCanary.prg" if canary else "MotoNavTest.prg")
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg(jungles, prg, unit_test=True):
        print("FAILED: did not compile")
        return 1

    started = time.monotonic()
    text, timed_out = run_monkeydo(prg, unit_test=True, timeout_s=TEST_TIMEOUT_S)
    log = save("sim_canary.log" if canary else "sim_test.log", text)
    if timed_out:
        print(f"FAILED: the tests went past {TEST_TIMEOUT_S} s (log: {log})")
        return 1

    code, verdict = judge_tests(text, canary)
    elapsed = time.monotonic() - started
    print(f"{'ok' if code == 0 else 'FAILED'}: {verdict} · {elapsed:.0f} s · log {log.relative_to(ROOT)}")
    return code


# --------------------------------------------------------------------------- #
# watchdog
# --------------------------------------------------------------------------- #

PROBE_OK = re.compile(r"^probe (\d+) ok", re.M)
PROBE_START = re.compile(r"^probe (\d+) start", re.M)


def judge_probe(text: str, timed_out: bool) -> tuple[int, str]:
    oks = [int(n) for n in PROBE_OK.findall(text)]
    starts = [int(n) for n in PROBE_START.findall(text)]
    tripped = "Watchdog Tripped" in text

    if tripped and starts:
        died = starts[-1]
        last_ok = oks[-1] if oks else 0
        # The budget ran out between the last whole step and the one that died,
        # so the instructions per iteration lie between these two figures.
        low = WATCHDOG_COUNT / died
        high = WATCHDOG_COUNT / last_ok if last_ok else float("inf")
        return 0, (
            f"APPLIES: {last_ok} iterations passed, {died} died with Watchdog Tripped "
            f"(~{low:.0f}–{high:.0f} instructions per iteration against {WATCHDOG_COUNT})"
        )
    if "probe end alive" in text:
        return 0, f"DOES NOT APPLY: {oks[-1] if oks else '?'} iterations in one callback and nothing died"
    if timed_out:
        return 1, f"undefined: went past {PROBE_TIMEOUT_S} s with no verdict (simulator hung?)"
    return 1, "undefined: the probe printed neither a death nor an end"


def cmd_watchdog() -> int:
    ensure_simulator()
    prg = BIN / "WatchdogProbe.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([PROBE_JUNGLE], prg, unit_test=False):
        print("FAILED: the probe did not compile")
        return 1
    # **Normal** run, without /t: in a unit test the watchdog is off.
    text, timed_out = run_monkeydo(prg, unit_test=False, timeout_s=PROBE_TIMEOUT_S)
    log = save("sim_watchdog.log", text)
    code, verdict = judge_probe(text, timed_out)
    print(text.strip())
    print(f"\n{verdict}\nlog {log.relative_to(ROOT)}")
    return code


# --------------------------------------------------------------------------- #
# shot
# --------------------------------------------------------------------------- #

def lit_fraction(png: Path) -> float:
    """Fraction of pixels with luma above [LIT_LUMA]."""
    from PIL import Image  # only the capture needs Pillow

    with Image.open(png) as image:
        histogram = image.convert("L").histogram()
    total = sum(histogram)
    return sum(histogram[LIT_LUMA + 1:]) / total if total else 0.0


def take_shot(out: Path) -> str | None:
    """Captures the simulator's framebuffer. Returns ``None`` or the reason for the failure.

    ``-Mode native`` is the simulator's own menu item: the device's screen comes out,
    454x454, without a bezel. Without ``-ExecutionPolicy``: the user's ``RemoteSigned``
    policy already runs local scripts.
    """
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.exists():
        out.unlink()
    if sys.platform == "darwin":
        return take_shot_mac(out)
    result = subprocess.run(
        ["powershell", "-NoProfile", "-File", str(SHOT_SCRIPT), "-Mode", "native", "-Out", str(out)],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
    )
    if result.returncode != 0 or not out.exists():
        lines = (result.stderr or result.stdout).strip().splitlines()
        return lines[-1] if lines else f"the script exited {result.returncode}"
    return None


#: The simulator window on macOS, found by its owner. ``screencapture`` asks for the window
#: number, and only CoreGraphics gives it: without PyObjC, a short Swift script.
MAC_WINDOW_SWIFT = """
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "") == "Connect IQ Device Simulator" {
    print(w[kCGWindowNumber as String] as? Int ?? 0); break
}
"""


def take_shot_mac(out: Path) -> str | None:
    """On macOS: the whole window through ``screencapture -l``, then the crop of the glass.

    The macOS simulator does not have the dialog that ``shot_simulator.ps1`` fills in. The
    window draws the device's ``device.png`` at Retina scale, between the title
    bar and the memory bar (both the same height, measured on 2026-10-26), and
    ``simulator.json`` says where the glass sits in it. Outside the circle it comes out black, as in
    the Windows native capture.
    """
    from PIL import Image, ImageDraw

    found = subprocess.run(["swift", "-"], input=MAC_WINDOW_SWIFT, capture_output=True, text=True, timeout=60)
    window = found.stdout.strip()
    if not window.isdigit():
        return "the simulator window did not show up (is it open?)"
    raw = out.with_name(out.stem + ".janela.png")
    subprocess.run(["screencapture", "-x", "-o", "-l", window, str(raw)], timeout=30)
    if not raw.exists():
        return "screencapture wrote nothing (missing the Screen Recording permission?)"
    device = Path.home() / "Library/Application Support/Garmin/ConnectIQ/Devices" / DEVICE
    simulator = json.loads((device / "simulator.json").read_text(encoding="utf-8"))
    spec = simulator["display"]["location"]
    with Image.open(device / simulator.get("image", "device.png")) as face:
        face_w, face_h = face.size
    with Image.open(raw) as image:
        scale = image.width / face_w
        top = (image.height - face_h * scale) / 2
        box = (round(spec["x"] * scale), round(top + spec["y"] * scale),
               round((spec["x"] + spec["width"]) * scale), round(top + (spec["y"] + spec["height"]) * scale))
        glass = image.convert("RGB").crop(box).resize((spec["width"], spec["height"]), Image.LANCZOS)
    mask = Image.new("L", glass.size, 0)
    ImageDraw.Draw(mask).ellipse((0, 0, glass.width - 1, glass.height - 1), fill=255)
    Image.composite(glass, Image.new("RGB", glass.size, (0, 0, 0)), mask).save(out)
    raw.unlink()
    return None


def cmd_shot(out: Path | None) -> int:
    png = out or SHOTS / "simulator.png"
    error = take_shot(png)
    if error:
        print(f"FAILED: no capture ({error})")
        return 1
    print(f"{lit_fraction(png):.1%} lit · {png}")
    return 0


# --------------------------------------------------------------------------- #
# demo
# --------------------------------------------------------------------------- #

LOD_LINE = re.compile(r"corridor lod (\d) (\d+) ways (\d+) pts")
WORK_PEAK = re.compile(r"work peak (\d+)/")


def decode_line(raw: bytes) -> str:
    """A line from ``monkeydo``. The app's ``println`` arrives in cp1252 (the telemetry's ``·``
    turned into ``�``) and the rest in UTF-8 with BOM: tries UTF-8 and falls back to
    cp1252. Old Portuguese log lines come out in English (``logphrases``)."""
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = raw.decode("cp1252", errors="replace")
    return to_english(text.rstrip("\r\n"))


def run_live(prg: Path, timeout_s: int, on_line, on_idle) -> tuple[str, bool]:
    """Runs the ``.prg`` without ``/t`` reading the output **line by line**.

    Measured on 2026-09-29 (C2b): the ``println`` of a normal run reaches
    ``monkeydo``'s stdout live, one per second. C2a's "nothing in 25 s" came
    from ``communicate()``, which only returns at the end. ``on_line(line, s)`` runs for
    each line and ``on_idle(s)`` every 0.2 s, both on the main thread.
    """
    process = subprocess.Popen([str(tool("monkeydo")), str(prg), DEVICE],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    pending: list[str] = []
    lock = threading.Lock()

    def pump() -> None:
        for raw in iter(process.stdout.readline, b""):
            with lock:
                pending.append(decode_line(raw))

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    started = time.monotonic()
    lines: list[str] = []
    timed_out = False

    def drain() -> None:
        with lock:
            batch = pending[:]
            pending.clear()
        for line in batch:
            lines.append(line)
            on_line(line, time.monotonic() - started)

    while True:
        drain()
        if process.poll() is not None and not reader.is_alive():
            drain()
            break
        if time.monotonic() - started > timeout_s:
            kill_tree(process)
            reader.join(timeout=5)
            drain()
            timed_out = True
            break
        on_idle(time.monotonic() - started)
        time.sleep(0.2)
    return "\n".join(lines) + "\n", timed_out


#: The watch's ``Diag`` when RADARS enters a route (``MessageAssembler.parseRadars``).
RADARS_LINE = re.compile(r"radars (\d+) route \d+")


def judge_demo(text: str, timed_out: bool, lit: float | None, canary: bool) -> tuple[int, list[str]]:
    lods = {int(m.group(1)): (int(m.group(2)), int(m.group(3))) for m in LOD_LINE.finditer(text)}
    peaks = [int(p) for p in WORK_PEAK.findall(text)]
    tripped = "Watchdog Tripped" in text
    report = [
        "LODs applied: "
        + (", ".join(f"{lod}={w} ways/{p} pts" for lod, (w, p) in sorted(lods.items())) or "none"),
        f"work peak: {max(peaks) if peaks else '-'} (ceiling {WORK_CEILING}, {len(peaks)} samples of 10 s)",
        f"Watchdog Tripped: {'YES' if tripped else 'no'}",
        f"radars: {RADARS_LINE.search(text).group(1) if RADARS_LINE.search(text) else 'none'}",
        f"screen: {'-' if lit is None else f'{lit:.1%} lit'} (floor {LIT_MIN:.0%})",
    ]
    if canary:
        # As in `test --canary`: exiting 1 is expected, but it only counts as a
        # bite if the death was the watchdog's. Anything else is blindness.
        if tripped:
            return 1, report + ["canary bit: the quadratic parse died by watchdog (exiting 1 here is expected)"]
        return 1, report + ["the canary did NOT die by watchdog: the instrument is blind"]

    failures = []
    if timed_out:
        failures.append(f"went past {DEMO_TIMEOUT_S} s")
    if sorted(lods) != [0, 1, 2, 3]:
        failures.append(f"LODs applied {sorted(lods)}, expected [0, 1, 2, 3]")
    if "map on" not in text:
        failures.append("the map did not come in (no 'map on')")
    radars = RADARS_LINE.search(text)
    if radars is None or int(radars.group(1)) == 0:
        failures.append("the radars did not come in (no 'radars N route', C16.6)")
    if not peaks:
        failures.append("no frameSummary with work peak")
    elif max(peaks) >= WORK_CEILING:
        failures.append(f"work peak {max(peaks)} >= {WORK_CEILING}")
    if tripped:
        failures.append("Watchdog Tripped")
    if "[demo] end" not in text:
        failures.append("the demo did not reach the end ([demo] end missing)")
    if lit is None:
        failures.append("no screen capture")
    elif lit <= LIT_MIN:
        failures.append(f"screen {lit:.1%} lit, floor {LIT_MIN:.0%}")
    return (1 if failures else 0), report + [f"FAILED: {f}" for f in failures]


def parse_config(specs: list[str]) -> dict[str, int]:
    """``["lead_s=10", "near_m=30,pulse_ms=250"]`` -> ``{"lead_s": 10, ...}``, in the order of the key
    id (the same one the watch logs). The name must be in the packer's ``CONFIG_KEYS``."""
    import packer

    values: dict[str, int] = {}
    for spec in specs:
        for item in filter(None, spec.split(",")):
            key, sep, value = item.partition("=")
            if not sep or key not in packer.CONFIG_KEYS or not value.strip().isdigit():
                sys.exit(f"--config {item!r}: use key=value, with the key in {', '.join(packer.CONFIG_KEYS)}")
            values[key] = int(value)
    return dict(sorted(values.items(), key=lambda kv: packer.CONFIG_KEYS[kv[0]]))


#: ``routeId`` of the ``--long-route`` long route: different from SP's 42, so the SP META
#: that comes next is a new route and swaps out the long one, as on the wrist.
LONG_ROUTE_ID = 7

#: The same long route, sent again with another id (C11): with the whole 7 on the watch, 8 is
#: assembled in preparation and the swap happens with **both at the protocol ceiling** in memory, which is
#: the worst case of the atomic swap. The unit test runs with 8 MB (measured: ``of 8187 KB``) and does not
#: prove it fits in the app's 763 KB; the demo runs with the real memory and watchdog.
LONG_SWAP_ID = 8

#: The watch's ``Diag`` on the atomic swap (``MessageAssembler.adopt``).
SWAP_LINE = re.compile(r"route swapped (\d+) -> (\d+)")

#: The watch's ``Diag`` when the whole POLY became a route (``MessageAssembler``).
POLY_LINE = re.compile(r"poly route (\d+) (\d+) pts")


def long_route_frames(points: int, route_id: int = LONG_ROUTE_ID) -> list[bytes]:
    """META, POLY and TURNS of a synthetic route of ``points`` points, as the phone sends them.

    **Why it exists:** in the 2026-10-02 preflight (``DECISIONS.md`` §C6a) the watch died from the
    watchdog in ``parsePoly`` with a 3,136 B POLY, and no simulator fixture had a POLY
    of that size (SP: 722 pts, 2,892 B). The route is synthetic to have the size wanted
    without recording anyone's route. Points ~20 m apart, with smooth curves, near SP; one maneuver every
    250 points."""
    import math

    import packer

    if not 2 <= points <= packer.MAX_POLY_POINTS:
        sys.exit(f"--long-route {points}: use 2 to {packer.MAX_POLY_POINTS} points")
    lat, lon = -2355000, -4663000
    coords = [(lat, lon)]
    meters = 0.0
    for i in range(1, points):
        heading = 0.6 * math.sin(i / 23) + i * 0.01
        dlat = round(18 * math.cos(heading))
        dlon = round(18 * math.sin(heading) / 0.917)
        lat, lon = lat + dlat, lon + dlon
        coords.append((lat, lon))
        meters += math.hypot(dlat * 1.11, dlon * 1.11 * 0.917)
    turns = [packer.Turn(k, packer.TURN_LEFT if k % 500 else packer.TURN_RIGHT, f"Street {k}")
             for k in range(250, points - 1, 250)]
    turns.append(packer.Turn(points - 1, packer.TURN_ARRIVE, ""))
    route = packer.Route(coords, turns, round(meters), round(meters / 12), f"Long route {points}")
    blocks = packer.build_blocks(route, route_id)
    return [c for block in blocks for c in block.chunks]


def write_config_params(path: Path, values: dict[str, int] | None, long_points: int | None = None) -> None:
    """What ``DemoFeed`` injects before SP's route, in Base64 as the phone sends it.

    With ``values``: the empty CONFIG (back to default) and then the requested one. Without ``values`` (the 2nd
    run of ``--reopen``): none, and the setting can only come from ``Storage``. With
    ``long_points``: after them, the long route (:func:`long_route_frames`), twice: the 2nd,
    with another id, swaps the 1st by the preparation (:data:`LONG_SWAP_ID`)."""
    import base64

    import packer

    frames = [] if values is None else [packer.config_frame({}), packer.config_frame(values)]
    if long_points is not None:
        frames += long_route_frames(long_points) + long_route_frames(long_points, LONG_SWAP_ID)
    body = ", ".join(f'"{base64.b64encode(f).decode()}"' for f in frames)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "// GENERATED by tools/sim.py demo (--config, --long-route) on every run, do not edit.\n"
        "import Toybox.Lang;\n\n"
        "function demoPreludeFrames() as Array<String> {\n"
        f"    return [{body}] as Array<String>;\n"
        "}\n",
        encoding="utf-8",
    )


def config_text(values: dict[str, int]) -> str:
    """The ``lead_s=10 near_m=30`` piece of the watch's ``config ... applied`` lines."""
    return " ".join(f"{k}={v}" for k, v in values.items())


def judge_config(text: str, values: dict[str, int], reopened: bool, code: int,
                 report: list[str]) -> tuple[int, list[str]]:
    """The fine adjustment (C5). 1st run: the watch applied the default and then the request. 2nd, with no
    CONFIG in the build: restored the request from ``Storage``. Any refusal is a failure."""
    wanted = config_text(values)
    if reopened:
        # `Config.restore` only logs what differs from the default (reviewer C5): the defaults come from
        # Config.mc itself, so there is no second copy of them here.
        source = (ROOT / "watch" / "source" / "Config.mc").read_text(encoding="utf-8")
        names = re.findall(r'"(\w+)"', re.search(r"const NAMES = \[([^\]]*)\]", source).group(1))
        defaults = [int(v) for v in re.search(r"const DEFAULTS = \[([^\]]*)\]", source).group(1).split(",")]
        changed = {k: v for k, v in values.items() if v != dict(zip(names, defaults))[k]}
        wanted = config_text(changed) if changed else "default"
    need = ([f"config {wanted} restored from Storage"] if reopened
            else ["config default applied", f"config {wanted} applied"])
    failures = [f"missing the line '{line}'" for line in need if line not in text]
    failures += [f"the watch refused: {m.group(0)}" for m in re.finditer(r"config refused[^\n]*", text)]
    report = report + [f"config: {'; '.join(need)} ({'ok' if not failures else 'MISSING'})"]
    report += [f"FAILED: {f}" for f in failures]
    return (1 if failures or code else 0), report


def judge_long_route(text: str, points: int, code: int, report: list[str]) -> tuple[int, list[str]]:
    """The long route went in whole: the watch logged ``poly route 7 <points> pts``. Without the line, the
    POLY did not become a route (died, or was cut), and the rest of the demo being green proves nothing about it.

    Since C11 also: the 2nd copy (:data:`LONG_SWAP_ID`) went in whole, and both atomic
    swaps happened, 7 by 8 (both at the ceiling) and 8 by SP's."""
    for route_id in (LONG_ROUTE_ID, LONG_SWAP_ID):
        got = [int(m.group(2)) for m in POLY_LINE.finditer(text) if int(m.group(1)) == route_id]
        report = report + [f"long route {route_id}: {got[-1] if got else '-'} of {points} pts"]
        if not got or got[-1] != points:
            return 1, report + [f"FAILED: the long route did not go in whole (poly route {route_id} {points} pts missing)"]
    swaps = [(int(m.group(1)), int(m.group(2))) for m in SWAP_LINE.finditer(text)]
    report = report + ["route swaps: " + (", ".join(f"{a} -> {b}" for a, b in swaps) or "-")]
    if len(swaps) != 2 or swaps[0] != (LONG_ROUTE_ID, LONG_SWAP_ID) or swaps[1][0] != LONG_SWAP_ID:
        return 1, report + [f"FAILED: expected two atomic swaps, {LONG_ROUTE_ID} -> {LONG_SWAP_ID} and "
                            f"{LONG_SWAP_ID} -> the demo route"]
    return code, report


def cmd_demo(fixture: str, canary: bool, config: list[str] | None = None, reopen: bool = False,
             long_points: int | None = None) -> int:
    resource = DEMO_FIXTURES.get(fixture)
    if resource is None or not resource.exists():
        print(f"FAILED: '{fixture}' has no demo resource (there are: {', '.join(DEMO_FIXTURES)}). "
              'Generate it with ./gradlew testDebugUnitTest --tests "*DemoFramesTest*"')
        return 1
    if (config or reopen) and canary:
        sys.exit("--config/--reopen do not combine with --canary")
    if reopen and not config:
        sys.exit("--reopen needs --config: it says what must come back from Storage")
    if long_points is not None and (canary or config or reopen):
        sys.exit("--long-route runs alone: no --canary, --config or --reopen")
    values = parse_config(config) if config else None
    ensure_simulator()

    code = run_demo(fixture, canary, values, long_points=long_points)
    if code != 0 or not reopen:
        return code
    # 2nd opening of the same app: with no CONFIG in the build, the setting can only come from Storage.
    print("\n--reopen: relaunching the app without CONFIG")
    return run_demo(fixture, canary, values, reopened=True)


def run_demo(fixture: str, canary: bool, values: dict[str, int] | None, reopened: bool = False,
             long_points: int | None = None) -> int:
    jungles = [JUNGLE, DEMO_JUNGLE] + ([DEMO_CANARY_JUNGLE] if canary else [])
    if values is not None or long_points is not None:
        write_config_params(CONFIG_PARAMS, None if reopened else values, long_points)
        jungles.append(DEMO_CONFIG_JUNGLE)
    name = (f"demo_{fixture}" + ("_canary" if canary else "") + ("_config" if values else "")
            + (f"_longa{long_points}" if long_points else "") + ("_reaberto" if reopened else ""))
    prg = BIN / ("MotoNavDemoCanary.prg" if canary else "MotoNavDemo.prg")
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg(jungles, prg, unit_test=False):
        print("FAILED: the demo did not compile")
        return 1

    png = SHOTS / f"{name}.png"
    state: dict = {"ready_at": None, "shot": False, "lit": None}

    def on_line(line: str, elapsed: float) -> None:
        if (line.startswith("[demo]") or "Watchdog" in line or "corridor lod" in line
                or "work peak" in line or line.startswith("Error") or "] config" in line
                or "poly route" in line or "route swapped" in line):
            print(f"{elapsed:5.1f}s {line}")
        if line.startswith("[demo] ready"):
            state["ready_at"] = elapsed

    def on_idle(elapsed: float) -> None:
        # The canary dies before being ready; if it does not die, there is no screen to judge.
        if canary or state["shot"] or state["ready_at"] is None:
            return
        if elapsed - state["ready_at"] < SHOT_DELAY_S:
            return
        state["shot"] = True
        error = take_shot(png)
        if error:
            print(f"{elapsed:5.1f}s capture failed: {error}")
            return
        state["lit"] = lit_fraction(png)
        print(f"{elapsed:5.1f}s capture: {state['lit']:.1%} lit")

    text, timed_out = run_live(prg, DEMO_TIMEOUT_S, on_line, on_idle)
    log = save(f"{name}.log", text)
    code, report = judge_demo(text, timed_out, state["lit"], canary)
    if long_points is not None:
        code, report = judge_long_route(text, long_points, code, report)
    if values is not None:
        code, report = judge_config(text, values, reopened, code, report)
    print()
    for line in report:
        print(f"  {line}")
    verdict = "canary" if canary else ("ok" if code == 0 else "FAILED")
    print(f"\n{verdict} · log {log.relative_to(ROOT)}"
          + (f" · png {png.relative_to(ROOT)}" if state["lit"] is not None else ""))
    return code


# --------------------------------------------------------------------------- #
# ride
# --------------------------------------------------------------------------- #

ALERT_LINE = re.compile(r"vibe turn (\d+) alert (\d) at (-?[\d.]+)m ([\d.]+)km/h (\d+)p")
ARRIVED_LINE = re.compile(r"arrived at destination at (\d+)m")
#: The HUD showed the weather (C9): ``hud weather 24C nublado``. The lap injects 24 °C
#: (``RideStart.mc``), because the simulator has no weather cache.
WEATHER_LINE = re.compile(r"hud weather (-?\d+)C\b")
#: The temperature that ``RideStart.mc`` injects (``WeatherInfo.inject(24, 1)``).
INJECTED_WEATHER_C = 24
RIDE_START = re.compile(r"^\[ride\] start (\d+) pts (\d+) maneuvers ([\d.]+) m")
RIDE_TURN = re.compile(r"^\[ride\] maneuver (\d+) type (\d+) at ([\d.]+) m")
RIDE_END = re.compile(r"^\[ride\] end (.+) in (\d+) fixes")

#: Accepted difference between the watch's route (Kotlin pipeline, 32-bit
#: Float) and ``esperado.py``'s (``packer.py``, Double), in meters along the
#: route. Measured on the 1st lap of 2026-09-29: 0.00 m on the 16 maneuvers and 0.0 m on the
#: total (22,385.2 m); 1 m is slack for rounding, not for a different route.
ROUTE_TOLERANCE_M = 1.0

#: Tolerance of the logged speed against the Python profile's, in km/h: the log
#: has one decimal place and the watch computes in 32-bit Float.
SPEED_TOLERANCE_KMH = 1.0

#: Seconds of loading before the first fix: the demo measures ~40 s up to
#: ``[demo] ready`` (C2b); 60 s is the slack.
RIDE_LOAD_S = 60

#: Connect IQ's timer does not accept a period below 50 ms.
MIN_PERIOD_MS = 50


def ride_paths(fixture: str) -> tuple[Path, Path]:
    return (ROOT / "tools" / "fixtures" / f"{fixture}.esperado.json",
            ROOT / "watch" / "bin" / "ride" / "RideParams.mc")


def monkey_literal(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return repr(float(value))
    if isinstance(value, list):
        inner = ", ".join(monkey_literal(v) for v in value)
        kind = "Float" if all(isinstance(v, float) for v in value) else "Object"
        return f"[{inner}] as Array<{kind}>"
    raise TypeError(f"no Monkey C literal for {value!r}")


def write_ride_params(path: Path, profile: dict, period_ms: int, fixture: str,
                      street_cache: bool = True) -> None:
    """The ``.esperado.json`` profile becomes code: the watch does not read JSON."""
    entries = ",\n".join(f'            "{k}" => {monkey_literal(v)}' for k, v in profile.items())
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "// GENERATED by tools/sim.py ride on every run, do not edit.\n"
        f"// Profile of tools/fixtures/{fixture}.esperado.json.\n"
        "import Toybox.Lang;\n\n"
        "module RideParams {\n\n"
        f"    const PERIOD_MS = {period_ms};\n\n"
        "    //! The streets as an image (`StreetCache`); `--no-cache` turns it off.\n"
        f"    const STREET_CACHE = {'true' if street_cache else 'false'};\n\n"
        "    function profile() as Dictionary {\n"
        "        return {\n"
        f"{entries}\n"
        "        };\n"
        "    }\n"
        "}\n",
        encoding="utf-8",
    )


def within(value: float, window: list[float]) -> bool:
    return window[0] <= value <= window[1]


def judge_maneuver(expected: dict, alerts: list[tuple[int, float, float, int]]) -> list[str]:
    """The defects of a maneuver; empty list = PASS.

    ``alerts`` are the ``(alert, distance, km/h, pulses)`` that the watch logged.
    """
    counts = expected["alerts"]
    got = len(alerts)
    problems = []
    if got not in counts:
        if got == 0:
            problems.append("no alert")
        elif 0 in counts:
            problems.append(f"{got} alert(s), but this maneuver does not vibrate ({expected.get('reason')})")
        elif got > 2:
            problems.append(f"{got} alerts, the maximum is 2")
        elif got < max(counts):
            problems.append("no 2nd alert")
        else:
            problems.append(f"unexpected 2nd alert ({expected.get('reason')})")
    if 0 in counts and got == 0:
        return problems

    for stage, distance, kmh, pulses in alerts:
        if "pulses" in expected and pulses != expected["pulses"]:
            problems.append(f"alert {stage} with {pulses} pulses, expected {expected['pulses']}")
        if stage > 2:
            continue
        window = expected.get(f"alert{stage}_m")
        if window and not within(distance, window):
            problems.append(f"alert {stage} at {distance:.1f}m, expected {window[0]}–{window[1]}")
        speeds = expected.get(f"alert{stage}_kmh")
        if speeds and not (speeds[0] - SPEED_TOLERANCE_KMH <= kmh <= speeds[1] + SPEED_TOLERANCE_KMH):
            problems.append(f"alert {stage} at {kmh:.1f} km/h, the profile says {speeds[0]}–{speeds[1]}")
    stages = [a[0] for a in alerts]
    if stages != sorted(stages) or len(set(stages)) != len(stages):
        problems.append(f"alerts out of order or repeated: {stages}")
    return problems


def judge_ride(text: str, spec: dict, timed_out: bool, canary: bool,
               ceiling: int = WORK_CEILING) -> tuple[int, list[str]]:
    lines = text.splitlines()
    report: list[str] = []
    failures: list[str] = []

    # Is the watch's route the expected one?
    start = next((RIDE_START.search(l) for l in lines if RIDE_START.search(l)), None)
    route_spec = spec["route"]
    if start is None:
        failures.append("the lap did not start ([ride] start missing)")
    else:
        pts, turns, metres = int(start.group(1)), int(start.group(2)), float(start.group(3))
        if (pts, turns) != (route_spec["points"], route_spec["maneuvers"]) or abs(metres - route_spec["meters"]) > ROUTE_TOLERANCE_M:
            failures.append(f"watch route {pts} pts/{turns} maneuvers/{metres} m, "
                            f"expected {route_spec['points']}/{route_spec['maneuvers']}/{route_spec['meters']}")
        worst = 0.0
        for m in (RIDE_TURN.search(l) for l in lines):
            if m is None:
                continue
            index, at = int(m.group(1)), float(m.group(3))
            if index < len(spec["maneuvers"]):
                worst = max(worst, abs(at - spec["maneuvers"][index]["at_m"]))
        if worst > ROUTE_TOLERANCE_M:
            failures.append(f"maneuver out of place: {worst:.1f} m off (ceiling {ROUTE_TOLERANCE_M})")
        report.append(f"route: {pts} pts, {turns} maneuvers, {metres:.0f} m · worst maneuver {worst:.2f} m from expected")

    # The alerts, in the order they came out, and what came after the arrival.
    by_turn: dict[int, list[tuple[int, float, float, int]]] = {}
    arrivals, arrival_vibes, after_arrival = [], 0, []
    for line in lines:
        alert = ALERT_LINE.search(line)
        if alert:
            record = (int(alert.group(2)), float(alert.group(3)), float(alert.group(4)), int(alert.group(5)))
            if arrivals:
                after_arrival.append(int(alert.group(1)))
            by_turn.setdefault(int(alert.group(1)), []).append(record)
        arrived = ARRIVED_LINE.search(line)
        if arrived:
            arrivals.append(int(arrived.group(1)))
        if "vibe arrival" in line:
            arrival_vibes += 1

    maneuver_lines, missing_near = [], []
    for expected in spec["maneuvers"]:
        index = expected["i"]
        alerts = by_turn.pop(index, [])
        problems = judge_maneuver(expected, alerts)
        label = f"{index} {expected['type']} {expected['street']}".rstrip()
        seen = " · ".join(f"#{s} at {d:.0f}m {v:.0f}km/h {p}p" for s, d, v, p in alerts) or "no alert"
        if problems:
            maneuver_lines.append(f"FAIL {index}: {'; '.join(problems)}  [{label} · {seen}]")
            if "no 2nd alert" in problems:
                missing_near.append(index)
        else:
            tag = f" (ambiguous: {expected['ambiguous']})" if "ambiguous" in expected else ""
            maneuver_lines.append(f"PASS {label} · {seen}{tag}")
    for index, alerts in sorted(by_turn.items()):
        maneuver_lines.append(f"FAIL {index}: alert of a maneuver the expected file does not know ({len(alerts)})")

    fails = [l for l in maneuver_lines if l.startswith("FAIL")]
    report += maneuver_lines

    # The arrival.
    end = next((RIDE_END.search(l) for l in lines if RIDE_END.search(l)), None)
    arrival_problems = []
    if len(arrivals) != 1:
        arrival_problems.append(f"{len(arrivals)} arrivals in the log, expected 1")
    elif arrivals[0] > spec["arrival"]["up_to_m"]:
        arrival_problems.append(f"arrived {arrivals[0]} m from the end, the ceiling is {spec['arrival']['up_to_m']}")
    if arrival_vibes != 1:
        arrival_problems.append(f"{arrival_vibes} arrival vibrations, expected 1")
    if after_arrival:
        arrival_problems.append(f"turn alert after the arrival: maneuvers {after_arrival}")
    if end is None or end.group(1) != "arrival":
        arrival_problems.append(f"the lap ended by '{end.group(1) if end else 'nothing'}'")
    report.append("arrival ok" + (f" at {arrivals[0]} m" if arrivals else "") if not arrival_problems
                  else "FAIL arrival: " + "; ".join(arrival_problems))

    peaks = [int(p) for p in WORK_PEAK.findall(text)]
    tripped = "Watchdog Tripped" in text
    report.append(f"work peak {max(peaks) if peaks else '-'} (ceiling {ceiling}, {len(peaks)} samples)"
                  + (f" · {end.group(2)} fixes" if end else ""))

    # The weather on the HUD (C9): the line only comes out when the HUD drew it.
    # The simulator has its own weather cache (17 °C in the 2026-10-10 run), which
    # the HUD logs first; the lap then injects 24 °C. Requiring the 24 proves the
    # whole path (injection -> HUD -> log), not just that the cache read something.
    weathers = [m.group(1) for m in (WEATHER_LINE.search(l) for l in lines) if m]
    if str(INJECTED_WEATHER_C) not in weathers:
        failures.append(f"the HUD did not log the injected weather ('hud weather {INJECTED_WEATHER_C}C' missing; "
                        f"got {weathers or 'none'})")
    else:
        report.append(f"HUD weather: {INJECTED_WEATHER_C} °C injected (logged readings: {', '.join(weathers)})")

    if canary:
        wanted = [m["i"] for m in spec["maneuvers"] if m["alerts"] == [2]]
        if wanted and all(i in missing_near for i in wanted):
            return 1, report + [f"canary bit: no 2nd alert in {wanted} (exiting 1 here is expected)"]
        return 1, report + [f"the canary did NOT bite: expected 'no 2nd alert' in {wanted}, "
                            f"got {missing_near}: the lap is blind"]

    if timed_out:
        failures.append("the lap went past the deadline")
    if tripped:
        failures.append("Watchdog Tripped")
    if not peaks:
        failures.append("no frameSummary with work peak")
    elif max(peaks) >= ceiling:
        failures.append(f"work peak {max(peaks)} >= {ceiling}")
    if fails:
        failures.append(f"{len(fails)} maneuver(s) failed")
    if arrival_problems:
        failures.append("arrival")
    return (1 if failures else 0), report + [f"FAILED: {f}" for f in failures]


#: The lap's detour (C11): to the right of the route, in meters. 60 m is 1.5x the RF-11 threshold
#: (40 m), far enough that the profile's noise (2 m) decides nothing.
DETOUR_M = 60.0

#: The detour canary: 30 m, below the threshold. The lap with it **must** fail (no
#: ``off route`` in the log): it is what proves the judge sees the absence of the detour.
DETOUR_CANARY_M = 30.0

#: Seconds of bike off the route: the 5 s of RF-11's window and the 10 s of the new-route timeout
#: (RF-11) make 15 s; the extra 17 s give the photo (1 s wait, at 4 fixes per second of
#: watch) and the "No phone" time to show up before the bike returns.
DETOUR_SECONDS = 32

#: Margin between the detour and the nearest maneuver, in meters, beyond the distance at which the bike is
#: already braking for it (``hold_m``): the detour is on a straight, with no turn alert around it.
DETOUR_MARGIN_M = 100.0


def plan_detour(spec: dict, metres: float) -> dict:
    """The detour stretch, as the three keys ``ReplaySource`` already reads.

    It sits in the middle of the route's longest maneuver-free stretch and lasts :data:`DETOUR_SECONDS` at
    cruising speed. The keys are fractions of the route length (``ReplaySource``). Exits with
    ``SystemExit`` if the route has no straight that fits: a detour glued to a turn would prove
    something else."""
    profile = spec["profile"]
    total = spec["route"]["meters"]
    marks = [0.0] + [m["at_m"] for m in spec["maneuvers"]] + [total]
    gap, start = max((b - a, a) for a, b in zip(marks, marks[1:]))
    length = DETOUR_SECONDS * profile["cruise_kmh"] / 3.6
    need = length + 2 * (profile["hold_m"] + DETOUR_MARGIN_M)
    if gap < need:
        sys.exit(f"--detour: the longest maneuver-free stretch is {gap:.0f} m and the detour needs {need:.0f} m")
    centre = start + gap / 2
    return {"detour_m": metres,
            "detour_from": (centre - length / 2) / total,
            "detour_to": (centre + length / 2) / total}


def judge_detour(text: str, canary: bool) -> tuple[list[str], list[str]]:
    """The lap's detour, in the watch's log: ``(failures, report lines)``.

    Exactly one exit from the route, one vibration, two requests (the exit's and the retry), and in the order RF-11 dictates: the screen
    shows "Recalculating…" with the arrow back, after 10 s without a reply "No phone", and
    the bike returns to the route."""
    failures: list[str] = []
    outs = re.findall(r"off route (\d+)m", text)
    counts = {
        "off route": len(outs),
        "reroute req": text.count("reroute req"),
        "vibe off route": text.count("vibe off route"),
        "hud arrow back": text.count("hud arrow back"),
        "hud Recalculating": text.count("hud Recalculating"),
        "hud No phone": text.count("hud No phone"),
        "back on route": text.count("back on route"),
    }
    # 2 requests: the exit's (5 s off) and the retry, silent, 20 s later (ADR-4); the
    # detour lasts 32 s, so the second fits and a third (at 45 s) does not.
    expected = {"reroute req": 2}
    for what, got in counts.items():
        want = expected.get(what, 1)
        if got != want:
            failures.append(f"{what!r} {got}x in the log, expected {want}")
    order = [text.find(k) for k in ("hud Recalculating", "hud No phone", "back on route")]
    if all(i >= 0 for i in order) and order != sorted(order):
        failures.append("the order Recalculating -> No phone -> back on route was not the log's")
    report = [f"detour: {counts['off route']}x off route"
              + (f" at {outs[0]} m" if outs else "")
              + f" · {counts['reroute req']} requests · Recalculating {counts['hud Recalculating']}x · "
                f"No phone {counts['hud No phone']}x · back {counts['back on route']}x"]
    if canary and failures:
        report.append(f"canary bit: {DETOUR_CANARY_M:.0f} m is not off route (exiting 1 here is expected)")
    return failures, report


def cmd_ride(fixture: str, speed: float, canary: bool, ceiling: int = WORK_CEILING,
             detour: int | None = None, no_phone: bool = False, street_cache: bool = True) -> int:
    expected_path, params_path = ride_paths(fixture)
    resource = DEMO_FIXTURES.get(fixture)
    if resource is None or not resource.exists() or not expected_path.exists():
        print(f"FAILED: '{fixture}' needs the demo resource and {expected_path.name} "
              f"(python tools/esperado.py --fixture {fixture})")
        return 1
    period_ms = round(1000 / speed)
    if period_ms < MIN_PERIOD_MS:
        print(f"FAILED: --speed {speed} gives {period_ms} ms between fixes, the minimum is {MIN_PERIOD_MS}")
        return 1

    spec = json.loads(expected_path.read_text(encoding="utf-8"))
    profile = dict(spec["profile"])
    if detour is not None:
        # The simulator has no phone: the request goes out and nobody answers, which is the "No
        # phone". The real new route is `tools/e2e.py --detour`.
        if detour != 1:
            print("FAILED: --detour only accepts 1 on the lap (the 3 detours with a reply are e2e.py's)")
            return 1
        if not no_phone:
            print("FAILED: --detour needs --no-phone: the simulator has no phone to "
                  "answer, and the lap proves what the watch does without one")
            return 1
        profile.update(plan_detour(spec, DETOUR_CANARY_M if canary else DETOUR_M))
    write_ride_params(params_path, profile, period_ms, fixture, street_cache)
    ensure_simulator()
    # With --detour the canary is the 30 m detour, not the ordinary lap's `no_near_alert`.
    near_canary = canary and detour is None
    jungles = [JUNGLE, RIDE_JUNGLE] + ([RIDE_CANARY_JUNGLE] if near_canary else [])
    name = (f"ride_{fixture}" + ("_canary" if canary else "") + ("_desvio" if detour else "")
            + ("" if street_cache else "_semcache"))
    prg = BIN / ("MotoNavRideCanary.prg" if near_canary else "MotoNavRide.prg")
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg(jungles, prg, unit_test=False):
        print("FAILED: the lap did not compile")
        return 1

    # The lap takes `duration_s` fixes at `period_ms` each; 1.5x is the slack for the
    # simulator to draw slower than the timer.
    timeout_s = int((spec["duration_s"] * period_ms / 1000 + RIDE_LOAD_S) * 1.5)
    print(f"lap of {spec['route']['meters'] / 1000:.1f} km, {spec['duration_s']} fixes "
          f"every {period_ms} ms (deadline {timeout_s} s)")

    shot: dict = {"at": None, "lit": None, "error": None}
    detour_words = ("off route", "hud arrow", "hud Recalculating", "hud No phone",
                    "reroute req", "back on route")

    def on_line(line: str, elapsed: float) -> None:
        if (line.startswith("[ride] start") or line.startswith("[ride] end") or "vibe " in line
                or line.startswith("[ride] streets")
                or "arrived at destination" in line or "Watchdog" in line or line.startswith("Error")
                or "hud weather" in line
                or (detour is not None and any(w in line for w in detour_words))):
            print(f"{elapsed:6.1f}s {line}")
        if detour is not None and "hud Recalculating" in line and shot["at"] is None:
            shot["at"] = elapsed

    def on_idle(elapsed: float) -> None:
        # The photo of the "Recalculating…" card: one second after it shows up, still
        # within the 10 s before "No phone".
        if shot["at"] is None or shot["lit"] is not None or shot["error"] is not None:
            return
        if elapsed - shot["at"] < SHOT_SETTLE_S:
            return
        png = SHOTS / "desvio.png"
        shot["error"] = take_shot(png)
        if shot["error"] is None:
            shot["lit"] = lit_fraction(png)
            print(f"{elapsed:6.1f}s capture {png.name}: {shot['lit']:.1%} lit")

    text, timed_out = run_live(prg, timeout_s, on_line, on_idle)
    log = save(f"{name}.log", text)
    code, report = judge_ride(text, spec, timed_out, near_canary, ceiling)
    if detour is not None:
        failures, lines = judge_detour(text, canary)
        report = report + lines
        if not canary:
            if shot["lit"] is None:
                failures.append(f"no detour photo ({shot['error'] or 'Recalculating did not show up'})")
            elif shot["lit"] <= LIT_MIN:
                failures.append(f"detour photo {shot['lit']:.1%} lit, floor {LIT_MIN:.0%}")
            else:
                report.append(f"photo: shots/desvio.png · {shot['lit']:.1%} lit")
        report += [f"FAILED: {f}" for f in failures]
        code = 1 if (code or failures) else 0
    print()
    for line in report:
        print(f"  {line}")
    verdict = "canary" if canary else ("ok" if code == 0 else "FAILED")
    print(f"\n{verdict} · log {log.relative_to(ROOT)}")
    return code


# --------------------------------------------------------------------------- #
# shots
# --------------------------------------------------------------------------- #

SHOT_READY = re.compile(r"^\[shot\] ready (\w+)")

#: Screens timeout. The demo takes ~40 s to be ready (C2b) and each scene stays
#: 10 to 30 s (3 s settling, up to 20 s waiting for the streets image and 7 of capture,
#: `ShotStart.mc`); with the 8 scenes of ``--sheet4`` it is up to 290 s in the worst case, and 360 s is the slack.
SHOTS_TIMEOUT_S = 360

#: Wait between ``[shot] ready`` and the capture: the last redraw has already come out.
SHOT_SETTLE_S = 1.0


#: ``shots --sheet4`` (2026-10-17): the sheet 4 scenes that ``tokens.json`` does not have. The end of the
#: route at 110 m (the destination dot), the three states of the rider's ring and the route without the edge
#: (v1.1.5: the edge is the default, and the test setting turns it off). The ``state`` is what
#: ``ShotStart`` puts in ``NavState`` after each fix: 1 recalculating, 2 weak GPS, 3 no
#: position, 4 the route edge turned off.
SHEET4_SCENES = {
    "destino": {"maneuver": 18, "dist_m": 110, "zoom": 1.2, "state": 0},
    "recalculando": {"maneuver": 7, "dist_m": 300, "zoom": 1.2, "state": 1},
    "gps_fraco": {"maneuver": 7, "dist_m": 300, "zoom": 1.2, "state": 2},
    "sem_posicao": {"maneuver": 7, "dist_m": 300, "zoom": 1.2, "state": 3},
    "sem_borda": {"maneuver": 7, "dist_m": 45, "zoom": 1.2, "state": 4},
}

#: ``shots --showcase`` (2026-10-26): the README and post photos, only in central SP (Prestes
#: Maia, Ipiranga, São Luís, Copan). The ``tokens.json`` scenes sit at the start of the route, outside the
#: center, which does not go into a public photo.
#: Each photo comes after an identical warm-up scene: in the 26/10 run, only the last scene
#: came out with the streets image; the other three went through the 20 s of ``IMAGE_WAIT_S`` without it and
#: came out with the street-by-street drawing half done. The second pass usually finds the tiles
#: ready. It is still unstable: stopped on Ipiranga (the radar and the old scene at 250 m from São Luís),
#: the app sometimes gives "You arrived" on the second pass (the match jumps to the end of the route,
#: ~400 m from there), and the arrival comes out without streets. Check the photos one by one; the ones in docs/img/ are from
#: a run of ``tools/telas_en.py``, the English preview, which came out clean.
SHOWCASE_SCENES = {}
for _name, _scene in {
    "vitrine_radar": {"maneuver": 13, "dist_m": 780, "zoom": 1.2},
    "vitrine_perto": {"maneuver": 10, "dist_m": 120, "zoom": 1.2},
    "vitrine_casper": {"maneuver": 11, "dist_m": 150, "zoom": 1.2},
    "vitrine_chegada": {"maneuver": 15, "dist_m": 0, "zoom": 1.2},
}.items():
    if _scene["dist_m"]:  # the arrival comes last and does not leave "You arrived": no warm-up
        SHOWCASE_SCENES[_name.replace("vitrine_", "aquece_")] = _scene
    SHOWCASE_SCENES[_name] = _scene


def write_shot_params(tokens: dict, config: dict[str, int] | None = None,
                      extra: dict | None = None) -> list[str]:
    """The ``tokens.json`` scenes become code: which maneuver, at what distance and
    at what zoom level (the closest to the scene's ``zoom`` among the watch's).
    ``config`` (C16.5, ``shots --config``): the settings ``ShotStart`` puts in ``Config``
    before the first scene, to photograph the group sizes at the ends. ``extra``: scenes
    beyond those of ``tokens.json``, with their ``state`` (``SHEET4_SCENES``)."""
    import packer

    config = config or {}
    levels = [0.6, 1.2, 2.5, 5.0, 10.0, 20.0]  # NavState.ZOOM_LEVELS
    names, turns, dists, zooms, states = [], [], [], [], []
    # The arrival (distance 0) comes last: after it the app does not leave "You arrived".
    scenes = list(tokens["scenes"].items()) + list((extra or {}).items())
    scenes.sort(key=lambda item: item[1]["dist_m"] == 0)
    for name, scene in scenes:
        names.append(name)
        turns.append(scene["maneuver"])
        dists.append(scene["dist_m"])
        zooms.append(min(range(len(levels)), key=lambda i: abs(levels[i] - scene["zoom"])))
        states.append(scene.get("state", 0))
    SHOT_PARAMS.parent.mkdir(parents=True, exist_ok=True)
    quoted = ", ".join(f'"{n}"' for n in names)
    SHOT_PARAMS.write_text(
        "// GENERATED by tools/sim.py shots on every run, do not edit.\n"
        "// Scenes of docs/design/relogio/tokens.json.\n"
        "import Toybox.Lang;\n\n"
        "module ShotParams {\n\n"
        f"    const NAMES = [{quoted}] as Array<String>;\n"
        f"    const TURN = {turns} as Array<Number>;\n"
        f"    const DIST_M = {dists} as Array<Number>;\n"
        f"    const ZOOM_INDEX = {zooms} as Array<Number>;\n"
        f"    const STATE = {states} as Array<Number>;\n"
        f"    const CONFIG_KEYS = {[packer.CONFIG_KEYS[k] for k in config]} as Array<Number>;\n"
        f"    const CONFIG_VALUES = {list(config.values())} as Array<Number>;\n"
        "}\n",
        encoding="utf-8",
    )
    return names


def cmd_shots(config: dict[str, int] | None = None, tag: str = "", sheet4: bool = False,
              showcase: bool = False) -> int:
    """The riding screens in the simulator, with SP's route: one photo per scene
    of ``tokens.json``, in ``shots/tela_<scene>.png``. Exits 0 only with the three photos,
    each above the lit-pixel floor, without Watchdog and with ``[shot] end``.
    With ``config`` and ``tag`` (C16.5), the settings apply before the first scene and the photos
    come out in ``shots/tela_<scene>_<tag>.png``."""
    tokens = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    resource = DEMO_FIXTURES["tiete_copan"]
    if not resource.exists():
        print('FAILED: no demo resource (./gradlew testDebugUnitTest --tests "*DemoFramesTest*")')
        return 1
    if showcase:
        tokens = {**tokens, "scenes": {}}
    names = write_shot_params(tokens, config, SHOWCASE_SCENES if showcase else SHEET4_SCENES if sheet4 else None)
    ensure_simulator()
    prg = BIN / "MotoNavShots.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, SHOTS_JUNGLE], prg, unit_test=False):
        print("FAILED: the screens did not compile")
        return 1

    state: dict = {"pending": [], "taken": {}, "problems": []}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[shot]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = SHOT_READY.search(line)
        if ready:
            state["pending"].append((ready.group(1), elapsed))

    def on_idle(elapsed: float) -> None:
        if not state["pending"] or elapsed - state["pending"][0][1] < SHOT_SETTLE_S:
            return
        name, _ = state["pending"].pop(0)
        png = SHOTS / (f"tela_{name}_{tag}.png" if tag else f"tela_{name}.png")
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture of {name} failed: {error}")
            return
        state["taken"][name] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken'][name]:.1%} lit")

    text, timed_out = run_live(prg, SHOTS_TIMEOUT_S, on_line, on_idle)
    log = save("shots.log", text)
    failures = list(state["problems"])
    for name in names:
        lit = state["taken"].get(name)
        if lit is None:
            failures.append(f"no photo of scene {name}")
        elif lit <= LIT_MIN:
            failures.append(f"scene {name}: {lit:.1%} lit, floor {LIT_MIN:.0%}")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[shot] end" not in text:
        failures.append("the scenes did not reach the end ([shot] end missing)")
    if timed_out:
        failures.append(f"went past {SHOTS_TIMEOUT_S} s")

    print()
    for name in names:
        if name in state["taken"]:
            print(f"  shots/tela_{name}{'_' + tag if tag else ''}.png · {state['taken'][name]:.1%} lit")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# shots --details
# --------------------------------------------------------------------------- #

DETAILS_READY = re.compile(r"^\[details\] ready (\d+) maneuvers (.+)$")

#: Details photo timeout. The demo takes ~40 s to be ready (C2b) and the bike
#: rides 120 virtual s at 20 fixes/s (``DetalhesStart.mc``); 180 s is slack.
DETAILS_TIMEOUT_S = 180


def cmd_details() -> int:
    """The Details screen (C9) in the simulator, with SP's route and the bike in the middle of it:
    ``shots/detalhes.png``. Exits 0 only with the photo above the lit-pixel floor, the
    ``[details] ready`` line with the 3 maneuvers, without Watchdog and with
    ``[details] end``. The exact content is that of ``DetailsTest`` (the `DetailsModel`)."""
    resource = DEMO_FIXTURES["tiete_copan"]
    if not resource.exists():
        print('FAILED: no demo resource (./gradlew testDebugUnitTest --tests "*DemoFramesTest*")')
        return 1
    ensure_simulator()
    prg = BIN / "MotoNavDetalhes.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, DETAILS_JUNGLE], prg, unit_test=False):
        print("FAILED: the Details screen did not compile")
        return 1

    state: dict = {"ready": None, "taken": None, "problems": [], "info": None}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[details]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = DETAILS_READY.search(line)
        if ready:
            state["ready"] = elapsed
            state["info"] = (int(ready.group(1)), ready.group(2))

    def on_idle(elapsed: float) -> None:
        if state["ready"] is None or state["taken"] is not None:
            return
        if elapsed - state["ready"] < SHOT_SETTLE_S:
            return
        png = SHOTS / "detalhes.png"
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture failed: {error}")
            state["taken"] = -1.0
            return
        state["taken"] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken']:.1%} lit")

    text, timed_out = run_live(prg, DETAILS_TIMEOUT_S, on_line, on_idle)
    log = save("detalhes.log", text)
    failures = list(state["problems"])
    if state["info"] is None:
        failures.append("the screen did not get ready ([details] ready missing)")
    elif state["info"][0] != 3:
        failures.append(f"{state['info'][0]} maneuvers on the screen, expected 3")
    if state["taken"] is None:
        failures.append("no photo of the Details screen")
    elif state["taken"] >= 0 and state["taken"] <= LIT_MIN:
        failures.append(f"{state['taken']:.1%} lit, floor {LIT_MIN:.0%}")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[details] end" not in text:
        failures.append("the screen did not reach the end ([details] end missing)")
    if timed_out:
        failures.append(f"went past {DETAILS_TIMEOUT_S} s")

    print()
    if state["taken"] is not None and state["taken"] >= 0:
        print(f"  shots/detalhes.png · {state['taken']:.1%} lit")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# shots --home
# --------------------------------------------------------------------------- #

HOME_READY = re.compile(r"^\[home\] ready (\w+)$")
#: The ``InicioStart.mc`` scenes, in order; each takes 8 s in the simulator.
HOME_SCENES = ["pronto", "cade", "pedindo", "silencio", "recentes", "ligacao"]
HOME_TIMEOUT_S = 120


def cmd_home() -> int:
    """The home screen (sheet 1, 2026-10-18) in the simulator, in each sheet state:
    ``shots/inicio_<scene>.png`` and ``shots/folha_inicio.png`` with all side by side. Exits 0 only with
    the six photos above the lit-pixel floor, without Watchdog and with ``[home] end``."""
    ensure_simulator()
    prg = BIN / "MotoNavInicio.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, HOME_JUNGLE], prg, unit_test=False):
        print("FAILED: the home screen did not compile")
        return 1

    state: dict = {"ready": None, "taken": {}, "problems": []}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[home]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = HOME_READY.search(line)
        if ready:
            state["ready"] = (ready.group(1), elapsed)

    def on_idle(elapsed: float) -> None:
        if state["ready"] is None:
            return
        name, at = state["ready"]
        if name in state["taken"] or elapsed - at < SHOT_SETTLE_S:
            return
        png = SHOTS / f"inicio_{name}.png"
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture of {name} failed: {error}")
            state["taken"][name] = -1.0
            return
        state["taken"][name] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken'][name]:.1%} lit")

    text, timed_out = run_live(prg, HOME_TIMEOUT_S, on_line, on_idle)
    log = save("inicio.log", text)
    failures = list(state["problems"])
    for name in HOME_SCENES:
        lit = state["taken"].get(name)
        if lit is None:
            failures.append(f"no photo of scene {name}")
        elif 0 <= lit <= LIT_MIN:
            failures.append(f"{name}: {lit:.1%} lit, floor {LIT_MIN:.0%}")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[home] end" not in text:
        failures.append("the scene round did not reach the end ([home] end missing)")
    if timed_out:
        failures.append(f"went past {HOME_TIMEOUT_S} s")

    shots = [SHOTS / f"inicio_{name}.png" for name in HOME_SCENES if (SHOTS / f"inicio_{name}.png").exists()]
    if shots:
        from PIL import Image, ImageDraw  # only the sheet needs Pillow

        sheet = Image.new("RGB", (len(shots) * 470 + 10, 500), (11, 15, 19))
        draw = ImageDraw.Draw(sheet)
        for i, png in enumerate(shots):
            with Image.open(png) as image:
                sheet.paste(image.convert("RGB"), (10 + i * 470, 10))
            draw.text((10 + i * 470, 472), png.stem.removeprefix("inicio_"), fill=(176, 186, 194))
        sheet.save(SHOTS / "folha_inicio.png")
        print("  shots/folha_inicio.png")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# shots --burnin
# --------------------------------------------------------------------------- #

BURNIN_READY = re.compile(r"^\[burnin\] ready (a|b) point (\d+) dx (-?\d+) dy (-?\d+) amplitude (\d+)")
BURNIN_CUT = re.compile(
    r"^\[burnin\] cut amplitude (\d+) cut (\d+) of (\d+) budget (-?\d+) widest (\d+)")

#: Orbit timeout. The demo takes ~40 s to be ready (C2b), the bike rides 120 virtual
#: s and each orbit point stays 6 s on the air (``BurnInStart.mc``); 180 s is slack.
BURNIN_TIMEOUT_S = 180


def pixel_difference(a: Path, b: Path) -> tuple[int, int]:
    """How many pixels differ between two captures, and the total. Pillow, like
    ``lit_fraction``: without it the comparison does not exist."""
    from PIL import Image, ImageChops  # only the capture needs Pillow

    with Image.open(a) as left, Image.open(b) as right:
        diff = ImageChops.difference(left.convert("L"), right.convert("L"))
        histogram = diff.histogram()
    total = sum(histogram)
    return total - histogram[0], total


ARROWS_READY = re.compile(r"^\[arrows\] ready (\d+)$")
#: The demo takes ~40 s to be ready (C2b) and the 7 pages stay 8 s each.
ARROWS_TIMEOUT_S = 180
#: The pages of ``watch/demo/setas/SetasStart.mc``: 5 of cards, the strip one and the icons one.
ARROWS_PAGES = 7
ARROWS_SMALL_PAGE = 5
ARROWS_ICON_PAGE = 6
#: Where ``watch/demo/setas/SetasStart.mc`` draws each symbol (the same computations as there):
#: the centers of the 7 cards of pages 0 to 4, the small arrow of type ``t`` on page 5,
#: the left corner of each status icon and the center of each back arrow (page 6).
ARROWS_BIG = ((127, 117), (227, 117), (327, 117), (127, 232), (227, 232), (327, 232), (227, 347))
ARROWS_ICONS = ("no phone", "weak GPS", "recalculating", "stopped")
ARROWS_BEARINGS = ("0°", "45°", "90°", "135°")
#: Two photos with fewer than this many differing pixels are the same page: the simulator
#: had not switched yet. Between real pages the difference goes past 10%. A choice, not a measurement.
ARROWS_SAME_MAX = 0.01


def arrows_small(t: int) -> tuple[int, int]:
    return 73 + (t % 8) * 44, 110 + (t // 8) * 44


def arrows_icon_left(i: int) -> int:
    # StatusIcons: SIZE 34, GAP 8; the row of 4 centered at 227.
    return 227 - (4 * 34 + 3 * 8) // 2 + i * (34 + 8)


def arrows_bearing(step: int) -> tuple[int, int]:
    return 92 + step * 90, 317


def arrows_differ(a: Path, b: Path) -> float:
    """Fraction of pixels that change from one photo to the other."""
    from PIL import Image, ImageChops

    one = Image.open(a).convert("RGB")
    two = Image.open(b).convert("RGB")
    diff = ImageChops.difference(one, two).convert("L").point(lambda v: 255 if v > 24 else 0)
    return diff.histogram()[255] / (one.size[0] * one.size[1])


def arrows_sheet(tiles: list, out: Path) -> None:
    """The sheet for Igor to point at: one row per maneuver type (number, name, the arrow of the
    top card and the one of the "and then" strip), and below the status icons (A–D) and the back
    arrow (E–H). All cropped from the photos and enlarged 2× without smoothing, pixel by pixel."""
    from PIL import Image, ImageDraw, ImageFont

    k = 2
    try:
        font = ImageFont.truetype("arial.ttf", 30)
        small = ImageFont.truetype("arial.ttf", 24)
    except OSError:
        font = small = ImageFont.load_default()

    def crop(page: int, box: tuple[int, int, int, int]):
        piece = tiles[page].crop(box)
        return piece.resize((piece.size[0] * k, piece.size[1] * k), Image.NEAREST)

    rows = (len(ARROWS_NAMES) + 2) // 3
    row_h, label_w, gap = 100 * k + 16, 500, 24
    col_w = label_w + 100 * k + gap + 44 * k + 40
    top = 70
    icons_top = top + rows * row_h + 30
    bearings_top = icons_top + 50 + 42 * k + 60
    sheet = Image.new("RGB", (3 * col_w + 20, bearings_top + 50 + 90 * k + 50), (24, 24, 24))
    draw = ImageDraw.Draw(sheet)
    draw.text((20, 18), "Watch arrows: point by number (maneuvers) or by letter (icons)",
              fill=(240, 240, 240), font=font)
    for t, name in enumerate(ARROWS_NAMES):
        x0 = 20 + (t // rows) * col_w
        y0 = top + (t % rows) * row_h
        cx, cy = ARROWS_BIG[t % 7]
        big = crop(t // 7, (cx - 50, cy - 50, cx + 50, cy + 50))
        sx, sy = arrows_small(t)
        little = crop(ARROWS_SMALL_PAGE, (sx - 22, sy - 22, sx + 22, sy + 22))
        draw.text((x0, y0 + row_h // 2 - 40), f"{t}", fill=(255, 200, 60), font=font)
        draw.text((x0 + 50, y0 + row_h // 2 - 40), name, fill=(235, 235, 235), font=font)
        draw.text((x0 + 50, y0 + row_h // 2), "card  ·  and then", fill=(140, 140, 140), font=small)
        sheet.paste(big, (x0 + label_w, y0))
        sheet.paste(little, (x0 + label_w + big.size[0] + gap, y0 + (big.size[1] - little.size[1]) // 2))

    draw.text((20, icons_top), "Status icons (above the time card)", fill=(235, 235, 235), font=font)
    draw.text((20, bearings_top), "Arrow back (on the top card, off route)", fill=(235, 235, 235), font=font)
    for i, name in enumerate(ARROWS_ICONS):
        left = arrows_icon_left(i)
        icon = crop(ARROWS_ICON_PAGE, (left - 4, 224, left + 38, 266))
        x = 20 + i * 300
        sheet.paste(icon, (x, icons_top + 50))
        draw.text((x, icons_top + 50 + icon.size[1] + 6), f"{'ABCD'[i]}  {name}", fill=(235, 235, 235), font=small)
    for step, bearing in enumerate(ARROWS_BEARINGS):
        bx, by = arrows_bearing(step)
        arrow = crop(ARROWS_ICON_PAGE, (bx - 45, by - 45, bx + 45, by + 45))
        x = 20 + step * 300
        sheet.paste(arrow, (x, bearings_top + 50))
        draw.text((x, bearings_top + 50 + arrow.size[1] + 6), f"{'EFGH'[step]}  {bearing}", fill=(235, 235, 235), font=small)
    sheet.save(out)
#: The maneuver types of ``05-PROTOCOL.md`` §Types, in the order of the number the sheet shows.
ARROWS_NAMES = ("depart", "straight", "slight right", "right", "sharp right", "u-turn",
                "sharp left", "left", "slight left", "roundabout", "enter the expressway",
                "leave the expressway", "arrive", "new name", "fork, left",
                "fork, right", "merge", "merge from the left", "merge from the right",
                "arrive left", "arrive right", "roundabout, sharp right exit",
                "roundabout, right exit", "roundabout, slight right exit", "roundabout, straight on",
                "roundabout, slight left exit", "roundabout, left exit", "roundabout, sharp left exit",
                "roundabout, u-turn", "enter the road, from the left", "leave the road, from the left")


def cmd_arrows() -> int:
    """The arrows sheet (C16.5) in the simulator: ``shots/setas_<page>.png`` (0 to 4: the maneuver
    types at card size; 5: the size of the "and then" strip; 6: the icons and the back arrow) and
    ``shots/folha_setas.png``, all side by side with each type's name. Exits 0 only with the
    photos above the lit-pixel floor, without Watchdog and with ``[arrows] end``."""
    resource = DEMO_FIXTURES["tiete_copan"]
    if not resource.exists():
        print('FAILED: no demo resource (./gradlew testDebugUnitTest --tests "*DemoFramesTest*")')
        return 1
    ensure_simulator()
    prg = BIN / "MotoNavSetas.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, ARROWS_JUNGLE], prg, unit_test=False):
        print("FAILED: the arrows sheet did not compile")
        return 1

    state: dict = {"pending": [], "taken": {}, "problems": []}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[arrows]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = ARROWS_READY.search(line)
        if ready:
            state["pending"].append((int(ready.group(1)), elapsed))

    def on_idle(elapsed: float) -> None:
        if not state["pending"] or elapsed - state["pending"][0][1] < 1.0:
            return
        page, _ = state["pending"].pop(0)
        png = SHOTS / f"setas_{page}.png"
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture of page {page} failed: {error}")
            return
        state["taken"][page] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken'][page]:.1%} lit")

    text, timed_out = run_live(prg, ARROWS_TIMEOUT_S, on_line, on_idle)
    log = save("setas.log", text)
    failures = list(state["problems"])
    for page in range(ARROWS_PAGES):
        lit = state["taken"].get(page)
        if lit is None:
            failures.append(f"no photo of page {page}")
        elif lit <= LIT_MIN:
            failures.append(f"page {page}: {lit:.1%} lit, floor {LIT_MIN:.0%}")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[arrows] end" not in text:
        failures.append("the sheet did not reach the end ([arrows] end missing)")
    if timed_out:
        failures.append(f"went past {ARROWS_TIMEOUT_S} s")
    if len(state["taken"]) == ARROWS_PAGES:
        for a, b in [(page, page + 1) for page in range(ARROWS_PAGES - 1)]:
            changed = arrows_differ(SHOTS / f"setas_{a}.png", SHOTS / f"setas_{b}.png")
            if changed < ARROWS_SAME_MAX:
                failures.append(f"the photos of pages {a} and {b} came out equal ({changed:.2%} difference): "
                                "the simulator had not switched page")

    if len(state["taken"]) == ARROWS_PAGES and not failures:
        from PIL import Image

        tiles = [Image.open(SHOTS / f"setas_{page}.png").convert("RGB") for page in range(ARROWS_PAGES)]
        arrows_sheet(tiles, SHOTS / "folha_setas.png")

    print()
    for page in sorted(state["taken"]):
        print(f"  shots/setas_{page}.png · {state['taken'][page]:.1%} lit")
    if len(state["taken"]) == ARROWS_PAGES and not failures:
        print("  shots/folha_setas.png")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# shots --trace
# --------------------------------------------------------------------------- #

TRACE_READY = re.compile(r"^\[trace\] ready (\d+)$")
#: The demo takes ~40 s to be ready and each page stays 8 s: 3 pages fit in 120 s.
TRACE_TIMEOUT_S = 150
TRACE_PAGES = 3
#: The ruler's widths, in the order of the rows of ``TracoStart.mc`` (y = 90 + 50k).
TRACE_WIDTHS = (7, 9, 11, 12, 14, 18)


def trace_ruler(png: Path) -> list[str]:
    """Measures the ruler: how many pixels each line and each disc light, in coverage (sum of luma
    / 255, which counts antialiasing by fraction). It is what decides each width's disc radius."""
    from PIL import Image

    img = Image.open(png).convert("L")
    out = []

    def column(x: int, y: int) -> float:
        return sum(img.getpixel((x, yy)) for yy in range(y - 15, y + 16)) / 255

    def row(xc: int, y: int) -> float:
        return sum(img.getpixel((xx, y)) for xx in range(xc - 15, xc + 16)) / 255

    for k, w in enumerate(TRACE_WIDTHS):
        y = 90 + 50 * k
        out.append(f"width {w:2}: line at whole y {column(120, y):5.2f} px · y+0.5 {column(240, y):5.2f} px · "
                   f"disc r={w // 2} {row(330, y):5.2f}x{column(330, y):5.2f} · "
                   f"disc r={(w - 1) // 2} {row(380, y):5.2f}x{column(380, y):5.2f}")
    return out


def trace_compare(png: Path, out: Path, title: str) -> None:
    """The page's two halves (before on the left, after on the right) enlarged 2x, side by side."""
    from PIL import Image, ImageDraw

    img = Image.open(png).convert("RGB")
    left = img.crop((0, 40, 227, 414)).resize((454, 748), Image.NEAREST)
    right = img.crop((227, 40, 454, 414)).resize((454, 748), Image.NEAREST)
    sheet = Image.new("RGB", (454 * 2 + 12, 748 + 40), (40, 40, 40))
    sheet.paste(left, (0, 40))
    sheet.paste(right, (454 + 12, 40))
    d = ImageDraw.Draw(sheet)
    d.text((10, 12), f"{title}: before", fill=(230, 230, 230))
    d.text((454 + 22, 12), f"{title}: after", fill=(230, 230, 230))
    sheet.save(out)


def cmd_trace() -> int:
    """The stroke bench (C16.5) in the simulator: ``shots/traco_<page>.png``, the ruler measured in the
    terminal, and ``shots/traco_rota.png`` and ``shots/traco_ruas.png`` with the before and after
    enlarged. Exits 0 only with the 3 photos, without Watchdog and with ``[trace] end``."""
    resource = DEMO_FIXTURES["tiete_copan"]
    if not resource.exists():
        print('FAILED: no demo resource (./gradlew testDebugUnitTest --tests "*DemoFramesTest*")')
        return 1
    ensure_simulator()
    prg = BIN / "MotoNavTraco.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, TRACE_JUNGLE], prg, unit_test=False):
        print("FAILED: the stroke bench did not compile")
        return 1

    state: dict = {"pending": [], "taken": {}, "problems": []}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[trace]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = TRACE_READY.search(line)
        if ready:
            state["pending"].append((int(ready.group(1)), elapsed))

    def on_idle(elapsed: float) -> None:
        if not state["pending"] or elapsed - state["pending"][0][1] < 1.0:
            return
        page, _ = state["pending"].pop(0)
        png = SHOTS / f"traco_{page}.png"
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture of page {page} failed: {error}")
            return
        state["taken"][page] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken'][page]:.1%} lit")

    text, timed_out = run_live(prg, TRACE_TIMEOUT_S, on_line, on_idle)
    log = save("traco.log", text)
    failures = list(state["problems"])
    for page in range(TRACE_PAGES):
        if page not in state["taken"]:
            failures.append(f"no photo of page {page}")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[trace] end" not in text:
        failures.append("the bench did not reach the end ([trace] end missing)")
    if timed_out:
        failures.append(f"went past {TRACE_TIMEOUT_S} s")
    if len(state["taken"]) == TRACE_PAGES:
        for a, b in ((0, 1), (1, 2)):
            if arrows_differ(SHOTS / f"traco_{a}.png", SHOTS / f"traco_{b}.png") < ARROWS_SAME_MAX:
                failures.append(f"the photos of pages {a} and {b} came out equal: the simulator did not switch page")

    print()
    if 0 in state["taken"]:
        for line in trace_ruler(SHOTS / "traco_0.png"):
            print("  " + line)
    if 1 in state["taken"]:
        trace_compare(SHOTS / "traco_1.png", SHOTS / "traco_rota.png", "route")
        print("  shots/traco_rota.png")
    if 2 in state["taken"]:
        trace_compare(SHOTS / "traco_2.png", SHOTS / "traco_ruas.png", "streets")
        print("  shots/traco_ruas.png")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


def cmd_burnin() -> int:
    """The anti burn-in orbit (C10) in the simulator: ``shots/burnin_a.png`` and
    ``shots/burnin_b.png``, the HUD at two opposite points of the ring. Exits 0 only with the
    two photos above the lit-pixel floor, **different from each other**, the full
    street-name cut sweep, without Watchdog and with ``[burnin] end``. The
    amplitude the sweep points to (the largest with no new cut) is printed: it is the
    number that goes into ``Config.mc`` and ``DECISIONS.md``."""
    resource = DEMO_FIXTURES["tiete_copan"]
    if not resource.exists():
        print('FAILED: no demo resource (./gradlew testDebugUnitTest --tests "*DemoFramesTest*")')
        return 1
    ensure_simulator()
    prg = BIN / "MotoNavBurnIn.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, BURNIN_JUNGLE], prg, unit_test=False):
        print("FAILED: the orbit did not compile")
        return 1

    state: dict = {"pending": [], "taken": {}, "problems": [], "cuts": {}, "ready": {}}

    def on_line(line: str, elapsed: float) -> None:
        if line.startswith("[burnin]") or "Watchdog" in line or line.startswith("Error"):
            print(f"{elapsed:6.1f}s {line}")
        ready = BURNIN_READY.search(line)
        if ready:
            state["pending"].append((ready.group(1), elapsed))
            state["ready"][ready.group(1)] = tuple(int(g) for g in ready.groups()[1:])
        cut = BURNIN_CUT.search(line)
        if cut:
            amp, cut_n, total, budget, widest = (int(g) for g in cut.groups())
            state["cuts"][amp] = (cut_n, total, budget, widest)

    def on_idle(elapsed: float) -> None:
        if not state["pending"] or elapsed - state["pending"][0][1] < SHOT_SETTLE_S:
            return
        name, _ = state["pending"].pop(0)
        png = SHOTS / f"burnin_{name}.png"
        error = take_shot(png)
        if error:
            state["problems"].append(f"capture of {name} failed: {error}")
            return
        state["taken"][name] = lit_fraction(png)
        print(f"{elapsed:6.1f}s capture {png.name}: {state['taken'][name]:.1%} lit")

    text, timed_out = run_live(prg, BURNIN_TIMEOUT_S, on_line, on_idle)
    log = save("burnin.log", text)
    failures = list(state["problems"])
    for name in ("a", "b"):
        lit = state["taken"].get(name)
        if lit is None:
            failures.append(f"no photo of point {name}")
        elif lit <= LIT_MIN:
            failures.append(f"point {name}: {lit:.1%} lit, floor {LIT_MIN:.0%}")

    differ = None
    if "a" in state["taken"] and "b" in state["taken"]:
        differ, total = pixel_difference(SHOTS / "burnin_a.png", SHOTS / "burnin_b.png")
        if differ == 0:
            failures.append("burnin_a and burnin_b are identical: the orbit did not move the HUD")
    if len(state["cuts"]) < 2:
        failures.append("the street-name cut sweep did not come out ([burnin] cut missing)")
    if "Watchdog Tripped" in text:
        failures.append("Watchdog Tripped")
    if "[burnin] end" not in text:
        failures.append("the orbit did not reach the end ([burnin] end missing)")
    if timed_out:
        failures.append(f"went past {BURNIN_TIMEOUT_S} s")

    print()
    for name in ("a", "b"):
        if name in state["taken"]:
            print(f"  shots/burnin_{name}.png · {state['taken'][name]:.1%} lit · point/dx/dy/amp "
                  f"{state['ready'].get(name)}")
    if differ is not None:
        print(f"  a and b differ in {differ} pixels")
    if state["cuts"]:
        base = state["cuts"].get(0)
        # The largest continuous amplitude since 0 without an extra name cut.
        best = 0
        for amp in sorted(state["cuts"]):
            if base and state["cuts"][amp][0] == base[0]:
                best = amp
            else:
                break
        for amp, (cut_n, total, budget, widest) in sorted(state["cuts"].items()):
            print(f"  amplitude {amp:2d} px: {cut_n} of {total} names cut (budget {budget} px, "
                  f"widest name {widest} px)")
        print(f"  largest amplitude with no new cut: {best} px (base cut: {base[0] if base else '?'})")
    for failure in failures:
        print(f"  FAILED: {failure}")
    print(f"\n{'ok' if not failures else 'FAILED'} · log {log.relative_to(ROOT)}")
    return 1 if failures else 0


# --------------------------------------------------------------------------- #
# ride --track
# --------------------------------------------------------------------------- #

TRACK_START = re.compile(r"^\[track\] start (\d+) fixes route (\d+) pts (\d+) maneuvers ([\d.]+) m")
TRACK_END = re.compile(r"^\[track\] end (.+) in (\d+) fixes")
TRACK_RECORDER = re.compile(r"^\[track\] recorder (\d+) lost (\d+)")
NO_FIX_LINE = re.compile(r"no fix for (\d+)s")
FIX_BACK_LINE = re.compile(r"fix back after (\d+)s")

#: Accepted difference between the hole the track has and the duration the watch
#: logged on the fix's return, in seconds: the log has whole seconds.
GAP_TOLERANCE_S = 1


def write_track_inputs(fixes: list[list[int]], period_ms: int) -> None:
    """The track becomes a watch resource (``Rez.JsonData.TrackFixes``) and the period
    becomes code: the watch does not read files. Flattened vector ``[t, lat, lon, v, h, ...]``
    inside a dictionary, because it is a flat Array of Numbers and not an Array
    of Arrays (1,700 small arrays cost more heap than the 8,500 numbers)."""
    resources = TRACK_DIR / "resources"
    resources.mkdir(parents=True, exist_ok=True)
    flat = [value for fix in fixes for value in fix]
    (resources / "track.json").write_text(json.dumps({"f": flat}, separators=(",", ":")), encoding="utf-8")
    (resources / "track.xml").write_text(
        '<resources>\n    <jsonData id="TrackFixes" filename="track.json" />\n</resources>\n', encoding="utf-8")
    (TRACK_DIR / "TrackParams.mc").write_text(
        "// GENERATED by tools/sim.py ride --track on every run, do not edit.\n"
        "import Toybox.Lang;\n\n"
        "module TrackParams {\n\n"
        f"    const PERIOD_MS = {period_ms};\n"
        "}\n",
        encoding="utf-8")


def judge_track(text: str, track: dict, spec: dict, timed_out: bool,
                ceiling: int = WORK_CEILING) -> tuple[int, list[str]]:
    lines = text.splitlines()
    fixes = track["fixes"]
    report: list[str] = []
    failures: list[str] = []

    # Is the watch's route the track's?
    start = next((TRACK_START.search(l) for l in lines if TRACK_START.search(l)), None)
    route_spec = spec["route"]
    if start is None:
        failures.append("the track did not start ([track] start missing)")
    else:
        count, pts, turns, metres = int(start.group(1)), int(start.group(2)), int(start.group(3)), float(start.group(4))
        if count != len(fixes):
            failures.append(f"the watch read {count} fixes, the track has {len(fixes)}")
        if (pts, turns) != (route_spec["points"], route_spec["maneuvers"]) or abs(metres - route_spec["meters"]) > ROUTE_TOLERANCE_M:
            failures.append(f"watch route {pts} pts/{turns} maneuvers/{metres} m, "
                            f"expected {route_spec['points']}/{route_spec['maneuvers']}/{route_spec['meters']}")
        report.append(f"track: {count} fixes, noise {spec.get('noise_m', '?')} m, route {pts} pts/{turns} maneuvers")

    # How many fixes arrived and how the lap ended.
    end = next((TRACK_END.search(l) for l in lines if TRACK_END.search(l)), None)
    delivered = int(end.group(2)) if end else 0
    if end is None or end.group(1) != "arrival":
        failures.append(f"the track ended by '{end.group(1) if end else 'nothing'}', expected 'arrival'")
    if delivered < spec["delivered_min"]:
        failures.append(f"{delivered} fixes delivered, the floor is {spec['delivered_min']}")
    report.append(f"fixes delivered {delivered} of {len(fixes)}")

    # The route holds despite the noise: a single arrival, alerts in order, at most two per maneuver.
    arrivals, arrival_vibes, after_arrival, order, per_turn = [], 0, [], [], {}
    for line in lines:
        alert = ALERT_LINE.search(line)
        if alert:
            turn = int(alert.group(1))
            if arrivals:
                after_arrival.append(turn)
            order.append(turn)
            per_turn[turn] = per_turn.get(turn, 0) + 1
        arrived = ARRIVED_LINE.search(line)
        if arrived:
            arrivals.append(int(arrived.group(1)))
        if "vibe arrival" in line:
            arrival_vibes += 1
    route_problems = []
    if len(arrivals) != 1:
        route_problems.append(f"{len(arrivals)} arrivals in the log, expected 1")
    elif arrivals[0] > spec["arrival"]["up_to_m"]:
        route_problems.append(f"arrived {arrivals[0]} m from the end, the ceiling is {spec['arrival']['up_to_m']}")
    if arrival_vibes != 1:
        route_problems.append(f"{arrival_vibes} arrival vibrations, expected 1")
    if after_arrival:
        route_problems.append(f"turn alert after the arrival: maneuvers {after_arrival}")
    too_many = {t: n for t, n in per_turn.items() if n > 2}
    if too_many:
        route_problems.append(f"more than 2 alerts on the same maneuver: {too_many}")
    backwards = [(a, b) for a, b in zip(order, order[1:]) if b < a]
    if backwards:
        route_problems.append(f"the match went back to an earlier maneuver: {backwards[:3]}")
    if route_problems:
        failures.append("route not held: " + "; ".join(route_problems))
        report.append("FAIL route not held: " + "; ".join(route_problems))
    else:
        report.append(f"route held: 1 arrival at {arrivals[0]} m, {len(order)} alerts in "
                      f"{len(per_turn)} maneuvers, no step back")

    # The holes: each one logged in the middle (`no fix for`) and on the return (`fix back after`).
    holes = trilha_tool.holes(fixes[:delivered])
    silent = [int(m.group(1)) for l in lines for m in [NO_FIX_LINE.search(l)] if m]
    back = [int(m.group(1)) for l in lines for m in [FIX_BACK_LINE.search(l)] if m]
    gap_problems = []
    if len(silent) != len(holes) or len(back) != len(holes):
        gap_problems.append(f"{len(holes)} hole(s) in the track, {len(silent)} 'no fix' and {len(back)} 'fix back' in the log")
    else:
        for hole, quiet, returned in zip(holes, silent, back):
            if not (trilha_tool.GAP_THRESHOLD_S <= quiet <= hole["silence_s"]):
                gap_problems.append(f"'no fix' at {quiet}s, expected {trilha_tool.GAP_THRESHOLD_S}–{hole['silence_s']}")
            if abs(returned - hole["silence_s"]) > GAP_TOLERANCE_S:
                gap_problems.append(f"'fix back' with {returned}s, the hole is {hole['silence_s']}s")
    if gap_problems:
        failures.append("hole: " + "; ".join(gap_problems))
        report.append("FAIL hole: " + "; ".join(gap_problems))
    else:
        report.append("hole: " + ", ".join(
            f"{h['silence_s']} s after {h['after_s']} s, logged as 'no fix for {q}s' and 'fix back after {b}s'"
            for h, q, b in zip(holes, silent, back)))

    # The recorder: the count is the rule's (1 fix every 5 s) over what was delivered.
    recorder = next((TRACK_RECORDER.search(l) for l in lines if TRACK_RECORDER.search(l)), None)
    want = trilha_tool.recorded(fixes[:delivered])
    if recorder is None:
        failures.append("recorder: no [track] recorder line")
        report.append("FAIL recorder: no line")
    else:
        got, lost = int(recorder.group(1)), int(recorder.group(2))
        recorder_problems = []
        if got != want:
            recorder_problems.append(f"recorded {got}, the rule gives {want}")
        if lost:
            recorder_problems.append(f"lost {lost}")
        if recorder_problems:
            failures.append("recorder: " + "; ".join(recorder_problems))
            report.append("FAIL recorder: " + "; ".join(recorder_problems))
        else:
            report.append(f"recorder: {got} fixes (the rule gives {want}), {lost} lost")

    peaks = [int(p) for p in WORK_PEAK.findall(text)]
    tripped = "Watchdog Tripped" in text
    report.append(f"work peak {max(peaks) if peaks else '-'} (ceiling {ceiling}, {len(peaks)} samples)")
    if timed_out:
        failures.append("the track went past the deadline")
    if tripped:
        failures.append("Watchdog Tripped")
    if not peaks:
        failures.append("no frameSummary with work peak")
    elif max(peaks) >= ceiling:
        failures.append(f"work peak {max(peaks)} >= {ceiling}")
    return (1 if failures else 0), report + [f"FAILED: {f}" for f in failures]


def cmd_track(track_path: Path, speed: float, ceiling: int = WORK_CEILING) -> int:
    expected_path = track_path.with_name(track_path.stem + ".esperado.json")
    if not track_path.exists() or not expected_path.exists():
        print(f"FAILED: need {track_path} and {expected_path.name} "
              "(python tools/trilha.py generate --fixture tiete_copan)")
        return 1
    track = json.loads(track_path.read_text(encoding="utf-8"))
    spec = json.loads(expected_path.read_text(encoding="utf-8"))
    resource = DEMO_FIXTURES.get(track["fixture"])
    if resource is None or not resource.exists():
        print(f"FAILED: the track's fixture '{track['fixture']}' has no demo resource")
        return 1
    period_ms = round(1000 / speed)
    if period_ms < MIN_PERIOD_MS:
        print(f"FAILED: --speed {speed} gives {period_ms} ms between fixes, the minimum is {MIN_PERIOD_MS}")
        return 1

    write_track_inputs(track["fixes"], period_ms)
    ensure_simulator()
    prg = BIN / "MotoNavTrack.prg"
    BIN.mkdir(parents=True, exist_ok=True)
    if not compile_prg([JUNGLE, TRACK_JUNGLE], prg, unit_test=False):
        print("FAILED: the track did not compile")
        return 1

    seconds = track["fixes"][-1][0] - track["fixes"][0][0] + 1
    timeout_s = int((seconds * period_ms / 1000 + RIDE_LOAD_S) * 1.5)
    print(f"track of {len(track['fixes'])} fixes in {seconds} s every {period_ms} ms (deadline {timeout_s} s)")

    def on_line(line: str, elapsed: float) -> None:
        if (line.startswith("[track]") or "vibe " in line or "arrived at destination" in line
                or "no fix" in line or "fix back" in line or "trail " in line
                or "Watchdog" in line or line.startswith("Error")):
            print(f"{elapsed:6.1f}s {line}")

    text, timed_out = run_live(prg, timeout_s, on_line, lambda _elapsed: None)
    log = save(f"track_{track_path.stem}.log", text)
    code, report = judge_track(text, track, spec, timed_out, ceiling)
    print()
    for line in report:
        print(f"  {line}")
    print(f"\n{'ok' if code == 0 else 'FAILED'} · log {log.relative_to(ROOT)}")
    return code


# --------------------------------------------------------------------------- #
# all
# --------------------------------------------------------------------------- #

DEBUG_ENTRY = re.compile(r'<entry filename="([^"]+)"[^>]*lineNum="(\d+)"[^>]*symbol="([^"]*)"')


def annotated_range(source: Path, annotation: str) -> range:
    """Lines of the function right below ``(:annotation)``, up to its ``}``."""
    lines = source.read_text(encoding="utf-8").splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip() == f"(:{annotation})")
    indent = len(lines[start]) - len(lines[start].lstrip())
    end = next(i for i in range(start + 2, len(lines))
               if lines[i].strip() == "}" and len(lines[i]) - len(lines[i].lstrip()) == indent)
    return range(start + 1, end + 2)  # monkeyc's lineNum starts at 1


def check_release(debug_xml: Path) -> list[str]:
    """What the demo build and the demo canary add must not be in the
    release. The ``.prg.debug.xml`` says which file and line each
    instruction came from; any text will not do, because the documentation of
    ``DemoHook.mc`` cites ``DemoFeed`` and would give a false positive."""
    assembler = ROOT / "watch" / "source" / "comm" / "MessageAssembler.mc"
    quadratic = annotated_range(assembler, "quadratic_parse")
    linear = annotated_range(assembler, "linear_parse")
    policy = ROOT / "watch" / "source" / "nav" / "AlertPolicy.mc"
    no_near = annotated_range(policy, "no_near_alert")
    near = annotated_range(policy, "near_alert")
    hud = ROOT / "watch" / "source" / "render" / "Hud.mc"
    hud_canary = annotated_range(hud, "canary")
    hud_real = annotated_range(hud, "no_canary")
    demo_hits, quad_hits, linear_hits, no_near_hits, near_hits = set(), 0, 0, 0, 0
    replay_hits = 0
    hud_canary_hits, hud_real_hits = 0, 0
    for filename, line, symbol in DEBUG_ENTRY.findall(debug_xml.read_text(encoding="utf-8")):
        # Forward slash on both systems: Windows' `debug.xml` carries `\\`, macOS's `/`
        # (on macOS, with a fixed `\\`, the check went blind).
        path = filename.replace("\\\\", "/").replace("\\", "/").lower()
        # `watch\demo\` covers the demo and the lap; `watch\bin\ride\` is the
        # `RideParams.mc` that `sim.py ride` generates.
        if ("/watch/demo/" in path or "/watch/ponte/" in path or "/watch/bin/ride/" in path
                or "/watch/bin/track/" in path or "/watch/bin/shots/" in path
                or "/watch/bin/config/" in path or "DemoFeed" in symbol):
            demo_hits.add(symbol)
        elif path.endswith("/nav/replaysource.mc"):
            # Since C3b ReplaySource belongs to the real app: it is the "Simulate
            # ride" of the menu. If it vanishes from the release, the menu does not work.
            replay_hits += 1
        elif path.endswith("/comm/messageassembler.mc") and "parseCorridor" in symbol:
            if int(line) in quadratic:
                quad_hits += 1
            elif int(line) in linear:
                linear_hits += 1
        elif path.endswith("/render/hud.mc") and "distancePx" in symbol:
            if int(line) in hud_canary:
                hud_canary_hits += 1
            elif int(line) in hud_real:
                hud_real_hits += 1
        elif path.endswith("/nav/alertpolicy.mc") and "nearAlertOn" in symbol:
            if int(line) in no_near:
                no_near_hits += 1
            elif int(line) in near:
                near_hits += 1
    problems = []
    if demo_hits:
        problems.append("demo, lap or bridge code in the release: " + ", ".join(sorted(demo_hits)))
    if no_near_hits:
        problems.append(f"the AlertPolicy with no 2nd alert (the lap canary) is in the release ({no_near_hits} instructions)")
    if hud_canary_hits:
        problems.append(f"the RNF-05 canary Hud (distance at 54 px) is in the release ({hud_canary_hits} instructions)")
    if not hud_real_hits:
        problems.append("the real Hud distancePx does not show up in the release: the check is blind")
    if not replay_hits:
        problems.append("ReplaySource does not show up in the release: \"Simulate ride\" is gone or the check is blind")
    if not near_hits:
        problems.append("the real nearAlertOn does not show up in the map: the check is blind")
    if quad_hits:
        problems.append(f"the quadratic parseCorridor is in the release ({quad_hits} instructions)")
    if not linear_hits:
        # If not even the linear one shows up, the check is not seeing anything.
        problems.append("the linear parseCorridor does not show up in the map: the check is blind")
    # C16.5: with the `Fit` permission (C9's "Screen on (record)") the watch put the app in the activities
    # list, and not the apps one (C16 bench, 2026-10-15). The manifest is the release's.
    manifest = (ROOT / "watch" / "manifest.xml").read_text(encoding="utf-8")
    if re.search(r'<iq:uses-permission\s+id="Fit"', manifest):
        problems.append("the Fit permission is back in the manifest: the app leaves the watch's apps list")
    return problems


#: The ``all`` stamp: ``tools/sideload.ps1`` only copies the ``.prg`` whose hash
#: is here. It lives in ``watch/bin`` (outside git), so it holds only for this machine.
STAMP = BIN / "tudo.carimbo"


def write_stamp() -> Path:
    prg = BIN / f"MotoNav-{app_version()}.prg"
    STAMP.write_text(json.dumps({
        "prg": prg.name,
        "sha256": hashlib.sha256(prg.read_bytes()).hexdigest(),
        "versao": app_version(),
        "quando": time.strftime("%Y-%m-%d %H:%M:%S"),
    }, indent=2) + "\n", encoding="utf-8")
    return STAMP


def cmd_all() -> int:
    """Tests, debug build and release build: what must be green before
    any ``.prg`` goes to the watch (``CLAUDE.md`` rule). Green writes the
    stamp that ``sideload.ps1`` requires; a new run erases the previous one."""
    STAMP.unlink(missing_ok=True)
    # The two languages (C16.8a) before anything: it is instant, and an id missing from a catalog
    # compiles, but shows English on the Portuguese watch.
    languages = Path(__file__).resolve().parent / "idioma.py"
    steps: list[tuple[str, int]] = [("languages", subprocess.run([sys.executable, str(languages)]).returncode)]
    if steps[-1][1] == 0:
        steps.append(("tests", cmd_test(canary=False)))
    build = Path(__file__).resolve().parent / "build_watch.py"
    for label, extra in (("debug build", []), ("release build", ["--release"])):
        if steps[-1][1] != 0:
            break
        steps.append((label, subprocess.run([sys.executable, str(build), *extra]).returncode))

    if steps[-1] == ("release build", 0):
        debug_xml = BIN / f"MotoNav-{app_version()}.prg.debug.xml"
        problems = check_release(debug_xml) if debug_xml.exists() else [f"{debug_xml.name} does not exist"]
        for problem in problems:
            print(f"  release: {problem}")
        print(f"checked: ReplaySource present; no DemoFeed, lap, track, quadratic parse or 2nd-alert canary: {debug_xml}"
              if not problems else "")
        steps.append(("release without demo or sabotage", 1 if problems else 0))

    print()
    for label, code in steps:
        print(f"  {'ok    ' if code == 0 else 'FAILED'} {label}")
    ok = len(steps) == 5 and all(code == 0 for _, code in steps)
    print(f"\nsim.py all: {'GREEN' if ok else 'RED'} · MotoNav {app_version()}")
    if ok:
        print(f"stamp: {write_stamp().relative_to(ROOT)}")
    return 0 if ok else 1


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        # line_buffering: without it, the subprocesses' output (monkeyc, build_watch)
        # shows up before ours and `all` comes out of order.
        sys.stdout.reconfigure(encoding="utf-8", errors="replace", line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--language", "--idioma", dest="language", choices=sorted(SIM_LANGUAGES), default="por",
                        help="the watch language in the simulator (C16.8a); comes before the command")
    sub = parser.add_subparsers(dest="command", required=True)
    test = sub.add_parser("test", help="unit tests in the simulator")
    test.add_argument("--canary", action="store_true", help="turns on the test that fails on purpose")
    sub.add_parser("watchdog", help="the probe: does the simulator apply the watchdog?")
    sub.add_parser("all", aliases=["tudo"], help="tests + debug build + release build")
    demo = sub.add_parser("demo", help="the app with SP's real route and corridor")
    demo.add_argument("--fixture", required=True, help="only tiete_copan for now")
    demo.add_argument("--canary", action="store_true", help="quadratic parse: MUST die")
    demo.add_argument("--config", action="append", metavar="KEY=VALUE",
                      help="injects the CONFIG (C5) before the route, e.g. lead_s=10; repeatable or comma-separated")
    demo.add_argument("--reopen", "--reabrir", dest="reopen", action="store_true",
                      help="with --config: relaunches the app without CONFIG and requires the setting restored from Storage")
    demo.add_argument("--long-route", "--rota-longa", dest="long_route", type=int, metavar="POINTS",
                      help="injects before SP a synthetic route with this POLY (up to 4000) and requires it to go in")
    ride = sub.add_parser("ride", help="the virtual lap: the whole route, alert by alert")
    ride.add_argument("--fixture", help="only tiete_copan for now (required without --track)")
    ride.add_argument("--track", type=Path, default=None,
                      help="replays a recorded track (tools/fixtures/trilha_ruidosa.json) instead of the lap")
    ride.add_argument("--speed", type=float, default=4.0,
                      help="fixes per second of watch time (each fix is worth 1 s of bike)")
    ride.add_argument("--canary", action="store_true", help="without the 2nd alert: MUST fail")
    ride.add_argument("--detour", "--desvio", dest="detour", type=int, default=None, metavar="N",
                      help="C11: the bike leaves the route for 32 s on a straight (N=1 only; the 3 with a reply are in e2e.py)")
    ride.add_argument("--no-phone", "--sem-celular", dest="no_phone", action="store_true",
                      help="with --detour: nobody answers the request (the simulator has no phone)")
    ride.add_argument("--no-cache", "--sem-cache", dest="no_cache", action="store_true",
                      help="the streets drawn on every frame, without the image (StreetCache), to compare")
    ride.add_argument("--work-ceiling", "--teto-work", dest="work_ceiling", type=int, default=WORK_CEILING,
                      help=f"ceiling of the work peak in work points (default {WORK_CEILING})")
    shots = sub.add_parser("shots", help="the 3 riding screens (C4) in shots/tela_*.png")
    shots.add_argument("--details", "--detalhes", dest="details", action="store_true",
                       help="only the Details screen (C9): shots/detalhes.png")
    shots.add_argument("--home", "--inicio", dest="home", action="store_true",
                       help="only the home screen (sheet 1): shots/inicio_*.png and shots/folha_inicio.png")
    shots.add_argument("--burnin", action="store_true",
                       help="only the anti burn-in orbit (C10): shots/burnin_a.png and burnin_b.png")
    shots.add_argument("--arrows", "--setas", dest="arrows", action="store_true",
                       help="only the arrows sheet (C16.5): shots/setas_*.png and shots/folha_setas.png")
    shots.add_argument("--trace", "--traco", dest="trace", action="store_true",
                       help="only the stroke bench (C16.5): shots/traco_rota.png and shots/traco_ruas.png")
    shots.add_argument("--config", action="append", metavar="KEY=VALUE", default=[],
                       help="setting put in Config before the scenes (C16.5), e.g.: text_pct=63")
    shots.add_argument("--tag", default="", help="with --config: photo suffix, shots/tela_<scene>_<tag>.png")
    shots.add_argument("--showcase", "--vitrine", dest="showcase", action="store_true",
                       help="only the public README and post photos, in central SP: shots/tela_vitrine_*.png")
    shots.add_argument("--sheet4", "--folha4", dest="sheet4", action="store_true",
                       help="plus the sheet 4 scenes: the destination, the rider states and the route without an edge")
    shot = sub.add_parser("shot", help="captures the simulator screen and measures the %% lit")
    shot.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    global LANGUAGE
    LANGUAGE = args.language

    if args.command == "test":
        return cmd_test(args.canary)
    if args.command == "watchdog":
        return cmd_watchdog()
    if args.command == "demo":
        return cmd_demo(args.fixture, args.canary, args.config, args.reopen, args.long_route)
    if args.command == "ride":
        if args.track is not None:
            if args.canary:
                parser.error("--track has no canary; the lap's canary is --fixture ... --canary")
            return cmd_track(args.track, args.speed, args.work_ceiling)
        if args.fixture is None:
            parser.error("ride needs --fixture or --track")
        return cmd_ride(args.fixture, args.speed, args.canary, args.work_ceiling,
                        args.detour, args.no_phone, not args.no_cache)
    if args.command == "shot":
        return cmd_shot(args.out)
    if args.command == "shots":
        if args.home:
            return cmd_home()
        if args.burnin:
            return cmd_burnin()
        if args.arrows:
            return cmd_arrows()
        if args.trace:
            return cmd_trace()
        if args.config and not args.tag:
            sys.exit("--config needs --tag: without it the photos overwrite the default-size ones")
        return (cmd_details() if args.details
                else cmd_shots(parse_config(args.config), args.tag, args.sheet4, args.showcase))
    return cmd_all()


if __name__ == "__main__":
    raise SystemExit(main())
