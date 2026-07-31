"""Resolve an elevation for every observation location, cached by coarse grid.

Phenology runs later at altitude — the classic field rule of thumb is a few days
per hundred metres. Pooling a coastal record and a montane record of the same
species into one window is the largest known source of error in the model after
fruit persistence, so we need elevation per observation.

Looking up 39k points individually would be absurd; instead we snap to a ~1 km
grid, resolve each unique cell once, and cache the result so reruns are free.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

# ~1.1 km at this latitude. Fine enough that elevation error inside a cell is
# small relative to the phenological signal we are trying to detect.
SNAP = 0.01
BATCH = 100
# opentopodata's public instance documents 100 locations/call and 1 call/sec, so
# it is the primary. open-meteo is faster but rate-limits aggressively and
# unpredictably; it serves as a fallback. Spot-checked against each other: both
# return 12 m at the Santa Barbara waterfront and ~1520 m at the ridge.
INTERVAL = 1.1


def snap(lat: float, lng: float) -> str:
    return f"{round(lat / SNAP) * SNAP:.2f},{round(lng / SNAP) * SNAP:.2f}"


def _opentopo(points: list[str]) -> list[float]:
    q = urllib.parse.urlencode({"locations": "|".join(points)})
    with urllib.request.urlopen(f"https://api.opentopodata.org/v1/srtm30m?{q}", timeout=90) as r:
        return [x["elevation"] for x in json.load(r)["results"]]


def _openmeteo(points: list[str]) -> list[float]:
    q = urllib.parse.urlencode(
        {
            "latitude": ",".join(p.split(",")[0] for p in points),
            "longitude": ",".join(p.split(",")[1] for p in points),
        }
    )
    with urllib.request.urlopen(f"https://api.open-meteo.com/v1/elevation?{q}", timeout=90) as r:
        return json.load(r)["elevation"]


def fetch_batch(points: list[str]) -> list[float]:
    """Try each provider with a long backoff before giving up on the batch."""
    last: Exception | None = None
    for provider in (_opentopo, _openmeteo):
        for attempt in range(4):
            try:
                out = provider(points)
                if out and len(out) == len(points):
                    return out
                raise ValueError(f"expected {len(points)} elevations, got {len(out)}")
            except Exception as exc:  # noqa: BLE001 - transient service errors
                last = exc
                wait = 10 * (attempt + 1)
                print(f"\n  {provider.__name__} failed ({exc}); waiting {wait}s")
                time.sleep(wait)
    raise RuntimeError(f"all elevation providers failed: {last}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    obs_path = root / "data" / f"obs_{args.region}.jsonl"
    cache_path = root / "data" / "elevation.json"

    cache: dict[str, float] = {}
    if cache_path.exists():
        cache = json.loads(cache_path.read_text())
        print(f"cache holds {len(cache):,} points")

    wanted: set[str] = set()
    with obs_path.open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            wanted.add(snap(r["lat"], r["lng"]))

    todo = sorted(wanted - cache.keys())
    print(f"{len(wanted):,} distinct grid points, {len(todo):,} to resolve")

    for i in range(0, len(todo), BATCH):
        chunk = todo[i : i + BATCH]
        for point, elev in zip(chunk, fetch_batch(chunk)):
            cache[point] = elev
        cache_path.write_text(json.dumps(cache))
        print(f"\r  {min(i + BATCH, len(todo)):,}/{len(todo):,}", end="", flush=True)
        time.sleep(INTERVAL)

    print(f"\ndone: {len(cache):,} points cached -> {cache_path}")


if __name__ == "__main__":
    main()
