"""Fit seed-collection windows per species *per sub-region*, and emit spatial tiles.

Two problems with fitting one window per species across a whole region:

1. It blurs populations separated by a climate gradient. Splitting coastal
   Southern California at Los Angeles, half of well-sampled species disagree by
   more than two weeks between north and south and a fifth by more than a month.
   Larrea tridentata peaks in June in the Mojave and November in the southern
   deserts; a pooled fit reports neither.
2. At national scale a single payload would be tens of megabytes.

Both are solved by cutting space into tiles and fitting inside each one. The
catch is sample size: a tile that is small enough to be climatically coherent is
often too small to fit a season. So each (species, tile) takes the *finest* fit
it has the data for:

    cell    the tile itself          - most specific
    block   3x3 tiles around it
    area    5x5 tiles around it
    wide    7x7 tiles around it       - last resort

The search expands outward but is always bounded. An earlier version fell back
to "everything in the dataset", which is reasonable inside one coastal region
and meaningless across a continent: at national scale 45% of fits landed there,
pooling Florida with Maine. A species that cannot be fitted within seven tiles
is now omitted rather than answered badly.

The level used is recorded per species so the client can say how local the
answer actually is.

Tiles are self-contained: a client loads the one or two covering its search
radius and needs nothing else. Metadata is duplicated across tiles, which costs
disk on the server and saves a round trip on a phone.
"""

from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from datetime import date
from pathlib import Path

import numpy as np

from build_model import (
    CELL_DEG,
    FRUIT_QUANTILES,
    MIN_FLOWER_OBS,
    MIN_FRUIT_OBS,
    RIPE_QUANTILES,
    cell_key,
    doy,
    elev_key,
    elevation_band,
    fit_taxon,
    load_elevation,
)

# Tile size in degrees. Small enough that phenology inside one is reasonably
# coherent, large enough that common species clear the sample-size bar without
# falling back. At mid-latitudes 2 degrees is roughly 220 km north-south.
TILE_DEG = 2.0

# A local fit has to be better-supported than a pooled one to be worth
# preferring, otherwise we trade pooling bias for sampling noise.
LOCAL_MIN_FRUIT = 15
LOCAL_MIN_FLOWER = 10

# Expanding search radii in tiles, with the label and confidence multiplier for
# each. Bounded deliberately: beyond ~7 tiles a "local" window stops meaning
# anything. The last radius is the widest pooling this model will ever do.
FIT_LEVELS = [(0, "cell", 1.0), (1, "block", 0.75), (2, "area", 0.6), (3, "wide", 0.45)]


def tile_key(lat: float, lng: float) -> tuple[int, int]:
    return (math.floor(lat / TILE_DEG), math.floor(lng / TILE_DEG))


class Bucket:
    """Observations for one (taxon, tile) pair."""

    __slots__ = ("fruit", "flower", "elevs", "cells")

    def __init__(self):
        self.fruit: list[int] = []
        self.flower: list[int] = []
        self.elevs: list[float] = []
        self.cells: defaultdict[str, int] = defaultdict(int)

    def merge(self, other: "Bucket") -> None:
        self.fruit += other.fruit
        self.flower += other.flower
        self.elevs += other.elevs
        for k, v in other.cells.items():
            self.cells[k] += v


def load(rows_paths: list[Path], elev_cache: dict[str, float], elev_snap: float):
    """Bucket every observation by (taxon, tile), keeping only what the fit needs.

    Several sources can be combined: a national pull truncated by upload date
    plus a deeper regional one covering the same ground. Observation ids are
    globally unique, so the union is deduped on the way in and each record is
    counted once regardless of how many files contain it.
    """
    buckets: dict[tuple[int, tuple[int, int]], Bucket] = {}
    meta: dict[int, dict] = {}
    seen_ids: set[int] = set()
    n = dupes = 0
    for rows_path in rows_paths:
      with rows_path.open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            oid = r.get("id")
            if oid is not None:
                if oid in seen_ids:
                    dupes += 1
                    continue
                seen_ids.add(oid)
            n += 1
            tid = r["taxon_id"]
            meta.setdefault(tid, {
                "taxon_id": tid, "name": r["name"],
                "common": r["common"], "rank": r["rank"],
            })
            key = (tid, tile_key(r["lat"], r["lng"]))
            b = buckets.get(key)
            if b is None:
                b = buckets[key] = Bucket()
            d = doy(r["observed_on"])
            if "fruits" in r["phenology"]:
                b.fruit.append(d)
                b.cells[cell_key(r["lat"], r["lng"])] += 1
                e = elev_cache.get(elev_key(r["lat"], r["lng"], elev_snap))
                if e is not None:
                    b.elevs.append(e)
            if "flowers" in r["phenology"]:
                b.flower.append(d)
            if n % 500_000 == 0:
                print(f"\r  read {n:,}", end="", flush=True)
    print(f"\r  read {n:,} unique observations "
          f"({dupes:,} duplicates skipped) -> {len(buckets):,} (taxon, tile) pairs")
    return buckets, meta


def neighbourhood(buckets, tid: int, tile: tuple[int, int], radius: int) -> Bucket:
    """All tiles within `radius` tiles of this one, pooled."""
    out = Bucket()
    r0, c0 = tile
    for dr in range(-radius, radius + 1):
        for dc in range(-radius, radius + 1):
            b = buckets.get((tid, (r0 + dr, c0 + dc)))
            if b:
                out.merge(b)
    return out


def build(rows_paths: list[Path], out_dir: Path, region: str) -> dict:
    data_dir = rows_paths[0].parent
    elev_snap, elev_cache = load_elevation(data_dir, region)
    if not elev_cache:
        print("no elevation cache; elevation filtering will be unavailable")
    print(f"sources: {', '.join(p.name for p in rows_paths)}")

    buckets, meta = load(rows_paths, elev_cache, elev_snap)

    # Family, conservation status, handling notes and photos, written once per
    # species by enrich_taxa.py and merged into every tile the species appears
    # in. Duplicated on disk so a tile is self-contained on the client.
    meta_path = out_dir.parent / f"taxa_meta_{region}.json"
    extra = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    if extra:
        print(f"  merging enrichment for {len(extra):,} taxa")
    else:
        print("  no taxa_meta file; run enrich_taxa.py for photos, tips and status")

    # Establishment resolved per tile by establishment_tiles.py. It is local,
    # not species-level: Geranium robertianum is native in the east and invasive
    # in the Pacific Northwest, so a single national answer is wrong for exactly
    # the species the native filter exists to catch.
    est_path = data_dir / f"establishment_tiles_{region}.json"
    per_tile_est = json.loads(est_path.read_text()) if est_path.exists() else {}
    if per_tile_est:
        print(f"  merging per-tile establishment for {len(per_tile_est):,} tiles")

    tiles: dict[tuple[int, int], list[dict]] = defaultdict(list)
    levels = {name: 0 for _, name, _ in FIT_LEVELS}

    for (tid, tile), b in buckets.items():
        if not b.fruit:
            continue   # taxon seen here only in flower; nothing to collect

        model = level = None
        penalty = 1.0
        # Expand outward until there is enough data, and stop at the last radius
        # rather than falling back to the whole dataset.
        for radius, name, mult in FIT_LEVELS:
            pool = b if radius == 0 else neighbourhood(buckets, tid, tile, radius)
            need_fruit = LOCAL_MIN_FRUIT if radius == 0 else MIN_FRUIT_OBS
            need_flower = LOCAL_MIN_FLOWER if radius == 0 else MIN_FLOWER_OBS
            if len(pool.fruit) >= need_fruit and len(pool.flower) >= need_flower:
                model = fit_taxon(np.array(pool.fruit), np.array(pool.flower))
                if model:
                    level, penalty = name, mult
                    break
        if model is None:
            continue

        levels[level] += 1
        # A fit borrowed from a wider area is less trustworthy here than its raw
        # sample size suggests.
        if penalty < 1.0:
            model["confidence"] = round(model["confidence"] * penalty, 3)

        local_est = per_tile_est.get(f"{tile[0]}_{tile[1]}", {}).get(str(tid))
        tiles[tile].append({
            **meta[tid], **model, **extra.get(str(tid), {}),
            **({"establishment": local_est} if local_est else {}),
            "fit_level": level,
            "n_local": len(b.fruit),
            "elevation": elevation_band(b.elevs),
            "cells": dict(b.cells),
        })

    out_dir.mkdir(parents=True, exist_ok=True)
    for f in out_dir.glob("*.json"):
        f.unlink()

    index = []
    for (r, c), taxa in sorted(tiles.items()):
        taxa.sort(key=lambda t: -t["n_local"])
        name = f"{r}_{c}.json"
        (out_dir / name).write_text(json.dumps({
            "schema_version": 2,
            "tile": [r, c],
            "tile_deg": TILE_DEG,
            "bounds": [r * TILE_DEG, c * TILE_DEG, (r + 1) * TILE_DEG, (c + 1) * TILE_DEG],
            "taxa": taxa,
        }, separators=(",", ":")))
        index.append({"tile": [r, c], "file": name, "taxa": len(taxa)})

    payload = {
        "schema_version": 2,
        "generated": date.today().isoformat(),
        "region": region,
        "tile_deg": TILE_DEG,
        "cell_deg": CELL_DEG,
        "ripe_quantiles": list(RIPE_QUANTILES),
        "fit_levels": levels,
        "tiles": index,
    }
    (out_dir / "index.json").write_text(json.dumps(payload, separators=(",", ":")))

    total = sum(t["taxa"] for t in index)
    size = sum(f.stat().st_size for f in out_dir.glob("*.json"))
    big = max(index, key=lambda t: t["taxa"]) if index else None
    print(f"\n{len(index):,} tiles, {total:,} species-tile fits, {size/1e6:.1f} MB total")
    print(f"  fit levels: {levels}")
    if big:
        print(f"  largest tile: {big['file']} with {big['taxa']:,} species "
              f"({(out_dir / big['file']).stat().st_size/1e6:.2f} MB)")
    return payload


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--merge", action="append", default=[],
                    help="additional region whose observations should be pooled in "
                         "(repeatable); duplicates are removed by observation id")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = [root / "data" / f"obs_{r}.jsonl" for r in [args.region, *args.merge]]
    missing = [p for p in paths if not p.exists()]
    if missing:
        raise SystemExit("missing: " + ", ".join(p.name for p in missing))
    build(paths, root / "web" / f"tiles_{args.region}", args.region)


if __name__ == "__main__":
    main()
