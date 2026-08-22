"""Emit per-tile observation points for the web client.

The iOS app reads individual fruiting coordinates from its bundled SQLite `obs`
table. The web client has no such bundle, and folding 1.26M points into the
phenology tiles would roughly double a payload that is fetched on every move.

So the points ship as sidecar files on the same 2 degree tile grid, fetched only
when a species detail is opened and cached thereafter. Coordinates are rounded
to four decimals (~11 m, far finer than anything you would navigate by) and the
day of year is kept so the client can offer the same "this time of year" filter
the iOS map has.
"""

from __future__ import annotations
import argparse, json, math
from collections import defaultdict
from datetime import datetime
from pathlib import Path

TILE_DEG = 2.0


def doy(iso: str) -> int:
    return datetime.strptime(iso, "%Y-%m-%d").date().timetuple().tm_yday


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    src = root / "data" / f"obs_{args.region}.jsonl"
    out = root / "web" / f"obs_{args.region}"
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("*.json"):
        f.unlink()

    tiles: dict[tuple[int, int], dict[int, list]] = defaultdict(lambda: defaultdict(list))
    seen: set[tuple] = set()
    n = kept = 0
    with src.open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            n += 1
            if "fruits" not in r["phenology"]:
                continue
            lat, lng = round(r["lat"], 4), round(r["lng"], 4)
            tid = r["taxon_id"]
            # Duplicate coordinates for one species carry no extra information
            # about where to walk, and observers do cluster on the same plant.
            key = (tid, lat, lng)
            if key in seen:
                continue
            seen.add(key)
            kept += 1
            tiles[(math.floor(lat / TILE_DEG), math.floor(lng / TILE_DEG))][tid].append(
                [lat, lng, doy(r["observed_on"])]
            )
            if n % 1_000_000 == 0:
                print(f"\r  read {n:,}", end="", flush=True)

    print(f"\r  read {n:,} observations, kept {kept:,} distinct fruiting points")
    total = 0
    for (tr, tc), by_taxon in sorted(tiles.items()):
        path = out / f"{tr}_{tc}.json"
        path.write_text(json.dumps({str(k): v for k, v in by_taxon.items()},
                                   separators=(",", ":")))
        total += path.stat().st_size
    biggest = max(out.glob("*.json"), key=lambda p: p.stat().st_size)
    print(f"{len(tiles)} tiles -> {out.name}/ ({total/1e6:.1f} MB total, "
          f"largest {biggest.name} at {biggest.stat().st_size/1e6:.2f} MB)")


if __name__ == "__main__":
    main()
