# SeedScout

Given a place and a date, which native plants have collectible seed right now?

Live at **[garrettgcraig.com/seedscout](https://garrettgcraig.com/seedscout/)**.

Seed-zone tools ([USGS](https://www.usgs.gov/apps/seed-toolkit/),
[USFS](https://research.fs.usda.gov/pnw/products/dataandtools/seed-zone-webmap)) answer *where* to
source seed for a restoration site. [USA-NPN](https://www.usanpn.org/data/maps) models fruit
ripening for a small set of species as gridded maps. Regional harvest charts are hand-curated and
fixed. SeedScout answers the field question instead: standing here, today, what is ready?

## How the window is modelled

iNaturalist's controlled term 12 carries a value "Fruits or Seeds". It spans green fruit through
dehiscence and does not mean *ripe*, so the peak of a species' fruiting records is not its
collection date.

Each fruiting record is therefore measured as **days elapsed since that species' flowering peak**
rather than as a day of year. Fruit follows flowers, so this runs the season along the axis the
biology actually uses, and it keeps species whose dried fruit persists for months
(*Malosma*, *Eriogonum*, *Baccharis*) from smearing across the calendar. The ripe window is taken
as the 20th–55th percentile of that distribution, with the peak at the 35th.

Species with too few flowering records fall back to a day-of-year fit and are marked
`doy_fallback`, which carries a confidence penalty.

Two quantities are kept separate:

- **Phenology is regional.** Per-cell sample sizes are far too thin to fit a season, so the window
  is pooled across the region.
- **Occurrence is local.** Each species carries the ~25 km grid cells where it has been recorded
  fruiting, plus the 10th–90th percentile elevation band of those records.

The client combines them at query time: what grows near you, crossed with what is ripe now.

Against 10 species with well-documented Santa Barbara phenology, 8 of 10 modelled peaks fall inside
the documented collection window. Median window width is 45 days.

## Elevation

Elevation filters **occurrence, not timing**. A species whose fruiting records sit between 2005 m
and 2651 m is not growing at the coast, and hiding it is the difference between a usable list and
one padded with montane plants that happen to fall inside the search radius.

It is deliberately not used to shift dates. Measured across 47 taxa with sufficient vertical spread
in this dataset, flowering shifts +0.60 days per 100 m and fruiting +0.85, so the flower-to-fruit
lag the model runs on shifts +0.52 with an interquartile range straddling zero. Anchoring on the
flowering peak already absorbs the effect, and a lapse term would double-count it.

## Known limits

- **`RIPE_QUANTILES` is calibrated against nine species.** It is the first thing to revisit when
  field observation disagrees with the app.
- **Persistent-fruit species read late.** `persistence` — the share of fruiting records landing more
  than 210 days after the flowering peak — flags this per species. Above ~0.3, distrust the window
  and judge by the condition of the fruit cluster instead.
- **20% of fitted windows are too wide to act on.** Median width is 45 days, but 11% exceed 100 days
  and 9% exceed 200. These are fits that failed rather than long seasons, typically species that
  flower near year-round so the flowering anchor carries no information. The client tags the former
  and drops the latter.
- **One window is fitted per species for the whole region, and that over-pools.** Splitting the
  current region at Los Angeles and fitting north and south separately, 50% of well-sampled species
  disagree by more than 14 days and 21% by more than 30. *Larrea tridentata* peaks in June in the
  Mojave and November in the southern deserts — 165 days apart — while the pooled fit reports late
  June and is simply wrong for southern populations. Species whose range spans a strong climate
  gradient should be read with this in mind; fitting per sub-region is the fix.
- **Windows are climatological averages.** There is no year-to-year adjustment, so a hot or late
  season shifts real phenology in ways the model will not see.
- **Observation density follows people, not plants.** Roadsides and popular trails are heavily
  over-represented relative to back country.
- **Handling notes are hand-written and partial.** 165 of 228 species resolve to a note, many only
  at family level; each card states which. They are not a substitute for a propagation manual.

## The app

A single HTML file plus a JSON model. No build step, no framework, no server.

- **Find seed** — set a location by tapping the map, dragging the pin, or using device geolocation;
  the search radius is drawn as a circle. Species are grouped into *collectible now*, *coming up*,
  and *just missed*, ranked by proximity to the modelled peak, local abundance, and confidence.
- **Timeline** — every species shows a full-year bar: flowering period, fruiting period, ripe
  window, and the selected date.
- **Photos** — CC-licensed iNaturalist images pulled from observations *inside* each ripe window, so
  they show fruit rather than flowers. Attribution and licence travel with each image.
- **Handling notes** — how to tell ripeness, collection technique, and post-collection treatment,
  resolved species → genus → family.
- **Guards** — non-natives are filtered out by default; rare and listed species are flagged
  *do not collect* and down-ranked; the 30-plants / 30%-of-seed rule and permit requirements are
  stated up front.

Leaflet and CARTO basemaps are loaded from a CDN for the map. If they are unavailable, the map is
replaced by manual coordinate entry and everything else works unchanged.

## Records and propagation

The second tab tracks a seed lot from the field to the garden.

**Collection** — species, date, location, elevation, quantity, notes.

**Propagation** — storage, scarification, stratification, sowing, and germination. Two things are
computed rather than stored:

- **Stratification due dates.** A lot reads `stratifying · 40 d left`, then flips to `ready to sow`
  and appears under *Needs attention*. This is the step that gets missed, because it falls due
  months after the work that starts it.
- **Germination rate** — seedlings over seeds sown, and days to first germination.

**Photos** — camera capture at each stage: the parent plant, cleaned seed, first pot, seedlings, and
final planting location. Images are downscaled to 1400 px and stored in IndexedDB.

Each lot surfaces its species' handling note inline, so a toyon lot shows *"Cold-moist stratify 1–3
months"* directly above the stratification fields.

Records live in `localStorage` and photos in IndexedDB, both browser-local and never uploaded.
Export to CSV or JSON. The CSV carries the full propagation schedule alongside `modelled_peak_doy`
and `days_from_peak`; that signed offset is the ground truth needed to recalibrate `RIPE_QUANTILES`.

## Layout

```
etl/fetch_inat.py     cursor-paginated pull of annotated observations -> JSONL (resumable)
etl/add_elevation.py  elevation per ~1 km grid point, cached (resumable)
etl/build_model.py    fits the per-taxon window -> web/species_<region>.json
etl/enrich_taxa.py    family, native/introduced, conservation listings, seed photos, tips
etl/tips.json         hand-curated field guidance, by species / genus / family
web/index.html        the app
```

```bash
python3 etl/fetch_inat.py sbv && python3 etl/add_elevation.py sbv \
  && python3 etl/build_model.py sbv && python3 etl/enrich_taxa.py sbv
python3 -m http.server 8731 --directory web
```

Serve over http rather than opening the file directly — geolocation and `fetch` both need an origin.

`build_model.py` carries prior enrichment forward by default, so re-fitting does not re-fetch every
photo. Pass `--fresh` to discard it.

Regions are defined in `REGIONS` in the ETL scripts. `sbv` is Santa Barbara + Ventura counties
(~39k annotated observations, a few minutes). `socal` is coastal Southern California (~408k, around
half an hour).

## Data contract

`species_<region>.json` is the interface between the pipeline and any client, versioned via
`schema_version`. All dates are integer day-of-year, 1–365, and **wrap**: a window may have
`ripe_end_doy < ripe_start_doy`. Compute forward distance modulo 365 rather than comparing directly.

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
    "flower_start_doy": 107,     // flowering span, for the timeline
    "flower_end_doy": 254,
    "ripe_start_doy": 301,       // the collection window
    "ripe_peak_doy": 323,
    "ripe_end_doy": 348,
    "ripe_window_days": 47,
    "fruit_start_doy": 258,      // full fruiting span, for context
    "fruit_end_doy": 96,
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

`confidence` measures data sufficiency only. It is deliberately not mixed with
`season_concentration`: a genuinely long fruiting season is a fact about the plant, not low
confidence in the estimate.

`by` and `license` must travel with any displayed photo.

## Roadmap

- **National coverage.** `conus`, `alaska`, and `hawaii` regions are defined in the ETL. CONUS is
  ~6.3 million annotated observations, roughly nine hours of paging; the fetch is resumable, so
  re-running the same command after an interruption continues from the last observation id.
  Reaching national scale needs two changes beyond a wider bounding box: phenology fitted per
  species *per sub-region* rather than pooled (see Known limits), and the model emitted as spatial
  tiles with the client loading only nearby ones, since a single national payload would be tens of
  megabytes.
- **Ground-truth calibration.** Export the record CSV and refit `RIPE_QUANTILES` against
  `days_from_peak`, ideally per fruit type. Fleshy, dry-dehiscent, and dry-persistent almost
  certainly want different values; family is already in the payload as a rough proxy.
- **Growing-degree-day anchoring** via Daymet or PRISM, so windows shift with an early or late year
  instead of resting on a climatological average.
- **Offline tile caching** and a service worker, so the map works without signal in the field.
- **iOS client** against the same `species_<region>.json`.

## Collection ethics

Collect only from populations of 30+ plants, never more than 30% of available seed, never from
listed taxa, and never without landowner or agency permission — collection is prohibited in most
parks and preserves without a permit. Species flagged `sensitive` are down-ranked and marked
*do not collect*.

Observation data from [iNaturalist](https://www.inaturalist.org), research-grade only.
