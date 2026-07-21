#!/usr/bin/env python3
"""Build the SolarpunkSurvival wand content pak.

Pipeline (all offline, no Unreal Editor):
  1. Clone BP_Stick_Item -> BP_MundaneWand_Item / BP_ElectricWand_Item (JSON rename round-trip).
  2. Patch DB_Items: two new imports pairs + two new S_Item rows (Repairkit-shaped tools).
  3. wandsmith fromjson -> staged/Solarpunk/Content/... (legacy assets, VER_UE5_6 flavor).
  4. retoc to-zen (UE5_7) -> z_SolarpunkWand_P.{utoc,ucas,pak} -> install to ~mods.

Requires: wandsmith (UAssetAPI), retoc.exe, Solarpunk.usmap, legacy/ (retoc to-legacy of the game).
"""
import json, copy, os, subprocess, shutil, sys, uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
WS = os.path.join(ROOT, "wandsmith", "bin", "Release", "net10.0", "wandsmith.exe")
RETOC = os.path.join(ROOT, "retoc.exe")
USMAP = os.path.join(ROOT, "Solarpunk.usmap")
LEGACY = os.path.join(ROOT, "legacy")
STAGED = os.path.join(ROOT, "staged")
OUT = os.path.join(ROOT, "out")
ITEMS_DIR = "Solarpunk/Content/Code/Inventory_Items"
GAME_PAKS = r"C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk\Content\Paks"

def run(*args):
    r = subprocess.run(list(args), capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout); print(r.stderr)
        sys.exit(f"FAILED: {' '.join(args)}")
    return r.stdout

MASTER_BP = os.path.join(LEGACY, ITEMS_DIR, "ItemActors", "_BP_ItemActor_MASTER.uasset")
S_ITEM = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_Item.uasset")
S_ATTR = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_ItemAttribute.uasset")

def tojson(asset, out, preloads=""):
    run(WS, "tojson", USMAP, asset, out, "VER_UE5_6", preloads)

def fromjson(src, out, preloads=""):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    run(WS, "fromjson", USMAP, src, out, "VER_UE5_6", preloads)

def key32():
    return uuid.uuid4().hex.upper()

# ---------------------------------------------------------------- 1. clone item BPs
def clone_bp(new_name):
    src = os.path.join(LEGACY, ITEMS_DIR, "ItemActors", "BP_Stick_Item.uasset")
    j = os.path.join(OUT, "bp_stick.json")
    tojson(src, j)
    text = open(j, encoding="utf-8").read()
    text = text.replace("BP_Stick_Item", new_name)
    jout = os.path.join(OUT, f"{new_name}.json")
    open(jout, "w", encoding="utf-8").write(text)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "ItemActors", f"{new_name}.uasset"),
             preloads=MASTER_BP)
    print(f"cloned {new_name}")

# ---------------------------------------------------------------- 2. patch DB_Items
def field(row, prefix):
    for p in row["Value"]:
        if p["Name"].split("_")[0] == prefix:
            return p
    raise KeyError(prefix)

def add_name(d, s):
    if s not in d["NameMap"]:
        d["NameMap"].append(s)

def add_rowkey_name(d, s):
    """Insert a DataTable ROW-KEY name into the low 'local names' region (just before the
    package's own name, 'DB_Items'). retoc's to-zen preserves FName references inside DataTable
    row data only for names in this low region; a name appended at the tail (index ~1788) is
    dropped on repack, orphaning the row key -> 'Bad name index' crash at load. Property names,
    enum values, and text keys are reused from existing rows so they already live down here; only
    the brand-new row *keys* need placing."""
    if s in d["NameMap"]:
        return
    anchor = d["NameMap"].index("DB_Items")
    d["NameMap"].insert(anchor, s)

def add_bp_imports(d, bp_name):
    """Package + BlueprintGeneratedClass import pair copied from the Stick pattern.
    Returns the (negative) import index of the class import."""
    imports = d["Imports"]
    stick_cls = next(i for i, e in enumerate(imports) if e["ObjectName"] == "BP_Stick_Item_C")
    stick_pkg = -imports[stick_cls]["OuterIndex"] - 1
    pkg = copy.deepcopy(imports[stick_pkg])
    pkg["ObjectName"] = f"/Game/Code/Inventory_Items/ItemActors/{bp_name}"
    imports.append(pkg)
    pkg_idx = -len(imports)
    cls = copy.deepcopy(imports[stick_cls])
    cls["ObjectName"] = f"{bp_name}_C"
    cls["OuterIndex"] = pkg_idx
    imports.append(cls)
    cls_idx = -len(imports)
    add_name(d, pkg["ObjectName"])
    add_name(d, cls["ObjectName"])
    return cls_idx

def make_row(d, rows, row_name, display, desc, icon_idx, actor_idx):
    # Base the wand on the HOE, not the Stick: the Hoe is a real held hand-tool, so its full type
    # taxonomy (ItemType, ItemInteractionType, DefaultAttribues/durability) drives the game's
    # hand system to actually swap the tool into the hand and apply its material. A Stick is a
    # RESOURCE (interaction type 0) -- equipping it showed an untextured mesh and tool->tool
    # switches didn't update the hand. The hoe's grip orientation also reads best for a wand (user
    # call). Only the mesh differs: our ItemActor points at a stick-meshed clone, so the held
    # object is a stick, held the way a hoe is held.
    hoe = next(r for r in rows if r["Name"] == "Hoe")
    cobalt = next(r for r in rows if r["Name"] == "Cobalt")
    row = copy.deepcopy(hoe)
    row["Name"] = row_name

    dn = field(row, "DisplayName")
    dn["Value"] = key32()
    dn["CultureInvariantString"] = display

    field(row, "MaxStackSize")["Value"] = 1
    field(row, "Icon")["Value"] = icon_idx
    field(row, "ItemActor")["Value"] = actor_idx
    # description: clone the Cobalt's populated text property, swap key + string
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    dp = copy.deepcopy(field(cobalt, "Description"))
    dp["Name"] = row["Value"][di]["Name"]
    dp["Value"] = key32()
    dp["CultureInvariantString"] = desc
    row["Value"][di] = dp
    rows.append(row)
    add_rowkey_name(d, row_name)
    print(f"row {row_name} (hoe-based) -> icon {icon_idx} actor {actor_idx}")

def patch_db_items():
    src = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "DB_Items.uasset")
    j = os.path.join(OUT, "db_items_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]
    imports = d["Imports"]
    icon_stick = -next(i for i, e in enumerate(imports) if e["ObjectName"] == "Icon_Stick") - 1
    icon_cobalt = -next(i for i, e in enumerate(imports) if e["ObjectName"] == "Icon_Cobalt") - 1

    mund_cls = add_bp_imports(d, "BP_MundaneWand_Item")
    elec_cls = add_bp_imports(d, "BP_ElectricWand_Item")
    make_row(d, rows, "MundaneWand", "Mundane Wand",
             "A stick crowned with cobalt. It hums faintly when storms pass. The dark arts know its true name.",
             icon_stick, mund_cls)
    make_row(d, rows, "ElectricWand", "Electric Wand",
             "The bolt is bound. The cobalt burns diamond-bright and asks to be aimed.",
             icon_cobalt, elec_cls)

    jout = os.path.join(OUT, "db_items_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "Framework_and_Data", "DB_Items.uasset"),
             preloads=";".join([S_ITEM, S_ATTR]))
    print("DB_Items patched: 311 rows")

# ---------------------------------------------------------------- 3. pack + install
def pack():
    utoc = os.path.join(OUT, "z_SolarpunkWand_P.utoc")
    run(RETOC, "to-zen", STAGED, utoc, "--version", "UE5_7")
    for ext in (".utoc", ".ucas", ".pak"):
        f = os.path.join(OUT, "z_SolarpunkWand_P" + ext)
        if not os.path.exists(f):
            sys.exit(f"missing pack output {f}")
        print("built", f, os.path.getsize(f), "bytes")
    print("build complete -- install the triple to <game>/Content/Paks/~mods/ separately")

if __name__ == "__main__":
    shutil.rmtree(STAGED, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    clone_bp("BP_MundaneWand_Item")
    clone_bp("BP_ElectricWand_Item")
    patch_db_items()
    pack()
    print("DONE")
