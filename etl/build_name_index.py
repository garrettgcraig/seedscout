"""Emit a national species-name index for the web client's search.

The web client only ever loads the tiles around the map pin, so on a search
miss it cannot tell "not near here" from "not in the dataset at all" - and it
used to give both the same message, which was false for the first. This index
lists every modeled species with the tiles it was fitted in, so a miss can say
where the nearest records are. It is fetched only when a search comes up empty.

    python3 etl/build_name_index.py conus
"""

from __future__ import annotations
import argparse, json
from collections import defaultdict
from pathlib import Path


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    tile_dir = root / "web" / f"tiles_{args.region}"
    index = json.loads((tile_dir / "index.json").read_text())

    names: dict[int, tuple[str, str | None]] = {}
    tiles: dict[int, list[str]] = defaultdict(list)
    for entry in index["tiles"]:
        blob = json.loads((tile_dir / entry["file"]).read_text())
        key = f"{blob['tile'][0]}_{blob['tile'][1]}"
        for t in blob["taxa"]:
            names.setdefault(t["taxon_id"], (t["name"], t.get("common")))
            tiles[t["taxon_id"]].append(key)

    rows = [[tid, n, c, tiles[tid]] for tid, (n, c) in sorted(names.items())]
    out = root / "web" / f"names_{args.region}.json"
    out.write_text(json.dumps(rows, separators=(",", ":"), ensure_ascii=False))
    print(f"{len(rows):,} species -> {out.name} ({out.stat().st_size/1024:.0f} KB)")


if __name__ == "__main__":
    main()
