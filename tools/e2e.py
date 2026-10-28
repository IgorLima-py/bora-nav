#!/usr/bin/env python3
"""The whole path on the PC: from the Maps link to the map drawn in the simulator (C7b).

Why this script exists
----------------------
C7a proved half of the bridge (``tools/ponte.py``): the companion, in the ``pato37`` emulator,
talks to the watch app in the simulator through ``TETHERED``; the return leg does not work,
because ``Communications.transmit`` freezes the SDK 9.2.0 simulator (CIQQA-4579), and it now goes
**through a relay** (``PONTE:TX:`` on the console, delivered by ``adb``). This script uses the
half bridge to run the real path, with no watch or phone: a Maps link share becomes a Mapbox
route and an Overpass corridor, crosses the bridge and draws the map.

What it does, in order:

1. brings up ``pato37``, installs the ``sim`` variant and opens the companion (all from
   ``ponte.py``, reused), grants location, puts the emulator at the origin
   (``adb emu geo fix``) and hands the Mapbox token to the ``TokenReceiver``
   (read from ``.secrets/`` now; never printed, never in git, never in the APK);
2. compiles the bridge build (``monkey.jungle;ponte.jungle`` — plain debug freezes on the
   first ACK), opens it in the simulator and presses **adb Connection > Start**;
3. sends the C7a probe until the watch prints ``PONTE:C2R:<id>``: that is the sign the
   outbound leg is alive;
4. shares a Maps link of a public place through ``am start -n``, taps the filled button (**Bora** / **Let's go**) on the
   companion's confirmation screen (C8, ``uiautomator``) and, from then on, hands the
   companion each ``PONTE:TX:`` from the console (each block's ACK comes back that way) and
   reads the companion's ``motonav.log`` every 2 s;
5. checks the two logs and the simulator photo.

Exit codes (``docs/ROADMAP.md`` §3, conventions):

* ``0`` — complete route and all the corridor LODs in the simulator, map on screen;
* ``1`` — our failure (anything else);
* ``2`` — external API down (Mapbox or Overpass), read from the companion's log;
* ``3`` — known bug reproduced: with ``--double``, the first share
  arrived and the second did not (``docs/STATUS.md`` §OPEN ISSUES).

The options have English names; the old Portuguese ones (``--dupla``, ``--telas``, ``--desvio``,
``--favorito``, ``--queda``, ``--sem-fix``, ``--estresse``, ``--primeiro-uso``) still work as aliases.
The apps' log is read in both languages (``tools/logphrases.py``): a log from before v1.4.1 gives
the same result.

Usage::

    python tools/e2e.py
    python tools/e2e.py --double    # two shares in a row: 0 or 3
    python tools/e2e.py --canary    # no relay: MUST exit 1 (0 = the canary died)
    python tools/e2e.py --screens   # the phone's three screens, no simulator (C8)
    python tools/e2e.py --detour 3  # C11: three detours, three recalculations over the whole bridge
    python tools/e2e.py --doze      # C13a: 10 min of forced doze, the ROUTE_UPDATE must arrive
    python tools/e2e.py --doze 60   # one hour: 5 ROUTE_UPDATEs at pace, no restart
    python tools/e2e.py --drop      # C13b: the outbound leg drops for 15 s in the middle of a corridor block
    python tools/e2e.py --drop 45   # drops for 45 s: the watch sends the bitmap and only what is missing is resent

``--detour 3`` (C11) turns on the watch's virtual ride (``PONTE:CMD:SIM``) on a short route
(~5 km) and, **one command per detour** (``PONTE:CMD:DETOUR:60``), puts the motorcycle
60 m off the route. Each detour is only armed after the current route's corridor
settles: a corridor chunk in flight holds the link ~9 s and would blow the deadline.
The watch asks, the relay delivers the ``REROUTE_REQ`` to the companion, Mapbox recalculates,
the new route comes back over ``TETHERED`` and the watch logs ``route swapped A -> B in N ms``.
Exits 0 only with exactly 3 0x82 frames from the watch, 3 swaps, each ``N`` up to
10,000 ms, and the arrival without a 4th request; exits 1 saying which interval blew; 2 if
Mapbox or Overpass did not let the run fit.

``--doze [MIN]`` (C13a) sends the short ``--detour`` route, waits for the corridor to settle,
leaves the app (HOME), turns the screen off, unplugs the emulator (``dumpsys battery unplug``) and
forces doze (``dumpsys deviceidle force-idle``) for ``MIN`` minutes plus 60 s of slack, **without**
the battery exemption. The console relay stays on the whole time. Every 30 s it reads the doze
state, the service (``isForeground``) and the wake lock. Exits 0 only with the ``eta route N`` lines
on the watch console **with a new Mapbox duration** (matched with the phone's ``delivered: A -> B s``;
the query that repeats the old duration does not count) falling between two ``IDLE`` samples
(1 in 10 min, 5 in 60), spaced
600 ± 60 s apart, the service in the foreground in every sample and the same pid from start to
end. Mapbox down **inside** the doze is 1, not 2: it is what the test measures. On exit, and at the
start of every run, doze is undone (``unforce``, ``battery reset``).

``--drop [S]`` (C13b) does the usual share and, when the first chunk of the corridor's
largest block is in flight, **drops the outbound leg** (``adb Connection > Release``
in the simulator; ``ponte.drop_link``) for ``S`` seconds (default 15) and reconnects (``Start``).
The chunk in flight still arrives and the next one is lost: the watch is left with a half block.
Exits 0 only with the whole route and corridor **and** the line ``block 0x04 complete after N
rounds`` of that block with N >= 2, a ``drop at chunk i/n`` round (i >= 2) before it, and each
LOD read only once on the watch. With ``S`` above 30 (the watch's block deadline)
it requires more: ``timeout 0x04`` on the watch, a round with the partial bitmap and the last
round with fewer chunks than the block. ``--drop --canary`` is the same round **without
dropping**: N = 1, must exit 1. On the PC only the outbound leg drops; the return is the console
relay, which stays up. On the radio both directions drop together, and that is C16.

``--no-fix S`` (C13b) sends the short ``--detour`` route, waits for the corridor to settle,
turns on the virtual ride and the ``PONTE:POS`` line (the motorcycle says where it is at every
step, and the e2e carries the emulator's GPS along with ``geo fix``), leaves the app (HOME), turns
the screen off and opens a **hole of ``S`` seconds** in the motorcycle's fixes
(``PONTE:CMD:NOFIX:S``): it keeps moving and no fix reaches the watch, as in a tunnel. Exits 0
only with the turn-on ``FIX_REQ`` (0x86) going through the relay inside the hole, the service in
the foreground with type ``location``, the screen actually off and the app out of it,
``phone fix: start`` on the watch within 15 s, **every** telemetry line from then until the
end of the hole saying ``on route`` and ``fix phone`` (at least one), no ``off route``, at least
``(S - 5) / 2`` ``PHONE_FIX sent`` on the phone **after** the hole starts and as many
**applied** on the watch, with no more than 5 s between two and the last within 3 s of the
end of the hole, at a median of up to 25 m from the motorcycle, each equal (position and heading)
to one the phone said it sent, and after
the hole the telemetry back to the build's own source (``replay`` on the PC; the literal ``gps``
is the hardware's, C16), the turn-off ``FIX_REQ`` and the ``PHONE_FIX off: the
watch dismissed it``. ``--no-fix S --canary`` stops the service before the hole: the
companion refuses the request (``PHONE_FIX unavailable``) and must exit 1; if the judge passes it
exits 0, and if the run fails for another reason the canary says ``inconclusive``.

``--double`` only exits 0 if the two shares have different ``routeId``s and
are under the **same process-start line** of ``motonav.log``
(``--- session <version> pid <N> ---``): that is the proof the second did not need
a new process. ``--screens`` does not bring up the simulator: it installs the APK, opens the
confirmation (``c9_confirm.png``), the search (``c9_search.png``) and the watch
settings (``c9_settings.png``) and photographs each with ``screencap``.

The APK comes from gradle, which **does not run alongside the simulator** (``CLAUDE.md``
§Bateria). Compile first::

    cd companion && ./gradlew assembleSim

Raw output in ``shots/e2e_watch.log``, ``shots/e2e_companion.log`` and
``shots/e2e_map.png`` (outside git). The real ``transmit`` is still
unproven on the PC: only on hardware (C16).
"""

from __future__ import annotations

import argparse
import base64
import binascii
import math
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from xml.etree import ElementTree

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ponte  # noqa: E402
import sim  # noqa: E402
from build_watch import JUNGLE, ROOT  # noqa: E402
from logphrases import to_english  # noqa: E402

PACKAGE = ponte.PACKAGE
SHARE_ACTIVITY = f"{PACKAGE}/dev.igor.motonav.share.ShareReceiverActivity"
TOKEN_RECEIVER = f"{PACKAGE}/dev.igor.motonav.sim.TokenReceiver"
TOKEN_ACTION = "dev.igor.motonav.sim.TOKEN"
COMPANION_LOG = f"/sdcard/Android/data/{PACKAGE}/files/motonav.log"

WATCH_LOG = "e2e_watch.log"
COMPANION_OUT = "e2e_companion.log"
MAP_SHOT = sim.SHOTS / "e2e_map.png"

#: The three screens of ``--screens``. The ``c9_`` prefix is what C8's ``verificar:``
#: asks for in ``docs/ROADMAP.md`` (the chat's old numbering).
SCREEN_SHOTS = {
    "confirm": sim.SHOTS / "c9_confirm.png",
    "search": sim.SHOTS / "c9_search.png",
    "settings": sim.SHOTS / "c9_settings.png",
    # C12: the name is what C12's `verificar:` asks for.
    "favorites": sim.SHOTS / "c12_favorites.png",
}
MAIN_ACTIVITY = f"{PACKAGE}/dev.igor.motonav.MainActivity"
#: ASCII on purpose: ``adb shell input text`` does not type accents.
SEARCH_QUERY = "Copan Sao Paulo"
UI_DUMP_PATH = "/sdcard/motonav_ui.xml"

#: Public places, from the repository fixtures — never Igor's address.
#: Origin and first destination are the ends of
#: ``tools/fixtures/route_tiete_copan.json`` (Parque Ecológico do Tietê → Edifício Copan, the
#: same route as ``sim.py demo``); the second destination is the one in
#: ``tools/fixtures/route_sample.json`` (Aeroporto de Congonhas).
ORIGIN = (-23.498327, -46.525715)
COPAN = ("Copan", -23.547538, -46.642686)
CONGONHAS = ("Congonhas", -23.628427, -46.657675)

#: How much the destination asked of Mapbox may differ from the link's, in degrees. The link
#: carries the coordinate with 6 decimals and ``LinkResolver`` reads it as is, so the
#: expected difference is zero; 1e-4 (~11 m) only absorbs formatting. A destination
#: coming from the geocoder (the wrong path) misses by far more than that.
DEST_TOLERANCE_DEG = 1e-4

#: Seconds between one read of the companion's ``motonav.log`` and the next.
LOG_EVERY_S = 2.0

#: The CONFIG the e2e sends before the share (C16.6, Igor's decision on 26/10): the street
#: image off. With it on, the simulator hangs in the middle of the corridor: job 961
#: after LOD 2, job 973 after LOD 1, no Watchdog, and the companion's ``force-stop``
#: does not unfreeze it (the next run found it hung). With ``street_img=0`` the same e2e
#: passed whole (job 974: 4 LODs and 13 radars). The e2e proves the phone → watch path; the
#: street image stays with ``sim.py demo``/``ride`` and the wrist. ``--config street_img=1``
#: turns it back on.
E2E_CONFIG = {"street_img": 0}

#: Wait after sending the CONFIG over the bridge (``--config``, C16.6). ``BridgeReceiver``
#: waits for the SDK up to 10 s (``SDK_READY_TIMEOUT_MS``) and the message is short (the SDK's
#: ``sendMessage`` sleeps ``len/600`` s, ``DECISIONS.md`` §C7a): 10 s covers the worst case.
CONFIG_SETTLE_S = 10.0

TOKEN_FILE = ROOT / ".secrets" / "mapbox_token.txt"

POLY_LINE = re.compile(r"poly route (\d+) (\d+) pts")
COMPLETE_LINE = re.compile(r"complete (\d+)B (\d+)ms")
MAP_ON = "map on"

C_SHARED = "LinkResolver: shared:"
C_DEST = re.compile(r"MapboxProvider: route (-?[\d.]+),(-?[\d.]+) -> (-?[\d.]+),(-?[\d.]+)")
C_MAPBOX_READY = re.compile(r"Mapbox route ready in (\d+) ms")
C_SENDING = re.compile(r"sending route (\d+) to")
C_TOTAL = re.compile(r"TOTAL share -> route on watch: (\d+) ms( \(FAILED\))?")
C_CORRIDOR = re.compile(r"corridor: (\d+) segments in (\d+) LOD\(s\)")
C_CORRIDOR_SENT = re.compile(r"corridor sent to watch: (true|false)")
C_FAILED = re.compile(r"ShareReceiver: failed: (.*)")
C_AWAITING = "ShareReceiver: awaiting confirmation"
C_TAPPED = re.compile(r"Start tapped (\d+) ms after the share")
C_NEW_INTENT = "new share with the screen open (onNewIntent)"
#: One line per companion process (``EventLog.init``), with the pid.
C_SESSION = re.compile(r"EventLog: --- session (\S+) pid (\d+) ---")
C_NO_ACK = "no ACK in"
#: The block-sending lines (``WatchLink.sendBlocks`` and ``BlockRounds``, C13b).
C_SENDING_BLOCKS = re.compile(r"sending route (\d+) to [^:]+: (.+)")
C_BLOCK_COUNT = re.compile(r"0x([0-9A-F]{2})=(\d+) chunk")
C_BLOCK_DONE = re.compile(r"block 0x04 complete after (\d+) rounds")
C_ROUND = re.compile(r"block 0x04 round (\d+): ")
C_DROP_ROUND = re.compile(r"block 0x04 round (\d+): drop at chunk (\d+)/(\d+)(?:, ACK ([0-9A-F ]+))?")
C_CHUNK_OK = re.compile(r"WatchLink: chunk 0x04 \d+ B \(\d+ b64\): SUCCESS")
C_NO_CORRIDOR = "no corridor on this route after"
#: External API down, the way the companion writes it (``MapboxProvider.kt`` and
#: ``CorridorBuilder.kt``): no response, 429 or 5xx from Mapbox; all the
#: Overpass mirrors failing.
C_MAPBOX_DOWN = re.compile(r"MapboxProvider: (no response from Mapbox|HTTP (429|5\d\d))")
C_OVERPASS_DOWN = "Overpass mirrors failed"
#: The radars (C16.6), after the corridor and in the same job (``RerouteController``): what was
#: sent from the cache on the 1st failure, what the search brought, the route without radar, or giving up.
C_RADARS_CACHE = re.compile(r"RerouteController: (\d+) radars from cache for route (\d+), sent: (true|false)")
C_RADARS_FRESH = re.compile(r"RerouteController: (\d+) radars of route (\d+) on attempt (\d+) in (\d+) ms, sent: (true|false)")
C_RADARS_SAME = "same as the cache"
C_RADARS_NONE = "RerouteController: no radar on route"
C_RADARS_GAVE_UP = "no radars from Overpass on this route after"
#: The watch, on reading RADARS (``MessageAssembler.parseRadars``).
W_RADARS = re.compile(r"radars (\d+) route (\d+)")


@dataclass
class Share:
    """A share and everything both sides said after it."""

    label: str
    lat: float
    lon: float
    text: str = ""
    sent_at: float | None = None
    log_mark: int = 0
    am_output: str = ""
    companion: str = ""
    #: (seconds since ``am start``, simulator console line)
    watch: list[tuple[float, str]] = field(default_factory=list)
    relayed: dict[str, int] = field(default_factory=dict)
    #: When the companion wrote the first line of this share.
    started_at: float | None = None
    settled_at: float | None = None
    #: When the corridor finished arriving: from here we wait for the radars' verdict.
    corridor_done_at: float | None = None
    lit: float | None = None
    shot_error: str | None = None
    #: False with ``--link``: the destination of the free text is not known here.
    check_dest: bool = True
    #: The confirmation's start button has already been tapped.
    tapped: bool = False
    #: From the whole companion log, at the instant of the verdict: the pid of the process
    #: that handled this share (``--double``).
    pid: str | None = None

    def watch_text(self) -> str:
        return "\n".join(line for _, line in self.watch)

    def first_at(self, needle: str) -> float | None:
        return next((t for t, line in self.watch if needle in line), None)

    def last_at(self, needle: str) -> float | None:
        hits = [t for t, line in self.watch if needle in line]
        return hits[-1] if hits else None


def maps_link(label: str, lat: float, lon: float) -> str:
    """The text Maps shares: the place name and the URL. The URL format
    is the documented one (Maps URLs, ``search/?api=1&query=``) and matches
    ``LinkResolver``'s ``QUERY_COORDS``."""
    return f"{label} https://www.google.com/maps/search/?api=1&query={lat:.6f},{lon:.6f}"


def token_file() -> Path:
    """The checkout's ``.secrets/``; in a worktree, which does not receive the folder, the
    machine's vault (``docs/SETUP-MAQUINA.md``: same path on both)."""
    vault = Path(r"C:\chaves") if os.name == "nt" else Path.home() / "chaves"
    for candidate in (TOKEN_FILE, vault / "mapbox_token.txt"):
        if candidate.exists():
            return candidate
    sys.exit(f"no Mapbox token in {TOKEN_FILE} or {vault} (docs/SETUP-MAQUINA.md)")


def deliver_token() -> None:
    """Hands the token to the ``sim`` variant. The token is never printed: neither here,
    nor in an error message. Hence ``check=False`` (``ponte.py``'s ``adb``
    prints the arguments when the command fails) and the ``except``
    (``TimeoutExpired`` carries the whole argv, and a traceback would show it)."""
    token = token_file().read_text(encoding="utf-8").strip()
    if not token or "'" in token or " " in token:
        sys.exit("the Mapbox token file is empty or is not a token")
    mark = len(companion_log())
    try:
        ponte.adb("shell", "am", "broadcast", "-a", TOKEN_ACTION, "-n", TOKEN_RECEIVER,
                  "--es", "token", f"'{token}'", check=False)
    except subprocess.TimeoutExpired:
        sys.exit("adb did not answer while delivering the Mapbox token")
    deadline = time.monotonic() + TOKEN_WAIT_S
    while time.monotonic() < deadline:
        if "TokenReceiver: token saved" in companion_log()[mark:]:
            print("Mapbox token delivered to the sim variant")
            return
        time.sleep(0.5)
    sys.exit(f"the TokenReceiver did not confirm the token in {TOKEN_WAIT_S} s: is the installed APK "
             "C7b's? (cd companion && ./gradlew assembleSim)")


def companion_log() -> str:
    """The whole ``.sim`` package's ``motonav.log`` (it runs at 512 KB), in English: a log written
    by an app from before v1.4.1 (Portuguese) comes out as the current one."""
    result = ponte.adb("exec-out", "cat", COMPANION_LOG, check=False, timeout=30)
    return to_english(result.stdout) if result.returncode == 0 else ""


def watch_line(line: str) -> str:
    """One line of the simulator console in English (a build from before v1.4.1 logs in Portuguese).
    The relay frames (``PONTE:TX:``) stay byte for byte: they are handed to the companion."""
    return line if line.startswith(ponte.TX_PREFIX) else to_english(line)


def geo_fix(lat: float, lon: float) -> None:
    """``geo fix`` takes longitude first."""
    ponte.adb("emu", "geo", "fix", f"{lon:.6f}", f"{lat:.6f}", check=False)


def leave_doze() -> None:
    """Undoes what ``--doze`` forces on the emulator. Idempotent, and never throws:
    it runs in the ``finally`` of an hour-long run and at the start of all the others."""
    for args in (("dumpsys", "deviceidle", "unforce"), ("dumpsys", "battery", "reset"),
                 # The battery exemption stays with the package between one install and another: a
                 # tap on the main screen's card would loosen the next ``--doze``.
                 ("dumpsys", "deviceidle", "whitelist", f"-{PACKAGE}")):
        try:
            ponte.adb("shell", *args, check=False, timeout=20)
        except subprocess.TimeoutExpired:
            print(f"adb did not answer {' '.join(args)}")


def app_locale(tag: str) -> bool:
    """The language **of the app** (Android 13's per-app language, C16.8b's `locales_config`), without
    touching ``pato37``'s, which another project shares. ``False`` if the emulator does not have the
    command (below Android 13)."""
    ponte.adb("shell", "cmd", "locale", "set-app-locales", PACKAGE, "--locales", tag, check=False)
    got = ponte.adb("shell", "cmd", "locale", "get-app-locales", PACKAGE, check=False)
    ok = tag.lower() in (got.stdout + got.stderr).lower()
    print(f"app language: {tag}" if ok else f"the emulator did not set the app language to {tag}: "
          f"{(got.stdout + got.stderr).strip()}")
    return ok


def prepare_device(locale: str = "pt-BR") -> None:
    """``locale`` fixes the app's language: the usual runs tap on Portuguese texts."""
    ponte.ensure_emulator()
    # A ``--doze`` run killed in the middle leaves the emulator in forced doze and
    # "unplugged": the next run, whichever it is, would be left without network.
    leave_doze()
    # Screen off or locked: the share's Activity is born stopped, and
    # foreground location is not delivered to an app that is not on screen.
    ponte.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", check=False)
    ponte.adb("shell", "wm", "dismiss-keyguard", check=False)
    ponte.install_and_open()
    app_locale(locale)
    ponte.adb("shell", "pm", "grant", PACKAGE, "android.permission.ACCESS_FINE_LOCATION")
    geo_fix(*ORIGIN)
    deliver_token()


def send_share(text: str) -> str:
    result = ponte.adb("shell", "am", "start", "-n", SHARE_ACTIVITY, "-a", "android.intent.action.SEND",
                       "-t", "text/plain", "--es", "android.intent.extra.TEXT", f"'{text}'", check=False)
    return (result.stdout + result.stderr).strip()


def ui_nodes() -> list[dict[str, str]]:
    """The emulator screen's nodes (``uiautomator dump``). Empty list when the
    dump fails — it happens while the screen is animating, and the caller tries again."""
    # `--windows` also brings the keyboard window: the Gboard dialog that eats
    # the typing (`dismiss_ime_tutorial`) only shows up that way.
    ponte.adb("shell", "uiautomator", "dump", "--windows", UI_DUMP_PATH, check=False, timeout=30)
    result = ponte.adb("exec-out", "cat", UI_DUMP_PATH, check=False, timeout=30)
    if result.returncode != 0 or "<hierarchy" not in result.stdout:
        return []
    try:
        root = ElementTree.fromstring(result.stdout[result.stdout.index("<?xml"):]
                                      if "<?xml" in result.stdout else result.stdout)
    except ElementTree.ParseError:
        return []
    return [dict(node.attrib) for node in root.iter("node")]


def node_center(node: dict[str, str]) -> tuple[int, int] | None:
    match = re.fullmatch(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not match:
        return None
    x1, y1, x2, y2 = (int(v) for v in match.groups())
    return (x1 + x2) // 2, (y1 + y2) // 2


#: The confirmation's filled button (sheet 3, `docs/design/telas.md` §5.6); it was "Iniciar" until 1.1.2.
#: Since 1.4.0 (C16.8b) the phone speaks English too, and the button is "Let's go".
START_BUTTONS = ("Bora", "Let's go")


def tap_start() -> bool:
    """Taps the confirmation's filled button, in either language."""
    return any(tap_text(text) for text in START_BUTTONS)


def tap_text(text: str) -> bool:
    """Taps the node whose text is exactly ``text``. ``False`` if not found."""
    for node in ui_nodes():
        if node.get("text") == text:
            center = node_center(node)
            if center:
                ponte.adb("shell", "input", "tap", str(center[0]), str(center[1]), check=False)
                return True
    return False


def dismiss_ime_tutorial() -> bool:
    """Closes Gboard's «Try out your stylus», which the emulator opens the first
    time a text field gets focus and which **eats the following keys**
    (measured on 2026-10-10: 'Copan Sao Paulo' arrived as 'Copan Sa'). It is not the
    app's, and ``pato37``'s configuration, which another project shares, is not touched:
    only Cancel is tapped."""
    if any(n.get("text") == "Try out your stylus" for n in ui_nodes()):
        tap_text("Cancel")
        time.sleep(0.8)
        return True
    return False


def type_into(field: dict[str, str], text: str, attempts: int = 3) -> bool:
    """Types ``text`` into the field and **checks what ended up in it**. ``adb shell
    input text`` drops keys now and then (measured on 2026-10-10: 'Copan'
    arrived as 'Copa'), and a search with a letter missing flags nothing — it just
    returns another place."""
    center = node_center(field)
    if center is None:
        return False
    for _ in range(attempts):
        ponte.adb("shell", "input", "tap", str(center[0]), str(center[1]), check=False)
        time.sleep(0.5)
        dismiss_ime_tutorial()
        # Clears whatever is there: end of the text and a burst of backspaces.
        ponte.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END", check=False)
        ponte.adb("shell", "input", "keyevent", *(["KEYCODE_DEL"] * (len(text) + 8)), check=False)
        ponte.adb("shell", "input", "text", text.replace(" ", "%s"), check=False)
        time.sleep(0.8)
        # The Gboard tutorial may open in the middle of typing and swallow the rest.
        dismiss_ime_tutorial()
        edit = next((n for n in ui_nodes() if n.get("class", "").endswith("EditText")), None)
        if edit is not None and edit.get("text") == text:
            return True
    return False


def wait_for(predicate, timeout_s: float, every_s: float = 1.5):
    """Repeats ``predicate(nodes)`` until it returns something truthy, or ``None``."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        found = predicate(ui_nodes())
        if found:
            return found
        time.sleep(every_s)
    return None


def screencap(path: Path) -> str | None:
    """Photo of the emulator. ``None`` if it worked, otherwise the reason. Only
    ``pato37``: never Igor's S25 (``CLAUDE.md``)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        result = subprocess.run([str(ponte.ADB), "-s", ponte.SERIAL, "exec-out", "screencap", "-p"],
                                capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        return "screencap did not answer in 30 s"
    data = result.stdout
    if result.returncode != 0 or not data.startswith(b"\x89PNG"):
        return f"screencap did not return a PNG (code {result.returncode})"
    path.write_bytes(data)
    return None


def tx_kind(text: str) -> str:
    """What the watch sent back: ``ack`` (0x81), ``log`` (0x85), the
    probe's answer, or another type from ``05-PROTOCOL.md``."""
    if text.startswith("PONTE:"):
        return "probe"
    try:
        frame = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return "unreadable"
    if len(frame) < 2:
        return "unreadable"
    return {0x81: "ack", 0x85: "log"}.get(frame[1], f"0x{frame[1]:02X}")


def lods_on_watch(watch_text: str) -> dict[int, tuple[int, int]]:
    return {int(m.group(1)): (int(m.group(2)), int(m.group(3))) for m in sim.LOD_LINE.finditer(watch_text)}


def last_session_pid(log: str) -> str | None:
    """The pid of the last process-start line in the given log stretch."""
    found = C_SESSION.findall(log)
    return found[-1][1] if found else None


def share_started(companion: str) -> bool:
    return C_SHARED in companion or C_FAILED.search(companion) is not None


def share_finished(share: Share, elapsed: float) -> bool:
    """Does the share already have a verdict? It does not judge: it only says when to stop
    waiting."""
    companion = share.companion
    since = elapsed - (share.sent_at or elapsed)
    if not share_started(companion):
        return since > SHARE_START_WAIT_S
    if share.started_at is None:
        share.started_at = since
    if C_FAILED.search(companion) or "(FAILED)" in companion or C_NO_CORRIDOR in companion:
        return True
    sent = C_CORRIDOR_SENT.search(companion)
    if not sent:
        return False
    if sent.group(1) == "false":
        return True
    declared = C_CORRIDOR.search(companion)
    expected = int(declared.group(2)) if declared else 0
    if len(lods_on_watch(share.watch_text())) < expected:
        # The block's ACK goes out on arrival; the `corridor lod` line only after the sliced
        # parse. Wait for the watch to finish reading, with a deadline.
        if share.settled_at is None:
            share.settled_at = elapsed
        if elapsed - share.settled_at <= LOD_PARSE_WAIT_S:
            return False
    # The corridor is there (or its deadline passed): the radars come after, in the same job.
    if share.corridor_done_at is None:
        share.corridor_done_at = elapsed
    return radars_settled(share) or elapsed - share.corridor_done_at > RADAR_WAIT_S


def radars_settled(share: Share) -> bool:
    """This route's radars already have a verdict: the search answered (with a radar read on the watch,
    equal to the cache, or without radar) or the companion gave up on Overpass."""
    companion = share.companion
    if C_RADARS_GAVE_UP in companion or C_RADARS_NONE in companion or C_RADARS_SAME in companion:
        return True
    return C_RADARS_FRESH.search(companion) is not None and W_RADARS.search(share.watch_text()) is not None


def judge_share(share: Share, need_map: bool) -> tuple[int, list[str]]:
    """``0`` arrived whole, ``2`` external API down, ``1`` the rest. Pure: it only reads
    what both sides wrote."""
    companion, watch = share.companion, share.watch_text()
    report: list[str] = []
    failures: list[str] = []

    if share.started_at is not None:
        report.append(f"companion: started handling the share within +{share.started_at:.1f} s")
    dest = C_DEST.search(companion)
    if dest:
        lat, lon = float(dest.group(3)), float(dest.group(4))
        report.append(f"companion: destination asked of Mapbox {lat},{lon}")
        if share.check_dest and (abs(lat - share.lat) > DEST_TOLERANCE_DEG
                                 or abs(lon - share.lon) > DEST_TOLERANCE_DEG):
            failures.append(f"the link's destination was {share.lat},{share.lon}: the LinkResolver read another place")
    else:
        failures.append("the companion never asked Mapbox for the route")

    reason = C_FAILED.search(companion)
    if reason:
        failures.append(f"the companion gave up: {reason.group(1).strip()}")

    tapped = C_TAPPED.search(companion)
    if C_AWAITING in companion:
        report.append("companion: destination confirmed on screen"
                      + (f" ({tapped.group(1)} ms after the share)" if tapped else " (Start was never tapped)"))
    if C_NEW_INTENT in companion:
        report.append("companion: the open screen received the share through onNewIntent")

    ready = C_MAPBOX_READY.search(companion)
    if ready:
        report.append(f"companion: Mapbox route ready in {ready.group(1)} ms")

    sending = C_SENDING.search(companion)
    route_id = sending.group(1) if sending else None
    total = C_TOTAL.search(companion)
    if total:
        report.append(f"companion: share -> route on watch in {total.group(1)} ms"
                      + (" (FAILED)" if total.group(2) else ""))
        if total.group(2):
            failures.append("the companion did not deliver the route"
                            + (" (no ACK came back)" if C_NO_ACK in companion else ""))
    elif dest and not reason:
        failures.append("the companion did not finish sending the route (no TOTAL line)")

    polys = {m.group(1): int(m.group(2)) for m in POLY_LINE.finditer(watch)}
    if route_id is not None and route_id in polys:
        at = share.first_at(f"poly route {route_id} ")
        report.append(f"watch: route {route_id} with {polys[route_id]} pts read at +{at:.1f} s")
    else:
        failures.append(f"route {route_id or '?'} was not read on the watch (no 'poly route')")

    completes = COMPLETE_LINE.findall(watch)
    if completes:
        size, ms = completes[-1]
        report.append(f"watch: complete at +{share.first_at('complete '):.1f} s; last "
                      f"'complete' line with {size} B in {ms} ms (counts the corridor)")
    else:
        failures.append("the watch did not report the route complete")

    if need_map:
        map_at = share.first_at(MAP_ON)
        if map_at is None:
            failures.append("the map did not come up (no 'map on')")
        else:
            report.append(f"watch: map on at +{map_at:.1f} s")

    declared = C_CORRIDOR.search(companion)
    sent = C_CORRIDOR_SENT.search(companion)
    lods = lods_on_watch(watch)
    if declared:
        report.append(f"companion: corridor of {declared.group(1)} segments in {declared.group(2)} LOD(s)")
    report.append("watch: LODs read: "
                  + (", ".join(f"{lod}={w} ways/{p} pts" for lod, (w, p) in sorted(lods.items())) or "none"))
    if not sent:
        failures.append("the corridor was not sent" + (" (Overpass did not answer)" if C_NO_CORRIDOR in companion else ""))
    elif sent.group(1) == "false":
        failures.append("the companion could not deliver the corridor")
    elif declared:
        expected = int(declared.group(2))
        if expected < 1:
            failures.append("the corridor came with 0 LODs")
        elif len(lods) < expected:
            failures.append(f"the watch read {len(lods)} LOD(s) of {expected}")
        else:
            last = share.last_at("corridor lod ")
            report.append(f"watch: last LOD read at +{last:.1f} s since the share")

    # The radars (C16.6): the Tietê -> Copan route goes past OSM radars (9 in the recording of
    # 2026-10-26, `RadarFilterTest`), so "no radar" here is a defect, not the route.
    cached = C_RADARS_CACHE.search(companion)
    fresh = C_RADARS_FRESH.search(companion)
    on_watch = W_RADARS.findall(watch)
    if cached:
        report.append(f"companion: {cached.group(1)} radars from the cache (Overpass failed on the 1st), sent: {cached.group(3)}")
    if fresh:
        report.append(f"companion: {fresh.group(1)} radars from the search on attempt {fresh.group(3)} in "
                      f"{fresh.group(4)} ms, sent: {fresh.group(5)}")
    report.append("watch: radars read: " + (", ".join(f"{n} (route {r})" for n, r in on_watch) or "none"))
    radar_overpass_down = False
    if C_RADARS_NONE in companion:
        failures.append("the companion found the route with no radar at all")
    elif not on_watch:
        if C_RADARS_GAVE_UP in companion and not cached:
            radar_overpass_down = True
            failures.append("no radar: Overpass refused every attempt and the cache was empty")
        else:
            failures.append("no radar reached the watch (no 'radars N route')")
    elif int(on_watch[-1][0]) < 1:
        failures.append("the watch read an empty radar list")

    peaks = [int(p) for p in sim.WORK_PEAK.findall(watch)]
    if peaks:
        report.append(f"work peak: {max(peaks)} (ceiling {sim.WORK_CEILING}, {len(peaks)} sample(s))")
        if max(peaks) >= sim.WORK_CEILING:
            failures.append(f"work peak {max(peaks)} >= {sim.WORK_CEILING}")
    if "Watchdog Tripped" in watch:
        failures.append("Watchdog Tripped")

    acks = share.relayed.get("ack", 0)
    report.append("relay: " + (", ".join(f"{n} {kind}" for kind, n in sorted(share.relayed.items())) or "nothing")
                  + f" — {sum(share.relayed.values())} message(s) from the watch")
    if acks < 1:
        failures.append("no ACK came back through the relay")

    if need_map:
        if share.lit is None:
            failures.append(f"no simulator photo ({share.shot_error or 'not taken'})")
        else:
            report.append(f"screen: {share.lit:.1%} lit (floor {sim.LIT_MIN:.0%}) · {MAP_SHOT}")
            if share.lit <= sim.LIT_MIN:
                failures.append(f"screen {share.lit:.1%} lit, floor {sim.LIT_MIN:.0%}")

    if not failures:
        return 0, report
    report += [f"FAILED: {f}" for f in failures]
    mapbox_down = C_MAPBOX_DOWN.search(companion) and not ready
    overpass_down = C_NO_CORRIDOR in companion and C_OVERPASS_DOWN in companion
    if mapbox_down:
        return 2, report + ["External API down: Mapbox did not answer (is the emulator offline?)"]
    if overpass_down or (radar_overpass_down and len(failures) == 1):
        return 2, report + ["External API down: every Overpass mirror failed"]
    return 1, report


def config_command(values: dict[str, int]) -> str:
    """The CONFIG as a bridge command (``PONTE:CMD:DATA:<base64>``, C16.6): the companion's ``sim``
    variant does not have the ``ConfigReceiver``, which lives in ``src/debug``."""
    import packer

    return "DATA:" + base64.b64encode(packer.config_frame(values)).decode()


def run(timeout_s: int, double: bool, canary: bool, link: str | None,
        config: dict[str, int] | None = None, locale: str = "pt-BR") -> int:
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()  # fails early, before bringing up the emulator and simulator

    shares = [Share(*COPAN)]
    if double:
        shares.append(Share(*CONGONHAS))
    for share in shares:
        share.text = maps_link(share.label, share.lat, share.lon)
    if link:
        shares[0].text = link
        shares[0].check_dest = False

    prepare_device(locale)
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    state = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "index": 0, "next_log": 0.0,
             "held": 0, "config_at": None}

    def current() -> Share:
        return shares[state["index"]]

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if state["started"] is None and ponte.APP_START.match(line):
            state["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            state["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        share = current()
        if share.sent_at is not None:
            share.watch.append((elapsed - share.sent_at, line))
        if line.strip() == c2r and state["c2r_at"] is None:
            state["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            if canary:
                state["held"] += 1  # the canary is this: the return leg is not delivered
            elif ponte.relay(payload) and share.sent_at is not None:
                kind = tx_kind(payload)
                share.relayed[kind] = share.relayed.get(kind, 0) + 1

    def on_idle(elapsed: float) -> bool:
        if state["c2r_at"] is None:
            due = state["next_probe"]
            if due is not None and elapsed >= due:
                state["probes"] += 1
                ponte.send_probe(probe_id)
                state["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        if config and state["config_at"] is None:
            # The default and then the request, like `sim.py demo --config`: the simulator's
            # `Storage` keeps the previous run's CONFIG.
            ponte.send_command(config_command({}))
            ponte.send_command(config_command(config))
            state["config_at"] = elapsed
            print(f"CONFIG {sim.config_text(config)} sent over the bridge ({elapsed:.1f} s)")
            return False
        if config and elapsed < state["config_at"] + CONFIG_SETTLE_S:
            return False
        share = current()
        if share.sent_at is None:
            geo_fix(*ORIGIN)
            share.log_mark = len(companion_log())
            share.sent_at = elapsed
            share.am_output = send_share(share.text)
            print(f"shared ({elapsed:.1f} s): {share.text}")
            return False
        if elapsed < state["next_log"]:
            return False
        state["next_log"] = elapsed + LOG_EVERY_S
        full = companion_log()
        share.companion = full[share.log_mark:]
        if C_AWAITING in share.companion and not share.tapped:
            # RF-01's confirmation: without the tap the route never leaves the phone.
            share.tapped = tap_start()
            if share.tapped:
                print(f"Start tapped ({elapsed:.1f} s)")
            return False
        if not share_finished(share, elapsed):
            return False
        share.pid = last_session_pid(full[:share.log_mark + len(share.companion)])
        # The photo is of the map: without `map on` the screen is the transfer one, and a
        # photo of it would only confuse the report.
        if state["index"] == 0 and share.first_at(MAP_ON) is not None:
            try:
                share.shot_error = sim.take_shot(MAP_SHOT)
            except subprocess.TimeoutExpired:
                # Job 963 (26/10): with the simulator hung the capture blew past 60 s, the
                # `TimeoutExpired` left through the `finally` and the run fell without saving the logs.
                share.shot_error = "the capture timed out: is the simulator hung?"
            share.lit = None if share.shot_error else sim.lit_fraction(MAP_SHOT)
        if state["index"] + 1 < len(shares) and judge_share(share, need_map=True)[0] == 0:
            state["index"] += 1
            return False
        if config:
            # Gives the default back to `Storage` with the app still open, so the next
            # `sim.py demo` does not inherit the setting.
            ponte.send_command(config_command({}))
            time.sleep(CONFIG_SETTLE_S)
        return True

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
    finally:
        # Only our package: stops the corridor's retries and leaves
        # `pato37` as it was for the other project that shares it.
        ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    sim.save(WATCH_LOG, text)
    sim.save(COMPANION_OUT, "\n\n".join(f"--- {s.label}: {s.am_output}\n{s.companion}" for s in shares))

    print()
    if state["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if state["c2r_at"] is None:
        print(f"no probe arrived in {state['probes']} attempt(s): the outbound leg is not alive "
              "(close the simulator — taskkill /IM simulator.exe /F — and run again; or python tools/ponte.py)")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    codes = []
    for index, share in enumerate(shares):
        if share.sent_at is None:
            break
        code, report = judge_share(share, need_map=index == 0)
        codes.append(code)
        print(f"share {index + 1} ({share.label}):")
        for line in report:
            print(f"  {line}")
        if not share_started(share.companion):
            print(f"  the share did not move in the companion; am start said: {share.am_output or '(nothing)'}")

    if canary:
        passed = POLY_LINE.search(shares[0].watch_text()) is not None
        print(f"canary: {state['held']} watch message(s) held back")
        if passed:
            # The code has to change along with the text: whoever checks the canary
            # by "must exit 1" would see green on a dead canary.
            print("the canary did NOT bite (exit 0): the route passed with the return leg held back — the relay is not "
                  "being checked, or the simulator's transmit works again (python tools/ponte.py --socket)")
            return 0
        if C_NO_ACK in shares[0].companion:
            print("canary bit: without the relay the companion got no ACK and the route did not pass (exit 1 here is expected)")
            return 1
        print(f"canary inconclusive (exit {codes[0] if codes else 1}): the run stopped before the companion "
              "waited for an ACK; see the failures above")
        return codes[0] if codes and codes[0] == 2 else 1

    if codes[0] != 0:
        print(f"e2e: NO (exit {codes[0]}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
        return codes[0]
    if not double:
        print("e2e: OK — from the Maps link to the map in the simulator; outbound over TETHERED, return through the relay")
        return 0
    if len(codes) == 2 and codes[1] == 0:
        ids = [C_SENDING.search(s.companion) for s in shares]
        route_ids = [m.group(1) if m else "?" for m in ids]
        pids = [s.pid for s in shares]
        print(f"e2e --double: routes {route_ids[0]} and {route_ids[1]}; companion pid {pids[0]} and {pids[1]}")
        if "?" in route_ids or route_ids[0] == route_ids[1]:
            print("e2e --double: NO (exit 1) — the two shares do not have different routeIds")
            return 1
        if pids[0] is None or pids[0] != pids[1]:
            print("e2e --double: NO (exit 1) — the two shares are not under the same process-start line "
                  "of motonav.log")
            return 1
        print("e2e --double: OK — both shares arrived with the app open, under the same "
              f"process (pid {pids[0]}) and with different routeIds")
        return 0
    if len(codes) < 2 or timed_out:
        print("e2e --double: NO (exit 1) — the run ended before the second share had a verdict")
        return 1
    if codes[1] == 2:
        print("e2e --double: the second stopped on an external API (exit 2); says nothing about the bug")
        return 2
    if POLY_LINE.search(shares[1].watch_text()):
        # The second's route reached the watch: what failed after that is
        # a failure of this run, not the bug of "the second does not work".
        print("e2e --double: NO (exit 1) — the second's route reached the watch, but the run failed afterwards")
        return 1
    print("e2e --double: second-share bug REPRODUCED (exit 3): the first arrived and the second's route "
          "did not reach the watch, without killing the process (docs/STATUS.md §OPEN ISSUES)")
    return 3


#: The watch's block deadline (``Protocol.BLOCK_TIMEOUT_MS``): a drop longer than this
#: makes the watch send the bitmap of what arrived, and ``--drop`` starts requiring that path.
WATCH_BLOCK_TIMEOUT_S = 30

#: With the drop armed, ``motonav.log`` is read at this pace, not every 2 s: a 4 KB
#: chunk takes ~9 s on ``TETHERED``, but the last one of a block may have few bytes and go out
#: in under 1 s, and the drop has to land with the block still open.
DROP_POLL_S = 0.5


def corridor_blocks(companion: str) -> tuple[list[int], list[list[str]]] | None:
    """The last corridor send in the log: how many chunks each block has (one per LOD) and the
    log lines of each block, in order. ``None`` while the corridor has not started going out.

    Only lines of type 0x04 count: another send can go out in the middle of the corridor (the
    favorites resent when the outbound leg reconnects, measured in C13b), and its lines are not
    of this block."""
    lines = companion.splitlines()
    start, counts = None, []
    for index, line in enumerate(lines):
        sending = C_SENDING_BLOCKS.search(line)
        if not sending:
            continue
        blocks = C_BLOCK_COUNT.findall(sending.group(2))
        if blocks and all(msg_type == "04" for msg_type, _ in blocks):
            start, counts = index, [int(chunks) for _, chunks in blocks]
    if start is None:
        return None
    segments: list[list[str]] = [[]]
    for line in lines[start + 1:]:
        if "WatchLink: chunk 0x04 " not in line and "WatchLink: block 0x04 " not in line:
            continue
        segments[-1].append(line)
        if C_BLOCK_DONE.search(line) and len(segments) < len(counts):
            segments.append([])
    return counts, segments


def drop_target(counts: list[int]) -> int:
    """The block that ``--drop`` drops: the first of the largest."""
    return counts.index(max(counts))


def judge_drop(companion: str, watch: str, drop_s: int, dropped_block: int | None) -> tuple[list[str], list[str]]:
    """What ``--drop`` requires **beyond** the whole share (``judge_share``).
    ``dropped_block`` is the index of the block in which the outbound leg was dropped (``None``: it was not).
    Returns (report, failures). Pure: it only reads what both sides wrote."""
    report: list[str] = []
    failures: list[str] = []
    found = corridor_blocks(companion)
    if found is None:
        return report, ["the corridor never left the phone: there was no block to drop"]
    counts, segments = found
    target = drop_target(counts) if dropped_block is None else dropped_block
    report.append("companion: corridor in blocks of " + ", ".join(str(c) for c in counts)
                  + f" chunk(s); the dropped one is no. {target + 1} ({counts[target]} chunks)")
    if counts[target] < 2:
        failures.append("this route's corridor has no block of more than one chunk: there is no mid-block to drop")
    rounds_per_block = []
    for segment in segments:
        done = next((C_BLOCK_DONE.search(line) for line in segment if C_BLOCK_DONE.search(line)), None)
        rounds_per_block.append(int(done.group(1)) if done else None)
    report.append("companion: rounds per corridor block: "
                  + ", ".join("did not close" if n is None else str(n) for n in rounds_per_block))

    segment = segments[target] if target < len(segments) else []
    drops = [m for m in (C_DROP_ROUND.search(line) for line in segment) if m]
    for drop in drops:
        report.append(f"companion: block round {drop.group(1)}: drop at chunk {drop.group(2)}/{drop.group(3)}"
                      + (f", ACK {drop.group(4).strip()}" if drop.group(4) else ""))
    if dropped_block is None:
        failures.append("the outbound leg was not dropped")
    elif not drops:
        failures.append("no round with a drop in the dropped block: the drop did not catch one of its chunks in flight")
    elif int(drops[0].group(2)) < 2:
        # A drop at chunk 1 is a drop **between** blocks: the watch had nothing of this
        # block stored, and what the slice asks for is the half block crossing the drop.
        failures.append("the first drop was at chunk 1: no chunk of the block had arrived, "
                        "so it was not mid-block")
    rounds = rounds_per_block[target] if target < len(rounds_per_block) else None
    if rounds is None:
        failures.append("the dropped block did not close (no 'block 0x04 complete after N rounds')")
    elif rounds < 2:
        failures.append(f"block 0x04 complete after {rounds} round(s): it had to be 2 or more")

    read = [int(m.group(1)) for m in sim.LOD_LINE.finditer(watch)]
    twice = sorted({lod for lod in read if read.count(lod) > 1})
    if twice:
        failures.append("the watch read LOD(s) more than once: " + ", ".join(str(lod) for lod in twice))
    else:
        report.append("watch: each corridor LOD read only once")
    if "of corridor repeated: ignored" in watch:
        report.append("watch: a corridor block arrived repeated and was not read again")

    if drop_s > WATCH_BLOCK_TIMEOUT_S:
        if "timeout 0x04" not in watch:
            failures.append(f"drop of {drop_s} s and the watch did not hit the block deadline (no 'timeout 0x04')")
        if not any(drop.group(4) for drop in drops):
            failures.append("no round received the watch's partial bitmap")
        marks = [index for index, line in enumerate(segment) if C_ROUND.search(line)]
        if marks:
            first = marks[-2] + 1 if len(marks) > 1 else 0
            last_round = sum(1 for line in segment[first:marks[-1]] if C_CHUNK_OK.search(line))
            report.append(f"companion: the block's last round sent {last_round} of {counts[target]} chunks")
            if last_round >= counts[target]:
                failures.append("the last round resent the whole block: the bitmap was not used")
    return report, failures


def run_drop(timeout_s: int, drop_s: int, canary: bool) -> int:
    """``--drop`` (C13b): the usual share, with the outbound leg dropped in the middle of the
    largest corridor block."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()
    share = Share(*COPAN)
    share.text = maps_link(share.label, share.lat, share.lon)

    prepare_device()
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    state = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
             "dropped_at": None, "restored_at": None, "late": False, "block": None}

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if state["started"] is None and ponte.APP_START.match(line):
            state["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            state["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        if share.sent_at is not None:
            share.watch.append((elapsed - share.sent_at, line))
        if line.strip() == c2r and state["c2r_at"] is None:
            state["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            if ponte.relay(payload) and share.sent_at is not None:
                kind = tx_kind(payload)
                share.relayed[kind] = share.relayed.get(kind, 0) + 1

    def arm(elapsed: float) -> bool:
        """Drops the outbound leg at the **start** of a block of more than one chunk. Returns ``True``
        while the drop can still happen (and the log deserves to be read faster).

        Why at the start: measured in C13b, the message in flight when ``Release`` is
        pressed **arrives** at the watch, and the next one fails. Dropping with chunk
        ``k`` in flight, the watch is left with ``k + 1`` chunks stored and ``k + 2``
        is lost: for that to be mid-block, at least one chunk has to remain after the one
        in flight. If the log read arrived late for this block, the next one goes."""
        if canary or state["dropped_at"] is not None or state["late"]:
            return False
        found = corridor_blocks(share.companion)
        if found is None:
            return False
        counts, segments = found
        if state["block"] is None:
            state["block"] = drop_target(counts)
        while True:
            target = state["block"]
            if len(segments) <= target:
                return True
            delivered = sum(1 for line in segments[target] if C_CHUNK_OK.search(line))
            if delivered <= counts[target] - 2:
                state["dropped_at"] = elapsed
                print(f"outbound leg dropped ({elapsed:.1f} s), in block {target + 1} of {len(counts)} "
                      f"({counts[target]} chunks, {delivered} delivered): {ponte.drop_link()}")
                return False
            later = [i for i in range(target + 1, len(counts)) if counts[i] >= 2]
            if not later:
                state["late"] = True
                print(f"the log read came too late to drop ({elapsed:.1f} s): no block of 2 chunks left")
                return False
            state["block"] = later[0]

    def on_idle(elapsed: float) -> bool:
        if state["c2r_at"] is None:
            due = state["next_probe"]
            if due is not None and elapsed >= due:
                state["probes"] += 1
                ponte.send_probe(probe_id)
                state["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        if share.sent_at is None:
            geo_fix(*ORIGIN)
            share.log_mark = len(companion_log())
            share.sent_at = elapsed
            share.am_output = send_share(share.text)
            print(f"shared ({elapsed:.1f} s): {share.text}")
            return False
        dropped_at = state["dropped_at"]
        if dropped_at is not None and state["restored_at"] is None and elapsed - dropped_at >= drop_s:
            state["restored_at"] = elapsed
            print(f"outbound leg back ({elapsed:.1f} s, {elapsed - dropped_at:.1f} s later): {ponte.restore_link()}")
        if elapsed < state["next_log"]:
            return False
        share.companion = companion_log()[share.log_mark:]
        state["next_log"] = elapsed + (DROP_POLL_S if arm(elapsed) else LOG_EVERY_S)
        if C_AWAITING in share.companion and not share.tapped:
            share.tapped = tap_start()
            if share.tapped:
                print(f"Start tapped ({elapsed:.1f} s)")
            return False
        if dropped_at is not None and state["restored_at"] is None:
            return False
        if not share_finished(share, elapsed):
            return False
        if share.first_at(MAP_ON) is not None:
            share.shot_error = sim.take_shot(MAP_SHOT)
            share.lit = None if share.shot_error else sim.lit_fraction(MAP_SHOT)
        return True

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
    finally:
        ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    sim.save(WATCH_LOG, text)
    sim.save(COMPANION_OUT, f"--- {share.label}: {share.am_output}\n{share.companion}")

    print()
    if state["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if state["c2r_at"] is None:
        print(f"no probe arrived in {state['probes']} attempt(s): the outbound leg is not alive "
              "(close the simulator — taskkill /IM simulator.exe /F — and run again; or python tools/ponte.py)")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    code, report = judge_share(share, need_map=True)
    extra, failures = judge_drop(share.companion, share.watch_text(), drop_s,
                                  state["block"] if state["dropped_at"] is not None else None)
    for line in report + extra:
        print(f"  {line}")
    for failure in failures:
        print(f"  FAILED: {failure}")
    if not share_started(share.companion):
        print(f"  the share did not move in the companion; am start said: {share.am_output or '(nothing)'}")

    if canary:
        if code == 0 and not failures:
            print("the canary did NOT bite (exit 0): with no drop at all the judge found a block with 2 rounds or more")
            return 0
        if code == 0:
            print("canary bit: without dropping the outbound leg the block closes in 1 round and --drop fails "
                  "(exit 1 here is expected)")
            return 1
        print(f"canary inconclusive (exit {code}): the run failed before the drop judge counted; see above")
        return code
    if code == 2:
        print(f"e2e --drop: external API down (exit 2) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
        return 2
    if code != 0 or failures:
        print(f"e2e --drop: NO (exit 1) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
        return 1
    print(f"e2e --drop {drop_s}: OK — the outbound leg was down {drop_s} s in the middle of the block and the corridor arrived whole")
    return 0


#: The ``--detour`` destination (C11): the point of the ``route_tiete_copan.json`` route that is
#: 3,383 m from the start (point 91 of 479, on Av. Doutor Assis Ribeiro: at 5 km the route is already
#: on Ayrton Senna, which the app avoids). A short route because the recalculation's 10 s deadline only fits
#: in it: the emulator's transport cost ~7 s on the POLY of 790 points of the old test route alone
#: (``DECISIONS.md`` §C7b).
DETOUR_DEST = ("Ponto 3 km", -23.50916, -46.54919)

#: How far the motorcycle leaves the route, in meters: 1.5x the RF-11 threshold (40 m), the same as ``sim.py ride``.
DETOUR_M = 60

#: The RF-11 recalculation deadline, in ms, from the request to the swapped route.
DETOUR_BUDGET_MS = 10_000

#: Seconds of motorcycle on the route before the first detour, and between the swap settling and the next:
#: the detector only arms after a fix within 40 m of the new route.
DETOUR_RIDE_S = 12

#: How long to wait for a new route's corridor to settle before going on anyway. The public
#: Overpass has three attempts of 20 s (``RerouteController.CORRIDOR_*``).
DETOUR_SETTLE_MAX_S = 150

#: How long to wait for each command to take effect on the watch before repeating it.
DETOUR_CMD_WAIT_S = 20

W_SWAP = re.compile(r"route swapped (\d+) -> (\d+) in (\d+) ms")
W_SIM_START = "simulation start"
W_OFF_ROUTE = re.compile(r"off route \d+m")
W_ARRIVED = ("simulation end: arrival", "arrived at destination")


def judge_detour(watch: str, relayed: dict[str, int], companion: str, wanted: int) -> tuple[int, list[str]]:
    """``--detour N``, from what both sides wrote: ``(code, report)``. Pure."""
    report: list[str] = []
    failures: list[str] = []

    frames = relayed.get("0x82", 0)
    report.append(f"relay: {frames} REROUTE_REQ (0x82) from the watch, expected {wanted}; "
                  + (", ".join(f"{n} {kind}" for kind, n in sorted(relayed.items())) or "nothing"))
    if frames != wanted:
        failures.append(f"{frames} 0x82 frames, expected exactly {wanted}")

    outs = len(W_OFF_ROUTE.findall(watch))
    report.append(f"watch: {outs}x off route")
    if outs != wanted:
        failures.append(f"{outs} off-route events on the watch, expected {wanted}")

    swaps = [(m.group(1), m.group(2), int(m.group(3))) for m in W_SWAP.finditer(watch)]
    for index, (old, new, ms) in enumerate(swaps, start=1):
        report.append(f"swap {index}: route {old} -> {new} in {ms} ms (deadline {DETOUR_BUDGET_MS} ms)")
        if ms > DETOUR_BUDGET_MS:
            failures.append(f"interval {index}: {ms} ms from the request to the new route applied, deadline {DETOUR_BUDGET_MS} ms")
    if len(swaps) != wanted:
        failures.append(f"{len(swaps)} route swaps on the watch, expected {wanted}")

    if not any(word in watch for word in W_ARRIVED):
        failures.append("the watch did not reach the destination (no 'arrived at destination')")
    if "Watchdog Tripped" in watch:
        failures.append("Watchdog Tripped")
    peaks = [int(p) for p in sim.WORK_PEAK.findall(watch)]
    if peaks:
        report.append(f"work peak: {max(peaks)} (ceiling {sim.WORK_CEILING}, {len(peaks)} sample(s))")

    if not failures:
        return 0, report
    report += [f"FAILED: {f}" for f in failures]
    if C_MAPBOX_DOWN.search(companion) and len(swaps) < wanted:
        return 2, report + ["External API down: Mapbox did not answer (is the emulator offline?)"]
    if C_NO_CORRIDOR in companion and C_OVERPASS_DOWN in companion and len(swaps) < wanted:
        return 2, report + ["External API down: Overpass did not let the corridor settle"]
    return 1, report


def run_detour(timeout_s: int, wanted: int) -> int:
    """The whole recalculation on the PC (C11): link -> route -> virtual ride -> ``wanted`` detours."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()

    share = Share(*DETOUR_DEST)
    share.text = maps_link(share.label, share.lat, share.lon)
    prepare_device()
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    lines: list[tuple[float, str]] = []
    relayed: dict[str, int] = {}
    st = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
          "stage": "share", "detours": 0, "mark": 0.0, "cmd_at": None, "swaps": 0, "settled": None,
          "log": []}

    def stage(name: str, elapsed: float) -> None:
        st["stage"] = name
        st["mark"] = elapsed
        st["cmd_at"] = None
        st["settled"] = None
        st["log"].append(f"{elapsed:7.1f}s {name}")
        print(f"{elapsed:7.1f}s {name}")

    def count(pattern) -> int:
        return len(pattern.findall("\n".join(line for _, line in lines)))

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if st["started"] is None and ponte.APP_START.match(line):
            st["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            st["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        lines.append((elapsed, line))
        if line.strip() == c2r and st["c2r_at"] is None:
            st["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            if ponte.relay(payload):
                kind = tx_kind(payload)
                relayed[kind] = relayed.get(kind, 0) + 1
                if kind == "0x82":
                    print(f"{elapsed:7.1f}s REROUTE_REQ #{relayed[kind]} delivered to the companion")

    def seen(text: str) -> bool:
        return any(text in line for _, line in lines)

    def command(text: str, elapsed: float) -> None:
        ponte.send_command(text)
        st["cmd_at"] = elapsed
        print(f"{elapsed:7.1f}s command {text}")

    def corridor_events(companion: str) -> int:
        return len(C_CORRIDOR_SENT.findall(companion)) + companion.count(C_NO_CORRIDOR)

    def on_idle(elapsed: float) -> bool:
        if st["c2r_at"] is None:
            due = st["next_probe"]
            if due is not None and elapsed >= due:
                st["probes"] += 1
                ponte.send_probe(probe_id)
                st["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        if relayed.get("0x82", 0) > wanted:
            print(f"{elapsed:7.1f}s one request too many ({relayed['0x82']} > {wanted}): stopping")
            return True
        if st["stage"] == "share":
            if share.sent_at is None:
                geo_fix(*ORIGIN)
                share.log_mark = len(companion_log())
                share.sent_at = elapsed
                share.am_output = send_share(share.text)
                print(f"shared ({elapsed:.1f} s): {share.text}")
                return False
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            share.companion = companion_log()[share.log_mark:]
            if C_AWAITING in share.companion and not share.tapped:
                share.tapped = tap_start()
                if share.tapped:
                    print(f"Start tapped ({elapsed:.1f} s)")
                return False
            share.watch = [(t - share.sent_at, line) for t, line in lines]
            if share_finished(share, elapsed):
                stage("sim", elapsed)
            elif C_FAILED.search(share.companion):
                return True
            return False

        if st["stage"] == "sim":
            if seen(W_SIM_START):
                stage("riding", elapsed)
            elif st["cmd_at"] is None or elapsed - st["cmd_at"] > DETOUR_CMD_WAIT_S:
                command("SIM", elapsed)
            return False

        if st["stage"] == "riding":
            if elapsed - st["mark"] < DETOUR_RIDE_S:
                return False
            if st["detours"] >= wanted:
                stage("arrival", elapsed)
                return False
            st["detours"] += 1
            st["swaps_before"] = count(W_SWAP)
            stage(f"detour {st['detours']}", elapsed)
            command(f"DETOUR:{DETOUR_M}", elapsed)
            return False

        if st["stage"].startswith("detour"):
            if count(W_SWAP) > st["swaps_before"]:
                stage(f"settle {st['detours']}", elapsed)
            elif st["cmd_at"] is not None and elapsed - st["cmd_at"] > 90:
                print(f"{elapsed:7.1f}s the new route did not arrive in 90 s: stopping")
                return True
            return False

        if st["stage"].startswith("settle"):
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            companion = companion_log()[share.log_mark:]
            share.companion = companion
            # 1 for the original route's corridor + 1 per recalculation.
            done = corridor_events(companion) >= 1 + st["detours"]
            if done and st["settled"] is None:
                st["settled"] = elapsed
            if (st["settled"] is not None and elapsed - st["settled"] > LOD_PARSE_WAIT_S) \
                    or elapsed - st["mark"] > DETOUR_SETTLE_MAX_S:
                stage("riding", elapsed)
            return False

        # arrival: the motorcycle rides the rest of the route on its own.
        return any(word in line for _, line in lines for word in W_ARRIVED)

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
    finally:
        ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    sim.save(WATCH_LOG, text)
    companion = share.companion
    sim.save(COMPANION_OUT, f"--- {share.label}: {share.am_output}\n{companion}")

    print()
    if st["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if st["c2r_at"] is None:
        print(f"no probe arrived in {st['probes']} attempt(s): the outbound leg is not alive")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    code, report = judge_detour(to_english(text), relayed, companion, wanted)
    for line in report:
        print(f"  {line}")
    if code == 0:
        print(f"e2e --detour {wanted}: OK — {wanted} detours, {wanted} recalculations over the whole bridge, "
              "each within the deadline")
    else:
        print(f"e2e --detour {wanted}: NO (exit {code}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
    return code


# --- C13b: the phone's GPS as a fallback (--no-fix) ---------------------------------

#: How long the motorcycle rides with a fix before the hole, after the route and corridor settle.
NOFIX_RIDE_S = 12

#: From the start of the hole to the first phone fix applied on the watch: 5 s of the request
#: (``FixFallback``), the relay, the cold Fused (about 4 s in C7b) and the send. More than this fails.
NOFIX_FIRST_FIX_S = 15

#: After the hole: ``FIX_REQ 0`` goes out 5 s after the own fix is back, and the telemetry
#: is one line every 10 s; 25 s guarantee two lines already without the phone.
NOFIX_AFTER_S = 25

#: From HOME + screen off to the hole: the time for the Activity to really leave the scene.
NOFIX_POCKET_S = 5

#: The watch's own fix source in this build. On the PC the motorcycle is the virtual ride; the
#: literal ``gps`` of C13b's ``verificar:`` only exists on hardware (C16).
NOFIX_OWN_SOURCE = "replay"

#: 1 m/s in knots: the speed of the emulator console's ``geo fix``.
KNOTS_PER_MPS = 1.943844

#: How far behind the motorcycle the phone fix applied on the watch may be, at the median: less
#: than two steps of the virtual ride at 50 km/h (13.9 m/s). With the fix "at the start", which is the
#: defect the ``PONTE:POS`` line exists to avoid, it would be hundreds of meters.
NOFIX_BEHIND_M = 25

#: The largest interval accepted between two phone fixes applied, and from the last to the end of the
#: hole. 5 s is when the watch itself deems the phone silent (``FixFallback.PHONE_SILENT_MS``);
#: 3 s is three lost fixes in a row. Without these two, a fallback that died in the middle of the
#: tunnel would pass: the telemetry keeps saying ``fix phone`` with the map stopped.
NOFIX_GAP_S = 5
NOFIX_LAST_FIX_S = 3

#: Below this the motorcycle is almost stopped and its heading says nothing: the phone
#: fix's heading error is only measured above it.
NOFIX_HEADING_MIN_MPS = 5.0

W_TELEMETRY = re.compile(r"phase (\w+) .* (on route|off) .* fix (\S+)\s*$")
W_HOLE = re.compile(r"fix gap (\d+)s")
W_FIX_BACK = re.compile(r"fix back after (\d+)s")
W_PHONE_START = re.compile(r"phone fix: start, accuracy (\d+)m, age (\d+)ms")
W_PHONE_END = re.compile(r"phone fix: end after (\d+)s, (\d+) fixes")
W_PHONE_WEAK = re.compile(r"phone fix weak: accuracy (\d+)m")
W_POS = re.compile(r"^PONTE:POS:(-?\d+),(-?\d+),([\d.]+),(\d+)\s*$")
W_APPLIED = re.compile(r"^PONTE:FIX:(-?\d+),(-?\d+),(\d+),(\d+),(-?\d+)\s*$")
C_FIX_ON = "PhoneFix: PHONE_FIX on"
C_FIX_SENT = re.compile(r"PhoneFix: PHONE_FIX sent: age (\d+) ms, accuracy (\d+) m"
                        r"(?:, at (-?\d+),(-?\d+) at (\d+) dm/s heading (\S+))?")
C_FIX_NOT_SENT = "PhoneFix: PHONE_FIX not sent"
C_FIX_OFF = re.compile(r"PhoneFix: PHONE_FIX off: (.+), (\d+) fixes in (\d+) s")
C_FIX_UNAVAILABLE = re.compile(r"PhoneFix: PHONE_FIX unavailable: (.*)")
C_SERVICE_TYPE = re.compile(r"NavService: in foreground: pid \d+, type (\S+),")
C_SERVICE_NO_LOCATION = "NavService: without the location type"
C_SERVICE_GONE = "NavService: ended"


def geo_move(lat: float, lon: float, speed_mps: float) -> None:
    """Takes the emulator's GPS to where the motorcycle is, with its speed.

    ``geo fix``: longitude first, then altitude, satellites and knots. **The heading does not go**:
    the command has no such field and the emulator delivers a ``bearing`` near 0° with the motorcycle
    in any direction (measured in C13b: the motorcycle at 234°, the phone saying 0°). ``geo
    nmea`` with GGA + RMC, which would carry the heading, does not move ``pato37``'s GPS (measured: 19
    fixes 270 m from the motorcycle, stopped at the start). The real heading is the hardware's (C16)."""
    ponte.adb("emu", "geo", "fix", f"{lon:.6f}", f"{lat:.6f}", "760", "12", f"{speed_mps * KNOTS_PER_MPS:.1f}",
              check=False)


def metres_apart(lat_e5: int, lon_e5: int, other_lat_e5: int, other_lon_e5: int) -> float:
    """Flat distance between two points in E5; enough for tens of meters."""
    north = (lat_e5 - other_lat_e5) / 1e5 * 111_320
    east = (lon_e5 - other_lon_e5) / 1e5 * 111_320 * math.cos(math.radians(lat_e5 / 1e5))
    return math.hypot(north, east)


def median(values: list[float]) -> float:
    return sorted(values)[len(values) // 2]


def fix_req_on(text: str) -> bool | None:
    """What a relay 0x86 frame asks for: ``True`` turns on, ``False`` turns off, ``None`` is not FIX_REQ."""
    try:
        frame = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError):
        return None
    if len(frame) != 9 or frame[1] != 0x86 or frame[8] > 1:
        return None
    return frame[8] == 1


def judge_no_fix(lines: list[tuple[float, str]], fix_reqs: list[tuple[float, bool]], companion: str,
                  facts: dict, hole_s: int) -> tuple[int, list[str]]:
    """``--no-fix S``, from what both sides wrote: ``(code, report)``. Pure.

    ``lines`` is the watch console with the instant of each line; ``fix_reqs``, the 0x86
    frames that went through the relay; ``facts``, what the run noted: ``hole_at`` (the instant
    of the hole), ``log_mark`` (the phone log's size at that instant), ``applied``
    (each phone fix used: instant, meters from the motorcycle, heading error or ``None``, and its
    ``latE5, lonE5, heading``) and ``pocket`` (the screen and the Activity in view before the hole)."""
    report: list[str] = []
    failures: list[str] = []
    watch = "\n".join(line for _, line in lines)

    hole_at = facts.get("hole_at")
    if hole_at is None:
        report.append("FAILED: the fix hole never started (the route, the corridor or the virtual ride did not get there)")
        if C_MAPBOX_DOWN.search(companion):
            return 2, report + ["External API down: Mapbox did not answer (is the emulator offline?)"]
        return 1, report
    back_at = next((i for i, (t, line) in enumerate(lines) if t > hole_at and W_FIX_BACK.search(line)), None)
    back = lines[back_at][0] if back_at is not None else None
    hole_end = back if back is not None else hole_at + hole_s
    report.append(f"hole: {hole_end - hole_at:.0f} s without the motorcycle's fix, from +{hole_at:.0f} to +{hole_end:.0f} s"
                  + ("" if back is not None else " (no 'fix back after' line: estimated end)"))
    if back is None:
        failures.append("the watch did not write 'fix back after Ns': the hole did not close on its side")

    # The service: it is the `location` type that lets Android deliver position with the screen off.
    types = C_SERVICE_TYPE.findall(companion)
    report.append(f"service: type {types[-1] if types else '?'}"
                  + (" · refused location" if C_SERVICE_NO_LOCATION in companion else ""))
    if not types or types[-1] != "specialUse|location":
        failures.append(f"the foreground service did not come up with the location type (type: {types[-1] if types else 'none'})")
    if C_SERVICE_GONE in companion:
        failures.append("the foreground service ended in the middle of the run")
    ended = C_SESSION_ENDED.search(companion)
    if ended:
        failures.append(f"the phone's session ended: {ended.group(1)}")

    # The pocket: screen off and the app out of it. Without this the run would prove the GPS of an
    # open app, which C7b already proved.
    pocket = facts.get("pocket") or {}
    report.append(f"pocket: screen {pocket.get('wakefulness', '?')} · in view: {pocket.get('resumed') or 'nothing'}")
    if pocket.get("wakefulness") in (None, "Awake"):
        failures.append(f"the screen did not turn off before the hole (mWakefulness={pocket.get('wakefulness')})")
    if PACKAGE in (pocket.get("resumed") or ""):
        failures.append("the app was still in view before the hole: HOME did not take the Activity off the scene")

    # The request: FIX_REQ 1 inside the hole, FIX_REQ 0 after it.
    ons = [t for t, on in fix_reqs if on]
    offs = [t for t, on in fix_reqs if not on]
    report.append("relay: FIX_REQ on at " + (", ".join(f"+{t - hole_at:.0f}s" for t in ons) or "none")
                  + " · off at " + (", ".join(f"+{t - hole_at:.0f}s" for t in offs) or "none")
                  + " (from the start of the hole)")
    if not any(hole_at < t <= hole_end for t in ons):
        failures.append("no turn-on FIX_REQ (0x86, byte 1) went through the relay inside the hole")
    if not any(t > hole_end for t in offs):
        failures.append("no turn-off FIX_REQ (0x86, byte 0) went through the relay after the hole")

    # The phone: it turned on, sent, turned off. Only what is in the log after the hole
    # starts counts: the start (the watch with no own fix until the virtual ride begins) also
    # turns on the phone's GPS, and those fixes prove nothing about the hole.
    mark = facts.get("log_mark", 0)
    episode = companion[mark:]
    before = C_FIX_SENT.findall(companion[:mark])
    if before:
        early = [int(row[0]) for row in before]
        report.append(f"start (before the virtual ride, no verdict): {len(before)} PHONE_FIX sent, "
                      f"age at sending {min(early)}..{max(early)} ms, median {median(early):.0f} ms")
    sent = C_FIX_SENT.findall(episode)
    wanted = (hole_s - 5) / 2
    ages = [int(row[0]) for row in sent]
    report.append(f"phone: {len(sent)} PHONE_FIX sent after the hole started, floor {wanted:.1f}"
                  + (f"; age at sending {min(ages)}..{max(ages)} ms, median {median(ages):.0f} ms" if ages else "")
                  + (f"; {episode.count(C_FIX_NOT_SENT)} did not go out" if C_FIX_NOT_SENT in episode else ""))
    for reason in dict.fromkeys(C_FIX_UNAVAILABLE.findall(companion)):
        report.append(f"phone: PHONE_FIX unavailable: {reason}")
    if C_FIX_ON not in episode:
        failures.append("the phone did not turn the GPS on after the hole started (no 'PHONE_FIX on')")
    if len(sent) < wanted:
        failures.append(f"{len(sent)} PHONE_FIX sent after the hole started, floor {wanted:.1f}")
    off = C_FIX_OFF.findall(episode)
    if off:
        report.append(f"phone: PHONE_FIX off: {off[-1][0]}, {off[-1][1]} fixes in {off[-1][2]} s")
    if not off or off[-1][0] != "the watch dismissed it":
        failures.append("the phone did not turn the GPS off on the watch's order (no 'PHONE_FIX off: the watch dismissed it')")
    with_speed = [row for row in sent if row[4]]
    if with_speed:
        speeds = sorted(int(row[4]) for row in with_speed)
        headings = [row[5] for row in with_speed if row[5] != "?"]
        report.append(f"phone: Fused speed {speeds[0]}..{speeds[-1]} dm/s; "
                      f"heading in {len(headings)} of {len(with_speed)} fixes")

    # The watch: it used the phone fix, early, and stayed on the route with it.
    start = next(((t, m, i) for i, (t, line) in enumerate(lines) if t > hole_at
                  for m in [W_PHONE_START.search(line)] if m), None)
    if start is None:
        failures.append("the watch used no phone fix (no 'phone fix: start')")
        weak = W_PHONE_WEAK.search(watch)
        if weak:
            report.append(f"watch: phone fix refused as inaccurate ({weak.group(1)} m, 40 m cutoff)")
    else:
        took = start[0] - hole_at
        report.append(f"watch: 1st phone fix {took:.1f} s after the start of the hole (ceiling {NOFIX_FIRST_FIX_S} s), "
                      f"accuracy {start[1].group(1)} m, age {start[1].group(2)} ms")
        if took > NOFIX_FIRST_FIX_S:
            failures.append(f"the 1st phone fix took {took:.1f} s, ceiling {NOFIX_FIRST_FIX_S} s")
    end = next((m for t, line in lines if t > hole_at for m in [W_PHONE_END.search(line)] if m), None)
    if end:
        report.append(f"watch: phone fix for {end.group(1)} s, {end.group(2)} fixes used")
    elif start is not None:
        failures.append("the watch did not close the phone episode (no 'phone fix: end')")

    # By line order, not by instant: what the simulator drops together arrives with
    # the same instant, and the telemetry of the second the fix came back already says the own source.
    numbered = [(i, t, m.group(2), m.group(3)) for i, (t, line) in enumerate(lines)
                for m in [W_TELEMETRY.search(line)] if m]
    telemetry = [(t, None, where, source) for _, t, where, source in numbered]
    if start is not None:
        inside = [(t, None, where, source) for i, t, where, source in numbered
                  if i > start[2] and (i < back_at if back_at is not None else t <= hole_end)]
        report.append("telemetry in the hole, after the 1st phone fix: "
                      + (", ".join(f"+{t - hole_at:.0f}s {where} fix {source}" for t, _, where, source in inside) or "none"))
        if not inside:
            failures.append("no telemetry line between the 1st phone fix and the end of the hole")
        for t, _, where, source in inside:
            if source != "phone":
                failures.append(f"telemetry at +{t - hole_at:.0f}s says 'fix {source}', expected 'fix phone'")
            if where != "on route":
                failures.append(f"telemetry at +{t - hole_at:.0f}s says '{where}', expected 'on route'")
    # 6 s: the own fix is valid again right away, but the line that fell in the first second
    # may have been built before it.
    after = [row for row in telemetry if row[0] > hole_end + 6]
    report.append("telemetry after the hole: "
                  + (", ".join(f"+{t - hole_end:.0f}s {where} fix {source}" for t, _, where, source in after) or "none"))
    if not after:
        failures.append("no telemetry line after the hole")
    for t, _, where, source in after:
        if source != NOFIX_OWN_SOURCE:
            failures.append(f"telemetry {t - hole_end:.0f} s after the hole says 'fix {source}', "
                            f"expected 'fix {NOFIX_OWN_SOURCE}' (this build's own source)")
    outs = len(W_OFF_ROUTE.findall(watch))
    if outs:
        failures.append(f"{outs}x 'off route' on the watch: the phone fix took the motorcycle off the route")

    # Is the applied fix the motorcycle's? The position (against the last PONTE:POS line) and the heading.
    applied = [row for row in facts.get("applied") or [] if hole_at < row[0] <= hole_end]
    if applied:
        behind = [row[1] for row in applied]
        report.append(f"fix applied on the watch, {len(applied)} in the hole: {median(behind):.0f} m from the motorcycle at the median, "
                      f"worst {max(behind):.0f} m (median ceiling {NOFIX_BEHIND_M} m)")
        if median(behind) > NOFIX_BEHIND_M:
            failures.append(f"the phone fix was {median(behind):.0f} m from the motorcycle at the median, ceiling {NOFIX_BEHIND_M} m")
        # Did the fallback last the whole hole? Without this, the one that dies in the middle passes.
        times = [row[0] for row in applied]
        widest = max((b - a for a, b in zip(times, times[1:])), default=0.0)
        tail = hole_end - times[-1]
        report.append(f"cadence: largest interval between two applied fixes {widest:.1f} s (ceiling {NOFIX_GAP_S} s), "
                      f"the last one {tail:.1f} s before the end of the hole (ceiling {NOFIX_LAST_FIX_S} s)")
        if len(applied) < wanted:
            failures.append(f"only {len(applied)} phone fixes applied in the hole, floor {wanted:.1f}")
        if widest > NOFIX_GAP_S:
            failures.append(f"{widest:.1f} s between two applied phone fixes, ceiling {NOFIX_GAP_S} s")
        if tail > NOFIX_LAST_FIX_S:
            failures.append(f"the last phone fix was applied {tail:.1f} s before the end of the hole, "
                            f"ceiling {NOFIX_LAST_FIX_S} s: the fallback stopped halfway")
        # The transport: is what the watch used, field by field, what the phone said it
        # sent? (position and heading; `?` in the phone log is the bridge's -1.)
        told = {(int(row[2]), int(row[3]), -1 if row[5] == "?" else int(row[5])) for row in sent if row[2]}
        strangers = [row for row in applied if tuple(row[3:6]) not in told]
        with_heading = sum(1 for row in applied if row[5] >= 0)
        report.append(f"transport: {len(applied) - len(strangers)} of {len(applied)} applied fixes equal "
                      f"(position and heading) to a PHONE_FIX sent; {with_heading} with heading")
        if strangers:
            failures.append(f"{len(strangers)} fix(es) applied on the watch match no PHONE_FIX sent "
                            f"(the 1st: heading {strangers[0][5]}, {strangers[0][1]:.0f} m from the motorcycle)")
        # No judgment: the emulator gives no real heading (see `geo_move`).
        turned = [row[2] for row in applied if row[2] is not None]
        if turned:
            report.append(f"heading against the motorcycle's, no verdict (the emulator gives no heading): error of {median(turned):.0f}° "
                          f"at the median over {len(turned)} fixes with the motorcycle above {NOFIX_HEADING_MIN_MPS:.0f} m/s")
    elif start is not None:
        failures.append("no PONTE:FIX line in the hole: the watch did not say which phone fix it used")

    if "Watchdog Tripped" in watch:
        failures.append("Watchdog Tripped")
    peaks = [int(p) for p in sim.WORK_PEAK.findall(watch)]
    if peaks:
        report.append(f"work peak: {max(peaks)} (ceiling {sim.WORK_CEILING}, {len(peaks)} sample(s))")
        if max(peaks) >= sim.WORK_CEILING:
            failures.append(f"work peak {max(peaks)}, ceiling {sim.WORK_CEILING}")

    if not failures:
        return 0, report
    return 1, report + [f"FAILED: {f}" for f in failures]


def run_no_fix(timeout_s: int, hole_s: int, canary: bool) -> int:
    """C13b: the virtual motorcycle enters a tunnel of ``hole_s`` seconds with the phone in its pocket."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()

    share = Share(*DETOUR_DEST)
    share.text = maps_link(share.label, share.lat, share.lon)
    prepare_device()
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    lines: list[tuple[float, str]] = []
    relayed: dict[str, int] = {}
    fix_reqs: list[tuple[float, bool]] = []
    positions: list[tuple[float, int, int, float, int]] = []
    facts: dict = {"applied": []}
    st = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
          "stage": "share", "mark": 0.0, "cmd_at": None, "settled": None}

    def stage(name: str, elapsed: float) -> None:
        st["stage"] = name
        st["mark"] = elapsed
        st["cmd_at"] = None
        print(f"{elapsed:7.1f}s {name}")

    def seen(pattern, since: float = 0.0) -> bool:
        return any(t >= since and pattern.search(line) for t, line in lines)

    def command(text: str, elapsed: float) -> None:
        ponte.send_command(text)
        st["cmd_at"] = elapsed
        print(f"{elapsed:7.1f}s command {text}")

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if st["started"] is None and ponte.APP_START.match(line):
            st["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            st["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        lines.append((elapsed, line))
        position = W_POS.match(line)
        applied = W_APPLIED.match(line)
        if position:
            # The emulator's GPS moves with the motorcycle: without this the phone fix would say "at
            # the start" and the run would prove a jump, not a fallback.
            lat_e5, lon_e5 = int(position.group(1)), int(position.group(2))
            speed, course = float(position.group(3)), int(position.group(4))
            positions.append((elapsed, lat_e5, lon_e5, speed, course))
            geo_move(lat_e5 / 1e5, lon_e5 / 1e5, speed)
        elif applied and positions:
            # The phone fix the watch just used, against where the motorcycle is now.
            _, lat_e5, lon_e5, speed, course = positions[-1]
            fix_lat, fix_lon, heading = int(applied.group(1)), int(applied.group(2)), int(applied.group(5))
            error = None
            if heading >= 0 and speed >= NOFIX_HEADING_MIN_MPS:
                error = abs((heading - course + 180) % 360 - 180)
            facts["applied"].append((elapsed, metres_apart(fix_lat, fix_lon, lat_e5, lon_e5), error,
                                     fix_lat, fix_lon, heading))
        elif line.strip() == c2r and st["c2r_at"] is None:
            st["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            if ponte.relay(payload):
                kind = tx_kind(payload)
                relayed[kind] = relayed.get(kind, 0) + 1
                on = fix_req_on(payload)
                if on is not None:
                    fix_reqs.append((elapsed, on))
                    print(f"{elapsed:7.1f}s FIX_REQ {'on' if on else 'off'} delivered to the companion")

    def on_idle(elapsed: float) -> bool:
        if st["c2r_at"] is None:
            due = st["next_probe"]
            if due is not None and elapsed >= due:
                st["probes"] += 1
                ponte.send_probe(probe_id)
                st["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        if st["stage"] == "share":
            if share.sent_at is None:
                geo_fix(*ORIGIN)
                share.log_mark = len(companion_log())
                share.sent_at = elapsed
                share.am_output = send_share(share.text)
                print(f"shared ({elapsed:.1f} s): {share.text}")
                return False
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            share.companion = companion_log()[share.log_mark:]
            if C_AWAITING in share.companion and not share.tapped:
                share.tapped = tap_start()
                if share.tapped:
                    print(f"Start tapped ({elapsed:.1f} s)")
                return False
            share.watch = [(t - share.sent_at, line) for t, line in lines]
            if share_finished(share, elapsed):
                stage("corridor settling", elapsed)
            elif C_FAILED.search(share.companion):
                return True
            return False

        if st["stage"] == "corridor settling":
            # A corridor chunk in flight holds the link for about 9 s, and the PHONE_FIX would wait behind it.
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            share.companion = companion_log()[share.log_mark:]
            done = bool(C_CORRIDOR_SENT.search(share.companion)) or C_NO_CORRIDOR in share.companion
            if done and st["settled"] is None:
                st["settled"] = elapsed
            if (st["settled"] is not None and elapsed - st["settled"] > LOD_PARSE_WAIT_S) \
                    or elapsed - st["mark"] > DETOUR_SETTLE_MAX_S:
                stage("virtual ride", elapsed)
            return False

        if st["stage"] == "virtual ride":
            if seen(re.compile(re.escape(W_SIM_START))):
                stage("motorcycle riding", elapsed)
            elif st["cmd_at"] is None or elapsed - st["cmd_at"] > DETOUR_CMD_WAIT_S:
                command("SIM", elapsed)
            return False

        if st["stage"] == "motorcycle riding":
            if positions:
                if elapsed - st["mark"] >= NOFIX_RIDE_S:
                    stage("phone in pocket", elapsed)
                    if canary:
                        # The canary: without the foreground service the phone cannot read the
                        # position with the screen off. The run must exit 1.
                        ponte.adb("shell", "am", "broadcast", "-a", SERVICE_ACTION, "-n", SERVICE_RECEIVER, check=False)
                        print(f"{elapsed:7.1f}s canary: service stop request sent")
                    # Leaves the app and turns the screen off: the process with no Activity in view.
                    ponte.adb("shell", "input", "keyevent", "KEYCODE_HOME", check=False)
                    ponte.adb("shell", "input", "keyevent", "KEYCODE_SLEEP", check=False)
            elif st["cmd_at"] is None or elapsed - st["cmd_at"] > DETOUR_CMD_WAIT_S:
                command("POS", elapsed)
            return False

        if st["stage"] == "phone in pocket":
            if elapsed - st["mark"] < NOFIX_POCKET_S:
                return False
            if seen(W_HOLE, st["mark"]):
                facts["hole_at"] = next(t for t, line in lines if t >= st["mark"] and W_HOLE.search(line))
                # The request to the phone only goes out 5 s later: what is in the log until here is from before.
                facts["log_mark"] = max(len(companion_log()) - share.log_mark, 0)
                stage(f"hole of {hole_s} s", elapsed)
            elif st["cmd_at"] is None or elapsed - st["cmd_at"] > DETOUR_CMD_WAIT_S:
                if "pocket" not in facts:
                    power = ponte.adb("shell", "dumpsys", "power", check=False, timeout=30).stdout
                    awake = re.search(r"mWakefulness=(\w+)", power)
                    activities = ponte.adb("shell", "dumpsys", "activity", "activities", check=False, timeout=30).stdout
                    resumed = re.search(r"topResumedActivity=\S+ \S+ (\S+)", activities)
                    facts["pocket"] = {"wakefulness": awake.group(1) if awake else None,
                                       "resumed": resumed.group(1) if resumed else None}
                command(f"NOFIX:{hole_s}", elapsed)
            return False

        if st["stage"].startswith("hole"):
            if seen(W_FIX_BACK, facts["hole_at"]) or elapsed - facts["hole_at"] > hole_s + 20:
                stage("after the hole", elapsed)
            return False

        # after the hole: the watch dismisses the phone and the telemetry goes back to the own source.
        return elapsed - st["mark"] > NOFIX_AFTER_S

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
        share.companion = companion_log()[share.log_mark:] or share.companion
    finally:
        for args in (("input", "keyevent", "KEYCODE_WAKEUP"), ("am", "force-stop", PACKAGE)):
            ponte.adb("shell", *args, check=False)
        geo_fix(*ORIGIN)
    sim.save(WATCH_LOG, text)
    companion = share.companion
    sim.save(COMPANION_OUT, f"--- {share.label}: {share.am_output}\n{companion}")

    print()
    if st["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if st["c2r_at"] is None:
        print(f"no probe arrived in {st['probes']} attempt(s): the outbound leg is not alive")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    code, report = judge_no_fix(lines, fix_reqs, companion, facts, hole_s)
    for line in report:
        print(f"  {line}")
    name = f"e2e --no-fix {hole_s}" + (" --canary" if canary else "")
    if canary:
        if code == 0:
            # The code has to change along with the text: whoever checks the canary by
            # "must exit 1" would see green on a dead canary.
            print(f"{name}: the canary did NOT bite (exit 0): with the service stopped the judge passed — --no-fix "
                  "is not measuring the phone's GPS")
            return 0
        episode = companion[facts["log_mark"]:] if "log_mark" in facts else ""
        refused = any("location type" in reason for reason in C_FIX_UNAVAILABLE.findall(episode))
        if code == 1 and refused and C_FIX_ON not in episode and not W_PHONE_START.search(
                "\n".join(line for t, line in lines if t > facts["hole_at"])):
            print("canary bit: without the foreground service the companion refuses the request, no phone fix "
                  "arrives and --no-fix fails (exit 1 here is expected)")
            return 1
        print(f"canary inconclusive (exit {code}): the run failed for a reason other than the companion's refusal "
              "without the service; see the failures above")
        return code
    if code == 0:
        print(f"{name}: OK — {hole_s} s without the motorcycle's fix, the watch stayed on the route with the phone's GPS and "
              "dismissed it when the fix came back")
    else:
        print(f"{name}: NO (exit {code}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
    return code


def run_screens() -> int:
    """The phone's three new screens, photographed on ``pato37`` (C8)."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()
    prepare_device()
    problems: list[str] = []

    # 1. Confirmation: a Maps share opens the "Bora" / "Agora não" screen.
    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    geo_fix(*ORIGIN)
    mark = len(companion_log())
    print(f"sharing: {maps_link(*COPAN)}")
    out = send_share(maps_link(*COPAN))
    shown = wait_for(lambda nodes: any(n.get("text") in START_BUTTONS for n in nodes), SCREENS_WAIT_S)
    log = companion_log()[mark:]
    if not shown:
        failed = C_FAILED.search(log)
        print("the confirmation did not appear: " + (failed.group(1).strip() if failed else (out or "no answer from the companion")))
        if C_MAPBOX_DOWN.search(log):
            return 2
        return 1
    time.sleep(1.0)
    error = screencap(SCREEN_SHOTS["confirm"])
    texts = " | ".join(n.get("text", "") for n in ui_nodes() if n.get("text"))
    print(f"c9_confirm: {error or SCREEN_SHOTS['confirm']}\n  screen: {texts}")
    if error:
        problems.append(f"confirm: {error}")
    if "Copan" not in texts:
        problems.append("confirm: the screen does not show the destination's name")
    tap_text("Agora não")
    time.sleep(1.0)

    # 2. Search: types into the main screen's field and waits for Mapbox's result.
    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    geo_fix(*ORIGIN)
    mark = len(companion_log())
    ponte.adb("shell", "am", "start", "-n", MAIN_ACTIVITY)
    field_node = wait_for(
        lambda nodes: next((n for n in nodes if n.get("class", "").endswith("EditText")), None), SCREENS_WAIT_S)
    if not field_node:
        print("the main screen did not show the search field")
        return 1
    if not type_into(field_node, SEARCH_QUERY):
        print(f"could not type {SEARCH_QUERY!r} into the search field (adb input drops keys)")
        return 1

    def has_result(nodes: list[dict[str, str]]) -> bool:
        return any("Copan" in n.get("text", "") and not n.get("class", "").endswith("EditText") for n in nodes)

    if not wait_for(has_result, SCREENS_WAIT_S):
        log = companion_log()[mark:]
        print("the search returned no result in "
              f"{SCREENS_WAIT_S} s; companion log:\n  " + "\n  ".join(log.strip().splitlines()[-6:]))
        return 2 if re.search(r"MapboxGeocoder: (HTTP|no response)", log) else 1
    # The on-screen keyboard would cover half the photo: it only closes if it is open (BACK
    # with it closed would leave the app).
    ime = ponte.adb("shell", "dumpsys", "input_method", check=False, timeout=30).stdout
    if "mInputShown=true" in ime:
        ponte.adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
        time.sleep(1.0)
    time.sleep(0.5)
    error = screencap(SCREEN_SHOTS["search"])
    print(f"c9_search: {error or SCREEN_SHOTS['search']}")
    if error:
        problems.append(f"search: {error}")

    # 3. The watch's settings.
    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    ponte.adb("shell", "am", "start", "-n", MAIN_ACTIVITY)
    # Since 1.2.0 the settings live in the Relógio tab (docs/design/telas.md §5.2).
    if not wait_for(lambda nodes: tap_text("Relógio") or None, SCREENS_WAIT_S):
        print("could not find the «Relógio» tab")
        return 1
    if not wait_for(lambda nodes: tap_text("Ajustes do relógio") or None, SCREENS_WAIT_S):
        print("could not find the «Ajustes do relógio» button on the Relógio tab")
        return 1
    if not wait_for(lambda nodes: any(n.get("text") == "Enviar ao relógio" for n in nodes), SCREENS_WAIT_S):
        print("the settings screen did not open")
        return 1
    time.sleep(0.5)
    error = screencap(SCREEN_SHOTS["settings"])
    print(f"c9_settings: {error or SCREEN_SHOTS['settings']}")
    if error:
        problems.append(f"settings: {error}")

    # 4. Favorites (C12): the three public test places, listed on the screen.
    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    ponte.adb("shell", "am", "start", "-n", MAIN_ACTIVITY)
    # In 1.2.0 the Favoritos section of Início opens editing through "Editar".
    if not wait_for(lambda nodes: any(n.get("text") == "Editar" for n in nodes) or None, SCREENS_WAIT_S):
        print("Início did not show the favorites' «Editar»")
        return 1
    ponte.adb("shell", "am", "broadcast", "-a", FAVORITES_ACTION, "-n", FAVORITES_RECEIVER, check=False)
    time.sleep(1.5)
    if not tap_text("Editar"):
        print("could not tap «Editar»")
        return 1
    if not wait_for(lambda nodes: any(n.get("text") in ("Adicionar favorito", "Voltar") for n in nodes) or None,
                    SCREENS_WAIT_S):
        print("the favorites screen did not open")
        return 1
    time.sleep(0.5)
    error = screencap(SCREEN_SHOTS["favorites"])
    texts = " | ".join(n.get("text", "") for n in ui_nodes() if n.get("text"))
    print(f"c12_favorites: {error or SCREEN_SHOTS['favorites']}\n  screen: {texts}")
    if error:
        problems.append(f"favorites: {error}")
    for name, _lat, _lon in FAVORITE_PLACES:
        if name not in texts:
            problems.append(f"favorites: the screen does not list {name}")

    # Only our package, as at the end of `run`: pato37 is shared with another project.
    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    if problems:
        print("e2e --screens: NO (exit 1) — " + "; ".join(problems))
        return 1
    print("e2e --screens: OK — " + ", ".join(str(p) for p in SCREEN_SHOTS.values()))
    return 0


#: The receiver that writes the three public test places into the companion and sends them to the
#: watch (``FavoritesReceiver``, ``sim`` variant, C12).
FAVORITES_ACTION = "dev.igor.motonav.sim.FAVORITES"
FAVORITES_RECEIVER = f"{PACKAGE}/dev.igor.motonav.sim.FavoritesReceiver"

#: The favorites the receiver writes, in the order the watch lists them: public places,
#: never an address of Igor's (same names as the ``favorites_00.bin`` fixture).
FAVORITE_PLACES = [
    COPAN,
    ("MASP", -23.561414, -46.655881),
    ("Praça da Sé", -23.550520, -46.633309),
]

#: Seconds for a key to take effect on the watch before repeating (or switching method).
FAVORITE_KEY_WAIT_S = 8

#: From the tap on the favorite to the complete route on the watch. ``--detour`` measured 0.9 to 2.5 s for the
#: recalculation and F1, 7 s for the POLY; 90 s covers Mapbox and the corridor without hiding a hang.
FAVORITE_ROUTE_WAIT_S = 90

W_FAV_APPLIED = re.compile(rf"favorites {len(FAVORITE_PLACES)} applied")
W_FAV_OPENED = re.compile(r"favorites opened: (\d+)")
W_FAV_REQ = re.compile(r"nav start req fav (\d+)")
C_NAV_START = re.compile(r"WatchLink: NAV_START_REQ favId (\d+)")
C_FAV_SENT = re.compile(r"FavoriteNavigator: route (\d+) of favorite (\d+) (sent|NOT sent) in (\d+) ms")


def judge_favorite(watch: str, relayed: dict[str, int], companion: str, index: int) -> tuple[int, list[str]]:
    """``--favorite N``, from what both sides wrote: ``(code, report)``. Pure."""
    report: list[str] = []
    failures: list[str] = []
    place = FAVORITE_PLACES[index - 1]

    applied = W_FAV_APPLIED.findall(watch)
    report.append(f"watch: favorites applied: {applied or 'none'} (expected {len(FAVORITE_PLACES)})")
    if not applied:
        failures.append(f"the watch did not apply the phone's {len(FAVORITE_PLACES)} favorites")

    opened = W_FAV_OPENED.findall(watch)
    report.append(f"watch: Favorites screen open (PONTE:CMD:FAV:OPEN) with {opened[-1] if opened else '?'} items")
    if not opened:
        failures.append("the Favorites screen did not open (did the FAV:OPEN command not reach the watch?)")

    asked = relayed.get("0x83", 0)
    report.append(f"relay: {asked} NAV_START_REQ (0x83) from the watch, expected 1; "
                  + (", ".join(f"{n} {kind}" for kind, n in sorted(relayed.items())) or "nothing"))
    if asked != 1:
        failures.append(f"{asked} 0x83 frames, expected exactly 1")

    watch_ids = W_FAV_REQ.findall(watch)
    companion_ids = C_NAV_START.findall(companion)
    report.append(f"favId: watch asked for {watch_ids or 'none'}, companion received {companion_ids or 'none'}")
    # the companion log grows between runs: the last request is what counts, as in sent[-1] and dest[-1]
    if len(watch_ids) != 1 or companion_ids[-1:] != watch_ids:
        failures.append("the favId the watch sent is not the one the companion received")

    sent = C_FAV_SENT.findall(companion)
    if sent:
        route_id, fav_id, outcome, ms = sent[-1]
        report.append(f"companion: route {route_id} of favorite {fav_id} {outcome} in {ms} ms")
        if outcome != "sent" or (watch_ids and fav_id != watch_ids[0]):
            failures.append("the favorite's route was not sent, or it is another favorite's")
    else:
        failures.append("the companion sent no route for the favorite")

    dest = C_DEST.findall(companion)
    if dest:
        d_lat, d_lon = float(dest[-1][2]), float(dest[-1][3])
        report.append(f"destination asked of Mapbox: {d_lat:.6f},{d_lon:.6f} (expected {place[0]})")
        if abs(d_lat - place[1]) > DEST_TOLERANCE_DEG or abs(d_lon - place[2]) > DEST_TOLERANCE_DEG:
            failures.append(f"the destination is not favorite {index} ({place[0]})")
    else:
        failures.append("the companion did not ask Mapbox for a route")

    poly = POLY_LINE.search(watch)
    complete = COMPLETE_LINE.search(watch)
    report.append(f"watch: poly {'route ' + poly.group(1) if poly else 'NO'}, "
                  f"complete route {complete.group(0) if complete else 'NO'}, "
                  f"{MAP_ON if MAP_ON in watch else 'no map'}")
    if not poly or not complete or MAP_ON not in watch:
        failures.append("the complete route did not reach the watch with the map")
    if "Watchdog Tripped" in watch:
        failures.append("Watchdog Tripped")

    if not failures:
        return 0, report
    report += [f"FAILED: {f}" for f in failures]
    if C_MAPBOX_DOWN.search(companion) and not complete:
        return 2, report + ["External API down: Mapbox did not answer (is the emulator offline?)"]
    return 1, report


def run_favorite(timeout_s: int, index: int) -> int:
    """The whole RF-02 on the PC (C12): phone favorites -> Favorites screen on the watch, through the
    keys -> ``NAV_START_REQ`` -> complete route."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()
    prepare_device()
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    lines: list[tuple[float, str]] = []
    relayed: dict[str, int] = {}
    st = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
          "stage": "seed", "mark": 0.0, "acted_at": None, "attempts": 0, "mode": "post", "downs": 0,
          "log_mark": 0, "companion": ""}

    def stage(name: str, elapsed: float) -> None:
        st["stage"] = name
        st["mark"] = elapsed
        st["acted_at"] = None
        st["attempts"] = 0
        print(f"{elapsed:7.1f}s {name}")

    def watch_text() -> str:
        return "\n".join(line for _, line in lines)

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if st["started"] is None and ponte.APP_START.match(line):
            st["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            st["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        lines.append((elapsed, line))
        if line.strip() == c2r and st["c2r_at"] is None:
            st["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            if ponte.relay(payload):
                kind = tx_kind(payload)
                relayed[kind] = relayed.get(kind, 0) + 1
                if kind == "0x83":
                    print(f"{elapsed:7.1f}s NAV_START_REQ delivered to the companion")

    def command(text: str, elapsed: float) -> None:
        ponte.send_command(text)
        st["acted_at"] = elapsed
        print(f"{elapsed:7.1f}s command {text}")

    def key_due(elapsed: float, wait_s: float = FAVORITE_KEY_WAIT_S) -> bool:
        return st["acted_at"] is None or elapsed - st["acted_at"] > wait_s

    def on_idle(elapsed: float) -> bool:
        if st["c2r_at"] is None:
            due = st["next_probe"]
            if due is not None and elapsed >= due:
                st["probes"] += 1
                ponte.send_probe(probe_id)
                st["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        text = watch_text()

        if st["stage"] == "seed":
            if W_FAV_APPLIED.search(text):
                stage("open", elapsed)
            elif key_due(elapsed, 20):
                if st["attempts"] >= 3:
                    print(f"{elapsed:7.1f}s the watch did not apply the favorites in 3 attempts: stopping")
                    return True
                geo_fix(*ORIGIN)
                if not st["log_mark"]:
                    st["log_mark"] = len(companion_log())
                ponte.adb("shell", "am", "broadcast", "-a", FAVORITES_ACTION, "-n", FAVORITES_RECEIVER, check=False)
                st["acted_at"] = elapsed
                st["attempts"] += 1
                print(f"{elapsed:7.1f}s test favorites sent to the watch (attempt {st['attempts']})")
            return False

        if st["stage"] == "open":
            if W_FAV_OPENED.search(text):
                stage("pick", elapsed)
            elif key_due(elapsed):
                if st["attempts"] >= 4:
                    print(f"{elapsed:7.1f}s the Favorites screen did not open in 4 commands: stopping")
                    return True
                command("FAV:OPEN", elapsed)
                st["attempts"] += 1
            return False

        if st["stage"] == "pick":
            if W_FAV_REQ.search(text):
                stage("route", elapsed)
            elif key_due(elapsed, 1.0 if st["attempts"] == 0 else FAVORITE_KEY_WAIT_S):
                if st["attempts"] >= 3:
                    print(f"{elapsed:7.1f}s the favorite did not ask for a route in 3 commands: stopping")
                    return True
                command(f"FAV:PICK:{index}", elapsed)
                st["attempts"] += 1
            return False

        # route: the favorite's whole route on the watch, with the map.
        if elapsed - st["mark"] > FAVORITE_ROUTE_WAIT_S:
            print(f"{elapsed:7.1f}s the favorite's route did not arrive in {FAVORITE_ROUTE_WAIT_S} s: stopping")
            return True
        if elapsed < st["next_log"]:
            return False
        st["next_log"] = elapsed + LOG_EVERY_S
        st["companion"] = companion_log()[st["log_mark"]:]
        if C_FAILED.search(st["companion"]):
            return True
        return (COMPLETE_LINE.search(text) is not None and MAP_ON in text
                and C_FAV_SENT.search(st["companion"]) is not None)

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
    finally:
        st["companion"] = companion_log()[st["log_mark"]:]
        ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    sim.save(WATCH_LOG, text)
    sim.save(COMPANION_OUT, st["companion"])

    print()
    if st["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if st["c2r_at"] is None:
        print(f"no probe arrived in {st['probes']} attempt(s): the outbound leg is not alive")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    code, report = judge_favorite(to_english(text), relayed, st["companion"], index)
    for line in report:
        print(f"  {line}")
    if code == 0:
        print(f"e2e --favorite {index}: OK — favorites on the watch, picked by the bridge command, NAV_START_REQ in the "
              "companion and the complete route with the map")
    else:
        print(f"e2e --favorite {index}: NO (exit {code}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
    return code


#: The ``ROUTE_UPDATE`` pace, in seconds: ``RerouteController.ETA_REFRESH_MS``.
ETA_EVERY_S = 600

#: How far the interval between two ``ROUTE_UPDATE``s may stray from 600 s. The phone's loop
#: ticks on a fixed grid, so what varies is each tick's Mapbox query, which has a ceiling
#: of 30 s (``RerouteController.ETA_ROUTE_TIMEOUT_MS``): two queries, one at each end.
ETA_TOLERANCE_S = 60

#: How often ``--doze`` asks the emulator for the doze state and reads the companion
#: log. Half of ``ETA_TOLERANCE_S``: each update gets a sample on each side
#: within the tolerance.
DOZE_SAMPLE_S = 30

#: Deadline of each ``adb`` inside doze. Readings from 2026-10-09 on came back in
#: under 1 s; 20 s separates "slow" from "adb hung" without holding up the console relay.
DOZE_ADB_TIMEOUT_S = 20

SERVICE_ACTION = "dev.igor.motonav.sim.STOP_NAV_SERVICE"
SERVICE_RECEIVER = f"{PACKAGE}/dev.igor.motonav.sim.ServiceReceiver"
WAKE_LOCK_TAG = "motonav:nav"

W_ETA = re.compile(r"eta route (\d+): (\d+) -> (\d+) s")
W_ETA_REFUSED = re.compile(r"eta refused route (\d+): (.*)")
C_ETA_DELIVERED = re.compile(r"ROUTE_UPDATE route (\d+) delivered: (\d+) -> (\d+) s \(dist (\d+) -> (\d+) m\)")
C_ETA_MISSED = re.compile(r"RerouteController: (ROUTE_UPDATE route \d+ (?:not delivered|no new duration|skipped|kept)[^\n]*)")
C_SESSION_ENDED = re.compile(r"RerouteController: (session ended[^\n]*)")
C_SERVICE_RESTARTED = "restarted by the system"


def doze_wanted(minutes: int) -> int:
    """How many ``ROUTE_UPDATE``s the period must have. The route reaches the watch before
    doze, and the first tick is 10 min after it: in ``minutes`` of doze fit
    ``minutes // 10`` ticks. One is slack for the ends of the period. Gives the numbers from
    ``docs/ROADMAP.md`` §C13a: 1 in 10 min, 5 in 60."""
    return max(1, minutes // 10 - 1)


def fresh_etas(etas: list[tuple[float, int, int]], delivered: list[tuple[int, int]]) -> list[tuple[float, int, int]]:
    """The watch's ``eta route`` lines that carried a **new Mapbox duration**.

    Without a Mapbox response the phone resends the duration the watch already has, just to
    know whether it is still navigating: the watch logs ``eta route`` the same way, and that does not prove
    network. The phone is the one who knows the difference (``ROUTE_UPDATE route N delivered: A -> B s``).
    Matches the two lists in order, by ``(routeId, new duration)``; ``delivered`` are those
    pairs, from the phone log.
    """
    fresh: list[tuple[float, int, int]] = []
    pending = list(delivered)
    for at, route_id, seconds in etas:
        if pending and pending[0] == (route_id, seconds):
            pending.pop(0)
            fresh.append((at, route_id, seconds))
    return fresh


def state_around(samples: list[tuple[float, str]], at: float) -> tuple[str | None, str | None]:
    """The doze state sampled right before and right after ``at``."""
    before = [state for t, state in samples if t <= at]
    after = [state for t, state in samples if t >= at]
    return (before[-1] if before else None, after[0] if after else None)


def judge_doze(etas: list[tuple[float, int, int]], refused: list[str], samples: list[tuple[float, str]],
               companion: str, facts: dict, minutes: int) -> tuple[int, list[str]]:
    """``--doze``, from what both sides and the emulator said: ``(code, report)``. Pure.

    ``etas`` are the watch console's ``eta route N``, ``(seconds, routeId, new duration)``; ``samples``,
    the ``deviceidle get deep`` every ``DOZE_SAMPLE_S``; ``facts``, the rest of what the emulator
    said (``service``: ``(seconds, isForeground, wake lock line)`` per sample).
    """
    report: list[str] = []
    failures: list[str] = []
    wanted = doze_wanted(minutes)
    start, end = facts.get("doze_at"), facts.get("doze_end")

    if start is None or end is None:
        report.append("FAILED: the route did not reach the watch, doze never started")
        if C_MAPBOX_DOWN.search(companion):
            return 2, report + ["External API down: Mapbox did not answer before doze"]
        return 1, report

    in_window = [state for t, state in samples if start <= t <= end]
    idle = in_window.count("IDLE")
    others = sorted({state for state in in_window if state != "IDLE"})
    report.append(f"doze: {idle} of {len(in_window)} samples in IDLE"
                  + (f"; also {', '.join(others)}" if others else "")
                  + f" (force-idle: {facts.get('force_idle') or 'no answer'})")
    if idle == 0:
        failures.append("the emulator was in IDLE in no sample: the test measured nothing")

    if facts.get("allowlisted") is not False:
        failures.append("the app is exempt from battery optimization (or the list could not be read): the proof is "
                        "the service's, and with the exemption it proves nothing")
    else:
        report.append("battery exemption: no (the app is off the deviceidle list)")

    delivered = C_ETA_DELIVERED.findall(companion)
    fresh = fresh_etas(etas, [(int(route), int(new)) for route, _, new, _, _ in delivered])
    repeats = len(etas) - len(fresh)
    counted: list[float] = []
    in_period: list[float] = []
    for at, route_id, seconds in fresh:
        if not start <= at <= end:
            report.append(f"eta route {route_id} at {at:.0f} s: outside the doze period, does not count")
            continue
        in_period.append(at)
        before, after = state_around(samples, at)
        if before == "IDLE" and after == "IDLE":
            counted.append(at)
            report.append(f"eta route {route_id} ({seconds} s) at {at - start:.0f} s of doze, in IDLE")
        else:
            report.append(f"eta route {route_id} at {at - start:.0f} s of doze: state {before} -> {after}, does not count")
    report.append(f"watch: {len(counted)} ROUTE_UPDATE with a new duration applied in IDLE, expected at least "
                  f"{wanted} in {minutes} min"
                  + (f"; plus {repeats} with no new duration (the phone only queried the watch)" if repeats else ""))
    if len(counted) < wanted:
        failures.append(f"{len(counted)} ROUTE_UPDATE with a new duration on the watch in doze, expected at least {wanted}")
    # The pace covers all those that arrived in the period: one that the neighboring sample did not let
    # count as "in IDLE" cannot turn into a 1,200 s hole.
    for a, b in zip(in_period, in_period[1:]):
        if abs((b - a) - ETA_EVERY_S) > ETA_TOLERANCE_S:
            failures.append(f"interval of {b - a:.0f} s between two ROUTE_UPDATEs, expected "
                            f"{ETA_EVERY_S} ± {ETA_TOLERANCE_S} s")

    report.append(f"phone: {len(delivered)} ROUTE_UPDATE delivered"
                  + "".join(f"; {old} -> {new} s (dist {d0} -> {d1} m)" for _, old, new, d0, d1 in delivered))
    if len(delivered) > len(fresh):
        failures.append(f"the phone reported {len(delivered)} delivered and the watch only shows {len(fresh)}: "
                        "the two logs do not match")
    slowest = facts.get("slowest_sample_s")
    if slowest is not None:
        # The console relay waits for the sample to finish; past the phone's ACK deadline
        # (`ACK_TIMEOUT_MS`, 8 s), a lost ACK is the test's, not the service's.
        report.append(f"slowest emulator sample: {slowest:.1f} s")
    for line in C_ETA_MISSED.findall(companion):
        report.append(f"phone: {line}")
    for line in refused:
        failures.append(f"the watch refused an update: {line}")
    for line in C_SESSION_ENDED.findall(companion):
        failures.append(f"the phone ended navigation midway: {line}")

    restarts = len(C_SESSION.findall(companion))
    if restarts:
        failures.append(f"{restarts} new companion process(es) after the share")
    if C_SERVICE_RESTARTED in companion:
        failures.append("the service was restarted by the system")
    before, after = facts.get("pid_before"), facts.get("pid_after")
    report.append(f"process: pid {before or '?'} before doze, {after or 'none'} at the end")
    if not before or before != after:
        failures.append("the companion process is not the same from the start to the end of doze")

    service = [(fg, lock) for t, fg, lock in facts.get("service", []) if start <= t <= end]
    foreground = sum(1 for fg, _ in service if fg)
    held = [lock for _, lock in service if lock and "DISABLED" not in lock]
    disabled = [lock for _, lock in service if lock and "DISABLED" in lock]
    report.append(f"foreground service in {foreground} of {len(service)} samples; "
                  f"wake lock {WAKE_LOCK_TAG} held in {len(held)}"
                  + (f": {held[-1]}" if held else ""))
    if not service or foreground < len(service):
        failures.append(f"the companion had a foreground service in only {foreground} of {len(service)} "
                        "doze samples")
    if disabled:
        failures.append(f"the wake lock {WAKE_LOCK_TAG} was disabled by doze in {len(disabled)} sample(s): "
                        f"{disabled[0]}")
    if not service or len(held) + len(disabled) < len(service):
        failures.append(f"the wake lock {WAKE_LOCK_TAG} was missing from dumpsys power in "
                        f"{len(service) - len(held) - len(disabled)} of {len(service)} samples")

    if not failures:
        return 0, report
    # Mapbox down *inside* doze is what the test measures (network cut): 1, not 2.
    return 1, report + [f"FAILED: {f}" for f in failures]


def keep_pc_awake(on: bool) -> None:
    """One hour without a keyboard: Windows cannot sleep in the middle (``SetThreadExecutionState``)."""
    if os.name != "nt":
        return
    import ctypes
    es_continuous, es_system_required = 0x80000000, 0x00000001
    ctypes.windll.kernel32.SetThreadExecutionState(es_continuous | (es_system_required if on else 0))


def doze_shell(*args: str) -> str | None:
    """An ``adb shell`` inside doze. ``None`` if adb did not answer: ``ponte.adb``
    throws ``TimeoutExpired`` even with ``check=False``, and that cannot bring down the run."""
    try:
        result = ponte.adb("shell", *args, check=False, timeout=DOZE_ADB_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def run_doze(timeout_s: int, minutes: int, canary: bool) -> int:
    """C13a: the route goes to the watch, the phone leaves the app, turns the screen off and enters forced
    doze, unplugged, for ``minutes`` minutes. The ``ROUTE_UPDATE``s must keep coming."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()

    share = Share(*DETOUR_DEST)
    share.text = maps_link(share.label, share.lat, share.lon)
    prepare_device()
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    lines: list[tuple[float, str]] = []
    relayed: dict[str, int] = {}
    samples: list[tuple[float, str]] = []
    etas: list[tuple[float, int, int]] = []
    refused: list[str] = []
    facts: dict = {}
    st = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
          "next_sample": 0.0, "relay_lost": 0}

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if st["started"] is None and ponte.APP_START.match(line):
            st["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            st["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        lines.append((elapsed, line))
        eta = W_ETA.search(line)
        if eta:
            etas.append((elapsed, int(eta.group(1)), int(eta.group(3))))
            print(f"{elapsed:7.1f}s watch: {eta.group(0)}")
        no = W_ETA_REFUSED.search(line)
        if no:
            refused.append(no.group(0))
            print(f"{elapsed:7.1f}s watch: {no.group(0)}")
        if line.strip() == c2r and st["c2r_at"] is None:
            st["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            try:
                ok = ponte.relay(payload)
            except subprocess.TimeoutExpired:
                ok = False
            if ok:
                kind = tx_kind(payload)
                relayed[kind] = relayed.get(kind, 0) + 1
            else:
                st["relay_lost"] += 1

    def enter_doze(elapsed: float) -> None:
        facts["pid_before"] = doze_shell("pidof", PACKAGE)
        if canary:
            # The canary: the service is stopped before doze. Without it the run must exit 1.
            doze_shell("am", "broadcast", "-a", SERVICE_ACTION, "-n", SERVICE_RECEIVER)
            print(f"{elapsed:7.1f}s canary: service stop request sent")
        allowlist = doze_shell("dumpsys", "deviceidle", "whitelist")
        facts["allowlisted"] = None if allowlist is None else PACKAGE in allowlist
        # Leaves the app and turns the screen off, like the phone in a pocket: it is the harshest case, the
        # process with no Activity in view.
        doze_shell("input", "keyevent", "KEYCODE_HOME")
        doze_shell("input", "keyevent", "KEYCODE_SLEEP")
        doze_shell("dumpsys", "battery", "unplug")
        doze_shell("dumpsys", "deviceidle", "enable")
        facts["force_idle"] = doze_shell("dumpsys", "deviceidle", "force-idle")
        facts["doze_at"] = elapsed
        # The route reached the watch before this instant (the corridor's time), and the tick goes out
        # 600 s after it plus the Mapbox query: without the tolerance slack, with a fast
        # corridor and a slow Mapbox the only update of the 10 min would fall outside the period.
        facts["doze_end"] = elapsed + minutes * 60 + ETA_TOLERANCE_S
        st["next_sample"] = elapsed
        print(f"{elapsed:7.1f}s doze forced for {minutes} min + {ETA_TOLERANCE_S} s: {facts['force_idle']}")

    def sample(elapsed: float) -> None:
        began = time.monotonic()
        state = doze_shell("dumpsys", "deviceidle", "get", "deep") or "no answer"
        samples.append((elapsed, state))
        log = None
        try:
            log = companion_log()
        except subprocess.TimeoutExpired:
            pass
        if log:
            share.companion = log[share.log_mark:]
        services = doze_shell("dumpsys", "activity", "services", PACKAGE)
        power = doze_shell("dumpsys", "power")
        if services is not None and power is not None:
            lock = next((row.strip() for row in power.splitlines() if WAKE_LOCK_TAG in row and "WAKE_LOCK" in row),
                        None)
            facts.setdefault("service", []).append((elapsed, "isForeground=true" in services, lock))
        facts["slowest_sample_s"] = max(facts.get("slowest_sample_s", 0.0), time.monotonic() - began)
        in_doze = elapsed - facts["doze_at"]
        print(f"{elapsed:7.1f}s doze {in_doze:5.0f}/{minutes * 60 + ETA_TOLERANCE_S} s: {state}; {len(etas)} eta on the watch, "
              f"{len(C_ETA_DELIVERED.findall(share.companion))} delivered on the phone")

    def on_idle(elapsed: float) -> bool:
        if st["c2r_at"] is None:
            due = st["next_probe"]
            if due is not None and elapsed >= due:
                st["probes"] += 1
                ponte.send_probe(probe_id)
                st["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        if "doze_at" in facts:
            if elapsed >= facts["doze_end"]:
                sample(elapsed)
                facts["pid_after"] = doze_shell("pidof", PACKAGE)
                return True
            if elapsed >= st["next_sample"]:
                st["next_sample"] = elapsed + DOZE_SAMPLE_S
                sample(elapsed)
            return False
        if share.sent_at is None:
            geo_fix(*ORIGIN)
            share.log_mark = len(companion_log())
            share.sent_at = elapsed
            share.am_output = send_share(share.text)
            print(f"shared ({elapsed:.1f} s): {share.text}")
            return False
        if elapsed < st["next_log"]:
            return False
        st["next_log"] = elapsed + LOG_EVERY_S
        share.companion = companion_log()[share.log_mark:]
        if C_AWAITING in share.companion and not share.tapped:
            share.tapped = tap_start()
            if share.tapped:
                print(f"Start tapped ({elapsed:.1f} s)")
            return False
        share.watch = [(t - share.sent_at, line) for t, line in lines]
        if not share_finished(share, elapsed):
            return False
        total = C_TOTAL.search(share.companion)
        if total is None or total.group(2):
            print(f"{elapsed:7.1f}s the route did not reach the watch: no doze")
            return True
        enter_doze(elapsed)
        return False

    keep_pc_awake(True)
    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
        try:
            share.companion = companion_log()[share.log_mark:] or share.companion
        except subprocess.TimeoutExpired:
            pass
    finally:
        leave_doze()
        keep_pc_awake(False)
        for args in (("input", "keyevent", "KEYCODE_WAKEUP"), ("am", "force-stop", PACKAGE)):
            doze_shell(*args)
    sim.save(WATCH_LOG, text)
    companion = share.companion
    sim.save(COMPANION_OUT, f"--- {share.label}: {share.am_output}\n{companion}")

    print()
    if st["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if st["c2r_at"] is None:
        print(f"no probe arrived in {st['probes']} attempt(s): the outbound leg is not alive")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")
    if st["relay_lost"]:
        print(f"relay: {st['relay_lost']} watch line(s) not delivered to the companion (adb did not answer)")

    code, report = judge_doze(etas, refused, samples, companion, facts, minutes)
    for line in report:
        print(f"  {line}")
    name = f"e2e --doze {minutes}" + (" --canary" if canary else "")
    if code == 0:
        print(f"{name}: OK — {minutes} min of forced doze unplugged, ROUTE_UPDATE on pace, "
              "the same process from start to end")
    else:
        print(f"{name}: NO (exit {code}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
    return code


#: Deadline for the ``TokenReceiver`` confirmation in ``motonav.log``. In the runs of
#: 2026-10-09 the line was already there on the first or second read (0.5 s
#: each); 10 s is slack for the cold process right after ``install``.
TOKEN_WAIT_S = 10

#: How long to wait for the companion to write the first line of the share
#: (``shared:`` or ``failed:``) before concluding it did not move.
#: Measured on 2026-10-09: the line appeared within 0.4 s of ``am start``; 20 s is
#: slack for a cold process, and is what ``--double`` waits before saying
#: the second share did not move.
SHARE_START_WAIT_S = 20

#: After the companion says it delivered the corridor, how long to wait for the
#: watch to finish reading the sliced LODs. ``CorridorParseJob`` reads 450
#: points per 1 s tick and the largest LOD of the 2026-10-09 runs had 1,354
#: points (4 ticks); 30 s covers the four LODs in a row with slack.
LOD_PARSE_WAIT_S = 30

#: After the corridor, how long to wait for the radars' verdict (C16.6): the waits of
#: ``RerouteController.RADAR_RETRY_MS`` (25 + 60 + 120 s) and the deadline of the four queries,
#: rounded. With Overpass healthy, the radars arrive seconds after the corridor.
RADAR_WAIT_S = 300

#: Deadline of the whole run after ``monkeydo``, per share. Measured
#: on 2026-10-09 on the Windows dev PC, on the old test route (790 pts, corridor of 2,600
#: segments): from ``am start`` to the last LOD, 76 s in one run and 131 s in another.
#: The difference is Overpass (7.6 s and 62 s); the corridor transfer took
#: ~52 s in both, because the SDK simulates BLE by sleeping ``len/600`` s per
#: message (4,096 B chunk: 9.0 s). 300 s is a little over double the worst.
DEFAULT_TIMEOUT_S = 300

#: How long to wait for each ``--screens`` screen to appear. The confirmation needs the
#: location fix and, for free, the Mapbox address (3 s in the app); the search
#: waits for the 300 ms debounce and Mapbox. None of that went past ~10 s on the Windows dev PC.
SCREENS_WAIT_S = 45


# --- C14: F4's stress ride (--stress) -------------------------------------

#: How many detours the ride makes with the companion alive (``docs/07-ROADMAP.md`` §F4: "miss 3 turns").
STRESS_DETOURS = 3

#: The favorite that starts navigation: 1 is Copan, a public place.
STRESS_FAVORITE = 1

#: Where the motorcycle starts: Parque Ibirapuera, ~5.5 km from Copan. From the start of the old test route
#: the route would be 14 km and the ``adb`` relay (one broadcast per chunk) spent 7.4 to 9.7 s per recalculation
#: in the first run (2026-10-14); ``--detour`` measured 1.8 to 2.4 s with 5 km (C11). The 10 s
#: deadline is the recalculation's, not the PC relay's.
STRESS_ORIGIN = (-23.587416, -46.657634)

#: ``route swapped A -> B in N ms`` or, when the rider is already back on the route before the whole new one
#: arrives (``back on route`` zeroes the request), ``route swapped A -> B unrequested``.
W_SWAP_ANY = re.compile(r"\[diag\] (\d+)s route swapped (\d+) -> (\d+)(?: in (\d+) ms| unrequested)")
W_REQ_AT = re.compile(r"\[diag\] (\d+)s reroute req ")

#: After the companion is dead: the watch has to stay up for this long, with telemetry and
#: warning. 10 s of ``OffRoute.NO_PHONE_MS`` + one telemetry line every 10 s, with slack.
STRESS_AFTER_S = 30

#: How long to wait for a turn warned with the companion dead and the motorcycle on the route: ~25 s between
#: maneuvers in the 4x ride (SP's ``ride --speed 4``) with slack.
STRESS_CURVE_WAIT_S = 120

#: How long the fourth detour lasts (``DETOUR:<m>:<s>``): 10 s of ``OffRoute.NO_PHONE_MS`` plus the 5 s
#: window and slack, so the "recalculation needs the phone" goes out before the motorcycle returns.
STRESS_DETOUR_S = 25

#: The fourth detour is the one that catches the dead companion; the line the watch prints on receiving it.
W_CMD_DETOUR = "PONTE:CMD:DETOUR:"
W_NEEDS_PHONE = "recalculation needs the phone"
W_CURVE = re.compile(r"vibe turn \d+ alert")


def judge_stress(lines: list[tuple[float, str]], relayed: dict[str, int], companion: str,
                   killed_at: float | None, dead: bool, unanswered: int) -> tuple[int, list[str]]:
    """The stress ride, from what both sides wrote: ``(code, report)``. Pure.

    ``lines`` are the watch lines with the instant of each; ``killed_at`` is the instant
    the companion was terminated and ``dead`` says ``pidof`` did not find it afterwards."""
    watch = "\n".join(line for _, line in lines)
    report: list[str] = []
    failures: list[str] = []
    place = FAVORITE_PLACES[STRESS_FAVORITE - 1]

    asked = relayed.get("0x83", 0)
    ids = W_FAV_REQ.findall(watch)
    sent = C_FAV_SENT.findall(companion)
    report.append(f"navigation by favorite: {asked} NAV_START_REQ (0x83), favId {ids or 'none'}, "
                  f"route {'sent' if sent and sent[-1][2] == 'sent' else 'NOT sent'}")
    if asked != 1 or len(ids) != 1 or not sent or sent[-1][2] != "sent":
        failures.append("navigation was not started by a favorite NAV_START_REQ with the route sent")
    # The companion log grows between runs: the last Mapbox request is what counts (the destination is the same
    # on the favorite's route and on the recalculations).
    dest = C_DEST.findall(companion)
    if dest and (abs(float(dest[-1][2]) - place[1]) > DEST_TOLERANCE_DEG
                 or abs(float(dest[-1][3]) - place[2]) > DEST_TOLERANCE_DEG):
        failures.append(f"the route's destination is not favorite {STRESS_FAVORITE} ({place[0]})")

    frames = relayed.get("0x82", 0)
    outs = len(W_OFF_ROUTE.findall(watch))
    report.append(f"recalculations: {frames} REROUTE_REQ (0x82) delivered, {outs}x off route "
                  f"(expected {STRESS_DETOURS} + at least 1 without the phone)")
    if frames != STRESS_DETOURS:
        failures.append(f"{frames} 0x82 frames delivered to the companion, expected exactly {STRESS_DETOURS}")
    # ``>=``: with no companion the virtual motorcycle may return to the route for a second and leave again.
    if outs < STRESS_DETOURS + 1:
        failures.append(f"{outs} off-route events on the watch, expected at least {STRESS_DETOURS + 1}")

    # By the motorcycle's clock (one-second resolution) when the line does not carry the ms.
    requests = [(int(m.start()), int(m.group(1))) for m in W_REQ_AT.finditer(watch)]
    swaps = []
    for m in W_SWAP_ANY.finditer(watch):
        if m.group(4) is not None:
            ms, how = int(m.group(4)), "em"
        else:
            before = [sec for pos, sec in requests if pos < m.start()]
            ms = (int(m.group(1)) - before[-1]) * 1000 if before else DETOUR_BUDGET_MS + 1
            how = "unrequested, for ~"
        swaps.append((m.group(2), m.group(3), ms, how))
    for index, (old, new, ms, how) in enumerate(swaps, start=1):
        report.append(f"swap {index}: route {old} -> {new} {how} {ms} ms (deadline {DETOUR_BUDGET_MS} ms)")
        if ms > DETOUR_BUDGET_MS:
            failures.append(f"recalculation {index}: {ms} ms, deadline {DETOUR_BUDGET_MS} ms")
    if len(swaps) != STRESS_DETOURS:
        failures.append(f"{len(swaps)} route swaps, expected {STRESS_DETOURS}")

    report.append(f"companion stopped at {killed_at:.1f} s, process "
                  f"{'dead' if dead else 'STILL ALIVE'}" if killed_at is not None else "companion was NOT stopped")
    if killed_at is None or not dead:
        failures.append("the companion was not stopped (force-stop had no effect or never got there)")
    if unanswered < 1:
        failures.append("after the companion died the watch did not ask for a recalculation (no unanswered 0x82)")

    if killed_at is not None:
        # What counts is after the watch **knows** it is without a phone ("recalculation needs
        # the phone"): a turn warned before it only shows the kill has not taken effect yet
        # (C14's 2nd second opinion).
        needs_at = next((t for t, line in lines if t > killed_at and W_NEEDS_PHONE in line), None)
        if needs_at is None:
            failures.append(f"the watch did not say «{W_NEEDS_PHONE}»")
            report.append(f"after the companion: no «{W_NEEDS_PHONE}»")
        else:
            after = [line for t, line in lines if t > needs_at]
            # ``fix -`` is the watch without a position (``Telemetry.fixName``): it is not "following with a fix".
            telemetry = sum(1 for line in after
                            if (m := W_TELEMETRY.search(line)) is not None and m.group(3) != "-")
            # Only the turn counts as a navigation warning: ``vibe off route`` is from the detour the
            # test itself injects.
            warnings = sum(1 for line in after if W_CURVE.search(line))
            report.append(f"after «{W_NEEDS_PHONE}»: {telemetry} telemetry line(s) with a fix, "
                          f"{warnings} turn alert(s)")
            if telemetry < 1:
                failures.append("the watch stopped logging a fix after learning it has no phone")
            if warnings < 1:
                failures.append("no turn alert after learning it has no phone")

    for marker in ("Watchdog Tripped", "Unhandled Exception", "Error: ", "CIQ_LOG"):
        if marker in watch:
            failures.append(f"watch crash ({marker.strip()})")
            break
    peaks = [int(p) for p in sim.WORK_PEAK.findall(watch)]
    if peaks:
        report.append(f"work peak: {max(peaks)} (ceiling {sim.WORK_CEILING}, {len(peaks)} sample(s))")

    if not failures:
        return 0, report
    report += [f"FAILED: {f}" for f in failures]
    if C_MAPBOX_DOWN.search(companion) and len(swaps) < STRESS_DETOURS:
        return 2, report + ["External API down: Mapbox did not answer (is the emulator offline?)"]
    if C_NO_CORRIDOR in companion and C_OVERPASS_DOWN in companion and len(swaps) < STRESS_DETOURS:
        return 2, report + ["External API down: Overpass did not let the corridor settle"]
    return 1, report


def run_stress(timeout_s: int) -> int:
    """F4's whole stress ride on the PC (C14): navigation started by a favorite, three
    detours with recalculation over the bridge and the companion killed (``force-stop``) in the middle of the fourth."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()
    prepare_device()
    geo_fix(*STRESS_ORIGIN)
    if not sim.compile_prg([JUNGLE, ponte.BRIDGE_JUNGLE], ponte.BRIDGE_PRG, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    lines: list[tuple[float, str]] = []
    relayed: dict[str, int] = {}
    st = {"started": None, "next_probe": None, "c2r_at": None, "probes": 0, "next_log": 0.0,
          "stage": "seed", "mark": 0.0, "acted_at": None, "attempts": 0, "log_mark": 0, "companion": "",
          "detours": 0, "settled": None, "swaps_before": 0, "killed_at": None, "dead": False,
          "unanswered": 0}

    def stage(name: str, elapsed: float) -> None:
        st["stage"] = name
        st["mark"] = elapsed
        st["acted_at"] = None
        st["attempts"] = 0
        st["settled"] = None
        print(f"{elapsed:7.1f}s {name}")

    def watch_text() -> str:
        return "\n".join(line for _, line in lines)

    def count(pattern) -> int:
        return len(pattern.findall(watch_text()))

    def on_line(line: str, elapsed: float) -> None:
        line = watch_line(line)
        if st["started"] is None and ponte.APP_START.match(line):
            st["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {ponte.press_menu('adb', '^Start')}")
            st["next_probe"] = elapsed + ponte.FIRST_PROBE_S
        lines.append((elapsed, line))
        if line.strip() == c2r and st["c2r_at"] is None:
            st["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s) — the outbound leg is alive")
        elif line.startswith(ponte.TX_PREFIX):
            payload = line[len(ponte.TX_PREFIX):].strip()
            kind = tx_kind(payload)
            if st["killed_at"] is not None:
                # Companion killed: nobody delivers the frame. It is the lack of an answer that gets proved.
                if kind == "0x82":
                    st["unanswered"] += 1
                    print(f"{elapsed:7.1f}s REROUTE_REQ without a companion: nobody answers")
                return
            if ponte.relay(payload):
                relayed[kind] = relayed.get(kind, 0) + 1
                if kind == "0x83":
                    print(f"{elapsed:7.1f}s NAV_START_REQ delivered to the companion")
                elif kind == "0x82":
                    print(f"{elapsed:7.1f}s REROUTE_REQ #{relayed[kind]} delivered to the companion")

    def command(text: str, elapsed: float) -> None:
        ponte.send_command(text)
        st["acted_at"] = elapsed
        print(f"{elapsed:7.1f}s command {text}")

    def key_due(elapsed: float, wait_s: float = FAVORITE_KEY_WAIT_S) -> bool:
        return st["acted_at"] is None or elapsed - st["acted_at"] > wait_s

    def corridor_events(companion: str) -> int:
        return len(C_CORRIDOR_SENT.findall(companion)) + companion.count(C_NO_CORRIDOR)

    def on_idle(elapsed: float) -> bool:
        if st["c2r_at"] is None:
            due = st["next_probe"]
            if due is not None and elapsed >= due:
                st["probes"] += 1
                ponte.send_probe(probe_id)
                st["next_probe"] = elapsed + ponte.PROBE_EVERY_S
            return False
        text = watch_text()
        phase = st["stage"]

        if phase == "seed":
            if W_FAV_APPLIED.search(text):
                stage("open", elapsed)
            elif key_due(elapsed, 20):
                if st["attempts"] >= 3:
                    print(f"{elapsed:7.1f}s the watch did not apply the favorites in 3 attempts: stopping")
                    return True
                geo_fix(*STRESS_ORIGIN)
                if not st["log_mark"]:
                    st["log_mark"] = len(companion_log())
                ponte.adb("shell", "am", "broadcast", "-a", FAVORITES_ACTION, "-n", FAVORITES_RECEIVER, check=False)
                st["acted_at"] = elapsed
                st["attempts"] += 1
                print(f"{elapsed:7.1f}s test favorites sent to the watch (attempt {st['attempts']})")
            return False

        if phase == "open":
            if W_FAV_OPENED.search(text):
                stage("pick", elapsed)
            elif key_due(elapsed):
                if st["attempts"] >= 4:
                    print(f"{elapsed:7.1f}s the Favorites screen did not open in 4 commands: stopping")
                    return True
                command("FAV:OPEN", elapsed)
                st["attempts"] += 1
            return False

        if phase == "pick":
            if W_FAV_REQ.search(text):
                stage("route", elapsed)
            elif key_due(elapsed, 1.0 if st["attempts"] == 0 else FAVORITE_KEY_WAIT_S):
                if st["attempts"] >= 3:
                    print(f"{elapsed:7.1f}s the favorite did not ask for a route in 3 commands: stopping")
                    return True
                command(f"FAV:PICK:{STRESS_FAVORITE}", elapsed)
                st["attempts"] += 1
            return False

        if phase == "route":
            if elapsed - st["mark"] > FAVORITE_ROUTE_WAIT_S:
                print(f"{elapsed:7.1f}s the favorite's route did not arrive in {FAVORITE_ROUTE_WAIT_S} s: stopping")
                return True
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            companion = companion_log()[st["log_mark"]:]
            if C_FAILED.search(companion):
                return True
            if (COMPLETE_LINE.search(text) is not None and MAP_ON in text
                    and C_FAV_SENT.search(companion) is not None):
                stage("sim", elapsed)
            return False

        if phase == "sim":
            if W_SIM_START in text:
                stage("riding", elapsed)
            elif key_due(elapsed, DETOUR_CMD_WAIT_S):
                command("SIM", elapsed)
            return False

        if phase == "riding":
            if elapsed - st["mark"] < DETOUR_RIDE_S:
                return False
            st["detours"] += 1
            st["swaps_before"] = count(W_SWAP_ANY)
            stage(f"detour {st['detours']}", elapsed)
            command(f"DETOUR:{DETOUR_M}", elapsed)
            return False

        if phase.startswith("detour"):
            if st["detours"] > STRESS_DETOURS:
                if text.count(W_CMD_DETOUR) >= STRESS_DETOURS + 1:
                    ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
                    st["killed_at"] = elapsed
                    alive = ponte.adb("shell", "pidof", PACKAGE, check=False).stdout.strip()
                    st["dead"] = not alive
                    print(f"{elapsed:7.1f}s companion stopped "
                          f"({'process dead' if st['dead'] else 'STILL ALIVE: ' + alive})")
                    stage("after", elapsed)
                elif elapsed - st["mark"] > 30:
                    print(f"{elapsed:7.1f}s the fourth detour did not reach the watch in 30 s: stopping")
                    return True
                return False
            if count(W_SWAP_ANY) > st["swaps_before"]:
                stage(f"settle {st['detours']}", elapsed)
            elif st["acted_at"] is not None and elapsed - st["acted_at"] > 90:
                print(f"{elapsed:7.1f}s the new route did not arrive in 90 s: stopping")
                return True
            return False

        if phase.startswith("settle"):
            if elapsed < st["next_log"]:
                return False
            st["next_log"] = elapsed + LOG_EVERY_S
            companion = companion_log()[st["log_mark"]:]
            # 1 for the favorite route's corridor + 1 per recalculation.
            if corridor_events(companion) >= 1 + st["detours"] and st["settled"] is None:
                st["settled"] = elapsed
            if (st["settled"] is not None and elapsed - st["settled"] > LOD_PARSE_WAIT_S) \
                    or elapsed - st["mark"] > DETOUR_SETTLE_MAX_S:
                if st["detours"] >= STRESS_DETOURS:
                    # The fourth detour is short and ends on its own: the companion dies as soon as the
                    # watch receives it (before OffRoute's 5 s window), the request goes out to
                    # nobody, and the motorcycle returns to the route to warn of a turn without the phone.
                    st["detours"] += 1
                    stage("detour 4", elapsed)
                    command(f"DETOUR:{DETOUR_M}:{STRESS_DETOUR_S}", elapsed)
                else:
                    stage("riding", elapsed)
            return False

        # after: the watch alone. Ends when it said it needs the phone and warned of a
        # turn after the kill, or at the deadline.
        needs_at = next((t for t, line in lines if t > st["killed_at"] and W_NEEDS_PHONE in line), None)
        if needs_at is not None:
            tail = [line for t, line in lines if t > needs_at]
            if (any(W_CURVE.search(line) for line in tail)
                    and any((m := W_TELEMETRY.search(line)) is not None and m.group(3) != "-"
                            for line in tail)):
                return True
        return elapsed - st["mark"] > STRESS_CURVE_WAIT_S

    try:
        text, timed_out = ponte.run_live_until(ponte.BRIDGE_PRG, timeout_s, on_line, on_idle)
    finally:
        st["companion"] = companion_log()[st["log_mark"]:]
        ponte.adb("shell", "am", "force-stop", PACKAGE, check=False)
    sim.save(WATCH_LOG, text)
    sim.save(COMPANION_OUT, st["companion"])

    print()
    if st["started"] is None:
        print("the app never printed [diag] start: Start was not even pressed")
        return 1
    if st["c2r_at"] is None:
        print(f"no probe arrived in {st['probes']} attempt(s): the outbound leg is not alive")
        return 1
    if timed_out:
        print(f"deadline of {timeout_s} s exceeded")

    code, report = judge_stress(lines, relayed, st["companion"], st["killed_at"], st["dead"], st["unanswered"])
    for line in report:
        print(f"  {line}")
    if code == 0:
        print(f"e2e --stress: OK — favorite, {STRESS_DETOURS} recalculations within the deadline and the watch standing "
              "with the companion dead")
    else:
        print(f"e2e --stress: NO (exit {code}) — raw output in shots/{WATCH_LOG} and shots/{COMPANION_OUT}")
    return code


#: The first use (C16.8b), in each language's texts: the step, the continue button and the finish one.
SETUP_TEXTS = {
    "en-US": {"step": "Step {n} of 4", "next": "Continue", "allow": "Allow", "save": "Save token",
              "saved": "Token saved.", "bad": "That doesn't look like a Mapbox public token: those start with pk.",
              "done": "Done", "finish": "Let's go", "home": "Where to?"},
    "pt-BR": {"step": "Passo {n} de 4", "next": "Continuar", "allow": "Permitir", "save": "Salvar token",
              "saved": "Token salvo.", "bad": "Esse não parece um token público do Mapbox: ele começa com pk.",
              "done": "Pronto", "finish": "Bora", "home": "Para onde?"},
}

#: The first-use photos, outside git (``shots/``).
SETUP_SHOTS = sim.SHOTS / "c168b"

#: The Android permission dialog's buttons, by id (the text is the emulator's language).
PERMISSION_BUTTONS = (
    "com.android.permissioncontroller:id/permission_allow_foreground_only_button",
    "com.android.permissioncontroller:id/permission_allow_button",
    "android:id/button1",
)

#: How long each step waits for the screen to respond. The Compose screen responds in ~1 s on ``pato37``;
#: the system dialog takes longer. A choice, not a measurement.
SETUP_WAIT_S = 20


def has_text(nodes: list[dict[str, str]], text: str) -> bool:
    return any(n.get("text") == text for n in nodes)


def tap_id(resource_ids: tuple[str, ...]) -> str | None:
    """Taps the first node with one of these ids; returns the id tapped."""
    for node in ui_nodes():
        if node.get("resource-id") in resource_ids:
            center = node_center(node)
            if center:
                ponte.adb("shell", "input", "tap", str(center[0]), str(center[1]), check=False)
                return node.get("resource-id")
    return None


def run_first_run(timeout_s: int, locale: str) -> int:
    """The app reset up to the first route (C16.8b, item 3's `verificar:`): ``pm clear`` of the
    ``sim`` variant, the whole first use through taps and, at the end, the usual share
    up to the map in the simulator. The real token is never typed: the field receives a
    text that is not a token (and the screen has to refuse), and the token goes in through ``TokenReceiver``."""
    if not ponte.APK.exists():
        sys.exit(f"the sim variant's APK is missing: {ponte.APK}\n  cd companion && ./gradlew assembleSim")
    token_file()
    texts = SETUP_TEXTS[locale]
    shots = SETUP_SHOTS / locale
    failures: list[str] = []

    def shot(name: str) -> None:
        why = screencap(shots / f"{name}.png")
        print(f"  photo {name}: {why or 'ok'}")

    ponte.ensure_emulator()
    leave_doze()
    ponte.adb("shell", "input", "keyevent", "KEYCODE_WAKEUP", check=False)
    ponte.adb("shell", "wm", "dismiss-keyguard", check=False)
    print(f"installing {ponte.APK.name} and resetting the app (pm clear)")
    ponte.adb("install", "-r", "-t", str(ponte.APK), timeout=180)
    ponte.adb("shell", "pm", "clear", PACKAGE)
    if not app_locale(locale):
        failures.append(f"the app language did not become {locale}")
    geo_fix(*ORIGIN)
    mark = len(companion_log())
    # `-S -W`: with the app in front during `install`, a plain `am start` landed on the task the
    # system was still killing (result 3) and the screen stayed black (job 1056).
    ponte.adb("shell", "am", "start", "-S", "-W", "-n", ponte.ACTIVITY)

    # 1. The token: a text that is not a token is refused; the real one arrives through TokenReceiver.
    if not wait_for(lambda nodes: has_text(nodes, texts["step"].format(n=1)), SETUP_WAIT_S):
        print(f"first run: NO (exit 1) — the «{texts['step'].format(n=1)}» screen did not open with the app reset")
        return 1
    shot("1-token")
    field = next((n for n in ui_nodes() if n.get("class", "").endswith("EditText")), None)
    if field is None or not type_into(field, "pk.curto"):
        failures.append("could not type into the token field")
    ponte.adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)  # closes the keyboard
    time.sleep(0.8)
    tap_text(texts["save"])
    if not wait_for(lambda nodes: has_text(nodes, texts["bad"]), SETUP_WAIT_S):
        failures.append("the screen accepted a text that is not a token")
    deliver_token()
    if not wait_for(lambda nodes: has_text(nodes, texts["saved"]), SETUP_WAIT_S):
        failures.append("the token step did not see the delivered token")
    shot("1-token-salvo")

    # 2. The permissions: each "Permitir" opens the system dialog, which is tapped by id.
    tap_text(texts["next"])
    if not wait_for(lambda nodes: has_text(nodes, texts["step"].format(n=2)), SETUP_WAIT_S):
        failures.append("step 2 did not open")
    shot("2-permissoes")
    for _ in range(3):
        if not tap_text(texts["allow"]):
            break
        tapped = wait_for(lambda nodes: tap_id(PERMISSION_BUTTONS), SETUP_WAIT_S)
        print(f"  system dialog: {tapped or 'none'}")
        time.sleep(1.5)
    granted = sum(1 for n in ui_nodes() if n.get("text") == texts["done"])
    print(f"  permissions done: {granted} of 3")
    if granted < 3:
        failures.append(f"only {granted} of 3 permissions were done")
    shot("2-permissoes-dadas")

    # 3. The watch: the simulator is not up yet, so the connection test does not run here.
    tap_text(texts["next"])
    if not wait_for(lambda nodes: has_text(nodes, texts["step"].format(n=3)), SETUP_WAIT_S):
        failures.append("step 3 did not open")
    shot("3-relogio")

    # 4. Ready.
    tap_text(texts["next"])
    if not wait_for(lambda nodes: has_text(nodes, texts["step"].format(n=4)), SETUP_WAIT_S):
        failures.append("step 4 did not open")
    shot("4-pronto")
    tap_text(texts["finish"])
    if not wait_for(lambda nodes: has_text(nodes, texts["home"]), SETUP_WAIT_S):
        failures.append("Início did not open after the first run")
    shot("5-inicio")
    log = companion_log()[mark:]
    for line in ("first run: opened", "first run: done"):
        if line not in log:
            failures.append(f"motonav.log does not have «{line}»")
    if failures:
        print("first run: NO (exit 1)")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"first run: YES, in {locale}; now the first route")

    # 5. The first route, through the usual path, in the same language.
    code = run(timeout_s, False, False, None, locale=locale)
    shot("6-depois-da-rota")
    print(f"first run up to the first route: {'YES' if code == 0 else f'NO (exit {code})'}")
    return code


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--stress", "--estresse", dest="stress", action="store_true",
                        help="C14: F4's stress ride — navigation started by a favorite, 3 detours with "
                             "recalculation over the bridge and the companion killed (force-stop) in the middle of the "
                             "fourth; exits 0 only with 3 recalculations <= 10 s and the watch carrying on with fix and "
                             "alerts, saying 'recalculation needs the phone', with no crash")
    parser.add_argument("--timeout", type=int, default=None,
                        help=f"seconds of simulator before giving up (default {DEFAULT_TIMEOUT_S} per share)")
    parser.add_argument("--double", "--dupla", dest="double", action="store_true",
                        help="two shares in a row, without killing the companion: 0 if both arrive, "
                             "3 if the second-share bug reproduces")
    parser.add_argument("--canary", action="store_true",
                        help="does not deliver the watch's return leg: MUST exit 1")
    parser.add_argument("--link", help="the shared text, in place of the Copan link (a public place)")
    parser.add_argument("--detour", "--desvio", dest="detour", type=int, default=None, metavar="N",
                        help="C11: N detours in a row on the virtual ride, each with a recalculation over the bridge; "
                             "exits 0 only with N requests and N swaps within 10 s")
    parser.add_argument("--favorite", "--favorito", dest="favorite", type=int, default=None, metavar="N",
                        help="C12: the phone's favorites go to the watch, the Nth is picked by the bridge command "
                             "(SDK 9.2.0 does not deliver keys) of the simulator (Enter and arrows) and the whole "
                             "route has to arrive; exits 0 only with the NAV_START_REQ in the companion and the "
                             "complete route with the map")
    parser.add_argument("--doze", type=int, nargs="?", const=10, default=None, metavar="MIN",
                        help="C13a: MIN minutes (default 10) of forced doze, unplugged and with the app off "
                             "screen; exits 0 only with the ROUTE_UPDATEs reaching the watch at the 10 min pace, the "
                             "service in the foreground and the same process from start to end. With --canary the "
                             "service is stopped before doze: MUST exit 1")
    parser.add_argument("--drop", "--queda", dest="drop", type=int, nargs="?", const=15, default=None, metavar="S",
                        help="C13b: drops the outbound leg for S seconds (default 15) in the middle of the largest "
                             "corridor block; exits 0 only with 'block 0x04 complete after N rounds', N >= 2, and "
                             "the whole corridor. Above 30 s it also requires the bitmap resend. With --canary it does "
                             "not drop: MUST exit 1")
    parser.add_argument("--no-fix", "--sem-fix", dest="no_fix", type=int, default=None, metavar="S",
                        help="C13b: S seconds (>= 25) without a fix on the virtual ride, with the app off screen and "
                             "the screen off; exits 0 only with 'fix phone' in the telemetry during the hole, the "
                             "motorcycle on the route, and the own source back after it. With --canary the service is "
                             "stopped first: MUST exit 1")
    parser.add_argument("--first-run", "--primeiro-uso", dest="first_run", nargs="?", const="en-US", default=None,
                        choices=sorted(SETUP_TEXTS), metavar="LANGUAGE",
                        help="C16.8b: pm clear, the whole first use and the first route (default en-US)")
    parser.add_argument("--screens", "--telas", dest="screens", action="store_true",
                        help="photographs the phone's confirmation, search and settings on pato37 "
                             "(shots/c9_*.png), without the watch simulator")
    parser.add_argument("--config", action="append", metavar="KEY=VALUE", default=[],
                        help="C16.6: the CONFIG sent over the bridge before the share, on top of "
                             f"{E2E_CONFIG} (default path and --double only); the default goes back to Storage at the end")
    args = parser.parse_args()
    config = {**E2E_CONFIG, **sim.parse_config(args.config)}
    if args.config and (args.stress or args.screens or args.detour is not None or args.favorite is not None
                   or args.doze is not None or args.drop is not None or args.no_fix is not None):
        parser.error("--config only combines with the default path, --double, --link, --canary and --timeout")
    if args.first_run is not None:
        return run_first_run(args.timeout or DEFAULT_TIMEOUT_S + RADAR_WAIT_S, args.first_run)
    if args.stress:
        if (args.double or args.link or args.screens or args.detour is not None or args.favorite is not None
                or args.drop is not None or args.no_fix is not None or args.doze is not None or args.canary):
            parser.error("--stress only combines with --timeout")
        # Favorite (90 s) + the route + 3 recalculations with the corridor settling (up to 150 s each) + the end.
        return run_stress(args.timeout or 1500)
    if args.doze is not None:
        if (args.double or args.link or args.screens or args.detour is not None or args.favorite is not None
                or args.drop is not None or args.no_fix is not None):
            parser.error("--doze only combines with --canary and --timeout")
        if args.doze < 10:
            parser.error("--doze MIN needs MIN >= 10: the first ROUTE_UPDATE goes out 10 min after the route")
        # The share's deadline (measured, above) plus the doze period.
        return run_doze(args.timeout or DEFAULT_TIMEOUT_S + args.doze * 60 + ETA_TOLERANCE_S, args.doze, args.canary)
    if args.no_fix is not None:
        if (args.double or args.link or args.screens or args.detour is not None or args.favorite is not None
                or args.drop is not None):
            parser.error("--no-fix only combines with --canary and --timeout")
        if not 25 <= args.no_fix <= 120:
            parser.error("--no-fix S needs S between 25 and 120: the first phone fix arrives within 15 s, and the "
                         "telemetry is one line every 10 s")
        # Share + corridor (up to 150 s) + the ride, the hole and the after.
        return run_no_fix(args.timeout or DEFAULT_TIMEOUT_S + DETOUR_SETTLE_MAX_S + args.no_fix + 120,
                           args.no_fix, args.canary)
    if args.drop is not None:
        if args.double or args.link or args.screens or args.detour is not None or args.favorite is not None:
            parser.error("--drop only combines with --canary and --timeout")
        if not 5 <= args.drop <= 55:
            parser.error("--drop S needs S between 5 and 55: above 60 s the phone gives up on the block, by design")
        return run_drop(args.timeout or DEFAULT_TIMEOUT_S + args.drop + 60, args.drop, args.canary)
    if args.screens:
        if args.double or args.canary or args.link:
            parser.error("--screens does not combine with --double, --canary or --link")
        return run_screens()
    if args.favorite is not None:
        if args.double or args.canary or args.link or args.detour is not None:
            parser.error("--favorite does not combine with --double, --canary, --link or --detour")
        if not 1 <= args.favorite <= len(FAVORITE_PLACES):
            parser.error(f"--favorite N needs N between 1 and {len(FAVORITE_PLACES)}")
        return run_favorite(args.timeout or 300, args.favorite)
    if args.detour is not None:
        if args.double or args.canary or args.link:
            parser.error("--detour does not combine with --double, --canary or --link")
        if args.detour < 1:
            parser.error("--detour N needs N >= 1")
        return run_detour(args.timeout or 900, args.detour)
    if args.double and args.canary:
        parser.error("--double and --canary do not combine")
    # Plus the radars' verdict, which come after the corridor (C16.6).
    timeout_s = args.timeout or (DEFAULT_TIMEOUT_S + RADAR_WAIT_S) * (2 if args.double else 1)
    return run(timeout_s, args.double, args.canary, args.link, config)


if __name__ == "__main__":
    sys.exit(main())
