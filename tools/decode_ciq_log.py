#!/usr/bin/env python3
"""Translates the watch's ``CIQ_LOG.YML`` into file:line.

Why this script exists
--------------------------
When the watch app dies, Connect IQ writes
``GARMIN/APPS/LOGS/CIQ_LOG.YML`` with a stack of raw addresses::

    Error: 'Watchdog Tripped Error - Code Executed Too Long'
    Stack:
      - pc: 0x10005013

On their own they say nothing. ``monkeyc`` emits, next to each ``.prg``, a
``.prg.debug.xml`` with the ``pc -> (file, line, symbol)`` table; this script
does the matching — for each ``pc`` in the stack, the last entry with a ``pc`` less than
or equal, which is the instruction being executed.

It also **works out by itself which build produced the log**: it runs the whole stack
against every ``.prg.debug.xml`` in ``watch/bin/`` and scores them. This matters because the
log's ``Filename`` is the name of the copied ``.prg``, and more than once the build on the
watch was not what was assumed (``STATUS.md``, attempt 1).

Usage::

    python tools/decode_ciq_log.py                       # finds the log and the build by itself
    python tools/decode_ciq_log.py path/CIQ_LOG.YML
    python tools/decode_ciq_log.py log.yml --prg watch/bin/MotoNav-v0.15.0-f3a.prg
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import xml.etree.ElementTree as ET
from bisect import bisect_right
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = ROOT / "watch" / "bin"

# Where CIQ_LOG.YML usually lands when Igor copies it from the watch.
DEFAULT_LOG_PLACES = [
    Path(os.environ.get("TEMP", "")) / "CIQ_LOG.YML",
    ROOT / "CIQ_LOG.YML",
    Path.home() / "Downloads" / "CIQ_LOG.YML",
]


@dataclass
class Frame:
    pc: int
    filename: str | None
    line: int | None
    symbol: str | None
    parent: str | None
    exact: bool

    def render(self, root: Path) -> str:
        if self.filename is None:
            return f"  0x{self.pc:08x}  <not in this build's table>"
        path = Path(self.filename)
        try:
            shown = path.relative_to(root)
        except ValueError:
            shown = path
        owner = (self.parent or "globals").replace("globals/", "")
        mark = "" if self.exact else "  (~)"
        return f"  0x{self.pc:08x}  {shown}:{self.line}  {owner}.{self.symbol}{mark}"


class DebugInfo:
    """The ``pc -> line`` table of a ``.prg.debug.xml``."""

    def __init__(self, path: Path) -> None:
        self.path = path
        entries = []
        for entry in ET.parse(path).getroot().iter("entry"):
            pc = entry.get("pc")
            if pc is None:
                continue
            entries.append(
                (
                    int(pc),
                    entry.get("filename", "").replace("\\\\", "\\"),
                    int(entry.get("lineNum", "0")),
                    entry.get("symbol"),
                    entry.get("parent"),
                )
            )
        entries.sort(key=lambda e: e[0])
        self.pcs = [e[0] for e in entries]
        self.entries = entries

        # Address range of each function. It is what decides which build the log
        # came from: the stack's ``pc`` values are **return addresses**, almost never the
        # exact start of a tabulated instruction, so counting exact hits would give
        # 1 in 5 even on the right build. What separates the right build from the wrong one is the
        # whole stack falling *inside* known functions.
        spans: dict[tuple, list[int]] = {}
        for pc, _f, _l, symbol, parent in entries:
            key = (parent, symbol)
            span = spans.get(key)
            if span is None:
                spans[key] = [pc, pc]
            else:
                span[0] = min(span[0], pc)
                span[1] = max(span[1], pc)
        self.spans = sorted(spans.values())

    def resolve(self, pc: int) -> Frame:
        index = bisect_right(self.pcs, pc) - 1
        if index < 0:
            return Frame(pc, None, None, None, None, False)
        found = self.entries[index]
        # An address far beyond the function's last known instruction is not
        # from this build: better to say "I don't know" than to point at the wrong line.
        if pc - found[0] > 4096:
            return Frame(pc, None, None, None, None, False)
        return Frame(pc, found[1], found[2], found[3], found[4], pc == found[0])

    #: A stack ``pc`` is a **return address**: it falls right after the
    #: call instruction, and therefore a few bytes from a tabulated entry.
    #: A larger distance means "this build does not know this address"
    #: — trusting a large distance is what made the decoder pick a wrong
    #: build and print an impossible stack
    #: (``onMenuAction → parseCorridor → parseTurns``), on 2026-08-01.
    NEAR_BYTES = 64

    def score(self, pcs: list[int]) -> tuple[int, int]:
        """How well this table explains the stack: (near frames, -drift).

        Sorts by how many addresses fall **right on** a known instruction and,
        on a tie, by total drift — the smaller, the better.
        """
        near = 0
        drift = 0
        for pc in pcs:
            index = bisect_right(self.pcs, pc) - 1
            if index < 0:
                drift += 1 << 20
                continue
            delta = pc - self.pcs[index]
            drift += delta
            if delta <= self.NEAR_BYTES:
                near += 1
        return (near, -drift)


def parse_log(text: str) -> list[dict]:
    """The ``CIQ_LOG.YML`` reports (it accumulates several, separated by ``---``)."""
    reports = []
    current: dict | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if line == "---":
            if current:
                reports.append(current)
            current = {"stack": []}
            continue
        if current is None:
            continue
        stack = re.match(r"-\s*pc:\s*(0x[0-9a-fA-F]+|\d+)", line)
        if stack:
            current["stack"].append(int(stack.group(1), 0))
            continue
        field = re.match(r"([A-Za-z-]+):\s*'?([^']*)'?\s*$", line)
        if field and field.group(2):
            current[field.group(1)] = field.group(2)
    if current:
        reports.append(current)
    return [r for r in reports if r.get("stack") or r.get("Error")]


def find_log(explicit: str | None) -> Path:
    if explicit:
        return Path(explicit)
    for candidate in DEFAULT_LOG_PLACES:
        if candidate.is_file():
            return candidate
    sys.exit(
        "CIQ_LOG.YML not found. Copy it from the watch (MTP, GARMIN/APPS/LOGS/) and"
        " pass the path as an argument."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", nargs="?", help="path to CIQ_LOG.YML")
    parser.add_argument("--prg", help="the .prg (or .prg.debug.xml) that produced the log")
    args = parser.parse_args()

    log_path = find_log(args.log)
    reports = parse_log(log_path.read_text(encoding="utf-8", errors="replace"))
    if not reports:
        sys.exit(f"{log_path} has no error report")

    if args.prg:
        given = Path(args.prg)
        xml = given if given.suffix == ".xml" else given.with_suffix(".prg.debug.xml")
        candidates = [DebugInfo(xml)]
    else:
        candidates = [DebugInfo(p) for p in sorted(BIN.glob("*.prg.debug.xml"))]
    if not candidates:
        sys.exit(f"no .prg.debug.xml in {BIN} — build before decoding")

    print(f"log: {log_path}\n")

    for number, report in enumerate(reports, start=1):
        pcs = report["stack"]
        best = max(candidates, key=lambda d: d.score(pcs))
        hits = best.score(pcs)[0]

        print(f"── report {number} of {len(reports)} " + "─" * 40)
        for key in ("Time", "Error", "Details", "Filename", "Appname", "Firmware-Version"):
            if report.get(key):
                print(f"  {key}: {report[key]}")
        print()
        if not pcs:
            print("  (no stack)\n")
            continue

        print(f"  build: {best.path.name}  ({hits}/{len(pcs)} frames recognized)")
        if report.get("Filename") and report["Filename"] not in best.path.name:
            # The log's Filename field is the name of the .prg from when the app was
            # installed, and the watch does not update it when overwritten: 'MotoNav-release'
            # has already shown up on a device running 'MotoNav-v0.15.0-f3a'.
            # The stack is what counts.
            print(f"  (the log says '{report['Filename']}' — old file name, ignore)")
        if hits < len(pcs):
            print(
                "  ⚠ not every frame matched closely — distrust the stack below and"
                " check that the watch's `.prg` is really one of these."
            )
            others = sorted(candidates, key=lambda d: d.score(pcs), reverse=True)[1:3]
            for other in others:
                print(f"      alternative: {other.path.name} ({other.score(pcs)[0]}/{len(pcs)})")
        print("\n  stack (top to bottom):")
        for frame in (best.resolve(pc) for pc in pcs):
            print(frame.render(ROOT))
        print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
