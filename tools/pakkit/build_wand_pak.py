#!/usr/bin/env python3
"""Build the SolarpunkSurvival content pak (wand items + the Tempest Codex).

Pipeline (all offline, no Unreal Editor):
  1. Clone BP_Stick_Item -> BP_MundaneWand_Item / BP_ElectricWand_Item (JSON rename round-trip).
  2. Patch DB_Items: new imports pairs + new S_Item rows (wands + the codex).
  3. Tempest Codex: clone the whole survival-guide chain (enum + tips table + 3 widgets +
     item/placeable BPs) with retargeted imports, then add craft + buildable rows.
  4. wandsmith fromjson -> staged/Solarpunk/Content/... (legacy assets, VER_UE5_6 flavor).
  5. retoc to-zen (UE5_7) -> z_SolarpunkWand_P.{utoc,ucas,pak} -> install to Content/Paks.

Requires: wandsmith (UAssetAPI), retoc.exe, Solarpunk.usmap, legacy/ (retoc to-legacy of the game).
"""
import json, copy, os, struct, subprocess, shutil, sys, uuid, base64

ROOT = os.path.dirname(os.path.abspath(__file__))
WS = os.path.join(ROOT, "wandsmith", "bin", "Release", "net10.0", "wandsmith.exe")
RETOC = os.path.join(ROOT, "retoc.exe")
USMAP = os.path.join(ROOT, "Solarpunk.usmap")
LEGACY = os.path.join(ROOT, "legacy")
STAGED = os.path.join(ROOT, "staged")
OUT = os.path.join(ROOT, "out")
ITEMS_DIR = "Solarpunk/Content/Code/Inventory_Items"
ICONS_DIR = "Solarpunk/Content/UI/ItemIcons"           # where item icon Texture2Ds live (/Game/UI/ItemIcons)
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

# ---------------------------------------------------------------- 1b. recolored stick icons
# The wand states read as distinct sticks in the inventory: Mundane = dark brown, Electric = blue,
# charged Electric = white. Each is a NEW texture recolored from the vanilla stick icon (never an
# override of Icon_Stick, which would tint every real stick in the game).
#
# The UI icons are uncompressed 256x256 PF_B8G8R8A8 (BGRA) textures with the single mip stored
# INLINE at the tail of the export's trailing bytes (UAssetAPI reads a Texture2D it lacks a handler
# for as a NormalExport, so those bytes land in `Extras` as base64). A 108-byte platform header
# precedes exactly 256*256*4 pixel bytes. Each opaque pixel maps to its luminance L, then a tint
# fn returns the (B,G,R) to write (keeps the stick's shape/shading, recolors the hue); the
# transparent background is left untouched. Same-length edit -> every serialized offset stays valid.

# tint(L) -> (B, G, R). Clamped to 0..255 on write.
# Mundane = brown, Hydration = blue, Electrick uncharged = yellow, charged = LIGHT yellow.
TINTS = {
    "Icon_StickBrown":  lambda L: (L * 0.14, L * 0.30, L * 0.55),        # dark, warm brown (R>G>B)
    "Icon_StickBlue":   lambda L: (L * 1.10 + 22, L * 0.55, L * 0.32),   # watery blue (B dominant)
    "Icon_StickGold":   lambda L: (L * 0.20, L * 1.05 + 30, L * 1.10 + 40),  # yellow (uncharged)
    "Icon_StickYellow": lambda L: (L * 1.00 + 92, L * 0.88 + 72, L * 0.78 + 55),  # very light blue (charged; name kept to avoid import churn)
}

def _tint_icon(src_dir, src_name, new_name, tint):
    """Recolor any square uncompressed BGRA icon (same-length edit, offsets stay valid)."""
    d, raw, hdr, PIX = _icon_pixels(src_dir, src_name)
    e = d["Exports"][0]
    for i in range(hdr, hdr + PIX, 4):
        B, G, R, A = raw[i], raw[i + 1], raw[i + 2], raw[i + 3]
        if A == 0:
            continue
        L = 0.299 * R + 0.587 * G + 0.114 * B
        b, g, r = tint(L)
        raw[i]     = min(255, max(0, int(b)))
        raw[i + 1] = min(255, max(0, int(g)))
        raw[i + 2] = min(255, max(0, int(r)))
        # A left as-is: the stick silhouette is carried by alpha
    e["Extras"] = base64.b64encode(bytes(raw)).decode()
    # rename package + export src_name -> new_name. base64 uses no '_', so a text replace cannot
    # touch the pixel payload -- only the name/path fields.
    txt = json.dumps(d).replace(src_name, new_name)
    jout = os.path.join(OUT, f"{new_name}.json")
    open(jout, "w", encoding="utf-8").write(txt)
    fromjson(jout, os.path.join(STAGED, src_dir, f"{new_name}.uasset"))
    print(f"staged {new_name}")

def _tint_stick_icon(new_name, tint):
    _tint_icon(ICONS_DIR, "Icon_Stick", new_name, tint)

ART_ICONS_DIR = "Solarpunk/Content/Art/Textures/Icons"

# MIP FOOTER GOTCHA (found 2026-07-22, the Icon_DarkArts boot crash): the pixel payload is NOT
# the tail of Extras -- a 24-byte mip footer (SizeX, SizeY, SizeZ=1, then 12 zero bytes) sits
# BETWEEN the bulk pixels and the end of the export. Anchoring the pixel window to the tail
# overwrites that footer, and the async loader then reads garbage dims/flags and dies at boot with
# 'Serial size mismatch' (+68 bytes read). The stick recolors only survived the old tail-anchored
# math by luck: every footer byte that lands in an alpha position is 0, so the tint's A==0 skip
# left the footer untouched.
MIP_FOOTER = 24

def _icon_pixels(src_dir, src_name):
    """Decode a square BGRA icon's raw bytes -> (json dict, bytearray, pixel_start, pixel_len).
    The mip footer (see gotcha above) is validated against the probed dimensions, so a layout
    drift fails the build instead of cooking a boot crash."""
    src = os.path.join(LEGACY, src_dir, src_name + ".uasset")
    j = os.path.join(OUT, f"icon_src_{src_name}.json")
    if not os.path.exists(j):
        tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    raw = bytearray(base64.b64decode(d["Exports"][0]["Extras"]))
    for dim in (256, 512, 128, 64):
        p = dim * dim * 4
        if 0 <= len(raw) - p - MIP_FOOTER <= 4096:
            if struct.unpack_from("<III", raw, len(raw) - MIP_FOOTER) != (dim, dim, 1):
                sys.exit(f"{src_name}: mip footer is not ({dim},{dim},1) -- layout assumption broken")
            return d, raw, len(raw) - p - MIP_FOOTER, p
    sys.exit(f"{src_name}: unexpected texture payload {len(raw)}")

# GOTCHA (found 2026-07-22, the "two wands" research card): Icon_Handbook is PF_DXT5
# (BC3-compressed, 512x512, 1 byte/px = the SAME 262144-byte payload as a 256x256 BGRA icon), so
# the old same-length BGRA tint silently corrupted its compressed blocks into noise. Any icon
# built FROM the handbook must decode DXT5 first, then be repacked into a known-good uncompressed
# BGRA container (Icon_Stick's), never patched in place.
def _dxt5_decode(data, W, H):
    """BC3/DXT5 -> BGRA bytearray (W*H*4)."""
    import struct as _st
    out = bytearray(W * H * 4)
    off = 0
    for by in range(H // 4):
        for bx in range(W // 4):
            blk = data[off:off + 16]; off += 16
            a0, a1 = blk[0], blk[1]
            abits = int.from_bytes(blk[2:8], "little")
            c0, c1 = _st.unpack_from("<HH", blk, 8)
            cbits = int.from_bytes(blk[12:16], "little")
            def c565(c):
                return (((c >> 11) & 31) * 255 // 31, ((c >> 5) & 63) * 255 // 63,
                        (c & 31) * 255 // 31)
            r0, g0, b0 = c565(c0); r1, g1, b1 = c565(c1)
            cols = [(r0, g0, b0), (r1, g1, b1),
                    ((2 * r0 + r1) // 3, (2 * g0 + g1) // 3, (2 * b0 + b1) // 3),
                    ((r0 + 2 * r1) // 3, (g0 + 2 * g1) // 3, (b0 + 2 * b1) // 3)]
            if a0 > a1:
                al = [a0, a1] + [((7 - i) * a0 + i * a1) // 7 for i in range(1, 7)]
            else:
                al = [a0, a1] + [((5 - i) * a0 + i * a1) // 5 for i in range(1, 5)] + [0, 255]
            for py in range(4):
                for px in range(4):
                    i = py * 4 + px
                    r, g, b = cols[(cbits >> (2 * i)) & 3]
                    o = ((by * 4 + py) * W + bx * 4 + px) * 4
                    out[o:o + 4] = bytes((b, g, r, al[(abits >> (3 * i)) & 7]))
    return out

def _handbook_bgra256():
    """The vanilla open-book art as clean 256x256 BGRA: DXT5-decode Icon_Handbook (512x512),
    box-downscale 2x. The payload window respects the mip footer (see MIP_FOOTER) -- the old
    tail-anchored slice was shifted 24 bytes into the block stream and decoded a washed-out
    ghost, which is also why the art looked like an opaque card: correctly aligned, it carries
    a real alpha silhouette and needs no chroma-keying."""
    src = os.path.join(LEGACY, ART_ICONS_DIR, "Icon_Handbook.uasset")
    j = os.path.join(OUT, "icon_src_Icon_Handbook.json")
    if not os.path.exists(j):
        tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    raw = base64.b64decode(d["Exports"][0]["Extras"])
    if struct.unpack_from("<III", raw, len(raw) - MIP_FOOTER) != (512, 512, 1):
        sys.exit("Icon_Handbook: mip footer is not (512,512,1) -- layout assumption broken")
    need = (512 // 4) * (512 // 4) * 16
    big = _dxt5_decode(raw[len(raw) - MIP_FOOTER - need:len(raw) - MIP_FOOTER], 512, 512)
    out = bytearray(256 * 256 * 4)
    for y in range(256):
        for x in range(256):
            acc = [0, 0, 0, 0]
            for dy in (0, 1):
                for dx in (0, 1):
                    o = ((y * 2 + dy) * 512 + x * 2 + dx) * 4
                    for c in range(4):
                        acc[c] += big[o + c]
            o = (y * 256 + x) * 4
            out[o:o + 4] = bytes(v // 4 for v in acc)
    return out

def _stage_bgra_icon(new_name, bgra):
    """Pack 256x256 BGRA pixels into the proven Icon_Stick container (same dir, same header) and
    stage it as a NEW texture named new_name in /Game/UI/ItemIcons."""
    d, raw, hdr, pix = _icon_pixels(ICONS_DIR, "Icon_Stick")
    if len(bgra) != pix:
        sys.exit(f"{new_name}: pixel payload {len(bgra)} != container {pix}")
    raw[hdr:hdr + pix] = bgra
    d = json.loads(json.dumps(d))  # private copy (the src json is cached across calls)
    d["Exports"][0]["Extras"] = base64.b64encode(bytes(raw)).decode()
    txt = json.dumps(d).replace("Icon_Stick", new_name)
    jout = os.path.join(OUT, f"{new_name}.json")
    open(jout, "w", encoding="utf-8").write(txt)
    fromjson(jout, os.path.join(STAGED, ICONS_DIR, f"{new_name}.uasset"))
    print(f"staged {new_name} (BGRA container)")

def _indigo(book):
    """Re-ink an open-book BGRA image storm-indigo, in place."""
    for i in range(0, len(book), 4):
        B, G, R, A = book[i], book[i + 1], book[i + 2], book[i + 3]
        if A == 0:
            continue
        L = 0.299 * R + 0.587 * G + 0.114 * B
        book[i]     = min(255, int(L * 0.95 + 25))
        book[i + 1] = min(255, int(L * 0.30))
        book[i + 2] = min(255, int(L * 0.55 + 10))
    return book

def make_darkarts_icon():
    """Research-card icon for "The Dark Arts": the indigo book with the stick laid across it --
    alpha-over composite in clean 256x256 BGRA, packed into the stick's uncompressed container."""
    book = _indigo(_handbook_bgra256())
    _, stick, sh, sp = _icon_pixels(ICONS_DIR, "Icon_Stick")
    for i in range(0, sp, 4):
        sa = stick[sh + i + 3]
        if sa == 0:
            continue
        a = sa / 255.0
        for c in range(3):
            book[i + c] = int(stick[sh + i + c] * a + book[i + c] * (1 - a))
        book[i + 3] = max(book[i + 3], sa)
    _stage_bgra_icon("Icon_DarkArts", book)

def make_icons():
    for name, tint in TINTS.items():
        _tint_stick_icon(name, tint)
    # The Tempest Codex inventory icon: the Handbook's open-book art, re-inked storm-indigo
    # (decoded from DXT5 -- see the gotcha above -- and staged uncompressed).
    _stage_bgra_icon("Icon_TempestCodex", _indigo(_handbook_bgra256()))
    make_darkarts_icon()

# ---------------------------------------------------------------- 2. patch DB_Items
def field(row, prefix):
    for p in row["Value"]:
        if p["Name"].split("_")[0] == prefix:
            return p
    raise KeyError(prefix)

def add_name(d, s):
    if s not in d["NameMap"]:
        d["NameMap"].append(s)

def fix_name_count(d):
    """THE root cause of the 'Bad name index' family (found 2026-07-21 via exp_namecut.py):
    UE5 package summaries carry `NamesReferencedFromExportDataCount` -- the name map's PREFIX
    that export blobs may reference by index; retoc's to-zen keeps exactly that prefix (plus
    header/import-visible names) and prunes the rest. UAssetAPI preserves the BASE asset's count
    verbatim, so once inserted row keys grow the low block past the stale count, the block's
    TAIL names (usually the game's own last-alphabetical row keys, e.g. Wood_Waste) are pruned
    on repack. If filler names still occupy the following slots the affected rows are misnamed
    SILENTLY; once the reference walks off the end it is a fatal 'Bad name index N/N' at load.
    Cover the whole map -- every name survives, every blob index stays valid. MUST be called on
    any asset whose NameMap gained names that only export data references (i.e. row keys)."""
    d["NamesReferencedFromExportDataCount"] = len(d["NameMap"])

def add_rowkey_name(d, s):
    """Insert a new DataTable ROW-KEY name into the base package's sorted low-name block.

    DB_Items stores its row keys as an ALPHABETICALLY-SORTED block of FNames in the low name region
    (indices ~2 .. just before the package's own 'DB_Items' name near ~288). retoc's to-zen
    preserves names inside this block, but DROPS a name wedged at the very BOUNDARY (immediately
    before 'DB_Items') -> that orphans the last new row key -> 'Bad name index' crash at load.
    (The old approach inserted right before DB_Items; it worked only by luck while <=2 keys were
    added -- with 3, retoc pruned the last, caught by the offline round-trip verify.) Placing each
    key in its sorted position well INSIDE the block keeps it clear of that boundary. UAssetAPI
    re-derives every name index from the strings on write, so shifting the block is safe. Property
    names, enum values, and text keys are reused from existing rows so they already live down here;
    only the brand-new row *keys* need placing."""
    nm = d["NameMap"]
    if s in nm:
        return
    anchor = nm.index("DB_Items")
    i = 2
    while i < anchor and nm[i] < s:
        i += 1
    if i >= anchor:          # alphabetically past the block: step back off the DB_Items boundary
        i = anchor - 1
    nm.insert(i, s)

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

def add_texture_import(d, base_tex, new_tex):
    """Add a Package + Texture2D import pair for a staged icon, modeled on an existing icon import
    (base_tex, e.g. 'Icon_Stick'). Returns the (negative) import index of the texture -- what an
    S_Item row's Icon field points at. Import names survive retoc's repack via the import table, so
    they need no low-index placement (unlike DataTable row keys)."""
    imps = d["Imports"]
    tex_i = next(i for i, e in enumerate(imps)
                 if e["ObjectName"] == base_tex and e.get("ClassName") == "Texture2D")
    pkg_i = -imps[tex_i]["OuterIndex"] - 1
    pkg = copy.deepcopy(imps[pkg_i])
    pkg["ObjectName"] = pkg["ObjectName"].rsplit("/", 1)[0] + "/" + new_tex
    imps.append(pkg)
    pkg_idx = -len(imps)
    tex = copy.deepcopy(imps[tex_i])
    tex["ObjectName"] = new_tex
    tex["OuterIndex"] = pkg_idx
    imps.append(tex)
    tex_idx = -len(imps)
    add_name(d, pkg["ObjectName"])
    add_name(d, new_tex)
    return tex_idx

def make_row(d, rows, row_name, display, desc, icon_idx, actor_idx, durability=None,
             tools_tab=False):
    stick = next(r for r in rows if r["Name"] == "Stick")
    rasp = next(r for r in rows if r["Name"] == "Raspberry")
    cobalt = next(r for r in rows if r["Name"] == "Cobalt")
    row = copy.deepcopy(stick)
    row["Name"] = row_name

    dn = field(row, "DisplayName")
    dn["Value"] = key32()
    dn["CultureInvariantString"] = display

    field(row, "MaxStackSize")["Value"] = 1
    field(row, "Icon")["Value"] = icon_idx
    field(row, "ItemActor")["Value"] = actor_idx
    # RENDER PATH: type the wand as a CONSUMABLE (Raspberry = EItemType T5) -- T5 is the SAFE type
    # (no tool integration, no world-load crash). But T5 does NOT render the item BP's own Mesh
    # in-hand (earlier belief, disproven by bytecode RE of BP_MainPlayerCharacter 2026-07-21):
    # UpdateHandConsumable resolves the in-hand visual via a class->class map BAKED into the pawn's
    # bytecode (ItemActor class -> BP_HandItem_* class, 21 food entries) and spawns that hand-item
    # actor via SetHandRBlueprintForBoth. New rows can never be in the baked map, so the game shows
    # an empty palm-out hand; the Lua mod supplies the visual by making the same
    # SetHandRBlueprintForBoth call with a donor hand-item class and re-dressing the spawned actor
    # (features/wand.lua buildRig). Patching the map would mean re-cooking the whole pawn BP -- no.
    field(row, "ItemType")["Value"] = copy.deepcopy(field(rasp, "ItemType")["Value"])
    # CRAFTING-MENU TAB (bytecode RE of SkyGameInstance.InitialGetCraftingRecepysByType
    # 2026-07-22): the workbench tabs bucket recipes by the END PRODUCT item row's ItemType
    # via Array_CONTAINS -- membership, order-free, multi-tab capable. The pawn never READS
    # ItemType (its only refs are empty-hand struct consts), so extra entries can't reroute
    # the hand-render path; T5 stays at index 0 purely for it's-a-consumable clarity.
    # T1 == the Tools tab (Hoe/Axe/Watercan all carry it).
    if tools_tab:
        tool_entry = copy.deepcopy(field(rasp, "ItemType")["Value"][0])
        tool_entry["Name"] = str(len(field(row, "ItemType")["Value"]))
        tool_entry["Value"] = "EItemType::NewEnumerator1"
        field(row, "ItemType")["Value"].append(tool_entry)
    # ALSO copy Raspberry's INTERACTION (I2). The game only renders an item in-hand when it has an
    # active "use" interaction -- a passive I0 (Stick) shows nothing (proven: T5+I0 => invisible).
    # I2 makes the game draw the palm-out hold + SM_Stick. The wand has empty DefaultAttribues, so
    # "eating" it should be a no-op (no food value to consume); casting stays on our own input hooks.
    field(row, "ItemInteractionType")["Value"] = copy.deepcopy(field(rasp, "ItemInteractionType")["Value"])
    # description: clone the Cobalt's populated text property, swap key + string
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    dp = copy.deepcopy(field(cobalt, "Description"))
    dp["Name"] = row["Value"][di]["Name"]
    dp["Value"] = key32()
    dp["CultureInvariantString"] = desc
    row["Value"][di] = dp
    field(row, "BurnTime")["Value"] = 0
    # Charge display (offline RE of W_InventorySlot/BPL_AttributeFunctions 2026-07-22): the
    # inventory-slot bar is data-driven -- ANY item whose row carries a DefaultAttribues entry
    # {EItemAttribute::DURABILITY, max} gets the bar, seeded full on grant
    # (GenerateDefaultAttributesForItem writes the instance JSON), and the pawn's own
    # DecreaseCurItemDurability moves it. Donor entry: the Axe row's durability attribute.
    if durability is not None:
        axe = next(r for r in rows if r["Name"] == "Axe")
        slot = copy.deepcopy(field(axe, "DefaultAttribues")["Value"][0])
        slot["Name"] = "0"
        for f in slot["Value"]:
            if f["Name"].split("_")[0] == "Value":
                f["Value"] = float(durability)
                f["IsZero"] = False
        field(row, "DefaultAttribues")["Value"] = [slot]
    rows.append(row)
    add_rowkey_name(d, row_name)
    print(f"row {row_name} -> icon {icon_idx} actor {actor_idx}"
          + (f" durability {durability}" if durability is not None else ""))

def base_text(name, s):
    """A minimal Base-history FText property (culture-invariant string + fresh loc key)."""
    return {
        "$type": "UAssetAPI.PropertyTypes.Objects.TextPropertyData, UAssetAPI",
        "Flags": 0, "HistoryType": "Base", "Namespace": "",
        "CultureInvariantString": s, "SourceFmt": None, "Arguments": None,
        "ArgumentsData": None, "TransformType": "ToLower", "SourceValue": None,
        "FormatOptions": None, "TargetCulture": None,
        "Name": name, "ArrayIndex": 0, "PropertyGuid": None, "IsZero": False,
        "PropertyTagFlags": "None", "PropertyTypeName": None,
        "PropertyTagExtensions": "NoExtension", "Value": key32(),
    }

def make_codex_row(d, rows, icon_idx, actor_idx):
    """TempestCodex item row: a Handbook-shaped placeable book (T10 place-to-read + T0), so the
    game's own placement system handles it -- DB_Buildables maps the row to our placeable clone."""
    hb = next(r for r in rows if r["Name"] == "Handbook")
    row = copy.deepcopy(hb)
    row["Name"] = "TempestCodex"
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "DisplayName")
    row["Value"][di] = base_text(row["Value"][di]["Name"], "Tempest Codex")
    de = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    row["Value"][de] = base_text(row["Value"][de]["Name"],
                                 "Bound in storm-blackened hide. Place it anywhere, and read what the sky is owed.")
    field(row, "Icon")["Value"] = icon_idx
    field(row, "ItemActor")["Value"] = actor_idx
    rows.append(row)
    add_rowkey_name(d, "TempestCodex")
    print(f"row TempestCodex -> icon {icon_idx} actor {actor_idx}")

def patch_db_items():
    src = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "DB_Items.uasset")
    j = os.path.join(OUT, "db_items_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]
    imports = d["Imports"]
    # Recolored stick icons (staged by make_icons), one per wand state: Mundane = dark brown,
    # Hydration = blue, Electric (spent) = dim gold, Charged Electric = bright yellow.
    icon_brown  = add_texture_import(d, "Icon_Stick", "Icon_StickBrown")
    icon_blue   = add_texture_import(d, "Icon_Stick", "Icon_StickBlue")
    icon_gold   = add_texture_import(d, "Icon_Stick", "Icon_StickGold")
    icon_yellow = add_texture_import(d, "Icon_Stick", "Icon_StickYellow")
    # Codex icon: the Handbook's open-book art re-inked indigo, staged in the STICK's dir and
    # container (uncompressed BGRA -- Icon_Handbook itself is DXT5, see the make_icons gotcha).
    icon_codex = add_texture_import(d, "Icon_Stick", "Icon_TempestCodex")

    mund_cls  = add_bp_imports(d, "BP_MundaneWand_Item")
    hydra_cls = add_bp_imports(d, "BP_HydrationWand_Item")
    elec_cls  = add_bp_imports(d, "BP_ElectricWand_Item")
    chg_cls   = add_bp_imports(d, "BP_ChargedElectricWand_Item")
    codex_cls = add_bp_imports(d, "BP_TempestCodex_Item")
    make_row(d, rows, "MundaneWand", "Mundane Wand",
             "A stick sealed with beeswax. It hums faintly when storms pass. The dark arts know its true name.",
             icon_brown, mund_cls, tools_tab=True)
    # The middle rung of the ladder: the chicken-and-water rite quenches the mundane rod blue.
    # durability 12 = the charge bar: one notch per 20-measure pour (240 max / 20).
    make_row(d, rows, "HydrationWand", "Hydration Wand",
             "A rod that remembers the rain. It pours what it has drunk, and it is always thirsty.",
             icon_blue, hydra_cls, durability=12)
    # "Electrick" with the k -- the occult spelling, like magick (user-requested rename; the ROW
    # KEYS stay ElectricWand/ChargedElectricWand -- renaming keys would re-fight the name-index
    # gotcha and break the mod's itemRows mapping for zero gain)
    make_row(d, rows, "ElectricWand", "Electrick Wand",
             "The bolt has been spent. The rod waits, dim gold, for the storm to fill it again.",
             icon_gold, elec_cls)
    # durability 3 = the bolt count: the bar shows the three casts a full rod holds.
    make_row(d, rows, "ChargedElectricWand", "Charged Electrick Wand",
             "The storm sits caged in the rod, yellow-hot and howling. Loose it before it fades.",
             icon_yellow, chg_cls, durability=3)
    make_codex_row(d, rows, icon_codex, codex_cls)

    fix_name_count(d)
    jout = os.path.join(OUT, "db_items_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "Framework_and_Data", "DB_Items.uasset"),
             preloads=";".join([S_ITEM, S_ATTR]))
    print(f"DB_Items patched: {len(rows)} rows")

# ---------------------------------------------------------------- 4. the Tempest Codex
# A REAL in-game book, cloned wholesale from the survival guide's data-driven chain (RE 2026-07-21,
# HOWTO "The Tempest Codex"):
#   W_SurvivalGuide reads S_GameplayTip rows from DB_GameplayTips, groups them by the
#   EGameplayTipCategory enum (category-button labels come from the enum's DisplayNameMap via
#   Conv_NumericPropertyToText on WC_SurvivalGuideCategory), and renders each row with
#   WC_GameplayTip. The placed book (BP_SurvivalGuide_Placeable) virtual-calls
#   UI_OpenSurvivalGuide on the interacting controller.
# Clone chain (imports retargeted by plain text replace over the round-trip JSON -- bytecode
# references imports by INDEX, so re-pointing an import retargets every use with zero bytecode
# surgery; FNames/import indices are fixed-width, so serialized sizes stay stable):
#   ETempestCodexCategory  4 sections + MAX  (values 0..3, display names = section titles)
#   DB_TempestCodex        rows = the codex passages (RowStruct stays the ORIGINAL S_GameplayTip;
#                          category FNames therefore resolve against the ORIGINAL enum -- see
#                          CAT_FNAME for the byte<->name permutation)
#   W_TempestCodex         + title text inlined to "Tempest Codex", + the ONE baked loop literal
#                          MakeLiteralInt(9) -> 4 in GenerateCategoryButtons (button count)
#   WC_TempestCodexCategory / WC_TempestPage   (page text sized up to 15pt)
#   BP_TempestCodex_Item / BP_TempestCodex_Placeable  (the placeable's UI_OpenSurvivalGuide call is
#                          renamed to the controller's no-arg ForceCloseInteractableUIs -- a
#                          harmless native no-op; features/codex.lua hooks the clone's interact
#                          event and Opens W_TempestCodex itself. NEVER retarget a virtual call to
#                          a missing function: EX_LocalVirtualFunction resolves via
#                          FindFunctionChecked, which is a fatal assert.)
WIDGETS_DIR = "Solarpunk/Content/UI/Widgets"
WC_DIR      = WIDGETS_DIR + "/WidgetComponents"
TIPS_DIR    = "Solarpunk/Content/Code/Misc/GameplayTips"
PLACE_DIR   = "Solarpunk/Content/Code/Building_Placing/Placeables"
S_TIP       = os.path.join(LEGACY, TIPS_DIR, "S_GameplayTip.uasset")

def clone_asset(src_rel, out_rel, replaces, preloads="", patch=None):
    """tojson -> ordered text replaces -> optional structural patch -> fromjson into staged/."""
    base = os.path.splitext(os.path.basename(src_rel))[0]
    j = os.path.join(OUT, f"clone_{base}.json")
    tojson(os.path.join(LEGACY, src_rel), j, preloads)
    text = open(j, encoding="utf-8").read()
    for a, b in replaces:
        text = text.replace(a, b)
    d = json.loads(text)
    if patch:
        patch(d)
    newbase = os.path.splitext(os.path.basename(out_rel))[0]
    jout = os.path.join(OUT, f"{newbase}.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, out_rel), preloads)
    print(f"staged {out_rel}")
    return d

def add_import_pair(d, pkg_path, obj_name, class_name, class_pkg="/Script/Engine"):
    """Package + object import pair (dedup by object name+class). Returns the object's import idx.
    Appended names are safe -- only the row-key BOUNDARY position is retoc-hostile."""
    imps = d["Imports"]
    for i, e in enumerate(imps):
        if str(e["ObjectName"]) == obj_name and str(e.get("ClassName")) == class_name:
            return -(i + 1)
    pkg = {"$type": "UAssetAPI.Import, UAssetAPI", "ObjectName": pkg_path, "OuterIndex": 0,
           "ClassPackage": "/Script/CoreUObject", "ClassName": "Package", "PackageName": None,
           "bImportOptional": False}
    imps.append(pkg)
    pkg_idx = -len(imps)
    obj = {"$type": "UAssetAPI.Import, UAssetAPI", "ObjectName": obj_name, "OuterIndex": pkg_idx,
           "ClassPackage": class_pkg, "ClassName": class_name, "PackageName": None,
           "bImportOptional": False}
    imps.append(obj)
    add_name(d, pkg_path)
    add_name(d, obj_name)
    # class refs must be in the NameMap too -- usually already there ("/Script/Engine",
    # "BlueprintGeneratedClass"), but e.g. DB_CraftingRecipes had never heard of "/Script/UMG"
    # (dummy-FName serialize error). add_name dedups; appended names are retoc-safe.
    add_name(d, class_name)
    add_name(d, class_pkg)
    add_name(d, "Package")
    add_name(d, "/Script/CoreUObject")
    return -len(imps)

def add_rowkey(d, s, anchor):
    """Row-key FName into the low name block, interior (same retoc boundary gotcha as DB_Items --
    see add_rowkey_name; generalized to any table's anchor name)."""
    nm = d["NameMap"]
    if s in nm:
        return
    a = nm.index(anchor)
    i = min(2, max(0, a - 1))
    while i < a - 1 and str(nm[i]) < s:
        i += 1
    nm.insert(i, s)

# ---- the codex text ----------------------------------------------------------
# Four sections; each page is one S_GameplayTip row (icon, passage, category).
# Category BYTE -> ORIGINAL-enum FName (rows use the original S_GameplayTip, whose Category
# property resolves names against EGameplayTipCategory; its name<->value order is permuted):
CAT_FNAME = {
    0: "EGameplayTipCategory::NewEnumerator0",   # byte 0 -> section "Origins"
    1: "EGameplayTipCategory::NewEnumerator2",   # byte 1 -> "Pentagram"
    2: "EGameplayTipCategory::NewEnumerator1",   # byte 2 -> "Implements"
    3: "EGameplayTipCategory::NewEnumerator4",   # byte 3 -> "Hydration Wand"
    4: "EGameplayTipCategory::NewEnumerator3",   # byte 4 -> "Electrick Wand"
}
CODEX_SECTIONS = ["Origins", "Pentagram", "Implements", "Hydration Wand", "Electrick Wand"]
ICONS_ART = "/Game/Art/Textures/Icons/"
# icons that do NOT live in the Art/Textures/Icons flat dir (verified against the legacy extract)
ICON_DIR_OVERRIDES = { "Icon_Stick": "/Game/UI/ItemIcons/" }

CODEX_PAGES = [
    # -------- ORIGINS --------
    ("Codex_O1", 0, "Icon_Weather_Sunny",
     "In the beginning there were two fires, and they were brothers, and they hated one another"
     " as only brothers can. The elder is AURELION, the Patient Furnace, Warden of the Day, who"
     " lays his gold upon every leaf and every pane of glass, and asks for nothing. The younger"
     " is KERAUNOS, the Jealous Fire, Lord of the Riven Sky, who gives nothing -- but trades."),
    ("Codex_O2", 0, "Icon_Stormy",
     "Keraunos coils behind the clouds and counts what is owed him. Every shadow cast by his"
     " brother's light he writes down as an insult. When the ledger grows too heavy the sky"
     " turns black, and he comes down upon the land in white letters, and what he underlines is"
     " burned, and what is burned is his."),
    ("Codex_O3", 0, "Icon_Weather_Sunny",
     "Neither brother may slay the other, for the world is the wager, and the world must stand."
     " So they keep the old balance: the day is Aurelion's, given freely; the storm is Keraunos',"
     " and everything in it has a price. Thy panels of glass drink the elder's charity. This"
     " codex concerns the younger, and his terrible shop."),
    ("Codex_O4", 0, "Icon_Stormy",
     "Ask why any soul would trade with the Jealous Fire, when the Patient Furnace gives for"
     " free. Because Aurelion's gift falls soft and slow, and some works want fire that ARGUES."
     " Because the storm can be aimed. Because, little witch, thou hast already read this far."),
    # -------- PENTAGRAM --------
    ("Codex_P1", 1, "ICON_CandlePlate",
     "Of the Raising of the Shape. Raise up a pentagon of fence -- five walls of equal length --"
     " to pen the innocent within, that it may not flee. Then from each of the five sides draw"
     " forth a point, so that the walls give birth to a star of five sharp points: the old and"
     " evil geometry, the shape the wise will not name aloud."),
    ("Codex_P2", 1, "ICON_CandlePlate",
     "Upon each of the five corners set a single candle, and leave every one of them dark."
     " Suffer no earthly flame to touch them -- for the sky itself shall be their spark."),
    ("Codex_P3", 1, "AnimalIcon_Sheep",
     "In the very heart of the shape the offering must stand. Bind it not, and comfort it not --"
     " for the truly innocent do not run."),
    ("Codex_P4", 1, "Icon_Weather",
     "The sky is exact in its sums: no fewer than fifteen posts of fence and five candles, all"
     " within twenty paces of the heart. Work in the rain if thou must -- the storm snuffs every"
     " flame regardless; it is the PLACING that the sky reads, not the light."
     "\n\n-- count thy witnesses well, for the storm counts them too --"),
    # -------- IMPLEMENTS --------
    ("Codex_I1", 2, "Icon_Stick",
     "Hearken, thou who bearest in thy hand a rod both mundane and mute -- a dead branch of no"
     " more worth than a corpse's cold finger. It sleepeth, and shall sleep forever, unless the"
     " wrath of the heavens be called down to wake it. Whisper these steps to no living soul,"
     " and work them only in the dark of a gathering storm."),
    ("Codex_I2", 2, "Icon_Handbook",
     "No soul is born knowing the shape. Go first to the table of research and pay the ledger"
     " its opening tithe -- wax of the bee, clay of the earth, leaf of the tree, one measure of"
     " each -- and the old and evil geometry shall unfold to thee: the binding of this very"
     " codex, and the shaping of the rod alike. Knowledge is the first sacrifice. It is not the"
     " last."),
    ("Codex_I3", 2, "ICON_Beeswax",
     "Then cut thy rod: a stick, dry and honest, no longer than thy forearm. Seal its crown with"
     " the wax of the honeybee, molded warm and set cold, and work the two as one at the bench --"
     " no bare hand suffices for so exact a sin. Fret not that the crown sits soft and pale; the"
     " storm shall set its own stone there in time. But mark: the shape is NOT the weapon. What"
     " thou holdest now is a wand the way a coffin is a ship."),
    ("Codex_I4", 2, "Icon_Stormy",
     "No forge of man can wake the rod. Power is not smithed; it is OWED -- and it is owed TWICE."
     " The rod must climb a ladder of two rungs: first the WATER, then the FIRE. Carry it to the"
     " pentagram once for each, and pay what each rite demands, in the manner written upon the"
     " leaves that follow. Skip no rung: the sky does not deal with those who cut the line."),
    ("Codex_I5", 2, "Icon_Stick",
     "Of other implements -- the crook that herds hail, the needle that sews wounds in the wind,"
     " the bell that unringable rings -- this codex keeps its silence yet. Feed the ledger, and"
     " perhaps the ledger feeds thee."),
    # -------- HYDRATION WAND (the first rung: the Rite of the Quenched Rod) --------
    ("Codex_H1", 3, "Icon_Caraffe_Water",
     "I. Of the First Rung. The dry rod is a beggar; before it may argue with the sky it must"
     " first learn to HOLD. Water is the humblest of the sky's coins, and so it is the first"
     " taught. Return to thy pentagram beneath a gathering storm, and bring the five wet"
     " tributes: WATER clear of impurities, boiled and blameless, for the sky will not school"
     " a rod on silt. WAX of the honeybee, that seals the rod and calls to its own. LEAF of"
     " the trees, that drinks the rain all its green life. CLAY of the earth, that holds the"
     " river's shape. And a BERRY nourished by the sun, swollen fat with juice."),
    ("Codex_H2", 3, "AnimalIcon_Chicken",
     "And bring the offering: a chicken, bright of eye and busy of foot, that hath scratched"
     " all its small days in honest dirt. It is a lesser innocence than the lamb's, for this is"
     " a lesser asking -- but innocence it is, and the sky counts it fair coin for rain."),
    ("Codex_H3", 3, "ICON_CandlePlate",
     "Pen the bird in the heart of the star, and lay the five tributes upon the ground by the"
     " candles -- anywhere within the circle's heart will serve; the star is not fussy about"
     " strides. Then wait upon the storm. When the bolt takes the bird, the five tributes leap"
     " into the rod, and the rod turns river-blue: a HYDRATION WAND, brimming with two hundred"
     " and forty measures -- twice what any tinker's can may carry."),
    ("Codex_H4", 3, "Icon_Watercan_Wood",
     "II. Of the Pouring. Draw the blue rod and look upon what thirsts, and pour. Aim it at the"
     " tilled box and the soil drinks its fill in one gesture. Aim it at a COMPANION -- parched,"
     " staggering, too proud to ask -- and the rod quenches them where they stand, across the"
     " reach of thine eye. Every pouring spends its measures; the rod keeps its own ledger."),
    ("Codex_H5", 3, "Icon_Caraffe_Water",
     "III. Of the Refilling. The blue rod is refilled without ceremony, for water is owed to"
     " all things: DRINK, and it drinks with thee -- pure water or foul, the rod does not"
     " judge. Or WADE into pond or river, and it fills through thy boots. A rod so easily"
     " sated should teach thee suspicion of the next rung, which is not."),
    # -------- ELECTRICK WAND (the second rung) --------
    ("Codex_W1", 4, "Icon_Caraffe_Water",
     "I. Of the Things to be Gathered. Ere the tempest breaks, thou shalt set forth these five"
     " offerings, that the storm find them pleasing and stay its hand a while: WATER -- clear of"
     " every impurity, boiled and still as a drowned man's final breath. COMB OF THE HONEYBEE --"
     " the wax-wrought cell, sweet labour reft from the golden host."),
    ("Codex_W2", 4, "Icon_Sunflower",
     "LEAF OF THE TREE -- plucked living and green from the crown of an elder wood. CLAY OF THE"
     " EARTH -- dug cold and yielding from the deep and lightless belly of the ground. FLOWER OF"
     " THE SUN -- the great bloom that turns its face forever toward the light, stolen and laid"
     " down in the dark to spite the elder brother."),
    ("Codex_W3", 4, "AnimalIcon_Sheep",
     "And -- most dreadful of all -- thou shalt bring an innocent lamb, unblemished and free of"
     " sin, that hath done no wrong in all its short days, and suspecteth no ill of thee."),
    ("Codex_W4", 4, "ICON_Honey",
     "II. Of the Laying of the Offering. Lay the gathered catalysts about the star, each within"
     " two strides of a candle, and in the very heart of the shape lay down the lamb."
     "\n\n. . . . flower of the sun . . . .\ncomb of bee . . . . clay of earth\n. . . . . . the"
     " lamb . . . . . .\n. leaf of tree . . pure water .\n\n-- the pattern, as it must be drawn --"),
    ("Codex_W5", 4, "Icon_Stormy",
     "III. Of the Coming of the Storm. Now wait. Wait while the clouds swell black and the very"
     " air turns to iron upon the tongue. When the storm is come in its full and terrible"
     " strength, and the heavens are split by white fire, the lightning shall descend upon the"
     " star. The lamb shall be consumed, and its innocence spent like a coin dropped into a"
     " beggar's hand. And in that same breath every BLUE rod held by all who stand and bear"
     " witness shall boil dry and drink the sky's own fury in the water's stead. Mark it well:"
     " the fire only enters where the water went before -- a rod that never drank the deluge"
     " stays cold, and the sky will not look at it. The quenched is made ELECTRICK, and burns"
     " thereafter yellow as noon.\n\n-- blink not when the fire falls, lest thy rod stay cold --"),
    ("Codex_W6", 4, "ICON_Honey",
     "IV. Of the Wielding, and the Refilling. Draw the wand and look upon what offends thee, and"
     " strike -- the sky answers WHERE THINE EYE RESTS, in any weather, asking no leave of the"
     " clouds. One bolt, one payment: the wand then sleeps again, dim and spent. To refill it,"
     " thou needst not the pentagram twice: stand within five paces of any bolt thou didst not"
     " cast, wand drawn, feet planted, and let thy rod drink from thy neighbour's misfortune."
     " The storm does not care WHOSE hand holds the cup."),
    ("Codex_W7", 4, "Icon_Stormy",
     "But mark this well, and forget it never: the heavens keep a ledger, and every spark is a"
     " debt set down against thy name. The lamb was but the first payment.\n\nThe sky will"
     " remember the rest."),
]

def build_codex_enum():
    def patch(d):
        enum = d["Exports"][0]["Enum"]
        tup = "System.Tuple`2[[UAssetAPI.UnrealTypes.FName, UAssetAPI],[System.Int64, System.Private.CoreLib]], System.Private.CoreLib"
        n = len(CODEX_SECTIONS)
        enum["Names"] = [
            {"$type": tup, "Item1": f"ETempestCodexCategory::NewEnumerator{i}", "Item2": i}
            for i in range(n)
        ] + [{"$type": tup, "Item1": "ETempestCodexCategory::ETempestCodexCategory_MAX", "Item2": n}]
        pairs = []
        for i, title in enumerate(CODEX_SECTIONS):
            key = {"$type": "UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI",
                   "Name": "DisplayNameMap", "ArrayIndex": 0, "PropertyGuid": None, "IsZero": False,
                   "PropertyTagFlags": "None", "PropertyTypeName": None,
                   "PropertyTagExtensions": "NoExtension", "Value": f"NewEnumerator{i}"}
            pairs.append([key, base_text("DisplayNameMap", title)])
        d["Exports"][0]["Data"][0]["Value"] = pairs
    clone_asset(os.path.join(TIPS_DIR, "EGameplayTipCategory.uasset"),
                os.path.join(TIPS_DIR, "ETempestCodexCategory.uasset"),
                [("EGameplayTipCategory", "ETempestCodexCategory")], patch=patch)

def build_codex_table():
    def patch(d):
        rows = d["Exports"][0]["Table"]["Data"]
        template = copy.deepcopy(rows[0])
        del rows[:]
        icon_idx = {}
        for _, _, icon, _ in CODEX_PAGES:
            if icon not in icon_idx:
                idir = ICON_DIR_OVERRIDES.get(icon, ICONS_ART)
                icon_idx[icon] = add_import_pair(d, idir + icon, icon, "Texture2D")
        for key, cat, icon, text in CODEX_PAGES:
            row = copy.deepcopy(template)
            row["Name"] = key
            tip_i = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Tip")
            row["Value"][tip_i] = base_text(row["Value"][tip_i]["Name"], text)
            field(row, "Icon")["Value"] = icon_idx[icon]
            cats = field(row, "Category")
            one = copy.deepcopy(cats["Value"][0])
            one["Name"] = "0"
            one["Value"] = CAT_FNAME[cat]
            cats["Value"] = [one]
            rows.append(row)
            add_rowkey(d, key, "DB_TempestCodex")
        fix_name_count(d)
        print(f"codex table: {len(rows)} pages")
    clone_asset(os.path.join(TIPS_DIR, "DB_GameplayTips.uasset"),
                os.path.join(TIPS_DIR, "DB_TempestCodex.uasset"),
                [("DB_GameplayTips", "DB_TempestCodex")], preloads=S_TIP, patch=patch)

def build_codex_widgets():
    # widgets carry ByteProperties typed to our cloned enum; UAssetAPI can only re-serialize them
    # unversioned if the enum is registered in the usmap -> preload the STAGED enum clone
    # (wandsmith's preloader registers EnumExports since 2026-07-21)
    enum_pre = os.path.join(STAGED, TIPS_DIR, "ETempestCodexCategory.uasset")
    # category chip: label source = the enum DisplayNameMap (Conv_NumericPropertyToText), so only
    # the enum import needs retargeting
    clone_asset(os.path.join(WC_DIR, "WC_SurvivalGuideCategory.uasset"),
                os.path.join(WC_DIR, "WC_TempestCodexCategory.uasset"),
                [("WC_SurvivalGuideCategory", "WC_TempestCodexCategory"),
                 ("EGameplayTipCategory", "ETempestCodexCategory")],
                preloads=enum_pre)

    # page widget: text block sized up for the long passages
    def patch_page(d):
        for e in d["Exports"]:
            if str(e.get("ObjectName")) == "TXT_GameplayTip":
                for p in e.get("Data", []):
                    if p.get("Name") == "Font":
                        for m in p.get("Value", []):
                            if m.get("Name") == "Size":
                                m["Value"] = 15.0
    clone_asset(os.path.join(WC_DIR, "WC_GameplayTip.uasset"),
                os.path.join(WC_DIR, "WC_TempestPage.uasset"),
                [("WC_GameplayTip", "WC_TempestPage")], patch=patch_page)

    # the book itself
    def patch_book(d):
        # GenerateCategoryButtons iterates category indexes 0..N-1 with N BAKED at BP compile time
        # as MakeLiteralInt(9). Patch the ONE literal to our section count. Same-width int const ->
        # every serialized bytecode offset stays valid.
        gen = next(e for e in d["Exports"]
                   if str(e.get("ObjectName")) == "GenerateCategoryButtons"
                   and "FunctionExport" in e["$type"])
        hits = []
        def walk(x):
            if isinstance(x, dict):
                if str(x.get("$type", "")).endswith("EX_IntConst, UAssetAPI") and x.get("Value") == 9:
                    hits.append(x)
                for k, v in x.items():
                    if k != "$type":
                        walk(v)
            elif isinstance(x, list):
                for v in x:
                    walk(v)
        walk(gen.get("ScriptBytecode") or [])
        if len(hits) != 1:
            sys.exit(f"W_TempestCodex: expected exactly one MakeLiteralInt(9) in "
                     f"GenerateCategoryButtons, found {len(hits)}")
        hits[0]["Value"] = len(CODEX_SECTIONS)
        # title: the original pulls "Survival Guide" from the ST_ReusableTerms string table;
        # inline ours instead
        tb = next(e for e in d["Exports"] if str(e.get("ObjectName")) == "TextBlock_1")
        for i, p in enumerate(tb.get("Data", [])):
            if p.get("Name") == "Text":
                tb["Data"][i] = base_text("Text", "Tempest Codex")
    clone_asset(os.path.join(WIDGETS_DIR, "W_SurvivalGuide.uasset"),
                os.path.join(WIDGETS_DIR, "W_TempestCodex.uasset"),
                [("WC_SurvivalGuideCategory", "WC_TempestCodexCategory"),
                 ("WC_GameplayTip", "WC_TempestPage"),
                 ("DB_GameplayTips", "DB_TempestCodex"),
                 ("EGameplayTipCategory", "ETempestCodexCategory"),
                 ("W_SurvivalGuide", "W_TempestCodex")],
                preloads=enum_pre, patch=patch_book)

def build_codex_bps():
    # the inventory/world item: a Handbook clone (merchant-book mesh, dark tome look)
    clone_asset(os.path.join(ITEMS_DIR, "ItemActors", "BP_Handbook_Item.uasset"),
                os.path.join(ITEMS_DIR, "ItemActors", "BP_TempestCodex_Item.uasset"),
                [("BP_Handbook_Item", "BP_TempestCodex_Item")], preloads=MASTER_BP)
    # the placed, readable book. Replaces:
    #   * item ref     -> breaking the placed codex returns a codex, not a handbook
    #   * SM_Handbook  -> SM_Book_Merchant (visually distinct from the placed survival guide)
    #   * UI_OpenSurvivalGuide -> ForceCloseInteractableUIs (no-arg for no-arg; the codex UI is
    #     opened by features/codex.lua off this clone's interact event)
    place_master = ";".join([
        os.path.join(LEGACY, PLACE_DIR, "_BP_Placeable_MASTER.uasset"),
        os.path.join(LEGACY, "Solarpunk/Content/Code/Interactables/Framework",
                     "BPC_InteractableLogic.uasset"),
    ])
    # HARD-IMPORT the codex widget class from the placeable. The five codex-UI packages
    # (W/WC_* widgets, DB_TempestCodex, ETempestCodexCategory) are referenced by NOTHING the game
    # loads, and UE4SS LoadAsset can't pull pak packages that aren't in the game's AssetRegistry
    # (it returns null silently -- no SkipPackage log line). An import-table edge makes the zen
    # loader pull W_TempestCodex whenever a placed codex loads, and the widget's own imports drag
    # in the table + enum + both sub-widgets. (Same proven trick as the icon/item-BP imports in
    # DB_Items -- retoc keeps import-map entries it can't see referenced, and the runtime eagerly
    # loads every ImportedPackage.)
    def _patch_placeable(d):
        cls_idx = add_import_pair(
            d, "/Game/UI/Widgets/W_TempestCodex", "W_TempestCodex_C",
            "WidgetBlueprintGeneratedClass", "/Script/UMG")
        # The import edge above only LOADS the widget chain when a placed codex loads -- nothing
        # holds a live reference afterwards, so the post-load GC evicts it minutes later and
        # interact-time ensureWidget finds the class gone (seen live 2026-07-22 08:54). A script
        # OBJECT REFERENCE is a real GC edge: UStruct rebuilds ScriptAndPropertyObjectReferences
        # from its bytecode at load, and AddReferencedObjects reports those to the GC for as long
        # as the class is loaded. Plant an EX_ObjectConst on the interact event, AFTER EX_Return
        # and before EX_EndOfScript: serialized (=> collected) but never executed.
        fn = next(e for e in d["Exports"]
                  if "OnInteractedWith" in str(e.get("ObjectName", "")) and e.get("ScriptBytecode"))
        sb = fn["ScriptBytecode"]
        last = sb[-1].get("$type", "")
        if "EX_EndOfScript" not in last:
            sys.exit(f"placeable root: unexpected last opcode {last}")
        sb.insert(len(sb) - 1, {
            "$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_ObjectConst, UAssetAPI",
            "Value": cls_idx,
        })
        # PICK-UP FIX (RE'd 2026-07-22): pack-up is a VISIBILITY-channel line trace
        # (BP_MainPlayerCharacter.TraceForPlaceable, simple collision only) gated purely by
        # IsAxeDestroyable (is a placeable, not a plant, not IUnplaceable) -- but our
        # SM_Book_Merchant mesh ships an EMPTY BodySetup, so the trace passes through the book
        # and the codex can never be packed up (interact still works: E uses the separate
        # Interactable channel the InteractionBox blocks). Make that same box block Visibility
        # too -- the vanilla-furniture-style box approximation for aim/pickup traces.
        box = next(e for e in d["Exports"]
                   if e.get("ObjectName") == "InteractionBox_GEN_VARIABLE")
        def _prop(props, name):
            return next(p for p in props if p.get("Name") == name)
        ra = _prop(_prop(_prop(box["Data"], "BodyInstance")["Value"],
                         "CollisionResponses")["Value"], "ResponseArray")
        vis = next(el for el in ra["Value"]
                   if _prop(el["Value"], "Channel")["Value"] == "Visibility")
        _prop(vis["Value"], "Response")["Value"] = "ECR_Block"
    clone_asset(os.path.join(PLACE_DIR, "BP_SurvivalGuide_Placeable.uasset"),
                os.path.join(PLACE_DIR, "BP_TempestCodex_Placeable.uasset"),
                [("BP_SurvivalGuide_Placeable", "BP_TempestCodex_Placeable"),
                 ("BP_Handbook_Item", "BP_TempestCodex_Item"),
                 ("SM_Handbook", "SM_Book_Merchant"),
                 ("UI_OpenSurvivalGuide", "ForceCloseInteractableUIs")],
                preloads=place_master,
                patch=_patch_placeable)

def patch_db_recipes():
    """DB_CraftingRecipes: TempestCodex + MundaneWand, both BENCH-only and NOT starting recipes
    (they are unlocked by the TempestCodex research row -- see patch_db_researchables). The
    SurvivalGuide row is still the structural template; its hand+bench locations are trimmed to
    bench (ECraftingLocations::NewEnumerator1) and StartingRecipy flipped false. Returns
    {row_name: RecipyID} for the research row's UnlockingRecepieIDs."""
    rel = "Solarpunk/Content/Code/Crafting/Framework_and_Data"
    src = os.path.join(LEGACY, rel, "DB_CraftingRecipes.uasset")
    j = os.path.join(OUT, "db_recipes_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]

    def part_slot(template_slot, item_idx, qty):
        s = copy.deepcopy(template_slot)
        for f in s["Value"]:
            n = f["Name"].split("_")[0]
            if n == "Item":
                f["Value"] = item_idx
            elif n == "Quantity":
                f["Value"] = qty
                f["IsZero"] = False
        return s

    def cls_idx(name):
        return add_import_pair(d, f"/Game/Code/Inventory_Items/ItemActors/{name[:-2]}", name,
                               "BlueprintGeneratedClass")

    guide = next(r for r in rows if r["Name"] == "SurvivalGuide")
    next_id = max(field(r, "RecipyID")["Value"] for r in rows) + 1
    recipe_ids = {}

    def add_recipe(row_name, product_cls, parts):
        row = copy.deepcopy(guide)
        row["Name"] = row_name
        rid = field(row, "RecipyID")
        rid["Value"] = next_id + (0 if row_name == "TempestCodex" else 1)
        rid["IsZero"] = False
        recipe_ids[row_name] = rid["Value"]
        # research-gated: not known from the start, made at the crafting bench only
        sr = field(row, "StartingRecipy")
        sr["Value"], sr["IsZero"] = False, True
        loc = field(row, "CraftingLocations")
        loc["Value"] = [e for e in loc["Value"]
                        if e["Value"] == "ECraftingLocations::NewEnumerator1"]
        loc["Value"][0]["Name"] = "0"
        single = field(row, "SingleRecipies")["Value"][0]
        ep = next(p for p in single["Value"] if p["Name"].split("_")[0] == "Endproduct")
        for f in ep["Value"][0]["Value"]:
            if f["Name"].split("_")[0] == "Item":
                f["Value"] = cls_idx(product_cls)
        cp = next(p for p in single["Value"] if p["Name"].split("_")[0] == "CraftingParts")
        template_slot = cp["Value"][0]
        cp["Value"] = [part_slot(template_slot, cls_idx(c), q) for c, q in parts]
        rows.append(row)
        add_rowkey(d, row_name, "DB_CraftingRecipes")
        print(f"recipe {row_name}: " + ", ".join(f"{q}x {c}" for c, q in parts))

    # the codex: leaf-pages bound between clay boards on a spine of wood
    add_recipe("TempestCodex", "BP_TempestCodex_Item_C",
               [("BP_Log_Item_C", 1), ("BP_Leaf_Item_C", 2), ("BP_Clay_Item_C", 1)])
    # the mundane implement: an honest stick sealed with beeswax
    add_recipe("MundaneWand", "BP_MundaneWand_Item_C",
               [("BP_Stick_Item_C", 1), ("BP_Beeswax_Item_C", 1)])

    # The keeper: a hidden row whose one "ingredient" slot holds the W_TempestCodex_C class ref.
    # Purpose is GC ROOTING, not crafting: DataTable row object refs are GC-visible (this is how
    # DB_Items keeps every item BP class resident all session), so the always-loaded recipe table
    # pins the codex reader chain -- the widget class's own baked refs then hold DB_TempestCodex,
    # the WC_* page widgets and the enum. Without this the chain loads once at BOOT (via the
    # placeable's import edge, before any PlayerController exists) and the post-load GC evicts it
    # ~2s later, unrecoverable: UE4SS LoadAsset needs an AssetRegistry entry our pak doesn't
    # ship, and the reflected LoadClassAsset_Blocking FATALS when called from Lua (UE4SS cannot
    # marshal TSoftClassPtr -- proven 2026-07-21, the menu-idle launch crash). Empty
    # CraftingLocations + an ID no research unlocks = invisible to every crafting UI; the end
    # product stays the real codex item class in case anything ever reads it.
    keeper = copy.deepcopy(guide)
    keeper["Name"] = "TempestCodexKeeper"
    rid = field(keeper, "RecipyID")
    rid["Value"], rid["IsZero"] = next_id + 2, False
    sr = field(keeper, "StartingRecipy")
    sr["Value"], sr["IsZero"] = False, True
    field(keeper, "CraftingLocations")["Value"] = []
    single = field(keeper, "SingleRecipies")["Value"][0]
    ep = next(p for p in single["Value"] if p["Name"].split("_")[0] == "Endproduct")
    for f in ep["Value"][0]["Value"]:
        if f["Name"].split("_")[0] == "Item":
            f["Value"] = cls_idx("BP_TempestCodex_Item_C")
    widget_idx = add_import_pair(d, "/Game/UI/Widgets/W_TempestCodex", "W_TempestCodex_C",
                                 "WidgetBlueprintGeneratedClass", "/Script/UMG")
    cp = next(p for p in single["Value"] if p["Name"].split("_")[0] == "CraftingParts")
    cp["Value"] = [part_slot(cp["Value"][0], widget_idx, 0)]
    rows.append(keeper)
    add_rowkey(d, "TempestCodexKeeper", "DB_CraftingRecipes")
    print("recipe TempestCodexKeeper: hidden GC-keeper row roots W_TempestCodex_C")

    fix_name_count(d)
    jout = os.path.join(OUT, "db_recipes_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    # the row structs (S_CraftingRecipy etc.) are cooked INSIDE this table's own package ->
    # preload the source table itself to register them
    fromjson(jout, os.path.join(STAGED, rel, "DB_CraftingRecipes.uasset"), preloads=src)
    print(f"DB_CraftingRecipes patched: {len(rows)} rows")
    return recipe_ids

def patch_db_researchables(recipe_ids):
    """DB_Researchables: "The Dark Arts" research card unlocking BOTH bench recipes (the codex
    and the mundane wand) for 1 beeswax + 1 clay + 1 leaf. RainCollector is the template
    (IsLevel=False, ResearchType EItemType::NewEnumerator10 = the buildables/tools tab), but
    unlike it we are TIER-2 GATED: StartingResearch=False + our ID appended to LvL_2's
    UnlockingResearchIDs. Visibility model (RE'd from W_ResearchTable + BP_MainPlayerController):
    a card shows only if an S_SavedResearch{id, Researched=false} entry exists in the player's
    saved Researches array; completing a card adds entries for its UnlockingResearchIDs. Saves
    that already researched LvL_2 never re-fire it -- features/codex.lua carries the one-time
    save migration for those."""
    rel = "Solarpunk/Content/Code/Research/Framework"
    src = os.path.join(LEGACY, rel, "DB_Researchables.uasset")
    j = os.path.join(OUT, "db_research_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]

    tmpl = next(r for r in rows if r["Name"] == "RainCollector")
    row = copy.deepcopy(tmpl)
    row["Name"] = "TempestCodex"
    rid = field(row, "ResearchableID")
    rid["Value"] = max(field(r, "ResearchableID")["Value"] for r in rows) + 1
    rid["IsZero"] = False
    ni = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Name")
    row["Value"][ni] = base_text(row["Value"][ni]["Name"], "The Dark Arts")
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    row["Value"][di] = base_text(
        row["Value"][di]["Name"],
        "Bind the old and evil geometry into pages, and learn the shaping of the mundane rod."
        " The sky keeps a ledger; this is how thou opened thine account.")
    # staged in the stick-icon dir (uncompressed BGRA container -- see the make_icons gotcha)
    field(row, "Icon")["Value"] = add_import_pair(
        d, "/Game/UI/ItemIcons/Icon_DarkArts", "Icon_DarkArts", "Texture2D")

    # unlock both new recipes under this one card (grouped with the book)
    ur = field(row, "UnlockingRecepieIDs")
    id_tmpl = ur["Value"][0]
    ur["Value"] = []
    for i, name in enumerate(("TempestCodex", "MundaneWand")):
        e = copy.deepcopy(id_tmpl)
        e["Name"], e["Value"], e["IsZero"] = str(i), recipe_ids[name], False
        ur["Value"].append(e)

    # research cost: 1 beeswax + 1 clay + 1 leaf
    needed = field(row, "ItemsNeeded")
    slot_tmpl = needed["Value"][0]
    needed["Value"] = []
    for i, cls in enumerate(("BP_Beeswax_Item_C", "BP_Clay_Item_C", "BP_Leaf_Item_C")):
        slot = copy.deepcopy(slot_tmpl)
        slot["Name"] = str(i)
        for f in slot["Value"]:
            n = f["Name"].split("_")[0]
            if n == "Item":
                f["Value"] = add_import_pair(
                    d, f"/Game/Code/Inventory_Items/ItemActors/{cls[:-2]}", cls,
                    "BlueprintGeneratedClass")
            elif n == "Quantity":
                f["Value"], f["IsZero"] = 1, False
        needed["Value"].append(slot)

    # tier-2 gate: not offered at start; LvL_2 completion reveals it
    field(row, "StartingResearch")["Value"] = False
    lvl2 = next(r for r in rows if r["Name"] == "LvL_2")
    ur2 = field(lvl2, "UnlockingResearchIDs")
    gate = copy.deepcopy(ur2["Value"][0])
    gate["Name"] = str(len(ur2["Value"]))
    gate["Value"], gate["IsZero"] = rid["Value"], False
    ur2["Value"].append(gate)

    rows.append(row)
    add_rowkey(d, "TempestCodex", "DB_Researchables")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_research_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    # S_Researchable is a standalone struct asset (NOT cooked in-package like S_CraftingRecipy)
    fromjson(jout, os.path.join(STAGED, rel, "DB_Researchables.uasset"),
             preloads=os.path.join(LEGACY, rel, "S_Researchable.uasset"))
    print(f"DB_Researchables patched: {len(rows)} rows, research id {rid['Value']}, "
          f"unlocks recipes {sorted(recipe_ids.values())}")

def patch_db_buildables():
    """DB_Buildables: the TempestCodex placeable row (SurvivalGuide-shaped; items are matched by
    DB_Items ROW NAME via ItemsNeeded, so the row key + RowName both say TempestCodex)."""
    rel = "Solarpunk/Content/Code/Building_Placing/Framework_and_Data"
    src = os.path.join(LEGACY, rel, "DB_Buildables.uasset")
    j = os.path.join(OUT, "db_buildables_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]
    guide = next(r for r in rows if r["Name"] == "SurvivalGuide")
    row = copy.deepcopy(guide)
    row["Name"] = "TempestCodex"
    field(row, "Actor")["Value"] = add_import_pair(
        d, "/Game/Code/Building_Placing/Placeables/BP_TempestCodex_Placeable",
        "BP_TempestCodex_Placeable_C", "BlueprintGeneratedClass")
    field(row, "Mesh")["Value"] = add_import_pair(
        d, "/Game/Art/StaticMeshes/SM_Book_Merchant", "SM_Book_Merchant", "StaticMesh")
    for slot in field(row, "ItemsNeeded")["Value"]:
        for f in slot["Value"]:
            if f["Name"].split("_")[0] == "Item":
                for inner in f["Value"]:
                    if inner.get("Name") == "RowName":
                        inner["Value"] = "TempestCodex"
    rows.append(row)
    add_rowkey(d, "TempestCodex", "DB_Buildables")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_buildables_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, rel, "DB_Buildables.uasset"), preloads=src)
    print(f"DB_Buildables patched: {len(rows)} rows")

def build_codex():
    build_codex_enum()
    build_codex_table()
    build_codex_widgets()
    build_codex_bps()
    recipe_ids = patch_db_recipes()
    patch_db_researchables(recipe_ids)
    patch_db_buildables()

# ---------------------------------------------------------------- verify (round-trip)
def verify_pak():
    """retoc to-legacy the built pak and re-parse every table we touched: catches the row-key
    name-drop gotcha (and any serialization slip) OFFLINE instead of as a world-load crash."""
    vd = os.path.join(OUT, "verify_pak")
    vin = os.path.join(OUT, "verify_pak_in")
    shutil.rmtree(vd, ignore_errors=True)
    shutil.rmtree(vin, ignore_errors=True)
    os.makedirs(vin)
    # a lone mod container has no ScriptObjects chunk -- to-legacy needs the game's global.* beside
    # it to resolve native class ids
    for f in ("global.utoc", "global.ucas"):
        shutil.copy2(os.path.join(GAME_PAKS, f), vin)
    for ext in (".utoc", ".ucas", ".pak"):
        shutil.copy2(os.path.join(OUT, "z_SolarpunkWand_P" + ext), vin)
    run(RETOC, "to-legacy", vin, vd)
    # The round-tripped assets come back as RawExports (UAssetAPI cannot structurally re-read
    # retoc's legacy output), so the check targets the serialization failure mode directly: the
    # rebuilt NAME MAP's PREFIX -- every name below the table's own name, i.e. everything export
    # data references by index -- must survive the round trip VERBATIM AND IN ORDER. A dropped
    # name past the end is the fatal 'Bad name index' crash; a dropped name with filler behind
    # it silently MISNAMES rows (both really happened -- membership-only checks caught neither;
    # the fix is fix_name_count()).
    def names_of(rel, preloads=""):
        vj = os.path.join(OUT, "verify_" + os.path.basename(rel) + ".json")
        run(WS, "tojson", USMAP, os.path.join(vd, rel), vj, "VER_UE5_6", preloads)
        dd = json.load(open(vj, encoding="utf-8"))
        return [str(n) for n in dd["NameMap"]]
    def check_prefix(rel, patched_json, anchor):
        post = names_of(rel)
        pre = [str(n) for n in json.load(open(patched_json, encoding="utf-8"))["NameMap"]]
        a = pre.index(anchor)
        if post[:a] != pre[:a]:
            drops = [(i, n) for i, n in enumerate(pre[:a]) if i >= len(post) or post[i] != n][:6]
            sys.exit(f"{anchor}: round-trip name-map prefix mismatch (first diffs {drops}) -- "
                     "export-data name indices would misresolve at load")
        return post
    check_prefix(ITEMS_DIR + "/Framework_and_Data/DB_Items.uasset",
                 os.path.join(OUT, "db_items_patched.json"), "DB_Items")
    check_prefix("Solarpunk/Content/Code/Crafting/Framework_and_Data/DB_CraftingRecipes.uasset",
                 os.path.join(OUT, "db_recipes_patched.json"), "DB_CraftingRecipes")
    check_prefix("Solarpunk/Content/Code/Building_Placing/Framework_and_Data/DB_Buildables.uasset",
                 os.path.join(OUT, "db_buildables_patched.json"), "DB_Buildables")
    check_prefix("Solarpunk/Content/Code/Research/Framework/DB_Researchables.uasset",
                 os.path.join(OUT, "db_research_patched.json"), "DB_Researchables")
    pages = check_prefix(TIPS_DIR + "/DB_TempestCodex.uasset",
                         os.path.join(OUT, "DB_TempestCodex.json"), "DB_TempestCodex")
    for key, _, _, _ in CODEX_PAGES:
        assert key in pages, f"DB_TempestCodex lost page key {key}"
    # the widget + enum + BPs just need to round-trip parse (widgets carry ByteProperties typed to
    # the cloned enum -> preload it for the read too)
    enum_pre = os.path.join(STAGED, TIPS_DIR, "ETempestCodexCategory.uasset")
    for rel, pre in ((WIDGETS_DIR + "/W_TempestCodex.uasset", enum_pre),
                     (TIPS_DIR + "/ETempestCodexCategory.uasset", ""),
                     (PLACE_DIR + "/BP_TempestCodex_Placeable.uasset", "")):
        vj = os.path.join(OUT, "verify_" + os.path.basename(rel) + ".json")
        run(WS, "tojson", USMAP, os.path.join(vd, rel), vj, "VER_UE5_6", pre)
    print("verify: all tables + widgets survive the zen round-trip")

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
    clone_bp("BP_HydrationWand_Item")
    clone_bp("BP_ElectricWand_Item")
    clone_bp("BP_ChargedElectricWand_Item")
    make_icons()
    build_codex()
    patch_db_items()
    pack()
    verify_pak()
    print("DONE")
