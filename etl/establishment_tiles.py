"""Resolve native/introduced status per tile rather than per region.

Establishment is a local fact, not a species-level one. Geranium robertianum is
native in parts of eastern North America and an aggressive invasive in the
Pacific Northwest; Robinia pseudoacacia is native to the Appalachians and
introduced almost everywhere else. Asking whether a species is "introduced in
the United States" produces a contradiction for exactly the species people most
need the answer for, and leaving those unlabelled lets them through a filter
whose entire job is to exclude them.

So this asks the question the same way the phenology model does: inside each
tile. iNaturalist's species_counts endpoint takes a bounding box and returns
whole lists, so a tile costs a couple of requests rather than one per species.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "seedscout/0.1 (native seed collection timing)"
PAUSE = 1.2


def get(url: str, tries: int = 5) -> dict:
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except Exception as exc:  # noqa: BLE001
            if attempt == tries - 1:
                raise
            time.sleep(2 ** attempt * 3)
    raise RuntimeError("unreachable")


def taxa_of(bounds: list[float], kind: str) -> set[int]:
    """Taxon ids of the given establishment inside one tile."""
    s, w, n, e = bounds
    ids: set[int] = set()
    page = 1
    while True:
        q = urllib.parse.urlencode({
            "swlat": s, "swlng": w, "nelat": n, "nelng": e,
            "iconic_taxa": "Plantae", "quality_grade": "research",
            "per_page": 500, "page": page, kind: "true",
        })
        res = get(f"https://api.inaturalist.org/v1/observations/species_counts?{q}")
        ids.update(r["taxon"]["id"] for r in res["results"])
        if not res["results"] or page * 500 >= min(res["total_results"], 10_000):
            break
        page += 1
        time.sleep(PAUSE)
    return ids


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    tile_dir = root / "web" / f"tiles_{args.region}"
    index = json.loads((tile_dir / "index.json").read_text())

    sidecar = root / "data" / f"establishment_tiles_{args.region}.json"
    sidecar_data = json.loads(sidecar.read_text()) if sidecar.exists() else {}

    tiles = index["tiles"]
    # Skip tiles already resolved, so an interrupted run resumes.
    tiles = [t for t in tiles if f"{t['tile'][0]}_{t['tile'][1]}" not in sidecar_data]
    print(f"{len(tiles)} tiles to resolve ({len(sidecar_data)} already done)")
    changed = totals = 0
    for i, entry in enumerate(tiles):
        path = tile_dir / entry["file"]
        blob = json.loads(path.read_text())
        introduced = taxa_of(blob["bounds"], "introduced")
        time.sleep(PAUSE)
        native = taxa_of(blob["bounds"], "native")
        time.sleep(PAUSE)

        for t in blob["taxa"]:
            tid = t["taxon_id"]
            # Within a single tile the two lists rarely disagree; when they do,
            # introduced wins, because the filter exists to exclude and a false
            # negative there is the costlier error.
            value = ("introduced" if tid in introduced
                     else "native" if tid in native else None)
            if value and t.get("establishment") != value:
                t["establishment"] = value
                changed += 1
            totals += 1
        path.write_text(json.dumps(blob, separators=(",", ":")))
        # Also persist outside the tile, so rebuilding the model does not throw
        # away half an hour of per-tile lookups.
        sidecar_data[f"{entry['tile'][0]}_{entry['tile'][1]}"] = {
            str(t["taxon_id"]): t["establishment"]
            for t in blob["taxa"] if t.get("establishment")
        }
        sidecar.write_text(json.dumps(sidecar_data, separators=(",", ":")))
        print(f"\r  {i + 1}/{len(tiles)} tiles, {changed:,} labels set", end="", flush=True)

    print(f"\ndone: {changed:,} of {totals:,} species-tile entries relabelled")


if __name__ == "__main__":
    main()
