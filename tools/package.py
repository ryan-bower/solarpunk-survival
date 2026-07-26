#!/usr/bin/env python3
"""Assemble a release zip: install.py + the vendored UE4SS runtime + the Lua mod + the
content pak, laid out so a player unzips it, runs `python install.py`, and is done - no
other downloads, no dev tools anywhere in the zip.

    python tools/package.py    (run from anywhere)
"""

import json
import shutil
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PAK = "Solarpunk-Windows_1_P"
MOD = "SolarpunkSurvival"


def stage_mod(src: Path, dst: Path):
    """The mod, minus everything developer-flavored: Scripts/dev (RE dumper, remote exec
    channel, ritual dev kit), local saves, dump contents, caches."""
    for f in src.rglob("*"):
        if f.is_dir():
            continue
        rel = f.relative_to(src)
        if rel.parts[:2] == ("Scripts", "dev") or "__pycache__" in rel.parts:
            continue
        if rel.parts[0] in ("save", "dump") and rel.name != ".gitkeep":
            continue
        out = dst / rel
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(f, out)


def main():
    version = json.loads((REPO / "manifest.json").read_text())["modVersion"]
    name = f"{MOD}-v{version}"
    stage = REPO / "dist" / name
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    # 1) the installer - the only thing a player has to run - and the manifest it reads
    shutil.copy2(REPO / "install.py", stage)
    shutil.copy2(REPO / "manifest.json", stage)

    # 2) the vendored UE4SS runtime (trimmed, runtime-only build of the patched UE4SS)
    vendor = REPO / "vendor" / "UE4SS-Solarpunk-runtime.zip"
    if not vendor.is_file():
        sys.exit(f"Missing {vendor} - build it first: python tools/make_ue4ss_runtime.py")
    (stage / "vendor").mkdir()
    shutil.copy2(vendor, stage / "vendor")

    # 3) the Lua mod, in the same mod/ layout install.py reads from a repo clone
    stage_mod(REPO / "mod" / MOD, stage / "mod" / MOD)

    # 4) the content pak, pre-named to its final mount-order name
    triple = next((c for c in (REPO / "paks" / PAK,
                               REPO / "paks" / "z_SolarpunkWand_P",
                               REPO / "tools" / "pakkit" / "out" / "z_SolarpunkWand_P")
                   if all(c.with_suffix(ext).is_file() for ext in (".utoc", ".ucas", ".pak"))), None)
    if triple:
        (stage / "paks").mkdir()
        for ext in (".utoc", ".ucas", ".pak"):
            shutil.copy2(triple.with_suffix(ext), stage / "paks" / (PAK + ext))
        print(f"Content pak: {triple}.*")
    else:
        # Game-derived cooked data, not committed to the public repo - it has to be built.
        print("WARNING: no content pak found - the zip will install the Lua mod only "
              "(no wands, no codex). Build one first: python tools/pakkit/build_wand_pak.py")

    # 5) docs
    shutil.copy2(REPO / "README.md", stage / "README.txt")
    shutil.copy2(REPO / "docs" / "INSTALL.md", stage / "INSTALL.txt")

    # 6) zip
    zip_path = REPO / "dist" / f"{name}.zip"
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for f in sorted(stage.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(stage))
    manifest = json.loads((REPO / "manifest.json").read_text())
    print(f"Packaged -> {zip_path}  ({zip_path.stat().st_size / 1e6:.1f} MB)")
    print(f"Tested game build(s): {', '.join(manifest['testedGameBuilds'])}")
    print("Players unzip it and run:  python install.py   (nothing else to download)")


if __name__ == "__main__":
    main()
