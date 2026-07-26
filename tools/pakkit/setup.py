#!/usr/bin/env python3
"""One-time bootstrap for the content-pak toolchain (only needed if you BUILD the pak; players
never run this). Fetches or builds everything build_wand_pak.py needs:

    Python / .NET SDK / Lua / git  ->  winget
    retoc.exe                      ->  GitHub release
    UAssetAPI/                     ->  git clone
    wandsmith.exe                  ->  dotnet build
    legacy/                        ->  retoc to-legacy of the game's own paks (~2 GB, minutes)

The one thing it cannot fetch is Solarpunk.usmap - that is dumped from the RUNNING game (see
HOWTO.md); you are told about it at the end if it is missing.

    python tools/pakkit/setup.py [--game-paks PATH] [--skip-legacy]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
RETOC_URL = "https://github.com/trumank/retoc/releases/download/v0.1.5/retoc_cli-x86_64-pc-windows-msvc.zip"

sys.path.insert(0, str(HERE.parent.parent))
import install as inst  # noqa: E402 - Steam library detection lives in the installer


def step(msg):
    print(f"  {msg}", flush=True)


def warn(msg):
    print(f"  ! {msg}", flush=True)


def have(exe):
    return shutil.which(exe) is not None


def refresh_path():
    """winget puts things on PATH for NEW shells; refresh this one so the rest of the
    script sees them (machine + user PATH from the registry)."""
    import winreg
    parts = []
    for hive, key in ((winreg.HKEY_LOCAL_MACHINE,
                       r"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"),
                      (winreg.HKEY_CURRENT_USER, "Environment")):
        try:
            with winreg.OpenKey(hive, key) as k:
                parts.append(winreg.QueryValueEx(k, "Path")[0])
        except OSError:
            pass
    os.environ["PATH"] = os.environ["PATH"] + os.pathsep + os.pathsep.join(parts)


def ensure_winget(exe, pkg_id, label):
    if have(exe):
        step(f"{label} present")
        return
    if not have("winget"):
        warn(f"{label} missing and winget is unavailable - install {label} manually")
        return
    step(f"installing {label} ({pkg_id})...")
    subprocess.run(["winget", "install", "--id", pkg_id, "--exact", "--silent",
                    "--accept-package-agreements", "--accept-source-agreements"],
                   capture_output=True)
    refresh_path()
    if have(exe):
        step(f"{label} installed")
    else:
        warn(f"{label} installed but not on PATH yet - reopen the shell and re-run")


def ensure_retoc():
    retoc = HERE / "retoc.exe"
    if retoc.is_file():
        step("retoc.exe present")
        return retoc
    step("downloading retoc...")
    import urllib.request
    with tempfile.TemporaryDirectory(prefix="retoc_") as tmp:
        tmp = Path(tmp)
        zip_path = tmp / "retoc.zip"
        urllib.request.urlretrieve(RETOC_URL, zip_path)
        with zipfile.ZipFile(zip_path) as z:
            z.extractall(tmp)
        # the release zip has carried both retoc.exe and retoc_cli.exe over its life
        exe = next(tmp.rglob("retoc*.exe"), None)
        if not exe:
            sys.exit(f"No retoc executable inside {RETOC_URL} - grab it manually from "
                     "https://github.com/trumank/retoc/releases")
        shutil.copy2(exe, retoc)
    step("retoc.exe installed")
    return retoc


def ensure_uassetapi():
    uapi = HERE / "UAssetAPI"
    if (uapi / "UAssetAPI" / "UAssetAPI.csproj").is_file():
        step("UAssetAPI present")
    elif have("git"):
        step("cloning UAssetAPI...")
        subprocess.run(["git", "clone", "--depth", "1",
                        "https://github.com/atenfyr/UAssetAPI", str(uapi)])
    else:
        warn("UAssetAPI missing and git is unavailable - clone "
             "https://github.com/atenfyr/UAssetAPI into tools/pakkit/UAssetAPI")


def build_wandsmith():
    if not have("dotnet"):
        warn("no dotnet on PATH - cannot build wandsmith")
        return
    step("building wandsmith...")
    subprocess.run(["dotnet", "build", "-c", "Release", str(HERE / "wandsmith"),
                    "--nologo", "-v", "quiet"])
    if (HERE / "wandsmith" / "bin" / "Release" / "net10.0" / "wandsmith.exe").is_file():
        step("wandsmith built")
    else:
        warn("wandsmith did not build - see the dotnet output above")


def find_game_paks():
    for lib in inst.steam_libraries():
        c = lib / "steamapps" / "common" / "Solarpunk" / "Solarpunk" / "Content" / "Paks"
        if (c / "Solarpunk-Windows_0_P.utoc").is_file():
            return c
    return None


def ensure_legacy(retoc, game_paks, skip):
    legacy = HERE / "legacy"
    if skip:
        step("skipped the legacy/ extraction (--skip-legacy)")
        return
    if (legacy / "Solarpunk").exists():
        step("legacy/ present")
        return
    paks = Path(game_paks) if game_paks else find_game_paks()
    if not paks or not paks.is_dir():
        warn('could not find the game Paks folder - re-run with --game-paks "<game>/Content/Paks"')
        return
    step(f"extracting the game's assets from {paks} (~2 GB, several minutes)...")
    if subprocess.run([str(retoc), "to-legacy", str(paks), str(legacy)]).returncode != 0:
        sys.exit("retoc to-legacy failed")
    step("legacy/ extracted")


def main():
    ap = argparse.ArgumentParser(description="Bootstrap the content-pak build toolchain (dev only).")
    ap.add_argument("--game-paks", metavar="PATH", help="the game's Content/Paks folder")
    ap.add_argument("--skip-legacy", action="store_true", help="skip the ~2 GB legacy/ extraction")
    args = ap.parse_args()

    print("pakkit setup")
    ensure_winget("git", "Git.Git", "git")
    ensure_winget("python", "Python.Python.3.12", "Python 3.12")
    ensure_winget("dotnet", "Microsoft.DotNet.SDK.10", ".NET 10 SDK")
    ensure_winget("lua", "DEVCOM.Lua", "Lua 5.4 (for tests/spec.lua)")
    retoc = ensure_retoc()
    ensure_uassetapi()
    build_wandsmith()
    ensure_legacy(retoc, args.game_paks, args.skip_legacy)

    print()
    if (HERE / "Solarpunk.usmap").is_file():
        print("Ready:  python tools/pakkit/build_wand_pak.py")
    else:
        warn("Solarpunk.usmap is missing - it is dumped from the RUNNING game, so it cannot be")
        warn('fetched here. See the "Prerequisites" section of tools/pakkit/HOWTO.md (LoadAsset')
        warn("the item framework, then DumpUSMAP() over the mod remote channel), and drop the")
        warn("result here as Solarpunk.usmap.")


if __name__ == "__main__":
    main()
