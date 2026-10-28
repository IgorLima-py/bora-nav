#!/usr/bin/env python3
"""Mockups of the watch's riding screen, generated from `docs/design/relogio/tokens.json`.

Why it exists
--------------
The current screen violates RNF-05 (distance at 38 px, arrow at 44 px, versus 55 px = 12% of 454).
Before touching Monkey C (C4), the new screen is drawn in round 454 px HTML from
a `tokens.json`, and this script **checks** what the eye does not: minimum size, contrast,
faces that `Hud.mc` accepts and whether each text fits inside the glass circle.

Usage::

    python tools/design_tokens.py              # generates the 6 mockups and DesignTokens.mc
    python tools/design_tokens.py --check      # exits 0 only if everything passes (and the mockups are up to date)
    python tools/design_tokens.py --gallery X  # a single page, with the 6 screens, for the Artifact
    python tools/design_tokens.py --check --canary   # swaps the distance for 54 px: MUST exit != 0

The map background comes from `tools/preview_map.py` (same renderer as the watch) on the public fixture
`tiete_copan`. The arrow is `TurnArrow.mc` rewritten in SVG and scaled by the token.

Exit codes: 0 ok · 1 our failure.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import math
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

TOKENS = REPO / "docs/design/relogio/tokens.json"
OUT_DIR = REPO / "docs/design/relogio"
HUD_MC = REPO / "watch/source/render/Hud.mc"
CHOICE_MD = REPO / "docs/design/relogio/ESCOLHA.md"
TOKENS_MC = REPO / "watch/source/render/DesignTokens.mc"
STATES = ("far", "near", "arrival")
VARIANTS = ("v1", "v2")

# RNF-05 (docs/01-PRODUCT-SPEC.md): 12% of the 454 px height, and secondary text >= 20 px. Holds for the
# factory size (100%); since C16.5 the rider can shrink below it (see TEXT_FLOOR_PX).
MIN_CRITICAL_PX = 55
MIN_TEXT_PX = 20
# HUD scale floor (C16.5, Igor's request: "I find the numbers too big", "let me change the whole
# size"): no text below 13 px. Origin: the smallest text of the watchface Igor uses every day
# (Montserrat 13 px), which he called "100% smooth, legible" in C16.
TEXT_FLOOR_PX = 13
MIN_CONTRAST = 7.0
# Visible-map floor (% of the glass without black cover): our choice, outside RNF-05.
MIN_MAP_PCT = 60
# HUD layout: the same number in the mockups and in DesignTokens.mc (it is from here that Hud.mc reads).
GAP_ARROW = 14        # between the arrow and the number
GAP_UNIT = 8      # between the number and the unit
GAP_CLOCK = 3         # between the time and the maneuver line (C15b: 4 -> 3; the 7.5 px stroke of the arrow took
                     # the scale ceiling with the orbit to 114%, when the 05-PROTOCOL.md contract fixed 99..115)
GAP_STREET = 2          # between the maneuver line and the street name
GAP_TIME = 4        # between the time remaining and the distance remaining
GAP_DELTA = 8        # between the arrival time and the delta (C16.5): the same gap as the number and the unit
TOP_Y = 8           # edge_margin + 2: top of the top card
BOTTOM_END_Y = 440     # last line the bottom card can reach
CARD_PAD = 10      # card fattening around the content
CARD_RADIUS = 26     # rounded corner of the card
# The warning sign (v4, v1.1.5; sheet 6, option 12): the time in a black cutout, the maneuver on a street sign
# of two lines and the arrival in another cutout. The same numbers in Hud.mc (DesignTokens.TAB_* and PLATE_*).
TAB_TOP = 12      # top of the time cutout
TAB_PAD = 14         # from the text to the cutout edge, on each side: the text width + 28
TAB_EXTRA = 12        # the one-line cutout has the text height plus this: 20 px -> 32
TAB_GAP = 10         # from the bottom of the time cutout to the sign
PLATE_TOP = 54         # top of the sign
PLATE_INSET = 5     # from the sign edge to the frame
PLATE_LINE = 2     # the frame and the rule between the two lines
PLATE_SIDE = 20      # from the content to the sign edge, on each side: the width + 40
PLATE_ROW_MIN = 74 # the top line, at minimum (sheet 6, with the brand's 56 px arrow)
PLATE_ROW_PAD = 2      # from the tallest arrow to the frame and to the rule: the tallest Google icon
                     # (the roundabout) is 75 px at 34 half-height, and the line goes from 74 to 81
PLATE_NAME_EXTRA = 14  # the bottom line has the name body plus this: 28 px -> 42
PLATE_NAME_STEP = 2   # the name goes down from 28 to 22 px in steps of 2 before breaking into two lines
ARRIVAL_END_Y = 436  # bottom of the arrival cutout
ARRIVAL_EXTRA = 16   # the two-line cutout has the two bodies plus this: 34 + 20 -> 70
GAP_DONE = 12       # between the arrival check and "You're here"
# Anti burn-in orbit of the HUD (C10, watch/source/render/BurnIn.mc). The ring is 8 points at `reserve`
# px from the center and moves diagonally: the corner (A, A) is at A * 1.4143 from the center, and it is this radial
# reserve (rounded up, the same integer math as Hud.mc) that goes into the glass adjustment.
# The axes (top, bottom) reserve A.
ORBIT_RADIAL_MILLI = 1414
# The cost the orbit may charge to the HUD's maximum scale (117% before it): amplitudes that
# bring the scale ceiling down by more than this, in percentage points, do not enter.
ORBIT_SCALE_COST_PCT = 2
ORBIT_SEARCH_MAX_PX = 16
# Average width of a character as a fraction of the font size. Conservative on purpose
# (real Roboto Condensed is narrower): better to refuse a mockup that fits than approve
# one that goes over the glass edge.
CHAR_WIDTH = 0.55

# The polygons of the Google icons that TurnArrow.mc draws (C16.5): tools/glifos.py generates the
# two, TurnGlyphs.mc and this JSON, from the same PNGs.
GLYPHS_JSON = pathlib.Path(__file__).resolve().parent / "glifos" / "glifos.json"
TYPES = list(range(31))  # all the types in 05 §TURNS draw an icon
_glyphs_cache: dict = {}


# ─── util ────────────────────────────────────────────────────────────────────


def norm_bytes(path: pathlib.Path) -> bytes:
    """Bytes without CR: the hash must not change because Windows git swapped the line ending."""
    return path.read_bytes().replace(b"\r\n", b"\n")


def stamp() -> str:
    h = hashlib.sha256()
    h.update(norm_bytes(TOKENS))
    h.update(norm_bytes(pathlib.Path(__file__)))
    return h.hexdigest()[:16]


def luminance(hex_color: str) -> float:
    c = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    lin = [v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4 for v in c]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a: str, b: str) -> float:
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def hud_faces() -> list[str]:
    text = HUD_MC.read_text(encoding="utf-8")
    m = re.search(r"FACES\s*=\s*\[([^\]]*)\]", text)
    if not m:
        raise SystemExit("Hud.mc: FACES list not found")
    return re.findall(r'"([^"]+)"', m.group(1))


def format_distance(m: float) -> tuple[str, str]:
    """(number, unit) like NavEngine.formatDistance, with the unit separated."""
    if m < 20:
        return "AGORA", ""
    if m < 1000:
        return str(int(m // 10) * 10), "m"
    return f"{m / 1000:.1f}".replace(".", ","), "km"


# ─── arrow glyph (mirror of TurnArrow.mc) ─────────────────────────────────


def glyph(turn_type: int, cx: float, cy: float, half: float):
    """Returns (segments, polygons, circles, bbox) of the glyph, in screen pixels: mirror of
    TurnArrow.mc. Since C16.5 the glyph is the Google icon as polygons, so segments and
    circles come back empty and each polygon is `([(x, y)..], color)`, color 0 the path, 1 the rest (roundabout
    ring, the other road) and 2 the background (hole). The "straight" one measures 2 × half in height.
    """
    if not _glyphs_cache:
        _glyphs_cache.update(json.loads(GLYPHS_JSON.read_text(encoding="utf-8")))
    m = _glyphs_cache
    name = m["types"][turn_type] if 0 <= turn_type < len(m["types"]) else "straight"
    g = m["glyphs"][name]
    u = 2 * half / m["ref_h"]
    x0, y0, x1, y1 = g["bbox"]
    ox, oy = (x0 + x1) / 2, (y0 + y1) / 2
    poly = [([(cx + (x - ox) * u, cy + (y - oy) * u) for x, y in p["pts"]], p["color"]) for p in g["polys"]]
    w, h = (x1 - x0) * u / 2, (y1 - y0) * u / 2
    return [], poly, [], (cx - w, cy - h, cx + w, cy + h)


def glyph_min_px(half: float) -> float:
    """Smallest max-dimension among all the types: it is what RNF-05 has to cover."""
    worst = []
    for t in TYPES:
        x0, y0, x1, y1 = glyph(t, 0, 0, half)[3]
        worst.append(max(x1 - x0, y1 - y0))
    return min(worst)


def glyph_max_height(half: float) -> int:
    """The height of the tallest glyph, rounded up: the top line of the sign has the same
    height for every maneuver (`Hud.tallestArrow`), and does not jump on each turn."""
    return max(math.ceil(glyph(t, 0, 0, half)[3][3] - glyph(t, 0, 0, half)[3][1] - 1e-9) for t in TYPES)


# ─── layout ──────────────────────────────────────────────────────────────────


def half_chord(y: float, r: float) -> float:
    dy = y - r
    q = r * r - dy * dy
    return math.sqrt(q) if q > 0 else 0.0


def fits_in_circle(x0, y0, x1, y1, r, margin) -> bool:
    """Are the four corners of the box inside the glass (minus the margin)?"""
    lim = (r - margin) ** 2
    return all((x - r) ** 2 + (y - r) ** 2 <= lim for x, y in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)))


def text_width(text: str, px: float) -> float:
    return len(text) * px * CHAR_WIDTH


def format_time(minutes: int) -> str:
    """Time remaining as the rider reads it: '22 min', '1 h 34 min'."""
    if minutes >= 60:
        h, m = divmod(minutes, 60)
        return f"{h} h {m:02d} min" if m else f"{h} h"
    return f"{minutes} min"


def union(boxes):
    return (min(c[0] for c in boxes), min(c[1] for c in boxes),
            max(c[2] for c in boxes), max(c[3] for c in boxes))


def coverage(rectangles, r: float) -> float:
    """Fraction of the glass covered by black rectangles (0..1), by sampling on a 2 px grid."""
    total = covered = 0
    for yy in range(1, int(2 * r), 2):
        for xx in range(1, int(2 * r), 2):
            if (xx - r) ** 2 + (yy - r) ** 2 > r * r:
                continue
            total += 1
            if any(x0 <= xx <= x1 and y0 <= yy <= y1 for x0, y0, x1, y1 in rectangles):
                covered += 1
    return covered / total


# Current screen (Hud.mc in v0.17): top band up to y≈110 and bottom band from y≈398. Estimate
# made from the Hud.mc constants (TOP_TEXT_Y, 20 px font, 44 px arrow, BOTTOM_TEXT_END, SPEED_PX).
CURRENT_RECTS = [(0, 0, 454, 110), (0, 398, 454, 454)]


def radial_reserve(reserve: int) -> int:
    """The extra glass-circle adjustment margin for an orbit of `reserve` px: A·√2 rounded
    up, to an integer, **the same math as `Hud.setReserve`**."""
    return (reserve * ORBIT_RADIAL_MILLI + 999) // 1000


#: The words the sign abbreviates at the start of the name: the watch's `Fmt.PLATE_LONG`/`PLATE_SHORT`.
PLATE_ABBREVIATIONS = (("Avenida ", "Av. "), ("Rua ", "R. "))


def abbreviate_plate(name: str) -> str:
    """Maps "Avenida" to "Av." and "Rua" to "R.", as on the street sign: the watch's `Fmt.plate`."""
    for long, short in PLATE_ABBREVIATIONS:
        if len(name) > len(long) and name.startswith(long):
            return short + name[len(long):]
    return name


def half_width_at_top(y: float, r: float, margin: float) -> float:
    """The largest half-width of a box with top at `y`, above the center, and the top corners on the
    glass minus `margin`: `Hud.halfAtTop`."""
    q = (r - margin) ** 2 - (r - y) ** 2
    return math.sqrt(q) if q > 0 else 0.0


def two_lines(name: str) -> list[str]:
    """Breaks at the space closest to the middle: "Av. Moreira Guimarães" becomes "Av. Moreira" / "Guimarães"."""
    middle = len(name) / 2
    best = -1
    for i, ch in enumerate(name):
        if ch == " " and (best < 0 or abs(i - middle) < abs(best - middle)):
            best = i
    return [name] if best < 0 else [name[:best], name[best + 1:]]


def cut_text(text: str, px: float, limit: float) -> str:
    """The text cut with "…" until it fits in `limit` px."""
    if text_width(text, px) <= limit:
        return text
    while len(text) > 1 and text_width(text + "…", px) > limit:
        text = text[:-1]
    return text + "…"


def fit_name(name: str, start: int, floor: int, two: int, limit: float) -> tuple[int, list[str]]:
    """The body and lines of the name on the sign: from `start` px going down by PLATE_NAME_STEP to
    PLATE_NAME_STEP until `floor` on a single line; if it does not fit, two lines of `two` px, each one cut
    if it still overflows. `Hud.fitPlateName` does the same ladder with the measured width."""
    px = start
    while True:
        if text_width(name, px) <= limit:
            return px, [name]
        if px - PLATE_NAME_STEP < floor:
            break
        px -= PLATE_NAME_STEP
    return two, [cut_text(line, two, limit) for line in two_lines(name)]


def build_plate(tokens: dict, variant: str, state: str, data: dict, reserve: int = 0) -> dict:
    """The v4 "Warning sign" (sheet 6, option 12): the mirror of `Hud.drawPlate` and `Hud.drawArrivalTab`.

    On top, the time in a black cutout; right below, the street sign with the arrow and the distance on the top
    line and the street name on the bottom one; at the bottom, the arrival in another black cutout. As in `build_scene`,
    nothing is a position chosen by eye: the sign and the cutouts move until the corners fit in the glass."""
    v = tokens["variants"][variant]
    colors = tokens["colors"]
    r = tokens["screen"]["px"] / 2
    margin = tokens["screen"]["edge_margin"] + radial_reserve(reserve)
    items: list[dict] = []
    rectangles: list[tuple] = []

    def text(x, y, px, color, s, anchor, family="text", width=None):
        w = width if width is not None else text_width(s, px)
        x0 = x - (w / 2 if anchor == "c" else 0 if anchor == "l" else w)
        items.append({"kind": "text", "x": x, "y": y, "px": px, "color": color, "s": s,
                      "anchor": anchor, "family": family, "box": (x0, y, x0 + w, y + px)})
        return items[-1]

    def box(x0, y0, x1, y1, color):
        """The sign: its 4 corners have to fit in the glass, because the white frame cut by the
        round edge would stop being a sign."""
        items.append({"kind": "box", "color": color, "box": (x0, y0, x1, y1)})
        rectangles.append((x0, y0, x1, y1))

    def cutout(x0, y0, x1, y1):
        """A black cutout: it covers the map, but its corner may leave the glass (it is black over the
        watch's black frame). What has to fit is the text inside it."""
        rectangles.append((x0, y0, x1, y1))

    def slide(x0, y0, x1, y1, step):
        """Moves the box in steps of 2 px (downward with step > 0) until the 4 corners fit in the glass."""
        while not fits_in_circle(x0, y0, x1, y1, r, margin):
            y0 += step
            y1 += step
            if not 0 < y0 < 2 * r:
                raise SystemExit(f"{variant}/{state}: the sign does not fit in the glass")
        return y0, y1

    urgent = state == "near"
    arrived = state == "arrival"
    background = colors["urgent"] if urgent else colors["plate"]
    ink = colors["warn_ink"] if urgent else colors["primary"]

    # The time, in a black cutout --------------------------------------------
    clock = data["clock"]
    hp = v["clock_px"]
    hw = text_width(clock, hp)
    slack = TAB_EXTRA / 2
    t0, _ = slide(r - hw / 2, TAB_TOP + reserve + slack, r + hw / 2, TAB_TOP + reserve + slack + hp, 2)
    y1 = t0 + hp + slack
    cutout(r - hw / 2 - TAB_PAD, t0 - slack, r + hw / 2 + TAB_PAD, y1)
    text(r, t0, hp, colors["secondary"], clock, "c")

    # The sign --------------------------------------------------------------
    py = max(PLATE_TOP + reserve, y1 + TAB_GAP)
    limit = 2 * half_width_at_top(py, r, margin) - 2 * PLATE_SIDE
    half = v["arrow_half"]
    if arrived:
        mark = v["done_px"]
        main_text, p_px = "You're here", v["arrival_px"]
        pw = text_width(main_text, p_px)
        total = mark + GAP_DONE + pw
        row_h = max(mark, p_px)
        name_start = v["dest_px"]
    else:
        main_text, unit = format_distance(data["dist_m"])
        p_px, u_px = v["dist_px"], v["unit_px"]
        bx0, by0, bx1, by1 = glyph(data["turn_type"], 0, 0, half)[3]
        aw = bx1 - bx0
        pw = text_width(main_text, p_px)
        uw = text_width(unit, u_px)
        total = aw + GAP_ARROW + pw + GAP_UNIT + uw
        row_h = max(glyph_max_height(half), p_px)
        name_start = v["street_px"]
    name = abbreviate_plate(data["street"]) if data["street"] else ""
    if name:
        n_px, lines = fit_name(name, name_start, v["street_min_px"], v["street_two_px"], limit)
        name_w = max(text_width(line, n_px) for line in lines)
    else:
        n_px, lines, name_w = 0, [], 0
    h1 = max(PLATE_ROW_MIN, row_h + 2 * PLATE_ROW_PAD + PLATE_LINE)
    h2 = name_start + PLATE_NAME_EXTRA if lines else 0
    height = PLATE_INSET + h1 + (PLATE_LINE + h2 if lines else 0) + PLATE_INSET
    width = max(total, name_w) + 2 * PLATE_SIDE
    py, _ = slide(r - width / 2, py, r + width / 2, py + height, 2)
    box(r - width / 2, py, r + width / 2, py + height, background)

    cy1 = py + PLATE_INSET + PLATE_LINE + (h1 - PLATE_LINE) / 2
    x = r - total / 2
    if arrived:
        items.append({"kind": "mark", "color": colors["route_ahead"],
                      "box": (x, cy1 - mark / 2, x + mark, cy1 + mark / 2)})
        text(x + mark + GAP_DONE, cy1 - p_px / 2, p_px, colors["primary"], main_text, "l", "number", width=pw)
    else:
        acx, acy = x - bx0, cy1 - (by0 + by1) / 2
        items.append({"kind": "arrow", "cx": acx, "cy": acy, "half": half, "color": ink,
                      "rest": colors.get("arrow_rest", "#6A7380"), "background": background, "maneuver": data["turn_type"],
                      "box": glyph(data["turn_type"], acx, acy, half)[3]})
        text(x + aw + GAP_ARROW, cy1 - p_px / 2, p_px, ink, main_text, "l", "number", width=pw)
        text(x + aw + GAP_ARROW + pw + GAP_UNIT, cy1 + p_px * 0.36 - u_px * 0.8, u_px, ink, unit, "l",
              "number", width=uw)
    if lines:
        cy2 = py + PLATE_INSET + h1 + PLATE_LINE + h2 / 2
        if len(lines) == 1:
            text(r, cy2 - n_px / 2, n_px, ink, lines[0], "c", "number")
        else:
            text(r, cy2 - n_px - 2, n_px, ink, lines[0], "c", "number")
            text(r, cy2 + 2, n_px, ink, lines[1], "c", "number")

    # The arrival, in another black cutout ----------------------------------------
    end = float(ARRIVAL_END_Y - reserve)
    if arrived:
        line = f"arrived at {data['clock']}"
        cp = v["arrived_at_px"]
        w = text_width(line, cp)
        t0, t1 = slide(r - w / 2, end - slack - cp, r + w / 2, end - slack, -2)
        cutout(r - w / 2 - TAB_PAD, t0 - slack, r + w / 2 + TAB_PAD, t1 + slack)
        text(r, t0, cp, colors["secondary"], line, "c")
    else:
        hh, mm = divmod(int(data["clock"][:2]) * 60 + int(data["clock"][3:]) + data["minutes"], 60)
        eta = f"{hh % 24}:{mm:02d}"
        rest = f"{format_time(data['minutes'])} · {data['rest']}"
        tp, dp, rp = v["time_px"], v["status_px"], v["rest_px"]
        delta = data.get("delta", "")
        w_eta = text_width(eta, tp)
        w_delta = text_width(delta, dp) if delta else 0
        w1 = w_eta + (GAP_DELTA + w_delta if delta else 0)
        w2 = text_width(rest, rp)
        w = max(w1, w2)
        middle = ARRIVAL_EXTRA / 2
        t0, t1 = slide(r - w / 2, end - middle - tp - rp, r + w / 2, end - middle, -2)
        cutout(r - w / 2 - TAB_PAD, t0 - middle, r + w / 2 + TAB_PAD, t1 + middle)
        text(r - w1 / 2, t0, tp, colors["primary"], eta, "l", "number", width=w_eta)
        if delta:
            delta_color = colors["late"] if delta.startswith("+") else colors["arrived"]
            text(r - w1 / 2 + w_eta + GAP_DELTA, t0 + tp - dp, dp, delta_color, delta, "l", width=w_delta)
        text(r, t1 - rp, rp, colors["secondary"], rest, "c", width=w2)

    return {"items": items, "rectangles": rectangles, "radius": 0, "variant": variant, "state": state,
            "map_pct": 100 * (1 - coverage(rectangles, r))}


def build_scene(tokens: dict, variant: str, state: str, data: dict, reserve: int = 0) -> dict:
    """Layout of a screen: list of items with a box. Nothing here is a position chosen by eye:
    the maneuver group goes down to the first `y` where the whole box fits in the circle.

    style `strip`: two black bands edge to edge. style `cards`: the map takes up the whole glass
    and two rounded black cards hold the maneuver (top) and the time (bottom). style `plate`:
    the [build_plate]."""
    v = tokens["variants"][variant]
    if v["style"] == "plate":
        return build_plate(tokens, variant, state, data, reserve)
    colors = tokens["colors"]
    r = tokens["screen"]["px"] / 2
    margin = tokens["screen"]["edge_margin"] + radial_reserve(reserve)
    cards = v["style"] == "cards"
    pad = CARD_PAD if cards else 0   # only fattens the card; the content position is the same in both styles
    items: list[dict] = []

    def text(x, y, px, color, s, anchor, family="text", width=None):
        w = width if width is not None else text_width(s, px)
        x0 = x - (w / 2 if anchor == "c" else 0 if anchor == "l" else w)
        items.append({"kind": "text", "x": x, "y": y, "px": px, "color": color, "s": s,
                      "anchor": anchor, "family": family, "box": (x0, y, x0 + w, y + px)})
        return items[-1]

    urgent = state == "near"
    arrived = state == "arrival"
    main_color = colors["arrived"] if arrived else (colors["urgent"] if urgent else colors["primary"])
    half = v["arrow_half"]

    # Maneuver --------------------------------------------------------------
    y = TOP_Y + reserve
    if v["clock_on_top"]:
        text(r, y, v["clock_px"], colors["secondary"], data["clock"], "c")
        y += v["clock_px"] + GAP_CLOCK

    turn_type = 12 if arrived else data["turn_type"]
    if arrived:
        main_text, unit, p_px, family_p = "You're here", "", v["arrival_px"], "text"
    else:
        main_text, unit = format_distance(data["dist_m"])
        p_px, family_p = v["dist_px"], "number"
    u_px = v["unit_px"]
    gap_arrow, gap_unit = GAP_ARROW, GAP_UNIT
    bx0, by0, bx1, by1 = glyph(turn_type, 0, 0, half)[3]      # real box of the glyph, centered on (0,0)
    aw, ah = bx1 - bx0, by1 - by0
    pw = text_width(main_text, p_px)
    uw = text_width(unit, u_px) if unit else 0
    total = aw + gap_arrow + pw + (gap_unit + uw if unit else 0)
    row_h = max(p_px, ah)
    x0 = r - total / 2

    y_row = y
    while not fits_in_circle(x0, y_row, x0 + total, y_row + row_h, r, margin):
        y_row += 2
        if y_row > 200:
            raise SystemExit(f"{variant}/{state}: maneuver group does not fit in the glass")

    acx = x0 - bx0
    acy = y_row + row_h / 2 - (by0 + by1) / 2
    items.append({"kind": "arrow", "cx": acx, "cy": acy, "half": half, "color": main_color,
                  "rest": colors.get("arrow_rest", "#6A7380"), "background": colors.get("card", colors["background"]),
                  "maneuver": turn_type, "box": glyph(turn_type, acx, acy, half)[3]})
    px_x = x0 + aw + gap_arrow
    text(px_x, y_row + (row_h - p_px) / 2, p_px, main_color, main_text, "l", family_p, width=pw)
    if unit:
        base = y_row + (row_h - p_px) / 2 + p_px * 0.80
        text(px_x + pw + gap_unit, base - u_px * 0.80, u_px, main_color, unit, "l", family_p, width=uw)

    top_end = y_row + row_h
    street = data["street"]
    if street:
        y_name = top_end + GAP_STREET
        text(r, y_name, v["street_px"], colors["arrived"] if arrived else colors["secondary"], street, "c")
        top_end = y_name + v["street_px"]
    top_box = union([i["box"] for i in items])   # includes the time, when there is one

    # Time remaining ------------------------------------------------------
    tp = v["time_px"]
    st_px = v["status_px"]
    if arrived:
        main_b, rest_b = "arrived", ""
        color_b = colors["arrived"]
    else:
        main_b, rest_b = format_time(data["minutes"]), f' · {data["rest"]}'
        color_b = colors["primary"]
    stacked = v.get("bottom") == "stacked"
    if stacked:
        # v3 (C15a): the arrival time large on top and "time · distance" below, centered.
        h, m = divmod(int(data["clock"][:2]) * 60 + int(data["clock"][3:]) + data["minutes"], 60)
        eta = f"{h % 24}:{m:02d}"
        line2 = "arrived" if arrived else f"{format_time(data['minutes'])} · {data['rest']}"
        rp = v["rest_px"]
        # C16.5: the arrival delta against the trip start's, to the right of the time (Hud.drawTimeCard).
        delta = "" if arrived else data.get("delta", "")
        w_eta = text_width(eta, tp)
        w_delta = text_width(delta, rp) if delta else 0
        w1 = w_eta + (GAP_DELTA + w_delta if delta else 0)
        w2 = text_width(line2, rp)
        height = tp + 2 + rp
        wb = max(w1, w2)
        y_end = float(BOTTOM_END_Y - reserve)
        while not fits_in_circle(r - wb / 2, y_end - height, r + wb / 2, y_end, r, margin):
            y_end -= 2
            if y_end < r:
                raise SystemExit(f"{variant}/{state}: bottom card does not fit in the glass")
        text(r - w1 / 2, y_end - height, tp, colors["primary"], eta, "l", "number", width=w_eta)
        if delta:
            delta_color = colors["late"] if delta.startswith("+") else colors["arrived"]
            text(r - w1 / 2 + w_eta + GAP_DELTA, y_end - height + tp - rp, rp, delta_color, delta, "l",
                  width=w_delta)
        text(r - w2 / 2, y_end - rp, rp, colors["secondary"], line2, "l", width=w2)
        bottom_box = union([i["box"] for i in items[-(3 if delta else 2):]])
        y_line = y_end - height
    w_time = text_width(main_b, tp)
    w_rest = text_width(rest_b, st_px) if rest_b else 0
    gap_b = GAP_TIME
    w_total = w_time + (gap_b + w_rest if rest_b else 0)
    y_end = float(BOTTOM_END_Y - reserve)
    while not stacked:
        y_line = y_end - tp
        xb = r - w_total / 2
        if fits_in_circle(xb, y_line, xb + w_total, y_end, r, margin):
            break
        y_end -= 2
        if y_end < r:
            raise SystemExit(f"{variant}/{state}: timeline does not fit in the glass")
    if not stacked:
        text(xb, y_line, tp, color_b, main_b, "l", "number", width=w_time)
        if rest_b:
            text(xb + w_time + gap_b, y_line + (tp - st_px) / 2 + 2, st_px, colors["secondary"], rest_b, "l")
        bottom_box = union([i["box"] for i in items[-2:] if i["kind"] == "text"] if rest_b else [items[-1]["box"]])

    if cards:
        rects = [(top_box[0] - pad, top_box[1] - pad, top_box[2] + pad, top_box[3] + pad),
                 (bottom_box[0] - pad, bottom_box[1] - pad, bottom_box[2] + pad, bottom_box[3] + pad)]
        radius = v.get("card_radius", CARD_RADIUS)
    else:
        rects = [(0, 0, 2 * r, top_end + 6), (0, y_line - 6, 2 * r, 2 * r)]
        radius = 0
    return {"items": items, "rectangles": rects, "radius": radius, "variant": variant, "state": state,
            "map_pct": 100 * (1 - coverage(rects, r))}


# ─── background map ──────────────────────────────────────────────────────────


def scene_data(tokens: dict, state: str):
    """Renders the background with preview_map.py and returns (base64 png, HUD data)."""
    import preview_map as pm

    pm.SHOW_NORTH = False
    # Mockups v1/v2 are historical: the C15b map (rider at 276, flat, slate streets with no
    # border), the route with the petrol border and the chevron from before sheet 4.
    pm.ANCHOR_Y = 276
    pm.CORNER_PX = 276.0
    pm.TILT_K = 1.0
    pm.LOD_COLOR = [0x3A4550, 0x323C46, 0x2C353E, 0x262E36]
    pm.LOD_WIDTH = [14, 11, 9, 7]
    pm.ROAD_EDGE_PX = 0
    pm.ROUTE_CASING_COLOR = 0x0B5A73
    pm.RIDER_CHEVRON = True
    pm.DRAW_DESTINATION = False
    pm.COLOR_ROUTE_LINE = int(tokens['colors']['route_ahead'][1:], 16)
    pm.COLOR_ROUTE_AHEAD = int(tokens['colors']['route_ahead'][1:], 16)
    pm.COLOR_ROUTE_BEHIND = int(tokens['colors']['route_behind'][1:], 16)
    scene = tokens["scenes"][state]
    route, corridor, _ = pm.load_inputs(REPO / "tools/fixtures/route_tiete_copan.json",
                                        REPO / "tools/fixtures/corridor_tiete_copan.json")
    plane = pm.LocalPlane(route.lat0, route.lon0)
    xs = [plane.x(p[1]) for p in route.points]
    ys = [plane.y(p[0]) for p in route.points]
    cum = [0.0]
    for i in range(1, len(xs)):
        cum.append(cum[-1] + pm.distance(xs[i - 1], ys[i - 1], xs[i], ys[i]))
    turn = route.turns[scene["maneuver"]]
    target = max(0.0, cum[turn.point_idx] - scene["dist_m"])
    at = min(target / cum[-1], 0.999)
    img, _, ctx = pm.render(route, corridor, scene["zoom"], at, None)
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "PNG", optimize=True)
    actual = cum[turn.point_idx] - ctx["progress_m"]
    data = {
        "turn_type": turn.type, "dist_m": actual if scene["dist_m"] else 0.0,
        "street": turn.street_name if state != "arrival" else route.dest_name,
        "minutes": scene["remaining_min"], "rest": scene["rest"], "clock": "14:12",
        "delta": scene.get("delta", ""),
    }
    return base64.b64encode(buf.getvalue()).decode(), data


# ─── HTML ────────────────────────────────────────────────────────────────────

FONT_CSS = {
    "RobotoCondensedRegular": "'Roboto Condensed','Arial Narrow','Roboto',sans-serif",
    "RobotoCondensedBold": "'Roboto Condensed','Arial Narrow','Roboto',sans-serif",
    "RobotoRegular": "'Roboto','Helvetica Neue',Arial,sans-serif",
    "RobotoMedium": "'Roboto','Helvetica Neue',Arial,sans-serif",
    "BionicBold": "'Roboto Condensed','Arial Narrow',sans-serif",
    "BionicMedium": "'Roboto Condensed','Arial Narrow',sans-serif",
}
#: The CSS weight of each face (the `font:` shorthand wants the weight before the size).
FONT_WEIGHT = {"RobotoCondensedBold": 700, "BionicBold": 700, "RobotoMedium": 500, "BionicMedium": 500}


def svg_arrow(item: dict, screen: int) -> str:
    seg, poly, circ, _ = glyph(item["maneuver"], item["cx"], item["cy"], item["half"])
    c = item["color"]
    ink = {0: c, 1: item.get("rest", "#6A7380"), 2: item.get("background", "#000000")}
    p = []
    for x1, y1, x2, y2, w in seg:
        p.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{c}" '
                 f'stroke-width="{w:.1f}" stroke-linecap="butt"/>')
    for pts, color in poly:
        p.append('<polygon points="' + " ".join(f"{x:.1f},{y:.1f}" for x, y in pts) + f'" fill="{ink[color]}"/>')
    for x, y, rad, w, filled in circ:
        if filled:
            p.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{rad:.1f}" fill="{c}"/>')
        else:
            p.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{rad:.1f}" fill="none" stroke="{c}" stroke-width="{w:.1f}"/>')
    return (f'<svg width="{screen}" height="{screen}" viewBox="0 0 {screen} {screen}" '
            f'style="position:absolute;left:0;top:0">' + "".join(p) + "</svg>")


def html_screen(tokens: dict, scene: dict, map_b64: str) -> str:
    """A round 454 px glass, self-contained (inline styles)."""
    screen = tokens["screen"]["px"]
    faces = tokens["faces"]
    parts = [f'<div class="glass" style="position:relative;width:{screen}px;height:{screen}px;border-radius:50%;'
              f'overflow:hidden;background:#000;flex:none">',
              f'<img alt="" src="data:image/png;base64,{map_b64}" width="{screen}" height="{screen}" '
              f'style="position:absolute;left:0;top:0;display:block">',
              ]
    for x0, y0, x1, y1 in scene["rectangles"]:
        parts.append(f'<div style="position:absolute;left:{x0:.0f}px;top:{y0:.0f}px;width:{x1 - x0:.0f}px;'
                      f'height:{y1 - y0:.0f}px;background:#000;border-radius:{scene["radius"]}px"></div>')
    for it in scene["items"]:
        if it["kind"] == "arrow":
            parts.append(svg_arrow(it, screen))
        else:
            face = faces["number" if it["family"] == "number" else "text"]
            fam = FONT_CSS[face]
            weight = FONT_WEIGHT.get(face, 400)
            x0 = it["box"][0]
            parts.append(
                f'<div style="position:absolute;left:{x0:.1f}px;top:{it["y"]:.1f}px;font:{weight} {it["px"]}px/{it["px"]}px {fam};'
                f'color:{it["color"]};white-space:nowrap;'
                f'{"font-variant-numeric:tabular-nums;" if it["family"] == "number" else ""}">{it["s"]}</div>')
    parts.append("</div>")
    return "".join(parts)


def page(title: str, body: str, st: str) -> str:
    return (f"<!doctype html>\n<!-- generated by tools/design_tokens.py stamp:{st} — do not edit by hand -->\n"
            f'<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<meta name="stamp" content="{st}"><title>{title}</title>'
            f'<style>body{{margin:0;background:#111;color:#ddd;font:16px system-ui;display:flex;'
            f'flex-direction:column;align-items:center;padding:24px;gap:12px}}</style></head>'
            f'<body>{body}</body></html>\n')


# The mockup files keep their file names (the docs link them): state -> file prefix.
STATE_FILE = {"far": "longe", "near": "perto", "arrival": "chegada"}


def gen_all(tokens: dict) -> dict[str, str]:
    st = stamp()
    backgrounds = {e: scene_data(tokens, e) for e in STATES}
    output = {}
    for v in VARIANTS:
        for e in STATES:
            b64, data = backgrounds[e]
            scene = build_scene(tokens, v, e, data)
            name = f"{STATE_FILE[e]}_{v}.html"
            output[name] = page(f"Bora? {e} {v}", html_screen(tokens, scene, b64), st)
    return output


def gen_gallery(tokens: dict) -> str:
    st = stamp()
    backgrounds = {e: scene_data(tokens, e) for e in STATES}
    labels = {"far": "Far maneuver", "near": "Near maneuver (≤ 60 m, amber)", "arrival": "Arrival"}
    blocks = []
    for v in VARIANTS:
        info = tokens["variants"][v]
        screens = []
        for e in STATES:
            b64, data = backgrounds[e]
            scene = build_scene(tokens, v, e, data)
            screens.append(f'<figure><div class="frame">{html_screen(tokens, scene, b64)}</div>'
                         f'<figcaption>{labels[e]}<span>visible map {scene["map_pct"]:.0f}%</span></figcaption></figure>')
        blocks.append(f'<section><h2><em>{v.upper()}</em> {info["name"]}</h2><p>{info["idea"]}</p>'
                      f'<div class="line">{"".join(screens)}</div></section>')
    current = 100 * (1 - coverage(CURRENT_RECTS, tokens["screen"]["px"] / 2))
    return f"""<title>Watch screens</title>
<!-- stamp:{st} -->
<style>
:root{{--bg:#f6f5f2;--fg:#1b1b1b;--muted:#5d5d5d;--card:#ffffff;--line:#dcdad3;--accent:#b45309}}
@media (prefers-color-scheme: dark){{:root:not([data-theme="light"]){{--bg:#121212;--fg:#ececec;--muted:#a3a3a3;--card:#1c1c1c;--line:#333;--accent:#fbbf24}}}}
:root[data-theme="dark"]{{--bg:#121212;--fg:#ececec;--muted:#a3a3a3;--card:#1c1c1c;--line:#333;--accent:#fbbf24}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif}}
main{{max-width:1500px;margin:0 auto;padding-block:24px 56px;padding-inline:16px}}
h1{{font-size:1.6rem;margin:0 0 4px}} h2{{margin:36px 0 2px;font-size:1.3rem}} h2 em{{font-style:normal;color:var(--accent);margin-right:8px}}
p{{color:var(--muted);margin:0 0 14px;max-width:70ch}}
.line{{display:flex;flex-wrap:wrap;gap:20px}}
figure{{margin:0;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px;flex:0 0 auto}}
.frame{{width:min(454px,calc(100vw - 64px));aspect-ratio:1;overflow:hidden}}
.frame .glass{{transform-origin:0 0;transform:scale(var(--k,1))}}
figcaption{{margin-top:8px;font-weight:600}} figcaption span{{display:block;font-weight:400;color:var(--muted);font-size:.85rem}}
.how{{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 18px;margin-top:16px;max-width:75ch}}
</style>
<main>
<h1>New watch screen — pick one</h1>
<p>Two proposals for the same map (Av. São Paulo → Copan, public data). Arrow and distance go past 55 px, the RNF-05 minimum.
Today they are 44 px and 38 px, and the visible map is {current:.0f}%. Each screen shows its own percentage. The route is purple (a single color in the tokens, easy to swap).
The time and the speed are gone: the time remaining sits at the bottom.</p>
<div class="how"><strong>How to choose:</strong> answer in the chat with <b>V1</b> or <b>V2</b>, and what would change. Nobody touches the watch yet: the port is C4.</div>
{"".join(blocks)}
</main>
<script>
function fit(){{document.querySelectorAll('.frame').forEach(function(q){{var k=q.clientWidth/454;q.querySelector('.glass').style.setProperty('--k',k);q.style.height=(454*k)+'px'}})}}
addEventListener('resize',fit);fit();
</script>
"""


# ─── DesignTokens.mc (the chosen variant, in Monkey C) ────────────────────


def chosen_variant(tokens: dict) -> str:
    return tokens["chosen"]


def mc_color(hex_color: str) -> str:
    return "0x" + hex_color[1:].upper()


def gen_mc(tokens: dict) -> str:
    """`DesignTokens.mc`: colors, sizes and gaps of the `tokens["chosen"]` variant.
    Hud.mc, TurnArrow.mc and MapRenderer.mc read from here; none of it is typed by hand in Monkey C."""
    name = chosen_variant(tokens)
    v = tokens["variants"][name]
    c = tokens["colors"]
    lines = [
        f"// GENERATED by tools/design_tokens.py stamp:{stamp()} - do not edit.",
        f"// Variant {name} ({v['name']}, style {v['style']}) of docs/design/relogio/tokens.json.",
        "// Single source: change tokens.json and run python tools/design_tokens.py.",
        "import Toybox.Lang;",
        "",
        "module DesignTokens {",
        "",
        f'    const VARIANT = "{name}";',
        "",
        "    // Colors (docs/design/relogio/tokens.json, colors).",
    ]
    for key, color in (("BACKGROUND", "background"), ("PRIMARY", "primary"), ("SECONDARY", "secondary"),
                       ("URGENT", "urgent"), ("ARRIVED", "arrived"), ("LATE", "late"),
                       ("ROUTE_AHEAD", "route_ahead"), ("ROUTE_BEHIND", "route_behind")):
        lines.append(f"    const {key} = {mc_color(c[color])};")
    # C15b: the dark Waze look (slate card, cyan route with border, streets in wide bands).
    if "card" in c:
        for key, color in (("CARD", "card"), ("STREET_NAME", "street_name"), ("AFTER_STRIP", "after_strip"),
                           ("ICON_BUBBLE", "icon_bubble"), ("ICON", "icon"), ("PILL", "pill"),
                           ("PILL_TEXT", "pill_text"), ("HALO", "halo"), ("PUCK", "puck"),
                           ("ROUTE_CASING", "route_casing"), ("ARROW_REST", "arrow_rest")):
            lines.append(f"    const {key} = {mc_color(c[color])};")
        # The Bora? brand (2026-10-17): the idle ring, the faded signal and the steps of the home screen.
        for key, color in (("RING_OFF", "ring_off"), ("SIGN_OFF", "sign_off"),
                           ("NEAR_TEXT", "near_text"), ("HEADER_MID", "header_mid"),
                           # The favorites star in yellow (Igor, 2026-10-18).
                           ("STAR", "star")):
            if color in c:
                lines.append(f"    const {key} = {mc_color(c[color])};")
        lines.append("    const ROAD_COLORS = [" + ", ".join(mc_color(x) for x in c["road_colors"]) + "] as Array<Number>;")
        mp = tokens["map"]
        lines.append("    const ROAD_WIDTHS = [" + ", ".join(str(x) for x in mp["road_widths_px"]) + "] as Array<Number>;")
        lines += [
            f"    const ROUTE_PX = {mp['route_px']};",
            f"    const ROUTE_CASING_PX = {mp['route_casing_px']};",
            f"    const HALO_RADIUS = {mp['halo_radius']};",
            f"    const PUCK_Y = {mp['puck_y']};",
        ]
        # v1.1.5 (sheet 8, option 25): Maps on black, tilted. The blue route with border, the black border of the
        # streets inside the image and the vertical scale of the collage; and the sign from sheet 6.
        if "route_line" in c:
            for key, color in (("ROUTE_LINE", "route_line"), ("ROUTE_EDGE", "route_edge"),
                               ("ROAD_EDGE", "road_edge"), ("PLATE", "plate"), ("WARN_INK", "warn_ink")):
                lines.append(f"    const {key} = {mc_color(c[color])};")
            lines += [
                f"    const ROAD_EDGE_PX = {mp['road_edge_px']};",
                f"    const TILT_K = {mp['tilt_k']};",
            ]
    lines += [
        "",
        "    // Vector faces (the FACES list in Hud.mc must contain both).",
        f'    const FACE_TEXT = "{tokens["faces"]["text"]}";',
        f'    const FACE_NUMBER = "{tokens["faces"]["number"]}";',
        "",
        "    // Sizes in px, at 100%. RNF-05: DIST_PX and the arrow (2 x ARROW_HALF) >= 55; text >= 20.",
        f"    const ARROW_HALF = {v['arrow_half']};",
        f"    const DIST_PX = {v['dist_px']};",
        f"    const UNIT_PX = {v['unit_px']};",
        f"    const STREET_PX = {v['street_px']};",
        f"    const CLOCK_PX = {v['clock_px']};",
        f"    const STATUS_PX = {v['status_px']};",
        f"    const ARRIVAL_PX = {v['arrival_px']};",
        f"    const TIME_PX = {v['time_px']};",
        f"    const REST_PX = {v.get('rest_px', v['status_px'])};",
        f"    const AFTER_PX = {v.get('after_px', v['status_px'])};",
        f"    const PILL_PX = {v.get('pill_px', v['status_px'])};",
        "",
        "    // Card layout (the same numbers as the mockup).",
        f"    const EDGE_MARGIN = {tokens['screen']['edge_margin']};",
        f"    const TOP_Y = {TOP_Y};",
        f"    const BOTTOM_END_Y = {BOTTOM_END_Y};",
        f"    const CARD_PAD = {CARD_PAD};",
        f"    const CARD_RADIUS = {v.get('card_radius', CARD_RADIUS)};",
        f"    const GAP_ARROW = {GAP_ARROW};",
        f"    const GAP_UNIT = {GAP_UNIT};",
        f"    const GAP_CLOCK = {GAP_CLOCK};",
        f"    const GAP_STREET = {GAP_STREET};",
        f"    const GAP_TIME = {GAP_TIME};",
        f"    const DELTA_GAP = {GAP_DELTA};",
    ]
    if v["style"] == "plate":
        lines += [
            "",
            "    // The warning sign (v4, sheet 6, option 12): the same numbers as build_plate.",
            f"    const STREET_MIN_PX = {v['street_min_px']};",
            f"    const STREET_TWO_PX = {v['street_two_px']};",
            f"    const DEST_PX = {v['dest_px']};",
            f"    const ARRIVED_AT_PX = {v['arrived_at_px']};",
            f"    const DONE_PX = {v['done_px']};",
            f"    const TAB_TOP = {TAB_TOP};",
            f"    const TAB_PAD = {TAB_PAD};",
            f"    const TAB_EXTRA = {TAB_EXTRA};",
            f"    const TAB_GAP = {TAB_GAP};",
            f"    const PLATE_TOP = {PLATE_TOP};",
            f"    const PLATE_INSET = {PLATE_INSET};",
            f"    const PLATE_LINE = {PLATE_LINE};",
            f"    const PLATE_SIDE = {PLATE_SIDE};",
            f"    const PLATE_ROW_MIN = {PLATE_ROW_MIN};",
            f"    const PLATE_ROW_PAD = {PLATE_ROW_PAD};",
            f"    const PLATE_NAME_EXTRA = {PLATE_NAME_EXTRA};",
            f"    const PLATE_NAME_STEP = {PLATE_NAME_STEP};",
            f"    const ARRIVAL_END_Y = {ARRIVAL_END_Y};",
            f"    const ARRIVAL_EXTRA = {ARRIVAL_EXTRA};",
            f"    const GAP_DONE = {GAP_DONE};",
        ]
    lines += [
        "",
        "    // HUD scale accepted by the CONFIG message (C5), in %: px' = (px * pct + 50) / 100.",
        "    // Applies to hud_pct and to each group's % (C16.5); a group's effective scale,",
        "    // (hud_pct * group + 50) / 100, is clamped to this range (Config.groupPct).",
        f"    // MIN: smallest % at which no text falls below {TEXT_FLOOR_PX} px (legibility floor, C16.5).",
        f"    // MAX: largest % at which the 3 states fit in the glass with >= {MIN_MAP_PCT}% of map, all groups at it.",
        "    // Both come from design_tokens.py's computation (scale_range), not by eye.",
        "    // MAX already subtracts the anti burn-in orbit reserve (ORBIT_MAX_PX, C10).",
        f"    const HUD_SCALE_MIN_PCT = {scale_range(tokens)[0]};",
        f"    const HUD_SCALE_MAX_PCT = {scale_ceiling(tokens, orbit_max(tokens))};",
        "",
        "    // HUD anti burn-in orbit (C10, BurnIn.mc): maximum amplitude in px. It is the largest at which",
        f"    // the HUD scale ceiling loses at most {ORBIT_SCALE_COST_PCT} points (orbit_max).",
        f"    const ORBIT_MAX_PX = {orbit_max(tokens)};",
        "}",
        "",
    ]
    return "\n".join(lines)


# ─── check ───────────────────────────────────────────────────────────────────


def check(tokens: dict, canary: bool) -> list[str]:
    failures: list[str] = []
    screen = tokens["screen"]
    faces_ok = hud_faces()
    colors = tokens["colors"]

    for name, face in tokens["faces"].items():
        if face not in faces_ok:
            failures.append(f"face '{face}' ({name}) is not in FACES of Hud.mc {faces_ok}")

    for name in ("primary", "secondary", "urgent", "arrived", "late", "route_ahead"):
        c = contrast(colors[name], colors["background"])
        if c < MIN_CONTRAST:
            failures.append(f"color {name} {colors[name]}: contrast {c:.1f}:1 < {MIN_CONTRAST}:1")
    # The sign (v4): white ink on the petrol and black on the warning amber, both on the same ruler.
    if "plate" in colors:
        for ink, background in (("primary", "plate"), ("warn_ink", "urgent")):
            c = contrast(colors[ink], colors[background])
            if c < MIN_CONTRAST:
                failures.append(f"{ink} {colors[ink]} on {background} {colors[background]}: contrast {c:.1f}:1 < {MIN_CONTRAST}:1")

    for v in VARIANTS:
        info = dict(tokens["variants"][v])
        if canary:
            info["dist_px"] = 54
            tokens = json.loads(json.dumps(tokens))
            tokens["variants"][v] = info
        failures += rnf05_failures(v, info)

    for v in VARIANTS:
        failures += glass_failures(tokens, v)

    # The HUD scale range (C5; legibility floor since C16.5): at both ends the watch
    # still passes, and one step beyond does not. The factory size (100%) stays in RNF-05.
    name = chosen_variant(tokens)
    base = tokens["variants"][name]
    failures += rnf05_failures(name, base)
    orbit = orbit_max(tokens)
    lo, _ = scale_range(tokens)
    hi = scale_ceiling(tokens, orbit)
    if floor_failures(name, scale_variant(base, lo)) or not floor_failures(name, scale_variant(base, lo - 1)):
        failures.append(f"HUD_SCALE_MIN_PCT {lo}: is not the legibility floor boundary ({TEXT_FLOOR_PX} px)")
    if glass_failures(tokens, name, hi, orbit) or not glass_failures(tokens, name, hi + 1, orbit):
        failures.append(f"HUD_SCALE_MAX_PCT {hi}: is not the glass boundary (with an orbit of {orbit} px)")
    if glass_failures(tokens, name, 100, orbit):
        failures.append(f"ORBIT_MAX_PX {orbit}: the 3 states do not fit in the glass at 100%")
    if tokens["variants"][name].get("orbit_px") is None and orbit < ORBIT_SEARCH_MAX_PX and (
        not glass_failures(tokens, name, 100, orbit + 1)
        and scale_ceiling(tokens, orbit + 1) >= scale_ceiling(tokens, 0) - ORBIT_SCALE_COST_PCT
    ):
        failures.append(f"ORBIT_MAX_PX {orbit}: is not the boundary (at {orbit + 1} px it still fits)")
    return failures


def rnf05_failures(v: str, info: dict) -> list[str]:
    """Arrow, distance and texts of the `info` variant against RNF-05."""
    failures = []
    arrow = glyph_min_px(info["arrow_half"])
    if arrow < MIN_CRITICAL_PX:
        failures.append(f"{v}: arrow {arrow:.1f} px < {MIN_CRITICAL_PX} px (smallest glyph, RNF-05)")
    if info["dist_px"] < MIN_CRITICAL_PX:
        failures.append(f"{v}: distance {info['dist_px']} px < {MIN_CRITICAL_PX} px (RNF-05)")
    # "You're here" is secondary text (v1.1.5): RNF-05 only makes the arrow and the distance critical, and the
    # arrival asks nothing of the rider. Up to v3 there was a 40 px floor taken by eye; the sign
    # uses 34 (sheet 6), and the ruler becomes that of the other texts.
    for key in ("street_px", "clock_px", "status_px", "unit_px", "time_px", "arrival_px", "street_min_px",
                  "street_two_px", "rest_px", "after_px", "dest_px", "arrived_at_px"):
        if key in info and info[key] < MIN_TEXT_PX:
            failures.append(f"{v}: {key} {info[key]} px < {MIN_TEXT_PX} px (secondary text)")
    return failures


def glass_failures(tokens: dict, v: str, pct: int = 100, reserve: int = 0) -> list[str]:
    """Do the 3 states of variant `v`, with the HUD at `pct`%, fit in the glass and leave the map in view?
    Uses fixed data (without rendering the map): long street and time on purpose."""
    failures = []
    tokens = json.loads(json.dumps(tokens))
    tokens["variants"][v] = scale_variant(tokens["variants"][v], pct)
    screen = tokens["screen"]
    r = screen["px"] / 2
    sample = {"turn_type": 7, "dist_m": 850.0, "street": "Avenida Marechal Deodoro", "minutes": 94,
               "rest": "88,4 km", "clock": "14:12", "delta": "+1 h 34 min"}
    for e in STATES:
        d = dict(sample, dist_m=850.0 if e == "far" else 45.0 if e == "near" else 0.0)
        if e == "arrival":
            d["street"] = "Avenida São Luís"
        try:
            scene = build_scene(tokens, v, e, d, reserve)
        except SystemExit as err:
            failures.append(str(err))
            continue
        if e != "arrival" and scene["map_pct"] < MIN_MAP_PCT:
            failures.append(f"{v}/{e}: only {scene['map_pct']:.0f}% of the map visible (< {MIN_MAP_PCT}%)")
        for it in scene["items"]:
            x0, y0, x1, y1 = it["box"]
            if not fits_in_circle(x0, y0, x1, y1, r, screen["edge_margin"] - 1):
                failures.append(f"{v}/{e}: '{it.get('s', 'arrow')}' leaves the glass")
    return failures


# ─── HUD scale (CONFIG message, C5) ────────────────────────────────────

#: The sizes the HUD scale multiplies. Gaps and margins stay fixed.
SCALED_KEYS = ("arrow_half", "dist_px", "unit_px", "street_px", "clock_px",
                    "status_px", "arrival_px", "time_px", "rest_px", "after_px", "pill_px",
                    "street_min_px", "street_two_px", "dest_px", "arrived_at_px", "done_px")

#: The sizes that are text: the scale floor (TEXT_FLOOR_PX) applies to all of them.
TEXT_KEYS = tuple(c for c in SCALED_KEYS if c not in ("arrow_half", "done_px"))


def scale(px: int, pct: int) -> int:
    """`px` with the HUD at `pct`%, rounded. **The same integer math as the watch's `Config.groupPx`**:
    if the two diverge, the range generated here stops being valid there."""
    return (px * pct + 50) // 100


def scale_variant(info: dict, pct: int) -> dict:
    """The variant with the HUD at `pct`%, all groups together. **`fixed_font`** (C15b, Nunito as a
    bitmap, which did not scale): the scale moves only the arrow. Since C16.5 the font is vector and v3 has
    `fixed_font: false`."""
    out = dict(info)
    keys = ("arrow_half",) if info.get("fixed_font") else SCALED_KEYS
    for key in keys:
        if key in info:
            out[key] = scale(info[key], pct)
    return out


def floor_failures(v: str, info: dict) -> list[str]:
    """Is any text of the `info` variant below the legibility floor (TEXT_FLOOR_PX)?"""
    return [f"{v}: {key} {info[key]} px < {TEXT_FLOOR_PX} px (legibility floor)"
            for key in TEXT_KEYS if key in info and info[key] < TEXT_FLOOR_PX]


def scale_range(tokens: dict, reserve: int = 0) -> tuple[int, int]:
    """(min, max) % of the HUD scale that CONFIG accepts, in the chosen variant.

    Min: the last % where no text falls below the legibility floor (TEXT_FLOOR_PX),
    going down from 100. Until C15b it was RNF-05; since C16.5 RNF-05 applies to 100% and the rider
    can shrink below it (`DECISIONS.md` §2026-10-16).
    Max: the last % where the 3 states still fit in the glass with the map in view, going up from 100.
    Neither is chosen: it comes out of the math, and `--check` checks the boundary."""
    name = chosen_variant(tokens)
    base = tokens["variants"][name]
    lo = 100
    while lo > 1 and not floor_failures(name, scale_variant(base, lo - 1)):
        lo -= 1
    hi = 100
    while hi < 300 and not glass_failures(tokens, name, hi + 1, reserve):
        hi += 1
    return lo, hi


def scale_ceiling(tokens: dict, reserve: int) -> int:
    """The largest HUD scale % that still fits in the glass with an orbit of `reserve` px.

    **Holds for each group and for all together** (C16.5): the watch limits each group's effective scale
    (`hud_pct` × the group's %) to this ceiling, and the 3 states fit with **all** groups at it;
    shrinking one text never takes another out of the glass, so any mix below the ceiling also fits."""
    return scale_range(tokens, reserve)[1]


def orbit_max(tokens: dict) -> int:
    """The largest amplitude (px) of the anti burn-in orbit: goes up from 0 while the HUD scale ceiling
    loses at most `ORBIT_SCALE_COST_PCT` points and the 3 states fit in the glass at 100%.
    Stops at the first amplitude that breaks the rule. It is not chosen: it comes out of the math, and `--check`
    checks the boundary. The 100% math (the factory scale) is never the one that limits: at 12 px the
    layout still fits with ≥ 60% of map; what limits is the scale ceiling."""
    name = chosen_variant(tokens)
    fixed = tokens["variants"][name].get("orbit_px")
    if fixed is not None:
        # Contract (05-PROTOCOL.md, orbit_px 0..6): holds if the 3 states fit at 100% and the scale ceiling
        # with it still covers the contract's. `--check` checks both things at the boundary.
        return fixed
    base = scale_ceiling(tokens, 0)
    best = 0
    for amp in range(1, ORBIT_SEARCH_MAX_PX + 1):
        if glass_failures(tokens, name, 100, amp):
            break
        if scale_ceiling(tokens, amp) < base - ORBIT_SCALE_COST_PCT:
            break
        best = amp
    return best


def check_mc(tokens: dict) -> list[str]:
    """DesignTokens.mc exists, is up to date with the variant and the variant is the one in ESCOLHA.md."""
    failures = []
    name = chosen_variant(tokens)
    if name not in tokens["variants"]:
        return [f"tokens.json: chosen '{name}' does not exist in variants"]
    text = CHOICE_MD.read_text(encoding="utf-8")
    m = re.search(r"style:\s*(\w+)", text)
    style = tokens["variants"][name]["style"]
    if not m:
        failures.append("ESCOLHA.md does not state the chosen `style:`")
    elif m.group(1) != style:
        failures.append(f"ESCOLHA.md chose style '{m.group(1)}', tokens.json 'chosen' points to '{name}' ({style})")
    if not TOKENS_MC.exists():
        failures.append("missing watch/source/render/DesignTokens.mc (run python tools/design_tokens.py)")
    elif norm_bytes(TOKENS_MC) != gen_mc(tokens).encode("utf-8"):
        failures.append("DesignTokens.mc out of date with tokens.json; run python tools/design_tokens.py")
    return failures


def check_files() -> list[str]:
    failures = []
    expected = {f"{STATE_FILE[e]}_{v}.html" for e in STATES for v in VARIANTS}
    existing = {p.name for p in OUT_DIR.glob("*.html")}
    for n in sorted(expected - existing):
        failures.append(f"missing docs/design/relogio/{n}")
    for n in sorted(existing - expected):
        failures.append(f"extra file docs/design/relogio/{n}")
    st = stamp()
    for n in sorted(expected & existing):
        text = (OUT_DIR / n).read_text(encoding="utf-8")
        m = re.search(r"stamp:([0-9a-f]{16})", text)
        if not m:
            failures.append(f"{n}: no generator stamp")
        elif m.group(1) != st:
            failures.append(f"{n}: stamp mismatch ({m.group(1)} ≠ {st}); run tools/design_tokens.py")
    return failures


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError):  # pragma: no cover
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--canary", action="store_true", help="with --check: distance at 54 px, must fail")
    ap.add_argument("--gallery", dest="gallery", type=pathlib.Path, help="writes the single page with the 6 screens")
    args = ap.parse_args()
    tokens = json.loads(TOKENS.read_text(encoding="utf-8"))

    if args.check:
        failures = check(tokens, args.canary)
        if not args.canary:
            failures += check_files() + check_mc(tokens)
        for f in failures:
            print("FAILED:", f)
        if failures:
            return 1
        for v in VARIANTS:
            i = tokens["variants"][v]
            print(f"{v}: arrow {glyph_min_px(i['arrow_half']):.0f} px · distance {i['dist_px']} px · "
                  f"text ≥ {min(i['street_px'], i['clock_px'], i['status_px'], i['unit_px'])} px")
        print("OK: RNF-05, contrast ≥ 7:1, Hud.mc faces, glass circle, 6 mockups and DesignTokens.mc up to date")
        return 0

    if args.gallery:
        args.gallery.parent.mkdir(parents=True, exist_ok=True)
        args.gallery.write_text(gen_gallery(tokens), encoding="utf-8")
        print(f"gallery: {args.gallery}")
        return 0

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    TOKENS_MC.write_bytes(gen_mc(tokens).encode("utf-8"))
    print("generated", TOKENS_MC.relative_to(REPO))
    for name, html in gen_all(tokens).items():
        (OUT_DIR / name).write_text(html, encoding="utf-8")
        print("generated", name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
