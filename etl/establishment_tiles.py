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


def taxa_of(bounds: list[float], kind: str) -> dict[int, int]:
    """Taxon id -> observation count for the given establishment inside one tile."""
    s, w, n, e = bounds
    counts: dict[int, int] = {}
    page = 1
    while True:
        q = urllib.parse.urlencode({
            "swlat": s, "swlng": w, "nelat": n, "nelng": e,
            "iconic_taxa": "Plantae", "quality_grade": "research",
            "per_page": 500, "page": page, kind: "true",
        })
        res = get(f"https://api.inaturalist.org/v1/observations/species_counts?{q}")
        for r in res["results"]:
            counts[r["taxon"]["id"]] = r["count"]
        if not res["results"] or page * 500 >= min(res["total_results"], 10_000):
            break
        page += 1
        time.sleep(PAUSE)
    return counts


# How much one side must outweigh the other before we believe it.
DECISIVE_RATIO = 3.0


def decide(native: int, introduced: int) -> str | None:
    """Label a species from its two observation counts in a tile.

    The lists overlap more than you would expect - 74 of Boston's species appear
    in both - because establishment is recorded per place and a handful of stray
    or mislabelled records is enough to put a species on the wrong list. Treating
    any introduced record as decisive gets this badly wrong: staghorn sumac shows
    10 introduced against 5,875 native in Massachusetts, and common milkweed 10
    against 7,475. Both are native there, and both were being hidden by the
    natives-only filter.

    So the counts decide, and only when one side clearly dominates. A genuinely
    contested species returns None, which the client shows rather than hides -
    the right default when the alternative is silently dropping a good seed
    source the collector could have judged for themselves.
    """
    if native and introduced:
        hi, lo = max(native, introduced), min(native, introduced)
        if hi < lo * DECISIVE_RATIO:
            return None
        return "native" if native > introduced else "introduced"
    if native:
        return "native"
    if introduced:
        return "introduced"
    return None


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--force", action="store_true",
                    help="re-resolve every tile instead of resuming")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    tile_dir = root / "web" / f"tiles_{args.region}"
    index = json.loads((tile_dir / "index.json").read_text())

    sidecar = root / "data" / f"establishment_tiles_{args.region}.json"
    sidecar_data = {} if args.force else (
        json.loads(sidecar.read_text()) if sidecar.exists() else {})
    counts_path = root / "data" / f"establishment_counts_{args.region}.json"
    counts_data = {} if args.force else (
        json.loads(counts_path.read_text()) if counts_path.exists() else {})

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

        tile_counts = {}
        for t in blob["taxa"]:
            tid = t["taxon_id"]
            nat, intro = native.get(tid, 0), introduced.get(tid, 0)
            value = decide(nat, intro)
            if nat or intro:
                tile_counts[str(tid)] = [nat, intro]
            if t.get("establishment") != value:
                t["establishment"] = value
                changed += 1
            totals += 1
        path.write_text(json.dumps(blob, separators=(",", ":")))
        # Raw counts are kept so the threshold can be retuned later without
        # spending another 2,500 requests to ask the same questions.
        counts_data[f"{entry['tile'][0]}_{entry['tile'][1]}"] = tile_counts
        counts_path.write_text(json.dumps(counts_data, separators=(",", ":")))
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
