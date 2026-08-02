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

# Default snap, overridable with --snap. Elevation feeds only a 10th-90th
# percentile presence band, so a coarser grid costs almost nothing and saves a
# great deal of time at national scale: CONUS needs 124,687 lookups at 0.01
# degrees but only 53,674 at 0.05.
SNAP = 0.01
BATCH = 100
# opentopodata's public instance documents 100 locations/call and 1 call/sec, so
# it is the primary. open-meteo is faster but rate-limits aggressively and
# unpredictably; it serves as a fallback. Spot-checked against each other: both
# return 12 m at the Santa Barbara waterfront and ~1520 m at the ridge.
INTERVAL = 1.1


def snap(lat: float, lng: float, step: float = SNAP) -> str:
    # Decimals must track the step or coarse grids collide into one key.
    dp = max(2, len(str(step).split(".")[-1]))
    return f"{round(lat / step) * step:.{dp}f},{round(lng / step) * step:.{dp}f}"


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
    ap.add_argument("--snap", type=float, default=SNAP,
                    help="grid size in degrees (default 0.01; 0.05 suits national builds)")
    ap.add_argument("--merge", action="append", default=[],
                    help="also cover another region's observations (repeatable), so a "
                         "merged tile build finds every point on one grid")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    obs_paths = [root / "data" / f"obs_{r}.jsonl" for r in [args.region, *args.merge]]
    cache_path = root / "data" / f"elevation_{args.region}.json"

    # The snap travels with the cache so consumers cannot silently key against a
    # different grid than the one the points were resolved on.
    cache: dict[str, float] = {}
    legacy = root / "data" / "elevation.json"
    if cache_path.exists():
        blob = json.loads(cache_path.read_text())
        if blob.get("snap") != args.snap:
            print(f"cache was built at snap {blob.get('snap')}, rebuilding at {args.snap}")
        else:
            cache = blob["points"]
            print(f"cache holds {len(cache):,} points")
    elif args.snap == 0.01 and legacy.exists():
        cache = json.loads(legacy.read_text())
        print(f"seeded {len(cache):,} points from shared elevation.json")

    wanted: set[str] = set()
    for obs_path in obs_paths:
        with obs_path.open() as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Only fruiting records feed the elevation band, so resolving
                # flower-only locations would double the work for nothing.
                if "fruits" in r.get("phenology", ()):
                    wanted.add(snap(r["lat"], r["lng"], args.snap))

    todo = sorted(wanted - cache.keys())
    print(f"{len(wanted):,} distinct grid points, {len(todo):,} to resolve")

    for i in range(0, len(todo), BATCH):
        chunk = todo[i : i + BATCH]
        for point, elev in zip(chunk, fetch_batch(chunk)):
            cache[point] = elev
        cache_path.write_text(json.dumps({"snap": args.snap, "points": cache}))
        print(f"\r  {min(i + BATCH, len(todo)):,}/{len(todo):,}", end="", flush=True)
        time.sleep(INTERVAL)

    cache_path.write_text(json.dumps({"snap": args.snap, "points": cache}))
    print(f"\ndone: {len(cache):,} points at snap {args.snap} -> {cache_path}")


if __name__ == "__main__":
    main()
