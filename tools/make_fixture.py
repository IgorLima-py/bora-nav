#!/usr/bin/env python3
"""Builds a real fixture (OSRM route + Overpass corridor) for the preview.

Why this script exists
----------------------
Every time you want to look at the map of a new stretch — "run the test starting from
street X" — you need the same sequence: geocode, request the route, build the
corridor polygon **the same way `CorridorBuilder` builds it**, query
Overpass and save the two JSONs. Done by hand this gets the polygon wrong, gets the
mirror wrong and produces a preview that does not match what the phone would send.

The route comes from FOSSGIS's OSRM (`routing.openstreetmap.de`), not Mapbox: Mapbox's terms
forbid storing and redistributing Directions responses, and the fixtures go public. OSRM speaks the
same v5 format (Directions was born from it) with OSM data under ODbL, already credited in
`NOTICE`. Only what Mapbox adds is missing: `bannerInstructions`, `instruction` and `annotation`, which
`MapboxRouteParser` can do without (no banner, a roundabout stays type 9 and an unnamed street
stays unnamed).

It reuses `preview_map.py`, which is already the mirror of the phone's pipeline:
`buffer_polygon` and `build_query` are exactly those of `CorridorBuilder.kt`.

Usage::

    python tools/make_fixture.py --from "Praça da Sé, São Paulo" \\
                                 --to "Edifício Copan, São Paulo" --name se_copan
    python tools/preview_map.py --route tools/fixtures/route_se_copan.json \\
                               --corridor tools/fixtures/corridor_se_copan.json \\
                               --zoom 1.2 --at 0.1 --budget 1800 --out out.png

`--from` and `--to` also accept `lat,lon`. The `sim.py demo` fixture came out like this::

    python tools/make_fixture.py --from=-23.498327,-46.525715 \\
                                 --to=-23.547538,-46.642686 --name tiete_copan --radars

and the protocol and stops ones (route only, no corridor)::

    python tools/make_fixture.py --from=-23.561456,-46.655826 \\
                                 --to=-23.628427,-46.657675 --name sample --no-corridor
    python tools/make_fixture.py --from=-23.561456,-46.655826 --via=-23.615945,-46.660445 \\
                                 --to=-23.628427,-46.657675 --name 2legs --no-corridor

With ``--radars`` it also writes ``overpass_radars_<name>.json``, the response to the
`RadarClient.kt` query on the same polygon: it is the `RadarFilterTest` fixture.

A name becomes a coordinate through Photon (OSM), the same geocoder as the app. FOSSGIS's OSRM
accepts one query per second and asks for a real User-Agent; the script makes just one.
"""

from __future__ import annotations

import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

# The Windows console starts in cp1252 and drops any accent in the output.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

sys.path.insert(0, str(Path(__file__).resolve().parent))

import check_overpass  # noqa: E402  (the measured mirror list lives there)
import packer  # noqa: E402
import preview_map as pm  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "tools" / "fixtures"
OSRM = "https://routing.openstreetmap.de/routed-car/route/v1/driving/"
PHOTON = "https://photon.komoot.io/api/"
#: Goes inside the fixture: ODbL asks for the credit alongside the data.
ATTRIBUTION = "Rota: OSRM (routing.openstreetmap.de). Dados © colaboradores do OpenStreetMap, ODbL."

#: São Paulo box (west, south, east, north), so the geocoder does not return a namesake street.
SP_BBOX = "-46.95,-24.05,-46.30,-23.35"


def fetch(url: str, what: str) -> dict:
    request = urllib.request.Request(url, headers={"User-Agent": check_overpass.USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        if response.status != 200:
            sys.exit(f"{what}: HTTP {response.status}")
        return json.loads(response.read().decode("utf-8"))


def geocode(query: str, near: tuple[float, float]) -> tuple[float, float, str]:
    """`(lon, lat, name)` of Photon's best result, with proximity bias.

    The candidates are printed so the error shows up right away, instead of turning into a 33 km route
    to the wrong place: with the previous geocoder, "Edifício Copan" gave Rua Copa do Mundo.
    """
    url = (
        PHOTON + "?q=" + urllib.parse.quote(query)
        + f"&lat={near[1]}&lon={near[0]}&bbox={SP_BBOX}&limit=5&lang=default"
    )
    data = fetch(url, f"geocode of {query!r}")
    features = data.get("features") or []
    if not features:
        sys.exit(f"Photon did not find {query!r} in São Paulo")
    for n, feature in enumerate(features):
        props = feature.get("properties") or {}
        label = ", ".join(str(props[k]) for k in ("name", "street", "district", "city") if props.get(k))
        mark = "→" if n == 0 else " "
        print(f"  {mark} {label}")
    lon, lat = features[0]["geometry"]["coordinates"]
    return lon, lat, (features[0].get("properties") or {}).get("name") or query


def place(query: str, near: tuple[float, float]) -> tuple[float, float, str]:
    """`(lon, lat, name)` of a name through the geocoder, or of `lat,lon` directly.

    Direct coordinates exist because Mapbox's geocoder got both ends of the `tiete_copan`
    route wrong: "Parque Ecológico do Tietê" gave the park boundary in
    Guarulhos and "Edifício Copan" gave Rua Copa do Mundo, on an 11 km route.
    """
    parts = query.split(",")
    if len(parts) == 2:
        try:
            lat, lon = float(parts[0]), float(parts[1])
        except ValueError:
            pass
        else:
            print(f"  → {lat:.6f},{lon:.6f} (given coordinate)")
            return lon, lat, query
    return geocode(query, near)


def directions(stops: list[tuple[float, float]]) -> dict:
    """The route through OSRM, in the Directions v5 format that `MapboxRouteParser` reads.

    The `hint` of each waypoint goes out (an opaque blob from the server's index, unused here) and the
    ODbL credit comes in. `stops` is `(lon, lat)` of each end and each stop in the middle.
    """
    url = (
        OSRM + ";".join(f"{lon:.6f},{lat:.6f}" for lon, lat in stops)
        + "?geometries=polyline6&overview=full&steps=true"
    )
    data = fetch(url, "OSRM")
    if data.get("code") != "Ok" or not data.get("routes"):
        sys.exit(f"OSRM has no route: {data.get('message', data.get('code'))}")
    for waypoint in data.get("waypoints") or []:
        waypoint.pop("hint", None)
    return {"attribution": ATTRIBUTION, **data}


def radar_query(polygon: list[tuple[int, int]]) -> str:
    """Mirror of `RadarClient.buildQuery`: the radars in the polygon and the roads next to them."""
    poly = " ".join(
        f"{lat * pm.E5_TO_DEGREE:.5f} {lon * pm.E5_TO_DEGREE:.5f}" for lat, lon in polygon
    )
    return (
        f"[out:json][timeout:{pm.OVERPASS_TIMEOUT_S}];\n"
        f'node[highway=speed_camera](poly:"{poly}")->.cams;\n'
        ".cams out;\n"
        "way(bn.cams)[highway];\n"
        "out geom;\n"
    )


def overpass(points: list[tuple[int, int]], radars: bool = False) -> dict:
    """Same query as `CorridorBuilder` (or `RadarClient`), on the first mirror that returns something.

    **Empty is a mirror failure, not a result** — a regional mirror
    answering `200` with zero ways is what made the corridor vanish for several
    rounds (`DECISIONS.md` §The mirror I chose). The same holds for radars:
    in São Paulo, a route polygon with no radar at all is an empty mirror.
    """
    plane = pm.LocalPlane(points[0][0], points[0][1])
    polygon = pm.buffer_polygon(points, plane)
    query = radar_query(polygon) if radars else pm.build_query(polygon)

    for endpoint in check_overpass.ENDPOINTS:
        try:
            request = urllib.request.Request(
                endpoint,
                data=query.encode("utf-8"),
                headers={"User-Agent": check_overpass.USER_AGENT, "Content-Type": "text/plain"},
            )
            with urllib.request.urlopen(request, timeout=120) as response:
                raw = json.loads(response.read().decode("utf-8"))
        except Exception as error:  # noqa: BLE001 — any failure is "try the next one"
            print(f"  {endpoint}: {type(error).__name__} {error}")
            continue

        ways = [e for e in raw.get("elements", []) if e.get("type") == "way"]
        cams = [e for e in raw.get("elements", []) if e.get("type") == "node"]
        print(f"  {endpoint}: {len(cams)} radars, {len(ways)} ways" if radars else f"  {endpoint}: {len(ways)} ways")
        if cams if radars else ways:
            return raw
    sys.exit("no Overpass mirror returned ways — run tools/check_overpass.py")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="origin", required=True)
    parser.add_argument("--via", action="append", default=[],
                        help="stop in the middle (repeat for more than one): adds one more leg")
    parser.add_argument("--to", dest="destination", required=True)
    parser.add_argument("--name", required=True, help="suffix of the generated files")
    parser.add_argument(
        "--near",
        default="-46.65,-23.60",
        help="lon,lat of the geocoder proximity bias (default: São Paulo)",
    )
    parser.add_argument("--radars", "--radares", dest="radars", action="store_true",
                        help="also writes overpass_radars_<name>.json (RadarClient query)")
    parser.add_argument("--no-corridor", "--sem-corredor", dest="no_corridor", action="store_true",
                        help="route only: the protocol fixtures do not use an Overpass corridor")
    args = parser.parse_args()

    parts = args.near.split(",")
    near = (float(parts[0]), float(parts[1]))

    print("origin:")
    stops = [place(args.origin, near)[:2]]
    for via in args.via:
        print("stop:")
        stops.append(place(via, near)[:2])
    print("destination:")
    stops.append(place(args.destination, near)[:2])

    route = directions(stops)
    leg = route["routes"][0]
    print(f"route  : {leg['distance'] / 1000:.1f} km · {leg['duration'] / 60:.0f} min")

    FIXTURES.mkdir(parents=True, exist_ok=True)
    route_path = FIXTURES / f"route_{args.name}.json"
    route_path.write_text(json.dumps(route, ensure_ascii=False), encoding="utf-8")
    if args.no_corridor:
        print(f"\n{route_path}")
        return 0

    points = packer.route_from_mapbox(route).points
    print("querying Overpass:")
    raw = overpass(points)
    corridor_path = FIXTURES / f"corridor_{args.name}.json"
    corridor_path.write_text(json.dumps(raw), encoding="utf-8")
    written = [route_path, corridor_path]

    if args.radars:
        print("querying Overpass (radars):")
        radars_path = FIXTURES / f"overpass_radars_{args.name}.json"
        radars_path.write_text(json.dumps(overpass(points, radars=True)), encoding="utf-8")
        written.append(radars_path)

    print("\n" + "\n".join(str(path) for path in written))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
