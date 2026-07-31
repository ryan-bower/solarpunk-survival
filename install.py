#!/usr/bin/env python3
"""Solarpunk Survival - the one installer. Pure Python (3.8+), nothing to download, no dev tools.

    python install.py                (Windows;  or:  py install.py, or double-click install.bat)
    python3 install.py               (Linux / Steam Deck, running the game via Proton)

Everything the mod needs ships in this folder: a trimmed runtime-only build of the
Solarpunk-patched UE4SS, the Visual C++ runtime DLLs UE4SS links against (placed app-local, so
nothing is installed machine-wide), the Lua mod, and the content pak. The script finds your
Solarpunk install via Steam, puts UE4SS next to the game exe, copies the Lua mod into UE4SS's
Mods folder and the content pak into Content/Paks. It makes no network requests at all unless
the bundled runtime DLLs are somehow absent AND the machine lacks the runtime.

Idempotent - re-run any time to update after a `git pull` or over an older release zip.

    --game-dir PATH   skip auto-detection (the Solarpunk folder, or its Binaries/Win64)
    --skip-pak        install the Lua mod only - no wands, no books, no diamond rod
    --no-vcredist     don't check for / install the Visual C++ runtime (Windows)
    --vcrun           Linux: also run `protontricks <appid> vcrun2022` now
    --force           reinstall the UE4SS core even if it is already there
    --status          report what is currently installed, change nothing
    --uninstall       remove the mod + content pak (leaves UE4SS in place)
    --purge           remove everything this installer ever puts on disk, UE4SS included

This file doubles as the library tools/run.py (the dev deploy-and-launch flow) imports, so
player installs and dev deploys can never drift apart.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

APP_ID = 1805110
EXE = "SolarpunkSteam-Win64-Shipping.exe"
PAK = "Solarpunk-Windows_1_P"  # mount order 204 - ABOVE the game's own _0_P (104). See docs/INSTALL.md.
MOD = "SolarpunkSurvival"
ROOT = Path(__file__).resolve().parent
VENDOR_UE4SS = ROOT / "vendor" / "UE4SS-Solarpunk-runtime.zip"
GAMEDIR_CACHE = ROOT / "tools" / ".gamedir"
IS_WIN = os.name == "nt"

# Files a re-extraction must not clobber: the user may have tweaked settings, and an existing
# install's mod lists can reference mods the runtime payload doesn't ship.
UE4SS_PRESERVE = {"ue4ss/UE4SS-settings.ini", "ue4ss/Mods/mods.txt", "ue4ss/Mods/mods.json"}

# The Visual C++ 2015-2022 x64 runtime UE4SS links against, shipped inside the vendored payload
# and extracted next to the game exe. Binaries/Win64 IS the exe's own directory, which Windows
# searches first for non-KnownDLLs, so an app-local copy satisfies the load with no machine-wide
# install and no UAC prompt. Kept in sync with tools/make_ue4ss_runtime.py's VCRUNTIME.
VCRUNTIME_DLLS = ("msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
                  "vcruntime140.dll", "vcruntime140_1.dll", "concrt140.dll")

# UE4SS cannot auto-detect UE 5.7, the AOB scan needs a bigger budget on this game, and the
# console windows are dev tools (UE4SS.log carries everything they show) - keep them off.
INI_WANT = {"ConsoleEnabled": "0", "GuiConsoleEnabled": "0", "GuiConsoleVisible": "0",
            "MajorVersion": "5", "MinorVersion": "7", "SecondsToScanBeforeGivingUp": "120"}


def say(msg=""):
    print(msg, flush=True)


def step(msg):
    say(f"  {msg}")


def warn(msg):
    say(f"  ! {msg}")


def fail(msg):
    # Plain, stack-trace-free errors: this script is run by players, not developers.
    sys.exit(f"\n{msg}")


# --- locate the game -----------------------------------------------------------------------

def resolve_game_dir(d):
    """Accept the Solarpunk folder, its parent, or Binaries/Win64; return the folder that
    holds Binaries/ and Content/ (.../steamapps/common/Solarpunk/Solarpunk), or None."""
    if not d:
        return None
    d = Path(d)
    for c in (d, d / "Solarpunk", d.parent.parent):
        if (c / "Binaries" / "Win64" / EXE).is_file():
            return c.resolve()
    return None


def steam_roots():
    roots = []
    if IS_WIN:
        import winreg
        for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                          (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
                          (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam")):
            try:
                with winreg.OpenKey(hive, key) as k:
                    for name in ("SteamPath", "InstallPath"):
                        try:
                            roots.append(winreg.QueryValueEx(k, name)[0])
                        except OSError:
                            pass
            except OSError:
                pass
        roots.append(r"C:\Program Files (x86)\Steam")
    else:
        home = Path.home()
        roots += [home / ".local/share/Steam", home / ".steam/steam", home / ".steam/root",
                  home / ".var/app/com.valvesoftware.Steam/data/Steam",
                  home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"]
    return [Path(str(r).replace("/", os.sep)) for r in roots]


def steam_libraries():
    """Every steamapps/ dir Steam knows about: each root's own plus libraryfolders.vdf
    entries (and Steam Deck SD cards on Linux). Order-preserving, deduped."""
    libs = []
    for root in steam_roots():
        libs.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.is_file():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors="replace")):
                libs.append(Path(m.group(1).replace("\\\\", "\\")))
    if not IS_WIN and Path("/run/media").is_dir():  # Steam Deck SD cards
        libs += sorted(p for pat in ("*", "*/*") for p in Path("/run/media").glob(pat)
                       if (p / "steamapps").is_dir())
    seen, out = set(), []
    for lib in libs:
        key = str(lib).lower()
        if key not in seen:
            seen.add(key)
            out.append(lib)
    return out


def find_game_dir():
    for lib in steam_libraries():
        hit = resolve_game_dir(lib / "steamapps" / "common" / "Solarpunk")
        if hit:
            return hit
    return None


def get_game_dir(cli_dir=None):
    if cli_dir:
        game = resolve_game_dir(cli_dir)
        if not game:
            fail(f"No {EXE} under '{cli_dir}' - pass --game-dir with the folder that contains Binaries/Win64.")
        return game
    if GAMEDIR_CACHE.is_file():  # detection result from a previous run
        game = resolve_game_dir(GAMEDIR_CACHE.read_text().strip())
        if game:
            return game
    game = find_game_dir()
    if not game:
        # Two very different causes, and the old message only addressed the rarer one. Lead with
        # "is it installed?" - this installer adds a mod to Solarpunk, it cannot fetch the game,
        # and being told to pass --game-dir is useless advice when there is no game to point at.
        fail(f"Could not find Solarpunk in any Steam library.\n\n"
             f"Is the game installed? This installs the MOD into an existing copy of Solarpunk -\n"
             f"it can't download the game itself. Install it from Steam first (app {APP_ID}):\n"
             f"    steam://install/{APP_ID}\n\n"
             'Already installed somewhere unusual? Point at it:\n'
             '    python install.py --game-dir "<...\\steamapps\\common\\Solarpunk\\Solarpunk>"')
    try:
        GAMEDIR_CACHE.parent.mkdir(parents=True, exist_ok=True)
        GAMEDIR_CACHE.write_text(str(game))
    except OSError:
        pass
    return game


# --- process control -----------------------------------------------------------------------

def game_running():
    """Is the game up right now? Everything that writes into the install asks this first.

    /FO CSV is load-bearing. tasklist's default table format truncates the Image Name column to
    25 characters, and this exe's name is 33 - so it printed "SolarpunkSteam-Win64-Ship" and the
    obvious `EXE in output` test was ALWAYS False. The filter matched and the row came back; only
    the name we compared against had been cut. Which meant this returned False with the game
    running: installs went ahead over locked files, run.py's stop_game() never killed anything
    (its "UE4SS.log still locked by the old instance" fallback exists because of exactly this),
    and --purge would have deleted UE4SS out from under a live process. CSV quotes the full name.
    """
    if IS_WIN:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {EXE}", "/NH", "/FO", "CSV"],
                             capture_output=True, text=True).stdout
        return EXE.lower() in out.lower()
    return subprocess.run(["pgrep", "-f", EXE], capture_output=True).returncode == 0


# --- UE4SS core (from the vendored runtime payload - nothing to download) ------------------

def vendored_names():
    """Top-level file names inside the vendored payload - i.e. exactly what an extraction drops
    into Binaries/Win64. Empty set if the payload is gone, which makes every caller conservative."""
    try:
        with zipfile.ZipFile(VENDOR_UE4SS) as z:
            return {n for n in z.namelist() if "/" not in n.rstrip("/")}
    except (OSError, zipfile.BadZipFile):
        return set()


def install_ue4ss(win64: Path):
    """Extract the trimmed runtime-only UE4SS next to the game exe. Stock UE4SS cannot scan
    this game's UE 5.7.1 build; the vendored payload is the Solarpunk-patched build with the
    dev tooling (debug symbols, debugger DLLs, dumper configs) stripped out."""
    if not VENDOR_UE4SS.is_file():
        fail(f"Missing {VENDOR_UE4SS}.\n"
             "It ships with the repo and the release zip; if you deleted it, restore it with\n"
             "`git checkout vendor/` (or rebuild it: python tools/make_ue4ss_runtime.py).")
    with zipfile.ZipFile(VENDOR_UE4SS) as z:
        for info in z.infolist():
            n = info.filename
            if n.endswith("/"):
                continue
            dst = win64 / Path(*n.split("/"))
            if n in UE4SS_PRESERVE and dst.is_file():
                continue
            dst.parent.mkdir(parents=True, exist_ok=True)
            with z.open(info) as src, open(dst, "wb") as f:
                shutil.copyfileobj(src, f)
    step(f"installed the UE4SS runtime from {VENDOR_UE4SS.name}")


def ensure_ini(ue4ss: Path):
    """Pin the settings the game needs - rewrite only when wrong (fresh extractions of the
    vendored payload already carry these values)."""
    ini = ue4ss / "UE4SS-settings.ini"
    if not ini.is_file():
        return
    txt = new = ini.read_text(errors="replace")
    for key, val in INI_WANT.items():
        new = re.sub(rf"(?m)^{key}\s*=.*$", f"{key} = {val}", new)
    if new != txt:
        ini.write_text(new, encoding="ascii")
        step("UE4SS settings normalized (console windows off, engine pinned to 5.7)")


def ensure_mod_lists(ue4ss: Path):
    """enabled.txt (shipped inside the mod folder) is what actually enables the mod; the
    mods.txt / mods.json entries are belt-and-braces for UE4SS builds that only read a list."""
    mods_txt = ue4ss / "Mods" / "mods.txt"
    if mods_txt.is_file():
        lines = mods_txt.read_text(errors="replace").splitlines()
        if not any(re.match(rf"^\s*{MOD}\s*:", l) for l in lines):
            out, done = [], False
            for l in lines:
                if not done and re.match(r"^\s*(;.*keybinds.*|Keybinds\s*:.*)$", l, re.IGNORECASE):
                    out.append(f"{MOD} : 1")
                    done = True
                out.append(l)
            if not done:
                out.append(f"{MOD} : 1")
            mods_txt.write_text("\n".join(out) + "\n", encoding="ascii")
            step(f"enabled {MOD} in mods.txt")

    mods_json = ue4ss / "Mods" / "mods.json"
    if mods_json.is_file():
        try:
            entries = json.loads(mods_json.read_text(errors="replace"))
        except ValueError:
            return
        if isinstance(entries, list) and not any(e.get("mod_name") == MOD for e in entries
                                                 if isinstance(e, dict)):
            entries.insert(0, {"mod_name": MOD, "mod_enabled": True})
            mods_json.write_text(json.dumps(entries, indent=4) + "\n", encoding="ascii")
            step(f"enabled {MOD} in mods.json")


# --- the Lua mod ---------------------------------------------------------------------------

def _changed(src: Path, dst: Path):
    try:
        s, d = src.stat(), dst.stat()
        return s.st_size != d.st_size or int(s.st_mtime) > int(d.st_mtime)
    except OSError:
        return True


def sync_mod(mod_src: Path, mod_dst: Path, include_dev: bool):
    """Mirror mod_src into mod_dst: copy changed files, prune stale ones. Scripts/dev (the RE
    dumper, remote exec channel, ritual dev kit) only ship when include_dev - player installs
    get no dev tools; main.lua skips missing dev modules silently. dump/ (RE dumps + the live
    exec channel) and config/ (the user's config.json overlay) are never pruned, and save/ is
    the player's persistent state."""
    copied = pruned = 0
    src_files = set()
    for f in mod_src.rglob("*"):
        if f.is_dir() or "__pycache__" in f.parts:
            continue
        rel = f.relative_to(mod_src)
        if not include_dev and rel.parts[:2] == ("Scripts", "dev"):
            continue
        if rel.parts[0] == "save" and rel.name != ".gitkeep":  # never ship local saves
            continue
        src_files.add(rel)
        dst = mod_dst / rel
        if _changed(f, dst):
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
            copied += 1
    for f in list(mod_dst.rglob("*")):
        if f.is_dir():
            continue
        rel = f.relative_to(mod_dst)
        if rel.parts[0] not in ("dump", "config", "save") and rel not in src_files:
            f.unlink()
            pruned += 1
    (mod_dst / "dump").mkdir(exist_ok=True)  # wand.lua io.open()s its crash log into it
    return copied, pruned


def find_mod_src():
    # repo layout first, then the release-zip layout.
    for c in (ROOT / "mod" / MOD, ROOT / "ue4ss" / "Mods" / MOD, ROOT / MOD):
        if (c / "Scripts" / "main.lua").is_file():
            return c
    fail(f"Could not find the mod source (Scripts/main.lua) under {ROOT}")


# --- the content pak (wands, the two books, research card) ---------------------------------

def find_pak_triple():
    """paks/ is the one canonical home. It used to also fall back to the pak-build toolchain's
    output folder, which meant an install silently depended on a 2 GB developer tree being
    present - and produced a half-working mod on any machine without it."""
    c = ROOT / "paks" / PAK
    if all(c.with_suffix(ext).is_file() for ext in (".utoc", ".ucas", ".pak")):
        return c
    return None


def install_pak(game_dir: Path):
    triple = find_pak_triple()
    if not triple:
        # Refuse rather than warn. Half the mod's items live in this pak - the wands, the Tempest
        # Codex and its research card, the Diamond Fishing Rod, the Sorting Chest, the gold
        # fishing drops - and a mod installed without them looks broken rather than reduced.
        # Game-derived cooked data, so it is not committed to the public repo: it ships in the
        # release zip, or you build it yourself from an extracted copy of the game's assets.
        fail(f"No content pak in {ROOT / 'paks'}.\n"
             f"Expected {PAK}.utoc / .ucas / .pak there.\n\n"
             "The release zip ships it. From a git clone, build it with\n"
             "  python tools/pakkit/build_wand_pak.py\n"
             "and copy out/z_SolarpunkWand_P.* into paks/ under the name above.\n\n"
             "To install the Lua mod anyway, knowing the wands, both books, the Diamond\n"
             "Fishing Rod and the Sorting Chest will all be missing:  --skip-pak")
    paks = game_dir / "Content" / "Paks"
    paks.mkdir(parents=True, exist_ok=True)
    fresh = [ext for ext in (".utoc", ".ucas", ".pak")
             if _changed(triple.with_suffix(ext), paks / (PAK + ext))]
    for ext in fresh:
        shutil.copy2(triple.with_suffix(ext), paks / (PAK + ext))
    step(f"content pak {'installed' if fresh else 'already up to date'} -> {paks / PAK}.*")


# --- Visual C++ runtime (Windows) ----------------------------------------------------------

def have_vc_runtime():
    import winreg
    for key in (r"SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64",
                r"SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as k:
                if winreg.QueryValueEx(k, "Installed")[0] == 1:
                    return True
        except OSError:
            pass
    return (Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "vcruntime140_1.dll").is_file()


def ensure_vc_runtime(win64: Path = None):
    """UE4SS links against the VC++ 2015-2022 x64 runtime. Three ways it can be satisfied, in
    order of preference: already installed machine-wide (most machines), the app-local copies
    the vendored payload drops next to the game exe, or - only if both of those fail - fetching
    Microsoft's installer. That last branch is the sole network access anywhere in the install
    and should now be unreachable in practice; it stays as a safety net for a payload built with
    tools/make_ue4ss_runtime.py --no-vcruntime."""
    if have_vc_runtime():
        step("Visual C++ runtime present")
        return
    if win64 and (win64 / "vcruntime140_1.dll").is_file():
        step("Visual C++ runtime supplied app-local (bundled next to the game exe)")
        return
    url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
    import ctypes
    import tempfile
    import time
    import urllib.request
    vc = Path(tempfile.gettempdir()) / "vc_redist.x64.exe"
    try:
        step("installing the Visual C++ 2015-2022 x64 runtime (accept the UAC prompt)...")
        urllib.request.urlretrieve(url, vc)
        # ShellExecuteW with the 'runas' verb is the UAC elevation prompt; > 32 means launched.
        rc = ctypes.windll.shell32.ShellExecuteW(None, "runas", str(vc),
                                                 "/install /quiet /norestart", None, 1)
        if rc <= 32:
            raise OSError(f"ShellExecuteW returned {rc}")
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if have_vc_runtime():
                step("Visual C++ runtime installed")
                return
            time.sleep(2)
        warn("the runtime installer is still running (or was cancelled) - if UE4SS fails to")
        warn(f"load, install it manually from {url}")
    except Exception:
        warn("could not install the Visual C++ runtime automatically")
        warn(f"if UE4SS fails to load, install it from {url}")
    finally:
        try:
            vc.unlink()
        except OSError:
            pass


# --- Proton bits Steam has to do, not the filesystem (Linux) -------------------------------

def proton_notes(run_vcrun: bool):
    pfx = next((lib / "steamapps" / "compatdata" / str(APP_ID) / "pfx"
                for lib in steam_libraries()
                if (lib / "steamapps" / "compatdata" / str(APP_ID) / "pfx").is_dir()), None)
    pt = None
    if shutil.which("protontricks"):
        pt = ["protontricks"]
    elif shutil.which("flatpak") and subprocess.run(
            ["flatpak", "info", "com.github.Matoking.protontricks"],
            capture_output=True).returncode == 0:
        pt = ["flatpak", "run", "com.github.Matoking.protontricks"]

    say()
    say("Two Proton steps remain (Steam settings, not files):")
    say("  1) Launch option - Steam > Solarpunk > Properties > General > Launch Options:")
    say('         WINEDLLOVERRIDES="dwmapi=n,b" %command%')
    say("     (so Wine loads UE4SS's proxy dwmapi.dll; n,b = native first, builtin fallback)")
    pt_str = " ".join(pt) if pt else "protontricks"
    if run_vcrun and pfx and pt:
        say("  2) MSVC runtime - installing vcrun2022 into the prefix via protontricks (can take a minute)...")
        if subprocess.run(pt + [str(APP_ID), "vcrun2022"]).returncode == 0:
            step("vcrun2022 installed into the Proton prefix")
        else:
            warn(f"protontricks failed - run it yourself: {pt_str} {APP_ID} vcrun2022")
    else:
        say(f"  2) MSVC runtime - UE4SS links against it; install it into the prefix"
            f"{'' if run_vcrun else ' (re-run with --vcrun to do this automatically)'}:")
        say(f"         {pt_str} {APP_ID} vcrun2022")
        if not pt:
            say("     (no protontricks found - Steam Deck: flatpak install com.github.Matoking.protontricks)")
        if not pfx:
            say(f"     (launch the game once first so Proton creates its prefix under compatdata/{APP_ID})")


# --- top-level flows -----------------------------------------------------------------------

def deploy(game_dir: Path, force=False, skip_pak=False, include_dev=False):
    """The whole install, shared by players (include_dev=False) and tools/run.py (True)."""
    win64 = game_dir / "Binaries" / "Win64"
    ue4ss = win64 / "ue4ss"

    # The game ships its own .pdb next to the exe, which is how UE4SS resolves symbols on
    # this build. Verifying game files in Steam restores it if something stripped it.
    if not (win64 / EXE).with_suffix(".pdb").is_file():
        warn(f"{Path(EXE).with_suffix('.pdb')} is missing from Binaries/Win64 - UE4SS may fail to")
        warn("resolve symbols. Steam > Solarpunk > Properties > Installed Files > Verify integrity.")

    if force or not (win64 / "dwmapi.dll").is_file() or not ue4ss.is_dir():
        install_ue4ss(win64)
    else:
        step("UE4SS already installed (--force to reinstall)")
    ensure_ini(ue4ss)

    copied, pruned = sync_mod(find_mod_src(), ue4ss / "Mods" / MOD, include_dev)
    step(f"mod synced -> {ue4ss / 'Mods' / MOD} ({copied} copied, {pruned} pruned"
         f"{', dev tools included' if include_dev else ', no dev tools'})")
    ensure_mod_lists(ue4ss)

    if skip_pak:
        step("skipped the content pak (--skip-pak) - no wand/codex items")
    else:
        install_pak(game_dir)


def _rm(path: Path, count):
    """Remove one file or one directory tree, reporting it. Everything the uninstallers touch
    goes through here and every caller names an exact path - nothing globs, nothing recurses
    into the game's own files."""
    try:
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
        else:
            return count
    except OSError as e:
        warn(f"could not remove {path}: {e}")
        return count
    step(f"removed {path}")
    return count + 1


def _remove_mod(game_dir: Path, count=0):
    count = _rm(game_dir / "Binaries" / "Win64" / "ue4ss" / "Mods" / MOD, count)
    for ext in (".utoc", ".ucas", ".pak"):
        count = _rm(game_dir / "Content" / "Paks" / (PAK + ext), count)
    return count


def uninstall(game_dir: Path):
    win64 = game_dir / "Binaries" / "Win64"
    _remove_mod(game_dir)
    say()
    say("Mod removed. UE4SS itself was left in place (other mods may use it);")
    say("to remove that too:  python install.py --purge")


def purge(game_dir: Path):
    """Everything this installer has ever written, gone - so a reinstall starts from nothing.

    Strictly an allow-list of paths we create. The game's own files live in the same folders
    (Solarpunk-Windows_0_P.*, global.u*, the exe and its .pdb, tbb*.dll, D3D12/, DML/) and must
    survive untouched; a purge that took the folder would cost a full Steam redownload."""
    win64 = game_dir / "Binaries" / "Win64"
    n = _remove_mod(game_dir)
    n = _rm(win64 / "ue4ss", n)
    n = _rm(win64 / "dwmapi.dll", n)
    # Only the runtime DLLs THIS payload would have installed. A game that ships its own copy of
    # msvcp140.dll next to its exe is not unheard of, and purging one we never placed would break
    # the vanilla game - so ask the vendored zip what it actually carries.
    for dll in vendored_names() & set(VCRUNTIME_DLLS):
        n = _rm(win64 / dll, n)

    # A bad --game-dir (or a hand copy) can leave a mod tree one level too deep, at
    # <game>/Solarpunk/Binaries/Win64/ue4ss. UE4SS never loads it - there is no dwmapi.dll
    # beside a game exe there - so it is pure litter. Only ever remove a folder that has no
    # game exe of its own, so this can never eat a real second install.
    nested = game_dir / "Solarpunk"
    if (nested / "Binaries" / "Win64").is_dir() and not (nested / "Binaries" / "Win64" / EXE).is_file():
        n = _rm(nested, n)

    n = _rm(GAMEDIR_CACHE, n)  # so the next install exercises Steam auto-detection for real

    say()
    say(f"Purged - {n} item{'' if n == 1 else 's'} removed. The game itself is untouched.")
    say("Saved games are not ours to delete; they live outside the game folder")
    say(r"(Windows: %LOCALAPPDATA%\Solarpunk\Saved\SaveGames).")


def status(game_dir: Path):
    """Report what is installed without changing anything - the way to check a clean slate
    before a fresh install, and to confirm the fresh install afterwards."""
    win64 = game_dir / "Binaries" / "Win64"
    ue4ss = win64 / "ue4ss"
    mod_dst = ue4ss / "Mods" / MOD

    def mark(ok):
        return "yes" if ok else "no "

    say(f"  UE4SS core        {mark((win64 / 'dwmapi.dll').is_file() and ue4ss.is_dir())}"
        f"  ({win64 / 'dwmapi.dll'})")
    say(f"  VC++ runtime      {mark(have_vc_runtime() or (win64 / 'vcruntime140_1.dll').is_file())}"
        f"  ({'machine-wide' if have_vc_runtime() else 'app-local' if (win64 / 'vcruntime140_1.dll').is_file() else 'MISSING'})")

    if mod_dst.is_dir():
        # Count Scripts/, not the whole folder: dump/, config/ and save/ are the player's own
        # state and would make the number drift for reasons that say nothing about the install.
        # And count dev FILES, not the dev folder - sync_mod prunes stale files but never removes
        # the directory they were in, so an install with every dev tool pruned still has an empty
        # Scripts/dev/ sitting there. Testing is_dir() here reported "dev tools: yes" on a clean
        # player install (caught live).
        scripts = mod_dst / "Scripts"
        n = sum(1 for f in scripts.rglob("*") if f.is_file()) if scripts.is_dir() else 0
        dev_dir = scripts / "dev"
        dev = sum(1 for f in dev_dir.rglob("*") if f.is_file()) if dev_dir.is_dir() else 0
        say(f"  {MOD:<17} yes  ({n} script files, dev tools: {'yes (%d)' % dev if dev else 'no'})")
    else:
        say(f"  {MOD:<17} no")

    triple = [game_dir / "Content" / "Paks" / (PAK + e) for e in (".utoc", ".ucas", ".pak")]
    if all(f.is_file() for f in triple):
        say(f"  content pak       yes  ({sum(f.stat().st_size for f in triple) / 1e6:.1f} MB, {PAK}.*)")
    else:
        say(f"  content pak       {mark(False)} ({PAK}.* not in Content/Paks)")

    src = ROOT / "paks" / PAK
    say(f"  pak source ready  {mark(find_pak_triple() is not None)}  ({src}.*)")

    # UE4SS.log is written without line breaks - the whole file is one enormous line, so
    # splitlines() is useless on it. Pick the startup banner out by its timestamp instead.
    log = ue4ss / "UE4SS.log"
    if log.is_file():
        # timestamp, then the [Lua] [SolarpunkSurvival] [INF] tag run, then the banner
        hits = re.findall(rf"\[([\d\-]+ [\d:.]+)\](?:\s*\[[^\]]*\])*\s*{MOD} v([\d.]+) starting",
                          log.read_text(errors="replace"))
        if hits:
            when, ver = hits[-1]
            say(f"  last loaded       v{ver} at {when}")
        else:
            say("  last loaded       (no startup line in UE4SS.log yet)")


def main():
    # Before anything else: a version this old cannot run the rest of the file, and the failure
    # a player would otherwise see is a traceback about syntax.
    if sys.version_info < (3, 8):
        sys.exit("This installer needs Python 3.8 or newer (you have %d.%d).\n"
                 "Windows: get it from https://www.python.org/downloads/ or the Microsoft Store."
                 % sys.version_info[:2])

    ap = argparse.ArgumentParser(
        description="Install the Solarpunk Survival mod (everything is bundled - no downloads).")
    ap.add_argument("--game-dir", metavar="PATH", help="skip auto-detection")
    ap.add_argument("--skip-pak", action="store_true", help="don't touch Content/Paks")
    ap.add_argument("--no-vcredist", action="store_true", help="skip the Visual C++ runtime check (Windows)")
    ap.add_argument("--vcrun", action="store_true", help="Linux: run protontricks vcrun2022 now")
    ap.add_argument("--force", action="store_true", help="reinstall the UE4SS core even if present")
    ap.add_argument("--status", action="store_true", help="report what is installed, change nothing")
    ap.add_argument("--uninstall", action="store_true", help="remove the mod + content pak")
    ap.add_argument("--purge", action="store_true", help="remove the mod, the pak AND UE4SS itself")
    args = ap.parse_args()

    game_dir = get_game_dir(args.game_dir)
    say(f"Game:  {game_dir}")

    if args.status:
        status(game_dir)
        return

    # The game holds its paks and dwmapi.dll open - nothing can be replaced while it runs.
    if game_running():
        fail("Solarpunk is running - quit the game first (its pak/DLL files are locked while it runs).")

    if args.purge:
        purge(game_dir)
        return
    if args.uninstall:
        uninstall(game_dir)
        return

    deploy(game_dir, force=args.force, skip_pak=args.skip_pak, include_dev=False)
    # After deploy, not before: the bundled runtime DLLs land during the UE4SS extraction, and
    # checking first would send a machine that is already covered off to download an installer.
    if IS_WIN and not args.no_vcredist:
        ensure_vc_runtime(game_dir / "Binaries" / "Win64")
    if not IS_WIN:
        proton_notes(args.vcrun)

    try:
        version = json.loads((ROOT / "manifest.json").read_text())["modVersion"]
    except (OSError, ValueError, KeyError):
        version = "X.Y.Z"
    say()
    say("Done. Launch Solarpunk - Binaries/Win64/ue4ss/UE4SS.log should log")
    say(f'"{MOD} v{version} starting". Every player in a co-op session needs this same install.')


if __name__ == "__main__":
    main()
