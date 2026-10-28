"""The README GIF: the virtual ride in the Mac simulator, only the downtown SP stretch.

Runs ``sim.py ride --fixture spmarket_copan``, starts shooting the simulator window at the
warning for turn 10 (Av. Senador Queirós, ~130 m after the start of Av. Prestes Maia) and stops
right after ``[ride] fim`` (arrival at Copan). Nothing of the route before downtown is included:
its start does not go into a public photo.

    python3 tools/gif_simulador.py --en                 # docs/img/demo.gif, as in the README
    python3 tools/gif_simulador.py --gif-only shots/gif   # (alias --so-gif) rebuilds the GIF from the shots already there

``--en`` runs the ride through ``tools/telas_en.py``, the same English build as the README screens.
At real speed the whole ride takes ~29 min, and the shots cover only the final ~2.5 min (26/10).

Mac only, with the screen unlocked: with the screen locked ``screencapture`` answers "could not
create image from window" (measured on 2026-10-26). ``screencapture -v`` (video) does not work: with
``-l`` or ``-R`` it hung without recording anything, and Homebrew's ffmpeg does not list the screen as
an avfoundation device. So it takes consecutive shots of the window, with the instant of each one, and
the GIF comes out of them via ffmpeg (``palettegen``/``paletteuse``).
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sim import DEVICE, MAC_WINDOW_SWIFT, ROOT, SHOTS  # noqa: E402

FIXTURE = "spmarket_copan"
START_LINES = ("vibe turn 10 alert 1", "vibra curva 10 aviso 1")   # Senador Queirós approaching: already downtown (English / old Portuguese log)
END_LINES = ("[ride] end", "[ride] fim")
AFTER_END_S = 2.5                   # the arrival screen, before the app closes (3 s)
OUT_PATH = ROOT / "docs" / "img" / "demo.gif"
# 360 px at 8 frames/s fit the 2 to 3 MB target (at 400 px and 12/s, the 26/10 ride gave 4.74 MB)
SIDE = 360                              # GIF px (the LANCAMENTO target: 320 to 454)
FPS = 8
DURATION_S = 10.0                        # the whole stretch is compressed into this
HOLD_END_S = 1.5                      # the last screen holds still before restarting


def window() -> str:
    found = subprocess.run(["swift", "-"], input=MAC_WINDOW_SWIFT, capture_output=True, text=True, timeout=60)
    number = found.stdout.strip()
    if not number.isdigit():
        raise SystemExit("FAILED: the simulator window did not show up (is it open?)")
    return number


def shoot(number: str, folder: Path, stop: threading.Event, moments: list) -> None:
    """Consecutive shots of the window, as fast as screencapture can go."""
    i = 0
    while not stop.is_set():
        file = folder / f"bruto_{i:05d}.png"
        t = time.monotonic()
        subprocess.run(["screencapture", "-x", "-o", "-l", number, str(file)], timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if file.exists():
            moments.append((file.name, t))
            i += 1


def capture(folder: Path, speed_x: float, english: bool = False) -> None:
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("bruto_*.png"):
        old.unlink()
    number = None
    stop = threading.Event()
    moments: list = []
    thread = None
    end_at = None
    script = ROOT / "tools" / ("telas_en.py" if english else "sim.py")
    # -u: the warning line has to arrive on time, not when the pipe buffer fills
    cmd = [sys.executable, "-u", str(script), "ride", "--fixture", FIXTURE, "--speed", str(speed_x)]
    print("running:", " ".join(cmd[2:]))
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in proc.stdout:
        print(line, end="")
        if thread is None and any(m in line for m in START_LINES):
            number = number or window()
            thread = threading.Thread(target=shoot, args=(number, folder, stop, moments), daemon=True)
            thread.start()
            print(">> shooting")
        if thread is not None and any(m in line for m in END_LINES) and end_at is None:
            end_at = time.monotonic()
            threading.Timer(AFTER_END_S, stop.set).start()
    proc.wait()
    stop.set()
    if thread is not None:
        thread.join()
    if not moments:
        raise SystemExit(f"FAILED: no shot (did the line «{START_LINES[0]}» show up? is the screen unlocked?)")
    (folder / "instantes.json").write_text(json.dumps(moments), encoding="utf-8")
    print(f"{len(moments)} shots in {moments[-1][1] - moments[0][1]:.1f} s")


def crop(raw: Path):
    """The watch glass in the window shot: the same calculation as ``sim.take_shot_mac``."""
    from PIL import Image, ImageDraw

    device = Path.home() / "Library/Application Support/Garmin/ConnectIQ/Devices" / DEVICE
    simulator = json.loads((device / "simulator.json").read_text(encoding="utf-8"))
    spec = simulator["display"]["location"]
    with Image.open(device / simulator.get("image", "device.png")) as face:
        face_w, face_h = face.size
    with Image.open(raw) as image:
        scale = image.width / face_w
        top = (image.height - face_h * scale) / 2
        box = (round(spec["x"] * scale), round(top + spec["y"] * scale),
               round((spec["x"] + spec["width"]) * scale), round(top + (spec["y"] + spec["height"]) * scale))
        glass = image.convert("RGB").crop(box).resize((SIDE, SIDE), Image.LANCZOS)
    mask = Image.new("L", (SIDE * 4, SIDE * 4), 0)
    ImageDraw.Draw(mask).ellipse((0, 0, SIDE * 4 - 1, SIDE * 4 - 1), fill=255)
    glass.putalpha(mask.resize((SIDE, SIDE), Image.LANCZOS))
    return glass


def build_gif(folder: Path, out: Path) -> None:
    """Resamples the shots at a fixed rate (the stretch fits in DURATION_S) and makes the GIF with its own palette."""
    moments = json.loads((folder / "instantes.json").read_text(encoding="utf-8"))
    t0, t1 = moments[0][1], moments[-1][1]
    frames = folder / "quadros"
    shutil.rmtree(frames, ignore_errors=True)
    frames.mkdir()
    n = int(DURATION_S * FPS)
    j = 0
    cache: dict[str, object] = {}
    for k in range(n):
        target = t0 + (t1 - t0) * k / (n - 1)
        while j + 1 < len(moments) and abs(moments[j + 1][1] - target) <= abs(moments[j][1] - target):
            j += 1
        name = moments[j][0]
        if name not in cache:
            cache = {name: crop(folder / name)}
        cache[name].save(frames / f"q_{k:04d}.png")
    last = frames / f"q_{n - 1:04d}.png"
    for k in range(n, n + int(HOLD_END_S * FPS)):
        shutil.copy(last, frames / f"q_{k:04d}.png")
    palette = folder / "paleta.png"
    inputs = ["-framerate", str(FPS), "-i", str(frames / "q_%04d.png")]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs,
                    "-vf", "palettegen=stats_mode=diff:reserve_transparent=1", str(palette)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-i", str(palette),
                    "-lavfi", "paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle:alpha_threshold=128",
                    "-loop", "0", str(out)], check=True)
    name = out.resolve()
    name = name.relative_to(ROOT) if name.is_relative_to(ROOT) else name
    print(f"{name}: {out.stat().st_size / 1e6:.2f} MB, {n} frames + "
          f"{HOLD_END_S} s held, {(t1 - t0) / DURATION_S:.1f}x the capture")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    # At 4x the streets do not keep up: on 26/10, a good part of the frames came out with only the route. At 1x, all
    # the frames had the streets, and the capture runs at ~4 shots/s instead of ~1.
    ap.add_argument("--speed", type=float, default=1.0, help="the ride speed (default 1, the real one)")
    ap.add_argument("--folder", "--pasta", dest="folder", type=Path, default=SHOTS / "gif", help="where the shots go (outside git)")
    ap.add_argument("--gif-only", "--so-gif", dest="gif_only", type=Path, metavar="FOLDER", help="does not run the ride: rebuilds the GIF from the shots in FOLDER")
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    ap.add_argument("--en", action="store_true", help="in the English build of tools/telas_en.py")
    args = ap.parse_args()
    if sys.platform != "darwin":
        print("FAILED: Mac only (the capture uses screencapture)")
        return 1
    folder = args.gif_only or args.folder
    if args.gif_only is None:
        capture(folder, args.speed, args.en)
    build_gif(folder, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
