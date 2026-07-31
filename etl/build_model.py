"""Fit a per-taxon seed-collection window from iNaturalist phenology annotations.

The central problem: iNaturalist's annotation is "Fruits or Seeds", a single
value spanning green fruit through dehiscence. It does not mean *ripe*. Taking
the peak of that distribution tells you to collect weeks early.

The fix is to change coordinates. Fruit always follows flowers, so instead of
day-of-year we measure each fruiting record as "days elapsed since this taxon's
flowering peak". That single change does two things: it linearizes a circular
quantity along the axis the biology actually runs on, and it stops species whose
dried fruit persists on the plant for months (Malosma, Eriogonum, Baccharis)
from having their season smeared across the whole calendar. Under day-of-year
quantiles, laurel sumac's ripe window came out five months late.

RIPE_QUANTILES is then the remaining assumption, and it is a weak one: it was
tuned against only nine species with well-documented local phenology (8/9 hit,
versus 6/9 for the day-of-year model). Treat it as a starting point to be
recalibrated against field observation, not as a fitted parameter.

Occurrence is treated as local and phenology as regional: per-cell sample sizes
are far too thin to fit a season, but they are plenty to answer "does this grow
near me". The two are combined at query time.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path

import numpy as np

# Quantiles of the fruiting distribution, measured in days since the flowering
# peak, taken as (window start, peak, window end). See module docstring: these
# are calibrated against a handful of species and are the first thing to revisit
# when field observations disagree with the app.
RIPE_QUANTILES = (0.20, 0.35, 0.55)
# Quantiles describing the full fruiting span, for display and for the
# "too early, come back later" case.
FRUIT_QUANTILES = (0.05, 0.90)

MIN_FRUIT_OBS = 5          # below this, no window is emitted at all
MIN_FLOWER_OBS = 8         # below this, fall back to the day-of-year model
CONFIDENCE_HALF = 12.0     # n at which data-sufficiency confidence reaches 0.5
CELL_DEG = 0.25            # ~25 km occurrence grid
ELEV_SNAP = 0.01           # must match add_elevation.SNAP
# Fruiting records landing more than this many days after the flowering peak are
# almost certainly persistent dried fruit rather than a fresh crop.
PERSISTENCE_CUTOFF_DAYS = 210

DAYS = 365.25


def doy(iso: str) -> int:
    d = datetime.strptime(iso, "%Y-%m-%d").date()
    return d.timetuple().tm_yday


def circular_mean_doy(days: np.ndarray) -> tuple[float, float]:
    """Return (mean day-of-year, resultant length R in 0..1).

    R measures how concentrated the season is: near 1 is a tight window, near 0
    means the observations are scattered around the whole year.
    """
    ang = 2 * np.pi * days / DAYS
    c, s = np.cos(ang).mean(), np.sin(ang).mean()
    mean = (np.arctan2(s, c) % (2 * np.pi)) * DAYS / (2 * np.pi)
    return float(mean), float(np.hypot(c, s))


def centered_offsets(days: np.ndarray, center: float) -> np.ndarray:
    """Signed distance from center in days, wrapped to [-182.6, +182.6].

    Lets us take ordinary quantiles of a circular quantity without the December
    to January discontinuity splitting a winter-fruiting season in two.
    """
    return (days - center + DAYS / 2) % DAYS - DAYS / 2


def wrap_doy(x: float) -> int:
    return int(round(x - 1) % 365 + 1)


def fit_taxon(fruit_days: np.ndarray, flower_days: np.ndarray) -> dict | None:
    if len(fruit_days) < MIN_FRUIT_OBS:
        return None

    _, R = circular_mean_doy(fruit_days)
    model = {
        "n_fruit": int(len(fruit_days)),
        "n_flower": int(len(flower_days)),
        "season_concentration": round(R, 3),
        # Data sufficiency only. Deliberately NOT mixed with concentration: a
        # genuinely long fruiting season is a real fact, not low confidence.
        "confidence": round(len(fruit_days) / (len(fruit_days) + CONFIDENCE_HALF), 3),
    }

    if len(flower_days) >= MIN_FLOWER_OBS:
        # Preferred path: measure fruiting in days elapsed since the flowering
        # peak, which is when fruit set begins. Flowering is transient and
        # heavily annotated, so this anchor is well determined.
        anchor, _ = circular_mean_doy(flower_days)
        offs = (fruit_days - anchor) % DAYS
        model["method"] = "flower_anchored"
        model["flower_peak_doy"] = wrap_doy(anchor)
        # Flowering span, for the timeline. Shown because "it is still in flower"
        # is the clearest possible signal that you are too early for seed.
        fl_offs = centered_offsets(flower_days, anchor)
        model["flower_start_doy"] = wrap_doy(anchor + float(np.quantile(fl_offs, 0.10)))
        model["flower_end_doy"] = wrap_doy(anchor + float(np.quantile(fl_offs, 0.90)))
        # What share of "fruits" records are stale dried fruit still hanging on
        # the plant? High values mean the ripe window is easy to overestimate.
        model["persistence"] = round(float((offs > PERSISTENCE_CUTOFF_DAYS).mean()), 3)
    else:
        # Fallback for taxa nobody annotates in flower: centre on the fruiting
        # distribution itself and accept the wider error.
        anchor, _ = circular_mean_doy(fruit_days)
        offs = centered_offsets(fruit_days, anchor) + DAYS / 2
        anchor -= DAYS / 2
        model["method"] = "doy_fallback"
        model["persistence"] = None
        model["confidence"] = round(model["confidence"] * 0.6, 3)

    r_start, r_peak, r_end = (float(np.quantile(offs, q)) for q in RIPE_QUANTILES)
    f_start, f_end = (float(np.quantile(offs, q)) for q in FRUIT_QUANTILES)
    model.update(
        fruit_start_doy=wrap_doy(anchor + f_start),
        fruit_end_doy=wrap_doy(anchor + f_end),
        ripe_start_doy=wrap_doy(anchor + r_start),
        ripe_peak_doy=wrap_doy(anchor + r_peak),
        ripe_end_doy=wrap_doy(anchor + r_end),
        ripe_window_days=int(round(r_end - r_start)),
    )
    if model["method"] == "flower_anchored":
        model["flower_to_ripe_days"] = int(round(r_peak))
    return model


def cell_key(lat: float, lng: float) -> str:
    return f"{int(np.floor(lat / CELL_DEG))},{int(np.floor(lng / CELL_DEG))}"


def elev_key(lat: float, lng: float) -> str:
    return f"{round(lat / ELEV_SNAP) * ELEV_SNAP:.2f},{round(lng / ELEV_SNAP) * ELEV_SNAP:.2f}"


def elevation_band(elevs: list[float]) -> dict | None:
    """Where a taxon actually fruits, vertically.

    Elevation turned out to be useless for correcting *timing* here: measured
    against this dataset, flowering shifts +0.60 d/100 m and fruiting +0.85, so
    the flower-to-fruit lag the model runs on shifts only +0.52 d/100 m with an
    interquartile range straddling zero. Anchoring on the flowering peak already
    absorbs the elevation effect, and a lapse term would double-count it. (The
    effect is weak in absolute terms too, which is unsurprising in a
    summer-dry Mediterranean climate where phenology tracks soil moisture more
    than heat accumulation.)

    It is very useful for deciding *whether a species is even present*: without
    this, a sea-level query in Santa Barbara returns montane species that happen
    to fall inside the search radius.
    """
    if len(elevs) < 3:
        return None
    a = np.array(elevs)
    return {
        "lo": int(np.percentile(a, 10)),
        "mid": int(np.median(a)),
        "hi": int(np.percentile(a, 90)),
    }


def build(rows_path: Path, out_path: Path, region: str, keep_enrichment: bool = True) -> dict:
    fruit: dict[int, list[int]] = defaultdict(list)
    flower: dict[int, list[int]] = defaultdict(list)
    cells: dict[int, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    elevs: dict[int, list[float]] = defaultdict(list)
    meta: dict[int, dict] = {}
    n_rows = 0

    elev_cache_path = rows_path.parent / "elevation.json"
    elev_cache: dict[str, float] = (
        json.loads(elev_cache_path.read_text()) if elev_cache_path.exists() else {}
    )
    if not elev_cache:
        print("no elevation cache found; run add_elevation.py for elevation filtering")

    with rows_path.open() as fh:
        for line in fh:
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue  # tolerate a torn last line from an in-flight fetch
            n_rows += 1
            tid = r["taxon_id"]
            meta.setdefault(
                tid,
                {"taxon_id": tid, "name": r["name"], "common": r["common"], "rank": r["rank"]},
            )
            d = doy(r["observed_on"])
            if "fruits" in r["phenology"]:
                fruit[tid].append(d)
                # Occurrence grid is built from fruiting records specifically:
                # we care where a taxon actually sets seed, not merely where it
                # has been photographed.
                cells[tid][cell_key(r["lat"], r["lng"])] += 1
                e = elev_cache.get(elev_key(r["lat"], r["lng"]))
                if e is not None:
                    elevs[tid].append(e)
            if "flowers" in r["phenology"]:
                flower[tid].append(d)

    taxa = []
    for tid, m in meta.items():
        model = fit_taxon(np.array(fruit[tid]), np.array(flower.get(tid, [])))
        if model is None:
            continue
        taxa.append(
            {**m, **model, "elevation": elevation_band(elevs[tid]), "cells": dict(cells[tid])}
        )

    # Carry over anything enrich_taxa.py added, so iterating on the model does
    # not mean re-fetching a photo for every taxon.
    if keep_enrichment and out_path.exists():
        prior = {t["taxon_id"]: t for t in json.loads(out_path.read_text())["taxa"]}
        carried = 0
        for t in taxa:
            old = prior.get(t["taxon_id"])
            if not old:
                continue
            for key in ("family", "sensitive", "status_codes", "establishment", "tips", "photos"):
                if key in old:
                    t[key] = old[key]
                    carried += key == "photos"
        print(f"carried enrichment forward for {carried:,} taxa")

    taxa.sort(key=lambda t: -t["n_fruit"])
    payload = {
        "schema_version": 1,
        "generated": date.today().isoformat(),
        "region": region,
        "cell_deg": CELL_DEG,
        "ripe_quantiles": list(RIPE_QUANTILES),
        # Measured, not assumed. See elevation_band() for why no timing
        # correction is applied despite elevation being available.
        "elevation_lapse_days_per_100m": 0.52,
        "elevation_lapse_note": "not applied; flower-anchoring already absorbs it",
        "source": "iNaturalist research-grade observations, controlled term 12",
        "taxa": taxa,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, separators=(",", ":")))
    print(
        f"{n_rows:,} observations -> {len(taxa):,} taxa with a fitted window "
        f"({len(meta):,} taxa seen) -> {out_path} "
        f"({out_path.stat().st_size / 1e6:.1f} MB)"
    )
    return payload


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--fresh", action="store_true",
                    help="discard prior enrichment instead of carrying it forward")
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    build(
        root / "data" / f"obs_{args.region}.jsonl",
        root / "web" / f"species_{args.region}.json",
        args.region,
        keep_enrichment=not args.fresh,
    )


if __name__ == "__main__":
    main()
