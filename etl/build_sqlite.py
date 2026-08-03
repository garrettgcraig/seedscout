"""Compile the JSON tiles into a single read-only SQLite database for the iOS app.

The web client fetches a tile and parses ~1.3 MB of JSON per move. That is the
wrong shape for a native app: JSON parsing is pure CPU on the main actor, it
allocates the whole payload whether or not you need it, and it has to happen
again every time the user pans across a tile boundary.

A bundled SQLite file avoids all of it. The database is memory-mapped, so pages
are faulted in only as queries touch them; lookups go through B-tree indexes
instead of a linear scan over a decoded array; and there is no parse step at all,
so a cold start is an mmap rather than a multi-megabyte decode. It also ships
inside the app, which means the field case - no signal, standing in a canyon -
works with no network path to fail.

Species search uses FTS5 rather than scanning names in Swift.

The file is read-only at runtime. User records live in a separate writable
database so an app update can replace this one wholesale without touching them.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import time
from pathlib import Path

SCHEMA = """
PRAGMA journal_mode = OFF;
PRAGMA page_size = 4096;

CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

-- One row per species. Everything here is geography-independent, so it is
-- stored once rather than repeated in every tile the species appears in (the
-- JSON tiles duplicate it; that trade made sense for HTTP, not for a bundle).
CREATE TABLE taxon (
  taxon_id     INTEGER PRIMARY KEY,
  name         TEXT NOT NULL,
  common       TEXT,
  family       TEXT,
  sensitive    INTEGER NOT NULL DEFAULT 0,
  status_codes TEXT,
  tip_scope    TEXT,
  tip_cue      TEXT,
  tip_collect  TEXT,
  tip_handling TEXT,
  tip_caution  TEXT
);

CREATE TABLE photo (
  taxon_id INTEGER NOT NULL REFERENCES taxon(taxon_id),
  url      TEXT NOT NULL,
  license  TEXT,
  credit   TEXT,
  obs_id   INTEGER,
  kind     TEXT NOT NULL DEFAULT 'seed-window',
  ord      INTEGER NOT NULL DEFAULT 0
);

-- One row per (species, tile): the fitted window for that species in that
-- place. This is the table the main query joins against.
CREATE TABLE fit (
  tile_r        INTEGER NOT NULL,
  tile_c        INTEGER NOT NULL,
  taxon_id      INTEGER NOT NULL REFERENCES taxon(taxon_id),
  ripe_start    INTEGER NOT NULL,
  ripe_peak     INTEGER NOT NULL,
  ripe_end      INTEGER NOT NULL,
  ripe_days     INTEGER NOT NULL,
  fruit_start   INTEGER,
  fruit_end     INTEGER,
  flower_peak   INTEGER,
  flower_start  INTEGER,
  flower_end    INTEGER,
  persistence   REAL,
  confidence    REAL NOT NULL,
  method        TEXT,
  fit_level     TEXT NOT NULL,
  n_local       INTEGER NOT NULL,
  n_fruit       INTEGER,
  establishment TEXT,
  elev_lo       INTEGER,
  elev_mid      INTEGER,
  elev_hi       INTEGER,
  PRIMARY KEY (tile_r, tile_c, taxon_id)
) WITHOUT ROWID;

-- Occurrence grid, ~25 km cells. Answers "does this grow near me" independently
-- of the coarser tile the phenology was fitted in.
CREATE TABLE cell (
  cell_r   INTEGER NOT NULL,
  cell_c   INTEGER NOT NULL,
  taxon_id INTEGER NOT NULL,
  tile_r   INTEGER NOT NULL,
  tile_c   INTEGER NOT NULL,
  n        INTEGER NOT NULL
);
"""

# Built after the bulk insert: maintaining indexes during a 1.5M row load is
# markedly slower than creating them once at the end.
INDEXES = """
CREATE INDEX cell_rc ON cell(cell_r, cell_c);
CREATE INDEX photo_taxon ON photo(taxon_id, ord);
CREATE INDEX fit_taxon ON fit(taxon_id);

CREATE VIRTUAL TABLE taxon_fts USING fts5(
  name, common, content='taxon', content_rowid='taxon_id', tokenize='unicode61'
);
INSERT INTO taxon_fts(rowid, name, common)
  SELECT taxon_id, name, IFNULL(common, '') FROM taxon;
INSERT INTO taxon_fts(taxon_fts) VALUES('optimize');
"""


def build(tile_dir: Path, out_path: Path) -> None:
    index = json.loads((tile_dir / "index.json").read_text())
    if out_path.exists():
        out_path.unlink()

    db = sqlite3.connect(out_path)
    db.executescript(SCHEMA)

    taxa: dict[int, dict] = {}
    fits: list[tuple] = []
    cells: list[tuple] = []
    photos: list[tuple] = []
    started = time.monotonic()

    for i, entry in enumerate(index["tiles"]):
        blob = json.loads((tile_dir / entry["file"]).read_text())
        tr, tc = blob["tile"]
        for t in blob["taxa"]:
            tid = t["taxon_id"]
            if tid not in taxa:
                tip = t.get("tips") or {}
                taxa[tid] = (
                    tid, t["name"], t.get("common"), t.get("family"),
                    1 if t.get("sensitive") else 0,
                    ",".join(t["status_codes"]) if t.get("status_codes") else None,
                    tip.get("scope"), tip.get("cue"), tip.get("collect"),
                    tip.get("handling"), tip.get("caution"),
                )
                for ord_, p in enumerate(t.get("photos") or []):
                    photos.append((tid, p["url"], p.get("license"), p.get("by"),
                                   p.get("obs"), p.get("kind", "seed-window"), ord_))

            elev = t.get("elevation") or {}
            fits.append((
                tr, tc, tid,
                t["ripe_start_doy"], t["ripe_peak_doy"], t["ripe_end_doy"],
                t.get("ripe_window_days", 0),
                t.get("fruit_start_doy"), t.get("fruit_end_doy"),
                t.get("flower_peak_doy"), t.get("flower_start_doy"), t.get("flower_end_doy"),
                t.get("persistence"), t.get("confidence", 0.0),
                t.get("method"), t.get("fit_level", "region"),
                t.get("n_local", 0), t.get("n_fruit"),
                t.get("establishment"),
                elev.get("lo"), elev.get("mid"), elev.get("hi"),
            ))
            for key, n in (t.get("cells") or {}).items():
                cr, cc = key.split(",")
                cells.append((int(cr), int(cc), tid, tr, tc, n))
        if (i + 1) % 50 == 0:
            print(f"\r  {i + 1}/{len(index['tiles'])} tiles", end="", flush=True)

    print(f"\r  {len(index['tiles'])} tiles read in {time.monotonic() - started:.1f}s")

    db.executemany("INSERT INTO taxon VALUES (?,?,?,?,?,?,?,?,?,?,?)", taxa.values())
    db.executemany("INSERT INTO photo VALUES (?,?,?,?,?,?,?)", photos)
    db.executemany(f"INSERT INTO fit VALUES ({','.join('?' * 22)})", fits)
    db.executemany("INSERT INTO cell VALUES (?,?,?,?,?,?)", cells)
    for k in ("schema_version", "generated", "region", "tile_deg", "cell_deg"):
        if k in index:
            db.execute("INSERT INTO meta VALUES (?,?)", (k, str(index[k])))
    db.execute("INSERT INTO meta VALUES ('app_schema','1')")
    db.commit()

    print("  building indexes and FTS")
    db.executescript(INDEXES)
    db.commit()
    # Pack the file: the app never writes to it, so leaving free pages around
    # only costs download size.
    db.execute("VACUUM")
    db.execute("ANALYZE")
    db.commit()
    db.close()

    mb = out_path.stat().st_size / 1e6
    print(f"\ndone: {len(taxa):,} taxa, {len(fits):,} fits, {len(cells):,} cells, "
          f"{len(photos):,} photos -> {out_path.name} ({mb:.1f} MB)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("region")
    ap.add_argument("--out", type=Path, default=None)
    args = ap.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = args.out or root / "ios" / "SeedScout" / "Resources" / f"seedscout_{args.region}.sqlite"
    out.parent.mkdir(parents=True, exist_ok=True)
    build(root / "web" / f"tiles_{args.region}", out)


if __name__ == "__main__":
    main()
