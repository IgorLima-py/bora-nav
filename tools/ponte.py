#!/usr/bin/env python3
"""Does the bridge exist? One message each way between the companion and the simulator (C7a).

Why this script exists
----------------------
Until C6b, the only way to see the companion talking to the watch app was the
hardware: S25, Garmin Connect, BLE and the Venu 4. The Connect IQ Mobile SDK has a
``TETHERED`` mode that links the Android app to the **simulator** through
``adb forward tcp:7381 tcp:7381`` and **adb Connection > Start** (``Ctrl+F1``)
(``docs/DECISIONS.md`` §2026-09-11). If that works, the whole path runs on the
PC (C7b); if not, the queue up to C15b is replanned.

This script proves it with one message each way, then exits:

* ``0`` only when it finds ``PONTE:C2R:<id>`` in the simulator output **and**
  ``PONTE:R2C:<id>`` in ``adb -s emulator-5554 logcat -d``;
* ``1`` on anything else, saying which side is missing.

The ``<id>`` is new on every run: an old run's line in logcat never counts.

**The C7a answer (2026-10-09): half a bridge.** The way out (phone -> watch) goes
over the real ``TETHERED``. The way back does not: in the SDK 9.2.0 simulator,
``Communications.transmit`` over ``TETHERED`` freezes the app (known bug,
CIQQA-4579 / CIQQA-4735, no fix). So the bridge build prints
``PONTE:TX:<text>`` in place of ``transmit``, and this script hands the text to the
companion through ``adb shell am broadcast`` — the relay. ``--socket`` removes the
relay and tries the real ``transmit``: that is how the failure is reproduced and
how a new SDK is checked.

What it does, in order:

1. brings up ``pato37`` if it is not running (**always** ``-s emulator-5554``:
   the emulator is shared with another project, and a real phone may be on the same USB);
2. installs ``app-sim.apk`` (``sim`` variant: ``CIQ_TETHERED``, package ``.sim``)
   and opens the app, so the SDK listens on 7381 **before** the simulator connects;
3. ``adb forward tcp:7381 tcp:7381``;
4. builds the bridge ``.prg`` (``watch/ponte.jungle``), opens it in the simulator and,
   when the app prints ``[diag] start``, presses **adb Connection > Start**
   through the window menu (``WM_COMMAND``, found by its label, the way
   ``shot_simulator.ps1`` finds *Save Screen Capture*);
5. sends the proof through ``am broadcast`` until the watch prints the line, hands
   the companion every ``PONTE:TX:`` the watch prints, and looks for the answer
   in logcat.

Usage::

    python tools/ponte.py
    python tools/ponte.py --timeout 180
    python tools/ponte.py --socket      # no relay: MUST exit 1 while the bug exists

The APK comes from gradle, which **does not run together with the simulator** (it ran
the dev PC out of memory, ``CLAUDE.md`` §Test battery). Build first::

    cd companion && ./gradlew assembleSim

The raw output goes to ``shots/ponte.log`` (outside git).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sim  # noqa: E402
from build_watch import BIN, JUNGLE, ROOT  # noqa: E402

SERIAL = "emulator-5554"
AVD = "pato37"
PACKAGE = "dev.igor.motonav.sim"
ACTIVITY = f"{PACKAGE}/dev.igor.motonav.MainActivity"
RECEIVER = f"{PACKAGE}/dev.igor.motonav.sim.BridgeReceiver"
ACTION = "dev.igor.motonav.sim.PONTE"
APK = ROOT / "companion" / "app" / "build" / "outputs" / "apk" / "sim" / "app-sim.apk"
BRIDGE_JUNGLE = ROOT / "watch" / "ponte.jungle"
BRIDGE_PRG = BIN / "ponte" / "MotoNavPonte.prg"
SOCKET_JUNGLE = ROOT / "watch" / "ponte_socket.jungle"
SOCKET_PRG = BIN / "ponte" / "MotoNavPonteSocket.prg"
RELAY_ACTION = "dev.igor.motonav.sim.RELAY"
CMD_ACTION = "dev.igor.motonav.sim.CMD"

#: What the watch prints in place of ``transmit`` (``watch/ponte/source/Ponte.mc``).
TX_PREFIX = "PONTE:TX:"

#: The ``TETHERED`` port, the same on both sides (Mobile SDK for Android).
TETHER_PORT = 7381

#: Timeout for the ``pato37`` boot. Measured on 2026-10-09 on the Windows dev PC: see
#: ``DECISIONS.md`` §C7a; 180 s is slack over a cold boot.
BOOT_TIMEOUT_S = 180

#: Seconds between the companion's ``am start`` and ``monkeydo``: the SDK must
#: be listening on 7381 when the simulator connects.
SDK_WARMUP_S = 4

#: Seconds between Start and the first probe, and between one probe and the next
#: while the simulator has not printed the line. The connection does not say when
#: it is ready; repeating is cheaper than guessing.
FIRST_PROBE_S = 3
PROBE_EVERY_S = 6

#: Timeout for the whole run after ``monkeydo``. The probe goes and comes back in a few
#: seconds when the bridge exists; 120 s covers a cold simulator and several
#: attempts.
DEFAULT_TIMEOUT_S = 120

#: After the watch's line, how long to wait for the answer to show up in logcat.
R2C_WAIT_S = 20

#: One ``adb logcat -d`` every 2 s, not on every 0.2 s turn of the loop.
LOGCAT_EVERY_S = 2.0

#: Seconds for `monkeydo` to exit on its own after Kill App.
KILL_APP_WAIT_S = 5

#: The app's first line: ``[diag] 341s start v0.18.4-f3a`` (``Diag`` puts the
#: clock first). It is the signal that Start can be pressed.
APP_START = re.compile(r"\[diag\] \S+ start ")

#: Clicks a simulator menu item through ``WM_COMMAND``, found by the label
#: of the submenu and of the item. Exits 0 with the id, 2 with no window, 3 with no item.
MENU_SCRIPT = r"""
$sig = @'
using System; using System.Text; using System.Runtime.InteropServices;
public class BridgeMenu {
  [DllImport("user32.dll")] public static extern IntPtr GetMenu(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetMenuItemCount(IntPtr m);
  [DllImport("user32.dll")] public static extern IntPtr GetSubMenu(IntPtr m, int p);
  [DllImport("user32.dll")] public static extern int GetMenuItemID(IntPtr m, int p);
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetMenuStringW(IntPtr m, int id, StringBuilder s, int n, int f);
  public static string Label(IntPtr m, int p) { var sb = new StringBuilder(256); GetMenuStringW(m, p, sb, 256, 0x400); return sb.ToString().Replace("&", ""); }
}
'@
Add-Type -TypeDefinition $sig
$h = (Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
if (-not $h) { Write-Output "no simulator window"; exit 2 }
$bar = [BridgeMenu]::GetMenu($h)
for ($i = 0; $i -lt [BridgeMenu]::GetMenuItemCount($bar); $i++) {
  if ([BridgeMenu]::Label($bar, $i) -notmatch '__SUBMENU__') { continue }
  $sub = [BridgeMenu]::GetSubMenu($bar, $i)
  for ($j = 0; $j -lt [BridgeMenu]::GetMenuItemCount($sub); $j++) {
    if ([BridgeMenu]::Label($sub, $j) -match '__ITEM__') {
      $id = [BridgeMenu]::GetMenuItemID($sub, $j)
      [void][BridgeMenu]::PostMessageW($h, 0x0111, [IntPtr]$id, [IntPtr]0)
      Write-Output "menu $id"; exit 0
    }
  }
}
Write-Output "menu item not found"; exit 3
"""


#: Virtual watch keys (C12): Enter is the top button (SELECT), the arrows
#: move through menus, Esc is back. ``post`` delivers through ``PostMessage`` to the
#: simulator window, without focus (it cannot hit the wrong window); ``send`` brings the
#: window to the front and uses ``SendKeys``, and **only sends if the simulator really is the front window**.
KEY_CODES = {"ENTER": (0x0D, "{ENTER}"), "DOWN": (0x28, "{DOWN}"), "UP": (0x26, "{UP}"), "ESC": (0x1B, "{ESC}")}

KEY_SCRIPT = r"""
Add-Type -AssemblyName System.Windows.Forms
$sig = @'
using System; using System.Runtime.InteropServices;
public class BridgeKey {
  [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
}
'@
Add-Type -TypeDefinition $sig
$h = (Get-Process simulator -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1).MainWindowHandle
if (-not $h) { Write-Output "no simulator window"; exit 2 }
if ('__MODE__' -eq 'post') {
  [void][BridgeKey]::PostMessageW($h, 0x0100, [IntPtr]__VK__, [IntPtr]1)
  Start-Sleep -Milliseconds 60
  [void][BridgeKey]::PostMessageW($h, 0x0101, [IntPtr]__VK__, [IntPtr]0xC0000001)
  Write-Output "post __VK__"; exit 0
}
[void][BridgeKey]::ShowWindow($h, 9)
[BridgeKey]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[void][BridgeKey]::SetForegroundWindow($h)
[BridgeKey]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200
if ([BridgeKey]::GetForegroundWindow() -ne $h) { Write-Output "simulator did not come to the front"; exit 3 }
if ('__MODE__' -eq 'click') {
  # Tap at the center of the watch screen (BehaviorDelegate.onTap becomes onSelect): 333,500 in the 666x984 window (capture 2026-10-13).
  $r = New-Object BridgeKey+RECT
  [void][BridgeKey]::GetWindowRect($h, [ref]$r)
  $sx = $r.L + [int](($r.R - $r.L) * 333 / 666)
  $sy = $r.T + [int](($r.B - $r.T) * 500 / 984)
  [void][BridgeKey]::SetCursorPos($sx, $sy)
  Start-Sleep -Milliseconds 80
  [BridgeKey]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [BridgeKey]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Write-Output "click $sx,$sy"; exit 0
}
[System.Windows.Forms.SendKeys]::SendWait('__SEND__')
Write-Output "send __SEND__"; exit 0
"""


def sdk_roots() -> list[Path]:
    """The Android SDKs possible on this machine, the project's first.

    On the Windows dev PC, MotoNav's (``%LOCALAPPDATA%\\Android\\Sdk``) does not have
    ``emulator``; another project's (``%USERPROFILE%\\Android\\Sdk``) does.
    """
    roots = []
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(env):
            roots.append(Path(os.environ[env]))
    if os.environ.get("LOCALAPPDATA"):
        roots.append(Path(os.environ["LOCALAPPDATA"]) / "Android" / "Sdk")
    roots.append(Path.home() / "Android" / "Sdk")
    return roots


def find_sdk_tool(relative: str) -> Path:
    suffix = ".exe" if os.name == "nt" else ""
    for root in sdk_roots():
        candidate = root / f"{relative}{suffix}"
        if candidate.exists():
            return candidate
    found = shutil.which(Path(relative).name)
    if found:
        return Path(found)
    sys.exit(f"could not find {relative} in any Android SDK ({', '.join(map(str, sdk_roots()))})")


def adb(*args: str, check: bool = True, timeout: int = 60) -> subprocess.CompletedProcess:
    """Always with ``-s emulator-5554``: never Igor's S25."""
    result = subprocess.run([str(ADB), "-s", SERIAL, *args], capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=timeout)
    if check and result.returncode != 0:
        sys.exit(f"adb {' '.join(args)} failed ({result.returncode}): {result.stderr.strip() or result.stdout.strip()}")
    return result


def emulator_up() -> bool:
    devices = subprocess.run([str(ADB), "devices"], capture_output=True, text=True).stdout
    return any(line.split("\t")[:2] == [SERIAL, "device"] for line in devices.splitlines())


def booted() -> bool:
    result = adb("shell", "getprop", "sys.boot_completed", check=False, timeout=10)
    return result.stdout.strip() == "1"


def ensure_emulator() -> None:
    if emulator_up() and booted():
        print(f"{SERIAL} already up")
        return
    if not emulator_up():
        print(f"starting {AVD}")
        flags = 0
        if os.name == "nt":
            flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
        # Detached from this script, like the simulator: stays up for the next run.
        subprocess.Popen([str(find_sdk_tool("emulator/emulator")), "-avd", AVD, "-no-boot-anim"],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         creationflags=flags)
    started = time.monotonic()
    while time.monotonic() - started < BOOT_TIMEOUT_S:
        if emulator_up() and booted():
            print(f"{SERIAL} ready in {time.monotonic() - started:.0f} s")
            return
        time.sleep(2)
    sys.exit(f"{AVD} did not finish booting in {BOOT_TIMEOUT_S} s")


def install_and_open() -> None:
    if not APK.exists():
        sys.exit(f"missing the sim variant APK: {APK}\n  cd companion && ./gradlew assembleSim")
    print(f"installing {APK.name}")
    adb("install", "-r", "-t", str(APK), timeout=180)
    adb("shell", "am", "start", "-n", ACTIVITY)
    adb("forward", f"tcp:{TETHER_PORT}", f"tcp:{TETHER_PORT}")
    print(f"companion open, forward tcp:{TETHER_PORT} done")
    time.sleep(SDK_WARMUP_S)


def press_menu(submenu: str, item: str) -> str:
    script = MENU_SCRIPT.replace("__SUBMENU__", submenu).replace("__ITEM__", item)
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    return result.stdout.strip() or result.stderr.strip()


def drop_link() -> str:
    """Drops the way out (phone -> watch) with everything up: **adb Connection > Release**.

    Measured on 2026-10-14 (C13b), with the bridge proof before and after each lever:

    * ``adb forward --remove tcp:7381`` **does not drop it**: the already open connection
      stays alive and the probes keep arriving;
    * ``Release`` drops it right away. The **first** ``sendMessage`` after it still returns
      ``SUCCESS`` and the message is lost; from the second on it is ``FAILURE_UNKNOWN``;
    * ``Start`` again reconnects **in the same** companion process, without restarting the SDK
      (two cycles in a row, first probe delivered 2 s after ``Start``).

    The way back (the console relay) does not drop with it: on the PC only the way out is dropped."""
    return press_menu("adb", "^Release")


def restore_link() -> str:
    """Reconnects the way out after :func:`drop_link`: **adb Connection > Start**."""
    return press_menu("adb", "^Start")


def press_key(key: str, mode: str = "post") -> str:
    """Presses a key on the virtual watch (``ENTER``, ``DOWN``, ``UP``, ``ESC``)."""
    vk, send = KEY_CODES[key]
    script = KEY_SCRIPT.replace("__MODE__", mode).replace("__VK__", str(vk)).replace("__SEND__", send)
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script], capture_output=True, text=True)
    return result.stdout.strip() or result.stderr.strip()


def send_probe(probe_id: str) -> None:
    adb("shell", "am", "broadcast", "-a", ACTION, "-n", RECEIVER, "--es", "id", probe_id, check=False)


def send_command(text: str) -> None:
    """A command to the app in the simulator (``PONTE:CMD:<text>``, C11)."""
    adb("shell", "am", "broadcast", "-a", CMD_ACTION, "-n", RECEIVER, "--es", "text", f"'{text}'", check=False)


def logcat_r2c(probe_id: str) -> str | None:
    text = adb("logcat", "-d", "-s", "WatchLink:I", check=False, timeout=30).stdout
    match = re.search(rf"PONTE:R2C:{probe_id}\b", text)
    return match.group(0) if match else None


def relay(text: str) -> bool:
    """Hands the companion what the watch printed in ``PONTE:TX:``."""
    if "'" in text:
        return False  # Base64 and the proof never have quotes; the rest is not ours.
    result = adb("shell", "am", "broadcast", "-a", RELAY_ACTION, "-n", RECEIVER, "--es", "text", f"'{text}'",
                 check=False)
    return result.returncode == 0


def run(timeout_s: int, socket_mode: bool) -> int:
    ensure_emulator()
    install_and_open()

    jungle, prg = (SOCKET_JUNGLE, SOCKET_PRG) if socket_mode else (BRIDGE_JUNGLE, BRIDGE_PRG)
    if not sim.compile_prg([JUNGLE, jungle], prg, unit_test=False):
        print("the bridge .prg did not compile")
        return 1
    sim.ensure_simulator()

    probe_id = str(int(time.time()))
    c2r = f"PONTE:C2R:{probe_id}"
    state = {"started": None, "next_probe": None, "c2r_at": None, "next_logcat": 0.0, "r2c": None,
             "probes": 0, "relayed": 0}

    def on_line(line: str, elapsed: float) -> None:
        if state["started"] is None and APP_START.match(line):
            state["started"] = elapsed
            print(f"app in the simulator ({elapsed:.1f} s): {press_menu('adb', '^Start')}")
            state["next_probe"] = elapsed + FIRST_PROBE_S
        if line.strip() == c2r and state["c2r_at"] is None:
            state["c2r_at"] = elapsed
            print(f"simulator: {c2r} ({elapsed:.1f} s)")
        elif line.startswith(TX_PREFIX):
            # Every `transmit` from the app goes through the relay: the proof's answer and
            # also the log that `PhoneLink` sends every 15 s.
            if relay(line[len(TX_PREFIX):].strip()):
                state["relayed"] += 1
        elif line.startswith("bridge r2c"):
            print(f"simulator: {line.strip()}")

    def on_idle(elapsed: float) -> bool:
        """Sends the probe until the watch prints; then waits for the answer in
        logcat. Returns ``True`` when the run has already answered."""
        if state["c2r_at"] is None:
            due = state["next_probe"]
            if due is not None and elapsed >= due:
                state["probes"] += 1
                send_probe(probe_id)
                state["next_probe"] = elapsed + PROBE_EVERY_S
            return False
        if elapsed >= state["next_logcat"]:
            state["r2c"] = logcat_r2c(probe_id)
            state["next_logcat"] = elapsed + LOGCAT_EVERY_S
        return state["r2c"] is not None or elapsed - state["c2r_at"] > R2C_WAIT_S

    text, timed_out = run_live_until(prg, timeout_s, on_line, on_idle)
    sim.save("ponte_socket.log" if socket_mode else "ponte.log", text)
    if socket_mode:
        # The real `transmit` leaves the simulator in a state where the next run
        # receives nothing (measured on 2026-10-09: even the app's 1 s tick
        # stopped). Closed here, `ensure_simulator` opens a clean one.
        subprocess.run(["taskkill", "/IM", "simulator.exe", "/F"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    r2c = state["r2c"] or logcat_r2c(probe_id)
    got_c2r = state["c2r_at"] is not None
    way_back = ("through the TETHERED transmit" if socket_mode
                else f"through the console relay, {state['relayed']} line(s)")
    print()
    print(f"probes sent: {state['probes']}" + (f"; {timeout_s} s deadline hit" if timed_out else ""))
    print(f"C2R phone -> watch, through TETHERED: {c2r if got_c2r else 'NOT received'}")
    print(f"R2C watch -> phone, {way_back}: {r2c or 'NOT received'}")
    if state["started"] is None:
        print("the app did not print [diag] start: Start was never pressed")
    elif not got_c2r:
        print("no probe arrived: if the simulator comes from a --socket run or from a dead "
              "monkeydo, close it (taskkill /IM simulator.exe /F) and run again")
    if got_c2r and r2c:
        if socket_mode:
            print("bridge: OK through the socket — the simulator was fixed; the relay can go (DECISIONS §C7a)")
        else:
            print("bridge: OK — way out through TETHERED, way back through the relay (the 9.2.0 simulator's "
                  "transmit freezes the app: CIQQA-4579, DECISIONS §C7a)")
        return 0
    log = "ponte_socket.log" if socket_mode else "ponte.log"
    print(f"bridge: NO — raw output in shots/{log}; the companion side in "
          f"adb -s {SERIAL} logcat -d -s WatchLink BridgeReceiver")
    return 1


def run_live_until(prg: Path, timeout_s: int, on_line, on_idle) -> tuple[str, bool]:
    """`sim.run_live` with early exit: when ``on_idle`` returns
    ``True``, ``monkeydo`` (which never exits on its own in a normal run) is
    killed and the run ends. Returns (output, timed out)."""
    process = subprocess.Popen([str(sim.tool("monkeydo")), str(prg), sim.DEVICE],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    pending: list[str] = []
    lock = threading.Lock()

    def pump() -> None:
        for raw in iter(process.stdout.readline, b""):
            with lock:
                pending.append(sim.decode_line(raw))

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    started = time.monotonic()
    lines: list[str] = []

    def drain() -> None:
        with lock:
            batch = pending[:]
            pending.clear()
        for item in batch:
            lines.append(item)
            on_line(item, time.monotonic() - started)

    timed_out = False
    while True:
        drain()
        if process.poll() is not None and not reader.is_alive():
            break
        elapsed = time.monotonic() - started
        timed_out = elapsed > timeout_s
        if timed_out or on_idle(elapsed):
            # Killing `monkeydo` with the app open hangs the simulator (measured
            # on 2026-09-29 in `sim.py`, and again here on 2026-10-09: the next run
            # sat 120 s without a line). Kill App closes the app
            # first; `kill_tree` is left for whatever remains.
            press_menu("File", "^Kill App")
            try:
                process.wait(timeout=KILL_APP_WAIT_S)
            except subprocess.TimeoutExpired:
                pass
            sim.kill_tree(process)
            reader.join(timeout=5)
            drain()
            break
        time.sleep(0.2)
    return "\n".join(lines) + "\n", timed_out


ADB = find_sdk_tool("platform-tools/adb")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S,
                        help=f"seconds of simulator before giving up (default {DEFAULT_TIMEOUT_S})")
    parser.add_argument("--socket", action="store_true",
                        help="the way back through the real Communications.transmit, no relay: "
                             "reproduces the simulator freeze (CIQQA-4579)")
    args = parser.parse_args()
    return run(args.timeout, args.socket)


if __name__ == "__main__":
    sys.exit(main())
