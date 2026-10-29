"""Puts the simulator screens (docs/img/tela-*.png) in a watch frame drawn here.

The frame is our own on purpose: the SDK's `device.png` is "Program Material" under the Connect IQ
Developer Agreement and cannot be hosted in a public repo, and the Venu 4 silhouette is Garmin's
(docs/LANCAMENTO.md §O visual). So it is a generic round watch: glass, metal rim, two buttons
on the right and a smooth strap that fades out at the ends. No logo and no text.

The hero and the social preview are one board: the name and the tagline on the left, and underneath the
real downtown SP map (the streets of the recorded OSM corridor and the route to Copan, from the
fixtures), entering a large watch on the right. The four screens go on a separate strip.

    python3 tools/moldura.py            # docs/img/relogio-*.png, hero.png and telas.png
    python3 tools/moldura.py --social   # and docs/brand/bora-social-preview.png (1280x640)

Needs Pillow and numpy. The font is the companion's Outfit (OFL).
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
IMG = ROOT / "docs" / "img"
BRAND_DIR = ROOT / "docs" / "marca"
FIXTURES = ROOT / "tools" / "fixtures"
OUTFIT = ROOT / "companion" / "app" / "src" / "main" / "res" / "font" / "outfit_bold.ttf"
OUTFIT_SEMI = OUTFIT.with_name("outfit_semibold.ttf")

# Route order (`sim.py shots --vitrine`): the turn onto Senador Queirós, Cásper Líbero
# arriving, the Av. Ipiranga radar with the 50 sign and the arrival at Copan.
SCREENS = ["perto", "casper", "radar", "chegada"]
HERO_SCREEN = "radar"          # the one shown large in the hero: street, turn card, radar and sign

SS = 3                       # supersampling: draws at 3x and downsizes, so the edge comes out smooth
W, H = 620, 900              # the whole frame, in final px
R_SCREEN = 227                 # the simulator screen is 454x454
R_GLASS = 241                # black glass around the active area
R_RIM_IN, R_RIM_OUT = 241, 266
R_CASE = 270
STRAP_WIDTH = (300, 276)   # width next to the case and at the tip
BUTTON_DEGREES = (-31, 31)     # from 3 o'clock: ~2h and ~4h
CYAN = (47, 211, 255)       # route_ahead from tokens.json, the same as the brand
INK = (11, 15, 19)         # the brand's dark background
BLACK = (0, 0, 0)            # the brand symbol's background, which is the hero's (Igor, 2026-10-26)


def _gradient(w, h, light, dark_c, angle_deg=135):
    """RGBA linear gradient; the light side is toward `angle_deg` (135 = top left)."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    a = np.radians(angle_deg)
    t = (x - w / 2) * -np.cos(a) + (y - h / 2) * np.sin(a)
    t = (t - t.min()) / (t.max() - t.min())
    c = np.array(light, np.float32) * (1 - t[..., None]) + np.array(dark_c, np.float32) * t[..., None]
    alpha = np.full((h, w, 1), 255, np.float32)
    return Image.fromarray(np.concatenate([c, alpha], axis=2).astype(np.uint8), "RGBA")


def _metal_ring(w, h, cx, cy, r_int, r_ext):
    """Brushed-metal rim: the shine follows the angle, with the light coming from the top left."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    dx, dy = x - cx, y - cy
    r = np.hypot(dx, dy)
    angle_rad = np.arctan2(dy, dx)
    light_c = np.cos(angle_rad - np.radians(-135))                 # 1 at top left, -1 at bottom right
    base = 62 + 34 * light_c + 10 * np.cos(4 * angle_rad)          # cos(4θ) gives the turned-metal reflection
    # a lighter bead near the outer edge and a darker one on the inner
    frac = (r - r_int) / (r_ext - r_int)
    base += 26 * np.exp(-((frac - 0.86) / 0.07) ** 2) - 18 * np.exp(-((frac - 0.08) / 0.08) ** 2)
    gray = np.clip(base, 18, 200)
    rgb = np.stack([gray * 0.96, gray * 0.99, gray * 1.04], axis=2)
    alpha = ((r >= r_int) & (r <= r_ext)).astype(np.float32) * 255
    return Image.fromarray(np.concatenate([np.clip(rgb, 0, 255), alpha[..., None]], axis=2).astype(np.uint8), "RGBA")


def _strap(w, h, cx, cy, brighten=1.0):
    """The two strap halves, smooth, lighter in the middle (silicone), fading out at the ends.
    `brighten` multiplies the gray: the post image wants it more visible on the dark background."""
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    t = np.abs(y - cy) / (h / 2)                                   # 0 at the center, 1 at the tip
    width = (STRAP_WIDTH[0] + (STRAP_WIDTH[1] - STRAP_WIDTH[0]) * t) * SS / 2
    u = np.abs(x - cx) / width                                      # 0 in the middle, 1 at the edge
    inside = u <= 1
    gray = 46 - 16 * u ** 2.2 + 6 * np.exp(-((u - 0.62) / 0.05) ** 2)   # the molded seam bead
    edge = np.clip((1 - u) * width / (1.2 * SS), 0, 1)             # side antialiasing
    end = np.clip((1 - t) / 0.30, 0, 1) ** 1.4                     # fades out before the image edge
    alpha = inside * edge * end * 255
    gray = gray * brighten
    rgb = np.stack([gray * 0.97, gray, gray * 1.05], axis=2)
    return Image.fromarray(np.concatenate([rgb, alpha[..., None]], axis=2).clip(0, 255).astype(np.uint8), "RGBA")


def _button(w, h, cx, cy, degrees):
    """A button: radial rounded rectangle that sticks out ~13 px from the case."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    comp, height = 30 * SS, 56 * SS
    piece = _gradient(comp, height, (150, 156, 164), (52, 57, 63), angle_deg=100)
    mask = Image.new("L", (comp, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, comp - 1, height - 1], radius=9 * SS, fill=255)
    piece.putalpha(mask)
    # a light bead at the top of the button
    ImageDraw.Draw(piece).line([(comp - 4 * SS, 10 * SS), (comp - 4 * SS, height - 10 * SS)],
                              fill=(190, 196, 204, 160), width=2 * SS)
    piece = piece.rotate(-degrees, resample=Image.BICUBIC, expand=True)
    a = np.radians(degrees)
    d = (R_CASE - 17) * SS + comp / 2
    px, py = cx + d * np.cos(a), cy + d * np.sin(a)
    layer.alpha_composite(piece, (int(px - piece.width / 2), int(py - piece.height / 2)))
    return layer


def _circle(size, cx, cy, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return m


def frame_watch(screen: Image.Image, height: int = H, strap_brighten: float = 1.0) -> Image.Image:
    """The 454x454 screen inside the watch; returns RGBA of W x `height`, transparent background.
    A smaller `height` shortens the strap (the hero uses 720)."""
    w, h = W * SS, height * SS
    cx, cy = w / 2, h / 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))

    # case shadow, to give volume on the light background (on dark it vanishes, and that's fine)
    shadow = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    r = (R_CASE + 4) * SS
    ImageDraw.Draw(shadow).ellipse([cx - r, cy - r + 14 * SS, cx + r, cy + r + 14 * SS], fill=(0, 0, 0, 90))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16 * SS)))

    img.alpha_composite(_strap(w, h, cx, cy, strap_brighten))

    for g in BUTTON_DEGREES:
        img.alpha_composite(_button(w, h, cx, cy, g))

    case = _gradient(w, h, (96, 102, 110), (26, 29, 33))
    case.putalpha(_circle((w, h), cx, cy, R_CASE * SS))
    img.alpha_composite(case)

    img.alpha_composite(_metal_ring(w, h, cx, cy, R_RIM_IN * SS, R_RIM_OUT * SS))

    glass = Image.new("RGBA", (w, h), (4, 5, 6, 255))
    glass.putalpha(_circle((w, h), cx, cy, R_GLASS * SS))
    img.alpha_composite(glass)

    t = screen.convert("RGB").resize((2 * R_SCREEN * SS, 2 * R_SCREEN * SS), Image.LANCZOS).convert("RGBA")
    t.putalpha(_circle(t.size, R_SCREEN * SS, R_SCREEN * SS, R_SCREEN * SS))
    img.alpha_composite(t, (int(cx - R_SCREEN * SS), int(cy - R_SCREEN * SS)))

    # glass reflection: a very faint diagonal band at top left
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    diag = ((x - cx) + (y - cy)) / (R_GLASS * SS)
    shine = np.clip(-diag - 0.35, 0, 1) ** 1.5 * 16
    shine *= np.hypot(x - cx, y - cy) <= R_GLASS * SS
    reflection = np.zeros((h, w, 4), np.uint8)
    reflection[..., :3] = 255
    reflection[..., 3] = shine.astype(np.uint8)
    img.alpha_composite(Image.fromarray(reflection, "RGBA"))

    return img.resize((W, height), Image.LANCZOS)


# The map crop: downtown, from Prestes Maia to Copan. Only it goes into the public image; the start of the
# test route is left out.
CENTER = {"lat": (-23.5530, -23.5340), "lon": (-46.6520, -46.6250)}
# The width (px at map scale) and the gray of each road class; the rest is a neighborhood street.
ROADS = {
    "trunk": (7, 60), "primary": (7, 60), "trunk_link": (5, 52), "primary_link": (5, 52),
    "secondary": (6, 54), "secondary_link": (4, 48), "tertiary": (5, 48),
}
STREET = (3, 40)


def _polyline(s: str, precision: int = 6):
    """Mapbox's `polyline6` as [(lat, lon)]."""
    idx = lat = lon = 0
    points = []
    while idx < len(s):
        delta = []
        for _ in range(2):
            offset = res = 0
            while True:
                b = ord(s[idx]) - 63
                idx += 1
                res |= (b & 0x1F) << offset
                offset += 5
                if b < 0x20:
                    break
            delta.append(~(res >> 1) if res & 1 else res >> 1)
        lat += delta[0]
        lon += delta[1]
        points.append((lat / 10 ** precision, lon / 10 ** precision))
    return points


def _in_center(lat, lon):
    return CENTER["lat"][0] <= lat <= CENTER["lat"][1] and CENTER["lon"][0] <= lon <= CENTER["lon"][1]


def _map(w, h, cx, cy, px_per_m, angle_deg=0.0, tail_m=None, streets_json=None):
    """The corridor streets and the route, in RGBA of w x h, with Copan (the end of the route) at
    (cx, cy). `tail_m`: only the last meters of the route (the post image, where the whole route
    crossed the text). `streets_json`: other streets in place of the corridor's, drawn without the
    center crop (the post uses every street around Copan, so the background has blocks and not just
    avenues). Draws at 2x and downsizes, so the thin stroke comes out smooth."""
    k = 2
    streets = json.loads((streets_json or FIXTURES / "corridor_spmarket_copan.json").read_text(encoding="utf-8"))["elements"]
    route = json.loads((FIXTURES / "route_spmarket_copan.json").read_text(encoding="utf-8"))
    points = _polyline(route["routes"][0]["geometry"])
    lat0, lon0 = points[-1]
    cos0 = np.cos(np.radians(lat0))
    a = np.radians(angle_deg)

    def xy(lat, lon):
        x = (lon - lon0) * cos0 * 111_320 * px_per_m
        y = -(lat - lat0) * 110_540 * px_per_m
        x, y = x * np.cos(a) - y * np.sin(a), x * np.sin(a) + y * np.cos(a)
        return ((cx + x) * k, (cy + y) * k)

    img = Image.new("RGBA", (w * k, h * k), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    order = sorted(streets, key=lambda e: ROADS.get(e.get("tags", {}).get("highway"), STREET)[0])
    for via in order:
        geo = [(g["lat"], g["lon"]) for g in via.get("geometry", [])]
        if streets_json is None and not any(_in_center(*g) for g in geo):
            continue
        width, gray = ROADS.get(via.get("tags", {}).get("highway"), STREET)
        d.line([xy(*g) for g in geo], fill=(gray - 6, gray, gray + 10, 255), width=width * k, joint="curve")

    if tail_m is not None:
        left, i = 0.0, len(points) - 1
        while i > 0 and left < tail_m:
            (la, lo), (lb, lob) = points[i - 1], points[i]
            left += np.hypot((lob - lo) * cos0 * 111_320, (lb - la) * 110_540)
            i -= 1
        points = points[i:]
    stretch = [xy(*p) for p in points if _in_center(*p)]
    shine = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(shine).line(stretch, fill=CYAN + (110,), width=34 * k, joint="curve")
    img.alpha_composite(shine.filter(ImageFilter.GaussianBlur(14 * k)))
    d = ImageDraw.Draw(img)
    d.line(stretch, fill=CYAN + (255,), width=11 * k, joint="curve")
    fx, fy = stretch[-1]
    for r, color in [(17 * k, (255, 255, 255, 255)), (11 * k, CYAN + (255,))]:
        d.ellipse([fx - r, fy - r, fx + r, fy + r], fill=color)
    return img.resize((w, h), Image.LANCZOS)


def _stroke(d, points, width):
    """A wide stroke with a flat cap and mitered join, like SVG's `stroke`, in a single polygon (the
    outline of both sides). Pillow's `line` leaves spikes on an arc of many segments, and one
    polygon per segment leaves seams."""
    pts = [np.array(q, np.float64) for q in points]
    half = width / 2

    def normal(a, b):
        v = b - a
        return np.array([-v[1], v[0]]) / np.hypot(*v)

    detours = []
    for i, q in enumerate(pts):
        if i == 0:
            detours.append(normal(q, pts[1]) * half)
        elif i == len(pts) - 1:
            detours.append(normal(pts[i - 1], q) * half)
        else:
            n1, n2 = normal(pts[i - 1], q), normal(q, pts[i + 1])
            bis = (n1 + n2) / np.hypot(*(n1 + n2))
            detours.append(bis * half / max(np.dot(bis, n1), 0.2))
    side_a = [tuple(q + v) for q, v in zip(pts, detours)]
    side_b = [tuple(q - v) for q, v in zip(pts, detours)]
    d.polygon(side_a + side_b[::-1], fill="white")


def _brand_mark(height_px):
    """The brand's "Bora?" without the round symbol, with `height_px` px from the top of the B to the tip
    of the drop. The text is Outfit Bold and the "?" is the one from `bora-brand-dark.svg` (the arc,
    the dot and the cyan drop), drawn here at the SVG's scale because there is no SVG rasterizer on
    macOS."""
    f = 8                                            # px per SVG unit, before downsizing
    img = Image.new("RGBA", (800 * f, 200 * f), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(OUTFIT), int(96 * f))
    for letter, advance in zip("Bora", (0, 641, 1217, 1661)):   # the letters' advances in the SVG
        d.text(((336.21 + advance * 0.096) * f, 135.52 * f), letter, font=font, fill="white", anchor="ls")

    def p(x, y):                                     # the SVG's "?": translate(580 99.96) scale(0.44962)
        return ((580 + x * 0.44962) * f, (99.96 + y * 0.44962) * f)

    arc = [(2 + 34 * np.cos(t), -36 - 34 * np.sin(t)) for t in np.linspace(np.pi, 0, 60)]
    _stroke(d, [p(-32, -30)] + [p(*q) for q in arc] + [p(0, -12), p(0, 10)], 26 * 0.44962 * f)
    d.polygon([p(-26, 8), p(26, 8), p(0, 41.2)], fill="white")
    cx, cy = p(0, 62)
    r = 16.1 * 0.44962 * f
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CYAN)
    img = img.crop(img.getbbox())
    return img.resize((int(img.width * height_px / img.height), height_px), Image.LANCZOS)


def _spaced_text(d, xy, text, font, color, spacing):
    x, y = xy
    for letter in text:
        d.text((x, y), letter, font=font, fill=color)
        x += d.textlength(letter, font=font) + spacing


def board(screen: Image.Image, w: int, h: int, corners: int = 0) -> Image.Image:
    """The hero: the name, the tagline and the stack (Android · BLE · Connect IQ) on the left; the
    downtown map underneath everything, stronger on the right; and the large watch showing the same
    route on its screen. The stack is a gray small-caps line, in the style of "MOTORCYCLE NAVIGATION":
    the pill labels joined by a stroke came out ugly (Igor, 2026-10-26).
    Everything as a function of `h`, to work for the hero (2400x1040) and the social preview (2560x1280)."""
    u = h / 1040
    img = Image.new("RGBA", (w, h), BLACK + (255,))

    # The map: Copan falls behind the watch. Rotated 128° (the app also rotates the map with the heading)
    # so the route, which lies east and north of Copan, reaches the watch from the left.
    rx, ry = int(w - 560 * u), int(h / 2)
    # Narrower than the hero (the social preview is 2:1), the map shrinks along, so the route's
    # loop does not touch the text.
    map_img = _map(w, h, rx - 20 * u, ry + 20 * u, 0.66 * u * min(1.0, (w / h) / (2400 / 1040)) ** 1.5,
                 angle_deg=-128)
    xs = np.linspace(0, 1, w, dtype=np.float32)
    ramp = np.clip((xs - 0.30) / 0.30, 0, 1)
    ramp = 0.22 + 0.78 * ramp * ramp * (3 - 2 * ramp)
    alpha = np.asarray(map_img.getchannel("A"), np.float32) * ramp[None, :]
    map_img.putalpha(Image.fromarray(alpha.astype(np.uint8), "L"))
    img.alpha_composite(map_img)

    watch_img = frame_watch(screen, height=H)
    k = 1.32 * u
    watch_img = watch_img.resize((int(W * k), int(H * k)), Image.LANCZOS)
    img.alpha_composite(watch_img, (int(rx - watch_img.width / 2), int(ry - watch_img.height / 2)))

    d = ImageDraw.Draw(img)
    x0, y0 = int(128 * u), int(222 * u)          # the text block, centered in height
    f_eyebrow = ImageFont.truetype(str(OUTFIT_SEMI), int(30 * u))
    _spaced_text(d, (x0, y0), "MOTORCYCLE NAVIGATION", f_eyebrow, CYAN, 5 * u)
    brand = _brand_mark(int(150 * u))
    img.alpha_composite(brand, (x0, y0 + int(68 * u)))
    f_line = ImageFont.truetype(str(OUTFIT_SEMI), int(54 * u))
    y = y0 + int(68 * u) + brand.height + int(60 * u)
    for line_text in ["Turn-by-turn directions on a", "Garmin watch, with the streets", "around you."]:
        d.text((x0, y), line_text, font=f_line, fill=(236, 240, 244))
        y += int(70 * u)

    # The stack: a short cyan thread and, below, the three words with a cyan dot between them
    y += int(46 * u)
    d.line([(x0, y), (x0 + int(96 * u), y)], fill=CYAN, width=max(2, int(3 * u)))
    y += int(34 * u)
    f_stack = ImageFont.truetype(str(OUTFIT_SEMI), int(27 * u))
    x = x0
    for i, tag in enumerate(["ANDROID", "BLE", "CONNECT IQ"]):
        if i:
            r, cx, cy = 4.5 * u, x + 20 * u, y + 15 * u
            d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CYAN)
            x += int(40 * u)
        _spaced_text(d, (x, y), tag, f_stack, (150, 160, 170), 4 * u)
        x += sum(d.textlength(c, font=f_stack) + 4 * u for c in tag)

    # The map is from OSM (ODbL): the credit goes in the image, which the social preview carries out on its own
    f_osm = ImageFont.truetype(str(OUTFIT_SEMI), int(24 * u))
    d.text((x0, h - int(64 * u)), "Map data © OpenStreetMap contributors", font=f_osm, fill=(96, 106, 116))

    if corners:
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, h - 1], radius=corners, fill=255)
        img.putalpha(mask)
    return img


def strip(screens):
    """The four screens side by side, the same size, with the short strap. Transparent background."""
    watches = [frame_watch(t, height=600) for t in screens]
    step = W - 30
    img = Image.new("RGBA", (step * 3 + W, 600), (0, 0, 0, 0))
    for i, r in enumerate(watches):
        img.alpha_composite(r, (i * step, 0))
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--social", action="store_true", help="also the 1280x640 social preview")
    args = ap.parse_args()
    screens = {name: Image.open(IMG / f"tela-{name}.png") for name in SCREENS}
    for name, screen in screens.items():
        frame_watch(screen).save(IMG / f"relogio-{name}.png", optimize=True)
        print(f"docs/img/relogio-{name}.png")
    board(screens[HERO_SCREEN], 2400, 1040, corners=36).save(IMG / "hero.png", optimize=True)
    print(f"docs/img/hero.png ({(IMG / 'hero.png').stat().st_size // 1024} KB)")
    strip([screens[n] for n in SCREENS]).save(IMG / "telas.png", optimize=True)
    print(f"docs/img/telas.png ({(IMG / 'telas.png').stat().st_size // 1024} KB)")
    if args.social:
        out_path = BRAND_DIR / "bora-social-preview.png"
        board(screens[HERO_SCREEN], 2560, 1280).resize((1280, 640), Image.LANCZOS).convert("RGB").save(
            out_path, optimize=True)
        print(f"docs/brand/bora-social-preview.png ({out_path.stat().st_size // 1024} KB)")


if __name__ == "__main__":
    main()
