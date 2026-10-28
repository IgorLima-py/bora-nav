#!/usr/bin/env python3
"""Measures the Overpass mirrors — and measures the right thing.

Why this script exists
--------------------------
In a debugging round `overpass.osm.ch` was promoted to main mirror
because it answered **HTTP 200 in 0.7 s**, against 8.9 s for `overpass-api.de`. What
nobody looked at was the *content*: `osm.ch` only carries data for Switzerland and returned
**zero ways** in São Paulo. Since the request is hedged and the winner was the
first to answer, it won with an empty list and cancelled the mirror that
would have worked. Result: a map with no streets, and **no error anywhere**.

The lesson became this script: latency and HTTP code say nothing on their own.
**The number that matters is how many ways came back.**

Usage::

    python tools/check_overpass.py                 # default block in São Paulo
    python tools/check_overpass.py --lat -23.56 --lon -46.66
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

#: The same as `OverpassClient.DEFAULT_ENDPOINTS`, plus the candidates already
#: rejected — rejected today may pass tomorrow, and vice versa.
ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.osm.jp/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]

#: The same agent as the app: public Overpass returns 406 for the libraries'
#: default, and measuring with another agent would measure something else.
USER_AGENT = "BoraNav/1.0 (+https://github.com/IgorLima-py/bora-nav)"

TIMEOUT_S = 45


def query(lat: float, lon: float) -> str:
    """One block around the point — cheap for the server, enough to
    prove it has the region's data."""
    return (
        "[out:json][timeout:18];\n"
        f"way[highway]({lat - 0.001:.5f},{lon - 0.002:.5f},{lat + 0.001:.5f},{lon + 0.002:.5f});\n"
        "out geom;\n"
    )


def probe(endpoint: str, body: str) -> tuple[str, float, int | None]:
    data = urllib.parse.urlencode({"data": body}).encode()
    request = urllib.request.Request(endpoint, data=data, headers={"User-Agent": USER_AGENT})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
            payload = response.read().decode("utf-8", "replace")
            elapsed = time.monotonic() - started
            try:
                return str(response.status), elapsed, len(json.loads(payload).get("elements", []))
            except json.JSONDecodeError:
                return f"{response.status} (unreadable body)", elapsed, None
    except urllib.error.HTTPError as error:
        return f"HTTP {error.code}", time.monotonic() - started, None
    except Exception as error:  # timeout, DNS, TLS…
        return type(error).__name__, time.monotonic() - started, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lat", type=float, default=-23.5610, help="probe latitude")
    parser.add_argument("--lon", type=float, default=-46.6580, help="probe longitude")
    args = parser.parse_args()

    body = query(args.lat, args.lon)
    print(f"probing {args.lat:.4f}, {args.lon:.4f} — what matters is the 'ways' column\n")
    print(f"{'mirror':<56} {'status':>16} {'time':>8} {'ways':>6}")
    print("-" * 90)

    usable = []
    for endpoint in ENDPOINTS:
        status, elapsed, ways = probe(endpoint, body)
        mark = ""
        if ways is None:
            mark = "  <- failed"
        elif ways == 0:
            mark = "  <- ANSWERED EMPTY: no data for this region"
        else:
            usable.append((elapsed, endpoint))
        shown = "-" if ways is None else str(ways)
        print(f"{endpoint:<56} {status:>16} {elapsed:>7.1f}s {shown:>6}{mark}")

    print()
    if not usable:
        print("NO mirror works right now. The corridor will fail — try again later.")
        return 1

    usable.sort()
    print("Suggested order for OverpassClient.DEFAULT_ENDPOINTS (fastest with data first):")
    for elapsed, endpoint in usable:
        print(f"  {endpoint}   ({elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
