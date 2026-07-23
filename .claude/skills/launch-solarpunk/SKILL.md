---
name: launch-solarpunk
description: Run/launch/start this project's app — deploy the SolarpunkSurvival mod and launch Solarpunk, then confirm the mod loaded. This is the launch entrypoint /run should use for this repo (it is a UE4SS Lua game mod, not a standalone app).
---

# Launching the Solarpunk mod (the "run the app" procedure)

This repo is a **UE4SS Lua mod + content pak for Solarpunk** (a Steam game), not a standalone
program. "Running the app" therefore means: deploy the current mod into the game install and launch
Solarpunk so the mod injects. A ready helper script does the whole flow — **use it, don't reinvent
the steps.**

## Do this

Pick by platform (the game is Windows-only; Linux/Steam Deck run it via Proton):

- **Windows** (PowerShell tool):
  ```
  powershell -ExecutionPolicy Bypass -File tools/run.ps1
  ```
- **Linux / Steam Deck** (Bash tool):
  ```
  bash tools/run.sh
  ```

Each script: stops any running instance → runs the installer (`install.ps1` / `install.sh`) to copy
in the current `mod/` + pak → launches via `steam://rungameid/1805110` → tails
`<game>/Binaries/Win64/ue4ss/UE4SS.log` until the mod prints `SolarpunkSurvival vX.Y.Z starting`
(≤120 s), then echoes the recent mod log lines.

Useful flags: `-NoInstall` / `--no-install` (relaunch without redeploying — faster when only testing
a launch), `-WaitSeconds N` / `--wait N`, `-GameDir <path>` / `--game-dir <path>` if auto-detection
misses the install.

## What "success" looks like

The script prints `Mod loaded.` and the `SolarpunkSurvival ... starting` / `... ready` lines from
`UE4SS.log`. Report that to the user. Then tell them to **load a save** — the main menu has no pawn,
so most features (storms on **P**, the wand on **V**, `sps_*` console commands) need a loaded world.

## Important limits — set expectations, don't fake them

- **No auto-screenshot / no headless run.** This is a full 3D game with a GUI you can't drive from
  the terminal. "Confirming a change works" here = the UE4SS log shows the mod loaded, plus (for
  gameplay) the user playing, or the live `dump/cmd.txt` → `dump/result.txt` remote exec channel
  (see the `solarpunk-live-hotload` memory) to poke the running game. Do not claim to have seen
  in-game behavior you didn't observe.
- **Prerequisites the scripts assume are already met:** Solarpunk installed on Steam, and the
  Solarpunk-patched UE4SS available to the installer (see `README.md` / `docs/INSTALL.md`). On
  Linux, Proton must already have the `WINEDLLOVERRIDES="dwmapi=n,b" %command%` launch option and
  `vcrun2022` in the prefix — the script can't set those (`docs/INSTALL.md`).
- **The game must be closed to redeploy** — the script stops it for you; if the user has an
  unsaved session, warn before restarting.
- **Multiplayer:** every player in a co-op session needs the same install.

## Live iteration without a full relaunch

If the game is already running and you only changed Lua, you usually don't need `/run` at all: copy
the changed file into the installed `ue4ss/Mods/SolarpunkSurvival/Scripts/` and hot-reload it through
the `dump/cmd.txt` exec channel (`solarpunk-live-hotload` memory). Reserve `tools/run.*` for a clean
deploy-and-launch or after changing the content pak.
