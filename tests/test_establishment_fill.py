"""python3 tests/test_establishment_fill.py"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "etl"))
from establishment_fill import apply  # noqa: E402


def taxon(tid, name, est):
    return {"taxon_id": tid, "name": name, **({"establishment": est} if est else {})}


tiles = {
    "a": [taxon(1, "Lonicera japonica", "introduced"), taxon(2, "Quercus agrifolia", "native"),
          taxon(3, "Phytolacca americana", "native"), taxon(10, "Vicia villosa", "introduced"),
          taxon(556361, "Phragmites australis australis", None)],
    "b": [taxon(1, "Lonicera japonica", None), taxon(2, "Quercus agrifolia", None),
          taxon(3, "Phytolacca americana", "introduced"), taxon(4, "Phytolacca americana rigida", None),
          taxon(11, "Vicia villosa varia", None), taxon(5, "Unlisted native", None)],
    "c": [taxon(3, "Phytolacca americana", None), taxon(556361, "Phragmites australis australis", "native")],
}
apply(tiles)
get = lambda tile, tid: next(t for t in tiles[tile] if t["taxon_id"] == tid)

# Introduced wherever listed, native nowhere: unknowns become introduced.
assert get("b", 1)["establishment"] == "introduced" and "native nowhere" in get("b", 1)["establishment_basis"]
# Native somewhere: unknowns stay unknown.
assert "establishment" not in get("b", 2)
# Contested species (native in one tile, introduced in another): untouched.
assert "establishment" not in get("c", 3)
# Subspecies of a contested species: no inheritance.
assert "establishment" not in get("b", 4)
# Unlisted variety of an introduced-only species inherits.
assert get("b", 11)["establishment"] == "introduced" and "inherits" in get("b", 11)["establishment_basis"]
# No listing anywhere and no parent: left unknown (usually an unlisted native).
assert "establishment" not in get("b", 5)
# Cited override applies everywhere, even over a tile that said native.
assert get("a", 556361)["establishment"] == "introduced" and get("c", 556361)["establishment"] == "introduced"
# Listed tiles are never rewritten by the rules.
assert get("a", 2)["establishment"] == "native" and get("a", 1)["establishment"] == "introduced"
print("PASS: only-introduced fill, contested untouched, inheritance, unknowns kept, override, listings kept")
