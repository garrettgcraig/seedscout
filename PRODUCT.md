# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

One product on two surfaces: a single-file web app (`web/index.html`, deployed at garrettgcraig.com/seedfinder) and a native SwiftUI iPhone app (`ios/`). Each follows its own platform's conventions; content, behavior, model outputs and wording match. Every change ships to both. When one surface can't take a change, say so explicitly instead of shipping it to one quietly.

## Users

Anyone who collects native seed and wants to know what is ripe where they are standing, today:

- restoration volunteers collecting local-ecotype seed for habitat projects, land trusts and native nurseries;
- native-plant gardeners gathering seed to propagate at home;
- agency and NGO botanists and seed-program crews planning collection trips;
- the author, Garrett Craig, as a working tool and as a portfolio piece for the modeling work.

The use scene is usually outdoors on a phone, often with weak or no signal, deciding in minutes whether a plant in front of them is worth collecting. Planning a trip at a desk (a place, a future date, a radius) is the secondary scene.

## Product Purpose

Given a place and a date, SeedFinder lists which native plants have collectible seed now, which are coming up in the next six weeks, and which were just missed. It then helps the collector recognize ripe fruit, find a plant, handle the seed, and track each lot through propagation.

Success over the next year is personal and portfolio: it works well for the author in the field, and it shows the modeling clearly. Outside users are welcome but are not the goal. No App Store launch is committed.

## Positioning

Seed-zone tools (USGS, USFS) answer where to source seed for a restoration site. USA-NPN models fruiting for a small set of species. Regional harvest charts are hand-curated and fixed. SeedFinder answers the field question instead: standing here, today, what is ready?

What makes that possible is the model. Ripe windows are fitted from iNaturalist fruiting records measured as days since each species' local flowering peak, separately for every 2° tile, with stated fallback levels. The windows come from the data, not from a hand-built calendar.

## Operating Context

- Outdoors on a phone, often without signal. iOS bundles the whole dataset (read-only SQLite, about 77 MB), so Find, species detail, cautions and records work offline. Photos, the basemap, place search and observation maps need a connection.
- At a desk, planning with a future date and a 10–100 km radius.
- At home or in a nursery, months later, when stratification falls due and seed lots move to pots and then into the ground.
- Records never leave the device. The web app uses localStorage plus IndexedDB for photos; iOS uses private app files. CSV and JSON export; iOS imports web exports, and the web app has no import.

## Capabilities and Constraints

- **Find seed:** place by name (Nominatim, US only), map tap, pin drag or geolocation; any date; radius of 10, 25, 50 or 100 km. Results are grouped Collectible now / Coming up (next 6 weeks) / Just missed, and ranked by closeness to the modeled peak, local abundance and confidence. Family filter shows counts, there is a favorites filter, natives only is the default, and there are three sorts. A search that finds nothing explains why: hidden by filters, grows elsewhere (with distance and direction), or not in the dataset.
- **Species detail:** a full-year timeline (flowering, fruiting, ripe window, selected date); CC-licensed photos taken inside the ripe window, with attribution; handling notes resolved species, then genus, then family, labeled by level; an observation map of research-grade sightings from all dates, loaded 100 at a time.
- **Records and propagation:** quick collection logging; treatment batches with allocated seed counts; storage, scarification, stratification, sowing and germination steps; computed stratification due dates and germination rates; photos at five stages; CSV export that carries days from the modeled peak, the value needed to recalibrate the model.
- **Model terms the interface uses:** ripe window (20th–55th percentile of fruiting records after the flowering peak, peak at the 35th); fit level `cell` / `block` / `area` / `wide`; confidence; `doy_fallback`; persistence; per-tile native status (3× record margin; contested species resolve to unknown and are shown, not hidden).
- **Known limits that must stay visible to users rather than be hidden:** ripe percentiles are calibrated on nine species; persistent-fruit species read late; windows over 100 days are flagged and windows over 200 are dropped; most fits borrow from beyond their own tile; tile edges are hard boundaries; windows are climatological averages with no adjustment for the year; the national pull is truncated at 2020 uploads; species with multi-year fruit maturation break the flowering anchor.
- **Stack (existing):** no build step, no framework, no server. One HTML file, JSON tiles fetched per search circle, Leaflet with CARTO basemaps from a CDN. Python ETL in `etl/`. iOS is SwiftUI with a project generated by `ios/make_project.py`.
- **Undecided:** App Store release; any account or sync; sharing collection dates back to recalibrate the model.

## Brand Commitments

- Name: **SeedFinder**. It was renamed from SeedScout, which collides with an unrelated service; never reintroduce the old name in copy.
- Voice: plain, field-practical and honest about uncertainty. Cards say how local a fit is and why a caution applies. American English spelling throughout.
- Type: Fraunces for display and Inter for text, self-hosted on web and bundled on iOS. Never the platform default faces.
- Standing interface rules from the author: no monospace numbers (especially dotted-zero mono), no uppercase letter-spaced eyebrow labels, and no pill badges. Facts go on a plain sans line with tabular figures.
- Icon: a pine cone app icon exists in the iOS asset catalog.

## Evidence on Hand

- 6,346,718 iNaturalist observations, 1,262,968 of them fruiting; 7,542 species modeled across the contiguous US.
- Santa Barbara check: 8 of 10 modeled peaks fall inside the documented collection window, against 7 of 10 for one pooled regional fit.
- The latitudinal gradient emerges unforced: *Acer rubrum* samara drop is modeled at Mar 6 in Tallahassee, Mar 28 in Charlotte, Apr 27 in New York and May 18 in Burlington.
- Staghorn sumac, once hidden as non-native in Massachusetts, is now the top late-summer result there after the per-tile native rule.
- Product requirements: Claude Doc "SeedFinder — Product Requirements" (overview plus six feature PRDs).
- None exist, so never fabricate: testimonials, named partner organizations, user counts, App Store ratings, press.

## Product Principles

1. **Say how sure we are.** Every window carries its fit level and confidence, and known limits surface on the card where they apply. Never present a borrowed or weak fit as local and solid.
2. **Do no harm to the plants.** Natives are the default. Rare and listed species are flagged do-not-collect and down-ranked. Permits and the 30-plants / 30%-of-seed rule stay in front of the user.
3. **The field case first.** Answers arrive offline, fast and readable on a phone in sunlight. Nothing essential depends on a network path.
4. **One product, two native surfaces.** Web and iOS stay in step on behavior and wording, and each feels at home on its own platform.
5. **Explain, don't empty.** An empty list always says why and what to try next.

## Accessibility & Inclusion

Tabs, cards and controls work by keyboard, with visible focus. Result changes are announced through a live region. The web app respects reduced motion. Text stays at 11px or larger, with month initials on the timeline axis as the one deliberate exception. Outdoor use on phones makes contrast and touch-target size matter more than usual.
