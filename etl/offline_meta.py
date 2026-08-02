"""Assemble taxon metadata for a region without touching the iNaturalist API.

enrich_taxa.py is the full path: it fetches family, conservation status and a
seed photo per species. That costs one request per taxon, which is not available
when the API is throttling a long build.

This gets what can be had offline. Species already enriched for another region
are reused wholesale. Everything else gets handling notes matched by species or
genus name from tips.json — family-level notes are unavailable because family
itself comes from the API.

Run enrich_taxa.py later to fill in the rest; it overwrites what this produces.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--reuse", action="append", default=[],
                    help="region whose enrichment should be reused (repeatable)")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    tips = json.loads((Path(__file__).parent / "tips.json").read_text())

    # Every taxon present in the region's observations.
    names: dict[str, str] = {}
    with (root / "data" / f"obs_{args.region}.jsonl").open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            names.setdefault(str(r["taxon_id"]), r["name"])

    out: dict[str, dict] = {}
    reused = 0
    for other in args.reuse:
        path = root / "web" / f"taxa_meta_{other}.json"
        if not path.exists():
            print(f"  no enrichment for {other}, skipping")
            continue
        for tid, meta in json.loads(path.read_text()).items():
            if tid in names and tid not in out:
                out[tid] = meta
                reused += 1
        print(f"  reused {reused:,} taxa from {other}")

    # Offline tips for everything else: species name, then genus. Family-level
    # notes need family, which only the API provides.
    added = 0
    for tid, name in names.items():
        if tid in out:
            continue
        genus = name.split()[0]
        tip = tips["by_taxon"].get(name) or tips["by_taxon"].get(genus)
        if tip:
            out[tid] = {"tips": {**tip, "scope": "species" if name in tips["by_taxon"] else "genus"}}
            added += 1

    path = root / "web" / f"taxa_meta_{args.region}.json"
    path.write_text(json.dumps(out, separators=(",", ":")))
    print(f"{len(names):,} taxa in region; {len(out):,} carry metadata "
          f"({reused:,} reused, {added:,} tips-only) -> {path.name}")
    print("run enrich_taxa.py when the API allows, for family, status and photos")


if __name__ == "__main__":
    main()
