"""Fill in native/introduced status that iNaturalist's per-place listings leave blank.

Per-tile establishment (establishment_tiles.py) is decided from observation
counts and is left unknown when there is no listing or no clear majority. The
client keeps unknown species in the natives-only view, on the reasoning that an
unknown is usually a native that simply lacks a listing. That reasoning fails
for three groups, which together let known invasives through as collectible:

1. Species recorded as introduced somewhere and native nowhere, but unknown in
   other tiles (Japanese honeysuckle, Lantana, watercress). Unknown tiles take
   the only status the species has anywhere: introduced.
2. Subspecies and varieties with no listing of their own, whose species is
   introduced somewhere and native nowhere (Trapa natans bispinosa, Vicia
   villosa varia). They inherit the species' status.
3. Taxa no listing can settle, set by hand with a citation in
   establishment_overrides.json (European Phragmites, whose species is native
   in North America through a different lineage).

Only unknowns are filled; a tile that says native or introduced is never
overridden by rules 1 and 2. Each filled entry records why, in
"establishment_basis", so the decision stays inspectable.

Run directly to patch built outputs in place (web tiles and the iOS SQLite
bundle) without refitting; build_tiles.py also applies it on every build.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path

OVERRIDES = Path(__file__).with_name("establishment_overrides.json")


def decide(taxa_by_tile: dict) -> dict[int, tuple[str, str]]:
    """Return {taxon_id: (status, basis)} for taxa whose unknowns should be filled."""
    counts: dict[int, Counter] = defaultdict(Counter)
    names: dict[int, str] = {}
    for taxa in taxa_by_tile.values():
        for t in taxa:
            counts[t["taxon_id"]][t.get("establishment")] += 1
            names[t["taxon_id"]] = t["name"]

    def only_introduced(c: Counter) -> bool:
        return c["introduced"] > 0 and c["native"] == 0

    out: dict[int, tuple[str, str]] = {}
    for tid, c in counts.items():
        if c[None] and only_introduced(c):
            out[tid] = ("introduced", "introduced wherever listed, native nowhere")

    by_name = {n: tid for tid, n in names.items()}
    for tid, c in counts.items():
        if tid in out or c["native"] or c["introduced"]:
            continue
        words = names[tid].split()
        if len(words) < 3:
            continue
        parent = by_name.get(" ".join(words[:2]))
        if parent is not None and only_introduced(counts[parent]):
            out[tid] = ("introduced", f"inherits from {' '.join(words[:2])}, introduced wherever listed")

    for key, row in json.loads(OVERRIDES.read_text()).items():
        if key.startswith("_"):
            continue
        out[int(key)] = (row["establishment"], "override: " + row["source"])
    return out


def apply(taxa_by_tile: dict) -> dict[str, int]:
    """Fill unknowns in place. Overrides apply everywhere; rules only to unknowns."""
    decisions = decide(taxa_by_tile)
    overrides = {int(k) for k in json.loads(OVERRIDES.read_text()) if not k.startswith("_")}
    stats = Counter()
    for taxa in taxa_by_tile.values():
        for t in taxa:
            d = decisions.get(t["taxon_id"])
            if not d:
                continue
            forced = t["taxon_id"] in overrides
            if t.get("establishment") is None or (forced and t.get("establishment") != d[0]):
                t["establishment"], t["establishment_basis"] = d
                stats["override" if forced else "rule"] += 1
    stats["taxa"] = len(decisions)
    return dict(stats)


def patch_outputs(region: str) -> None:
    root = Path(__file__).resolve().parents[1]
    tile_dir = root / "web" / f"tiles_{region}"
    index = json.loads((tile_dir / "index.json").read_text())
    blobs = {e["file"]: json.loads((tile_dir / e["file"]).read_text()) for e in index["tiles"]}
    stats = apply({f: b["taxa"] for f, b in blobs.items()})
    for f, b in blobs.items():
        (tile_dir / f).write_text(json.dumps(b, separators=(",", ":")))
    print(f"  tiles: {stats}")

    db_path = root / "ios" / "SeedFinder" / "Resources" / f"seedfinder_{region}.sqlite"
    if not db_path.exists():
        print("  no SQLite bundle to patch")
        return
    db = sqlite3.connect(db_path)
    changed = 0
    for b in blobs.values():
        tr, tc = b["tile"]
        for t in b["taxa"]:
            if t.get("establishment_basis"):
                changed += db.execute(
                    "UPDATE fit SET establishment = ? WHERE tile_r = ? AND tile_c = ? AND taxon_id = ? "
                    "AND IFNULL(establishment, '') != ?",
                    (t["establishment"], tr, tc, t["taxon_id"], t["establishment"])).rowcount
    db.commit()
    db.close()
    print(f"  sqlite: {changed} fits updated")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    patch_outputs(ap.parse_args().region)
