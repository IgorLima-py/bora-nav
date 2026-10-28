#!/usr/bin/env python3
"""Draws in PNG the same frame the watch would draw — and counts what it costs.

Why this script exists
----------------------
"The corridor does not show up" is a symptom that, on the watch, cannot be
inspected: there is no way to stop `onUpdate`, count the ways and look at the result.
Telemetry says `corridor lod 3 1431 pts, 262 ways` and `work 1239/220
CAPPED`, but it does not say **what would have shown up** if the budget had not
cut it. This renderer answers that off the watch: same projection, same
rotation, same colors, same culling, same work count — in Python,
where you can look.

It is a **mirror** of `watch/source/render/MapRenderer.mc`, in the same category
as `tools/packer.py` for the protocol. If the two diverge, the number this
script prints stops being valid; so everything copied from there is marked
with the original symbol's name.

Mirrored from:
  - `watch/source/nav/Projection.mc`      → `LocalPlane`
  - `watch/source/render/MapRenderer.mc`  → `MapRenderer` (constants and drawing)
  - `watch/source/model/CorridorModel.mc` → `CorridorModel` (flattened arrays + wayBox)
  - `watch/source/model/RouteModel.mc`    → `block_boxes` (16-point index)
  - `companion/.../corridor/*.kt`         → `Simplify`, `RouteProximity`, `build_corridor`

What is **not** reproduced, and why:
  - Antialiasing. PIL has none, and the corridor is drawn with AA off on the
    watch anyway. It changes neither geometry nor cost.
  - The font of the compass rose's "N" (development marker).
  - The HUD (`render/Hud.mc`) — it does not belong to `MapRenderer`.

Usage::

    python tools/preview_map.py --zoom 1.2 --at 0.35 --out saida.png
    python tools/preview_map.py --zoom 20 --at 0.35 --budget 220 --out cortado.png

`--budget` turns on the adaptive leash at the given value (the floor is 220, the ceiling 1800);
without it the drawing is what the watch **should** show, with no cut at all.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import packer  # noqa: E402  (same folder; it is the source of truth for the protocol)

try:
    from PIL import Image, ImageDraw
except ModuleNotFoundError:  # pragma: no cover - message, not logic
    print("Pillow is missing: python -m pip install --user Pillow", file=sys.stderr)
    raise


# ─── Local projection ────────────────────────────────────────────────────────
# Mirror of `nav/Projection.mc` and `corridor/LocalPlane.kt`.

METRES_PER_DEGREE = 111194.9
E5_TO_DEGREE = 0.00001


class LocalPlane:
    """Equirectangular anchored at the route's first point (ADR-6)."""

    def __init__(self, lat0_e5: int, lon0_e5: int) -> None:
        self.lat0 = lat0_e5
        self.lon0 = lon0_e5
        self.lon_scale = METRES_PER_DEGREE * math.cos(math.radians(lat0_e5 * E5_TO_DEGREE))

    def x(self, lon_e5: int) -> float:
        return (lon_e5 - self.lon0) * E5_TO_DEGREE * self.lon_scale

    def y(self, lat_e5: int) -> float:
        return (lat_e5 - self.lat0) * E5_TO_DEGREE * METRES_PER_DEGREE

    # Java rounds half up; Python's `round()` rounds to even.
    def to_lat_e5(self, y: float) -> int:
        return math.floor(y / METRES_PER_DEGREE / E5_TO_DEGREE + 0.5) + self.lat0

    def to_lon_e5(self, x: float) -> int:
        return math.floor(x / self.lon_scale / E5_TO_DEGREE + 0.5) + self.lon0


def distance(x1: float, y1: float, x2: float, y2: float) -> float:
    return math.hypot(x2 - x1, y2 - y1)


def distance_to_segment(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    dx = bx - ax
    dy = by - ay
    length_sq = dx * dx + dy * dy
    if length_sq <= 0.0:
        return distance(px, py, ax, ay)
    t = ((px - ax) * dx + (py - ay) * dy) / length_sq
    t = min(1.0, max(0.0, t))
    return distance(px, py, ax + dx * t, ay + dy * t)


# ─── Douglas-Peucker (mirror of corridor/Simplify.kt) ────────────────────────

EPSILON_M = [2.0, 2.0, 3.0, 4.0]


def douglas_peucker(xs: list[float], ys: list[float], epsilon: float) -> list[int]:
    if len(xs) <= 2:
        return list(range(len(xs)))
    keep = [False] * len(xs)
    keep[0] = True
    keep[-1] = True
    stack = [(0, len(xs) - 1)]
    while stack:
        frm, to = stack.pop()
        if to <= frm + 1:
            continue
        worst = -1
        worst_dist = epsilon
        for i in range(frm + 1, to):
            d = distance_to_segment(xs[i], ys[i], xs[frm], ys[frm], xs[to], ys[to])
            if d > worst_dist:
                worst_dist = d
                worst = i
        if worst >= 0:
            keep[worst] = True
            stack.append((frm, worst))
            stack.append((worst, to))
    return [i for i, k in enumerate(keep) if k]


def polyline_length_m(xs: list[float], ys: list[float]) -> float:
    return sum(distance(xs[i], ys[i], xs[i + 1], ys[i + 1]) for i in range(len(xs) - 1))


# ─── Route buffer (mirror of corridor/RouteProximity.kt) ─────────────────────

CORRIDOR_M = 300.0
MANEUVER_M = 600.0


class RouteProximity:
    """"Is this point inside the corridor?" — ±300 m from the route, 600 m at maneuvers."""

    def __init__(self, xs: list[float], ys: list[float], maneuver_idx: list[int]) -> None:
        self.xs = xs
        self.ys = ys
        self.maneuvers = set(maneuver_idx)
        self.cell = max(CORRIDOR_M, MANEUVER_M)
        self.cells: dict[tuple[int, int], list[int]] = {}
        for i in range(len(xs) - 1):
            min_cx = self._cell_of(min(xs[i], xs[i + 1]))
            max_cx = self._cell_of(max(xs[i], xs[i + 1]))
            min_cy = self._cell_of(min(ys[i], ys[i + 1]))
            max_cy = self._cell_of(max(ys[i], ys[i + 1]))
            for cx in range(min_cx, max_cx + 1):
                for cy in range(min_cy, max_cy + 1):
                    self.cells.setdefault((cx, cy), []).append(i)

    def _cell_of(self, value: float) -> int:
        return math.floor(value / self.cell)

    def _near_maneuver(self, segment_idx: int) -> bool:
        return segment_idx in self.maneuvers or (segment_idx + 1) in self.maneuvers

    def _neighbours(self, px: float, py: float):
        cx = self._cell_of(px)
        cy = self._cell_of(py)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                bucket = self.cells.get((cx + dx, cy + dy))
                if bucket:
                    yield from bucket

    def is_inside(self, px: float, py: float) -> bool:
        for i in self._neighbours(px, py):
            limit = MANEUVER_M if self._near_maneuver(i) else CORRIDOR_M
            if distance_to_segment(px, py, self.xs[i], self.ys[i], self.xs[i + 1], self.ys[i + 1]) <= limit:
                return True
        return False

    def distance_to(self, px: float, py: float) -> float:
        best = float("inf")
        for i in self._neighbours(px, py):
            d = distance_to_segment(px, py, self.xs[i], self.ys[i], self.xs[i + 1], self.ys[i + 1])
            if d < best:
                best = d
        return best

    def nearest_route_index(self, px: float, py: float) -> int:
        best = 0
        best_dist = float("inf")
        for i in range(len(self.xs)):
            d = distance(px, py, self.xs[i], self.ys[i])
            if d < best_dist:
                best_dist = d
                best = i
        return best


# ─── Corridor: raw Overpass → LODs (mirror of corridor/CorridorBuilder.kt) ───

LOD_OF = {
    "motorway": 0, "trunk": 0, "motorway_link": 0, "trunk_link": 0,
    "primary": 1, "secondary": 1, "primary_link": 1, "secondary_link": 1,
    "tertiary": 2,
    "residential": 3, "unclassified": 3,
}
MIN_WAY_LENGTH_M = 20.0
POLYGON_MARGIN_M = 700.0
SPINE_EPSILON_M = 50.0
MAX_POLY_VERTICES = 80
HIGHWAY_FILTER = (
    "motorway|trunk|primary|secondary|tertiary|residential|unclassified|"
    "motorway_link|trunk_link|primary_link|secondary_link"
)
OVERPASS_TIMEOUT_S = 60


def parse_overpass(raw: dict) -> list[tuple[str, list[tuple[int, int]]]]:
    """Mirror of `OverpassClient.parse`: (class, points in protocol units)."""
    ways = []
    for element in raw.get("elements", []):
        highway = (element.get("tags") or {}).get("highway")
        geometry = element.get("geometry")
        if not highway or not geometry or len(geometry) < 2:
            continue
        points = [(packer.quantize_deg(p["lat"]), packer.quantize_deg(p["lon"])) for p in geometry]
        ways.append((highway, points))
    return ways


def buffer_polygon(points: list[tuple[int, int]], plane: LocalPlane) -> list[tuple[int, int]]:
    """Coarse ribbon around the route for Overpass's `poly:`."""
    xs = [plane.x(p[1]) for p in points]
    ys = [plane.y(p[0]) for p in points]
    max_spine = MAX_POLY_VERTICES // 2
    epsilon = SPINE_EPSILON_M
    spine = douglas_peucker(xs, ys, epsilon)
    while len(spine) > max_spine:
        epsilon *= 2
        spine = douglas_peucker(xs, ys, epsilon)

    left: list[tuple[int, int]] = []
    right: list[tuple[int, int]] = []
    for n, index in enumerate(spine):
        previous = spine[max(n - 1, 0)]
        nxt = spine[min(n + 1, len(spine) - 1)]
        dx = xs[nxt] - xs[previous]
        dy = ys[nxt] - ys[previous]
        length = math.hypot(dx, dy)
        if length <= 0.0:
            dx, dy = 1.0, 0.0
        else:
            dx /= length
            dy /= length
        nx = -dy * POLYGON_MARGIN_M
        ny = dx * POLYGON_MARGIN_M
        left.append((plane.to_lat_e5(ys[index] + ny), plane.to_lon_e5(xs[index] + nx)))
        right.append((plane.to_lat_e5(ys[index] - ny), plane.to_lon_e5(xs[index] - nx)))
    return left + right[::-1]


def build_query(polygon: list[tuple[int, int]]) -> str:
    """Mirror of `OverpassClient.buildQuery`."""
    poly = " ".join(
        f"{lat * E5_TO_DEGREE:.5f} {lon * E5_TO_DEGREE:.5f}" for lat, lon in polygon
    )
    return (
        f"[out:json][timeout:{OVERPASS_TIMEOUT_S}];\n"
        f'way[highway~"^({HIGHWAY_FILTER})$"](poly:"{poly}");\n'
        "out geom;\n"
    )


def clip(points: list[tuple[int, int]], plane: LocalPlane, proximity: RouteProximity):
    """Mirror of `CorridorBuilder.clip`: the stretches that fall inside the corridor."""
    inside = [proximity.is_inside(plane.x(p[1]), plane.y(p[0])) for p in points]
    runs = []
    i = 0
    while i < len(points):
        if not inside[i]:
            i += 1
            continue
        end = i
        while end + 1 < len(points) and inside[end + 1]:
            end += 1
        frm = max(i - 1, 0)
        to = min(end + 1, len(points) - 1)
        if to > frm:
            runs.append(points[frm : to + 1])
        i = end + 1
    return runs


def build_corridor(raw_ways, route_points, plane: LocalPlane, turn_idx: list[int]):
    """Mirror of `CorridorBuilder.assemble` + `fitToCaps` + `Corridor.apply_caps`.

    Returns `(packer.Corridor, statistics)` — exactly what the phone
    would pack and send over BLE.
    """
    rxs = [plane.x(p[1]) for p in route_points]
    rys = [plane.y(p[0]) for p in route_points]
    proximity = RouteProximity(rxs, rys, turn_idx)

    buckets = []  # (lod, order, distance_m, points)
    for highway, points in raw_ways:
        lod = LOD_OF.get(highway)
        if lod is None:
            continue
        for run in clip(points, plane, proximity):
            xs = [plane.x(p[1]) for p in run]
            ys = [plane.y(p[0]) for p in run]
            if polyline_length_m(xs, ys) < MIN_WAY_LENGTH_M:
                continue
            keep = douglas_peucker(xs, ys, EPSILON_M[lod])
            if len(keep) < 2:
                continue
            simplified = [run[i] for i in keep]
            first = simplified[0]
            middle = simplified[len(simplified) // 2]
            buckets.append(
                (
                    lod,
                    proximity.nearest_route_index(plane.x(first[1]), plane.y(first[0])),
                    proximity.distance_to(plane.x(middle[1]), plane.y(middle[0])),
                    simplified,
                )
            )

    # fitToCaps: whole expressways and arterials; the rest by distance to the route.
    kept: list[list] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]
    segments = 0
    nbytes = 0
    for way in buckets:
        if way[0] <= 1:
            kept[way[0]].append(way)
            segments += len(way[3]) - 1
            nbytes += 4 + 4 * len(way[3])
    trimmed = 0
    last_kept_m = 0.0
    for way in sorted((w for w in buckets if w[0] > 1), key=lambda w: w[2]):
        seg = len(way[3]) - 1
        byt = 4 + 4 * len(way[3])
        if segments + seg > packer.MAX_CORRIDOR_SEGMENTS or nbytes + byt > packer.MAX_CORRIDOR_BYTES:
            trimmed += 1
            continue
        kept[way[0]].append(way)
        segments += seg
        nbytes += byt
        last_kept_m = way[2]

    corridor = packer.Corridor(
        ways=[[w[3] for w in sorted(bucket, key=lambda w: w[1])] for bucket in kept]
    )
    dropped = corridor.apply_caps(route_points[0][0], route_points[0][1])
    stats = {
        "raw_ways": len(raw_ways),
        "clipped": len(buckets),
        "cut_by_distance": trimmed,
        "mesh_up_to_m": last_kept_m,
        "dropped_lods": dropped,
        "segments": corridor.segment_count(),
        "bytes": corridor.packed_size(route_points[0][0], route_points[0][1]),
        "ways_per_lod": [len(bucket) for bucket in corridor.ways],
        "points_per_lod": [sum(len(w) for w in bucket) for bucket in corridor.ways],
    }
    return corridor, stats


# ─── What the watch stores (mirror of model/CorridorModel.mc) ────────────────


class CorridorModel:
    """Flattened parallel arrays per LOD, with `way_start` and `way_box`."""

    def __init__(self, corridor: packer.Corridor, plane: LocalPlane) -> None:
        self.xs: list[list[float]] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]
        self.ys: list[list[float]] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]
        self.way_start: list[list[int]] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]
        self.way_box: list[list[float]] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]
        self.block_box: list[list[float]] = [[] for _ in range(packer.CORRIDOR_LOD_COUNT)]

        for lod in range(packer.CORRIDOR_LOD_COUNT):
            xs: list[float] = []
            ys: list[float] = []
            starts: list[int] = []
            for way in corridor.ways[lod]:
                # The packer cuts the way into 255-point pieces on the air; the watch
                # receives each piece as a way of its own.
                for piece in packer.split_way(way):
                    if len(piece) < 2:
                        continue
                    if len(xs) + len(piece) > 7000:  # Protocol.MAX_CORRIDOR_POINTS
                        break
                    starts.append(len(xs))
                    for lat, lon in piece:
                        xs.append(plane.x(lon))
                        ys.append(plane.y(lat))
            starts.append(len(xs))  # sentinel
            self.xs[lod] = xs
            self.ys[lod] = ys
            self.way_start[lod] = starts
            self.way_box[lod] = self._boxes(xs, ys, starts)
            self.block_box[lod] = self._blocks(self.way_box[lod])

    #: Mirror of `CorridorModel.WAYS_PER_BLOCK`.
    WAYS_PER_BLOCK = 32

    @staticmethod
    def _blocks(boxes: list[float]) -> list[float]:
        """Mirror of `CorridorModel.blocksOf`: one rectangle per 32 ways."""
        ways = len(boxes) // 4
        if ways == 0:
            return []
        blocks = (ways + CorridorModel.WAYS_PER_BLOCK - 1) // CorridorModel.WAYS_PER_BLOCK
        out = [0.0] * (blocks * 4)
        for b in range(blocks):
            first = b * CorridorModel.WAYS_PER_BLOCK
            last = min(first + CorridorModel.WAYS_PER_BLOCK, ways)
            min_x = boxes[first * 4]
            max_x = boxes[first * 4 + 1]
            min_y = boxes[first * 4 + 2]
            max_y = boxes[first * 4 + 3]
            for w in range(first + 1, last):
                base = w * 4
                min_x = min(min_x, boxes[base])
                max_x = max(max_x, boxes[base + 1])
                min_y = min(min_y, boxes[base + 2])
                max_y = max(max_y, boxes[base + 3])
            out[b * 4] = min_x
            out[b * 4 + 1] = max_x
            out[b * 4 + 2] = min_y
            out[b * 4 + 3] = max_y
        return out

    @staticmethod
    def _boxes(xs: list[float], ys: list[float], starts: list[int]) -> list[float]:
        ways = len(starts) - 1 if starts else 0
        boxes = [0.0] * (ways * 4)
        for w in range(ways):
            frm = starts[w]
            to = starts[w + 1]
            min_x = max_x = xs[frm]
            min_y = max_y = ys[frm]
            for i in range(frm + 1, to):
                x = xs[i]
                y = ys[i]
                if x < min_x:
                    min_x = x
                elif x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                elif y > max_y:
                    max_y = y
            boxes[w * 4] = min_x
            boxes[w * 4 + 1] = max_x
            boxes[w * 4 + 2] = min_y
            boxes[w * 4 + 3] = max_y
        return boxes

    def way_count(self, lod: int) -> int:
        starts = self.way_start[lod]
        return len(starts) - 1 if starts else 0


# ─── Route block index (mirror of model/RouteModel.mc) ───────────────────────

BLOCK_POINTS = 16


def block_boxes(xs: list[float], ys: list[float]) -> list[float]:
    count = len(xs)
    if count == 0:
        return []
    blocks = (count + BLOCK_POINTS - 1) // BLOCK_POINTS
    boxes = [0.0] * (blocks * 4)
    for b in range(blocks):
        frm = b * BLOCK_POINTS
        to = min(frm + BLOCK_POINTS, count - 1)
        min_x = max_x = xs[frm]
        min_y = max_y = ys[frm]
        for i in range(frm + 1, to + 1):
            x = xs[i]
            y = ys[i]
            if x < min_x:
                min_x = x
            elif x > max_x:
                max_x = x
            if y < min_y:
                min_y = y
            elif y > max_y:
                max_y = y
        boxes[b * 4] = min_x
        boxes[b * 4 + 1] = max_x
        boxes[b * 4 + 2] = min_y
        boxes[b * 4 + 3] = max_y
    return boxes


# ─── The renderer (mirror of render/MapRenderer.mc) ──────────────────────────

SCREEN = 454
ANCHOR_X = 227
ANCHOR_Y = 330        # v1.1.5: the rider at 330, under the plate (MapRenderer.ANCHOR_Y = DesignTokens.PUCK_Y)
CORNER_PX = 330.0     # 227 + (330 - 227): the farthest lit pixel from the anchor
CULL_MARGIN = 1.4

#: v1.1.5 (sheet 8): the map laid back, `y' = anchor + K · (y − anchor)` (`MapRenderer._k`). 1.0 is
#: flat; ``--flat`` turns it off, like the watch's "Mapa deitado (teste)" setting.
TILT_K = 0.72

COLOR_ROUTE_AHEAD = 0x2FD3FF   # the rider's cyan (DesignTokens.ROUTE_AHEAD)
COLOR_ROUTE_LINE = 0x4C8DF6    # the route and the destination (DesignTokens.ROUTE_LINE, v1.1.5)
COLOR_ROUTE_BEHIND = 0x4A4A4A
WIDTH_AHEAD = 12
WIDTH_BEHIND = 5

#: C15b: the default is the dark Waze look's MapRenderer, without the walked stretch. Since v1.1.5 the route
#: has an edge by default (DesignTokens.ROUTE_EDGE); ``--no-edge`` removes it, like the watch's
#: "Route edge" test setting.
DRAW_BEHIND = False         # the already walked stretch
ROUTE_CASING_COLOR = 0x0E2550   # route edge (color), drawn under it; None = one pass
ROUTE_CASING_DEFAULT = 0x0E2550
ROUTE_CASING_PX = 3         # px of edge on each side
DRAW_RIDER = True           # False: the caller draws the puck
RIDER_CHEVRON = False       # True: the chevron from before sheet 4 (the design_tokens.py v1/v2 mockups)
DRAW_DESTINATION = True     # the route's end point (sheet 4)

LOD_COLOR = [0x8C7A58, 0x6A7584, 0x58626F, 0x4A535E]   # DesignTokens.ROAD_COLORS (v1.2.3, readable on AMOLED)
LOD_WIDTH = [16, 12, 9, 7]                             # DesignTokens.ROAD_WIDTHS
#: Maps' stroke on the black of the streets image (`StreetCache.step`): in each class, from local to
#: expressway, a black edge of ROAD_EDGE_PX on each side and the core on top; local has no edge.
#: 0 draws only the core, like the watch's street-by-street drawing without the image.
ROAD_EDGE_PX = 2
LOD_MAX_SCALE = [20.0, 20.0, 20.0, 20.0]

SHOW_NORTH = True
NORTH_CX = 376
NORTH_CY = 112
NORTH_NEEDLE_PX = 15
NORTH_LABEL_PX = 30
COLOR_NORTH = 0xFF4040

MIN_STEP_PX = 2.5
SEGMENT_COST = 3
DISC_COST = 2        # MapRenderer.DISC_COST
CAP_MAX_LOD = 1      # MapRenderer.CAP_MAX_LOD (the discs here are not drawn yet, only counted in the plan)
PLAN_COST = 1        # MapRenderer.PLAN_COST
WORK_MIN = 220
WORK_MAX = 1800


def rgb(value: int) -> tuple[int, int, int]:
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)


class MapRenderer:
    """One map frame. `work` is counted exactly as in Monkey C."""

    def __init__(self, centre_x: float, centre_y: float, heading_rad: float, scale: float,
                 budget: int | None = None, warm: bool = False) -> None:
        self._sin = math.sin(heading_rad)
        self._cos = math.cos(heading_rad)
        self._centre_x = centre_x
        self._centre_y = centre_y
        self._scale = scale
        self._cull_m = CORNER_PX / TILT_K * scale * CULL_MARGIN
        step = MIN_STEP_PX * scale
        self._step_sq_m = step * step

        self.budget = budget
        self.warm = warm
        self.work = 0
        self.segments_drawn = 0
        self.corridor_capped = False
        # Cost breakdown, for the table.
        self.work_scan = 0
        self.work_corridor = 0
        self.work_route_index = 0
        self.work_route = 0
        self.visible_ways = [0, 0, 0, 0]
        self.drawn_ways = [0, 0, 0, 0]
        self.corridor_segments = 0
        self.route_segments = 0

    # ── transform ────────────────────────────────────────────────────────────
    def visible(self, x: float, y: float) -> bool:
        dx = x - self._centre_x
        dy = y - self._centre_y
        return -self._cull_m < dx < self._cull_m and -self._cull_m < dy < self._cull_m

    def box_visible(self, min_x: float, max_x: float, min_y: float, max_y: float) -> bool:
        return (
            max_x > self._centre_x - self._cull_m
            and min_x < self._centre_x + self._cull_m
            and max_y > self._centre_y - self._cull_m
            and min_y < self._centre_y + self._cull_m
        )

    def screen(self, x: float, y: float) -> tuple[int, int]:
        dx = (x - self._centre_x) / self._scale
        dy = (y - self._centre_y) / self._scale
        # Monkey C's `.toNumber()` truncates toward zero, like int() here.
        return (
            int(ANCHOR_X + dx * self._cos - dy * self._sin),
            int(ANCHOR_Y - TILT_K * (dx * self._sin + dy * self._cos)),
        )

    def _over_budget(self) -> bool:
        if self.budget is None:
            return False
        if self.work >= self.budget:
            self.corridor_capped = True
            return True
        return False

    # ── corridor ─────────────────────────────────────────────────────────────
    def refresh_visible(self, corridor: CorridorModel) -> list[list[int]]:
        """Mirror of `refreshVisible`.

        Two regimes, and the difference between them is half the story:

        - **cold** (default): the visible-ways list is stale and the sweep
          runs. It happens every [CACHE_REBUILD_M] = 25 m of displacement,
          on every scale change and every new corridor — that is, ~once per
          second at 90 km/h.
        - **warm** (`warm=True`): the list is valid and `refreshVisible` returns without spending
          anything. It is the cheap frame, between two sweeps.
        """
        found: list[list[int]] = [[], [], [], []]
        for lod in range(packer.CORRIDOR_LOD_COUNT):
            if self._scale > LOD_MAX_SCALE[lod]:
                continue  # above the scale ceiling the LOD is not even swept
            boxes = corridor.way_box[lod]
            blocks = corridor.block_box[lod]
            ways = len(boxes) // 4
            span = CorridorModel.WAYS_PER_BLOCK
            # Sweep per block: 32 ways die in a single test when the whole block
            # is out of view (mirror of `refreshVisible`).
            for b in range(len(blocks) // 4):
                if not self.warm and self._over_budget():
                    return found
                bb = b * 4
                if not self.warm:
                    self.work += 1
                    self.work_scan += 1
                if not self.box_visible(blocks[bb], blocks[bb + 1], blocks[bb + 2], blocks[bb + 3]):
                    continue
                for w in range(b * span, min(b * span + span, ways)):
                    base = w * 4
                    if not self.warm:
                        self.work += 1
                        self.work_scan += 1
                    if self.box_visible(boxes[base], boxes[base + 1], boxes[base + 2], boxes[base + 3]):
                        found[lod].append(w)
        return found

    def plan_corridor(self, corridor: CorridorModel, visible: list[list[int]]) -> list[int]:
        """Mirror of `planCorridor` (C16.5): how many ways of each LOD fit, from coarse to
        fine, by the cost ceiling of each one."""
        planned = [0] * packer.CORRIDOR_LOD_COUNT
        spent = self.work
        ways = 0
        for lod in range(packer.CORRIDOR_LOD_COUNT):
            starts = corridor.way_start[lod]
            per_point = 1 + SEGMENT_COST + (DISC_COST if lod <= CAP_MAX_LOD else 0)
            count = 0
            for w in visible[lod]:
                if self.budget is not None and spent >= self.budget:
                    self.corridor_capped = True
                    break
                if w + 1 < len(starts):
                    spent += (starts[w + 1] - starts[w]) * per_point - SEGMENT_COST
                spent += PLAN_COST
                count += 1
            planned[lod] = count
            ways += count
            if count < len(visible[lod]):
                break
        self.work += ways * PLAN_COST
        return planned

    def draw_corridor(self, draw: ImageDraw.ImageDraw, corridor: CorridorModel) -> None:
        visible = self.refresh_visible(corridor)
        self.visible_ways = [len(v) for v in visible]
        planned = self.plan_corridor(corridor, visible)

        # Local street underneath, expressway on top (C16.5), like `drawCorridor`; with the edge
        # (v1.1.5), each class's black edge before its core, like the streets image.
        for lod in reversed(range(packer.CORRIDOR_LOD_COUNT)):
            indexes = visible[lod][:planned[lod]]
            if not indexes:
                continue
            xs = corridor.xs[lod]
            ys = corridor.ys[lod]
            starts = corridor.way_start[lod]
            edge = ROAD_EDGE_PX > 0 and lod < packer.CORRIDOR_LOD_COUNT - 1
            passes = ([((0, 0, 0), LOD_WIDTH[lod] + 2 * ROAD_EDGE_PX, False)] if edge else []) + [
                (rgb(LOD_COLOR[lod]), LOD_WIDTH[lod], True)]
            for colour, width, count in passes:
                for w in indexes:
                    if w + 1 >= len(starts):
                        continue
                    drawn = self._draw_way(draw, xs, ys, starts[w], starts[w + 1], colour, width)
                    if not count:
                        continue
                    if drawn:
                        self.drawn_ways[lod] += 1
                    self.segments_drawn += drawn
                    self.corridor_segments += drawn

    def _draw_way(self, draw, xs, ys, frm: int, to: int, colour, width: int) -> int:
        """Mirror of `drawWay`, with scale decimation."""
        if to - frm < 2:
            return 0
        before = self.work
        self.work += to - frm
        drawn = 0
        run: list[tuple[int, int]] = []

        ax = xs[frm]
        ay = ys[frm]
        a_visible = self.visible(ax, ay)
        apx = apy = 0
        have_a = False

        for i in range(frm, to - 1):
            bx = xs[i + 1]
            by = ys[i + 1]
            if i + 2 < to:
                sx = bx - ax
                sy = by - ay
                if sx * sx + sy * sy < self._step_sq_m:
                    continue
            b_visible = self.visible(bx, by)
            bpx = bpy = 0
            have_b = False

            if a_visible or b_visible:
                if not have_a:
                    apx, apy = self.screen(ax, ay)
                bpx, bpy = self.screen(bx, by)
                have_b = True
                if run and run[-1] == (apx, apy):
                    run.append((bpx, bpy))
                else:
                    if len(run) > 1:
                        draw.line(run, fill=colour, width=width, joint="curve")
                    run = [(apx, apy), (bpx, bpy)]
                drawn += 1

            a_visible = b_visible
            apx, apy = bpx, bpy
            have_a = have_b
            ax, ay = bx, by

        if len(run) > 1:
            draw.line(run, fill=colour, width=width, joint="curve")
        self.work += drawn * SEGMENT_COST
        self.work_corridor += self.work - before
        return drawn

    # ── route ────────────────────────────────────────────────────────────────
    def route_ranges(self, xs: list[float], ys: list[float], boxes: list[float]) -> list[int]:
        """Mirror of `refreshRouteRanges`.

        Same pair of regimes as the corridor, and by the **same trigger** (the center
        moving [CACHE_REBUILD_M]): in a warm frame the ranges cache is valid and
        this loop does not run. The difference from the corridor is that this one is **not
        resumable** — when it runs, it runs entirely, in a single `onUpdate`.
        """
        before = self.work
        ranges: list[int] = []
        count = len(xs)
        blocks = len(boxes) // 4
        span = BLOCK_POINTS
        open_at = -1
        if blocks == 0:
            blocks = 1
            span = count

        for b in range(blocks):
            frm = b * span
            to = min(frm + span, count)
            if not self.warm:
                self.work += 1
            if len(boxes) >= (b + 1) * 4 and not self.box_visible(
                boxes[b * 4], boxes[b * 4 + 1], boxes[b * 4 + 2], boxes[b * 4 + 3]
            ):
                if open_at >= 0:
                    ranges.extend((open_at, frm))
                    open_at = -1
                continue
            if not self.warm:
                self.work += to - frm
            for i in range(frm, to):
                if self.visible(xs[i], ys[i]):
                    if open_at < 0:
                        open_at = i - 1 if i > 0 else 0
                elif open_at >= 0:
                    ranges.extend((open_at, i))
                    open_at = -1
        if open_at >= 0:
            ranges.extend((open_at, count - 1))
        self.work_route_index += self.work - before
        return ranges

    def draw_route(self, draw, xs, ys, boxes, split: int) -> None:
        ranges = self.route_ranges(xs, ys, boxes)
        passes = [(False, COLOR_ROUTE_BEHIND, WIDTH_BEHIND)] if DRAW_BEHIND else []
        if ROUTE_CASING_COLOR is not None:   # C15a prototype: Waze's dark route edge
            passes.append((True, ROUTE_CASING_COLOR, WIDTH_AHEAD + 2 * ROUTE_CASING_PX))
        passes.append((True, COLOR_ROUTE_LINE, WIDTH_AHEAD))
        for ahead, colour, width in passes:
            colour = rgb(colour)
            for i in range(0, len(ranges) - 1, 2):
                frm = ranges[i]
                to = ranges[i + 1]
                if ahead:
                    frm = max(frm, split)
                else:
                    to = min(to, split)
                if to > frm:
                    drawn = self._draw_range(draw, xs, ys, frm, to, colour, width)
                    self.segments_drawn += drawn
                    self.route_segments += drawn

    def _draw_range(self, draw, xs, ys, frm: int, to: int, colour, width: int) -> int:
        """Mirror of `drawRange`, with scale decimation."""
        before = self.work
        last_x = xs[frm]
        last_y = ys[frm]
        ax, ay = self.screen(last_x, last_y)
        run = [(ax, ay)]
        drawn = 0

        for i in range(frm, to):
            px = xs[i + 1]
            py = ys[i + 1]
            if i + 1 < to:
                sx = px - last_x
                sy = py - last_y
                if sx * sx + sy * sy < self._step_sq_m:
                    continue
            bx, by = self.screen(px, py)
            run.append((bx, by))
            last_x, last_y = px, py
            drawn += 1

        if len(run) > 1:
            draw.line(run, fill=colour, width=width, joint="curve")
        self.work += drawn * SEGMENT_COST
        self.work_route += self.work - before
        return drawn

    # ── rider and north ──────────────────────────────────────────────────────
    def draw_rider(self, draw, x: float, y: float) -> None:
        """Mirror of sheet 4's rider with the good position: halo, cyan ring and the "?" tip."""
        px, py = self.screen(x, y)
        if RIDER_CHEVRON:
            body = [(px, py - 18), (px - 11, py + 12), (px, py + 5), (px + 11, py + 12)]
            draw.polygon(body, fill=(255, 255, 255), outline=(0, 0, 0))
            return
        draw.ellipse((px - 24, py - 24, px + 24, py + 24), fill=rgb(0x12303B))
        draw.ellipse((px - 24, py - 24, px + 24, py + 24), outline=rgb(COLOR_ROUTE_AHEAD), width=4)
        draw.polygon([(px - 15, py + 8.6), (px + 15, py + 8.6), (px, py - 10.5)], fill=(255, 255, 255))

    def draw_destination(self, draw, x: float, y: float) -> None:
        """Mirror of `drawDestination`: the route-colored dot at its end, if under 240 px from the center."""
        px, py = self.screen(x, y)
        if (px - 227) ** 2 + (py - 227) ** 2 > 240 ** 2:
            return
        draw.ellipse((px - 13.5, py - 13.5, px + 13.5, py + 13.5), fill=(0, 0, 0))
        draw.ellipse((px - 10, py - 10, px + 10, py + 10), fill=rgb(COLOR_ROUTE_LINE))

    def draw_north(self, draw) -> None:
        nx = -self._sin
        ny = -self._cos
        draw.line(
            [
                (int(NORTH_CX - nx * NORTH_NEEDLE_PX), int(NORTH_CY - ny * NORTH_NEEDLE_PX)),
                (int(NORTH_CX + nx * NORTH_NEEDLE_PX), int(NORTH_CY + ny * NORTH_NEEDLE_PX)),
            ],
            fill=rgb(COLOR_NORTH),
            width=3,
        )
        draw.text(
            (int(NORTH_CX + nx * NORTH_LABEL_PX) - 3, int(NORTH_CY + ny * NORTH_LABEL_PX) - 5),
            "N",
            fill=rgb(COLOR_NORTH),
        )


# ─── Frame assembly ──────────────────────────────────────────────────────────


def render(route, corridor_raw, zoom: float, at: float, budget: int | None,
           heading_override: float | None = None, warm: bool = False):
    """Draws a frame and returns `(image, renderer, context)`."""
    plane = LocalPlane(route.lat0, route.lon0)
    xs = [plane.x(p[1]) for p in route.points]
    ys = [plane.y(p[0]) for p in route.points]
    boxes = block_boxes(xs, ys)

    # Accumulated distance, to place the rider at the requested fraction.
    cum = [0.0]
    for i in range(1, len(xs)):
        cum.append(cum[-1] + distance(xs[i - 1], ys[i - 1], xs[i], ys[i]))
    target = cum[-1] * at
    idx = 0
    for i, value in enumerate(cum):
        if value <= target:
            idx = i
        else:
            break

    centre_x = xs[idx]
    centre_y = ys[idx]
    # Heading: route tangent ~50 m ahead, as the GPS would deliver it following the route.
    look = idx
    while look + 1 < len(cum) and cum[look] - cum[idx] < 50.0:
        look += 1
    if look == idx:
        look = min(idx + 1, len(xs) - 1)
    heading = (
        heading_override
        if heading_override is not None
        else math.atan2(xs[look] - centre_x, ys[look] - centre_y)
    )

    renderer = MapRenderer(centre_x, centre_y, heading, zoom, budget, warm)

    image = Image.new("RGB", (SCREEN, SCREEN), (0, 0, 0))
    draw = ImageDraw.Draw(image)

    corridor_model = None
    if corridor_raw is not None:
        corridor_model = corridor_raw
        renderer.draw_corridor(draw, corridor_model)
    renderer.draw_route(draw, xs, ys, boxes, idx)
    if DRAW_DESTINATION:
        renderer.draw_destination(draw, xs[-1], ys[-1])
    if DRAW_RIDER:
        renderer.draw_rider(draw, centre_x, centre_y)
    if SHOW_NORTH:
        renderer.draw_north(draw)

    # Round screen: what falls outside the glass does not exist.
    mask = Image.new("L", (SCREEN, SCREEN), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, SCREEN - 1, SCREEN - 1), fill=255)
    round_image = Image.new("RGB", (SCREEN, SCREEN), (0, 0, 0))
    round_image.paste(image, (0, 0), mask)

    context = {
        "idx": idx,
        "heading_deg": math.degrees(heading) % 360.0,
        "cull_m": renderer._cull_m,
        "route_points": len(xs),
        "route_length_m": cum[-1],
        "progress_m": cum[idx],
    }
    return round_image, renderer, context


def load_inputs(route_path: pathlib.Path, corridor_path: pathlib.Path | None):
    route = packer.route_from_mapbox(json.loads(route_path.read_text(encoding="utf-8")))
    corridor_model = None
    stats = None
    if corridor_path is not None and corridor_path.exists():
        plane = LocalPlane(route.lat0, route.lon0)
        raw = parse_overpass(json.loads(corridor_path.read_text(encoding="utf-8")))
        corridor, stats = build_corridor(
            raw, route.points, plane, [t.point_idx for t in route.turns]
        )
        corridor_model = CorridorModel(corridor, plane)
    return route, corridor_model, stats


def main() -> int:
    # The Windows console starts in cp1252 and this script prints accents and arrows.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):  # pragma: no cover
        pass
    repo = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--route", type=pathlib.Path,
                        default=repo / "tools/fixtures/route_tiete_copan.json")
    parser.add_argument("--corridor", type=pathlib.Path,
                        default=repo / "tools/fixtures/corridor_tiete_copan.json")
    parser.add_argument("--zoom", type=float, default=1.2, help="meters per pixel")
    parser.add_argument("--at", type=float, default=0.35, help="fraction 0..1 of progress along the route")
    parser.add_argument("--budget", type=int, default=None,
                        help="corridor leash in work points (floor 220, ceiling 1800)")
    parser.add_argument("--heading", type=float, default=None, help="heading in degrees (overrides the tangent)")
    parser.add_argument("--warm", action="store_true",
                        help="frame with a valid ways cache (does not charge the sweep)")
    parser.add_argument("--out", type=pathlib.Path, required=True)
    parser.add_argument("--no-edge", "--sem-borda", dest="no_edge", action="store_true",
                        help="the route without the dark edge (the watch's test setting turned off)")
    parser.add_argument("--flat", "--plano", dest="flat", action="store_true",
                        help="the flat map, without v1.1.5's laid-back one (the watch's test setting turned off)")
    parser.add_argument("--lods-json", type=pathlib.Path, default=None,
                        help="writes the ways and points per LOD of the whole corridor (DemoFramesTest's answer key)")
    args = parser.parse_args()
    global ROUTE_CASING_COLOR, TILT_K
    if args.no_edge:
        ROUTE_CASING_COLOR = None
    if args.flat:
        TILT_K = 1.0

    route, corridor_model, stats = load_inputs(args.route, args.corridor)
    if args.lods_json is not None and stats is not None:
        # Answer key for `DemoFramesTest` (Kotlin): the same corridor counted by the
        # Python mirror. Two codes that agree are the proof that neither
        # invented a rule — the distance cut exists in both.
        args.lods_json.parent.mkdir(parents=True, exist_ok=True)
        args.lods_json.write_text(json.dumps({
            "generated_by": "python tools/preview_map.py --lods-json",
            "route": args.route.name,
            "corridor": args.corridor.name,
            "ways_per_lod": stats["ways_per_lod"],
            "points_per_lod": stats["points_per_lod"],
            "segments": stats["segments"],
            "bytes": stats["bytes"],
        }, indent=2) + "\n", encoding="utf-8")
        print(f"LODs: ways {stats['ways_per_lod']} · points {stats['points_per_lod']} → {args.lods_json}")
    if stats is not None:
        print(f"corridor: {stats['raw_ways']} raw ways → {stats['clipped']} clipped → "
              f"{stats['segments']} segments, {stats['bytes']} B "
              f"({stats['cut_by_distance']} cut by distance, "
              f"mesh up to {stats['mesh_up_to_m']:.0f} m from the route"
              + (f"; LODs dropped: {stats['dropped_lods']}" if stats['dropped_lods'] else "")
              + ")")

    heading = math.radians(args.heading) if args.heading is not None else None
    image, renderer, context = render(
        route, corridor_model, args.zoom, args.at, args.budget, heading, args.warm
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    image.save(args.out)

    print(
        f"zoom {args.zoom} m/px · at {args.at} (point {context['idx']}, "
        f"{context['progress_m']:.0f} m of {context['route_length_m']:.0f}) · "
        f"heading {context['heading_deg']:.0f}° · cull radius {context['cull_m']:.0f} m"
    )
    print(
        f"ways in view {sum(renderer.visible_ways)} {renderer.visible_ways} · "
        f"drawn {sum(renderer.drawn_ways)} {renderer.drawn_ways}"
    )
    print(
        f"segments {renderer.segments_drawn} "
        f"(corridor {renderer.corridor_segments} · route {renderer.route_segments}) · "
        f"work {renderer.work} "
        f"(scan {renderer.work_scan} · corridor {renderer.work_corridor} · "
        f"route index {renderer.work_route_index} · route {renderer.work_route})"
        + (" CAPPED" if renderer.corridor_capped else "")
    )
    print(
        f"corridor work alone {renderer.work_scan + renderer.work_corridor} "
        f"(the leash only measures this one) · route work "
        f"{renderer.work_route_index + renderer.work_route} (never capped)"
    )
    print(f"PNG: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
