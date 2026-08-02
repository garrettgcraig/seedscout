"""Fetch family, conservation status and a representative photo for every taxon.

This is the cheap three-quarters of enrichment. iNaturalist's taxa endpoint
takes thirty ids at a time and returns all three, so covering eighteen thousand
species costs about six hundred requests rather than eighteen thousand.

Only the seed-specific photo needs a request per species, because it comes from
searching that species' own observations inside its modelled ripe window. That
pass lives in enrich_taxa.py and is worth running for a region you care about;
this one makes every species outside it usable in the meantime.

The photo here is the taxon's default, which is usually a flower or a habit
shot rather than fruit. It is labelled as such so the client can say which kind
of picture the user is looking at.
"""

from __future__ import annotations

import argparse
import gzip
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "seedscout/0.1 (native seed collection timing)"
BATCH = 30
PAUSE = 1.15

# Same reasoning as the observation fetch: v1 returns whole taxon records and
# costs 645 KB for thirty taxa, where v2 with an explicit field list costs 9 KB.
API = "https://api.inaturalist.org/v2/taxa/"
FIELDS = (
    "(id:!t,name:!t,rank:!t,"
    "ancestors:(name:!t,rank:!t),"
    "default_photo:(medium_url:!t,license_code:!t,attribution:!t),"
    "conservation_statuses:(status:!t,place:(name:!t)))"
)

SENSITIVE = {"CR", "EN", "VU", "NT", "SE", "ST", "SC", "CE"}
OPEN_LICENSES = {"cc0", "cc-by", "cc-by-sa", "cc-by-nc", "cc-by-nc-sa", "cc-by-nd"}


def get(url: str, tries: int = 6) -> dict:
    for attempt in range(tries):
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"}
            )
            with urllib.request.urlopen(req, timeout=90) as r:
                raw = r.read()
                if r.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                return json.loads(raw)
        except Exception as exc:  # noqa: BLE001
            if attempt == tries - 1:
                raise
            wait = 2 ** attempt * 3
            print(f"\n  retry in {wait}s ({exc})", flush=True)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def taxon_ids(tile_dir: Path) -> list[int]:
    ids: set[int] = set()
    for f in tile_dir.glob("*.json"):
        if f.name == "index.json":
            continue
        for t in json.loads(f.read_text())["taxa"]:
            ids.add(t["taxon_id"])
    return sorted(ids)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--limit", type=int, default=0, help="stop after N taxa (for testing)")
    args = ap.parse_args()

    root = Path(__file__).resolve().parents[1]
    tile_dir = root / "web" / f"tiles_{args.region}"
    meta_path = root / "web" / f"taxa_meta_{args.region}.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}
    tips = json.loads((Path(__file__).parent / "tips.json").read_text())

    ids = taxon_ids(tile_dir)
    if args.limit:
        ids = ids[: args.limit]
    print(f"{len(ids):,} taxa, {(len(ids) + BATCH - 1)//BATCH:,} requests")

    done = 0
    for i in range(0, len(ids), BATCH):
        chunk = ids[i : i + BATCH]
        res = get(API + ",".join(map(str, chunk)) + "?fields=" + FIELDS)
        for t in res.get("results", []):
            entry = meta.setdefault(str(t["id"]), {})

            fams = [a["name"] for a in t.get("ancestors", []) if a.get("rank") == "family"]
            if fams:
                entry["family"] = fams[0]

            statuses = t.get("conservation_statuses") or []
            codes = {(s.get("status") or "").upper() for s in statuses}
            hits = sorted(codes & SENSITIVE)
            entry["sensitive"] = bool(hits)
            entry["status_codes"] = hits or None

            # Keep a seed-window photo if enrich_taxa already found one; this is
            # the weaker fallback, so it must not overwrite the better image.
            if not entry.get("photos"):
                dp = t.get("default_photo") or {}
                if dp.get("license_code") in OPEN_LICENSES and dp.get("medium_url"):
                    entry["photos"] = [{
                        "url": dp["medium_url"],
                        "license": dp["license_code"],
                        "by": (dp.get("attribution") or "").split(",")[0]
                              .replace("(c) ", "").strip() or None,
                        "kind": "habit",   # not necessarily fruit; the client says so
                    }]

            name = t.get("name", "")
            genus = name.split()[0] if name else ""
            tip = (tips["by_taxon"].get(name) or tips["by_taxon"].get(genus)
                   or tips["by_family"].get(entry.get("family") or ""))
            if tip:
                entry["tips"] = {**tip, "scope": (
                    "species" if name in tips["by_taxon"]
                    else "genus" if genus in tips["by_taxon"] else "family")}
            done += 1

        meta_path.write_text(json.dumps(meta, separators=(",", ":")))
        print(f"\r  {min(i + BATCH, len(ids)):,}/{len(ids):,}", end="", flush=True)
        time.sleep(PAUSE)

    have = lambda k: sum(1 for v in meta.values() if v.get(k))  # noqa: E731
    print(f"\ndone: {done:,} taxa detailed")
    print(f"  family {have('family'):,} | photos {have('photos'):,} | "
          f"tips {have('tips'):,} | sensitive {have('sensitive'):,}")
    print("rebuild tiles to pick this up")


if __name__ == "__main__":
    main()
