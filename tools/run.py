#!/usr/bin/env python3
"""Deploy the latest mod, launch Solarpunk, and confirm the mod loaded.

The "run the app" entrypoint for the game+mod (Claude's /run uses it via
.claude/skills/launch-solarpunk). Cross-platform: Windows native, Linux/Steam Deck via Proton.

    python tools/run.py [--no-install] [--full] [--wait N] [--game-dir PATH]

Flow: stop any running instance (a fresh UE4SS injection needs a clean launch, and the locked
DLL/paks cannot be overwritten while the game runs) -> deploy -> launch via Steam -> tail
ue4ss/UE4SS.log until the mod logs "SolarpunkSurvival vX.Y.Z starting".

Deploy is a fast dev sync (changed files only, stale files pruned) when UE4SS is already
installed; the full installer (install.ps1 / install.sh) runs automatically when it is not,
or on --full. --no-install relaunches without touching the install at all.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

APP_ID = 1805110
EXE = "SolarpunkSteam-Win64-Shipping.exe"
PAK = "Solarpunk-Windows_1_P"  # mount order 204 - ABOVE the game's own _0_P (104)
MOD = "SolarpunkSurvival"
READY_RE = re.compile(r"SolarpunkSurvival v[\d.]+ starting")
REPO = Path(__file__).resolve().parent.parent
GAMEDIR_CACHE = Path(__file__).resolve().parent / ".gamedir"
IS_WIN = os.name == "nt"


def say(msg=""):
    print(msg, flush=True)


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
        try:
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
        except ImportError:
            pass
        roots.append(r"C:\Program Files (x86)\Steam")
    else:
        home = Path.home()
        roots += [home / ".local/share/Steam", home / ".steam/steam",
                  home / ".var/app/com.valvesoftware.Steam/.local/share/Steam"]
    return [Path(str(r).replace("/", os.sep)) for r in roots]


def find_game_dir():
    libs = []
    for root in steam_roots():
        libs.append(root)
        vdf = root / "steamapps" / "libraryfolders.vdf"
        if vdf.is_file():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors="replace")):
                libs.append(Path(m.group(1).replace("\\\\", "\\")))
    seen = set()
    for lib in libs:
        key = str(lib).lower()
        if key in seen:
            continue
        seen.add(key)
        hit = resolve_game_dir(lib / "steamapps" / "common" / "Solarpunk")
        if hit:
            return hit
    return None


def get_game_dir(cli_dir):
    if cli_dir:
        game = resolve_game_dir(cli_dir)
        if not game:
            sys.exit(f"No {EXE} under '{cli_dir}' - pass --game-dir with the folder that contains Binaries/Win64.")
        return game
    if GAMEDIR_CACHE.is_file():  # detection result from a previous run
        game = resolve_game_dir(GAMEDIR_CACHE.read_text().strip())
        if game:
            return game
    game = find_game_dir()
    if not game:
        sys.exit('Could not find Solarpunk automatically. Re-run with --game-dir "<.../steamapps/common/Solarpunk/Solarpunk>"')
    GAMEDIR_CACHE.write_text(str(game))
    return game


# --- process control -----------------------------------------------------------------------

def game_running():
    if IS_WIN:
        out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {EXE}", "/NH"],
                             capture_output=True, text=True).stdout
        return EXE.lower() in out.lower()
    return subprocess.run(["pgrep", "-f", EXE], capture_output=True).returncode == 0


def stop_game():
    if not game_running():
        return
    say("Stopping the running game (a clean launch is needed to inject the fresh mod)...")
    if IS_WIN:
        subprocess.run(["taskkill", "/F", "/IM", EXE], capture_output=True)
    else:
        subprocess.run(["pkill", "-f", EXE], capture_output=True)
    deadline = time.monotonic() + 10
    while game_running() and time.monotonic() < deadline:
        time.sleep(0.5)
    time.sleep(1)  # let the OS release dwmapi.dll / the pak file handles


# --- deploy --------------------------------------------------------------------------------

def run_full_installer(game_dir):
    say("Running the full installer...")
    if IS_WIN:
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", str(REPO / "install.ps1"), "-GameDir", str(game_dir)]
    else:
        cmd = ["bash", str(REPO / "install.sh"), "--game-dir", str(game_dir)]
    if subprocess.run(cmd).returncode:
        sys.exit("installer failed (see output above)")


def changed(src: Path, dst: Path):
    try:
        s, d = src.stat(), dst.stat()
        return s.st_size != d.st_size or int(s.st_mtime) > int(d.st_mtime)
    except OSError:
        return True


def sync_mod(mod_src: Path, mod_dst: Path):
    """Mirror mod_src into mod_dst: copy changed files, prune stale ones. dump/ (RE dumps +
    the live exec channel) and config/ (the user's config.json overlay) are never pruned."""
    copied = pruned = 0
    src_files = set()
    for f in mod_src.rglob("*"):
        if f.is_dir() or "__pycache__" in f.parts:
            continue
        rel = f.relative_to(mod_src)
        src_files.add(rel)
        dst = mod_dst / rel
        if changed(f, dst):
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dst)
            copied += 1
    for f in list(mod_dst.rglob("*")):
        if f.is_dir():
            continue
        rel = f.relative_to(mod_dst)
        if rel.parts[0] not in ("dump", "config") and rel not in src_files:
            f.unlink()
            pruned += 1
    (mod_dst / "dump").mkdir(exist_ok=True)  # dev/recapture.lua io.open()s into it
    return copied, pruned


def ensure_mods_txt(ue4ss: Path):
    mods_txt = ue4ss / "Mods" / "mods.txt"
    if not mods_txt.is_file():
        return
    lines = mods_txt.read_text(errors="replace").splitlines()
    if any(re.match(rf"^\s*{MOD}\s*:", l) for l in lines):
        return
    out, done = [], False
    for l in lines:
        if not done and re.match(r"^\s*Keybinds\s*:", l):
            out.append(f"{MOD} : 1")
            done = True
        out.append(l)
    if not done:
        out.append(f"{MOD} : 1")
    mods_txt.write_text("\n".join(out) + "\n", encoding="ascii")
    say(f"  enabled {MOD} in mods.txt")


def ensure_ini(ue4ss: Path):
    """Console on, engine pinned to 5.7, AOB scan budget raised - rewrite only when wrong."""
    ini = ue4ss / "UE4SS-settings.ini"
    if not ini.is_file():
        return
    want = {"ConsoleEnabled": "1", "GuiConsoleEnabled": "1", "GuiConsoleVisible": "1",
            "MajorVersion": "5", "MinorVersion": "7", "SecondsToScanBeforeGivingUp": "120"}
    txt = new = ini.read_text(errors="replace")
    for key, val in want.items():
        new = re.sub(rf"(?m)^{key}\s*=.*$", f"{key} = {val}", new)
    if new != txt:
        ini.write_text(new, encoding="ascii")
        say("  UE4SS console enabled, engine version pinned to 5.7")


def deploy(game_dir: Path, full: bool):
    win64 = game_dir / "Binaries" / "Win64"
    ue4ss = win64 / "ue4ss"
    if full or not (win64 / "dwmapi.dll").is_file() or not (ue4ss / "Mods").is_dir():
        run_full_installer(game_dir)
        return

    # fast dev path: UE4SS is in place, just sync our own files
    mod_src = REPO / "mod" / MOD
    if not (mod_src / "Scripts" / "main.lua").is_file():
        sys.exit(f"Could not find the mod source (Scripts/main.lua) under {mod_src}")
    copied, pruned = sync_mod(mod_src, ue4ss / "Mods" / MOD)
    say(f"  mod synced ({copied} copied, {pruned} pruned)")
    ensure_mods_txt(ue4ss)
    ensure_ini(ue4ss)

    triple = next((c for c in (REPO / "paks" / PAK,
                               REPO / "paks" / "z_SolarpunkWand_P",
                               REPO / "tools" / "pakkit" / "out" / "z_SolarpunkWand_P")
                   if all(c.with_suffix(ext).is_file() for ext in (".utoc", ".ucas", ".pak"))), None)
    if triple:
        paks = game_dir / "Content" / "Paks"
        paks.mkdir(parents=True, exist_ok=True)
        fresh = [ext for ext in (".utoc", ".ucas", ".pak")
                 if changed(triple.with_suffix(ext), paks / (PAK + ext))]
        for ext in fresh:
            shutil.copy2(triple.with_suffix(ext), paks / (PAK + ext))
        say(f"  content pak {'updated' if fresh else 'unchanged'}")
    else:
        say("  ! no content pak found - wands/codex will be missing (python tools/pakkit/build_wand_pak.py)")


# --- launch + wait -------------------------------------------------------------------------

def launch():
    url = f"steam://rungameid/{APP_ID}"
    say(f"Launching Solarpunk (app {APP_ID})...")
    if IS_WIN:
        os.startfile(url)  # noqa - Windows only
        return
    for cmd in (["steam", url],
                ["flatpak", "run", "com.valvesoftware.Steam", url],
                ["xdg-open", url]):
        if shutil.which(cmd[0]):
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
    say("! Could not find steam / flatpak / xdg-open to launch. Start Solarpunk from Steam yourself.")


def wait_for_mod(log: Path, wait_s: int):
    """Poll the UE4SS log for the mod's startup line. Fail fast if the game process appears
    and then dies without the mod loading (crash), instead of burning the whole timeout."""
    started = time.monotonic()
    deadline = started + wait_s
    seen_proc = False
    gone_checks = 0
    tick = 0
    while time.monotonic() < deadline:
        time.sleep(1)
        if log.is_file() and READY_RE.search(log.read_text(errors="replace")):
            return True, time.monotonic() - started
        tick += 1
        if tick % 3 == 0:  # process check is a subprocess spawn - keep it at 1/3 the rate
            if game_running():
                seen_proc, gone_checks = True, 0
            elif seen_proc:
                gone_checks += 1
                if gone_checks >= 2:
                    say("! The game process exited before the mod loaded (crash?).")
                    break
    return False, time.monotonic() - started


def report(log: Path, ready: bool, elapsed: float, wait_s: int):
    say()
    if ready:
        say(f"Mod loaded ({elapsed:.0f}s). Recent {MOD} log:")
        lines = [l for l in log.read_text(errors="replace").splitlines() if MOD in l]
        for l in lines[-15:]:
            say(f"  {l}")
        say()
        say("Load a save (the menu has no pawn, so most features need a world), then press P for a storm.")
        return 0
    say(f"! Did not see \"SolarpunkSurvival vX.Y.Z starting\" within {wait_s}s.")
    say(f"! Check the UE4SS console window, or the log at: {log}")
    say("! If UE4SS did not inject at all, confirm the Solarpunk-patched UE4SS is installed (install --force),")
    say('! and on Linux the Proton launch option WINEDLLOVERRIDES="dwmapi=n,b" %command% + vcrun2022 (docs/INSTALL.md).')
    if log.is_file():
        say("--- last 20 lines of UE4SS.log ---")
        for l in log.read_text(errors="replace").splitlines()[-20:]:
            say(f"  {l}")
    return 1


def main():
    ap = argparse.ArgumentParser(description="Deploy the mod, launch Solarpunk, confirm it loaded.")
    ap.add_argument("--no-install", action="store_true", help="relaunch without redeploying")
    ap.add_argument("--full", action="store_true", help="run the full installer instead of the fast dev sync")
    ap.add_argument("--wait", type=int, default=120, metavar="N", help="seconds to wait for the mod (default 120)")
    ap.add_argument("--game-dir", metavar="PATH", help="skip auto-detection")
    args = ap.parse_args()

    game_dir = get_game_dir(args.game_dir)
    say(f"Game:  {game_dir}")
    stop_game()
    if not args.no_install:
        deploy(game_dir, args.full)

    log = game_dir / "Binaries" / "Win64" / "ue4ss" / "UE4SS.log"
    log.unlink(missing_ok=True)
    launch()
    ready, elapsed = wait_for_mod(log, args.wait)
    sys.exit(report(log, ready, elapsed, args.wait))


if __name__ == "__main__":
    main()
