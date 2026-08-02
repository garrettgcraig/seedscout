"""Fill in native/introduced status for a region, cheaply.

The "native species only" filter is the app's most-used control, and it works by
excluding species explicitly marked introduced. Where that field is missing the
filter silently passes everything, which is how a national build ends up
recommending common hawthorn and herb Robert in Seattle.

Unlike photos, this does not cost a request per species: iNaturalist's
species_counts endpoint returns whole lists of introduced and native taxa for a
bounding box, 500 at a time. A national fill is a few dozen requests.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "seedscout/0.1 (native seed collection timing)"
REGIONS = {
    "sbv": dict(swlat=34.0, nelat=35.1, swlng=-120.8, nelng=-118.9),
    "socal": dict(swlat=32.5, nelat=35.1, swlng=-120.8, nelng=-116.5),
    "conus": dict(swlat=24.4, nelat=49.4, swlng=-125.0, nelng=-66.9),
}


def get(url: str, tries: int = 5) -> dict:
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=90) as r:
                return json.load(r)
        except Exception as exc:  # noqa: BLE001
            if attempt == tries - 1:
                raise
            wait = 2 ** attempt * 3
            print(f"    retry in {wait}s ({exc})", flush=True)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def taxa_of(bbox: dict, kind: str) -> set[int]:
    ids: set[int] = set()
    page = 1
    while True:
        q = urllib.parse.urlencode(
            dict(bbox, iconic_taxa="Plantae", quality_grade="research",
                 per_page=500, page=page, **{kind: "true"})
        )
        res = get(f"https://api.inaturalist.org/v1/observations/species_counts?{q}")
        ids.update(r["taxon"]["id"] for r in res["results"])
        print(f"\r  {kind}: {len(ids):,}", end="", flush=True)
        # The endpoint caps out well before very large result sets are exhausted.
        if not res["results"] or page * 500 >= min(res["total_results"], 10_000):
            break
        page += 1
        time.sleep(1.2)
    print()
    return ids


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region", choices=sorted(REGIONS))
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    bbox = REGIONS[args.region]

    introduced = taxa_of(bbox, "introduced")
    native = taxa_of(bbox, "native")

    meta_path = root / "web" / f"taxa_meta_{args.region}.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    filled = 0
    for tid in {str(i) for i in introduced | native}:
        i = int(tid)
        # Only assign when the two lists agree, so a species recorded both ways
        # in different parts of a large region stays unlabelled rather than
        # being asserted wrongly.
        value = ("introduced" if i in introduced and i not in native
                 else "native" if i in native and i not in introduced else None)
        if value is None:
            continue
        entry = meta.setdefault(tid, {})
        if entry.get("establishment") != value:
            entry["establishment"] = value
            filled += 1

    meta_path.write_text(json.dumps(meta, separators=(",", ":")))
    counts = {k: sum(1 for v in meta.values() if v.get("establishment") == k)
              for k in ("native", "introduced")}
    print(f"{filled:,} taxa updated; {len(meta):,} carry metadata; {counts}")
    print("rebuild tiles to pick this up")


if __name__ == "__main__":
    main()
