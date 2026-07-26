#!/usr/bin/env python3
"""Dev tool: launch Solarpunk, wait for UE4SS output (log + any re_capture.txt), copy it
into dumps/<timestamp>/ (git-ignored), then stop the game.

    python tools/capture_dump.py [--wait N] [--game-dir PATH]
"""

import argparse
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import install as inst  # noqa: E402 - game detection / process control live there

REPO = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser(description="Capture UE4SS.log + re_capture.txt into dumps/.")
    ap.add_argument("--wait", type=int, default=90, metavar="N", help="seconds to wait (default 90)")
    ap.add_argument("--game-dir", metavar="PATH", help="skip auto-detection")
    args = ap.parse_args()

    game_dir = inst.get_game_dir(args.game_dir)
    win64 = game_dir / "Binaries" / "Win64"
    log = win64 / "ue4ss" / "UE4SS.log"
    re_file = win64 / "ue4ss" / "Mods" / inst.MOD / "dump" / "re_capture.txt"
    out = REPO / "dumps" / datetime.now().strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)

    for f in (log, re_file):
        f.unlink(missing_ok=True)

    print(f"Launching Solarpunk (app {inst.APP_ID})...")
    import os
    os.startfile(f"steam://rungameid/{inst.APP_ID}")  # noqa - dev tool, Windows only

    deadline = time.monotonic() + args.wait
    saw_log = False
    while time.monotonic() < deadline:
        time.sleep(5)
        if not saw_log and log.is_file():
            saw_log = True
            print("UE4SS.log appeared (injection OK).")
        if re_file.is_file():
            print("re_capture.txt found.")
            break
        if saw_log and not inst.game_running():
            print("Game exited.")
            break

    for f in (log, re_file):
        if f.is_file():
            shutil.copy2(f, out)
    subprocess.run(["taskkill", "/F", "/IM", inst.EXE], capture_output=True)

    if not saw_log:
        print("WARNING: no UE4SS.log was produced - UE4SS may not have injected. Try: python tools/run.py --force")
    print(f"Artifacts in: {out}")
    for f in sorted(out.iterdir()):
        print(f"  {f.name}  {f.stat().st_size}")


if __name__ == "__main__":
    main()
