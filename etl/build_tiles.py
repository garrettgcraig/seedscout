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

    cell    the tile itself                     - most specific
    block   the tile plus its eight neighbours  - falls back for sparse species
    region  everything in the dataset           - last resort, flagged

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
    ELEV_SNAP,
    FRUIT_QUANTILES,
    MIN_FLOWER_OBS,
    MIN_FRUIT_OBS,
    RIPE_QUANTILES,
    cell_key,
    doy,
    elev_key,
    elevation_band,
    fit_taxon,
)

# Tile size in degrees. Small enough that phenology inside one is reasonably
# coherent, large enough that common species clear the sample-size bar without
# falling back. At mid-latitudes 2 degrees is roughly 220 km north-south.
TILE_DEG = 2.0

# A local fit has to be better-supported than the regional one to be worth
# preferring, otherwise we trade pooling bias for sampling noise.
LOCAL_MIN_FRUIT = 15
LOCAL_MIN_FLOWER = 10


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


def load(rows_path: Path, elev_cache: dict[str, float]):
    """Bucket every observation by (taxon, tile), keeping only what the fit needs."""
    buckets: dict[tuple[int, tuple[int, int]], Bucket] = {}
    meta: dict[int, dict] = {}
    n = 0
    with rows_path.open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
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
                e = elev_cache.get(elev_key(r["lat"], r["lng"]))
                if e is not None:
                    b.elevs.append(e)
            if "flowers" in r["phenology"]:
                b.flower.append(d)
            if n % 500_000 == 0:
                print(f"\r  read {n:,}", end="", flush=True)
    print(f"\r  read {n:,} observations -> {len(buckets):,} (taxon, tile) pairs")
    return buckets, meta


def neighbourhood(buckets, tid: int, tile: tuple[int, int]) -> Bucket:
    """The tile plus its eight neighbours, pooled."""
    out = Bucket()
    r0, c0 = tile
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            b = buckets.get((tid, (r0 + dr, c0 + dc)))
            if b:
                out.merge(b)
    return out


def build(rows_path: Path, out_dir: Path, region: str) -> dict:
    elev_path = rows_path.parent / "elevation.json"
    elev_cache = json.loads(elev_path.read_text()) if elev_path.exists() else {}
    if not elev_cache:
        print("no elevation cache; elevation filtering will be unavailable")

    buckets, meta = load(rows_path, elev_cache)

    # Region-wide totals per taxon, the last-resort fallback.
    region_wide: dict[int, Bucket] = {}
    for (tid, _), b in buckets.items():
        rb = region_wide.get(tid)
        if rb is None:
            rb = region_wide[tid] = Bucket()
        rb.merge(b)

    region_fit = {}
    for tid, b in region_wide.items():
        m = fit_taxon(np.array(b.fruit), np.array(b.flower))
        if m:
            region_fit[tid] = m

    # Family, conservation status, handling notes and photos, written once per
    # species by enrich_taxa.py and merged into every tile the species appears
    # in. Duplicated on disk so a tile is self-contained on the client.
    meta_path = out_dir.parent / f"taxa_meta_{region}.json"
    extra = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    if extra:
        print(f"  merging enrichment for {len(extra):,} taxa")
    else:
        print("  no taxa_meta file; run enrich_taxa.py for photos, tips and status")

    tiles: dict[tuple[int, int], list[dict]] = defaultdict(list)
    levels = {"cell": 0, "block": 0, "region": 0}

    for (tid, tile), b in buckets.items():
        if not b.fruit:
            continue   # taxon seen here only in flower; nothing to collect

        model = level = None
        # Finest level first.
        if len(b.fruit) >= LOCAL_MIN_FRUIT and len(b.flower) >= LOCAL_MIN_FLOWER:
            model = fit_taxon(np.array(b.fruit), np.array(b.flower))
            level = "cell"
        if model is None:
            nb = neighbourhood(buckets, tid, tile)
            if len(nb.fruit) >= MIN_FRUIT_OBS and len(nb.flower) >= MIN_FLOWER_OBS:
                model = fit_taxon(np.array(nb.fruit), np.array(nb.flower))
                level = "block"
        if model is None and tid in region_fit:
            model, level = dict(region_fit[tid]), "region"
        if model is None:
            continue

        levels[level] += 1
        # A fit borrowed from a wider area is less trustworthy here than its raw
        # sample size suggests.
        if level != "cell":
            model["confidence"] = round(model["confidence"] * (0.75 if level == "block" else 0.5), 3)

        tiles[tile].append({
            **meta[tid], **model, **extra.get(str(tid), {}),
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
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    build(root / "data" / f"obs_{args.region}.jsonl",
          root / "web" / f"tiles_{args.region}",
          args.region)


if __name__ == "__main__":
    main()
