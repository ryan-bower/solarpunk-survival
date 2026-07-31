#!/usr/bin/env python3
"""Two-instance same-machine MP test rig (2026-07-31).

Drives TWO copies of Solarpunk on one PC so a modded client can join a modded
host over 127.0.0.1 -- no second human, no second Steam account. The recipe
below is the one that ACTUALLY WORKED end-to-end on 2026-07-31 (full session:
host+client in one world, crouch replicated, ship props attached both sides):

  * Instance 1 = the real Steam install; instance 2 = a plain folder copy of
    the game root (robocopy to dump/game2 -- 3 seconds, mod + UE4SS ride
    along). steam_appid.txt (1805110) beside each exe lets a direct exe launch
    skip RestartAppIfNecessary. Direct launches are UNELEVATED (killable).
  * Launch BOTH instances with --nosteam. This is load-bearing twice over:
    with Steam up, the SteamSockets plugin registers itself as the DEFAULT
    socket subsystem, and even a forced IpNetDriver then fails InitBindSockets
    (its fake sockets reject SO_BROADCAST). And the per-connection
    PacketHandler stack must MATCH on both ends: one side -nosteam and the
    other side merely steam-init-failed load different component stacks ->
    ZeroLastByte/ReadHeaderFail fault disconnects.
  * A user-layer Engine.ini override (ClearArray + NetDriverDefinitions) does
    NOT work -- proven inert on this build; the packaged SteamSockets def wins
    (only e.g. [SystemSettings] CVars apply from that file). Instead rewrite
    the LIVE UEngine::NetDriverDefinitions array via the exec channel at the
    menu (netrig_steps/nd_fix.lua): GameNetDriver ->
    /Script/OnlineSubsystemUtils.IpNetDriver. Struct-array writes from Lua
    work on this build.
  * Host: click the main menu's "keep playing" trampoline
    (netrig_steps/menu_continue.lua; NOTE with -nosteam it starts a FRESH
    world -- no Steam user, no save discovery), then travel with
    "open /Game/Maps/MainLevel?Name=Player?listen" via
    KismetSystemLibrary.ExecuteConsoleCommand (netrig_steps/relisten.lua).
    The pause menu's Host button needs a Steam session -- skip it. Success
    line in Solarpunk.log: "IpNetDriver listening on port 7777".
  * Client: at its menu run nd_fix.lua too, then
    GameplayStatics.OpenLevel(pc, "127.0.0.1:7777") (netrig_steps/join.lua).
    Success: "Welcomed by server". Both instances share the AppData Saved
    dir; the second process logs to Solarpunk_2.log.
  * Menu / host / join are driven through the mod's dev exec channel
    (dump/cmd.txt -> dump/exec.lua -> dump/result.txt inside each install's
    mod folder), so nobody has to touch the keyboard. UE4SS.log is
    exclusively locked while its game runs -- probe liveness via the channel,
    read logs after shutdown.

Usage:
  python tools/netrig.py ps
  python tools/netrig.py launch 1            (add --nosteam for instance 2 fallback)
  python tools/netrig.py exec 1 rig/step.lua [--timeout 25]
  python tools/netrig.py cmd 1 "sig Crouch"
  python tools/netrig.py tail 1|2|game [lines]
  python tools/netrig.py kill

The exec subcommand copies the given Lua file into that install's
dump/exec.lua, triggers it, and prints result.txt. The Lua runs with
`ctx`, `emit`, `print` in scope on the GAME THREAD (see dev/remote.lua).
"""
import argparse
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
import install  # noqa: E402  (repo-root module)

EXE_NAME = "SolarpunkSteam-Win64-Shipping.exe"
GAME2 = REPO / "dump" / "game2" / "Solarpunk"
PIDFILE = REPO / "dump" / "netrig_pids.txt"
LAUNCH_ARGS = ["-windowed", "-ResX=1280", "-ResY=720", "-nosound", "-NOSPLASH"]
SHARED_LOG_DIR = Path.home() / "AppData" / "Local" / "Solarpunk" / "Saved" / "Logs"


def game_dir(n: int) -> Path:
    if n == 1:
        d = install.get_game_dir()
        if not d:
            sys.exit("instance 1: real install not found")
        return Path(d)
    if not (GAME2 / "Binaries" / "Win64" / EXE_NAME).is_file():
        sys.exit(f"instance 2: no exe under {GAME2} (copy the game folder first)")
    return GAME2


def mod_root(n: int) -> Path:
    return game_dir(n) / "Binaries" / "Win64" / "ue4ss" / "Mods" / "SolarpunkSurvival"


def dump_dir(n: int) -> Path:
    return mod_root(n) / "dump"


def cmd_launch(n: int, nosteam: bool):
    exe = game_dir(n) / "Binaries" / "Win64" / EXE_NAME
    args = [str(exe)] + LAUNCH_ARGS + (["-nosteam"] if nosteam else [])
    proc = subprocess.Popen(args, cwd=str(exe.parent),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    pids = PIDFILE.read_text().split() if PIDFILE.is_file() else []
    pids.append(str(proc.pid))
    PIDFILE.parent.mkdir(parents=True, exist_ok=True)
    PIDFILE.write_text(" ".join(pids))
    print(f"instance {n} pid={proc.pid} ({'nosteam' if nosteam else 'steam'})")


def run_channel(n: int, cmdline: str, timeout: float) -> str:
    """Write one command line to the install's cmd.txt and wait for result.txt."""
    d = dump_dir(n)
    d.mkdir(parents=True, exist_ok=True)
    result = d / "result.txt"
    if result.exists():
        result.unlink()
    (d / "cmd.txt").write_text(cmdline, encoding="utf-8")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if result.is_file():
            time.sleep(0.3)  # let the game finish the write
            try:
                return result.read_text(encoding="utf-8", errors="replace")
            except OSError:
                pass  # mid-write; retry
        time.sleep(0.25)
    return "(TIMEOUT: no result.txt -- is the game up with dev mods on?)"


def cmd_exec(n: int, lua_file: Path, timeout: float):
    if not lua_file.is_file():
        sys.exit(f"no such lua file: {lua_file}")
    shutil.copyfile(lua_file, dump_dir(n) / "exec.lua")
    print(run_channel(n, "exec", timeout))


def cmd_raw(n: int, line: str, timeout: float):
    print(run_channel(n, line, timeout))


def cmd_tail(which: str, lines: int):
    if which == "game":
        candidates = sorted(SHARED_LOG_DIR.glob("Solarpunk*.log"))
    else:
        candidates = [game_dir(int(which)) / "Binaries" / "Win64" / "ue4ss" / "UE4SS.log"]
    for path in candidates:
        if not path.is_file():
            continue
        print(f"===== {path} =====")
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as e:  # UE keeps the live log open with share-read, so this is rare
            print(f"(unreadable: {e})")
            continue
        for ln in text.splitlines()[-lines:]:
            print(ln)


def cmd_ps():
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {EXE_NAME}", "/NH", "/FO", "CSV"],
                         capture_output=True, text=True).stdout
    print(out.strip() or "(none)")


def cmd_kill():
    if PIDFILE.is_file():
        for pid in PIDFILE.read_text().split():
            subprocess.run(["taskkill", "/PID", pid, "/F"], capture_output=True)
            print(f"killed {pid}")
        PIDFILE.unlink()
    else:
        print("(no recorded pids)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="op", required=True)
    p = sub.add_parser("launch"); p.add_argument("n", type=int); p.add_argument("--nosteam", action="store_true")
    p = sub.add_parser("exec"); p.add_argument("n", type=int); p.add_argument("lua"); p.add_argument("--timeout", type=float, default=25)
    p = sub.add_parser("cmd"); p.add_argument("n", type=int); p.add_argument("line"); p.add_argument("--timeout", type=float, default=25)
    p = sub.add_parser("tail"); p.add_argument("which"); p.add_argument("lines", nargs="?", type=int, default=40)
    sub.add_parser("ps")
    sub.add_parser("kill")
    a = ap.parse_args()
    if a.op == "launch":
        cmd_launch(a.n, a.nosteam)
    elif a.op == "exec":
        cmd_exec(a.n, Path(a.lua), a.timeout)
    elif a.op == "cmd":
        cmd_raw(a.n, a.line, a.timeout)
    elif a.op == "tail":
        cmd_tail(a.which, a.lines)
    elif a.op == "ps":
        cmd_ps()
    elif a.op == "kill":
        cmd_kill()


if __name__ == "__main__":
    main()
