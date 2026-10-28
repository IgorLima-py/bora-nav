"""The showcase screens in English, without touching `watch/`: a preview until the app has real English.

The watch only speaks Portuguese, and the screen texts are literals in the code (`Hud.mc`,
`WeatherInfo.mc`, `Fmt.mc`, `NavEngine.mc`; docs/LANCAMENTO.md §The app in English). Real English
is a session in `watch/`, which C16.6 is touching. Until then, this copies `watch/`
to a temporary folder, swaps there only the texts the showcase screens can show, builds the
copy and runs the same `sim.py shots --showcase`. The photos come out as `shots/tela_<cena>_en.png`.

    python3 tools/telas_en.py                                          # the showcase photos
    python3 tools/telas_en.py ride --fixture spmarket_copan --speed 1  # the lap, for the GIF

The lap is `sim.py ride`'s, with the same output; `tools/gif_simulador.py --en` runs through here.
Street names stay as they are (they are proper nouns). When the app gets real English, this
file goes away and the screens go back to coming straight from `sim.py shots --showcase`.
"""
from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sim  # noqa: E402

# watch/ file → [(Portuguese snippet, English)]; each snippet must exist.
TRANSLATIONS = {
    "source/nav/WeatherInfo.mc": [
        ('return "sol";', 'return "sunny";'),
        ('return "nublado";', 'return "cloudy";'),
        ('return "temporal";', 'return "storm";'),
        ('return "chuva";', 'return "rain";'),
        ('return "neve";', 'return "snow";'),
        ('return "névoa";', 'return "fog";'),
        ('return "vento";', 'return "wind";'),
    ],
    "source/render/Hud.mc": [
        ('"Cadê o celular?"', '"Where is the phone?"'),
        ('"Recalculando…"', '"Rerouting…"'),
        ('mainText = "Você chegou";', 'mainText = "You have arrived";'),
        ('var label = "e depois";', 'var label = "then";'),
        ('main = "sem GPS";', 'main = "no GPS";'),
        ('main = "chegou às " + _arrivedAt;', 'main = "arrived at " + _arrivedAt;'),
        ('main = "fora da rota";', 'main = "off route";'),
        ('return "sem rota";', 'return "no route";'),
        ('return "esperando GPS";', 'return "waiting for GPS";'),
        ('return "procurando a rota";', 'return "finding the route";'),
        ('return "siga em frente";', 'return "continue straight";'),
    ],
    "source/Fmt.mc": [
        ('(tenths / 10).toString() + "," + (tenths % 10).toString()',
         '(tenths / 10).toString() + "." + (tenths % 10).toString()'),
    ],
    "source/nav/NavEngine.mc": [
        ('return "AGORA";', 'return "NOW";'),
    ],
}


def prepare(tmp: Path) -> bool:
    """Copies `watch/` to `tmp`, translates the copy and points `sim` at it."""
    watch = tmp / "watch"
    shutil.copytree(sim.ROOT / "watch", watch, ignore=shutil.ignore_patterns("bin"))
    for rel, swaps in TRANSLATIONS.items():
        file = watch / rel
        text = file.read_text(encoding="utf-8")
        for pt, en in swaps:
            if pt not in text:
                print(f"FAILED: «{pt}» is no longer in watch/{rel}; update TRANSLATIONS")
                return False
            text = text.replace(pt, en)
        file.write_text(text, encoding="utf-8")
    # cmd_shots and cmd_ride read these module paths at call time: pointing them at the copy is enough.
    sim.JUNGLE = watch / "monkey.jungle"
    sim.SHOTS_JUNGLE = watch / "shots.jungle"
    sim.RIDE_JUNGLE = watch / "ride.jungle"
    sim.RIDE_CANARY_JUNGLE = watch / "ride_canary.jungle"
    sim.BIN = watch / "bin"
    sim.SHOT_PARAMS = watch / "bin" / "shots" / "ShotParams.mc"
    expected = sim.ride_paths
    sim.ride_paths = lambda fixture: (expected(fixture)[0], watch / "bin" / "ride" / "RideParams.mc")
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd")
    ride = sub.add_parser("ride", help="the lap from sim.py ride, in the English build")
    ride.add_argument("--fixture", required=True)
    ride.add_argument("--speed", type=float, default=4.0)
    args = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix="motonav-en-") as tmp:
        if not prepare(Path(tmp)):
            return 1
        if args.cmd == "ride":
            return sim.cmd_ride(args.fixture, args.speed, canary=False)
        return sim.cmd_shots(tag="en", showcase=True)


if __name__ == "__main__":
    sys.exit(main())
