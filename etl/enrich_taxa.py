"""Attach family, establishment means, conservation listings, and photos.

Rare-taxon flagging is not cosmetic here. Seed collection from a listed
population can be illegal and is ecologically harmful regardless of legality, so
the app needs to surface status before it suggests anyone go collect.

Photos are chosen deliberately: rather than the taxon's default photo (almost
always a flower, which is what the plant looks like when you have *missed* the
seed), we pull observations annotated as fruiting whose date falls inside the
modelled ripe window. That yields an image of the thing you are actually trying
to recognise in the field. Only CC-licensed photos are used, and attribution
travels with the URL.
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

USER_AGENT = "seedscout/0.1 (native seed collection timing)"
BATCH = 30

# iNat conservation status codes that should stop a collector.
SENSITIVE = {"CR", "EN", "VU", "NT", "SE", "ST", "SC", "CE"}

# Reusable without permission, with credit. Anything else is left alone.
OPEN_LICENSES = "cc0,cc-by,cc-by-sa,cc-by-nc,cc-by-nc-sa"


def months_spanning(start_doy: int, end_doy: int) -> str:
    """Months touched by a day-of-year window, handling the year wrap."""
    months, d = set(), start_doy
    span = (end_doy - start_doy) % 365 or 365
    for _ in range(span + 1):
        months.add((datetime(2025, 1, 1) + timedelta(days=d - 1)).month)
        d = d % 365 + 1
    return ",".join(str(m) for m in sorted(months))


def seed_photos(taxon_id: int, start_doy: int, end_doy: int, want: int = 2) -> list[dict]:
    """Photos of this taxon in fruit, taken during its modelled ripe window."""
    q = urllib.parse.urlencode(
        {
            "taxon_id": taxon_id,
            "term_id": 12,
            "term_value_id": 14,  # Fruits or Seeds
            "quality_grade": "research",
            "photos": "true",
            "photo_license": OPEN_LICENSES,
            "month": months_spanning(start_doy, end_doy),
            "order_by": "votes",
            "per_page": want * 3,
        }
    )
    try:
        res = get(f"https://api.inaturalist.org/v1/observations?{q}")
    except Exception:  # noqa: BLE001 - a missing photo must not fail the run
        return []

    out, seen = [], set()
    for obs in res.get("results", []):
        for p in obs.get("photos", []):
            if not p.get("license_code") or p["id"] in seen:
                continue
            seen.add(p["id"])
            out.append(
                {
                    "url": p["url"].replace("/square.", "/medium."),
                    "license": p["license_code"],
                    "by": (p.get("attribution") or "").split(",")[0].replace("(c) ", "").strip()
                    or obs.get("user", {}).get("login"),
                    "obs": obs["id"],
                }
            )
            break  # one photo per observation keeps the set visually varied
        if len(out) >= want:
            break
    return out


def get(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def establishment_sets(bbox: dict) -> tuple[set[int], set[int]]:
    """Taxon ids recorded as introduced / native within the region.

    One request per class beats one request per taxon by two orders of
    magnitude.
    """
    out = []
    for kind in ("introduced", "native"):
        ids: set[int] = set()
        page = 1
        while True:
            q = urllib.parse.urlencode(
                dict(bbox, iconic_taxa="Plantae", per_page=500, page=page, **{kind: "true"})
            )
            res = get(f"https://api.inaturalist.org/v1/observations/species_counts?{q}")
            ids.update(r["taxon"]["id"] for r in res["results"])
            if page * 500 >= res["total_results"] or not res["results"]:
                break
            page += 1
            time.sleep(1.05)
        out.append(ids)
        print(f"  {kind}: {len(ids):,} taxa")
    return out[0], out[1]


def enrich(model_path: Path, bbox: dict, photos: bool = True) -> None:
    payload = json.loads(model_path.read_text())
    taxa = payload["taxa"]
    print(f"enriching {len(taxa):,} taxa")

    introduced, native = establishment_sets(bbox)

    ids = [t["taxon_id"] for t in taxa]
    detail: dict[int, dict] = {}
    for i in range(0, len(ids), BATCH):
        chunk = ids[i : i + BATCH]
        res = get("https://api.inaturalist.org/v1/taxa/" + ",".join(map(str, chunk)))
        for t in res["results"]:
            detail[t["id"]] = t
        print(f"\r  detail {min(i + BATCH, len(ids)):,}/{len(ids):,}", end="", flush=True)
        time.sleep(1.05)
    print()

    n_sensitive = 0
    for t in taxa:
        d = detail.get(t["taxon_id"], {})
        fams = [a["name"] for a in d.get("ancestors", []) if a.get("rank") == "family"]
        t["family"] = fams[0] if fams else None

        # Any listing counts, global or from any place. Restricting this to one
        # state was fine for a single-region build and silently wrong for a
        # national one. Over-flagging is the safe direction of error here: the
        # cost of a needless warning is nothing, the cost of a missed one is
        # someone collecting from a listed population.
        statuses = d.get("conservation_statuses") or []
        places = sorted({
            (s.get("place") or {}).get("name", "global")
            for s in statuses
            if (s.get("status") or "").upper() in SENSITIVE
        })
        codes = {(s.get("status") or "").upper() for s in statuses}
        hits = sorted(codes & SENSITIVE)
        t["sensitive"] = bool(hits)
        t["status_codes"] = hits or None
        t["status_places"] = places or None
        if hits:
            n_sensitive += 1

        tid = t["taxon_id"]
        t["establishment"] = (
            "introduced" if tid in introduced and tid not in native
            else "native" if tid in native and tid not in introduced
            else None
        )

    # Curated field guidance, keyed most-specific-first: exact taxon, then genus,
    # then family. Nothing here comes from iNaturalist.
    tips = json.loads((Path(__file__).parent / "tips.json").read_text())
    n_tips = 0
    for t in taxa:
        genus = t["name"].split()[0]
        tip = (
            tips["by_taxon"].get(t["name"])
            or tips["by_taxon"].get(genus)
            or tips["by_family"].get(t.get("family") or "")
        )
        if tip:
            scope = (
                "species" if t["name"] in tips["by_taxon"]
                else "genus" if genus in tips["by_taxon"]
                else "family"
            )
            t["tips"] = {**tip, "scope": scope}
            n_tips += 1

    # Photos cost one request per species; family and status come thirty at a
    # time. On a large region the photo pass is the only expensive part, so it
    # can be deferred without giving up the conservation flags that decide
    # whether the app tells someone not to collect.
    n_photos = 0
    if photos:
        print("fetching seed photos")
        for i, t in enumerate(taxa):
            t["photos"] = seed_photos(t["taxon_id"], t["ripe_start_doy"], t["ripe_end_doy"])
            n_photos += bool(t["photos"])
            print(f"\r  {i + 1:,}/{len(taxa):,} ({n_photos} with photos)", end="", flush=True)
            time.sleep(1.05)
        print()
    else:
        print("skipping photos (--no-photos)")

    payload["enriched"] = True
    model_path.write_text(json.dumps(payload, separators=(",", ":")))

    # Per-taxon metadata is independent of geography, so it is also written on
    # its own for build_tiles.py to merge into every tile a species appears in.
    # That keeps enrichment a once-per-species cost rather than once per tile.
    meta_path = model_path.parent / f"taxa_meta_{payload['region']}.json"
    meta_path.write_text(json.dumps({
        str(t["taxon_id"]): {
            k: t[k] for k in ("family", "sensitive", "status_codes", "establishment", "tips", "photos")
            if k in t
        }
        for t in taxa
    }, separators=(",", ":")))
    print(f"  taxon metadata -> {meta_path.name}")
    counts = {k: sum(1 for t in taxa if t["establishment"] == k) for k in ("native", "introduced")}
    print(
        f"done: {n_sensitive} sensitive flagged, {counts} (rest ambiguous), "
        f"{n_tips} with tips, {n_photos} with photos "
        f"({model_path.stat().st_size / 1e6:.1f} MB)"
    )


REGIONS = {
    "sbv": dict(swlat=34.0, nelat=35.1, swlng=-120.8, nelng=-118.9),
    "socal": dict(swlat=32.5, nelat=35.1, swlng=-120.8, nelng=-116.5),
    "conus": dict(swlat=24.4, nelat=49.4, swlng=-125.0, nelng=-66.9),
}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region", choices=sorted(REGIONS))
    ap.add_argument("--no-photos", action="store_true",
                    help="skip the one-request-per-species photo pass")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    enrich(root / "web" / f"species_{args.region}.json", REGIONS[args.region],
           photos=not args.no_photos)


if __name__ == "__main__":
    main()
