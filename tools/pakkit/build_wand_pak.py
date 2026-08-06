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
S_SMELT = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_Smeltable.uasset")
S_SLOT  = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_InventorySlotSlim.uasset")

def tojson(asset, out, preloads=""):
    run(WS, "tojson", USMAP, asset, out, "VER_UE5_6", preloads)

def fromjson(src, out, preloads=""):
    os.makedirs(os.path.dirname(out), exist_ok=True)
    run(WS, "fromjson", USMAP, src, out, "VER_UE5_6", preloads)

def key32():
    return uuid.uuid4().hex.upper()

# ---------------------------------------------------------------- 1. clone item BPs
def clone_item_bp(src_name, new_name):
    """Clone any flat ItemActors BP by JSON rename round-trip (imports keep the vanilla meshes/
    materials, so nothing uncooked is ever referenced). src_name must not be a prefix of another
    name the asset references (BP_Stick_Item, BP_FishingRod_Item, BP_Egg_Item, BP_Truffle_Item
    all verified clean)."""
    src = os.path.join(LEGACY, ITEMS_DIR, "ItemActors", f"{src_name}.uasset")
    j = os.path.join(OUT, f"bp_{src_name.lower()}.json")
    tojson(src, j)
    text = open(j, encoding="utf-8").read()
    text = text.replace(src_name, new_name)
    jout = os.path.join(OUT, f"{new_name}.json")
    open(jout, "w", encoding="utf-8").write(text)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "ItemActors", f"{new_name}.uasset"),
             preloads=MASTER_BP)
    print(f"cloned {src_name} -> {new_name}")

def clone_bp(new_name):
    clone_item_bp("BP_Stick_Item", new_name)

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

def _verdant(book):
    """Re-ink an open-book BGRA image living-green, in place. Sibling of _indigo: same open-book
    silhouette, different ink, so the Codex and the Handbook read as a matched pair on the bar."""
    for i in range(0, len(book), 4):
        B, G, R, A = book[i], book[i + 1], book[i + 2], book[i + 3]
        if A == 0:
            continue
        L = 0.299 * R + 0.587 * G + 0.114 * B
        book[i]     = min(255, int(L * 0.35))
        book[i + 1] = min(255, int(L * 0.90 + 30))
        book[i + 2] = min(255, int(L * 0.45 + 10))
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
    # The Tempest Handbook inventory icon: the same art re-inked living-green.
    _stage_bgra_icon("Icon_TempestHandbook", _verdant(_handbook_bgra256()))
    make_darkarts_icon()

# ---------------------------------------------------------------- 1c. fishing icons
# (fishing-overhaul, 2026-07-28) Three new item icons, each recolored from the vanilla art and
# staged as a NEW 256x256 BGRA texture in the proven Icon_Stick container (never an override):
#   Icon_FishingrodDiamond  diamond-blue rod        (from Icon_Fishingrod, PF_DXT5 256x256)
#   Icon_EggGold            gilded egg              (from Icon_Egg,        PF_DXT5 256x256)
#   Icon_TruffleGold        gilded truffle          (from Icon_Truffle,    PF_B8G8R8A8 292x251!)
# The truffle icon is NON-SQUARE uncompressed -- the only one of its kind met so far -- so the
# loader below reads dims from the mip footer instead of assuming squares, and _fit256 letterboxes
# into the stick container. Formats are sniffed from the platform header (the Icon_Handbook DXT5
# gotcha: byte length alone cannot distinguish DXT5 512 from BGRA 256).

def _load_icon_bgra(src_dir, src_name):
    """Any icon -> (BGRA bytearray, W, H). Handles PF_B8G8R8A8 (any dims) and PF_DXT5."""
    src = os.path.join(LEGACY, src_dir, src_name + ".uasset")
    j = os.path.join(OUT, f"icon_src_{src_name}.json")
    if not os.path.exists(j):
        tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    raw = base64.b64decode(d["Exports"][0]["Extras"])
    W, H, Z = struct.unpack_from("<III", raw, len(raw) - MIP_FOOTER)
    if Z != 1 or not (4 <= W <= 4096 and 4 <= H <= 4096):
        sys.exit(f"{src_name}: mip footer reads ({W},{H},{Z}) -- layout assumption broken")
    if b"PF_B8G8R8A8" in raw[:200]:
        need = W * H * 4
        return bytearray(raw[len(raw) - MIP_FOOTER - need:len(raw) - MIP_FOOTER]), W, H
    if b"PF_DXT5" in raw[:200]:
        if W % 4 or H % 4:
            sys.exit(f"{src_name}: DXT5 dims ({W},{H}) not block-aligned")
        need = (W // 4) * (H // 4) * 16
        return _dxt5_decode(raw[len(raw) - MIP_FOOTER - need:len(raw) - MIP_FOOTER], W, H), W, H
    sys.exit(f"{src_name}: pixel format not PF_B8G8R8A8/PF_DXT5 -- teach _load_icon_bgra first")

def _fit256(bgra, W, H):
    """Nearest-neighbour fit into a centred 256x256 canvas (transparent letterbox)."""
    if (W, H) == (256, 256):
        return bgra
    out = bytearray(256 * 256 * 4)
    scale = max(W, H) / 256.0
    ox = (256 - W / scale) / 2.0
    oy = (256 - H / scale) / 2.0
    for y in range(256):
        sy = int((y - oy) * scale)
        if sy < 0 or sy >= H:
            continue
        for x in range(256):
            sx = int((x - ox) * scale)
            if sx < 0 or sx >= W:
                continue
            o, s = (y * 256 + x) * 4, (sy * W + sx) * 4
            out[o:o + 4] = bgra[s:s + 4]
    return out

def _tint_bgra(bgra, tint):
    """Apply a TINTS-style luminance ramp in place (alpha carries the silhouette)."""
    for i in range(0, len(bgra), 4):
        B, G, R, A = bgra[i], bgra[i + 1], bgra[i + 2], bgra[i + 3]
        if A == 0:
            continue
        L = 0.299 * R + 0.587 * G + 0.114 * B
        b, g, r = tint(L)
        bgra[i]     = min(255, max(0, int(b)))
        bgra[i + 1] = min(255, max(0, int(g)))
        bgra[i + 2] = min(255, max(0, int(r)))
    return bgra

FISHING_TINTS = {
    # (B, G, R) ramps: gold = warm high-R/high-G, diamond = pale ice blue
    "gold":    lambda L: (L * 0.18, L * 0.66 + 40, L * 0.92 + 64),
    "diamond": lambda L: (L * 1.00 + 55, L * 0.82 + 35, L * 0.55 + 15),
}

def make_fishing_icons():
    for new_name, src_name, tint in (
            ("Icon_FishingrodDiamond", "Icon_Fishingrod", FISHING_TINTS["diamond"]),
            ("Icon_EggGold",           "Icon_Egg",        FISHING_TINTS["gold"]),
            ("Icon_TruffleGold",       "Icon_Truffle",    FISHING_TINTS["gold"])):
        bgra, W, H = _load_icon_bgra(ART_ICONS_DIR, src_name)
        _stage_bgra_icon(new_name, _fit256(_tint_bgra(bgra, tint), W, H))

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
             tools_tab=False, extra_types=None, interaction=None):
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
    def _append_type(enum_val):
        e = copy.deepcopy(field(rasp, "ItemType")["Value"][0])
        e["Name"] = str(len(field(row, "ItemType")["Value"]))
        e["Value"] = f"EItemType::NewEnumerator{enum_val}"
        field(row, "ItemType")["Value"].append(e)
    if tools_tab:
        _append_type(1)
    # FURNACE INPUT-SLOT FILTER (offline RE of DB_Smeltables x DB_Items 2026-07-23): a valid
    # DB_Smeltables recipe is NOT sufficient -- the appliance's input slot rejects the item first,
    # by ItemType. EVERY furnace input carries T6 (ore: Iron/Clay/Sand/Quartz/Copper/Cobalt/Dough)
    # or T13 (cookable: dirty-water carafe, raw pizza, raw muffin); NONE is T5. The wand cloned
    # Raspberry's lone T5, so the slot turned it away despite the recipe being present and correct.
    # Fix: also carry T13 (the water-boiling appliance the user analogised to) AND T6 (the metal
    # furnace), so whichever appliance they use accepts the rod. T5 STAYS at index 0 -- the in-hand
    # render + world-load safety ride on the primary type; the slot check is array-membership
    # (same Array_CONTAINS shape as the crafting tabs), so appended types suffice. If a live test
    # shows the slot reads index 0 only, promote T13 to the front instead.
    for t in (extra_types or []):
        _append_type(t)
    # ALSO copy Raspberry's INTERACTION (I2). The game only renders an item in-hand when it has an
    # active "use" interaction -- a passive I0 (Stick) shows nothing (proven: T5+I0 => invisible).
    # I2 makes the game draw the palm-out hold + SM_Stick. The wand has empty DefaultAttribues, so
    # "eating" it should be a no-op (no food value to consume); casting stays on our own input hooks.
    # interaction=N overrides the enumerator: the DiamondFishingRod row passes 1 (tool) so the
    # hand-rebuild chokepoint (UpdateHandMeshesAndModes switches on ItemInteractionType, bytecode
    # RE 2026-07-28) takes the TOOL branch -- whose hardcoded class ladder doesn't know our row and
    # returns WITHOUT touching the hand actor. A UI close then never destroys the mod-seated rod
    # (a thrown line survives the TAB inventory); the old I2 typing routed every rebuild through
    # UpdateHandConsumable's baked food map, which nulled + destroyed the hand actor per close.
    # ItemType stays T5-primary -- ONLY the full tool taxonomy (ItemType [T1,T0] + durability,
    # commit 109fcd9) is the proven world-load crash, not the interaction byte.
    field(row, "ItemInteractionType")["Value"] = copy.deepcopy(field(rasp, "ItemInteractionType")["Value"])
    if interaction is not None:
        field(row, "ItemInteractionType")["Value"] = \
            f"EItemInteractionType::NewEnumerator{interaction}"
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

def clone_item_row(d, rows, src_name, row_name, display, desc, icon_idx, actor_idx,
                   recycler=None):
    """Clone an EXISTING game row wholesale (keeps its ItemType/interaction/stack -- the gold
    variants must behave exactly like their base items everywhere but price and look)."""
    src = next(r for r in rows if r["Name"] == src_name)
    row = copy.deepcopy(src)
    row["Name"] = row_name
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "DisplayName")
    row["Value"][di] = base_text(row["Value"][di]["Name"], display)
    de = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    row["Value"][de] = base_text(row["Value"][de]["Name"], desc)
    field(row, "Icon")["Value"] = icon_idx
    field(row, "ItemActor")["Value"] = actor_idx
    if recycler is not None:
        f = field(row, "RecyclerValue")
        f["Value"], f["IsZero"] = recycler, recycler == 0
    rows.append(row)
    add_rowkey_name(d, row_name)
    print(f"row {row_name} (clone of {src_name}) -> icon {icon_idx} actor {actor_idx}"
          + (f" recycler {recycler}" if recycler is not None else ""))

def make_book_row(d, rows, row_name, display, desc, icon_idx, actor_idx):
    """A readable-book item row: a Handbook-shaped placeable book (T10 place-to-read + T0), so the
    game's own placement system handles it -- DB_Buildables maps the row to our placeable clone."""
    hb = next(r for r in rows if r["Name"] == "Handbook")
    row = copy.deepcopy(hb)
    row["Name"] = row_name
    di = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "DisplayName")
    row["Value"][di] = base_text(row["Value"][di]["Name"], display)
    de = next(i for i, p in enumerate(row["Value"]) if p["Name"].split("_")[0] == "Description")
    row["Value"][de] = base_text(row["Value"][de]["Name"], desc)
    field(row, "Icon")["Value"] = icon_idx
    field(row, "ItemActor")["Value"] = actor_idx
    rows.append(row)
    add_rowkey_name(d, row_name)
    print(f"row {row_name} -> icon {icon_idx} actor {actor_idx}")

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
    # Book icons: the Handbook's open-book art re-inked (indigo for the Codex, green for the
    # Handbook), staged in the STICK's dir and container (uncompressed BGRA -- Icon_Handbook
    # itself is DXT5, see the make_icons gotcha).
    book_icons = {b["slug"]: add_texture_import(d, "Icon_Stick", b["item_icon"]) for b in BOOKS}

    mund_cls  = add_bp_imports(d, "BP_MundaneWand_Item")
    hydra_cls = add_bp_imports(d, "BP_HydrationWand_Item")
    elec_cls  = add_bp_imports(d, "BP_ElectricWand_Item")
    chg_cls   = add_bp_imports(d, "BP_ChargedElectricWand_Item")
    make_row(d, rows, "MundaneWand", "Mundane Wand",
             "A stick sealed with beeswax. It hums faintly when storms pass. The dark arts know its true name.",
             icon_brown, mund_cls, tools_tab=True)
    # The path of water: the chicken rite quenches a BLANK rod blue (one nature, forever).
    # durability 12 = the charge bar: one notch per 20-measure pour (240 max / 20).
    make_row(d, rows, "HydrationWand", "Hydration Wand",
             "A rod that remembers the rain. It pours what it has drunk, and it is always thirsty.",
             icon_blue, hydra_cls, durability=12)
    # "Electrick" with the k -- the occult spelling, like magick (user-requested rename; the ROW
    # KEYS stay ElectricWand/ChargedElectricWand -- renaming keys would re-fight the name-index
    # gotcha and break the mod's itemRows mapping for zero gain)
    # extra_types [13,6] = the furnace input-slot filter: T13 lets the energy furnace (where foul
    # water is boiled) accept the spent rod, T6 lets the metal furnace accept it. See make_row.
    make_row(d, rows, "ElectricWand", "Electrick Wand",
             "The bolt has been spent. The rod waits, dim gold, for the storm to fill it again.",
             icon_gold, elec_cls, extra_types=[13, 6])
    # durability 3 = the bolt count: the bar shows the three casts a full rod holds.
    make_row(d, rows, "ChargedElectricWand", "Charged Electrick Wand",
             "The storm sits caged in the rod, yellow-hot and howling. Loose it before it fades.",
             icon_yellow, chg_cls, durability=3)
    # the readable books (Tempest Codex, Tempest Handbook): Handbook-shaped place-to-read rows
    for b in BOOKS:
        make_book_row(d, rows, b["slug"], b["item_display"], b["item_desc"],
                      book_icons[b["slug"]], add_bp_imports(d, _names(b)["item"]))

    # ---- fishing-overhaul items (2026-07-28) ----
    icon_diarod  = add_texture_import(d, "Icon_Stick", "Icon_FishingrodDiamond")
    icon_goldegg = add_texture_import(d, "Icon_Stick", "Icon_EggGold")
    icon_goldtru = add_texture_import(d, "Icon_Stick", "Icon_TruffleGold")
    diarod_cls  = add_bp_imports(d, "BP_DiamondFishingRod_Item")
    goldegg_cls = add_bp_imports(d, "BP_GoldEgg_Item")
    goldtru_cls = add_bp_imports(d, "BP_GoldTruffle_Item")
    # The diamond rod row deliberately does NOT copy FishingRod's tool taxonomy (ItemType [T1,T0]
    # + durability on a NEW row = the proven world-load crash, commit 109fcd9): make_row's
    # wand-proven shape (T5 primary + T1 appended for the Tools tab + durability bar) loads clean,
    # and features/fishing.lua seats the REAL BP_HandItem_FishingRod on equip so it fishes like
    # the vanilla rod. Durability 999 (user spec 2026-07-30, down from 2000 -- keep in sync with
    # mapping.fishing.diamondDurability; fishing.lua clamps over-max rods in old saves).
    # interaction=1 (tool) is the never-uncast fix: rebuilds miss the tool ladder and leave the
    # cast rod actor alone (see make_row).
    make_row(d, rows, "DiamondFishingRod", "Diamond Fishing Rod",
             "Two cut diamonds crown the reel. Five times the endurance of a plain rod, and the"
             " deep things rise to meet it: twice the luck for rare and precious catches."
             " Its skillshot demands a finer touch, and pays only in jackpots.",
             icon_diarod, diarod_cls, durability=999, tools_tab=True, interaction=1)
    # THE VANILLA ROD IS REPLACED (user spec 2026-07-30): its class sits inside
    # UpdateHandMeshesAndModes' hardcoded tool ladder, so a UI close always destroys+respawns
    # its hand actor (uncasting a thrown line -- the Lua recast shim was its ceiling), and its
    # VM-internal Catch() forced the leaf-swap hack on every skillshot reveal. This row is the
    # diamond rod's proven shape at exactly vanilla stats: the vanilla row's own icon, the same
    # display name, durability 200. The FishingRod RECIPE's end product is repointed at this
    # class (patch_db_recipes -- crafting yields it), features/fishing.lua's loot tables drop it
    # and its migration sweep reforges rods already in inventories. The vanilla DB_Items row
    # stays: legacy/unmigrated rods must keep resolving.
    modrod_cls = add_bp_imports(d, "BP_ModFishingRod_Item")
    icon_rod = field(next(r for r in rows if r["Name"] == "FishingRod"), "Icon")["Value"]
    make_row(d, rows, "ModFishingRod", "Fishing Rod",
             "Five sticks, two stone and four iron around a patient heart. This one keeps its"
             " line in the water even when your eyes are in your pack.",
             icon_rod, modrod_cls, durability=200, tools_tab=True, interaction=1)
    clone_item_row(d, rows, "Egg", "GoldEgg", "Gold Egg",
                   "One egg in twenty comes out gilded. Worth ten times the usual to the recycler.",
                   icon_goldegg, goldegg_cls, recycler=200)
    clone_item_row(d, rows, "Truffle", "GoldTruffle", "Gold Truffle",
                   "A truffle veined with gold. Worth ten times the usual to the recycler.",
                   icon_goldtru, goldtru_cls, recycler=200)

    # ---- the blue sorting chest (2026-07-29) ----
    # EnergyFurnace is the row donor (placeable machine taxonomy: stack 1, T-type, interaction);
    # only icon/actor/text change. DB_Buildables maps the row to BP_SortingChest_Placeable.
    icon_sortchest = add_texture_import(d, "Icon_Chest", "Icon_SortingChest")
    sortchest_cls = add_bp_imports(d, "BP_SortingChest_Item")
    clone_item_row(d, rows, "EnergyFurnace", "SortingChest", "Sorting Chest",
                   "A cobalt-blue chest with a tidy streak. Wire it to power, fill it with"
                   " clutter, and it files every item into whichever nearby chest already"
                   " keeps that kind.",
                   icon_sortchest, sortchest_cls)

    fix_name_count(d)
    jout = os.path.join(OUT, "db_items_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "Framework_and_Data", "DB_Items.uasset"),
             preloads=";".join([S_ITEM, S_ATTR]))
    print(f"DB_Items patched: {len(rows)} rows")

def _slot_set(slot_props, item_ref, qty):
    """Point an S_InventorySlotSlim (Item ObjectProperty + Quantity int) at a new item/count."""
    for p in slot_props:
        n = p["Name"].split("_")[0]
        if n == "Item":
            p["Value"] = item_ref
        elif n == "Quantity":
            p["Value"] = qty

def patch_db_smeltables():
    """DB_Smeltables: a furnace recipe that COOKS a spent Electrick Wand into a Charged one -- the
    same mechanism the game boils foul water clean (row WaterDirty: CarafeDirtWater -> Drinkable).
    Input BP_ElectricWand_Item_C -> Output BP_ChargedElectricWand_Item_C, smelt time like boiling.
    The row is keyed by input theme; the furnace matches the INPUT by item CLASS, not by row name.
    Both BP_Furnace and BP_EnergyFurnace read this one table, so the recipe serves either."""
    src = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "DB_Smeltables.uasset")
    j = os.path.join(OUT, "db_smeltables_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]
    # DB_Smeltables has no BP_Stick import to template off (add_bp_imports' anchor), so add the
    # class imports the generic way -- exactly how patch_db_recipes references the wand classes.
    def cls_idx(name):
        return add_import_pair(d, f"/Game/Code/Inventory_Items/ItemActors/{name[:-2]}", name,
                               "BlueprintGeneratedClass")
    elec_cls = cls_idx("BP_ElectricWand_Item_C")            # the spent rod (input)
    chg_cls  = cls_idx("BP_ChargedElectricWand_Item_C")     # the charged rod (output)
    row = copy.deepcopy(next(r for r in rows if r["Name"] == "WaterDirty"))  # 1-in/1-out template
    row["Name"] = "ElectricWand"
    _slot_set(field(row, "Output")["Value"], chg_cls, 1)
    parts = field(row, "SmeltingParts")["Value"]
    parts[:] = parts[:1]                                            # exactly one ingredient slot
    _slot_set(parts[0]["Value"], elec_cls, 1)
    field(row, "SmeltingTime")["Value"] = 30                        # seconds, like boiling water
    rows.append(row)
    add_rowkey(d, "ElectricWand", "DB_Smeltables")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_smeltables_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "Framework_and_Data", "DB_Smeltables.uasset"),
             preloads=";".join([S_SMELT, S_SLOT]))
    print(f"DB_Smeltables patched: {len(rows)} rows (+ElectricWand furnace recipe)")

def patch_db_consumables():
    """DB_Consumables: GoldTruffle eats exactly like a Truffle (same food/drink values). The
    table matches consumables by ItemActor CLASS, so the gold clone needs its own row or eating
    it would be a silent no-op."""
    src = os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "DB_Consumables.uasset")
    j = os.path.join(OUT, "db_consumables_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]
    row = copy.deepcopy(next(r for r in rows if r["Name"] == "Truffle"))
    row["Name"] = "GoldTruffle"
    for p in row["Value"]:
        if p["Name"].split("_")[0] == "ItemActor":
            p["Value"] = add_import_pair(
                d, "/Game/Code/Inventory_Items/ItemActors/BP_GoldTruffle_Item",
                "BP_GoldTruffle_Item_C", "BlueprintGeneratedClass")
    rows.append(row)
    add_rowkey(d, "GoldTruffle", "DB_Consumables")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_consumables_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, ITEMS_DIR, "Framework_and_Data", "DB_Consumables.uasset"),
             preloads=";".join([
                 os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_Consumable.uasset"),
                 os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "EConsumableType.uasset")]))
    print(f"DB_Consumables patched: {len(rows)} rows (+GoldTruffle)")

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

def _check_replaces(replaces, where):
    """clone_asset does ORDERED, UNANCHORED text replaces over the whole round-trip JSON. Two
    invariants make the result correct AND make list order irrelevant; violate either and you
    silently cook a corrupt package (an import renamed to an asset that does not exist, or a
    half-renamed FName):
      (1) no SOURCE may be a substring of another SOURCE -- otherwise the shorter one eats the
          longer one's text and list order decides the outcome;
      (2) no TARGET may contain any LATER SOURCE -- otherwise a later pass rewrites text an
          earlier pass just produced. (A target containing its OWN source is fine: str.replace
          is single-pass and never rescans its own output.)
    Verified 2026-07-30: every existing call site already satisfies both, so the hand-tuned order
    at build_book_widgets is merely defensive -- 'W_SurvivalGuide' is NOT a substring of
    'WC_SurvivalGuideCategory' (the W is followed by C, not _). The rule is ASSERTED rather than
    assumed because the book factory GENERATES these lists from a slug."""
    srcs = [a for a, _ in replaces]
    for i, a in enumerate(srcs):
        for j, c in enumerate(srcs):
            if i != j and a in c:
                sys.exit(f"{where}: replace source {a!r} is a substring of {c!r}")
    for k, (a, t) in enumerate(replaces):
        for c in srcs[k + 1:]:
            if c in t:
                sys.exit(f"{where}: replace target {t!r} contains later source {c!r}")

def clone_asset(src_rel, out_rel, replaces, preloads="", patch=None):
    """tojson -> ordered text replaces -> optional structural patch -> fromjson into staged/."""
    base = os.path.splitext(os.path.basename(src_rel))[0]
    j = os.path.join(OUT, f"clone_{base}.json")
    tojson(os.path.join(LEGACY, src_rel), j, preloads)
    _check_replaces(replaces, os.path.basename(out_rel))
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

# ---- book text ---------------------------------------------------------------
# Each page is one S_GameplayTip row (icon, passage, category).
# Category BYTE -> ORIGINAL-enum FName. Rows keep the ORIGINAL S_GameplayTip row struct, whose
# Category property resolves names against EGameplayTipCategory -- and that enum's name<->value
# order is PERMUTED. Decoded straight out of legacy/.../EGameplayTipCategory.uexp (2026-07-30):
# 9 enumerators, _MAX=9, pairs (nameIdx,value) = (NE0,0)(NE2,1)(NE1,2)(NE4,3)(NE3,4)(NE7,5)
# (NE8,6)(NE5,7)(NE6,8). NINE is therefore the hard ceiling on sections for ANY book.
CAT_FNAME = {
    0: "EGameplayTipCategory::NewEnumerator0",
    1: "EGameplayTipCategory::NewEnumerator2",
    2: "EGameplayTipCategory::NewEnumerator1",
    3: "EGameplayTipCategory::NewEnumerator4",
    4: "EGameplayTipCategory::NewEnumerator3",
    5: "EGameplayTipCategory::NewEnumerator7",
    6: "EGameplayTipCategory::NewEnumerator8",
    7: "EGameplayTipCategory::NewEnumerator5",
    8: "EGameplayTipCategory::NewEnumerator6",
}
CODEX_SECTIONS = ["Origins", "Pentagram", "Instruments", "Hydration", "Electrick"]
ICONS_ART = "/Game/Art/Textures/Icons/"
# Icons that do NOT live in the Art/Textures/Icons flat dir. /Game/UI/ItemIcons holds only
# Icon_Chest, Icon_Log, Icon_Stick, Icon_Stone, Icon_Watercan, ItemIcon_Axe and TEMP_* -- PLUS
# every icon this build stages itself (make_icons/make_fishing_icons/make_sortchest_icon all
# write into ICONS_DIR). A page icon in the wrong dir ships as a dangling import.
ICON_DIR_OVERRIDES = {
    "Icon_Stick": "/Game/UI/ItemIcons/", "Icon_Chest": "/Game/UI/ItemIcons/",
    "Icon_Log": "/Game/UI/ItemIcons/", "Icon_Stone": "/Game/UI/ItemIcons/",
    "Icon_Watercan": "/Game/UI/ItemIcons/",
    # ours (staged by this script into ICONS_DIR = /Game/UI/ItemIcons)
    "Icon_TempestCodex": "/Game/UI/ItemIcons/", "Icon_TempestHandbook": "/Game/UI/ItemIcons/",
    "Icon_DarkArts": "/Game/UI/ItemIcons/", "Icon_SortingChest": "/Game/UI/ItemIcons/",
    "Icon_FishingrodDiamond": "/Game/UI/ItemIcons/", "Icon_EggGold": "/Game/UI/ItemIcons/",
    "Icon_TruffleGold": "/Game/UI/ItemIcons/", "Icon_StickBrown": "/Game/UI/ItemIcons/",
    "Icon_StickBlue": "/Game/UI/ItemIcons/", "Icon_StickGold": "/Game/UI/ItemIcons/",
    "Icon_StickYellow": "/Game/UI/ItemIcons/",
}

CODEX_PAGES = [
    # -------- ORIGINS --------
    ("Codex_O1", 0, "Icon_Handbook",
     "Wherein is set downe the beginning of the storme, and who is to blame for it."
     "\n\nI write this because they that taught me are dead, and they wrote nothing downe, and I"
     " am wearie of bearing it alone."
     "\n\nThere be two. There were never more than two, and they have not agreed in all the yeares"
     " of the worlde."),
    ("Codex_O2", 0, "Icon_Weather_Sunny",
     "The first is Solenne, whom the olde folke named the Open Hand. She is the long light. Every"
     " good thing that ever laye in thy palm came forth from betwixt her fingers -- the wood and"
     " the wax, the vein of copper sleeping in the rocke, the bone of iron, the fyre that scoureth"
     " the rot out of standing watir. She taught our mothers to draw the metal into barre and tube,"
     " to worke the loome, and to speake so gentlie unto the sunneflower that it turneth its face"
     " and followeth her the whole daye long. I have loved her. I set that downe plainlie, that"
     " what cometh after may be rightlie understood."),
    ("Codex_O3", 0, "Icon_Stormy",
     "The second is Vorrach, called the Unlit, and he is elder than she by an age, being the darke"
     " that stood alone before ever there was a sunne for it to stand against. He hath made nothing"
     " in all his yeares. He cannot. It is not in him. He may onlie take, and counte, and remember"
     " -- and he remembereth all."
     "\n\nWhen Solenne began her giving, he spake but once, and hath had no cause to speake againe:"
     " nothing given shall goe unpaid."),
    ("Codex_O4", 0, "Icon_Stormy",
     "So he keepeth his accompt. Every gift of hers is writ downe against us, and the stormes are"
     " him walking abroad to gather what is owed. When the white fyre falleth, a debt is struck"
     " through. The thunder after is but the sound of his booke closing."),
    ("Codex_O5", 0, "Icon_Stick",
     "Marke well why the rods will not answere. Solenne shaped the vessel -- so much she could doe."
     " But she cannot fill it. Onlie the Unlit filleth, and he filleth nothing till he be paid in"
     " somewhat warme and breathing. Herein lieth the whole of the arte. All else in this booke is"
     " but the manner of the paying."),
    # -------- PENTAGRAM --------
    ("Codex_P1", 1, "ICON_CandlePlate",
     "Of the raising of the Starre, common unto everie rite herein."
     "\n\nThe shape is one and the same for all workes I have knowledge of, and I doe not thinke it"
     " was ever ours. I thinke it was founde."
     "\n\nRaise up a fence of five walles, each of the length of the last, so that a pen be made"
     " which the offering cannot leave. Then from everie walle draw forth a point, till the pen"
     " hath flowered into a starre of five sharpe armes. Thou shalt know when it standeth true, for"
     " thy handes will not wishe to finish it. Finish it notwithstanding."),
    ("Codex_P2", 1, "ICON_CandlePlate",
     "Sette a candle upon each of the five corners, and leave everie one of them darke."
     "\n\nCaveat. Light them not. There be women who have set fyre to them out of kindnesse,"
     " thinking the darke unfriendlie to the worke, and the storme passed over their heades and"
     " gave them nothing, and they went to their graves not knowing wherefore. The skie is the"
     " onlie flame suffered here. Aught else is an insult, and he is easilie insulted."),
    ("Codex_P3", 1, "AnimalIcon_Sheep",
     "Lay the offerings upon the points, one unto each arme, that he may counte them without"
     " stooping. Sette the beast in the hearte. Binde it not. Gentle it not. The innocent runne not"
     " away, and it is their not running that he weigheth."),
    ("Codex_P4", 1, "Icon_Weather",
     "Thereafter remaineth nothing but waiting, and the waiting is the hardest part of anie rite."
     " The worke answereth not unto thee. It answereth unto the weather. Stand thou within the"
     " circle when the cloudes goe blacke and the ayre turneth to iron upon the tongue, holde thy"
     " rod, and when the fyre commeth downe --"
     "\n\nCaveat. Blink not. Everie rod helde by everie soule standing witnesse is quickened in"
     " that same breath, and the breath is verie short. He that looketh away hath looked away for"
     " good and all."),
    # -------- INSTRUMENTS --------
    ("Codex_I1", 2, "Icon_Stick",
     "Of the making of a blanke rod, and of the feeding of a quickened one."
     "\n\nTo make a Mundane Wand. Take thou one sticke, and one measure of beeswax. Binde them."
     " There is no more to it, and it availeth nothing."),
    ("Codex_I2", 2, "ICON_Beeswax",
     "Consider the crueltie herein. Both partes are hers -- the braunch off her trees, the wax off"
     " her bees -- and she giveth them freelie, and thou mayest binde them into the verie shape a"
     " wand ought to take, and it shall lye in thy palme as dead as a corpse his colde finger. It"
     " hath no nature. Such a rod is called blanke, and blanke it abideth, and no quantitie of"
     " wanting shall alter it. The shape is hers. The filling is his. She hath never in all her"
     " yeares beene able to give us both."),
    ("Codex_I3", 2, "Icon_Stormy",
     "Nota bene. Once a rod be filled, the nature thereof is sette and cannot be unsette. No second"
     " rite shall write over it, nor yet a third. Whatsoever thou callest downe into that sticke is"
     " what it shall be untill the wood rotteth. Choose thou the path afore thou raisest the starre,"
     " and not after."),
    ("Codex_I4", 2, "Icon_Caraffe_Water",
     "Of the feeding. Everie filled rod must be fed, and each feedeth after its owne kinde."
     "\n\nThe quenched rod drinketh when thou drinkest. Putte watir to thine owne lippes and thou"
     " shalt feele it fill beside thee; or els wade thou out into ponde or running river and stand"
     " still, and it shall take its fill without thy lifting a hande."),
    ("Codex_I5", 2, "Icon_Stormy",
     "The other is not so easilie satisfied. It waketh onlie when the white fyre falleth neare"
     " enough to lift the haire upon thy necke. Thou must stand close unto the stroke."
     "\n\nCaveat. Closer than anie sensible woman would stand. They that have done it beare the"
     " markes upon their armes, and they doe it againe."),
    ("Codex_I6", 2, "Icon_Stormy",
     "Yet mark a kindlier feeding, founde by them that had no stomacke for standing neare the"
     " stroke. The grounded rod, gone spent and dimme and golde, hath a second hunger the fyre can"
     " fille."
     "\n\nLaye the emptie electrick rod within the furnace, in the white hotte inferno thereof, even"
     " as thou wouldst sette a carafe of foule watir to boile. Shutte it up and be patient. The heat"
     " worketh the storme backe into the wood, and it commeth forth charged and howling againe, and"
     " no marke lefte upon thine arme. What the storme asketh in feare, the furnace asketh onlie in"
     " waiting."),
    # -------- HYDRATION (the path of water: the Rite of the Quenched Rod) --------
    ("Codex_H1", 3, "AnimalIcon_Chicken",
     "The Rite of the Quenched Rod. The path of watir."
     "\n\nFor this he asketh a chicken. A common thing, a foolish thing, that will walke into the"
     " starre upon its owne feete if a little graine be scattered, and will stand there in the"
     " myddes of it looking at nothing at all."),
    ("Codex_H2", 3, "Icon_Caraffe_Water",
     "Unto the five points give:"
     "\n\nItem, watir made cleane by boiling and boiling againe."
     "\nItem, a measure of the bees their owne wax."
     "\nItem, a leafe pluckt greene and living from the crowne of an elder wood."
     "\nItem, claye digged colde and yielding out of the lightlesse bellie of the ground."
     "\nItem, a rasberrie, the small red droppe off the bramble."),
    ("Codex_H3", 3, "Icon_Caraffe_Water",
     "Caveat concerning the watir. Be exacte. He will not take that which is filthie. Whole rites"
     " have failed in silence for a carafe drawen from a streame and never sette over the fyre --"
     " and there is no signe given, no refusall spoken, onlie the storme passing over, and the"
     " beast yet living, and everie rod yet dead in everie hande. Boile it. Boile it twice if thou"
     " be uncertaine."),
    ("Codex_H4", 3, "Icon_Watercan_Wood",
     "When the fyre falleth, everie mundane rod helde within that circle is quenched through and"
     " made a Hydration Wand, and commeth away filled unto two hundred and fortie measures."
     "\n\nProbatum est."),
    # -------- ELECTRICK (the path of fire) --------
    ("Codex_W1", 4, "AnimalIcon_Sheep",
     "The Rite of the Grounded Bolte. The path of fyre."
     "\n\nFor this he asketh a sheepe. A lambe will serve, and it is honestlie sette downe here that"
     " a lambe serveth better, and wherefore that should be is not written in this booke."),
    ("Codex_W2", 4, "Icon_Copper",
     "Unto the five points give:"
     "\n\nItem, a barre of copper refined and drawen by the craft she taught us."
     "\nItem, iron ore yet rawe, yet rough with the ground it was torne from."
     "\nItem, watir purified by fyre."
     "\nItem, a sunneflower, the greate bloome that turneth its face toward her all the daye long."
     "\nItem, a length of woven cloth."),
    ("Codex_W3", 4, "Icon_Sunflower",
     "Marke what he asketh for. Everie one of them is hers -- her metal wrought by her methodes,"
     " her flower that followeth her light, her flame in the watir, her loome in the cloth. He"
     " asketh not for materialls. He asketh that thou carrie her best worke out into the open and"
     " lay it upon the armes of his starre where he may see it, and then he taketh it, and the"
     " taking is the whole of the point."),
    ("Codex_W4", 4, "ICON_Ore_Pebbles_Iron",
     "When the bolte commeth downe, everie blanke rod within the circle is grounded through and"
     " made a Lightning Wand, and commeth away charged."),
    ("Codex_W5", 4, "Icon_Stormy",
     "Caveat. Blanke, it saith, and blanke it meaneth. A rod alreadie quenched by watir is passed"
     " over as though it were not there -- the fyre readeth the nature of it, findeth it spoken"
     " for, and goeth about. Bring nought but emptie wood unto this one. There was a girle helde up"
     " a watir rod in a storme looking for a second gift, and got nothing, and the sheepe died all"
     " the same."
     "\n\nProbatum est."),
]

# ---- the Tempest Handbook text -----------------------------------------------
# The practical companion to the Codex: what this mod actually adds, section by section, in a
# settler's voice rather than the Codex's archaic one. Counts appear only where they help a
# player PLAN ("ten times", "three bolts"); no percentages, distances or timings. Deliberately
# NO controls-reference section and no console commands -- keys are named where they belong.
HANDBOOK_SECTIONS = ["Storms", "Dark Arts", "The Unlit", "Fishing",
                     "Airship", "Homestead", "Pack & Person", "New Things"]

HANDBOOK_PAGES = [
    # -------- STORMS --------
    ("Hand_S0P1", 0, "Icon_Stormy",
     "The weather has teeth now."
     "\n\nWhen a storm holds, bolts come down near whoever is standing under it. You get a"
     " moment's warning: the ground scorches where the strike means to land, and if you are not"
     " standing on that mark when it falls, it misses. A few paces is enough. Watch your feet,"
     " not the sky."
     "\n\nOne bolt takes most of a person. Two takes all of them. Do not gamble on the second."),
    ("Hand_S0P2", 0, "Icon_Weather_Sunny",
     "Open ground is a bad place to be caught in it. Out over open water is worse -- there is"
     " nothing else out there for the sky to take an interest in. And it keeps a shorter temper"
     " still for anything already up in the air, so flying through a storm is asking for it."
     "\n\nAn airship struck loses a third of its hull, and struck enough times it comes down"
     " wherever it happens to be."
     "\n\nThere is no shelter rule to memorise. Put something between you and the weather, or be"
     " somewhere else."),
    ("Hand_S0P3", 0, "Icon_Battery",
     "Lightning is not only a danger. It is also, occasionally, generous."
     "\n\nA battery or a generator struck comes up fully charged. A furnace struck lights as"
     " though you had fed it wax. Anything else electrical takes it badly: it smokes and stops,"
     " and a second strike before you repair it destroys the thing outright and leaves half its"
     " parts lying in the grass."
     "\n\nGrown trees come down the way an axe would fell them, loot and all. Saplings are too"
     " small to be worth the trouble. Crops die where they stand and leave no seed."),
    ("Hand_S0P4", 0, "Icon_Weather",
     "Build a Weather Station and you have built a lightning rod. That is the whole trick --"
     " nothing new to research, nothing new to craft."
     "\n\nAny bolt meant for something near it is taken by the rod instead and put quietly into"
     " the ground. Set one over your workshop and the workshop stops burning down. Leave a"
     " battery standing beside it and the battery drinks what the rod catches."
     "\n\nIt does not wear out. One is enough, if you put it in the right place."),

    # -------- DARK ARTS --------
    ("Hand_S1P1", 1, "Icon_TempestCodex",
     "There is an older way of dealing with the sky, and I am not going to set it all down here."
     " It has its own book."
     "\n\nResearch the Dark Arts at the station -- it wants a little beeswax, a little clay and a"
     " leaf -- and you will learn two things: how to bind the Tempest Codex, and how to seal a"
     " stick with wax into a Mundane Wand."
     "\n\nCraft the Codex, set it down somewhere dry, and read it. It carries the whole account:"
     " the circle, the offerings, both rites and what each of them costs. I will not write it"
     " twice."),
    ("Hand_S1P2", 1, "Icon_StickBrown",
     "What is worth knowing before you open that book:"
     "\n\nA wand is drawn and put away with V. Drawing one stows whatever you were holding, and"
     " reaching for a tool on the bar puts the wand away again."
     "\n\nA blank rod is worth nothing until a storm and a circle give it a nature. There are two"
     " natures, water and fire. A rod takes one of them, once, and keeps it -- so make up your"
     " mind before you stand in the circle, because the other rite will simply pass your rod"
     " over."
     "\n\nThe rest is in the Codex. Go and make it."),

    # -------- THE UNLIT --------
    ("Hand_S2P1", 2, "AnimalIcon_Sheep",
     "Give something living to the storm and the storm remembers the species."
     "\n\nAfter that, every storm brings them back. They come out of the dark well beyond shouting"
     " distance, black the whole way through, trailing a red light that falls on nothing. They"
     " call in their own voice pitched far down. You will hear them before you see them."
     "\n\nThey prowl at twice the pace of an honest animal, and once they have you they come at"
     " four times that again. The lambs stand the size of a person and they do not bite -- they"
     " ram, and you will land somewhere you did not choose."),
    ("Hand_S2P2", 2, "ICON_Torch",
     "They will not walk into light. A lit torch, a powered lamp or a wireless light holds a wide"
     " circle clear; a candle or a small lamp holds a narrow one. Ring the places you sleep and"
     " work and they will go and be born somewhere else."
     "\n\nIf one reaches you, hit it. Stone hurts, iron hurts more, diamond most, and they flash"
     " white and stall when struck. A bolt of lightning kills one outright, which is worth"
     " remembering given the weather they turn up in."
     "\n\nWhen the storm lifts they lie down and are gone."),

    # -------- FISHING --------
    ("Hand_S3P1", 3, "Icon_Fishingrod",
     "You will notice the rivers are not what they were. Every stretch of water keeps its own"
     " habits -- the home waters are generous with food and scrap, the far ones with circuitry,"
     " cobalt and cut stones you could not grow or smelt."
     "\n\nGo down at first light or last and the water is kinder about what it gives up. Rain"
     " does not change the catch. It only makes the catch argue with you."
     "\n\nAnd the splash of a bite carries properly now. You do not have to sit and stare."),
    ("Hand_S3P2", 3, "Icon_Cobalt",
     "Sometimes the fish fights, and the moment you strike it becomes a contest instead of a"
     " catch. There are three of them and they come as they please."
     "\n\nOne is a marker sweeping along a bar: put your click in the gold. One is a needle"
     " spinning at the crosshair, which slows the same way every single time, so it can be"
     " learned. The last is a line growing beside a shifting gap; click and it slides across, and"
     " if you judged it the line drops flush home."
     "\n\nWin and you are promised something rare. Miss, or dither more than a few seconds, and"
     " the fish is gone."),
    ("Hand_S3P3", 3, "Icon_FishingrodDiamond",
     "There is a better rod. Two cut diamonds at the reel, made at the bench, and the ordinary"
     " fishing-rod research is all that teaches it."
     "\n\nIt endures ten times what a plain rod will. It doubles your luck on the rare and the"
     " precious -- your luck, mind; your friends still fish their own odds. It puts you into that"
     " contest far more often, gives you a narrower mark to hit, and when you hit it, it pays"
     " nothing but the best of the water."
     "\n\nRods you pull out of the river come to you already worn. That seems fair. Somebody"
     " dropped them."),

    # -------- AIRSHIP --------
    ("Hand_S4P1", 4, "Icon_Airship_chest",
     "The airship has somewhere to put things now. Not an upgrade and not a part -- it is simply"
     " there, at the back of the deck, and it holds through saving, loading and everybody else's"
     " eyes."
     "\n\nPress B and it opens: from the deck, from the ground beside it, or from the wheel."
     "\n\nAt the wheel, TAB lays the ship's hold and your own pack out side by side so you can"
     " move things across without letting go. TAB or ESC shuts it again."),
    ("Hand_S4P2", 4, "Icon_Airship_Balloon",
     "Hold the wheel and press SPACE and the ship goes to three times its usual pace. The view"
     " opens out, the wind comes up, and it stays there as long as you like -- there is no meter"
     " to watch."
     "\n\nSPACE again, or simply pull back, and it settles over a few seconds instead of dropping"
     " out from under you."
     "\n\nCalling the ship home is five times quicker than it was, and so is the long climb down"
     " after a bad parking job. It is still a flight. It will not blink out and reappear beside"
     " you; that would be cheating, and you would not enjoy it."),
    ("Hand_S4P3", 4, "Icon_Deco_Bench_White",
     "There is a bench at the stern of every ship, just forward of the hold. Three can sit on it"
     " and ride while somebody else flies."
     "\n\nWhile the owner is at the wheel the passengers stay in their seats, which is rather the"
     " point of a seat on a moving ship. Once she is parked they get up as they please."
     "\n\nAnd you no longer have to own a ship to walk onto it. Anyone may board. Both machines"
     " want this book's mod installed, mind, or the deck stays shut to them."),

    # -------- HOMESTEAD --------
    ("Hand_S5P1", 5, "Icon_SortingChest",
     "The blue chest sorts."
     "\n\nMake it at the Energy Crafting Table, run a cable to it like any machine, and empty"
     " your pockets into it. Every few"
     " seconds it takes what is inside and files it into whichever chest nearby already keeps"
     " that sort of thing. It will not invent a home for something -- it only agrees with the"
     " homes you already made. Whatever nothing wants stays in the blue chest for you to settle."
     "\n\nIt draws power while it has work and almost none while it is idle. Cut the cable and it"
     " stops politely; give it power again and it picks up where it left off."),
    ("Hand_S5P2", 5, "ICON_Workbench",
     "Two things about crafting."
     "\n\nEvery chest is deeper than it was -- six full rows now, the same spread as a well-worn"
     " pack -- including the ones you already filled. Nothing was tipped out on the floor to"
     " manage it."
     "\n\nAnd with a bench, an energy bench or a kitchen open, simply looking at a recipe fetches"
     " its missing pieces out of the chests around you and into your pack. The one-of-five you"
     " would have gone walking for is five of five by the time you have read it. Fair warning:"
     " browsing pulls too. Window-shop a recipe and you will find its materials in your pockets"
     " afterwards."),
    ("Hand_S5P3", 5, "Icon_Brick_Foundation",
     "Foundations used to insist that all four corners rest on soil, which made building out over"
     " a slope an argument you generally lost."
     "\n\nThey still insist -- but only when standing on their own. The moment a foundation snaps"
     " onto something you have already built, the rule lifts and it will take the placement."
     "\n\nBuild outward from what exists, and the ground stops having an opinion."),
    ("Hand_S5P4", 5, "Icon_Chair",
     "Sit down. Right-click a bench with empty hands and you will take a seat; right-click again"
     " and you will get up. Chairs, stools and couches will have you as well, and three can share"
     " a bench side by side."
     "\n\nYou get up on your own if you die, if you respawn, or if somebody takes the bench apart"
     " underneath you."
     "\n\nAnd whoever is hosting has a Save Game button in the pause menu now, sitting just above"
     " Resume. It runs the ordinary save, so you get the ordinary 'Saving...' and then you get on"
     " with your evening."),

    # -------- PACK & PERSON --------
    ("Hand_S6P1", 6, "Icon_Trashcan",
     "There is a red slot at the bottom corner of your bag. Put something in it and it is queued"
     " for the fire. Put a second thing in and the first burns while the second takes its place."
     "\n\nWhich means the last thing you threw away is always still there if you want it back."
     " Only the next thing you throw away is final."
     "\n\nIt is a real slot: it stacks, it splits, it carries, it tells you what is in it. It is"
     " yours alone -- nobody else can see it -- and it forgets itself when you log out."),
    ("Hand_S6P2", 6, "Icon_Chest",
     "The chest window shows everything now. The whole chest on one side and your whole pack on"
     " the other, in one grid: no third row cut off, no separate backpack tab to remember."
     "\n\nThe hotbar has come up to sit under the open inventory instead of hiding behind it, and"
     " it grows with your bag."
     "\n\nWhat you pick up is announced in the middle of the screen, where you are already"
     " looking, rather than off in a corner where you are not."),
    ("Hand_S6P3", 6, "Icon_MapMArker",
     "Crouch on C or on Left Ctrl. Tap either to stay down; hold either to stay down only as long"
     " as you hold it -- Ctrl is exact about the release, so use it for the short ones. Dying"
     " crouched no longer buries your things under the floor."
     "\n\nA ping turns to face whoever is looking at it, so it never goes edge-on and vanishes,"
     " and it stands as a tall marker you can pick out from a long way off. It wears the colour"
     " of whoever set it."
     "\n\nOn the map, everyone's name floats over where they actually are. No more guessing which"
     " dot is which."),

    # -------- NEW THINGS --------
    ("Hand_S7P1", 7, "Icon_TempestHandbook",
     "A short catalogue, so you know what to look for."
     "\n\nThe Tempest Handbook -- this. One log and two leaves, in the quick-craft menu, known"
     " from the start. If somebody joins you and looks lost, hand them one."
     "\n\nThe Tempest Codex -- a log, two leaves and clay at the bench, after the Dark Arts"
     " research. The full account of the circle and the rites."
     "\n\nThe Sorting Chest -- four logs, four iron and two cobalt at the Energy Crafting Table,"
     " with the other machines. No research needed; you have always known how."),
    # kept under ~590 chars a page: that is the longest the codex ships, and the length the page
    # widget is known to render without the reader having to scroll
    ("Hand_S7P2", 7, "Icon_StickBlue",
     "The Mundane Wand -- a stick and beeswax at the bench, after the Dark Arts research. Dark"
     " brown, and good for nothing until a storm and a circle give it a nature."
     "\n\nThe Hydration Wand -- river-blue, out of the rite of water. It waters growboxes, it"
     " quenches a friend, and you can drink from it yourself. It refills for nothing: drink any"
     " water, foul or clean, or simply wade in."),
    ("Hand_S7P3", 7, "Icon_StickYellow",
     "The Electrick Wand -- yellow-hot, out of the rite of fire. Three bolts, aimed wherever you"
     " are looking, in any weather at all. Spent, it goes dim gold, and it fills again near"
     " somebody else's lightning, or shut in a furnace for half a minute."
     "\n\nThe bars beneath the rods in your pack are honest: pours left, bolts left."),
    ("Hand_S7P4", 7, "Icon_EggGold",
     "The Diamond Fishing Rod -- five sticks, two stone, four iron and two cut diamonds at the"
     " bench, taught by the ordinary fishing-rod research. Or pull one out of the water, if the"
     " water likes you."
     "\n\nThe Gold Egg and the Gold Truffle -- jackpot catches, the pair of them. The truffle eats"
     " exactly like a truffle. Both are worth ten times their plain cousins at the recycler, so"
     " take care which one you fry."
     "\n\nThat is everything I know that is worth the writing down. The rest of it you will find"
     " out in the weather."),
]

# ---- the books ---------------------------------------------------------------
# Every readable book is the SAME clone chain off the survival guide, differing only by the
# fields below. Adding a third book means adding a spec, nothing else.
#   slug              the one true name: DB_Items row key, BP_%s_Item_C class, DB_Buildables
#                     row + ItemsNeeded.RowName, recipe row key. It lands in players' saves --
#                     pick it once; a rename orphans placed books and inventory stacks.
#   place_mesh        None keeps the donor placeable's SM_Handbook
#   block_visibility  force the InteractionBox to block the Visibility channel (see build_book_bps)
BOOKS = [
    dict(slug="TempestCodex", title="Tempest Codex",
         sections=CODEX_SECTIONS, pages=CODEX_PAGES,
         place_mesh="SM_Book_Merchant", block_visibility=True,
         # shipped before the factory existed as WC_TempestPage, not WC_TempestCodexPage --
         # pinned so the codex's cooked assets stay byte-identical across this refactor
         wc_page="WC_TempestPage",
         item_icon="Icon_TempestCodex",
         item_display="Tempest Codex",
         item_desc="Bound in storm-blackened hide. Place it anywhere, and read what the sky is owed."),
    dict(slug="TempestHandbook", title="Tempest Handbook",
         sections=HANDBOOK_SECTIONS, pages=HANDBOOK_PAGES,
         place_mesh=None, block_visibility=False,
         item_icon="Icon_TempestHandbook",
         item_display="Tempest Handbook",
         item_desc="Somebody's working notes on living with the new weather. Place it anywhere and read it."),
]

def _names(b):
    """Every derived asset name for a book, in one place so nothing is ever spelled twice."""
    s = b["slug"]
    return dict(enum=f"E{s}Category", table=f"DB_{s}", widget=f"W_{s}",
                wc_cat=f"WC_{s}Category", wc_page=b.get("wc_page") or f"WC_{s}Page",
                item=f"BP_{s}_Item", place=f"BP_{s}_Placeable",
                widget_pkg=f"/Game/UI/Widgets/W_{s}", widget_cls=f"W_{s}_C")

def book(slug):
    return next(b for b in BOOKS if b["slug"] == slug)

def _icon_dir(icon):
    return ICON_DIR_OVERRIDES.get(icon, ICONS_ART)

def _icon_exists(icon):
    """A page icon must resolve to a real cooked Texture2D -- either in the game's legacy extract
    or staged by this build. A typo otherwise ships as a dangling import and the page renders
    blank (or worse) at runtime, with nothing to see offline. Checked at build time instead."""
    rel = _icon_dir(icon).replace("/Game/", "Solarpunk/Content/").lstrip("/") + icon + ".uasset"
    return (os.path.exists(os.path.join(LEGACY, rel))
            or os.path.exists(os.path.join(STAGED, rel)))

def build_book_enum(b):
    n_sec, nm = len(b["sections"]), _names(b)
    if n_sec > len(CAT_FNAME):
        sys.exit(f"{b['slug']}: {n_sec} sections, but the vanilla EGameplayTipCategory only has "
                 f"{len(CAT_FNAME)} enumerators to borrow byte values from")
    def patch(d):
        enum = d["Exports"][0]["Enum"]
        tup = "System.Tuple`2[[UAssetAPI.UnrealTypes.FName, UAssetAPI],[System.Int64, System.Private.CoreLib]], System.Private.CoreLib"
        n = n_sec
        enum["Names"] = [
            {"$type": tup, "Item1": f"{nm['enum']}::NewEnumerator{i}", "Item2": i}
            for i in range(n)
        ] + [{"$type": tup, "Item1": f"{nm['enum']}::{nm['enum']}_MAX", "Item2": n}]
        pairs = []
        for i, title in enumerate(b["sections"]):
            key = {"$type": "UAssetAPI.PropertyTypes.Objects.NamePropertyData, UAssetAPI",
                   "Name": "DisplayNameMap", "ArrayIndex": 0, "PropertyGuid": None, "IsZero": False,
                   "PropertyTagFlags": "None", "PropertyTypeName": None,
                   "PropertyTagExtensions": "NoExtension", "Value": f"NewEnumerator{i}"}
            pairs.append([key, base_text("DisplayNameMap", title)])
        d["Exports"][0]["Data"][0]["Value"] = pairs
    clone_asset(os.path.join(TIPS_DIR, "EGameplayTipCategory.uasset"),
                os.path.join(TIPS_DIR, nm["enum"] + ".uasset"),
                [("EGameplayTipCategory", nm["enum"])], patch=patch)

def build_book_table(b):
    nm = _names(b)
    bad = sorted({i for _, _, i, _ in b["pages"] if not _icon_exists(i)})
    if bad:
        sys.exit(f"{nm['table']}: page icons not found (check ICON_DIR_OVERRIDES): {bad}")
    def patch(d):
        rows = d["Exports"][0]["Table"]["Data"]
        template = copy.deepcopy(rows[0])
        del rows[:]
        icon_idx = {}
        for _, _, icon, _ in b["pages"]:
            if icon not in icon_idx:
                icon_idx[icon] = add_import_pair(d, _icon_dir(icon) + icon, icon, "Texture2D")
        for key, cat, icon, text in b["pages"]:
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
            add_rowkey(d, key, nm["table"])
        fix_name_count(d)
        print(f"{nm['table']}: {len(rows)} pages, {len(b['sections'])} sections")
    clone_asset(os.path.join(TIPS_DIR, "DB_GameplayTips.uasset"),
                os.path.join(TIPS_DIR, nm["table"] + ".uasset"),
                [("DB_GameplayTips", nm["table"])], preloads=S_TIP, patch=patch)

def build_book_widgets(b):
    nm = _names(b)
    # widgets carry ByteProperties typed to our cloned enum; UAssetAPI can only re-serialize them
    # unversioned if the enum is registered in the usmap -> preload the STAGED enum clone
    # (wandsmith's preloader registers EnumExports since 2026-07-21)
    enum_pre = os.path.join(STAGED, TIPS_DIR, nm["enum"] + ".uasset")
    # category chip: label source = the enum DisplayNameMap (Conv_NumericPropertyToText). That is
    # exactly why this widget CANNOT be shared between books -- a shared chip would render the
    # other book's section titles.
    clone_asset(os.path.join(WC_DIR, "WC_SurvivalGuideCategory.uasset"),
                os.path.join(WC_DIR, nm["wc_cat"] + ".uasset"),
                [("WC_SurvivalGuideCategory", nm["wc_cat"]),
                 ("EGameplayTipCategory", nm["enum"])],
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
                os.path.join(WC_DIR, nm["wc_page"] + ".uasset"),
                [("WC_GameplayTip", nm["wc_page"])], patch=patch_page)

    # the book itself
    def patch_book(d):
        # GenerateCategoryButtons iterates category indexes 0..N-1 with N BAKED at BP compile time
        # as MakeLiteralInt(9) -- 9 is the VANILLA section count, so the search literal stays 9
        # whatever we write. Patch the ONE hit to our section count. Same-width int const ->
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
            sys.exit(f"{nm['widget']}: expected exactly one MakeLiteralInt(9) in "
                     f"GenerateCategoryButtons, found {len(hits)}")
        hits[0]["Value"] = len(b["sections"])
        # title: the original pulls "Survival Guide" from the ST_ReusableTerms string table;
        # inline ours instead
        tb = next(e for e in d["Exports"] if str(e.get("ObjectName")) == "TextBlock_1")
        for i, p in enumerate(tb.get("Data", [])):
            if p.get("Name") == "Text":
                tb["Data"][i] = base_text("Text", b["title"])
    clone_asset(os.path.join(WIDGETS_DIR, "W_SurvivalGuide.uasset"),
                os.path.join(WIDGETS_DIR, nm["widget"] + ".uasset"),
                [("WC_SurvivalGuideCategory", nm["wc_cat"]),
                 ("WC_GameplayTip", nm["wc_page"]),
                 ("DB_GameplayTips", nm["table"]),
                 ("EGameplayTipCategory", nm["enum"]),
                 ("W_SurvivalGuide", nm["widget"])],
                preloads=enum_pre, patch=patch_book)

def build_book_bps(b):
    nm = _names(b)
    # the inventory/world item: a Handbook clone (merchant-book mesh, dark tome look)
    clone_asset(os.path.join(ITEMS_DIR, "ItemActors", "BP_Handbook_Item.uasset"),
                os.path.join(ITEMS_DIR, "ItemActors", nm["item"] + ".uasset"),
                [("BP_Handbook_Item", nm["item"])], preloads=MASTER_BP)
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
            d, nm["widget_pkg"], nm["widget_cls"],
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
        # IsAxeDestroyable (is a placeable, not a plant, not IUnplaceable) -- but the
        # SM_Book_Merchant mesh ships an EMPTY BodySetup, so the trace passes through the book
        # and the codex could never be packed up (interact still works: E uses the separate
        # Interactable channel the InteractionBox blocks). Make that same box block Visibility
        # too -- the vanilla-furniture-style box approximation for aim/pickup traces.
        # Only for books that swapped in Merchant: SM_Handbook has real collision, and blocking
        # the oversized box would only inflate its aim/pack-up hit volume for nothing.
        if not b["block_visibility"]:
            return
        box = next(e for e in d["Exports"]
                   if e.get("ObjectName") == "InteractionBox_GEN_VARIABLE")
        def _prop(props, name):
            return next(p for p in props if p.get("Name") == name)
        ra = _prop(_prop(_prop(box["Data"], "BodyInstance")["Value"],
                         "CollisionResponses")["Value"], "ResponseArray")
        vis = next(el for el in ra["Value"]
                   if _prop(el["Value"], "Channel")["Value"] == "Visibility")
        _prop(vis["Value"], "Response")["Value"] = "ECR_Block"
    reps = [("BP_SurvivalGuide_Placeable", nm["place"]),
            ("BP_Handbook_Item", nm["item"])]
    if b["place_mesh"]:
        reps.append(("SM_Handbook", b["place_mesh"]))
    reps.append(("UI_OpenSurvivalGuide", "ForceCloseInteractableUIs"))
    clone_asset(os.path.join(PLACE_DIR, "BP_SurvivalGuide_Placeable.uasset"),
                os.path.join(PLACE_DIR, nm["place"] + ".uasset"),
                reps, preloads=place_master, patch=_patch_placeable)

# ---------------------------------------------------------------- 5. the blue sorting chest
# A powered chest that files its contents into nearby chests (features/sort_chest.lua drives the
# actual sorting via the game's own Quick Stack). Donor: BP_EnergyFurnace_Placeable -- the ONE
# placeable that ships every wire the feature needs already connected: BC_InventorySystem +
# SNAP_CableConnector + BPC_Device_EnergySystemComponent + GetEnergyComponent (BPI_EnergyBasic)
# + interactable logic + SaveData/DataToJSON persistence. Cloning a plain chest and ADDING power
# would mean SCS surgery; cloning the furnace and REMOVING smelting is bytecode-local.
#
# The de-furnacing, all cook-time:
#   * mesh: SM_Furnace_Electric -> SM_Crate_Wood (same /Game/Art/StaticMeshes dir, exact-name
#     import rename so SM_Furnace_Electric_closed stays untouched); the mesh template's
#     OverrideMaterials[0] (M_FurnaceElectric_Off) -> M_Cobalt = the whole crate renders in the
#     cobalt ore's blue. Visually unmistakable, per the user's spec.
#   * smelting: every smelt/fuel/timer function's ScriptBytecode is replaced with a bare
#     EX_Return + EX_EndOfScript stub. The ubergraph is untouched -- stubbing the ENTRY functions
#     (incl. the InventoryChanged / OnEnergyNetworkUpdated bound-event trampolines) is enough
#     because every path into the graph goes through one, and mid-graph edits would break the
#     serialized jump offsets (the codex insert was only safe because it sat after EX_Return).
#   * interact: the OnInteractedWith trampoline is stubbed too -- natively the chest does NOTHING
#     on E. But RegisterHook fires on ProcessEvent regardless of the body, so features/
#     sort_chest.lua hooks the stub (codex-proven pattern) and opens the plain chest UI itself.
#     No furnace widget ever flashes.
#   * power: the device template's draw becomes idle-level; features/sort_chest.lua modulates
#     CurPowerConsumption (-500 sorting / -100 idle, the engine's negative-draw convention;
#     the actual wattages are config -- sort_chest_power_active / sort_chest_power_idle).
#   * inventory: grown 2 -> 12 slots + AllowQuickStack, matching BP_Chest_Buildable's template
#     exactly (the chest UI's fixed 12-tile grid makes this correctness, not cosmetics -- see
#     SORTCHEST_SLOTS below).
#   * cable hookup: the SNAP_CableConnector box is pulled flush with the crate face so the
#     small cable connector snaps onto it (see the _patch_placeable comment).
SORTCHEST_STUBS = [
    "TrySmelting", "TryStartSmelting", "KickstartSmelting", "StartSmeltingTimer",
    "MULTI_StartSmeltingTimer", "SmeltItem", "TryFueling", "AbortSmelting",
    "SyncTimerToLocal", "MULTI_SyncTimer", "SetOpticallySmelting", "UpdatePowerConsumption",
    # bound-event trampolines (exact names carry the donor's own historic typos)
    "BndEvt__BP_Furnance_BC_InventorySystem_K2Node_ComponentBoundEvent_3_InventoryChanged__DelegateSignature",
    "BndEvt__BP_SortingChest_Placeable_BPC_Device_EnergySystemComponent_K2Node_ComponentBoundEvent_4_OnEnergyNetworkUpdated__DelegateSignature",
    "BndEvt__BP_Furnance_BPC_InteractableLogic_K2Node_ComponentBoundEvent_0_OnInteractedWith__DelegateSignature",
]

# W_ChestInventory's grid is built ONCE at Construct: CreateItemSlotGrid(..., 2, 6, ...) = 12
# tiles, and BP_Chest_Buildable's inventory template is exactly 12 slots. The sorting chest must
# match: FillInventoryInGridPanel only overwrites as many tiles as the bound inventory has
# SLOTS, so the furnace donor's 2-slot template left 10 tiles frozen on the PREVIOUS chest's
# items ("changes depending on the last chest you opened", 2026-08-06) -- and shift-clicking
# such a ghost tile ran PlayerInventory.AddItem(staleItem) for real while the chest-side
# clearing write landed out of range on the 2-slot array, a silent no-op: the item-dupe report,
# byte-for-byte. 12 slots drives every tile every fill; no ghosts, no dupes, a normal chest UI.
SORTCHEST_SLOTS = 12

def _stub_bytecode(export):
    export["ScriptBytecode"] = [
        {"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_Return, UAssetAPI",
         "ReturnExpression":
             {"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_Nothing, UAssetAPI"}},
        {"$type": "UAssetAPI.Kismet.Bytecode.Expressions.EX_EndOfScript, UAssetAPI"},
    ]

def _rename_import(d, class_name, old_obj, new_obj, old_pkg, new_pkg):
    """Exact-name import retarget (object + its package pair) -- every export/bytecode reference
    is by import INDEX, so renaming the entry redirects them all."""
    hits = 0
    for e in d["Imports"]:
        if str(e.get("ClassName")) == class_name and str(e["ObjectName"]) == old_obj:
            e["ObjectName"] = new_obj
            hits += 1
        elif str(e.get("ClassName")) == "Package" and str(e["ObjectName"]) == old_pkg:
            e["ObjectName"] = new_pkg
            hits += 1
    if hits != 2:
        sys.exit(f"sorting chest: expected exactly 2 import renames for {old_obj}, got {hits}")
    add_name(d, new_obj)
    add_name(d, new_pkg)

def build_sorting_chest():
    # the donor's component templates (inventory + the whole energy component chain) serialize
    # unversioned headers, so fromjson needs their schemas preloaded too
    place_master = ";".join([
        os.path.join(LEGACY, PLACE_DIR, "_BP_Placeable_MASTER.uasset"),
        os.path.join(LEGACY, "Solarpunk/Content/Code/Interactables/Framework",
                     "BPC_InteractableLogic.uasset"),
        os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "BC_InventorySystem.uasset"),
        os.path.join(LEGACY, "Solarpunk/Content/Code/Energy/Framework",
                     "BPC_EnergySystemComponent.uasset"),
        os.path.join(LEGACY, "Solarpunk/Content/Code/Energy/Framework",
                     "BPC_Device_EnergySystemComponent.uasset"),
        os.path.join(LEGACY, "Solarpunk/Content/Code/Energy/Framework",
                     "BPC_Active_EnergySystemComponent.uasset"),
        os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_Smeltable.uasset"),
        os.path.join(LEGACY, ITEMS_DIR, "Framework_and_Data", "S_InventorySlotSlim.uasset"),
    ])

    def _patch_item(d):
        # the world-drop model: the same wood crate the placed chest uses (its own material)
        _rename_import(d, "StaticMesh", "SM_Furnace_Electric", "SM_Crate_Wood",
                       "/Game/Art/StaticMeshes/SM_Furnace_Electric",
                       "/Game/Art/StaticMeshes/SM_Crate_Wood")

    clone_asset(os.path.join(ITEMS_DIR, "ItemActors", "BP_EnergyFurnance_Item.uasset"),
                os.path.join(ITEMS_DIR, "ItemActors", "BP_SortingChest_Item.uasset"),
                [("BP_EnergyFurnance_Item", "BP_SortingChest_Item")],
                preloads=MASTER_BP, patch=_patch_item)

    def _patch_placeable(d):
        _rename_import(d, "StaticMesh", "SM_Furnace_Electric", "SM_Crate_Wood",
                       "/Game/Art/StaticMeshes/SM_Furnace_Electric",
                       "/Game/Art/StaticMeshes/SM_Crate_Wood")
        _rename_import(d, "Material", "M_FurnaceElectric_Off", "M_Cobalt",
                       "/Game/Art/Materials/M_FurnaceElectric_Off",
                       "/Game/Art/Materials/M_Cobalt")
        stubbed = set()
        for e in d["Exports"]:
            if str(e.get("ObjectName")) in SORTCHEST_STUBS and e.get("ScriptBytecode"):
                _stub_bytecode(e)
                stubbed.add(str(e["ObjectName"]))
        missing = set(SORTCHEST_STUBS) - stubbed
        if missing:
            sys.exit(f"sorting chest: stub targets not found: {sorted(missing)}")
        # device template: idle draw by default; the Lua feature modulates it live
        dev = next(e for e in d["Exports"]
                   if e.get("ObjectName") == "BPC_Device_EnergySystemComponent_GEN_VARIABLE")
        for p in dev["Data"]:
            if p.get("Name") == "MaxPowerConsumption":
                p["Value"] = -500
            elif p.get("Name") == "CurPowerConsumption":
                p["Value"] = -100.0
        # inventory template: grow the furnace's 2 slots to a chest's 12 (see SORTCHEST_SLOTS
        # above for why 12 is load-bearing, not cosmetic). Property order must stay Inventory,
        # InventorySize, AllowQuickStack -- the chest donor's own serialized order (unversioned
        # cook writes by schema order).
        invc = next(e for e in d["Exports"]
                    if e.get("ObjectName") == "BC_InventorySystem_GEN_VARIABLE")
        inv_arr = next(p for p in invc["Data"] if p.get("Name") == "Inventory")
        slots = inv_arr["Value"]
        if len(slots) != 2:
            sys.exit(f"sorting chest: donor inventory has {len(slots)} slots, expected the "
                     "furnace's 2 -- game update changed the template, re-check the grid math")
        empty = copy.deepcopy(slots[0])
        for f in empty["Value"]:
            if f["Name"].split("_")[0] in ("Item", "Quantity") and not f.get("IsZero"):
                sys.exit("sorting chest: donor slot 0 holds an item -- refusing to stamp it out")
        while len(slots) < SORTCHEST_SLOTS:
            s = copy.deepcopy(empty)
            s["Name"] = str(len(slots))
            slots.append(s)
        size = next(p for p in invc["Data"] if p.get("Name") == "InventorySize")
        size["Value"], size["IsZero"] = SORTCHEST_SLOTS, False
        # the vanilla chest opts into Quick Stack (the Stack button + receiving deposits);
        # match it -- same BoolPropertyData shape the chest template carries
        if not any(p.get("Name") == "AllowQuickStack" for p in invc["Data"]):
            invc["Data"].append({
                "$type": "UAssetAPI.PropertyTypes.Objects.BoolPropertyData, UAssetAPI",
                "Name": "AllowQuickStack", "ArrayIndex": 0, "PropertyGuid": None,
                "IsZero": False, "PropertyTagFlags": "None", "PropertyTypeName": None,
                "PropertyTagExtensions": "NoExtension", "Value": True})
            add_name(d, "AllowQuickStack")
        # the wire hookup, made findable: the donor's SNAP_CableConnector box (tag
        # CableConnector, Building-channel overlap -- BC_BuildSystem.SnapTrace snaps a
        # BP_CableConnectorSmall onto any such box) sits at Y=63.6, inside the furnace's fat
        # footprint (Y-extent ~105) but ~21cm off the wood crate's face (Y-extent 42.5): an
        # invisible snap target floating in mid-air, which read in-game as "no cable hookup at
        # all" (2026-08-06). Pull it flush with the crate's +Y face so the connector snaps onto
        # the chest's side like on any other machine.
        snap = next(e for e in d["Exports"]
                    if e.get("ObjectName") == "SNAP_CableConnector_GEN_VARIABLE")
        rel = next(p for p in snap["Data"] if p.get("Name") == "RelativeLocation")
        v = rel["Value"][0]["Value"]
        if not (63.0 < v["Y"] < 65.0):
            sys.exit(f"sorting chest: SNAP box at Y={v['Y']}, expected the furnace's ~63.6 -- "
                     "game update moved the connector, re-derive the crate-face offset")
        v["Y"] = 44.0

    clone_asset(os.path.join(PLACE_DIR, "BP_EnergyFurnace_Placeable.uasset"),
                os.path.join(PLACE_DIR, "BP_SortingChest_Placeable.uasset"),
                [("BP_EnergyFurnace_Placeable", "BP_SortingChest_Placeable"),
                 ("BP_EnergyFurnance_Item", "BP_SortingChest_Item")],
                preloads=place_master,
                patch=_patch_placeable)

def make_sortchest_icon():
    # the vanilla chest icon re-inked cobalt blue (same watery-blue curve as the hydration wand)
    _tint_icon(ICONS_DIR, "Icon_Chest", "Icon_SortingChest",
               lambda L: (L * 1.10 + 22, L * 0.55, L * 0.32))

def patch_db_recipes():
    """DB_CraftingRecipes: TempestCodex + MundaneWand, both BENCH-only and NOT starting recipes
    (they are unlocked by the TempestCodex research row -- see patch_db_researchables). The
    SurvivalGuide row is still the structural template for every added row; its hand+bench
    ECraftingLocations pair and its StartingRecipy are rewritten per recipe (see add_recipe).
    Returns {row_name: RecipyID} for the research row's UnlockingRecepieIDs."""
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

    def add_recipe(row_name, product_cls, parts, starting=False,
                   locations=("NewEnumerator1",)):
        """starting   -- known from the start, no research card needed
           locations  -- the ECraftingLocations this recipe is offered at, written over the
                         SurvivalGuide template's hand+bench pair. None keeps that pair verbatim
                         -- NewEnumerator0 (hand) + NewEnumerator1 (Crafting Table) IS the
                         quick-craft (F) contract.

                         NewEnumerator2 is the "Energy Crafting Table" (the asset is named
                         AdvancedCraftingTable; its DB_Items DisplayName is not). Put every
                         POWERED MACHINE there -- all 16 vanilla machines are NewEnumerator2 and
                         nothing of the machine EItemType is offered anywhere else. It is also
                         the robust station: W_AdvancedWorkbenchCrafting drives ONE unfiltered
                         grid, where W_WorkbenchCrafting fans out per product EItemType
                         (1 Tools, 3 Plants, 4 Resources, 5 Furniture, 6 Devices, 7 Animals)
                         plus a whole-DB "All" grid, and the machine type has no tab of its own
                         there. The sorting chest sat at NewEnumerator1 and the player found it
                         in no category at all (2026-07-30)."""
        for loc_name in locations or ():
            val = f"ECraftingLocations::{loc_name}"
            if not any(e["Value"] == val for r in rows
                       for e in field(r, "CraftingLocations")["Value"] or []):
                sys.exit(f"{row_name}: no vanilla row uses {val}, so it is not in the table's "
                         "name map -- adding it needs add_rowkey/fix_name_count handling.")
        row = copy.deepcopy(guide)
        row["Name"] = row_name
        rid = field(row, "RecipyID")
        rid["Value"] = next_id + len(recipe_ids)   # sequential in add order
        rid["IsZero"] = False
        recipe_ids[row_name] = rid["Value"]
        sr = field(row, "StartingRecipy")
        sr["Value"], sr["IsZero"] = starting, not starting
        if locations is not None:
            loc = field(row, "CraftingLocations")
            template_loc = loc["Value"][0]
            loc["Value"] = []
            for loc_name in locations:
                e = copy.deepcopy(template_loc)
                e["Value"], e["Name"] = f"ECraftingLocations::{loc_name}", "0"
                loc["Value"].append(e)
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
    # the diamond rod: the vanilla FishingRod recipe (5 stick + 2 stone + 4 iron, bench) plus two
    # cut diamonds; unlocked by the game's existing basic FishingRod research card (see
    # patch_db_researchables)
    add_recipe("DiamondFishingRod", "BP_DiamondFishingRod_Item_C",
               [("BP_Stick_Item_C", 5), ("BP_Stone_Item_C", 2), ("BP_Iron_Item_C", 4),
                ("BP_Diamond_Item_C", 2)])
    # the sorting chest: a chest's worth of wood, a machine's worth of iron, cobalt for the blue.
    # Appended AFTER the research-gated rows so their persisted RecipyIDs stay stable in saves.
    # UN-HIDDEN (2026-08-06, with the 12-slot/dupe/connector overhaul): offered at the Energy
    # Crafting Table only (NewEnumerator2) -- every powered machine lives there; at the plain
    # Crafting Table it appeared under no category at all (see add_recipe's `locations` note).
    # It was hidden 2026-07-30 via locations=() while broken; the row stayed STARTING the whole
    # time because saves had already self-healed 10009 into UnlockedRecipys, so un-hiding is
    # exactly this one location flip, no save migration.
    add_recipe("SortingChest", "BP_SortingChest_Item_C",
               [("BP_Log_Item_C", 4), ("BP_Iron_Item_C", 4), ("BP_Cobalt_Item_C", 2)],
               starting=True, locations=("NewEnumerator2",))
    # The Tempest Handbook: the vanilla SurvivalGuide recipe verbatim (1 log + 2 leaves), left as
    # a HAND recipe -- quick-craft (F) AND bench -- and known from the start, so a brand-new
    # player can craft the thing that explains the mod in their first minute. Appended LAST so
    # every earlier RecipyID stays byte-identical: ids are positional and are persisted into
    # Playerdata.UnlockedRecipys, never re-derived from row names.
    add_recipe("TempestHandbook", "BP_TempestHandbook_Item_C",
               [("BP_Log_Item_C", 1), ("BP_Leaf_Item_C", 2)], starting=True, locations=None)

    # Pin the ladder. These numbers live in players' saves; only ever APPEND above this line.
    EXPECTED_IDS = {"TempestCodex": 10006, "MundaneWand": 10007, "DiamondFishingRod": 10008,
                    "SortingChest": 10009, "TempestHandbook": 10010}
    if recipe_ids != EXPECTED_IDS:
        sys.exit(f"RecipyID drift: {recipe_ids} != {EXPECTED_IDS} -- these ids are persisted into "
                 "Playerdata.UnlockedRecipys. Reordering add_recipe() rewrites what existing "
                 "saves think they know how to build.")

    # THE VANILLA ROD IS REPLACED (2026-07-30): the game's own FishingRod recipe row keeps its
    # RecipyID (persisted in saves -- everyone who researched the rod keeps the unlock, no
    # migration) but its END PRODUCT is repointed at the pak's ModFishingRod clone: every bench
    # that knew how to make a rod now makes the modded one. The crafting UI reads the end
    # product's DB_Items row for name/icon/tab, so the menu entry looks identical (same display
    # name, the vanilla row's own icon import). The vanilla DB_Items row itself stays -- loose
    # and unmigrated rods must keep resolving; features/fishing.lua sweeps them into the clone.
    vrod = next(r for r in rows if r["Name"] == "FishingRod")
    vsingle = field(vrod, "SingleRecipies")["Value"][0]
    vep = next(p for p in vsingle["Value"] if p["Name"].split("_")[0] == "Endproduct")
    for f in vep["Value"][0]["Value"]:
        if f["Name"].split("_")[0] == "Item":
            old_name = str(d["Imports"][-f["Value"] - 1]["ObjectName"])
            if old_name != "BP_FishingRod_Item_C":
                sys.exit(f"FishingRod recipe end product is {old_name}, expected the vanilla rod"
                         " -- refusing to repoint blind (game update changed the row?)")
            f["Value"] = cls_idx("BP_ModFishingRod_Item_C")
    print("recipe FishingRod: end product repointed -> BP_ModFishingRod_Item_C (same RecipyID)")

    # The keeper: a hidden row whose "ingredient" slots hold every book's reader-widget class ref.
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
    rid["Value"], rid["IsZero"] = next_id + len(recipe_ids), False
    sr = field(keeper, "StartingRecipy")
    sr["Value"], sr["IsZero"] = False, True
    field(keeper, "CraftingLocations")["Value"] = []
    single = field(keeper, "SingleRecipies")["Value"][0]
    ep = next(p for p in single["Value"] if p["Name"].split("_")[0] == "Endproduct")
    for f in ep["Value"][0]["Value"]:
        if f["Name"].split("_")[0] == "Item":
            f["Value"] = cls_idx("BP_TempestCodex_Item_C")
    # ONE row, one slot per book: a row struct's TArray<S_InventorySlotSlim> is walked
    # element-wise by AddReferencedObjects, so slot[1] is exactly as rooted as slot[0]. A second
    # keeper ROW would cost another row key (another add_rowkey boundary risk), another id in the
    # persisted-id space, and one more row for every full-table loop in SkygameExtraFunctions to
    # skip. Nothing ever reads these slots.
    cp = next(p for p in single["Value"] if p["Name"].split("_")[0] == "CraftingParts")
    tmpl = cp["Value"][0]
    cp["Value"] = [part_slot(tmpl, add_import_pair(d, _names(b)["widget_pkg"],
                                                   _names(b)["widget_cls"],
                                                   "WidgetBlueprintGeneratedClass", "/Script/UMG"), 0)
                   for b in BOOKS]
    for i, slot in enumerate(cp["Value"]):
        slot["Name"] = str(i)
    rows.append(keeper)
    add_rowkey(d, "TempestCodexKeeper", "DB_CraftingRecipes")
    print("recipe TempestCodexKeeper: hidden GC-keeper row roots "
          + ", ".join(_names(b)["widget_cls"] for b in BOOKS))

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

    # Diamond Fishing Rod rides the EXISTING basic "FishingRod" card (id 28, LvL_3 tier):
    # append our recipe id to its UnlockingRecepieIDs -- researching the fishing rod then also
    # teaches the diamond rod. Recipe ids ARE persisted into Playerdata.UnlockedRecipys once, at
    # research-complete time (UnlockResearch), but saves that owned the card before this row
    # grew the extra id still heal themselves: every crafting-bench interact runs
    # SkygameExtraFunctions.FixMissingCraftingRecipies, which re-derives missing ids from the
    # (patched) research map -- so no save migration is needed here either way.
    if "DiamondFishingRod" in recipe_ids:
        rod = next(r for r in rows if r["Name"] == "FishingRod")
        rur = field(rod, "UnlockingRecepieIDs")
        entry = copy.deepcopy(rur["Value"][0])
        entry["Name"] = str(len(rur["Value"]))
        entry["Value"], entry["IsZero"] = recipe_ids["DiamondFishingRod"], False
        rur["Value"].append(entry)
        print(f"research FishingRod also unlocks recipe {recipe_ids['DiamondFishingRod']}"
              " (DiamondFishingRod)")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_research_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    # S_Researchable is a standalone struct asset (NOT cooked in-package like S_CraftingRecipy)
    fromjson(jout, os.path.join(STAGED, rel, "DB_Researchables.uasset"),
             preloads=os.path.join(LEGACY, rel, "S_Researchable.uasset"))
    # NB only these are research-gated. SortingChest and TempestHandbook are StartingRecipy rows
    # and are deliberately in NO card's UnlockingRecepieIDs.
    print(f"DB_Researchables patched: {len(rows)} rows, research id {rid['Value']} unlocks "
          f"{[recipe_ids['TempestCodex'], recipe_ids['MundaneWand']]}, "
          f"FishingRod also unlocks {recipe_ids.get('DiamondFishingRod')}")

def patch_db_buildables():
    """DB_Buildables: one placeable row per book plus the sorting chest. Items are matched by
    DB_Items ROW NAME via ItemsNeeded, so each row key and its RowName are the same slug."""
    rel = "Solarpunk/Content/Code/Building_Placing/Framework_and_Data"
    src = os.path.join(LEGACY, rel, "DB_Buildables.uasset")
    j = os.path.join(OUT, "db_buildables_src.json")
    tojson(src, j)
    d = json.load(open(j, encoding="utf-8"))
    rows = d["Exports"][0]["Table"]["Data"]

    def add_buildable(donor_name, row_name, actor_cls, mesh_name):
        donor = next(r for r in rows if r["Name"] == donor_name)
        row = copy.deepcopy(donor)
        row["Name"] = row_name
        field(row, "Actor")["Value"] = add_import_pair(
            d, f"/Game/Code/Building_Placing/Placeables/{actor_cls[:-2]}", actor_cls,
            "BlueprintGeneratedClass")
        field(row, "Mesh")["Value"] = add_import_pair(
            d, f"/Game/Art/StaticMeshes/{mesh_name}", mesh_name, "StaticMesh")
        for slot in field(row, "ItemsNeeded")["Value"]:
            for f in slot["Value"]:
                if f["Name"].split("_")[0] == "Item":
                    for inner in f["Value"]:
                        if inner.get("Name") == "RowName":
                            inner["Value"] = row_name
        rows.append(row)
        add_rowkey(d, row_name, "DB_Buildables")

    # the books: SurvivalGuide-shaped placement (a small prop you set down and read). The ghost
    # mesh must match what the placeable actually shows -- the codex swapped in SM_Book_Merchant,
    # the handbook kept the donor's SM_Handbook.
    for b in BOOKS:
        add_buildable("SurvivalGuide", b["slug"], _names(b)["place"] + "_C",
                      b["place_mesh"] or "SM_Handbook")
    # the sorting chest: EnergyFurnace is the buildable donor (powered-machine placement rules,
    # slope/rotation taxonomy); actor -> our clone, ghost mesh -> the wood crate it really shows
    add_buildable("EnergyFurnace", "SortingChest",
                  "BP_SortingChest_Placeable_C", "SM_Crate_Wood")
    fix_name_count(d)
    jout = os.path.join(OUT, "db_buildables_patched.json")
    json.dump(d, open(jout, "w", encoding="utf-8"), indent=1)
    fromjson(jout, os.path.join(STAGED, rel, "DB_Buildables.uasset"), preloads=src)
    print(f"DB_Buildables patched: {len(rows)} rows")

def build_books():
    for b in BOOKS:
        build_book_enum(b)
        build_book_table(b)
        build_book_widgets(b)
        build_book_bps(b)
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
    check_prefix(ITEMS_DIR + "/Framework_and_Data/DB_Consumables.uasset",
                 os.path.join(OUT, "db_consumables_patched.json"), "DB_Consumables")
    check_prefix(ITEMS_DIR + "/Framework_and_Data/DB_Smeltables.uasset",
                 os.path.join(OUT, "db_smeltables_patched.json"), "DB_Smeltables")
    check_prefix("Solarpunk/Content/Code/Building_Placing/Framework_and_Data/DB_Buildables.uasset",
                 os.path.join(OUT, "db_buildables_patched.json"), "DB_Buildables")
    check_prefix("Solarpunk/Content/Code/Research/Framework/DB_Researchables.uasset",
                 os.path.join(OUT, "db_research_patched.json"), "DB_Researchables")
    for b in BOOKS:
        nm = _names(b)
        pages = check_prefix(TIPS_DIR + f"/{nm['table']}.uasset",
                             os.path.join(OUT, nm["table"] + ".json"), nm["table"])
        for key, _, _, _ in b["pages"]:
            assert key in pages, f"{nm['table']} lost page key {key}"
    # the widgets + enums + BPs just need to round-trip parse (widgets carry ByteProperties typed
    # to the cloned enum -> preload it for the read too)
    reads = [(PLACE_DIR + "/BP_SortingChest_Placeable.uasset", ""),
             (ITEMS_DIR + "/ItemActors/BP_SortingChest_Item.uasset", ""),
             (ITEMS_DIR + "/ItemActors/BP_ModFishingRod_Item.uasset", "")]
    for b in BOOKS:
        nm = _names(b)
        enum_pre = os.path.join(STAGED, TIPS_DIR, nm["enum"] + ".uasset")
        reads += [(WIDGETS_DIR + f"/{nm['widget']}.uasset", enum_pre),
                  (TIPS_DIR + f"/{nm['enum']}.uasset", ""),
                  (PLACE_DIR + f"/{nm['place']}.uasset", ""),
                  (ITEMS_DIR + f"/ItemActors/{nm['item']}.uasset", "")]
    for rel, pre in reads:
        vj = os.path.join(OUT, "verify_" + os.path.basename(rel) + ".json")
        run(WS, "tojson", USMAP, os.path.join(vd, rel), vj, "VER_UE5_6", pre)
        # the GC root edge: while any book stands placed, its placeable's import table is what
        # drags the reader chain in. Imports survive the legacy round trip even though exports
        # come back raw, so this is cheap to assert -- and losing it is a silent brick.
        if rel.startswith(PLACE_DIR) and "Placeable" in rel:
            want = next((_names(b)["widget_cls"] for b in BOOKS
                         if _names(b)["place"] in rel), None)
            if want:
                imps = json.load(open(vj, encoding="utf-8")).get("Imports") or []
                if not any(str(e.get("ObjectName")) == want for e in imps):
                    sys.exit(f"{os.path.basename(rel)}: lost the {want} import edge -- the reader "
                             "chain would never load and the book would be a brick")

    # The quick-craft contract, read back structurally: silently breakable, and the whole point of
    # the Tempest Handbook is that a new player finds it in the F menu.
    rd = json.load(open(os.path.join(OUT, "db_recipes_patched.json"), encoding="utf-8"))
    rrows = rd["Exports"][0]["Table"]["Data"]
    hb = next(r for r in rrows if r["Name"] == "TempestHandbook")
    locs = {e["Value"] for e in field(hb, "CraftingLocations")["Value"]}
    if not field(hb, "StartingRecipy")["Value"]:
        sys.exit("TempestHandbook: StartingRecipy is False -- it would need a research card")
    if "ECraftingLocations::NewEnumerator0" not in locs:
        sys.exit(f"TempestHandbook: not a quick-craft (F) recipe, locations = {sorted(locs)}")
    # The sorting chest is LIVE again (2026-08-06): Energy-Crafting-Table ONLY -- the plain
    # table shows machine-type products in no category, and a hand location would put it in
    # quick-craft. StartingRecipy stays True (saves self-healed 10009 long ago).
    sc = next(r for r in rrows if r["Name"] == "SortingChest")
    sc_locs = {e["Value"] for e in (field(sc, "CraftingLocations")["Value"] or [])}
    if not field(sc, "StartingRecipy")["Value"]:
        sys.exit("SortingChest: StartingRecipy is False -- existing saves would lose the recipe")
    if sc_locs != {"ECraftingLocations::NewEnumerator2"}:
        sys.exit(f"SortingChest: must be Energy-Crafting-Table only, locations = {sorted(sc_locs)}")
    # The vanilla-rod replacement, read back structurally: the FishingRod recipe must yield the
    # mod clone (or crafting silently hands back the ladder-cursed vanilla rod), and the clone's
    # row must carry interaction=1 (or a UI close uncasts it -- the whole point of the swap).
    vrod = next(r for r in rrows if r["Name"] == "FishingRod")
    vep = next(p for p in field(vrod, "SingleRecipies")["Value"][0]["Value"]
               if p["Name"].split("_")[0] == "Endproduct")
    item_idx = next(f["Value"] for f in vep["Value"][0]["Value"]
                    if f["Name"].split("_")[0] == "Item")
    got = str(rd["Imports"][-item_idx - 1]["ObjectName"])
    if got != "BP_ModFishingRod_Item_C":
        sys.exit(f"FishingRod recipe crafts {got} -- the vanilla-rod replacement did not take")
    idd = json.load(open(os.path.join(OUT, "db_items_patched.json"), encoding="utf-8"))
    mrow = next(r for r in idd["Exports"][0]["Table"]["Data"] if r["Name"] == "ModFishingRod")
    if field(mrow, "ItemInteractionType")["Value"] != "EItemInteractionType::NewEnumerator1":
        sys.exit("ModFishingRod row lost interaction=1 (tool) -- a UI close would uncast it")
    drow = next(r for r in idd["Exports"][0]["Table"]["Data"] if r["Name"] == "DiamondFishingRod")
    ddur = field(drow, "DefaultAttribues")["Value"][0]
    dval = next(f["Value"] for f in ddur["Value"] if f["Name"].split("_")[0] == "Value")
    if int(dval) != 999:
        sys.exit(f"DiamondFishingRod durability is {dval}, expected 999 (keep mapping.lua in sync)")

    keeper = next(r for r in rrows if r["Name"] == "TempestCodexKeeper")
    slots = next(p for p in field(keeper, "SingleRecipies")["Value"][0]["Value"]
                 if p["Name"].split("_")[0] == "CraftingParts")["Value"]
    if len(slots) != len(BOOKS):
        sys.exit(f"keeper roots {len(slots)} widget classes, expected {len(BOOKS)} -- a book's "
                 "reader chain would be GC'd mid-session")
    print("verify: all tables + widgets survive the zen round-trip; "
          f"{len(BOOKS)} books rooted, quick-craft contract intact")

# ---------------------------------------------------------------- 3. pack + install
def pack():
    utoc = os.path.join(OUT, "z_SolarpunkWand_P.utoc")
    run(RETOC, "to-zen", STAGED, utoc, "--version", "UE5_7")
    for ext in (".utoc", ".ucas", ".pak"):
        f = os.path.join(OUT, "z_SolarpunkWand_P" + ext)
        if not os.path.exists(f):
            sys.exit(f"missing pack output {f}")
        print("built", f, os.path.getsize(f), "bytes")
    # NOT ~mods/ -- that mounts at order 103, BELOW the base container, where these edits are
    # silently shadowed. install.py copies the triple in under the _1_P name (order 204).
    print("build complete -- run python tools/run.py (or python install.py, game closed) to"
          " install the triple as <game>/Content/Paks/Solarpunk-Windows_1_P.*")

if __name__ == "__main__":
    shutil.rmtree(STAGED, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    clone_bp("BP_MundaneWand_Item")
    clone_bp("BP_HydrationWand_Item")
    clone_bp("BP_ElectricWand_Item")
    clone_bp("BP_ChargedElectricWand_Item")
    # fishing-overhaul: the diamond rod + the gilded catches
    clone_item_bp("BP_FishingRod_Item", "BP_DiamondFishingRod_Item")
    # vanilla-rod replacement (2026-07-30): same clone recipe, vanilla stats (see patch_db_items)
    clone_item_bp("BP_FishingRod_Item", "BP_ModFishingRod_Item")
    clone_item_bp("BP_Egg_Item", "BP_GoldEgg_Item")
    clone_item_bp("BP_Truffle_Item", "BP_GoldTruffle_Item")
    make_icons()
    make_fishing_icons()
    make_sortchest_icon()
    build_sorting_chest()
    build_books()
    patch_db_items()
    patch_db_smeltables()
    patch_db_consumables()
    pack()
    verify_pak()
    print("DONE")
