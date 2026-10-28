#!/usr/bin/env python3
"""Generate the Monkey C test vectors for the watch assembler.

The simulator cannot talk to the Android app, so both sides are validated
against the same bytes instead (docs/08-CODEX-GUIDE.md §Integrated testing): the
Kotlin packer is compared byte-for-byte with the fixtures, and the Monkey C
assembler parses the vectors emitted here.

The route is synthetic on purpose — small, but it exercises every branch the
real data can hit: an escape delta, a roundabout with an exit number, an
accented street name that has to be truncated on a codepoint boundary, and a
block split across two chunks.

Usage:
    python tools/gen_watch_test_vectors.py
"""

from __future__ import annotations

import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import design_tokens  # noqa: E402
import packer  # noqa: E402

OUT = Path(__file__).parent.parent / "watch" / "source" / "test" / "TestVectors.mc"
CONFIG_FIXTURE = Path(__file__).parent / "fixtures" / "config_00.bin"
REROUTE_FIXTURE = Path(__file__).parent / "fixtures" / "reroute_req_00.bin"
FAVORITES_FIXTURE = Path(__file__).parent / "fixtures" / "favorites_00.bin"
NAV_START_FIXTURE = Path(__file__).parent / "fixtures" / "nav_start_req_00.bin"
RECENTS_FIXTURE = Path(__file__).parent / "fixtures" / "recents_00.bin"
NAV_START_RECENT_FIXTURE = Path(__file__).parent / "fixtures" / "nav_start_req_01.bin"
ROUTE_UPDATE_FIXTURE = Path(__file__).parent / "fixtures" / "route_update_00.bin"
PHONE_FIX_FIXTURE = Path(__file__).parent / "fixtures" / "phone_fix_00.bin"
FIX_REQ_FIXTURE = Path(__file__).parent / "fixtures" / "fix_req_00.bin"
RADARS_FIXTURE = Path(__file__).parent / "fixtures" / "radars_00.bin"
PACE_FIXTURE = Path(__file__).parent / "fixtures" / "ritmo.json"

# ~0.5 degree jump between p1 and p2 forces the int32 escape pair.
ROUTE = packer.Route(
    points=[
        (-2356145, -4665584),
        (-2356100, -4665500),
        (-2306100, -4665500),
        (-2306050, -4665450),
    ],
    turns=[
        packer.Turn(0, packer.TURN_DEPART, "Avenida Paulista"),
        packer.Turn(1, packer.TURN_ROUNDABOUT, "Praça da República", exit_num=3),
        packer.Turn(2, packer.TURN_LEFT, "Rua General Panteleão Teles do Amaral"),
        # C16.5: roundabout with the exit angle, which also carries exitNum (05 §TURNS).
        packer.Turn(2, packer.TURN_ROUNDABOUT_LEFT, "Praça Oswaldo Cruz", exit_num=4),
        packer.Turn(3, packer.TURN_ARRIVE, ""),
    ],
    distance_m=13263,
    duration_s=1710,
    dest_name="Aeroporto de Congonhas",
)
ROUTE_ID = 7
#: Small enough to split TURNS across two chunks, exercising reassembly.
SPLIT_CHUNK_SIZE = packer.HEADER_SIZE + 64

#: One CORRIDOR block with two ways, chosen to hit the branches the parser can
#: take: a way whose points fit in int16 deltas, and one whose second point is
#: far enough to force the escape pair. Coordinates orbit the route's origin so
#: the projected metres stay small and easy to assert on.
CORRIDOR_LOD = packer.LOD_ARTERIAL
CORRIDOR_WAYS = [
    [(-2356100, -4665600), (-2356050, -4665550), (-2356000, -4665500)],
    [(-2356200, -4665700), (-2306200, -4665700)],  # ~0.5 degree -> escape pair
]


#: The longest byte literal the generator emits in one `const`. On Windows the
#: Connect IQ 9.2.0 compiler (`monkeyc.bat`) dies with a `StackOverflowError` in
#: its `ConstTypeChecker` on the 2 824-byte RADARS_OVER_CAP (2026-10-24,
#: job 952); macOS compiled it, and every other vector here is under 300 bytes.
#: 256 sits under the largest size known to compile on both machines.
MONKEYC_SLICE = 256


def monkeyc_bytes(name: str, data: bytes) -> str:
    if len(data) > MONKEYC_SLICE:
        raise ValueError(f"{name}: {len(data)} B in one const; use monkeyc_bytes_fn (MONKEYC_SLICE)")
    body = ", ".join(f"0x{b:02X}" for b in data)
    return f"    const {name} = [{body}]b;\n"


def monkeyc_bytes_fn(name: str, function: str, data: bytes) -> str:
    """A vector longer than [MONKEYC_SLICE]: slices of it as `const NAME_i`, and a
    function that glues them into a new ByteArray on every call (the consts are
    never changed, so one test cannot leak into another)."""
    slices = [data[i:i + MONKEYC_SLICE] for i in range(0, len(data), MONKEYC_SLICE)]
    out = [monkeyc_bytes(f"{name}_{i}", part) for i, part in enumerate(slices)]
    out.append(f"    function {function}() as ByteArray {{\n")
    out.append("        var out = []b;\n")
    out += [f"        out.addAll({name}_{i});\n" for i in range(len(slices))]
    out.append("        return out;\n")
    out.append("    }\n")
    return "".join(out)


def config_vectors() -> list[str]:
    """CONFIG (0x09): the fixture itself, plus the messages the watch must refuse.

    `CONFIG` is read from `tools/fixtures/config_00.bin`, **the same file** the
    Kotlin `configMatchesFixture` compares against; a fixture that no longer
    matches `packer.CONFIG_SAMPLE` stops the generator here.
    """
    fixture = CONFIG_FIXTURE.read_bytes()
    assert fixture == packer.config_frame(packer.CONFIG_SAMPLE), (
        "config_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )
    # The floor of the HUD scale comes from the legibility sum in design_tokens.py
    # (no text under 13 px, C16.5), the same number generated into
    # DesignTokens.HUD_SCALE_MIN_PCT.
    tokens = design_tokens.json.loads(design_tokens.TOKENS.read_text(encoding="utf-8"))
    hud_min, _ = design_tokens.scale_range(tokens)
    lead = packer.CONFIG_KEYS["lead_s"]
    duplicate = packer.chunk(packer.MSG_CONFIG, 0, bytes([2, lead, 0, 10, lead, 0, 11]))[0]

    lines = [f"    const CONFIG_{name.upper()} = {value};\n" for name, value in packer.CONFIG_SAMPLE.items()]
    lines += [
        monkeyc_bytes("CONFIG", fixture),
        # lead_s 16: one past the watch's ceiling of 15 (Config.mc, DECISIONS §C5).
        monkeyc_bytes("CONFIG_OUT_OF_RANGE", packer.config_frame({"lead_s": 16})),
        f"    const CONFIG_HUD_LOW_PCT = {hud_min - 1};\n",
        monkeyc_bytes("CONFIG_HUD_LOW", packer.config_frame({"hud_pct": hud_min - 1})),
        monkeyc_bytes("CONFIG_HUD_MIN", packer.config_frame({"hud_pct": hud_min})),
        monkeyc_bytes("CONFIG_LEAD10", packer.config_frame({"lead_s": 10})),
        monkeyc_bytes("CONFIG_RESET", packer.config_frame({})),
        # Key 42 does not exist: ignored, and lead_s 12 still applies.
        monkeyc_bytes("CONFIG_UNKNOWN_KEY", packer.config_frame({"lead_s": 12, 42: 7})),
        # near_m 50 is inside 10..60 but not below lead_min_m 40: refused whole.
        monkeyc_bytes("CONFIG_NEAR_OVER_LEAD", packer.config_frame({"lead_min_m": 40, "near_m": 50})),
        monkeyc_bytes("CONFIG_DUPLICATE", duplicate),
    ]
    return lines


def reroute_vectors() -> list[str]:
    """REROUTE_REQ (0x82): the fields and the frame of `reroute_req_00.bin`,
    **the same file** the Kotlin `RerouteReq` reader is tested against. The
    watch builds the frame from the fields and has to land on these bytes."""
    fixture = REROUTE_FIXTURE.read_bytes()
    sample = packer.REROUTE_REQ_SAMPLE
    assert fixture == packer.reroute_req_frame(**sample), (
        "reroute_req_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )
    return [
        f"    const REROUTE_ROUTE_ID = {sample['route_id']};\n",
        f"    const REROUTE_LAT_E5 = {sample['lat_e5']};\n",
        f"    const REROUTE_LON_E5 = {sample['lon_e5']};\n",
        f"    const REROUTE_HEADING_DEG = {sample['heading_deg']};\n",
        f"    const REROUTE_DIST_ALONG_M = {sample['dist_along_m']};\n",
        monkeyc_bytes("REROUTE_REQ", fixture),
    ]


def raw_favorites_frame(payload: bytes) -> bytes:
    """A FAVORITES frame around a hand-made payload, for the messages the
    packer itself refuses to build (the watch has to refuse them too)."""
    (message,) = packer.chunk(packer.MSG_FAVORITES, 0, payload)
    return message


def raw_item(fav_id: int, name: bytes, lat: int = -2354522, lon: int = -4664218, icon: int = 1) -> bytes:
    return struct.pack(">Bii", fav_id, lat, lon) + struct.pack(">B", len(name)) + name + struct.pack(">B", icon)


def favorites_vectors() -> list[str]:
    """FAVORITES (0x05): **the fixture itself** (`favorites_00.bin`, the file the
    Kotlin `favoritesMatchFixture` compares against), the fields it must decode
    to, and the messages the watch has to refuse whole (05 §FAVORITES)."""
    fixture = FAVORITES_FIXTURE.read_bytes()
    sample = packer.FAVORITES_SAMPLE
    assert fixture == packer.favorites_frame(sample), (
        "favorites_00.bin is stale: run python tools/packer.py --favoritos"
    )
    nav = NAV_START_FIXTURE.read_bytes()
    assert nav == packer.nav_start_req_frame(**packer.NAV_START_REQ_SAMPLE), (
        "nav_start_req_00.bin is stale: run python tools/packer.py --favoritos"
    )
    ids = ", ".join(str(item["fav_id"]) for item in sample)
    lats = ", ".join(str(item["lat_e5"]) for item in sample)
    lons = ", ".join(str(item["lon_e5"]) for item in sample)
    icons = ", ".join(str(item["icon"]) for item in sample)
    names = ", ".join('"' + item["name"] + '"' for item in sample)
    replacement = [{"fav_id": 9, "name": "Mercado Municipal", "lat_e5": -2354139, "lon_e5": -4662917, "icon": 7}]
    seven = b"".join(raw_item(i + 1, f"F{i}".encode()) for i in range(7))
    three_items = raw_item(1, b"A") + raw_item(2, b"B") + raw_item(3, b"C")
    return [
        f"    const FAV_COUNT = {len(sample)};\n",
        f"    const FAV_IDS = [{ids}];\n",
        f"    const FAV_LATS = [{lats}];\n",
        f"    const FAV_LONS = [{lons}];\n",
        f"    const FAV_ICONS = [{icons}];\n",
        f"    const FAV_NAMES = [{names}];\n",
        monkeyc_bytes("FAVORITES", fixture),
        f'    const FAV_REPLACEMENT_NAME = "{replacement[0]["name"]}";\n',
        f"    const FAV_REPLACEMENT_ID = {replacement[0]['fav_id']};\n",
        monkeyc_bytes("FAVORITES_REPLACEMENT", packer.favorites_frame(replacement)),
        monkeyc_bytes("FAVORITES_EMPTY", packer.favorites_frame([])),
        # Refused whole: seven items, a repeated id, a count that promises more than
        # arrives, a name one byte over the 20 B cap, and a byte left over.
        monkeyc_bytes("FAVORITES_TOO_MANY", raw_favorites_frame(bytes([7]) + seven)),
        monkeyc_bytes("FAVORITES_DUPLICATE_ID", raw_favorites_frame(bytes([2]) + raw_item(1, b"A") + raw_item(1, b"B"))),
        monkeyc_bytes("FAVORITES_TRUNCATED", raw_favorites_frame(bytes([3]) + raw_item(1, b"A"))),
        monkeyc_bytes("FAVORITES_NAME_TOO_LONG", raw_favorites_frame(bytes([1]) + raw_item(1, b"X" * 21))),
        monkeyc_bytes("FAVORITES_TRAILING_BYTE", raw_favorites_frame(bytes([1]) + raw_item(1, b"A") + b"\x00")),
        monkeyc_bytes("FAVORITES_THREE_SHORT", raw_favorites_frame(bytes([3]) + three_items)),
        f"    const NAV_START_FAV_ID = {packer.NAV_START_REQ_SAMPLE['fav_id']};\n",
        monkeyc_bytes("NAV_START_REQ", nav),
    ]


def recents_vectors() -> list[str]:
    """RECENTS (0x0B, C16.5): **the fixture itself** (`recents_00.bin`, the file the Kotlin
    `recentsMatchFixture` compares against), the fields it must decode to, the six-item list the
    watch has to refuse (05 §RECENTS: at most 5) and the NAV_START_REQ of a recent, with `kind`."""
    fixture = RECENTS_FIXTURE.read_bytes()
    sample = packer.RECENTS_SAMPLE
    assert fixture == packer.recents_frame(sample), (
        "recents_00.bin is stale: run python tools/packer.py --favoritos"
    )
    nav = NAV_START_RECENT_FIXTURE.read_bytes()
    assert nav == packer.nav_start_req_frame(**packer.NAV_START_REQ_RECENT_SAMPLE), (
        "nav_start_req_01.bin is stale: run python tools/packer.py --favoritos"
    )
    ids = ", ".join(str(item["fav_id"]) for item in sample)
    names = ", ".join('"' + item["name"] + '"' for item in sample)
    six = b"".join(raw_item(i + 1, f"R{i}".encode()) for i in range(6))
    (too_many,) = packer.chunk(packer.MSG_RECENTS, 0, bytes([6]) + six)
    return [
        f"    const RECENT_COUNT = {len(sample)};\n",
        f"    const RECENT_IDS = [{ids}];\n",
        f"    const RECENT_NAMES = [{names}];\n",
        monkeyc_bytes("RECENTS", fixture),
        monkeyc_bytes("RECENTS_TOO_MANY", too_many),
        f"    const NAV_START_RECENT_ID = {packer.NAV_START_REQ_RECENT_SAMPLE['fav_id']};\n",
        f"    const NAV_START_KIND_RECENT = {packer.NAV_START_KIND_RECENT};\n",
        monkeyc_bytes("NAV_START_REQ_RECENT", nav),
    ]


def route_update_vectors() -> list[str]:
    """ROUTE_UPDATE (0x06): **the fixture itself** (`route_update_00.bin`, the
    file the Kotlin `routeUpdateMatchesFixture` compares against), and the
    messages the watch has to refuse (05 §ROUTE_UPDATE). The fixture is about
    the route of these vectors, so the watch test applies it to that route."""
    fixture = ROUTE_UPDATE_FIXTURE.read_bytes()
    sample = packer.ROUTE_UPDATE_SAMPLE
    assert fixture == packer.route_update_frame(**sample), (
        "route_update_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )
    assert sample["route_id"] == ROUTE_ID, "the ROUTE_UPDATE fixture must be about the route of the vectors"
    assert sample["duration_s"] != ROUTE.duration_s, "an update equal to the META proves nothing"

    def raw(payload: bytes) -> bytes:
        (message,) = packer.chunk(packer.MSG_ROUTE_UPDATE, ROUTE_ID, payload)
        return message

    whole = packer.pack_route_update(sample["duration_s"])
    return [
        f"    const ROUTE_UPDATE_DURATION_S = {sample['duration_s']};\n",
        monkeyc_bytes("ROUTE_UPDATE", fixture),
        # Refused: a byte short, a byte over, zero, the sign bit, and two chunks.
        monkeyc_bytes("ROUTE_UPDATE_SHORT", raw(whole[:3])),
        monkeyc_bytes("ROUTE_UPDATE_LONG", raw(whole + b"\x00")),
        monkeyc_bytes("ROUTE_UPDATE_ZERO", raw(struct.pack(">I", 0))),
        monkeyc_bytes("ROUTE_UPDATE_NEGATIVE", raw(struct.pack(">I", 0x80000000))),
        monkeyc_bytes("ROUTE_UPDATE_TWO_CHUNKS", packer.frame(packer.MSG_ROUTE_UPDATE, ROUTE_ID, 0, 2, whole)),
    ]


def phone_fix_vectors() -> list[str]:
    """PHONE_FIX (0x0A) and FIX_REQ (0x86): **the fixtures themselves**
    (`phone_fix_00.bin`, the file the Kotlin `phoneFixMatchesFixture` compares
    against, and `fix_req_00.bin`, the one `FixReqTest` reads), and the fixes
    the watch has to drop (05 §PHONE_FIX)."""
    fixture = PHONE_FIX_FIXTURE.read_bytes()
    sample = packer.PHONE_FIX_SAMPLE
    assert fixture == packer.phone_fix_frame(**sample), (
        "phone_fix_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )
    request = FIX_REQ_FIXTURE.read_bytes()
    assert request == packer.fix_req_frame(**packer.FIX_REQ_SAMPLE), (
        "fix_req_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )
    assert packer.FIX_REQ_SAMPLE["on"], "the FIX_REQ fixture is the request that turns the phone on"

    def raw(payload: bytes) -> bytes:
        (message,) = packer.chunk(packer.MSG_PHONE_FIX, 0, payload)
        return message

    whole = packer.pack_phone_fix(**sample)
    off_the_map = struct.pack(">i", packer.MAX_LAT_E5 + 1) + whole[4:]
    return [
        f"    const PHONE_FIX_LAT_E5 = {sample['lat_e5']};\n",
        f"    const PHONE_FIX_LON_E5 = {sample['lon_e5']};\n",
        f"    const PHONE_FIX_SPEED_DMS = {sample['speed_dms']};\n",
        f"    const PHONE_FIX_HEADING_DEG = {sample['heading_deg']};\n",
        f"    const PHONE_FIX_ACCURACY_M = {sample['accuracy_m']};\n",
        f"    const PHONE_FIX_AGE_MS = {sample['age_ms']};\n",
        monkeyc_bytes("PHONE_FIX", fixture),
        monkeyc_bytes("PHONE_FIX_NO_HEADING", packer.phone_fix_frame(**{**sample, "heading_deg": None})),
        # Dropped: a byte short, a byte over, a latitude past the pole, and two chunks.
        monkeyc_bytes("PHONE_FIX_SHORT", raw(whole[:-1])),
        monkeyc_bytes("PHONE_FIX_LONG", raw(whole + b"\x00")),
        monkeyc_bytes("PHONE_FIX_OFF_THE_MAP", raw(off_the_map)),
        monkeyc_bytes("PHONE_FIX_TWO_CHUNKS", packer.frame(packer.MSG_PHONE_FIX, 0, 0, 2, whole)),
        monkeyc_bytes("FIX_REQ_ON", request),
        monkeyc_bytes("FIX_REQ_OFF", packer.fix_req_frame(False)),
    ]


def radars_vectors() -> list[str]:
    """RADARS (0x08): **the fixture itself** (`radars_00.bin`, the file the Kotlin
    `radarsMatchFixture` compares against), the same payload on the route of these
    vectors, and the messages the watch has to refuse or cut (05 §RADARS)."""
    fixture = RADARS_FIXTURE.read_bytes()
    sample = packer.RADARS_SAMPLE
    _, fixture_route, _, _, _ = packer.unframe(fixture)
    assert fixture == packer.radars_frame(sample, fixture_route), (
        "radars_00.bin is stale: run tools/packer.py (see docs/STATUS.md §How to run everything)"
    )

    def raw(payload: bytes) -> bytes:
        (message,) = packer.chunk(packer.MSG_RADARS, ROUTE_ID, payload)
        return message

    whole = packer.pack_radars(sample)
    swapped = sample[:2][::-1]  # 5400 before 1200
    out_of_order = struct.pack(">H", 2) + b"".join(
        struct.pack(">IiiBB", r["dist_along_m"], r["dlat"], r["dlon"], r["limit_kmh"], r["flags"]) for r in swapped
    )
    over = [
        {"dist_along_m": 100 * i, "dlat": i, "dlon": -i, "limit_kmh": 40, "flags": 1}
        for i in range(packer.MAX_RADARS + 1)
    ]
    over_payload = struct.pack(">H", len(over)) + b"".join(
        struct.pack(">IiiBB", r["dist_along_m"], r["dlat"], r["dlon"], r["limit_kmh"], r["flags"]) for r in over
    )
    lines = [
        f"    const RADARS_COUNT = {len(sample)};\n",
        f"    const RADARS_MAX = {packer.MAX_RADARS};\n",
    ]
    for i, radar in enumerate(sample):
        lines += [
            f"    const RADAR{i}_DIST_M = {radar['dist_along_m']};\n",
            f"    const RADAR{i}_DLAT = {radar['dlat']};\n",
            f"    const RADAR{i}_DLON = {radar['dlon']};\n",
            f"    const RADAR{i}_LIMIT = {radar['limit_kmh']};\n",
            f"    const RADAR{i}_FLAGS = {radar['flags']};\n",
        ]
    return lines + [
        monkeyc_bytes("RADARS_FIXTURE", fixture),
        f"    const RADARS_FIXTURE_ROUTE_ID = {fixture_route};\n",
        monkeyc_bytes("RADARS", raw(whole)),
        monkeyc_bytes("RADARS_EMPTY", raw(packer.pack_radars([]))),
        # Refused whole: a record short, a byte over, out of distAlong order, two chunks.
        monkeyc_bytes("RADARS_SHORT", raw(whole[:-1])),
        monkeyc_bytes("RADARS_LONG", raw(whole + b"\x00")),
        monkeyc_bytes("RADARS_OUT_OF_ORDER", raw(out_of_order)),
        monkeyc_bytes("RADARS_TWO_CHUNKS", packer.frame(packer.MSG_RADARS, ROUTE_ID, 0, 2, whole)),
        # Over the cap: well formed, the watch keeps the first MAX_RADARS (rule 3).
        monkeyc_bytes_fn("RADARS_OVER_CAP", "radarsOverCap", raw(over_payload)),
    ]


def pace_vectors() -> list[str]:
    """The paced duration (C16, `PersonalPace.kt`): not protocol, the same
    ROUTE_UPDATE with the number the phone sends once it has learned the
    rider's pace from `tools/fixtures/ritmo.json`. The Kotlin `PersonalPaceTest`
    checks that file's `watch_s` against its own math; the watch test checks
    that the HUD shows it."""
    sample = json.loads(PACE_FIXTURE.read_text(encoding="utf-8"))
    assert sample["mapbox_s"] == ROUTE.duration_s, "ritmo.json must pace the route of the vectors"
    assert sample["watch_s"] != ROUTE.duration_s, "a paced duration equal to the META proves nothing"
    (message,) = packer.chunk(packer.MSG_ROUTE_UPDATE, ROUTE_ID, packer.pack_route_update(sample["watch_s"]))
    return [
        f"    const PACE_MAPBOX_S = {sample['mapbox_s']};\n",
        f"    const PACE_WATCH_S = {sample['watch_s']};\n",
        monkeyc_bytes("ROUTE_UPDATE_PACE", message),
    ]


def main() -> None:
    meta =packer.chunk(packer.MSG_ROUTE_META, ROUTE_ID, packer.pack_route_meta(ROUTE))
    poly = packer.chunk(packer.MSG_ROUTE_POLY, ROUTE_ID, packer.pack_route_poly(ROUTE))
    turns = packer.chunk(packer.MSG_TURNS, ROUTE_ID, packer.pack_turns(ROUTE), SPLIT_CHUNK_SIZE)
    assert len(meta) == 1 and len(poly) == 1, "meta/poly should fit one chunk"
    assert len(turns) == 2, f"expected TURNS to split in two chunks, got {len(turns)}"

    corridor_payload = packer.pack_corridor(CORRIDOR_LOD, CORRIDOR_WAYS, ROUTE.lat0, ROUTE.lon0)
    corridor = packer.chunk(packer.MSG_CORRIDOR, ROUTE_ID, corridor_payload)
    assert len(corridor) == 1, "corridor vector should fit one chunk"

    truncated = packer.truncate_utf8(ROUTE.turns[2].street_name, packer.MAX_STREET_NAME_BYTES)

    lines = [
        "import Toybox.Lang;\n",
        "\n",
        "//! GENERATED by tools/gen_watch_test_vectors.py — do not edit by hand.\n",
        "//! Same protocol bytes the Kotlin packer is tested against.\n",
        "(:test)\n",
        "module TestVectors {\n",
        "\n",
        f"    const ROUTE_ID = {ROUTE_ID};\n",
        f"    const POINT_COUNT = {len(ROUTE.points)};\n",
        f"    const TURN_COUNT = {len(ROUTE.turns)};\n",
        f"    const DISTANCE_M = {ROUTE.distance_m};\n",
        f"    const DURATION_S = {ROUTE.duration_s};\n",
        f'    const DEST_NAME = "{ROUTE.dest_name}";\n',
        f"    const LAT0 = {ROUTE.lat0};\n",
        f"    const LON0 = {ROUTE.lon0};\n",
        f"    const LAST_LAT = {ROUTE.points[-1][0]};\n",
        f"    const LAST_LON = {ROUTE.points[-1][1]};\n",
        f"    const ROUNDABOUT_EXIT = {ROUTE.turns[1].exit_num};\n",
        f"    const ANGLED_ROUNDABOUT_TYPE = {ROUTE.turns[3].type};\n",
        f"    const ANGLED_ROUNDABOUT_EXIT = {ROUTE.turns[3].exit_num};\n",
        f'    const ANGLED_ROUNDABOUT_NAME = "{ROUTE.turns[3].street_name}";\n',
        f'    const LONG_NAME_TRUNCATED = "{truncated.decode("utf-8")}";\n',
        "\n",
        monkeyc_bytes("META", meta[0]),
        monkeyc_bytes("POLY", poly[0]),
        monkeyc_bytes("TURNS_0", turns[0]),
        monkeyc_bytes("TURNS_1", turns[1]),
        "\n",
        f"    const CORRIDOR_LOD = {CORRIDOR_LOD};\n",
        f"    const CORRIDOR_WAY_COUNT = {len(CORRIDOR_WAYS)};\n",
        f"    const CORRIDOR_POINT_COUNT = {sum(len(w) for w in CORRIDOR_WAYS)};\n",
        f"    const CORRIDOR_LAST_LAT = {CORRIDOR_WAYS[-1][-1][0]};\n",
        f"    const CORRIDOR_LAST_LON = {CORRIDOR_WAYS[-1][-1][1]};\n",
        monkeyc_bytes("CORRIDOR", corridor[0]),
        "\n",
        *config_vectors(),
        "\n",
        *reroute_vectors(),
        "\n",
        *favorites_vectors(),
        "\n",
        *recents_vectors(),
        "\n",
        *route_update_vectors(),
        "\n",
        *pace_vectors(),
        "\n",
        *phone_fix_vectors(),
        "\n",
        *radars_vectors(),
        "}\n",
    ]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("".join(lines), encoding="utf-8")
    print(
        f"wrote {OUT} — meta {len(meta[0])} B, poly {len(poly[0])} B, "
        f"turns {len(turns)} chunks, corridor {len(corridor[0])} B"
    )


if __name__ == "__main__":
    main()
