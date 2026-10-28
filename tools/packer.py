#!/usr/bin/env python3
"""Reference implementation of the phone -> watch protocol (docs/05-PROTOCOL.md).

This module is the source of truth for the binary test vectors: the Kotlin
packer (companion/proto/ProtocolPacker.kt) and the Monkey C assembler
(watch/source/comm/MessageAssembler.mc) are both validated byte-for-byte
against the fixtures produced here.

Framing + ROUTE_META + ROUTE_POLY + TURNS, fed by a real Mapbox Directions
response, the synthetic CORRIDOR (F2), CONFIG (C5), REROUTE_REQ (C11), FAVORITES
and NAV_START_REQ (C12), ROUTE_UPDATE (C13a) and RECENTS (C16.5).

Usage:
    python tools/packer.py --route tools/fixtures/route_sample.json \
                           --out tools/fixtures/
"""

from __future__ import annotations

import argparse
import json
import struct
from dataclasses import dataclass, field
from pathlib import Path

# --- Protocol constants (docs/05-PROTOCOL.md) --------------------------------

#: 2 since C16.5: maneuver types 14..30 and the exitNum of 21..28 (05 §TURNS).
PROTO_VERSION = 2

MSG_ROUTE_META = 0x01
MSG_ROUTE_POLY = 0x02
MSG_TURNS = 0x03
MSG_CORRIDOR = 0x04
MSG_FAVORITES = 0x05
MSG_ROUTE_UPDATE = 0x06
MSG_CANCEL_NAV = 0x07
MSG_RADARS = 0x08
MSG_CONFIG = 0x09
MSG_PHONE_FIX = 0x0A
MSG_RECENTS = 0x0B
MSG_ACK = 0x81
MSG_REROUTE_REQ = 0x82
MSG_NAV_START_REQ = 0x83
MSG_NAV_ENDED = 0x84
# 0x85 is LOG: the watch's own text, nothing to pack here.
MSG_FIX_REQ = 0x86

HEADER_SIZE = 8
#: Size of a whole framed message handed to ConnectIQ.sendMessage, header
#: included. Recalibrated on real hardware in F1 (02 §Risks-4).
CHUNK_SIZE = 4096
MAX_CHUNK_PAYLOAD = CHUNK_SIZE - HEADER_SIZE
MAX_CHUNKS = 255  # `total` is a uint8

#: Escape marker for a delta that does not fit in an int16 (05 §ROUTE_POLY).
DELTA_ESCAPE = 0x7FFF

# Caps protecting the watch (03 §Memory budget, 05 §Robustness rules).
MAX_POLY_POINTS = 4000
MAX_DEST_NAME_BYTES = 40
MAX_STREET_NAME_BYTES = 28

# --- CORRIDOR (0x04) ---------------------------------------------------------

#: Levels of detail, coarsest first (05 §CORRIDOR, 04 §3.3).
LOD_EXPRESS = 0  # motorway, trunk (+links)
LOD_ARTERIAL = 1  # primary, secondary (+links)
LOD_COLLECTOR = 2  # tertiary
LOD_LOCAL = 3  # residential, unclassified
CORRIDOR_LOD_COUNT = 4

#: `pointCount` is a uint8, so a longer OSM way is cut into pieces. The pieces
#: repeat the shared vertex, otherwise a gap of one segment opens on the map.
MAX_WAY_POINTS = 255

#: Hard caps from 04 §3.5, mirror of `Protocol.kt`.
#:
#: Recalibrated on 2026-08-01: the previous 1,200 segments dropped the local LOD
#: (the neighborhood mesh) on every urban route, and that is what made the streets
#: vanish from the screen. They sized the **whole** corridor by the cost of one
#: *frame*, when the watch only draws what fits in a ~380 m radius. What
#: protects the frame now is `MapRenderer`'s adaptive leash; these numbers
#: protect the air and the memory. See `Protocol.kt` for the full reasoning.
MAX_CORRIDOR_SEGMENTS = 2600
MAX_CORRIDOR_BYTES = 32 * 1024

#: A way shorter than this is scenery, not orientation (04 §3.4).
MIN_WAY_LENGTH_M = 20.0

# Turn types (05 §TURNS).
TURN_DEPART = 0
TURN_STRAIGHT = 1
TURN_SLIGHT_RIGHT = 2
TURN_RIGHT = 3
TURN_SHARP_RIGHT = 4
TURN_UTURN = 5
TURN_SHARP_LEFT = 6
TURN_LEFT = 7
TURN_SLIGHT_LEFT = 8
TURN_ROUNDABOUT = 9  # carries an extra exitNum uint8 right after `type`, like 21..28
TURN_HIGHWAY_ENTER = 10
TURN_HIGHWAY_EXIT = 11
TURN_ARRIVE = 12
TURN_NEW_NAME = 13
# C16.5: the Google Navigation SDK icon set (tools/glifos.py) draws these apart.
TURN_FORK_LEFT = 14
TURN_FORK_RIGHT = 15
TURN_MERGE = 16
TURN_MERGE_LEFT = 17
TURN_MERGE_RIGHT = 18
TURN_ARRIVE_LEFT = 19
TURN_ARRIVE_RIGHT = 20
#: Roundabout with the exit drawn at its angle, sharp right (21) counterclockwise to U-turn (28).
TURN_ROUNDABOUT_SHARP_RIGHT = 21
TURN_ROUNDABOUT_RIGHT = 22
TURN_ROUNDABOUT_SLIGHT_RIGHT = 23
TURN_ROUNDABOUT_STRAIGHT = 24
TURN_ROUNDABOUT_SLIGHT_LEFT = 25
TURN_ROUNDABOUT_LEFT = 26
TURN_ROUNDABOUT_SHARP_LEFT = 27
TURN_ROUNDABOUT_UTURN = 28
TURN_HIGHWAY_ENTER_LEFT = 29
TURN_HIGHWAY_EXIT_LEFT = 30
TURN_TYPE_COUNT = 31

#: Upper edge of each 45° bucket of the Mapbox `degrees` (counterclockwise arc around the
#: ring, 180 = straight through), centred on 45, 90 ... 315; past the last one is the U-turn.
ROUNDABOUT_DEGREE_EDGES = (67.5, 112.5, 157.5, 202.5, 247.5, 292.5, 337.5)


def has_exit_num(turn_type: int) -> bool:
    """Roundabouts carry `exitNum` (05 §TURNS): 9, and 21..28 since protoVersion 2."""
    return turn_type == TURN_ROUNDABOUT or TURN_ROUNDABOUT_SHARP_RIGHT <= turn_type <= TURN_ROUNDABOUT_UTURN


def roundabout_by_degrees(degrees: float) -> int:
    for k, edge in enumerate(ROUNDABOUT_DEGREE_EDGES):
        if degrees < edge:
            return TURN_ROUNDABOUT_SHARP_RIGHT + k
    return TURN_ROUNDABOUT_UTURN

_MODIFIER_TO_TURN = {
    "uturn": TURN_UTURN,
    "sharp right": TURN_SHARP_RIGHT,
    "right": TURN_RIGHT,
    "slight right": TURN_SLIGHT_RIGHT,
    "straight": TURN_STRAIGHT,
    "slight left": TURN_SLIGHT_LEFT,
    "left": TURN_LEFT,
    "sharp left": TURN_SHARP_LEFT,
}


# --- Model -------------------------------------------------------------------


@dataclass
class Turn:
    point_idx: int
    type: int
    street_name: str
    exit_num: int = 0


@dataclass
class Route:
    """A route in protocol units: coordinates are degrees x 1e5 (~1.1 m)."""

    points: list[tuple[int, int]]  # (lat_e5, lon_e5), origin -> destination
    turns: list[Turn]
    distance_m: int
    duration_s: int
    dest_name: str
    flags: int = 0  # bit0 hasSpeedLimits (v2), bit1 hasCongestion (v2)
    corridor_lod_count: int = 0
    #: Index of the point where each intermediate stop ends (end of each leg except the last).
    #: It does not go on the wire: the phone uses it to know which stops were left behind (C11).
    stop_idx: list[int] = field(default_factory=list)

    @property
    def lat0(self) -> int:
        return self.points[0][0]

    @property
    def lon0(self) -> int:
        return self.points[0][1]


# --- Primitives --------------------------------------------------------------


def truncate_utf8(text: str, max_bytes: int) -> bytes:
    """Encode `text` to UTF-8, cutting on a codepoint boundary (08 §Gotchas 6)."""
    raw = text.encode("utf-8")
    if len(raw) <= max_bytes:
        return raw
    cut = max_bytes
    while cut > 0 and (raw[cut] & 0xC0) == 0x80:  # do not split a multibyte char
        cut -= 1
    return raw[:cut]


def pack_string(text: str, max_bytes: int) -> bytes:
    raw = truncate_utf8(text, max_bytes)
    return struct.pack(">B", len(raw)) + raw


def frame(msg_type: int, route_id: int, seq: int, total: int, payload: bytes) -> bytes:
    """Wrap `payload` in the 8-byte header of 05 §Framing (big-endian)."""
    if len(payload) > 0xFFFF:
        raise ValueError("payload longer than uint16")
    if not 0 <= seq < total <= MAX_CHUNKS:
        raise ValueError(f"invalid seq/total: {seq}/{total}")
    header = struct.pack(">BBHBBH", PROTO_VERSION, msg_type, route_id, seq, total, len(payload))
    return header + payload


def unframe(message: bytes) -> tuple[int, int, int, int, bytes]:
    """Inverse of `frame`, used by the sanity check and by F1 test vectors."""
    version, msg_type, route_id, seq, total, length = struct.unpack_from(">BBHBBH", message, 0)
    if version != PROTO_VERSION:
        raise ValueError(f"unexpected protoVersion {version}")
    payload = message[HEADER_SIZE:HEADER_SIZE + length]
    if len(payload) != length:
        raise ValueError("truncated payload")
    return msg_type, route_id, seq, total, payload


def chunk(msg_type: int, route_id: int, payload: bytes, chunk_size: int = CHUNK_SIZE) -> list[bytes]:
    """Split a block payload into framed chunks of at most `chunk_size` bytes.

    The watch concatenates every chunk of a (msgType, routeId) block before
    parsing, so records may straddle a chunk boundary.
    """
    body = chunk_size - HEADER_SIZE
    parts = [payload[i:i + body] for i in range(0, len(payload), body)] or [b""]
    if len(parts) > MAX_CHUNKS:
        raise ValueError(f"block needs {len(parts)} chunks, protocol allows {MAX_CHUNKS}")
    return [frame(msg_type, route_id, i, len(parts), part) for i, part in enumerate(parts)]


def encode_points(points: list[tuple[int, int]], lat0: int, lon0: int) -> bytes:
    """Delta-encode coordinates as described in 05 §ROUTE_POLY."""
    out = bytearray()
    prev_lat, prev_lon = lat0, lon0
    for i, (lat, lon) in enumerate(points):
        dlat = lat - prev_lat
        dlon = lon - prev_lon
        if i == 0:
            out += struct.pack(">ii", dlat, dlon)
        elif -32767 <= dlat <= 32767 and -32767 <= dlon <= 32767:
            out += struct.pack(">hh", dlat, dlon)
        else:
            out += struct.pack(">hh", DELTA_ESCAPE, DELTA_ESCAPE)
            out += struct.pack(">ii", dlat, dlon)
        prev_lat, prev_lon = lat, lon
    return bytes(out)


# --- Block payloads ----------------------------------------------------------


def pack_route_meta(route: Route) -> bytes:
    return (
        struct.pack(">iiII", route.lat0, route.lon0, route.distance_m, route.duration_s)
        + pack_string(route.dest_name, MAX_DEST_NAME_BYTES)
        + struct.pack(">HBBB", len(route.points), len(route.turns), route.corridor_lod_count, route.flags)
    )


def pack_route_poly(route: Route) -> bytes:
    return encode_points(route.points, route.lat0, route.lon0)


def pack_turns(route: Route) -> bytes:
    out = bytearray()
    for turn in route.turns:
        out += struct.pack(">HB", turn.point_idx, turn.type)
        if has_exit_num(turn.type):
            out += struct.pack(">B", turn.exit_num)
        out += pack_string(turn.street_name, MAX_STREET_NAME_BYTES)
    return bytes(out)


def split_way(points: list[tuple[int, int]]) -> list[list[tuple[int, int]]]:
    """Cut a way into pieces of at most [MAX_WAY_POINTS] points.

    Consecutive pieces **share** the vertex where they were cut: without it the
    segment between them would simply not exist and the street would show a gap.
    """
    if len(points) <= MAX_WAY_POINTS:
        return [points]
    pieces = []
    start = 0
    while start < len(points) - 1:
        end = min(start + MAX_WAY_POINTS, len(points))
        pieces.append(points[start:end])
        start = end - 1
    return pieces


def pack_corridor(lod: int, ways: list[list[tuple[int, int]]], lat0: int, lon0: int) -> bytes:
    """CORRIDOR (0x04) payload for one LOD (05 §CORRIDOR).

    `lod uint8`, then `pointCount uint8` + delta-encoded points per way. Every
    way restarts its delta chain at (lat0, lon0) — the first point costs 8 bytes
    instead of 4, and in exchange a corrupt way cannot drag the ones after it out
    of place, which matters because these arrive over BLE.
    """
    out = bytearray(struct.pack(">B", lod))
    for way in ways:
        for piece in split_way(way):
            if len(piece) < 2:
                continue
            out += struct.pack(">B", len(piece))
            out += encode_points(piece, lat0, lon0)
    return bytes(out)


@dataclass
class Corridor:
    """Surrounding streets, grouped by level of detail (04 §3)."""

    #: `ways[lod]` = list of ways, each a list of (lat_e5, lon_e5).
    ways: list[list[list[tuple[int, int]]]] = field(
        default_factory=lambda: [[] for _ in range(CORRIDOR_LOD_COUNT)]
    )

    def segment_count(self) -> int:
        return sum(max(len(w) - 1, 0) for lod in self.ways for w in lod)

    def non_empty_lods(self) -> list[int]:
        return [lod for lod in range(CORRIDOR_LOD_COUNT) if self.ways[lod]]

    def packed_size(self, lat0: int, lon0: int) -> int:
        return sum(len(pack_corridor(lod, self.ways[lod], lat0, lon0)) for lod in self.non_empty_lods())

    def apply_caps(self, lat0: int, lon0: int) -> list[str]:
        """Drop whole LODs until the corridor fits the watch (04 §3.5).

        Returns the human-readable list of what was dropped. Silence here would
        be the worst outcome: a corridor that quietly lost half the streets looks
        exactly like a corridor that was always sparse.
        """
        dropped = []
        for lod in (LOD_LOCAL, LOD_COLLECTOR):
            if self.segment_count() <= MAX_CORRIDOR_SEGMENTS and self.packed_size(lat0, lon0) <= MAX_CORRIDOR_BYTES:
                break
            if self.ways[lod]:
                dropped.append(f"LOD {lod} ({len(self.ways[lod])} ways)")
                self.ways[lod] = []
        return dropped


# --- FAVORITES (0x05) and NAV_START_REQ (0x83) ---------------------------------

#: At most this many favourites travel (01 §Watch screens: "simple list (<=6 items)").
#: The watch refuses a longer list whole, like CONFIG.
MAX_FAVORITES = 6

#: `name` of a favourite, in UTF-8 bytes (05 §FAVORITES).
MAX_FAVORITE_NAME_BYTES = 20

#: The fixture: **public places only** (CLAUDE.md: never Igor's addresses in a
#: fixture). Ids are not 0..n-1 (1, 2, 4) so a reader that took the index for
#: the id cannot pass; the last name has multibyte letters, the signs are
#: negative (Sao Paulo), and every field differs so a swapped offset shows.
FAVORITES_SAMPLE = [
    {"fav_id": 1, "name": "Copan", "lat_e5": -2354522, "lon_e5": -4664218, "icon": 2},
    {"fav_id": 2, "name": "MASP", "lat_e5": -2356135, "lon_e5": -4665589, "icon": 3},
    {"fav_id": 4, "name": "Praça da Sé", "lat_e5": -2355050, "lon_e5": -4663340, "icon": 5},
]

#: `NAV_START_REQ` of the fixture: the second item of FAVORITES_SAMPLE.
NAV_START_REQ_SAMPLE = {"fav_id": 2}

#: RECENTS (0x0B, C16.5): the last destinations, same item layout as FAVORITES, at most 5
#: (05 §RECENTS). The home screen of the watch lists them under "Recent".
MAX_RECENTS = 5

#: `kind` byte of NAV_START_REQ (05 §NAV_START_REQ): which list the id is from. A favourite
#: goes without the byte (the C12 frame, one byte); a recent carries it.
NAV_START_KIND_FAVORITE = 0
NAV_START_KIND_RECENT = 1

#: The fixture: public places only, like FAVORITES_SAMPLE. Ids 0 and 3, not 0..n-1.
RECENTS_SAMPLE = [
    {"fav_id": 0, "name": "Estação da Luz", "lat_e5": -2353475, "lon_e5": -4663494, "icon": 0},
    {"fav_id": 3, "name": "Ibirapuera", "lat_e5": -2358742, "lon_e5": -4665755, "icon": 0},
]

#: `NAV_START_REQ` for the second recent of RECENTS_SAMPLE.
NAV_START_REQ_RECENT_SAMPLE = {"fav_id": 3, "kind": NAV_START_KIND_RECENT}


def pack_favorites(items: list[dict], max_items: int = MAX_FAVORITES) -> bytes:
    """FAVORITES payload (05 §FAVORITES): `count uint8`, then per item
    `favId uint8`, lat int32, lon int32 (1e-5 degree), `nome` len-prefixed
    UTF-8 (<= 20 B, cut on a codepoint), `icon uint8`. RECENTS uses the same
    layout with `max_items` 5."""
    if len(items) > max_items:
        raise ValueError(f"{len(items)} items; the protocol carries at most {max_items}")
    ids = [item["fav_id"] for item in items]
    if len(set(ids)) != len(ids):
        raise ValueError(f"repeated favId in {ids}")
    out = struct.pack(">B", len(items))
    for item in items:
        if not 0 <= item["fav_id"] <= 0xFF or not 0 <= item["icon"] <= 0xFF:
            raise ValueError(f"favorite {item} does not fit the wire format")
        out += struct.pack(">Bii", item["fav_id"], item["lat_e5"], item["lon_e5"])
        out += pack_string(item["name"], MAX_FAVORITE_NAME_BYTES)
        out += struct.pack(">B", item["icon"])
    return out


def favorites_frame(items: list[dict]) -> bytes:
    """A whole FAVORITES message: routeId 0 (no route), one chunk."""
    (message,) = chunk(MSG_FAVORITES, 0, pack_favorites(items))
    return message


def recents_frame(items: list[dict]) -> bytes:
    """A whole RECENTS message: the FAVORITES layout, at most 5 items, routeId 0, one chunk."""
    (message,) = chunk(MSG_RECENTS, 0, pack_favorites(items, MAX_RECENTS))
    return message


def nav_start_req_frame(fav_id: int, kind: int | None = None) -> bytes:
    """A whole NAV_START_REQ (watch -> phone): payload is `favId uint8`, and
    `kind uint8` only for a recent (05 §NAV_START_REQ); routeId 0, one chunk."""
    payload = struct.pack(">B", fav_id) if kind is None else struct.pack(">BB", fav_id, kind)
    (message,) = chunk(MSG_NAV_START_REQ, 0, payload)
    return message


# --- ROUTE_UPDATE (0x06) -------------------------------------------------------

#: The fixture: the route of the watch test vectors (7, like REROUTE_REQ_SAMPLE),
#: and a duration whose four bytes all differ (0x00010203), so a reader that took
#: two bytes, or the wrong end, cannot pass.
ROUTE_UPDATE_SAMPLE = {"route_id": 7, "duration_s": 0x00010203}


def pack_route_update(duration_s: int) -> bytes:
    """ROUTE_UPDATE payload, 4 bytes: `durationS uint32`, what the provider says
    the whole route takes now (05 §ROUTE_UPDATE). Zero is not a duration, and
    the watch reads the field signed: both ends refuse anything outside
    1..0x7FFFFFFF."""
    if not 0 < duration_s <= 0x7FFFFFFF:
        raise ValueError(f"durationS {duration_s} does not fit the wire format")
    return struct.pack(">I", duration_s)


def route_update_frame(route_id: int, duration_s: int) -> bytes:
    """A whole ROUTE_UPDATE message, one chunk. The header's routeId is the
    route the duration is of: the watch refuses an update about any other."""
    (message,) = chunk(MSG_ROUTE_UPDATE, route_id, pack_route_update(duration_s))
    return message


# --- CONFIG (0x09) -------------------------------------------------------------

#: Key ids of the CONFIG payload (05 §CONFIG). The watch owns the ranges; the
#: phone only packs.
CONFIG_KEYS = {
    "lead_s": 1,
    "lead_min_m": 2,
    "near_m": 3,
    "pulse_ms": 4,
    "zoom": 5,
    "corridor_pct": 6,
    "hud_pct": 7,
    "orbit_px": 8,
    "orbit_s": 9,
    # C16.5: the size of each HUD group, in %, on top of hud_pct.
    "dist_pct": 10,
    "eta_pct": 11,
    "text_pct": 12,
    "arrow_pct": 13,
    # v1.1.5: the plate's breathing room, sideways and up-down, in % (0..100).
    "plate_w_pct": 14,
    "plate_h_pct": 15,
    # C16: the GPS-gap drill, minutes after the trip starts (0 = off).
    "gps_drill_min": 16,
    # C16: the map's test switches, 0/1 (streets as an image, tilted map, 16-bit image).
    "street_img": 17,
    "map_tilt": 18,
    "street_16bit": 19,
    # C16: the street-image diagnostic lever, 0 (normal) to 10, one hypothesis each (v1.2.9: probes and tile grids).
    "street_diag": 20,
    # C16: vibration on the wrist (turns, arrival, off-route), 0 off (the default since 2026-10-02) / 1 on.
    "vibe_on": 21,
    # C16.6: the radar alert's own vibration, 1 on (default) / 0 off, apart from vibe_on.
    "radar_vibe": 22,
}

#: The fixture: every key present and none at its default, so a watch that
#: silently kept a default cannot pass `ConfigTest.parsesTheFixture`.
CONFIG_SAMPLE = {
    "lead_s": 10,
    "lead_min_m": 100,
    "near_m": 30,
    "pulse_ms": 250,
    "zoom": 2,
    "corridor_pct": 120,
    "hud_pct": 95,
    "orbit_px": 3,
    "orbit_s": 30,
    "dist_pct": 80,
    "eta_pct": 90,
    "text_pct": 70,
    "arrow_pct": 85,
    "plate_w_pct": 60,
    "plate_h_pct": 40,
    "gps_drill_min": 8,
    "street_img": 0,
    "map_tilt": 0,
    "street_16bit": 0,
    "street_diag": 3,
    "vibe_on": 1,
    "radar_vibe": 0,
}


def pack_config(values: dict) -> bytes:
    """CONFIG payload: `count uint8` + count x (`key uint8`, `value uint16`),
    in key-id order. A key may be a name from CONFIG_KEYS or a raw id (the
    watch-side tests need an id the watch does not know). An empty dict is the
    "back to defaults" message."""
    entries = []
    for key, value in values.items():
        key_id = key if isinstance(key, int) else CONFIG_KEYS[key]
        if not 0 <= key_id <= 0xFF or not 0 <= value <= 0xFFFF:
            raise ValueError(f"config {key}={value} does not fit the wire format")
        entries.append((key_id, value))
    entries.sort()
    return struct.pack(">B", len(entries)) + b"".join(struct.pack(">BH", k, v) for k, v in entries)


def config_frame(values: dict) -> bytes:
    """A whole CONFIG message: routeId 0 (no route), one chunk."""
    (message,) = chunk(MSG_CONFIG, 0, pack_config(values))
    return message


# --- RADARS (0x08) --------------------------------------------------------------

#: The watch reads at most this many (05 §RADARS): 2 + 14 x 200 = 2 802 B, one chunk.
MAX_RADARS = 200
RADAR_RECORD_BYTES = 14
#: flags bit0: the camera's direction is known and matches the route.
RADAR_FLAG_DIRECTION = 0x01

#: The fixture, on the sample route (routeId of the run): wire values, in distAlong order.
#: One with an unknown limit (0) and one without a known direction, so a watch that drops
#: either case cannot pass `RadarsTest.parsesTheFixture`.
RADARS_SAMPLE = [
    {"dist_along_m": 1200, "dlat": -850, "dlon": 410, "limit_kmh": 50, "flags": RADAR_FLAG_DIRECTION},
    {"dist_along_m": 5400, "dlat": -3120, "dlon": 1900, "limit_kmh": 0, "flags": RADAR_FLAG_DIRECTION},
    {"dist_along_m": 9800, "dlat": -6010, "dlon": 2250, "limit_kmh": 60, "flags": 0},
]


def pack_radars(radars: list[dict]) -> bytes:
    """RADARS payload (05 §RADARS): `count uint16` + count x (`distAlong uint32`,
    `dLat int32`, `dLon int32`, `limit uint8`, `flags uint8`), in distAlong order."""
    if len(radars) > MAX_RADARS:
        raise ValueError(f"{len(radars)} radars; the protocol carries at most {MAX_RADARS}")
    out = bytearray(struct.pack(">H", len(radars)))
    last = 0
    for radar in radars:
        dist = radar["dist_along_m"]
        if not last <= dist <= 0xFFFFFFFF:
            raise ValueError(f"radar distAlong {dist} out of order or out of uint32")
        if not 0 <= radar["limit_kmh"] <= 0xFF or not 0 <= radar["flags"] <= 0xFF:
            raise ValueError(f"radar {radar} does not fit the wire format")
        out += struct.pack(">IiiBB", dist, radar["dlat"], radar["dlon"], radar["limit_kmh"], radar["flags"])
        last = dist
    return bytes(out)


def radars_frame(radars: list[dict], route_id: int) -> bytes:
    """A whole RADARS message: the route's id, one chunk."""
    (message,) = chunk(MSG_RADARS, route_id, pack_radars(radars))
    return message


# --- PHONE_FIX (0x0A) ----------------------------------------------------------

#: The fixture: the MASP, a public place (no address of Igor ever goes into a
#: fixture). Negative coordinates so a reader that forgot the sign cannot pass,
#: and four uint16 that all differ, in both bytes where the field allows, so a
#: swapped offset cannot pass either: 30.0 m/s, heading 271, 12 m, 850 ms old.
PHONE_FIX_SAMPLE = {
    "lat_e5": -2356141,
    "lon_e5": -4665588,
    "speed_dms": 300,
    "heading_deg": 271,
    "accuracy_m": 12,
    "age_ms": 850,
}

#: A latitude or longitude outside these is not a place (1e-5 degree).
MAX_LAT_E5 = 9_000_000
MAX_LON_E5 = 18_000_000


def pack_phone_fix(
    lat_e5: int, lon_e5: int, speed_dms: int, heading_deg: int | None, accuracy_m: int, age_ms: int
) -> bytes:
    """PHONE_FIX payload, 16 bytes (05 §PHONE_FIX): lat, lon int32 (1e-5
    degree), speed uint16 (dm/s, the unit of the `trk` line), heading uint16
    (degrees, >= 360 = unknown, as in REROUTE_REQ), accuracy uint16 (metres),
    age uint16 (ms between the phone getting the fix and sending it).

    The three magnitudes saturate at 0xFFFF instead of failing: a fix a minute
    old is still a fix, and the watch reads the saturated age as "old"."""
    if not (-MAX_LAT_E5 <= lat_e5 <= MAX_LAT_E5 and -MAX_LON_E5 <= lon_e5 <= MAX_LON_E5):
        raise ValueError(f"{lat_e5}, {lon_e5} is not a place")
    if min(speed_dms, accuracy_m, age_ms) < 0:
        raise ValueError("speed, accuracy and age are magnitudes: none is negative")
    heading = heading_deg if heading_deg is not None and 0 <= heading_deg < 360 else HEADING_UNKNOWN
    return struct.pack(
        ">iiHHHH", lat_e5, lon_e5, min(speed_dms, 0xFFFF), heading, min(accuracy_m, 0xFFFF), min(age_ms, 0xFFFF)
    )


def phone_fix_frame(
    lat_e5: int, lon_e5: int, speed_dms: int, heading_deg: int | None, accuracy_m: int, age_ms: int
) -> bytes:
    """A whole PHONE_FIX message, one chunk. Not of any route: routeId 0."""
    (message,) = chunk(MSG_PHONE_FIX, 0, pack_phone_fix(lat_e5, lon_e5, speed_dms, heading_deg, accuracy_m, age_ms))
    return message


# --- REROUTE_REQ (0x82) --------------------------------------------------------

#: `heading` when the watch has no trustworthy course yet (05 §REROUTE_REQ):
#: anything >= 360 means "unknown", and the watch sends this value.
HEADING_UNKNOWN = 0xFFFF

#: The fixture, the first of the watch -> phone direction. Negative coordinates
#: (São Paulo) so a reader that forgot the sign cannot pass, and every field
#: with distinct bytes so a swapped offset cannot pass either.
REROUTE_REQ_SAMPLE = {
    "route_id": 7,
    "lat_e5": -2362660,
    "lon_e5": -4665640,
    "heading_deg": 87,
    "dist_along_m": 10432,
}


def pack_reroute_req(lat_e5: int, lon_e5: int, heading_deg: int, dist_along_m: int) -> bytes:
    """REROUTE_REQ payload, 14 bytes: lat, lon int32 (1e-5 degree), heading
    uint16 (degrees, >= 360 = unknown), distAlongRoute uint32 (metres)."""
    return struct.pack(">iiHI", lat_e5, lon_e5, heading_deg, dist_along_m)


def unpack_reroute_req(payload: bytes) -> dict:
    """Inverse of `pack_reroute_req`; `heading_deg` is None when unknown."""
    if len(payload) != 14:
        raise ValueError(f"REROUTE_REQ payload has {len(payload)} bytes, expected 14")
    lat_e5, lon_e5, heading_deg, dist_along_m = struct.unpack(">iiHI", payload)
    return {
        "lat_e5": lat_e5,
        "lon_e5": lon_e5,
        "heading_deg": heading_deg if heading_deg < 360 else None,
        "dist_along_m": dist_along_m,
    }


def reroute_req_frame(route_id: int, lat_e5: int, lon_e5: int, heading_deg: int, dist_along_m: int) -> bytes:
    """A whole REROUTE_REQ message. The header's routeId is the route the
    `distAlongRoute` refers to: the phone drops a request about any other."""
    (message,) = chunk(MSG_REROUTE_REQ, route_id, pack_reroute_req(lat_e5, lon_e5, heading_deg, dist_along_m))
    return message


# --- FIX_REQ (0x86) ------------------------------------------------------------

#: The fixture is the request that turns the phone's GPS on (05 §FIX_REQ).
FIX_REQ_SAMPLE = {"on": True}


def fix_req_frame(on: bool) -> bytes:
    """A whole FIX_REQ message: one byte, 1 = send PHONE_FIX, 0 = stop. Not of
    any route: routeId 0."""
    (message,) = chunk(MSG_FIX_REQ, 0, bytes([1 if on else 0]))
    return message


# --- Mapbox Directions -> Route ---------------------------------------------


def quantize_e6(microdeg: int) -> int:
    """1e-6 degrees -> protocol units (1e-5), rounding halves away from zero.

    Pure integer arithmetic on purpose: Python's round() breaks ties to even and
    Java's Math.round() breaks them upward, and one in ten polyline6 coordinates
    lands exactly on a tie. The Kotlin packer implements this same function.
    """
    sign = -1 if microdeg < 0 else 1
    return sign * ((abs(microdeg) + 5) // 10)


def quantize_deg(degrees: float) -> int:
    """Degrees as a JSON double -> protocol units (1e-5), halves away from zero."""
    scaled = abs(degrees) * 1e5
    value = int(scaled + 0.5)
    return -value if degrees < 0 else value


def decode_polyline6_e6(encoded: str) -> list[tuple[int, int]]:
    """Decode a Mapbox `polyline6` geometry into (lat, lon) microdegrees."""
    points: list[tuple[int, int]] = []
    index = 0
    lat = 0
    lon = 0
    length = len(encoded)
    while index < length:
        for axis in range(2):
            shift = 0
            result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += delta
            else:
                lon += delta
        points.append((lat, lon))
    return points


def maneuver_to_turn_type(maneuver: dict, degrees: float | None = None, driving_side: str = "right") -> int:
    """Map a Mapbox maneuver to a protocol turn type (05 §TURNS).

    `degrees` is the roundabout exit angle from the previous step's banner (Mapbox puts the
    banner of maneuver i+1 on step i); without it, or where traffic keeps left and the ring
    turns clockwise, a roundabout stays type 9."""
    kind = (maneuver.get("type") or "").lower()
    modifier = (maneuver.get("modifier") or "").lower()
    left = "left" in modifier
    right = "right" in modifier

    if kind == "depart":
        return TURN_DEPART
    if kind == "arrive":
        return TURN_ARRIVE_LEFT if left else TURN_ARRIVE_RIGHT if right else TURN_ARRIVE
    if kind in ("roundabout", "rotary", "roundabout turn"):
        if degrees is None or driving_side == "left":
            return TURN_ROUNDABOUT
        return roundabout_by_degrees(degrees)
    if kind in ("exit roundabout", "exit rotary"):
        return TURN_STRAIGHT
    if kind == "on ramp":
        return TURN_HIGHWAY_ENTER_LEFT if left else TURN_HIGHWAY_ENTER
    if kind == "off ramp":
        return TURN_HIGHWAY_EXIT_LEFT if left else TURN_HIGHWAY_EXIT
    if kind == "fork":
        return TURN_FORK_LEFT if left else TURN_FORK_RIGHT if right else TURN_STRAIGHT
    if kind == "merge":
        return TURN_MERGE_LEFT if left else TURN_MERGE_RIGHT if right else TURN_MERGE
    if kind in ("new name", "notification"):
        return TURN_NEW_NAME
    return _MODIFIER_TO_TURN.get(modifier, TURN_STRAIGHT)


def banner_degrees(step: dict | None) -> float | None:
    """The first `primary.degrees` in a step's banners: the exit angle of the **next** maneuver."""
    for banner in (step or {}).get("bannerInstructions") or []:
        degrees = (banner.get("primary") or {}).get("degrees")
        if degrees is not None:
            return float(degrees)
    return None


def street_name_of(step: dict) -> str:
    """Name of the road this step runs on, or "" when the road is unnamed.

    docs/04-COMPANION-APP.md falls back to `banner_instructions.primary.text`,
    but on real pt-BR responses that field holds a whole sentence whenever the
    road is unnamed ("Entre na rotatória e pegue a 2ª saída"), which the watch
    would show truncated where a street name belongs. So the banner is only
    accepted when it fits the field whole — long sentences are dropped and the
    HUD falls back to arrow plus distance. See docs/DECISIONS.md.
    """
    name = (step.get("name") or "").strip()
    if name:
        return name
    ref = (step.get("ref") or "").strip()
    if ref:
        return ref
    destinations = (step.get("destinations") or "").strip()
    if destinations:
        return destinations
    banners = step.get("bannerInstructions") or []
    if banners:
        text = ((banners[0].get("primary") or {}).get("text") or "").strip()
        if len(text.encode("utf-8")) <= MAX_STREET_NAME_BYTES:
            return text
    return ""


def _nearest_index(points: list[tuple[int, int]], target: tuple[int, int], start: int) -> int:
    """Index of the polyline point closest to `target`, searching forward from `start`.

    Maneuver locations are snapped to the route, so a monotonic forward scan is
    both correct and cheap (squared distance in e5 units; no projection needed).

    The scan stops at the **first** point within 1 e5 unit of `target` (C11): a stop
    in the middle of a street is reached and left by the same street, so the polyline
    passes through it twice, and picking the closest of the two could jump to the way
    back and skip every maneuver in between. Mirrors MapboxRouteParser.nearestIndex.
    """
    best_idx = start
    best_dist = None
    for i in range(start, len(points)):
        dlat = points[i][0] - target[0]
        dlon = points[i][1] - target[1]
        dist = dlat * dlat + dlon * dlon
        if best_dist is None or dist < best_dist:
            best_dist = dist
            best_idx = i
        if abs(dlat) <= 1 and abs(dlon) <= 1:
            return i
    return best_idx


def route_from_mapbox(response: dict, dest_name: str | None = None) -> Route:
    """Build a `Route` from a Mapbox Directions response (04 §MapboxProvider)."""
    mb_route = response["routes"][0]
    coords = decode_polyline6_e6(mb_route["geometry"])
    points = [(quantize_e6(lat), quantize_e6(lon)) for lat, lon in coords]
    if len(points) > MAX_POLY_POINTS:
        raise ValueError(
            f"{len(points)} points exceed the {MAX_POLY_POINTS} cap; the companion "
            "must simplify straight highway stretches first (05 §ROUTE_POLY)"
        )

    turns: list[Turn] = []
    stop_idx: list[int] = []
    cursor = 0
    legs = mb_route.get("legs", [])
    for leg_no, leg in enumerate(legs):
        for step_no, step in enumerate(leg.get("steps", [])):
            maneuver = step.get("maneuver", {})
            location = maneuver.get("location")
            if location is None:
                continue
            # Stop in the middle: the `depart` of a leg that is not the first repeats the previous
            # one's `arrive`, and a "leave" arrow in the middle of the route means nothing (C11).
            if leg_no > 0 and step_no == 0 and (maneuver.get("type") or "").lower() == "depart":
                continue
            target = (quantize_deg(location[1]), quantize_deg(location[0]))
            cursor = _nearest_index(points, target, cursor)
            previous = leg["steps"][step_no - 1] if step_no > 0 else None
            turns.append(
                Turn(
                    point_idx=cursor,
                    type=maneuver_to_turn_type(maneuver, banner_degrees(previous),
                                               (step.get("driving_side") or "right").lower()),
                    street_name=street_name_of(step),
                    exit_num=int(maneuver.get("exit") or 0),
                )
            )
        if leg_no < len(legs) - 1:
            stop_idx.append(cursor)

    if dest_name is None:
        waypoints = response.get("waypoints") or []
        dest_name = (waypoints[-1].get("name") if waypoints else "") or "Destino"

    return Route(
        points=points,
        turns=turns,
        distance_m=round(mb_route["distance"]),
        duration_s=round(mb_route["duration"]),
        dest_name=dest_name,
        stop_idx=stop_idx,
    )


# --- Fixture generation ------------------------------------------------------


@dataclass
class Block:
    name: str
    msg_type: int
    chunks: list[bytes] = field(default_factory=list)


def build_blocks(
    route: Route,
    route_id: int,
    chunk_size: int = CHUNK_SIZE,
    corridor: Corridor | None = None,
) -> list[Block]:
    """Blocks in send order (ADR-3: META -> POLY -> TURNS -> CORRIDOR).

    The corridor goes last on purpose: it is the only optional block, and the
    route has to be usable before the scenery arrives.
    """
    if corridor is not None:
        route.corridor_lod_count = len(corridor.non_empty_lods())

    blocks = [
        Block("meta", MSG_ROUTE_META, chunk(MSG_ROUTE_META, route_id, pack_route_meta(route), chunk_size)),
        Block("poly", MSG_ROUTE_POLY, chunk(MSG_ROUTE_POLY, route_id, pack_route_poly(route), chunk_size)),
        Block("turns", MSG_TURNS, chunk(MSG_TURNS, route_id, pack_turns(route), chunk_size)),
    ]
    if corridor is not None:
        for lod in corridor.non_empty_lods():
            payload = pack_corridor(lod, corridor.ways[lod], route.lat0, route.lon0)
            blocks.append(
                Block(f"corridor_lod{lod}", MSG_CORRIDOR, chunk(MSG_CORRIDOR, route_id, payload, chunk_size))
            )
    return blocks


def synthetic_corridor(route: Route) -> Corridor:
    """A deterministic corridor built from the route itself, **for fixtures only**.

    The fixtures exist to pin the *encoding* byte for byte across Python, Kotlin
    and Monkey C — not to be believable OSM data. Deriving them from the route
    keeps them reproducible without a network call to Overpass, and the shape
    below is chosen to exercise every branch of the encoder: a way past the
    255-point ceiling (so `split_way` runs), several ways per block, and offsets
    big enough to force the int32 escape on the first point of each way.
    """
    corridor = Corridor()
    points = route.points

    def shifted(start: int, count: int, dlat: int, dlon: int) -> list[tuple[int, int]]:
        piece = points[start : start + count]
        return [(lat + dlat, lon + dlon) for lat, lon in piece]

    # LOD 0: one long way — 300 points forces the split into 255 + 46.
    corridor.ways[LOD_EXPRESS] = [shifted(0, 300, 200, -200)]
    # LOD 1: two medium ways on the other side.
    corridor.ways[LOD_ARTERIAL] = [shifted(20, 40, -150, 120), shifted(120, 40, -150, 120)]
    # LOD 2: three short ways.
    corridor.ways[LOD_COLLECTOR] = [shifted(i * 60, 12, 90, 90) for i in range(3)]
    # LOD 3: five very short ways.
    corridor.ways[LOD_LOCAL] = [shifted(i * 40 + 5, 6, -60, -60) for i in range(5)]

    corridor.ways = [[w for w in lod if len(w) >= 2] for lod in corridor.ways]
    return corridor


def write_fixtures(blocks: list[Block], route: Route, route_id: int, out_dir: Path) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "protoVersion": PROTO_VERSION,
        "routeId": route_id,
        "chunkSize": CHUNK_SIZE,
        "polyPointCount": len(route.points),
        "turnCount": len(route.turns),
        "corridorLodCount": route.corridor_lod_count,
        "distanceM": route.distance_m,
        "durationS": route.duration_s,
        "destName": route.dest_name,
        "blocks": [],
    }
    for block in blocks:
        files = []
        for message in block.chunks:
            msg_type, _, seq, total, _ = unframe(message)  # sanity: header round-trips
            name = f"{block.name}_{seq:02d}.bin"
            (out_dir / name).write_bytes(message)
            files.append({"file": name, "seq": seq, "total": total, "bytes": len(message)})
        manifest["blocks"].append(
            {
                "name": block.name,
                "msgType": block.msg_type,
                "chunks": len(block.chunks),
                "payloadBytes": sum(len(c) - HEADER_SIZE for c in block.chunks),
                "files": files,
            }
        )
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    return manifest


def favorites_fixtures() -> dict[str, bytes]:
    """File name -> bytes of the favourites and recents fixtures."""
    return {
        "favorites_00.bin": favorites_frame(FAVORITES_SAMPLE),
        "nav_start_req_00.bin": nav_start_req_frame(**NAV_START_REQ_SAMPLE),
        "recents_00.bin": recents_frame(RECENTS_SAMPLE),
        "nav_start_req_01.bin": nav_start_req_frame(**NAV_START_REQ_RECENT_SAMPLE),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate protocol test vectors from a Mapbox route")
    parser.add_argument("--route", type=Path, help="Mapbox Directions JSON response")
    parser.add_argument("--out", type=Path, help="output directory for the .bin fixtures")
    parser.add_argument(
        "--favorites",
        "--favoritos",
        dest="favorites",
        action="store_true",
        help="only regenerate the favorites, recents and nav_start_req fixtures (default --out: tools/fixtures)",
    )
    parser.add_argument("--route-id", type=int, default=1)
    parser.add_argument("--dest-name", default=None, help="overrides the last waypoint name")
    parser.add_argument("--chunk-size", type=int, default=CHUNK_SIZE)
    parser.add_argument(
        "--no-corridor",
        action="store_true",
        help="skip the synthetic CORRIDOR fixtures (see synthetic_corridor)",
    )
    args = parser.parse_args()

    if args.favorites:
        out_dir = args.out or Path(__file__).parent / "fixtures"
        out_dir.mkdir(parents=True, exist_ok=True)
        for name, message in favorites_fixtures().items():
            (out_dir / name).write_bytes(message)
            print(f"{name:<22}: {len(message)} bytes")
        return
    if args.route is None or args.out is None:
        parser.error("--route and --out are required (unless --favorites)")

    response = json.loads(args.route.read_text(encoding="utf-8"))
    route = route_from_mapbox(response, args.dest_name)
    corridor = None if args.no_corridor else synthetic_corridor(route)
    if corridor is not None:
        dropped = corridor.apply_caps(route.lat0, route.lon0)
        for item in dropped:
            print(f"corridor  : {item} dropped by the caps")
    blocks = build_blocks(route, args.route_id, args.chunk_size, corridor)
    # RADARS is of the route, after the corridor (05 §RADARS).
    blocks.append(Block("radars", MSG_RADARS, [radars_frame(RADARS_SAMPLE, args.route_id)]))
    # CONFIG is not part of a route: routeId 0, sent on its own (05 §CONFIG).
    blocks.append(Block("config", MSG_CONFIG, [config_frame(CONFIG_SAMPLE)]))
    # Watch -> phone: nor is this one part of the route being packed (05 §REROUTE_REQ).
    blocks.append(Block("reroute_req", MSG_REROUTE_REQ, [reroute_req_frame(**REROUTE_REQ_SAMPLE)]))
    # FAVORITES and its answer are not of a route either: routeId 0 (05 §FAVORITES).
    blocks.append(Block("favorites", MSG_FAVORITES, [favorites_frame(FAVORITES_SAMPLE)]))
    blocks.append(Block("nav_start_req", MSG_NAV_START_REQ, [nav_start_req_frame(**NAV_START_REQ_SAMPLE)]))
    # ROUTE_UPDATE is of a route, but not of the one being packed (05 §ROUTE_UPDATE).
    blocks.append(Block("route_update", MSG_ROUTE_UPDATE, [route_update_frame(**ROUTE_UPDATE_SAMPLE)]))
    # The phone's GPS as a fallback, and the watch asking for it: routeId 0 (05 §PHONE_FIX, §FIX_REQ).
    blocks.append(Block("phone_fix", MSG_PHONE_FIX, [phone_fix_frame(**PHONE_FIX_SAMPLE)]))
    blocks.append(Block("fix_req", MSG_FIX_REQ, [fix_req_frame(**FIX_REQ_SAMPLE)]))
    manifest = write_fixtures(blocks, route, args.route_id, args.out)

    print(f"route     : {route.dest_name}  {route.distance_m} m  {route.duration_s} s")
    print(f"polyline  : {len(route.points)} points")
    print(f"turns     : {len(route.turns)}")
    if corridor is not None:
        print(f"corridor  : {corridor.segment_count()} segments in {len(corridor.non_empty_lods())} LOD(s)")
    for block in manifest["blocks"]:
        print(
            f"{block['name']:<6}: {block['chunks']} chunk(s), "
            f"{block['payloadBytes']} payload bytes"
        )
    print(f"fixtures  : {args.out}")


if __name__ == "__main__":
    main()
