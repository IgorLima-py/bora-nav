#!/usr/bin/env python3
"""TTF (including variable-axis) -> BMFont bitmap font (.fnt text + .png) for Connect IQ.

Connect IQ does not embed the app's vector fonts: the resource compiler only reads BMFont
(SDK 9.2.0, doc/docs/Core_Topics/Resources.html: "The resource compiler reads fonts in TXT or PNG
format"; see docs/UI-REFERENCIAS.md §Tipografia). AngelCode's BMFont is a third-party .exe;
this script does the same with Pillow, only with the requested glyphs, so the cost is the real one.

Usage:
    python tools/fonte_bmfont.py --ttf Nunito-wght.ttf --weight 900 --px 56 \
        --glyphs num --name nunito_num_56 --out folder/

    --glyphs: 'num' (digits and what distances and the time use), 'text' (pt-BR alphabet),
    or the literal list of characters.
Outputs: <out>/<name>.fnt and <out>/<name>_0.png. The PNG is white, coverage in alpha (chnl=15).
"""

from __future__ import annotations

import argparse
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

#: Digits, separators and the letters of distances and time ("AGORA", "m", "km", "h", "min").
GLYPHS_NUM = "0123456789,.:· AGORAmkhin"
#: What a São Paulo street name or a destination writes (C15a: pt-BR alphabet with accents).
GLYPHS_TEXT = (" !\"'(),-./0123456789:;?ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                "ÀÁÂÃÇÉÊÍÓÔÕÚÜàáâãçéêíóôõúü·ºª°")
PADDING = 1     # px of margin around each glyph in the atlas (antialiasing never touches the neighbor)
ATLAS_WIDTH = 512


def glyph_set(arg: str) -> str:
    chars = {"num": GLYPHS_NUM, "text": GLYPHS_TEXT}.get(arg, arg)
    return "".join(sorted(set(chars), key=ord))


def load_font(ttf: pathlib.Path, px: int, weight: int | None) -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(str(ttf), px)
    if weight is not None:
        try:
            font.set_variation_by_axes([weight])
        except OSError as e:   # static font: the weight comes from the file
            sys.exit(f"{ttf.name}: no weight axis ({e})")
    return font


def generate(ttf: pathlib.Path, px: int, weight: int | None, chars: str, name: str, out: pathlib.Path) -> dict:
    font = load_font(ttf, px, weight)
    ascent, descent = font.getmetrics()
    line_h = ascent + descent
    boxes = []
    for ch in chars:
        x0, y0, x1, y1 = font.getbbox(ch, anchor="ls")   # relative to the baseline
        adv = round(font.getlength(ch))
        boxes.append((ch, x0, y0, x1, y1, adv))

    # Pack into rows (shelves) of ATLAS_WIDTH.
    x = y = shelf_h = 0
    pos = []
    for ch, x0, y0, x1, y1, adv in boxes:
        w, h = max(0, x1 - x0), max(0, y1 - y0)
        if x + w + 2 * PADDING > ATLAS_WIDTH:
            x, y, shelf_h = 0, y + shelf_h, 0
        pos.append((x + PADDING, y + PADDING))
        x += w + 2 * PADDING
        shelf_h = max(shelf_h, h + 2 * PADDING)
    height_px = y + shelf_h
    tall = 1
    while tall < height_px:
        tall *= 2

    atlas = Image.new("RGBA", (ATLAS_WIDTH, tall), (255, 255, 255, 0))
    lines = []
    pixels = 0
    for (ch, x0, y0, x1, y1, adv), (ax, ay) in zip(boxes, pos):
        w, h = max(0, x1 - x0), max(0, y1 - y0)
        pixels += w * h
        if w and h:
            mask = Image.new("L", (w, h), 0)
            ImageDraw.Draw(mask).text((-x0, -y0), ch, font=font, fill=255, anchor="ls")
            white = Image.new("RGBA", (w, h), (255, 255, 255, 0))
            white.putalpha(mask)
            atlas.paste(white, (ax, ay))
        # BMFont: yoffset is from the top of the line (ascent above the base) to the top of the glyph.
        lines.append(f"char id={ord(ch):<5} x={ax:<5} y={ay:<5} width={w:<5} height={h:<5} "
                      f"xoffset={x0:<5} yoffset={ascent + y0:<5} xadvance={adv:<5} page=0  chnl=15")

    out.mkdir(parents=True, exist_ok=True)
    png = f"{name}_0.png"
    atlas.save(out / png, optimize=True)
    header = [
        f'info face="{font.getname()[0]}" size={px} bold=0 italic=0 charset="" unicode=1 stretchH=100 '
        f'smooth=1 aa=1 padding=0,0,0,0 spacing={PADDING},{PADDING} outline=0',
        f"common lineHeight={line_h} base={ascent} scaleW={ATLAS_WIDTH} scaleH={tall} pages=1 packed=0 "
        f"alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4",
        f'page id=0 file="{png}"',
        f"chars count={len(boxes)}",
    ]
    (out / f"{name}.fnt").write_text("\n".join(header + lines + ["kernings count=0", ""]), encoding="utf-8")
    return {"name": name, "px": px, "glyphs": len(boxes), "atlas": (ATLAS_WIDTH, tall),
            "glyph_pixels": pixels, "png_bytes": (out / png).stat().st_size}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ttf", type=pathlib.Path, required=True)
    ap.add_argument("--weight", dest="weight", type=int, help="value of the wght axis (variable font)")
    ap.add_argument("--px", type=int, required=True)
    ap.add_argument("--glyphs", dest="glyphs", default="num")
    ap.add_argument("--name", dest="name", required=True)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    a = ap.parse_args()
    info = generate(a.ttf, a.px, a.weight, glyph_set(a.glyphs), a.name, a.out)
    print(f"{info['name']}: {info['glyphs']} glyphs, atlas {info['atlas'][0]}x{info['atlas'][1]}, "
          f"{info['glyph_pixels']} glyph px, png {info['png_bytes']} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
