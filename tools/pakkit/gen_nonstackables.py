#!/usr/bin/env python3
"""Generate Scripts/data/nonstackables.lua from DB_Items: every item row with MaxStackSize <= 1.

The sorting chest's Quick Stack pass (the game's own function) EXCLUDES non-stackables by
design -- both its merge phase and its new-stack phase gate on MaxStackSize > 1 (decoded from
BC_InventorySystem bytecode 2026-08-06, the user's "weather station didn't transfer" report).
sort_chest.lua therefore runs a manual whole-slot move pass for these classes, and needs to
know which classes those are. Stack sizes live in the DataTable row VALUE struct, which Lua
must never read at runtime (struct-instance access wedges the Lua scheduler) -- so the list
is baked offline from the same DB_Items this repo cooks.

Source of truth: the STAGED (patched) DB_Items -- it carries the pak's own rows (SortingChest,
wands, books, rods) on top of vanilla. Rerun after any build that adds item rows:
    python tools/pakkit/gen_nonstackables.py

Every staged input is a local build artifact (staged/, the usmap, wandsmith.exe are all
gitignored game-derived content), so on a fresh clone there is NOTHING to read and this script
EXITS rather than quietly producing a map. It used to fall through to a vanilla dump without a
word, which regenerated the committed 238-class map as the 229-class vanilla one -- dropping
BP_SortingChest_Item_C, the wands, the books and the rods, i.e. silently un-fixing the sorter.
The vanilla fallback is still there but has to be asked for:
    python tools/pakkit/gen_nonstackables.py --allow-vanilla
"""
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(ROOT))
WS = os.path.join(ROOT, "wandsmith", "bin", "Release", "net10.0", "wandsmith.exe")
USMAP = os.path.join(ROOT, "Solarpunk.usmap")
FRAMEWORK = os.path.join(ROOT, "staged", "Solarpunk", "Content", "Code",
                         "Inventory_Items", "Framework_and_Data")
STAGED_DB = os.path.join(FRAMEWORK, "DB_Items.uasset")
# Row structs must be preloaded or the rows read back as RawExport (no Table) -- same
# preloads build_wand_pak.py uses for its DB_Items round-trip. The structs are not staged,
# so they come from legacy/.
PRELOADS = ";".join([
    os.path.join(ROOT, "legacy", "Solarpunk", "Content", "Code", "Inventory_Items",
                 "Framework_and_Data", "S_Item.uasset"),
    os.path.join(ROOT, "legacy", "Solarpunk", "Content", "Code", "Inventory_Items",
                 "Framework_and_Data", "S_ItemAttribute.uasset"),
])
VENDOR_JSON = os.path.join(REPO, "vendor", "db_items.json")
OUT_LUA = os.path.join(REPO, "mod", "SolarpunkSurvival", "Scripts", "data", "nonstackables.lua")


def load_db(allow_vanilla):
    missing = [label for label, path in (("staged DB_Items", STAGED_DB),
                                         ("wandsmith.exe", WS),
                                         ("Solarpunk.usmap", USMAP))
               if not os.path.isfile(path)]
    if not missing:
        tmp = os.path.join(tempfile.gettempdir(), "gen_nonstackables_db_items.json")
        r = subprocess.run([WS, "tojson", USMAP, STAGED_DB, tmp, "VER_UE5_6", PRELOADS],
                           capture_output=True, text=True)
        if r.returncode == 0:
            with open(tmp, encoding="utf-8") as f:
                return json.load(f), "staged DB_Items (patched)"
        print(r.stdout + r.stderr)
        print("!! staged tojson failed (exit %d)" % r.returncode)
    else:
        # NAME what is missing. The silent version of this branch is what let a fresh clone
        # regenerate the map without any pak rows and call it a success.
        print("!! no staged DB_Items build here -- missing: " + ", ".join(missing))
        print("   (all three are gitignored build artifacts; run tools/pakkit/build_wand_pak.py"
              " first, or pass --allow-vanilla if you really want the vanilla-only map)")
    if not allow_vanilla:
        sys.exit("refusing to regenerate from the vanilla dump: it would DROP the pak's own"
                 " rows (BP_SortingChest_Item_C, wands, books, rods) from nonstackables.lua."
                 " Re-run with --allow-vanilla to do it anyway.")
    if os.path.isfile(VENDOR_JSON):
        with open(VENDOR_JSON, encoding="utf-8") as f:
            return json.load(f), "vendor/db_items.json (VANILLA -- pak rows missing!)"
    sys.exit("no DB_Items source found (need a tools/pakkit/staged build, or the local"
             " vendor/db_items.json dump -- it is game-derived and not committed)")


def fname(v):
    return v.get("Value") if isinstance(v, dict) else v


def main():
    db, src = load_db("--allow-vanilla" in sys.argv[1:])
    table = next(e for e in db["Exports"] if e.get("Table"))
    imports = db["Imports"]
    rows = []
    for r in table["Table"]["Data"]:
        row = fname(r.get("Name"))
        stack = actor = None
        for f in r.get("Value", []):
            n = str(fname(f.get("Name")))
            if n.startswith("MaxStackSize"):
                stack = f.get("Value")
            elif n.startswith("ItemActor"):
                actor = f.get("Value")
        if stack is None or stack > 1:
            continue
        cls = pkg = None
        if isinstance(actor, int) and actor < 0:
            imp = imports[-actor - 1]
            cls = fname(imp.get("ObjectName"))
            outer = imp.get("OuterIndex")
            if isinstance(outer, int) and outer < 0:
                pkg = fname(imports[-outer - 1].get("ObjectName"))
        if cls and pkg:
            rows.append((str(cls), str(pkg), str(row)))
    rows.sort()
    os.makedirs(os.path.dirname(OUT_LUA), exist_ok=True)
    with open(OUT_LUA, "w", encoding="ascii", newline="\n") as f:
        f.write("-- GENERATED by tools/pakkit/gen_nonstackables.py -- do not hand-edit.\n")
        f.write("-- Item ACTOR class -> full asset path, for every DB_Items row with\n")
        f.write("-- MaxStackSize <= 1. The game's own Quick Stack refuses to move these\n")
        f.write("-- (bytecode-gated on MaxStackSize > 1), so sort_chest.lua files them with a\n")
        f.write("-- manual whole-slot move pass. A MAP, not a list: runtime discovery filters\n")
        f.write("-- the game's own DB_Items keys against these NAMES (bulk classByName wrappers\n")
        f.write("-- proved to be a stale-pointer lottery -- rig 2026-08-06), and the paths let\n")
        f.write("-- any single class be re-resolved exactly without a short-name lookup.\n")
        f.write("-- Source: " + src + " (" + str(len(rows)) + " classes)\n")
        f.write("return {\n")
        for cls, pkg, row in rows:
            f.write('  ["%s"] = "%s.%s", -- %s\n' % (cls, pkg, cls, row))
        f.write("}\n")
    print("wrote %s (%d classes, source: %s)" % (OUT_LUA, len(rows), src))


if __name__ == "__main__":
    main()
