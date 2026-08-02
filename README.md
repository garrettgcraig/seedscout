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

## Fits are local, with a stated fallback

Phenology varies across a region far more than one pooled window can express. *Larrea tridentata*
peaks in June in the Mojave and September in the southern deserts; a single fit for coastal Southern
California reports late June and is wrong for everything south of it.

So space is cut into 2° tiles and each species is fitted separately inside each one. The tension is
sample size — a tile small enough to be climatically coherent is often too small to fit a season —
so every (species, tile) takes the finest fit its data supports, searching outward until it has
enough:

| level | fitted from | share (national) |
|---|---|---|
| `cell` | the tile itself | 8% |
| `block` | 3×3 tiles | 63% |
| `area` | 5×5 tiles | 19% |
| `wide` | 7×7 tiles | 9% |

The search is bounded on purpose. An earlier version fell back to "everything in the dataset",
which is defensible inside one coastal region and meaningless across a continent — at national
scale 45% of fits landed there, pooling Florida with Maine. A species that cannot be fitted within
seven tiles is now omitted rather than answered badly.

Anything coarser than `cell` carries a confidence penalty and is labelled on the card, so a window
borrowed from a wider area never passes as a local one.

Occurrence stays finer still: each species carries the ~25 km grid cells where it has been recorded
fruiting, plus the 10th–90th percentile elevation band of those records. The client combines the
two at query time — what grows near you, crossed with what is ripe now.

Against 10 species with well-documented Santa Barbara phenology, 8 of 10 modelled peaks fall inside
the documented collection window, against 7 of 10 for a single pooled regional fit.

The continental gradient comes out of the fits rather than being imposed on them. *Acer rubrum*
samara drop is modelled at Mar 6 in Tallahassee, Mar 28 in Charlotte, Apr 27 in New York and May 18
in Burlington — about five days per degree of latitude, which is roughly what red maple does. A
pooled national fit would return one date for all four.

## Elevation

Elevation filters **occurrence, not timing**. A species whose fruiting records sit between 2005 m
and 2651 m is not growing at the coast, and hiding it is the difference between a usable list and
one padded with montane plants that happen to fall inside the search radius.

It is deliberately not used to shift dates. Measured across 47 taxa with sufficient vertical spread
in this dataset, flowering shifts +0.60 days per 100 m and fruiting +0.85, so the flower-to-fruit
lag the model runs on shifts +0.52 with an interquartile range straddling zero. Anchoring on the
flowering peak already absorbs the effect, and a lapse term would double-count it.

## Native or introduced

Establishment is a local fact, not a species-level one, so it is resolved per tile the same way
phenology is. *Robinia pseudoacacia* is native to the Appalachians and introduced almost everywhere
else; asking whether it is "introduced in the United States" has no useful answer.

iNaturalist records establishment per place, and the native and introduced lists for a tile overlap
more than you would expect — 74 of Boston's species appear in both — because a few stray or
mislabelled records are enough to put a species on the wrong list. Observation counts therefore
decide, and only when one side outweighs the other threefold. Contested species resolve to `null`,
which the client shows rather than hides: silently dropping a good seed source is worse than
showing one the collector can judge.

Deciding on presence alone, as an earlier version did, put staghorn sumac at 10 introduced records
against 5,875 native ones in Massachusetts and hid it from the natives-only default. It is now the
top result there in late summer.

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
- **Most fits still borrow from beyond their own tile.** Only 8% of species-tile pairs clear the
  sample-size bar for a `cell` fit; the rest reach outward, and the 9% at `wide` are pooling across
  7×7 tiles. Those are labelled, but a wide fit still carries some of the problem tiling was built
  to solve. More observations, not better code, is what moves species up a level.
- **Tile edges are hard boundaries.** A species is fitted independently either side of a 2° line
  with no smoothing across it, so two points a kilometre apart on opposite sides of an edge can
  report different windows.
- **Windows are climatological averages.** There is no year-to-year adjustment, so a hot or late
  season shifts real phenology in ways the model will not see.
- **Observation density follows people, not plants.** Roadsides and popular trails are heavily
  over-represented relative to back country.
- **Metadata coverage is uneven.** 13,509 species carry family, status and a photo; handling notes
  reach 64% of species near Santa Barbara but 34% near Miami, because the curated tips are written
  by family and the eastern and subtropical floras are less well covered. Photo coverage runs
  68-95% depending on region. Every card states which scope its note came from.

- **The national dataset is truncated at 2020.** iNaturalist throttled the bulk pull at roughly a
  quarter of the way through, so the model is built from observations uploaded through 2020 plus a
  complete Southern California pull. Because records were fetched in id order the truncation is by
  upload date and not by geography, and day-of-year phenology is largely indifferent to which years
  it saw — but recent range shifts and newly popular species are under-represented.
- **Species whose fruit takes more than a year to mature break the flowering anchor.** Red oaks and
  witch-hazel set fruit that ripens a season or more after flowering, so measuring elapsed days from
  the flowering peak lands in the wrong part of the cycle. *Hamamelis virginiana* is modelled two
  months early for this reason.

## The app

A single HTML file plus a directory of JSON tiles. No build step, no framework, no server. The
client loads only the tiles its search circle touches — one for a 25 km search, four when a 100 km
radius straddles tile boundaries.

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
etl/build_model.py    single pooled fit per species -> web/species_<region>.json
etl/build_tiles.py    per-tile fits with fallback   -> web/tiles_<region>/  (what the app uses)
etl/enrich_taxa.py    family, native/introduced, conservation listings, seed photos, tips
etl/tips.json         hand-curated field guidance, by species / genus / family
web/index.html        the app
```

```bash
python3 etl/fetch_inat.py socal && python3 etl/add_elevation.py socal \
  && python3 etl/build_model.py socal && python3 etl/enrich_taxa.py socal \
  && python3 etl/build_tiles.py socal
python3 -m http.server 8731 --directory web
```

`enrich_taxa.py` writes `taxa_meta_<region>.json` alongside its output; `build_tiles.py` merges that
into every tile a species appears in, so photos and handling notes are fetched once per species
rather than once per tile.

Serve over http rather than opening the file directly — geolocation and `fetch` both need an origin.

`build_model.py` carries prior enrichment forward by default, so re-fitting does not re-fetch every
photo. Pass `--fresh` to discard it.

Regions are defined in `REGIONS` in the ETL scripts. `sbv` is Santa Barbara + Ventura counties
(~39k annotated observations, a few minutes). `socal` is coastal Southern California (~408k, around
half an hour).

## Data contract

`tiles_<region>/index.json` lists the tiles; each `tiles_<region>/<r>_<c>.json` is self-contained,
so a client renders from the tiles it loaded and nothing else. Versioned via `schema_version`
(currently 2). All dates are integer day-of-year, 1–365, and **wrap**: a window may have
`ripe_end_doy < ripe_start_doy`, so compute forward distance modulo 365 rather than comparing
directly.

```jsonc
// index.json
{
  "schema_version": 2,
  "generated": "2026-07-31",
  "region": "socal",
  "tile_deg": 2.0,               // tile size in degrees
  "cell_deg": 0.25,              // occurrence grid inside a tile
  "ripe_quantiles": [0.20, 0.35, 0.55],
  "fit_levels": {"cell": 798, "block": 1932, "region": 292},
  "tiles": [{"tile": [17, -60], "file": "17_-60.json", "taxa": 762}]
}

// 17_-60.json  — tile keyed by floor(lat/tile_deg), floor(lng/tile_deg)
{
  "schema_version": 2,
  "tile": [17, -60],
  "bounds": [34.0, -120.0, 36.0, -118.0],   // south, west, north, east
  "taxa": [{
    "taxon_id": 47603,
    "name": "Heteromeles arbutifolia",
    "common": "Toyon",
    "family": "Rosaceae",
    "fit_level": "cell",         // "cell" | "block" | "region" — how local the fit is
    "n_local": 378,              // fruiting records inside this tile
    "n_fruit": 538,              // records backing the fit at whatever level was used
    "n_flower": 127,
    "method": "flower_anchored", // or "doy_fallback" when flowering data is thin
    "flower_peak_doy": 183,
    "flower_start_doy": 107,
    "flower_end_doy": 254,
    "ripe_start_doy": 301,       // the collection window
    "ripe_peak_doy": 323,
    "ripe_end_doy": 348,
    "ripe_window_days": 47,
    "fruit_start_doy": 258,      // full fruiting span, for context
    "fruit_end_doy": 96,
    "persistence": 0.223,        // >0.3 means the window likely reads late
    "confidence": 0.978,         // data sufficiency, penalised for non-cell fits
    "season_concentration": 0.61,
    "sensitive": false,          // rare/listed — do not collect
    "status_codes": null,
    "establishment": "native",   // "native" | "introduced" | null if unlisted
    "elevation": {"lo": 11, "mid": 200, "hi": 567},  // 10th/50th/90th pct, metres
    "tips": {"cue": "…", "collect": "…", "handling": "…",
             "caution": "…", "scope": "species"},    // scope: species|genus|family
    "photos": [{"url": "…", "license": "cc-by-nc", "by": "…", "obs": 12345}],
    "cells": {"138,-480": 60}    // "floor(lat/cell_deg),floor(lng/cell_deg)": count
  }]
}
```

A species appearing in several loaded tiles will carry a different window in each. Resolve by
preferring the tile containing the query point, then the finest `fit_level`, then the largest
`n_local`.

`confidence` measures data sufficiency, scaled down for `block` and `region` fits. It is
deliberately not mixed with `season_concentration`: a genuinely long fruiting season is a fact about
the plant, not low confidence in the estimate.

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
