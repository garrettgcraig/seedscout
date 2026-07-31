# SeedScout

Given a place and a date, what native plants have collectible seed right now?

No existing tool answers that. Seed-zone maps ([USGS](https://www.usgs.gov/apps/seed-toolkit/),
[USFS](https://research.fs.usda.gov/pnw/products/dataandtools/seed-zone-webmap)) answer *where* to
source seed but say nothing about timing. [USA-NPN](https://www.usanpn.org/data/maps) models fruit
ripening for a small set of species as gridded maps. Regional harvest charts are hand-curated and
fixed. Seeds of Success crews do this reasoning as field craft, not software.

This builds the missing piece from iNaturalist phenology annotations.

## The core problem

iNaturalist's controlled term 12 has a value "Fruits or Seeds". **It does not mean ripe.** One
annotation covers green fruit through dehiscence, so the naive approach — histogram the fruiting
records by month, take the peak — tells you to collect weeks early.

The first attempt here took the *trailing* quantiles of the day-of-year fruiting distribution, on
the theory that mature seed sits near the end of the fruiting span. That was worse than it looked.
It works for fleshy fruit that gets eaten or drops quickly, and fails badly for anything whose dry
fruit persists on the plant: laurel sumac (*Malosma laurina*) generates "fruits" annotations all
winter from dried drupes, and the model put its ripe window in **March — five months late.**

The fix is a change of coordinates. Fruit always follows flowers, so each fruiting record is
measured as **days elapsed since that taxon's flowering peak** rather than as a day of year. This
linearizes the season along the axis the biology actually runs on and removes the December/January
wrap that was smearing persistent-fruit species across the calendar.

Validated against 10 species with well-documented Santa Barbara phenology:

| | day-of-year model | flower-anchored model |
|---|---|---|
| peak lands in documented window | 6/10 | **8/10** |
| median window width | ~130 days | **~47 days** |

The two remaining misses are the two species with the highest `persistence` score, and the third
weakest case has n=5 with `confidence` 0.29 — the model flags its own failures, which is the
property that matters most for a field tool.

## Elevation: a negative result worth recording

The obvious next move was an elevation correction — phenology runs later at altitude, and Hopkins'
bioclimatic law puts it around +3.3 days per 100 m. Measured against this dataset, across 47 taxa
with enough vertical spread:

| measured on | days per 100 m | IQR | share positive |
|---|---|---|---|
| flowering day-of-year | +0.60 | −1.55 to +2.92 | 55% |
| fruiting day-of-year | +0.85 | −0.36 to +3.29 | 66% |
| **flower → fruit lag** | **+0.52** | −5.04 to +2.92 | 55% |

The lag the model actually runs on is elevation-insensitive, because flowering and fruiting shift
together — **anchoring on the flowering peak already absorbs the elevation effect**, and adding a
lapse term would double-count it. The absolute effect is weak here too, which is unsurprising in a
summer-dry Mediterranean climate where phenology tracks soil moisture more than heat accumulation.

So elevation is used for **occurrence filtering, not timing**: each taxon carries the 10th–90th
percentile elevation band of its fruiting records, and the client hides species whose band excludes
your elevation. Without it, a sea-level Santa Barbara query returned montane snowplant
(*Sarcodes sanguinea*, 2005–2651 m) simply because it fell inside the search radius.

## Known limits

- **`RIPE_QUANTILES` is calibrated on nine species.** It is the first thing to revisit when field
  observation disagrees with the app. This is a starting point, not a fitted parameter.
- **Persistent-fruit taxa still read late.** `persistence` (share of fruiting records landing >210
  days after the flowering peak) surfaces this per species; anything above ~0.3 deserves suspicion.
- **20% of fitted windows are too wide to act on.** Median width is 45 days, but 11% exceed 100 days
  and 9% exceed 200. These are fit failures rather than long seasons — typically species that flower
  near year-round, which leaves the flowering anchor meaningless. The client tags the former and
  drops the latter.
- **No year-to-year adjustment.** Windows are climatological averages. A hot or late year shifts
  real phenology and the model will not know. See the GDD note below.
- **Observation bias.** iNaturalist density follows people, not plants — roadsides and popular
  trails are heavily over-represented relative to the backcountry.
- **Handling notes are hand-written and partial.** 165 of 228 species resolve to a tip, many only at
  family level (the card says which). They are not a substitute for a propagation manual.

## Layout

```
etl/fetch_inat.py     cursor-paginated pull of annotated observations -> JSONL (resumable)
etl/add_elevation.py  elevation per ~1 km grid point, cached (resumable)
etl/build_model.py    fits the per-taxon window -> web/species_<region>.json
etl/enrich_taxa.py    family, native/introduced, conservation listings, seed photos, tips
etl/tips.json         hand-curated field guidance, by species / genus / family
web/index.html        single-file mobile client, no dependencies
```

```bash
python3 etl/fetch_inat.py sbv && python3 etl/add_elevation.py sbv \
  && python3 etl/build_model.py sbv && python3 etl/enrich_taxa.py sbv
```

`build_model.py` carries prior enrichment forward by default, so re-fitting the model does not mean
re-fetching 228 photos. Pass `--fresh` to discard it.

Then serve `web/` over http (geolocation and `fetch` both need a real origin):

```bash
python3 -m http.server 8731 --directory web
```

Regions are defined in `REGIONS` in the ETL scripts. `sbv` is Santa Barbara + Ventura (~39k
annotated observations, a few minutes to pull). `socal` is the full coastal Southern California
region (~408k, roughly half an hour).

## Data contract

`species_<region>.json` is the seam between the pipeline and any client, and is versioned via
`schema_version` so the planned iOS app can decode the same payload the web client does. All dates
are integer day-of-year, 1–365, and **wrap**: a window may have `ripe_end_doy < ripe_start_doy`.
Compute forward distance modulo 365 rather than comparing directly.

```jsonc
{
  "schema_version": 1,
  "generated": "2026-07-31",
  "region": "sbv",
  "cell_deg": 0.25,              // occurrence grid size in degrees
  "ripe_quantiles": [0.20, 0.35, 0.55],
  "taxa": [{
    "taxon_id": 47603,           // iNaturalist taxon id
    "name": "Heteromeles arbutifolia",
    "common": "Toyon",
    "family": "Rosaceae",
    "n_fruit": 538,              // fruiting records backing the window
    "n_flower": 127,
    "method": "flower_anchored", // or "doy_fallback" when flowering data is thin
    "flower_peak_doy": 183,
    "ripe_start_doy": 301,       // the collection window
    "ripe_peak_doy": 323,
    "ripe_end_doy": 348,
    "ripe_window_days": 47,
    "fruit_start_doy": 258,      // full fruiting span, for context
    "fruit_end_doy": 96,
    "flower_start_doy": 107,     // flowering span, for the timeline
    "flower_end_doy": 254,
    "persistence": 0.223,        // >0.3 means the window likely reads late
    "confidence": 0.978,         // data sufficiency only, n/(n+12)
    "season_concentration": 0.61,
    "sensitive": false,          // rare/listed — do not collect
    "status_codes": null,
    "establishment": "native",   // "native" | "introduced" | null if unlisted
    "elevation": {"lo": 2, "mid": 200, "hi": 569},   // 10th/50th/90th pct, metres
    "tips": {"cue": "…", "collect": "…", "handling": "…",
             "caution": "…", "scope": "species"},    // scope: species|genus|family
    "photos": [{"url": "…", "license": "cc-by-nc", "by": "…", "obs": 12345}],
    "cells": {"138,-480": 60}    // "floor(lat/cell_deg),floor(lng/cell_deg)": count
  }]
}
```

Photos are CC-licensed and drawn from observations annotated as fruiting **inside** the modelled
ripe window, so they show seed rather than flowers. `by` and `license` must travel with the image
wherever it is displayed.

Occurrence is local, phenology is regional. Per-cell sample sizes are far too thin to fit a season
but are plenty to answer "does this grow near me", so `cells` carries the spatial signal and the
window is pooled across the region. The client combines them at query time.

`confidence` is deliberately *not* mixed with `season_concentration`. A genuinely long fruiting
season is a real fact about a plant, not low confidence in the estimate.

## Collection records and propagation

The client's second tab tracks a seed lot from the field through to seedlings:

**Collection** — species, date, GPS, elevation (resolved automatically), quantity, notes.

**Propagation** — storage method and date, scarification, stratification (method, start, duration),
sowing (date, count, medium), and germination (date, count). The panel is edited in place and saves
on every change, because a half-filled propagation record is the normal state for months at a time.

Two things it computes rather than stores:

- **Stratification due dates.** A lot stratifying shows `stratifying · 40 d left`; once the clock
  runs out it flips to `ready to sow` and the lot is listed under **Needs attention** at the top of
  the tab. This is the step people forget, because it comes due months after the work that started
  it.
- **Germination rate**, seedlings over seeds sown, plus days from sowing to first germination.

Each lot's panel also surfaces the species' handling note from `tips.json` inline — so a toyon lot
shows *"Cold-moist stratify 1–3 months"* directly above the stratification fields.

Records live in `localStorage` only — nothing is uploaded — and export to CSV or JSON. The CSV
carries the full propagation schedule plus `modelled_peak_doy` and `days_from_peak`. That signed
offset is precisely the ground truth the model needs, so the logging feature and the calibration
problem are the same feature. Enough records and `RIPE_QUANTILES` stops being a guess.

Germination outcomes are the second, longer feedback loop: a lot collected well before or after the
modelled peak that then germinates poorly is direct evidence the window is wrong for that species.

## Next

- **Ground-truth calibration.** The highest-value work by a wide margin. Export the record CSV and
  refit `RIPE_QUANTILES` against `days_from_peak`, ideally per fruit type.
- **Fruit-type stratification.** Fleshy vs dry-dehiscent vs dry-persistent almost certainly want
  different quantiles; family is already in the payload as a rough proxy.
- **Growing-degree-day anchoring.** Convert day-of-year to accumulated GDD via Daymet or PRISM so
  windows shift correctly in a hot or late year and transfer across elevation. This is what would
  make the tool genuinely better than a static chart rather than merely more automated.
- **iOS client** against the same `species_<region>.json`, bundled for offline use in the field.

## Collection ethics

The client enforces what it can and states the rest: collect only from populations of 30+ plants,
never more than 30% of available seed, never from listed taxa, and never without landowner or
agency permission — collection is prohibited in most parks and preserves without a permit. Species
flagged `sensitive` are down-ranked and marked *do not collect*.

Data from [iNaturalist](https://www.inaturalist.org), research-grade observations only.
