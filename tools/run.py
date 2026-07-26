#!/usr/bin/env python3
"""Deploy the latest mod, launch Solarpunk, and confirm the mod loaded.

The "run the app" entrypoint for the game+mod (Claude's /run uses it via
.claude/skills/launch-solarpunk). Cross-platform: Windows native, Linux/Steam Deck via Proton.

    python tools/run.py [--no-install] [--force] [--wait N] [--game-dir PATH]

Flow: stop any running instance (a fresh UE4SS injection needs a clean launch, and the locked
DLL/paks cannot be overwritten while the game runs) -> deploy -> launch via Steam -> tail
ue4ss/UE4SS.log until the mod logs "SolarpunkSurvival vX.Y.Z starting".

All install logic lives in install.py (the player installer) and is imported from there -
this script only adds: kill-then-relaunch, dev tools in the sync (Scripts/dev, which player
installs never get), and the log tail. Everything is bundled - the UE4SS runtime extracts
from vendor/, so a fresh machine needs nothing beyond Steam+game+Python.
--no-install relaunches without touching the install at all.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import install as inst  # noqa: E402 - the repo-root installer doubles as a library

APP_ID = inst.APP_ID
MOD = inst.MOD
IS_WIN = inst.IS_WIN
READY_RE = re.compile(rf"{MOD} v[\d.]+ starting")


def say(msg=""):
    print(msg, flush=True)


def stop_game():
    if not inst.game_running():
        return
    say("Stopping the running game (a clean launch is needed to inject the fresh mod)...")
    if IS_WIN:
        subprocess.run(["taskkill", "/F", "/IM", inst.EXE], capture_output=True)
    else:
        subprocess.run(["pkill", "-f", inst.EXE], capture_output=True)
    deadline = time.monotonic() + 10
    while inst.game_running() and time.monotonic() < deadline:
        time.sleep(0.5)
    time.sleep(1)  # let the OS release dwmapi.dll / the pak file handles


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
            if inst.game_running():
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
    say(f'! Did not see "{MOD} vX.Y.Z starting" within {wait_s}s.')
    say(f"! Check the log at: {log}")
    say("! If UE4SS did not inject at all, re-run with --force to reinstall the UE4SS core,")
    say('! and on Linux confirm the Proton launch option WINEDLLOVERRIDES="dwmapi=n,b" %command% + vcrun2022 (docs/INSTALL.md).')
    if log.is_file():
        say("--- last 20 lines of UE4SS.log ---")
        for l in log.read_text(errors="replace").splitlines()[-20:]:
            say(f"  {l}")
    return 1


def main():
    ap = argparse.ArgumentParser(description="Deploy the mod, launch Solarpunk, confirm it loaded.")
    ap.add_argument("--no-install", action="store_true", help="relaunch without redeploying")
    ap.add_argument("--force", action="store_true", help="reinstall the UE4SS core even if it is already there")
    ap.add_argument("--wait", type=int, default=120, metavar="N", help="seconds to wait for the mod (default 120)")
    ap.add_argument("--game-dir", metavar="PATH", help="skip auto-detection")
    args = ap.parse_args()

    game_dir = inst.get_game_dir(args.game_dir)
    say(f"Game:  {game_dir}")
    stop_game()
    if not args.no_install:
        inst.deploy(game_dir, force=args.force, include_dev=True)

    log = game_dir / "Binaries" / "Win64" / "ue4ss" / "UE4SS.log"
    log.unlink(missing_ok=True)
    launch()
    ready, elapsed = wait_for_mod(log, args.wait)
    sys.exit(report(log, ready, elapsed, args.wait))


if __name__ == "__main__":
    main()
