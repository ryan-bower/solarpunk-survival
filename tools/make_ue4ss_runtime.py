#!/usr/bin/env python3
"""Build vendor/UE4SS-Solarpunk-runtime.zip from the full Solarpunk-patched UE4SS dev zip.

The dev zip (Nexus mod 4, "UE4SS SP Developer") is 33 MB of which most is developer
tooling: UE4SS.pdb, the Kismet debugger / event viewer DLLs, dumper configs, docs and
other games' configs. Players need none of it, and the mod's policy is that installs
ship no dev tools - so the repo vendors this trimmed, runtime-only payload instead and
the installers extract it. Nobody has to download anything from the internet.

The payload also carries the Visual C++ 2015-2022 x64 runtime DLLs UE4SS links against,
copied from this machine's System32 and redistributed app-local (which Microsoft's
Visual Studio redistributable terms permit). They land next to the game exe, which is
the first directory Windows searches for a non-KnownDLL, so no machine-wide install and
no UAC prompt is needed and the installer makes no network requests at all.

Run this only when adopting a NEW patched UE4SS build:

    python tools/make_ue4ss_runtime.py [path/to/UE4SS*.zip] [--no-vcruntime]

Without an argument it picks the newest UE4SS*.zip in the repo root / Downloads.
The output zip keeps the dev zip's top-level layout (dwmapi.dll + ue4ss/) so the
installer just extracts it next to the game exe.
"""

import os
import sys
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "vendor" / "UE4SS-Solarpunk-runtime.zip"

# Kept in sync with install.py's VCRUNTIME_DLLS.
VCRUNTIME = ("msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
             "vcruntime140.dll", "vcruntime140_1.dll", "concrt140.dll")

# What players need at runtime, and nothing else.
KEEP_FILES = {
    "dwmapi.dll",             # the injection proxy Wine/Windows loads next to the exe
    "ue4ss/UE4SS.dll",
    "ue4ss/UE4SS-settings.ini",
    "ue4ss/LICENSE",          # UE4SS is MIT - the license text must travel with the binary
    "ue4ss/README.md",
    "ue4ss/Changelog.md",
}
KEEP_TREES = (
    "ue4ss/UE4SS_Signatures/",       # AOB signature scripts the patched 5.7.1 scan uses
    "ue4ss/Mods/Keybinds/",          # UE4SS built-in keybind dispatcher (RegisterKeyBind)
    "ue4ss/Mods/ConsoleEnablerMod/", # in-game console - players use the sps_* commands
    "ue4ss/Mods/BPModLoaderMod/",    # loads Blueprint logic mods from content paks
    "ue4ss/Mods/BPML_GenericFunctions/",
    "ue4ss/Mods/shared/UEHelpers/",  # stock library BPModLoader/Keybinds may require()
    "ue4ss/Mods/shared/Types.lua",
)

# mods.txt / mods.json rewritten to reference only the mods that actually ship.
MODS_TXT = """\
BPML_GenericFunctions : 1
BPModLoaderMod : 1
ConsoleEnablerMod : 1

; Built-in keybinds, do not move up!
Keybinds : 1
"""
MODS_JSON = """\
[
    {"mod_name": "BPML_GenericFunctions", "mod_enabled": true},
    {"mod_name": "BPModLoaderMod", "mod_enabled": true},
    {"mod_name": "ConsoleEnablerMod", "mod_enabled": true},
    {"mod_name": "Keybinds", "mod_enabled": true}
]
"""

# Settings the game needs, pre-applied so a bare extraction is already correct:
# UE4SS cannot auto-detect UE 5.7, the AOB scan needs a bigger budget on this game,
# and the console windows are dev tools (UE4SS.log carries everything they show).
INI_WANT = {
    "ConsoleEnabled": "0",
    "GuiConsoleEnabled": "0",
    "GuiConsoleVisible": "0",
    "MajorVersion": "5",
    "MinorVersion": "7",
    "SecondsToScanBeforeGivingUp": "120",
}


def normalize_ini(text: str) -> str:
    import re
    for key, val in INI_WANT.items():
        text = re.sub(rf"(?m)^{key}\s*=.*$", f"{key} = {val}", text)
    return text


def find_dev_zip():
    for d in (REPO, Path.home() / "Downloads"):
        zips = sorted(d.glob("UE4SS*.zip"), key=lambda p: p.stat().st_mtime, reverse=True)
        if zips:
            return zips[0]
    return None


def add_vcruntime(out: zipfile.ZipFile) -> int:
    """Copy the VC++ runtime DLLs into the payload root (= Binaries/Win64 once extracted).
    Only meaningful when built on Windows; on Linux the files simply are not there and the
    installer falls back to its Microsoft download."""
    sys32 = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
    added = 0
    for dll in VCRUNTIME:
        src = sys32 / dll
        if not src.is_file():
            print(f"  ! {dll} not in {sys32} - skipped")
            continue
        out.writestr(dll, src.read_bytes())
        added += 1
    return added


def main():
    args = [a for a in sys.argv[1:] if a != "--no-vcruntime"]
    want_vc = "--no-vcruntime" not in sys.argv[1:]
    src = Path(args[0]) if args else find_dev_zip()
    if not src or not src.is_file():
        sys.exit("No UE4SS*.zip found (repo root / Downloads). Pass its path as an argument.")

    OUT.parent.mkdir(exist_ok=True)
    kept = 0
    with zipfile.ZipFile(src) as z, \
         zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as out:
        for info in z.infolist():
            n = info.filename
            if n.endswith("/"):
                continue
            if not (n in KEEP_FILES or any(n.startswith(t) for t in KEEP_TREES)):
                continue
            data = z.read(info)
            if n == "ue4ss/UE4SS-settings.ini":
                data = normalize_ini(data.decode("utf-8", errors="replace")).encode("ascii", errors="replace")
            out.writestr(info.filename, data)
            kept += 1
        out.writestr("ue4ss/Mods/mods.txt", MODS_TXT)
        out.writestr("ue4ss/Mods/mods.json", MODS_JSON)
        kept += 2
        if want_vc:
            n = add_vcruntime(out)
            kept += n
            print(f"  + {n} Visual C++ runtime DLL(s) bundled app-local")
    print(f"{src.name} -> {OUT.relative_to(REPO)}: {kept} files, "
          f"{OUT.stat().st_size / 1e6:.1f} MB (dev zip was {src.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
