"""Pull research-grade plant observations carrying iNaturalist's
'Flowers and Fruits' annotation (controlled term 12) for a bounding box.

Writes newline-delimited JSON incrementally and records the last observation id
seen, so an interrupted run resumes instead of restarting. Deep pagination uses
the id_above cursor because iNat caps page*per_page at 10,000.
"""

from __future__ import annotations

import argparse
import gzip
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# v2 rather than v1 for one reason: sparse fieldsets. v1 returns the whole
# observation - every photo, identification, comment and user record - which is
# 71 KB per observation when the model consumes about ten fields. Asking v2 for
# only those fields costs 458 bytes per observation, 156x less JSON and 34x less
# on the wire, and it is faster per page as well. Pulling millions of records
# through v1 was the reason iNaturalist kept throttling this client.
API = "https://api.inaturalist.org/v2/observations"
PER_PAGE = 200

# Exactly what slim() reads, in v2's field-selection syntax. Field names match
# v1's response shape, so the parsing below is unchanged.
FIELDS = (
    "(id:!t,observed_on:!t,geojson:!t,obscured:!t,geoprivacy:!t,"
    "positional_accuracy:!t,"
    "taxon:(id:!t,name:!t,preferred_common_name:!t,rank:!t,ancestry:!t),"
    "annotations:(controlled_attribute_id:!t,controlled_value_id:!t,vote_score:!t))"
)
# iNat asks for <=60 requests/min and a real user agent. Pacing exactly at that
# limit still trips their throttle on a long run, and each 429 costs more in
# backoff than the pacing would have cost in the first place, so the interval
# adapts: it climbs on throttling and eases back down after a clean streak.
MIN_INTERVAL = 1.05
MAX_INTERVAL = 6.0
CLEAN_STREAK = 40          # successes before easing the pace back down
USER_AGENT = "seedscout/0.1 (native seed collection timing; contact via github)"

_pace = {"interval": MIN_INTERVAL, "clean": 0, "throttled": 0}

# Controlled term 12 = "Flowers and Fruits"
TERM_FLOWERS_FRUITS = 12
VALUE_LABELS = {13: "flowers", 14: "fruits", 15: "flower_buds", 21: "none"}


def get(url: str, tries: int = 6) -> dict:
    """GET with adaptive pacing and exponential backoff.

    A 429 is treated as a signal to slow down permanently rather than just a
    reason to sleep once: throttling one page usually means the next page would
    be throttled too. Retry-After is honoured when the server sends it.
    """
    for attempt in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"}
            )
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                _pace["clean"] += 1
                if _pace["clean"] >= CLEAN_STREAK and _pace["interval"] > MIN_INTERVAL:
                    _pace["interval"] = max(MIN_INTERVAL, _pace["interval"] * 0.85)
                    _pace["clean"] = 0
                return json.loads(raw)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            if attempt == tries - 1:
                raise
            _pace["clean"] = 0
            throttled = isinstance(exc, urllib.error.HTTPError) and exc.code in (429, 503)
            if throttled:
                _pace["throttled"] += 1
                _pace["interval"] = min(MAX_INTERVAL, _pace["interval"] * 1.4)
            retry_after = 0
            if isinstance(exc, urllib.error.HTTPError):
                try:
                    retry_after = float(exc.headers.get("Retry-After") or 0)
                except ValueError:
                    retry_after = 0
            wait = max(retry_after, 2 ** attempt * 2)
            print(f"  retry in {wait:.0f}s, pace now {_pace['interval']:.2f}s ({exc})",
                  file=sys.stderr, flush=True)
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
        fields=FIELDS,
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
            print(f"\r  {seen:,}/{total:,} scanned, {written:,} kept, "
                  f"pace {_pace['interval']:.2f}s, {_pace['throttled']} throttled",
                  end="", flush=True)

            if len(results) < PER_PAGE:
                break
            elapsed = time.monotonic() - started
            if elapsed < _pace["interval"]:
                time.sleep(_pace["interval"] - elapsed)

    print(f"\ndone: {written:,} rows -> {out_path}")
    return written


REGIONS = {
    # Fast pilot: Santa Barbara + Ventura counties.
    "sbv": dict(swlat=34.0, nelat=35.1, swlng=-120.8, nelng=-118.9),
    # Coastal Southern California, Point Conception to the border.
    "socal": dict(swlat=32.5, nelat=35.1, swlng=-120.8, nelng=-116.5),
    # National build. CONUS is ~6.3M annotated observations and takes the better
    # part of a day to page through; the run is resumable, so re-invoking it
    # after an interruption picks up from the last observation id.
    "conus": dict(swlat=24.4, nelat=49.4, swlng=-125.0, nelng=-66.9),
    "alaska": dict(swlat=51.0, nelat=71.5, swlng=-180.0, nelng=-129.0),
    "hawaii": dict(swlat=18.8, nelat=22.3, swlng=-160.3, nelng=-154.7),
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
