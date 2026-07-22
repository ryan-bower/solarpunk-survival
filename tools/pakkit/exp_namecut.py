"""Empirically measure retoc's low-name-block truncation on DB_Items variants.

For each variant: patch json -> fromjson -> mini staged dir -> retoc to-zen -> to-legacy
(with the game's global.* beside it) -> tojson -> report which low-block names survived.
"""
import copy, json, os, shutil, subprocess, sys

PK = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(PK, "out")
WS = os.path.join(PK, "wandsmith", "bin", "Release", "net10.0", "wandsmith.exe")
RETOC = os.path.join(PK, "retoc.exe")
USMAP = os.path.join(PK, "Solarpunk.usmap")
GAME_PAKS = r"C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk\Content\Paks"
REL = "Solarpunk/Content/Code/Inventory_Items/Framework_and_Data"
LEGACY_SRC = os.path.join(PK, "legacy", REL, "DB_Items.uasset")
EXP = os.path.join(OUT, "exp")


def run(*args):
    r = subprocess.run(list(args), capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED {args}\n{r.stdout}\n{r.stderr}")


def build_variant(name, mutate):
    d = json.loads(open(os.path.join(OUT, "db_items_patched.json"), encoding="utf-8").read())
    mutate(d)
    vdir = os.path.join(EXP, name)
    staged = os.path.join(vdir, "staged", REL)
    shutil.rmtree(vdir, ignore_errors=True)
    os.makedirs(staged)
    j = os.path.join(vdir, "in.json")
    json.dump(d, open(j, "w", encoding="utf-8"), indent=1)
    run(WS, "fromjson", USMAP, j, os.path.join(staged, "DB_Items.uasset"), "VER_UE5_6",
        LEGACY_SRC)
    # pack + unpack
    zin = os.path.join(vdir, "zen_in")
    os.makedirs(zin)
    run(RETOC, "to-zen", os.path.join(vdir, "staged"), os.path.join(zin, "exp_P.utoc"),
        "--version", "UE5_7")
    for f in ("global.utoc", "global.ucas"):
        shutil.copy2(os.path.join(GAME_PAKS, f), zin)
    leg = os.path.join(vdir, "legacy")
    run(RETOC, "to-legacy", zin, leg)
    vj = os.path.join(vdir, "roundtrip.json")
    run(WS, "tojson", USMAP, os.path.join(leg, REL, "DB_Items.uasset"), vj, "VER_UE5_6")
    rd = json.load(open(vj, encoding="utf-8"))
    post = [str(n) for n in rd["NameMap"]]
    pre = [str(n) for n in d["NameMap"]]
    a = pre.index("DB_Items")
    low = pre[:a]
    missing = [(i, n) for i, n in enumerate(low) if n not in set(post)]
    print(f"[{name}] low={len(low)} DB_Items@{a} rows={len(d['Exports'][0]['Table']['Data'])} "
          f"dropped={missing if missing else 'NONE'}")
    return missing


def strip_hydration(d):
    rows = d["Exports"][0]["Table"]["Data"]
    d["Exports"][0]["Table"]["Data"] = [r for r in rows if str(r["Name"]) != "HydrationWand"]
    d["NameMap"] = [n for n in d["NameMap"] if str(n) != "HydrationWand"]


def pad_tail(n_pads):
    def m(d):
        nm = d["NameMap"]
        a = nm.index("DB_Items")
        for i in range(n_pads):
            nm.insert(a, f"Zz_RowkeyPad{i}")
            a += 1
    return m


def noop(d):
    pass


if __name__ == "__main__":
    os.makedirs(EXP, exist_ok=True)
    which = sys.argv[1:] or ["current", "nohydra", "pad4"]
    if "current" in which:
        build_variant("current", noop)
    if "nohydra" in which:
        build_variant("nohydra", strip_hydration)
    if "pad4" in which:
        build_variant("pad4", pad_tail(4))
    if "pad8" in which:
        build_variant("pad8", pad_tail(8))
