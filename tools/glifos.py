"""The watch's maneuver glyphs, from Google's icons (C16.5).

Origin of the drawings: the 192 px PNGs from the Google Maps Navigation SDK sample,
https://github.com/googlemaps-samples/android-navigation-samples @ a73bfbae075de72c8058d0b4df490612cb29078f
(navigation-sample/app/src/main/res/drawable/ic_*.png), under the **Apache License 2.0**
(copy in tools/glifos/google/LICENSE). They are the same ones as in the Navigation SDK page's
icon table (tbt-feed). Modified here: they become polygons and change color.

What the script does:

1. Reads the PNGs stored in ``tools/glifos/google/`` (``--download`` fetches them again from the
   commit above).
2. Traces each one into polygons with *marching squares* at level 0.5 and simplifies with
   Douglas-Peucker. There are two layers: the **path** (black in the PNG, the arrow color on the
   watch) and the **rest** (gray in the PNG: the roundabout ring, the other road of the
   fork). A hole becomes a polygon in the background color, because the watch's ``fillPolygon``
   does not make holes.
3. Writes ``watch/source/render/TurnGlyphs.mc`` (generated; do not edit by hand) and
   ``tools/glifos/glifos.json`` (the same polygons, for the Python mockups).

``--sheet <png>`` draws the polygons at the card size and the "and then" strip size, next
to the original PNG, to check the trace before compiling.
"""
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "tools" / "glifos" / "google"
JSON_OUT = ROOT / "tools" / "glifos" / "glifos.json"
MC_OUT = ROOT / "watch" / "source" / "render" / "TurnGlyphs.mc"

COMMIT = "a73bfbae075de72c8058d0b4df490612cb29078f"
RAW = ("https://raw.githubusercontent.com/googlemaps-samples/android-navigation-samples/"
       f"{COMMIT}/navigation-sample/app/src/main/res/drawable/")

#: ``05-PROTOCOL.md`` §TURNS type → Google icon. The ramp uses the slight curve, as the
#: SDK itself does (ON_RAMP_ and OFF_RAMP_SLIGHT_* use ic_turn_slight_*); the u-turn and the
#: roundabouts are the counterclockwise ones, Brazil's driving side.
TYPE_ICON = [
    "depart",                                     # 0 departure
    "straight",                                   # 1 straight
    "turn_slight_right",                          # 2 slight right
    "turn_right",                                 # 3 right
    "turn_sharp_right",                           # 4 sharp right
    "turn_u_turn_counterclockwise",               # 5 u-turn
    "turn_sharp_left",                            # 6 sharp left
    "turn_left",                                  # 7 left
    "turn_slight_left",                           # 8 slight left
    "roundabout_counterclockwise",                # 9 roundabout (without the exit angle)
    "turn_slight_right",                          # 10 enter the expressway from the right
    "turn_slight_right",                          # 11 leave the expressway on the right
    "destination",                                # 12 arrival
    "straight",                                   # 13 new name
    "fork_left",                                  # 14 fork, to the left
    "fork_right",                                 # 15 fork, to the right
    "merge",                                      # 16 merge
    "merge_left",                                 # 17 merge from the left
    "merge_right",                                # 18 merge from the right
    "destination_left",                           # 19 arrival, on the left
    "destination_right",                          # 20 arrival, on the right
    "roundabout_sharp_right_counterclockwise",    # 21 roundabout, sharp right exit
    "roundabout_right_counterclockwise",          # 22 roundabout, right exit
    "roundabout_slight_right_counterclockwise",   # 23 roundabout, slight right exit
    "roundabout_straight_counterclockwise",       # 24 roundabout, straight-ahead exit
    "roundabout_slight_left_counterclockwise",    # 25 roundabout, slight left exit
    "roundabout_left_counterclockwise",           # 26 roundabout, left exit
    "roundabout_sharp_left_counterclockwise",     # 27 roundabout, sharp left exit
    "roundabout_u_turn_counterclockwise",         # 28 roundabout, u-turn
    "turn_slight_left",                           # 29 enter the expressway from the left
    "turn_slight_left",                           # 30 leave the expressway on the left
]

#: Polygon colors, in the order the watch paints them.
FG, REST, BG = 0, 1, 2

#: Douglas-Peucker in PNG px (192). Half a pixel of the original is 0.2 px on the card at 100%
#: (glyph of ~76 px): not visible. A choice, not a measurement.
EPSILON = 0.5
#: A loop with less area than this (PNG px²) is antialiasing noise.
MIN_AREA = 6.0
#: ``Dc.fillPolygon`` accepts at most 64 points (SDK 9.2.0 doc, Toybox/Graphics/Dc:
#: "Array of coordinates with a 64 point limit"). A larger polygon is simplified again
#: with a larger tolerance until it fits.
MAX_PTS = 64
#: The PNG is 192 px; the watch stores 0..255 per byte.
UNIT = 255.0 / 192.0


def download() -> None:
    SRC.mkdir(parents=True, exist_ok=True)
    for name in sorted(set(TYPE_ICON)):
        out = SRC / f"ic_{name}.png"
        subprocess.run(["curl", "-sfL", "-o", str(out), f"{RAW}ic_{name}.png"], check=True)
    lic = "https://raw.githubusercontent.com/googlemaps-samples/android-navigation-samples/" + COMMIT + "/LICENSE"
    subprocess.run(["curl", "-sfL", "-o", str(SRC / "LICENSE"), lic], check=True)


# --------------------------------------------------------------------------- #
# Tracing
# --------------------------------------------------------------------------- #

def fields(png: Path) -> tuple[np.ndarray, np.ndarray]:
    """(path, all): the PNG's black and the black plus the gray, from 0 to 1."""
    rgba = np.asarray(Image.open(png).convert("RGBA"), dtype=np.float64) / 255.0
    alpha = rgba[..., 3]
    lum = rgba[..., 0]
    # Google's gray sits at 96..127 of 255; the black at 0. The cut at 0.31 (80/255)
    # puts the black/gray edge in the middle of the gradient.
    main = alpha * np.clip((0.31 - lum) / 0.31, 0.0, 1.0)
    return main, alpha


def march(field: np.ndarray, level: float = 0.5) -> list[list[tuple[float, float]]]:
    """The closed contours of ``field`` at ``level``, in px (x, y), without a library."""
    f = np.pad(field, 1)
    h, w = f.shape
    inside = f >= level
    neighbours: dict[tuple, list[tuple]] = {}
    where: dict[tuple, tuple[float, float]] = {}

    def point(key):
        if key in where:
            return where[key]
        kind, i, j = key
        if kind == "h":   # between (i, j) and (i, j+1)
            a, b = f[i, j], f[i, j + 1]
            t = (level - a) / (b - a)
            xy = (j + t - 1.0, i - 1.0)
        else:             # between (i, j) and (i+1, j)
            a, b = f[i, j], f[i + 1, j]
            t = (level - a) / (b - a)
            xy = (j - 1.0, i + t - 1.0)
        where[key] = xy
        return xy

    def link(a, b):
        neighbours.setdefault(a, []).append(b)
        neighbours.setdefault(b, []).append(a)

    for i in range(h - 1):
        for j in range(w - 1):
            tl, tr, br, bl = inside[i, j], inside[i, j + 1], inside[i + 1, j + 1], inside[i + 1, j]
            case = (tl << 3) | (tr << 2) | (br << 1) | bl
            if case in (0, 15):
                continue
            top, right, bottom, left = ("h", i, j), ("v", i, j + 1), ("h", i + 1, j), ("v", i, j)
            if case in (5, 10):
                centre = (f[i, j] + f[i, j + 1] + f[i + 1, j + 1] + f[i + 1, j]) / 4.0 >= level
                if (case == 5) == centre:
                    pairs = [(top, right), (bottom, left)] if case == 5 else [(top, left), (bottom, right)]
                else:
                    pairs = [(top, left), (bottom, right)] if case == 5 else [(top, right), (bottom, left)]
            else:
                edges = []
                if tl != tr:
                    edges.append(top)
                if tr != br:
                    edges.append(right)
                if br != bl:
                    edges.append(bottom)
                if bl != tl:
                    edges.append(left)
                pairs = [(edges[0], edges[1])]
            for a, b in pairs:
                link(a, b)

    loops = []
    seen: set = set()
    for start in neighbours:
        if start in seen:
            continue
        loop = [start]
        seen.add(start)
        prev, cur = None, start
        while True:
            nxt = [n for n in neighbours[cur] if n != prev]
            nxt = nxt[0] if nxt else neighbours[cur][0]
            if nxt == start:
                break
            if nxt in seen:
                break
            loop.append(nxt)
            seen.add(nxt)
            prev, cur = cur, nxt
        loops.append([point(k) for k in loop])
    return loops


def area(poly) -> float:
    s = 0.0
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        s += x0 * y1 - x1 * y0
    return s / 2.0


def contains(poly, x, y) -> bool:
    hit = False
    for (x0, y0), (x1, y1) in zip(poly, poly[1:] + poly[:1]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            hit = not hit
    return hit


def simplify(points, eps):
    """Douglas-Peucker of an open line."""
    if len(points) < 3:
        return list(points)
    (x0, y0), (x1, y1) = points[0], points[-1]
    dx, dy = x1 - x0, y1 - y0
    norm = (dx * dx + dy * dy) ** 0.5
    best, idx = -1.0, 0
    for k in range(1, len(points) - 1):
        px, py = points[k]
        d = abs(dy * px - dx * py + x1 * y0 - y1 * x0) / norm if norm > 0 else ((px - x0) ** 2 + (py - y0) ** 2) ** 0.5
        if d > best:
            best, idx = d, k
    if best <= eps:
        return [points[0], points[-1]]
    return simplify(points[: idx + 1], eps)[:-1] + simplify(points[idx:], eps)


def simplify_loop(loop, eps):
    """Douglas-Peucker of a closed loop: cuts at the point farthest from the first."""
    far = max(range(len(loop)), key=lambda k: (loop[k][0] - loop[0][0]) ** 2 + (loop[k][1] - loop[0][1]) ** 2)
    a = simplify(loop[: far + 1], eps)
    b = simplify(loop[far:] + loop[:1], eps)
    return a[:-1] + b[:-1]


def layer(field: np.ndarray) -> list[tuple[bool, list]]:
    """The loops of a field, each with "is it a hole?" from the nesting depth."""
    loops = [lp for lp in march(field) if abs(area(lp)) >= MIN_AREA]
    out = []
    for k, lp in enumerate(loops):
        x, y = lp[0]
        depth = sum(1 for m, other in enumerate(loops) if m != k and contains(other, x, y))
        eps = EPSILON
        pts = simplify_loop(lp, eps)
        while len(pts) > MAX_PTS:
            eps *= 1.2
            pts = simplify_loop(lp, eps)
        out.append((depth % 2 == 1, pts))
    return out


def trace(png: Path) -> list[tuple[int, list]]:
    """The polygons of an icon, in painting order: ``(color, [(x, y), ...])`` in PNG px."""
    main, everything = fields(png)
    rest_px = ((everything > 0.5) & (main < 0.5)).sum()
    polys: list[tuple[int, list]] = []
    if rest_px > 40:
        for hole, lp in sorted(layer(everything), key=lambda t: t[0]):
            polys.append((BG if hole else REST, lp))
    for hole, lp in sorted(layer(main), key=lambda t: t[0]):
        colour = FG
        if hole:
            # Inside the path's hole there may be rest (gray) or just background.
            mask = Image.new("L", main.shape[::-1], 0)
            ImageDraw.Draw(mask).polygon(lp, fill=255)
            m = np.asarray(mask) > 0
            colour = REST if m.any() and (everything[m] > 0.5).mean() > 0.5 else BG
        polys.append((colour, lp))
    return polys


def quantize(polys):
    out = []
    for colour, lp in polys:
        pts = [(min(255, max(0, round(x * UNIT))), min(255, max(0, round(y * UNIT)))) for x, y in lp]
        dedup = [p for k, p in enumerate(pts) if p != pts[k - 1]]
        if len(dedup) >= 3:
            out.append((colour, dedup))
    return out


def bbox(polys):
    xs = [x for c, lp in polys if c != BG for x, _ in lp]
    ys = [y for c, lp in polys if c != BG for _, y in lp]
    return min(xs), min(ys), max(xs), max(ys)


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def build() -> dict:
    icons = sorted(set(TYPE_ICON), key=TYPE_ICON.index)
    data = {}
    for name in icons:
        polys = quantize(trace(SRC / f"ic_{name}.png"))
        data[name] = {"bbox": bbox(polys), "polys": [{"color": c, "pts": lp} for c, lp in polys]}
    x0, y0, x1, y1 = data["straight"]["bbox"]
    return {"commit": COMMIT, "types": TYPE_ICON, "icons": icons, "ref_h": y1 - y0, "glyphs": data}


def write_mc(model: dict) -> None:
    icons = model["icons"]
    lines = [
        "// GENERATED by tools/glifos.py — do not edit by hand.",
        "//",
        "// Drawings: maneuver icons from the Google Maps Navigation SDK sample,",
        f"// github.com/googlemaps-samples/android-navigation-samples @ {COMMIT[:7]}",
        "// (navigation-sample/app/src/main/res/drawable/ic_*.png), Apache License 2.0",
        "// (tools/glifos/google/LICENSE). Modified: traced into polygons and recolored.",
        "import Toybox.Lang;",
        "",
        "//! The polygons of each icon in a 0..255 frame (the 192 px PNG).",
        "//! Each `ByteArray`: `x0 y0 x1 y1` (the box of what shows), `n` polygons, and",
        "//! per polygon `color` (0 path, 1 rest, 2 background), `k` points and `x y` × k.",
        "module TurnGlyphs {",
        "",
        "    //! Height, in the frame, of the \"straight\": it is what measures `2 × half` on the watch.",
        f"    const REF_H = {model['ref_h']};",
        "",
        "    //! Protocol type → index in [DATA].",
        "    const ICON_OF_TYPE = [" + ", ".join(str(icons.index(n)) for n in model["types"]) + "]b;",
        "",
        "    const DATA = [",
    ]
    for k, name in enumerate(icons):
        g = model["glyphs"][name]
        flat = list(g["bbox"]) + [len(g["polys"])]
        for p in g["polys"]:
            flat += [p["color"], len(p["pts"])]
            for x, y in p["pts"]:
                flat += [x, y]
        sep = "," if k < len(icons) - 1 else ""
        lines.append(f"        // {k}: ic_{name}")
        body = ", ".join(str(v) for v in flat)
        lines.append(f"        [{body}]b{sep}")
    lines += ["    ] as Array<ByteArray>;", "}", ""]
    MC_OUT.write_text("\n".join(lines), encoding="utf-8")


def sheet(model: dict, out: Path) -> None:
    """Polygons on the card (half-height 38) and on the strip (13) next to the original PNG."""
    card, strip, white, grey = (0x1B, 0x22, 0x2C), (0x29, 0x30, 0x3A), (255, 255, 255), (0x6A, 0x73, 0x80)
    colours = {FG: white, REST: grey}

    def render(name, half, bg):
        box = 2 * half * 255.0 / model["ref_h"]
        k = 4
        size = int(box + 8)
        img = Image.new("RGB", (size * k, size * k), bg)
        dr = ImageDraw.Draw(img)
        s = box / 255.0 * k
        off = (size * k - 255 * s) / 2
        for p in model["glyphs"][name]["polys"]:
            dr.polygon([(off + x * s, off + y * s) for x, y in p["pts"]], fill=colours.get(p["color"], bg))
        return img.resize((size, size), Image.LANCZOS)

    font = ImageFont.truetype("arial.ttf", 18)
    rows = []
    for t, name in enumerate(model["types"]):
        orig = Image.open(SRC / f"ic_{name}.png").convert("RGBA").resize((96, 96), Image.LANCZOS)
        back = Image.new("RGBA", orig.size, (255, 255, 255, 255))
        back.alpha_composite(orig)
        rows.append((t, name, back.convert("RGB"), render(name, 38, card), render(name, 13, strip)))
    cols = 3
    cw, rh = 470, 130
    img = Image.new("RGB", (cols * cw + 20, ((len(rows) + cols - 1) // cols) * rh + 20), (24, 24, 24))
    dr = ImageDraw.Draw(img)
    for i, (t, name, orig, big, small) in enumerate(rows):
        x, y = 10 + (i % cols) * cw, 10 + (i // cols) * rh
        img.paste(orig, (x, y))
        img.paste(big, (x + 106, y))
        img.paste(small, (x + 106 + big.size[0] + 10, y + 30))
        dr.text((x + 106 + big.size[0] + 60, y + 10), f"{t}", fill=(255, 200, 60), font=font)
        dr.text((x + 106 + big.size[0] + 60, y + 34), name.replace("_counterclockwise", ""), fill=(220, 220, 220), font=font)
        n = sum(len(p["pts"]) for p in model["glyphs"][name]["polys"])
        dr.text((x + 106 + big.size[0] + 60, y + 58), f"{len(model['glyphs'][name]['polys'])} pol, {n} pts", fill=(140, 140, 140), font=font)
    img.save(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--download", dest="download", action="store_true", help="fetches the PNGs and the LICENSE at the pinned commit")
    ap.add_argument("--sheet", dest="sheet", type=Path, help="draws the check sheet into this PNG")
    args = ap.parse_args()
    if args.download:
        download()
    model = build()
    JSON_OUT.write_text(json.dumps(model, ensure_ascii=False), encoding="utf-8")
    write_mc(model)
    total = sum(len(p["pts"]) for g in model["glyphs"].values() for p in g["polys"])
    print(f"{len(model['icons'])} icons, {total} points, ref_h {model['ref_h']}: {MC_OUT.relative_to(ROOT)}")
    if args.sheet:
        sheet(model, args.sheet)
        print(f"sheet: {args.sheet}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
