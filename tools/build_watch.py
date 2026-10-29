#!/usr/bin/env python3
"""Builds the watch app with the version in the file name.

Why this script exists
--------------------------
The name of the ``.prg`` means **nothing** to Garmin: the app is identified
by the UUID in ``manifest.xml``, which is why copying a file with a new name
replaces the previous install instead of creating a second one. The name exists for
Igor: with ``MotoNav-v0.12.0-f3a.prg`` in hand, there is no way to copy the wrong build —
which once cost an hour of debugging (``STATUS.md``, attempt 1).

The rule that **actually** matters on the watch: keep **one** MotoNav ``.prg`` at a
time in ``GARMIN/APPS/``. Two files with the same UUID is the only way to
confuse the device — which is why this script deletes old release builds
instead of piling them up. Keeping binary history is git's job, and
git does not even version ``watch/bin/``.

The real gain is that the file's version **cannot diverge** from the version on
screen: both come from the same ``AppVersion.LABEL``.

Uso::

    python tools/build_watch.py            # debug, for the simulator
    python tools/build_watch.py --release  # for sideload
    python tools/build_watch.py --test     # with the unit tests
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JUNGLE = ROOT / "watch" / "monkey.jungle"
VERSION_FILE = ROOT / "watch" / "source" / "AppVersion.mc"
#: The device it builds for. The Venu 4 45 mm is the reference (the one on the wrist, and the 454 px
#: every layout number is written in); `MOTONAV_DEVICE` picks another one of the manifest's products
#: (`sim.py --device`, `package.py`).
REFERENCE = "venu445mm"
DEVICE = os.environ.get("MOTONAV_DEVICE", REFERENCE)


def bin_for(device: str) -> Path:
    """Where the builds of `device` go: `watch/bin` for the reference, `watch/bin/<device>` for the others, so
    another model's `.prg` never takes the name of the wrist's (C16.12 review)."""
    return ROOT / "watch" / "bin" if device == REFERENCE else ROOT / "watch" / "bin" / device


BIN = bin_for(DEVICE)


def developer_key() -> Path:
    """The developer key, which stays outside the repo and in the same place on every machine.

    ``CIQ_DEVELOPER_KEY`` wins, for whoever keeps it elsewhere. Without it, the default
    is ``C:\\chaves`` on Windows and ``~/chaves`` on macOS and Linux — the paths
    documented in ``docs/SETUP-MAQUINA.md``. The path is not fixed on any
    system because the Windows user changes between machines and macOS has no
    ``C:``.
    """
    override = os.environ.get("CIQ_DEVELOPER_KEY")
    if override:
        key = Path(override).expanduser()
    elif os.name == "nt":
        key = Path(r"C:\chaves\developer_key")
    else:
        key = Path.home() / "chaves" / "developer_key"

    if not key.is_file():
        sys.exit(
            f"developer key not found at {key}\n"
            "Copy it there, or point CIQ_DEVELOPER_KEY to where it is. "
            "See docs/SETUP-MAQUINA.md."
        )
    return key


def monkeyc() -> Path:
    """The ``monkeyc`` of the newest installed SDK.

    On Windows the executable is the ``.bat``: the extensionless ``monkeyc`` next to it
    is a shell script, and calling it through ``subprocess`` gives
    ``WinError 193 — not a valid Win32 application``. On macOS the SDK also ships the
    ``.bat``, and it is the shell script that runs (C16, first build on macOS).
    """
    if os.name == "nt":
        base = Path(os.environ["APPDATA"]) / "Garmin" / "ConnectIQ" / "Sdks"
    else:
        base = Path.home() / "Library" / "Application Support" / "Garmin" / "ConnectIQ" / "Sdks"

    if not base.is_dir():
        sys.exit(f"no Connect IQ SDK at {base}")
    sdks = sorted(p for p in base.iterdir() if p.is_dir())
    if not sdks:
        sys.exit(f"no Connect IQ SDK at {base}")

    binary = sdks[-1] / "bin"
    return binary / ("monkeyc.bat" if os.name == "nt" else "monkeyc")


def app_version() -> str:
    """``AppVersion.LABEL`` — the same string the app draws on screen."""
    text = VERSION_FILE.read_text(encoding="utf-8")
    match = re.search(r'const\s+LABEL\s*=\s*"([^"]+)"', text)
    if not match:
        sys.exit(f"LABEL not found in {VERSION_FILE}")
    return match.group(1)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true", help="sideload build (-r)")
    parser.add_argument("--test", action="store_true", help="build with unit tests")
    args = parser.parse_args()

    version = app_version()
    BIN.mkdir(parents=True, exist_ok=True)

    if args.test:
        output = BIN / "MotoNavTest.prg"
    elif args.release:
        output = BIN / f"MotoNav-{version}.prg"
    else:
        output = BIN / "MotoNav.prg"

    command = [
        str(monkeyc()),
        "-f", str(JUNGLE),
        "-o", str(output),
        "-y", str(developer_key()),
        "-d", DEVICE,
        "-l", "2",
    ]
    if args.release:
        command.append("-r")
    if args.test:
        command.append("--unit-test")

    print(f"MotoNav {version} -> {output.name}")
    result = subprocess.run(command)
    if result.returncode != 0:
        return result.returncode

    if args.release:
        # One release .prg at a time: the old one is useless here and on the
        # watch it would be a second file with the same UUID.
        for old in BIN.glob("MotoNav-v*.prg"):
            if old != output:
                old.unlink()
                print(f"  removed the old release: {old.name}")
        print(f"\ncopy to Internal Storage\\GARMIN\\APPS\\:\n  {output}")
        print(f"and check on the watch screen that it shows {version}")

    # The `.prg.debug.xml` is the address → line map that `decode_ciq_log.py`
    # uses to read a crash. An orphan, from a release that was already deleted, is the
    # way to decode a crash of one build with the map of another.
    for debug in BIN.glob("*.prg.debug.xml"):
        if not debug.with_name(debug.name[: -len(".debug.xml")]).exists():
            debug.unlink()
            print(f"  removed the orphan map: {debug.name}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
