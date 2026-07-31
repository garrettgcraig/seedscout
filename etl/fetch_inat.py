"""Pull research-grade plant observations carrying iNaturalist's
'Flowers and Fruits' annotation (controlled term 12) for a bounding box.

Writes newline-delimited JSON incrementally and records the last observation id
seen, so an interrupted run resumes instead of restarting. Deep pagination uses
the id_above cursor because iNat caps page*per_page at 10,000.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.inaturalist.org/v1/observations"
PER_PAGE = 200
# Be a good citizen: iNat asks for <=60 requests/min and a real user agent.
MIN_INTERVAL = 1.05
USER_AGENT = "seedscout/0.1 (native seed collection timing; contact via github)"

# Controlled term 12 = "Flowers and Fruits"
TERM_FLOWERS_FRUITS = 12
VALUE_LABELS = {13: "flowers", 14: "fruits", 15: "flower_buds", 21: "none"}


def get(url: str, tries: int = 5) -> dict:
    """GET with exponential backoff. iNat returns 429/503 under load."""
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.load(resp)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            if attempt == tries - 1:
                raise
            wait = 2**attempt * 2
            print(f"  retry in {wait}s ({exc})", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def slim(obs: dict) -> dict | None:
    """Keep only the fields the phenology model needs.

    Drops observations without a taxon, a date, or public coordinates. Obscured
    records report a coarse public location, which is fine at our resolution.
    """
    taxon = obs.get("taxon")
    if not taxon or not obs.get("observed_on"):
        return None
    coords = obs.get("geojson") or {}
    lng_lat = coords.get("coordinates")
    if not lng_lat:
        return None

    # An annotation is only trustworthy if the community hasn't voted it down.
    phenology = sorted(
        {
            VALUE_LABELS[a["controlled_value_id"]]
            for a in obs.get("annotations", [])
            if a.get("controlled_attribute_id") == TERM_FLOWERS_FRUITS
            and a.get("controlled_value_id") in VALUE_LABELS
            and a.get("vote_score", 0) >= 0
        }
    )
    if not phenology:
        return None

    return {
        "id": obs["id"],
        "taxon_id": taxon["id"],
        "name": taxon["name"],
        "common": taxon.get("preferred_common_name"),
        "rank": taxon.get("rank"),
        "ancestry": taxon.get("ancestry"),
        "observed_on": obs["observed_on"],
        "lng": lng_lat[0],
        "lat": lng_lat[1],
        "obscured": bool(obs.get("obscured") or obs.get("geoprivacy")),
        "positional_accuracy": obs.get("positional_accuracy"),
        "phenology": phenology,
    }


def fetch(bbox: dict, out_path: Path, resume: bool = True) -> int:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    state_path = out_path.with_suffix(".state.json")

    id_above = 0
    written = 0
    if resume and state_path.exists() and out_path.exists():
        state = json.loads(state_path.read_text())
        id_above = state["id_above"]
        written = state["written"]
        print(f"resuming from observation id {id_above:,} ({written:,} rows kept)")

    params = dict(
        bbox,
        iconic_taxa="Plantae",
        quality_grade="research",
        term_id=TERM_FLOWERS_FRUITS,
        per_page=PER_PAGE,
        order_by="id",
        order="asc",
    )

    total = get(f"{API}?{urllib.parse.urlencode(dict(params, per_page=0))}")["total_results"]
    print(f"{total:,} annotated observations in bbox")

    seen = 0
    with out_path.open("a" if id_above else "w") as fh:
        while True:
            started = time.monotonic()
            page = get(f"{API}?{urllib.parse.urlencode(dict(params, id_above=id_above))}")
            results = page["results"]
            if not results:
                break

            for obs in results:
                row = slim(obs)
                if row:
                    fh.write(json.dumps(row) + "\n")
                    written += 1
            fh.flush()

            seen += len(results)
            id_above = results[-1]["id"]
            state_path.write_text(json.dumps({"id_above": id_above, "written": written}))
            print(f"\r  {seen:,}/{total:,} scanned, {written:,} kept", end="", flush=True)

            if len(results) < PER_PAGE:
                break
            elapsed = time.monotonic() - started
            if elapsed < MIN_INTERVAL:
                time.sleep(MIN_INTERVAL - elapsed)

    print(f"\ndone: {written:,} rows -> {out_path}")
    return written


REGIONS = {
    # Fast pilot: Santa Barbara + Ventura counties.
    "sbv": dict(swlat=34.0, nelat=35.1, swlng=-120.8, nelng=-118.9),
    # Full v1 region: coastal Southern California, Point Conception to the border.
    "socal": dict(swlat=32.5, nelat=35.1, swlng=-120.8, nelng=-116.5),
}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region", choices=sorted(REGIONS))
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--no-resume", action="store_true")
    args = ap.parse_args()

    out = args.out or Path(__file__).resolve().parents[1] / "data" / f"obs_{args.region}.jsonl"
    fetch(REGIONS[args.region], out, resume=not args.no_resume)


if __name__ == "__main__":
    main()
