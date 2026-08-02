#!/bin/bash
# Finish the national build once the per-tile establishment pass completes.
#
#   1. wait for establishment_tiles.py
#   2. lift its results out of the tile files into a sidecar, so rebuilds keep them
#   3. fetch family, conservation status and a photo for every taxon (30 per request)
#   4. rebuild tiles with all of it merged
#
# Steps run in sequence rather than in parallel on purpose: both API passes hit
# iNaturalist, and running them together is how the earlier pulls got throttled.
set -eu
cd "$(dirname "$0")/.."

echo "=== waiting for establishment_tiles ==="
while pgrep -f "establishment_tiles.py conus" > /dev/null; do sleep 30; done
echo "  finished"

echo "=== lifting per-tile establishment into sidecar ==="
python3 - <<'PY'
import json, pathlib
d = pathlib.Path("web/tiles_conus")
out = {}
for f in sorted(d.glob("*.json")):
    if f.name == "index.json":
        continue
    blob = json.loads(f.read_text())
    r, c = blob["tile"]
    got = {str(t["taxon_id"]): t["establishment"]
           for t in blob["taxa"] if t.get("establishment")}
    if got:
        out[f"{r}_{c}"] = got
p = pathlib.Path("data/establishment_tiles_conus.json")
p.write_text(json.dumps(out, separators=(",", ":")))
print(f"  {len(out)} tiles, {sum(len(v) for v in out.values()):,} labels -> {p.name}")
PY

echo "=== taxa detail: family, status, photo ==="
python3 etl/taxa_detail.py conus

echo "=== rebuilding tiles ==="
python3 etl/build_tiles.py conus --merge socal

echo "=== coverage after ==="
python3 - <<'PY'
import json
for lat, lng, place in [(34.42,-119.70,"Santa Barbara"), (42.36,-71.06,"Boston"),
                        (30.27,-97.74,"Austin"), (47.61,-122.33,"Seattle")]:
    r, c = int(lat//2), int(lng//2)
    t = json.load(open(f"web/tiles_conus/{r}_{c}.json"))["taxa"]
    ph = sum(1 for x in t if x.get("photos"))
    ti = sum(1 for x in t if x.get("tips"))
    print(f"{place:15s} {len(t):>4d} species | photos {ph:>4d} ({100*ph/len(t):3.0f}%) | "
          f"tips {ti:>4d} ({100*ti/len(t):3.0f}%)")
PY
echo "=== done, ready to deploy ==="
