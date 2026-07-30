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

One cross-platform script (the game is Windows-only; Linux/Steam Deck run it via Proton):

```
python tools/run.py
```

The script: stops any running instance → fast-syncs the current `mod/` + pak into the game install
(changed files only; it also installs the UE4SS core when it's missing or on `--force`, extracted
from the bundled `vendor/UE4SS-Solarpunk-runtime.zip` — nothing is ever downloaded) → launches via
`steam://rungameid/1805110` → tails `<game>/Binaries/Win64/ue4ss/UE4SS.log` until the mod prints
`SolarpunkSurvival vX.Y.Z starting` (≤120 s, failing fast if the game process crashes), then
echoes the recent mod log lines. All install logic is imported from the repo-root `install.py`, so
this sets up everything from nothing on a fresh machine — Steam + the game + Python are the only
prerequisites.

**What it deploys is the player install, byte for byte.** `Scripts/dev` — the RE dumper, the
`dump/cmd.txt` remote exec channel, the ritual kit, `sps_testkit` — ships **only** with `--dev`,
and a deploy *without* `--dev` prunes those files back out, so the exec channel goes quiet until
the next `--dev` deploy. Use plain `/run` to rehearse what a player gets; use `--dev` when you
need to drive the running game.

Useful flags: `--dev` (deploy the dev tools too), `--no-install` (relaunch without redeploying —
faster when only testing a launch), `--force` (reinstall the UE4SS core), `--wait N`,
`--game-dir <path>` if auto-detection misses the install (the detected dir is cached in
`tools/.gamedir`).

`python install.py --status` reports what is currently installed (UE4SS, mod, dev tools, pak,
last loaded version) without changing anything — the quickest way to check an install before or
after a run. `--purge` removes everything the installer ever wrote, UE4SS included.

## What "success" looks like

The script prints `Mod loaded.` and the `SolarpunkSurvival ... starting` / `... ready` lines from
`UE4SS.log`. Report that to the user. Then tell them to **load a save** — the main menu has no pawn,
so most features (the wand on **V**, `sps_*` console commands, `sps_storm` to force weather) need a
loaded world.

## Important limits — set expectations, don't fake them

- **No auto-screenshot / no headless run.** This is a full 3D game with a GUI you can't drive from
  the terminal. "Confirming a change works" here = the UE4SS log shows the mod loaded, plus (for
  gameplay) the user playing, or the live `dump/cmd.txt` → `dump/result.txt` remote exec channel
  (see the `solarpunk-live-hotload` memory) to poke the running game. Do not claim to have seen
  in-game behavior you didn't observe.
- **Prerequisites the script assumes are already met:** Solarpunk installed on Steam (UE4SS is
  bundled in `vendor/`, so nothing needs downloading). On Linux, Proton must already have the
  `WINEDLLOVERRIDES="dwmapi=n,b" %command%` launch option and `vcrun2022` in the prefix — the
  script can't set those (`docs/INSTALL.md`).
- **The game must be closed to redeploy** — the script stops it for you; if the user has an
  unsaved session, warn before restarting.
- **Multiplayer:** every player in a co-op session needs the same install.

## Live iteration without a full relaunch

If the game is already running and you only changed Lua, you usually don't need `/run` at all: copy
the changed file into the installed `ue4ss/Mods/SolarpunkSurvival/Scripts/` and hot-reload it through
the `dump/cmd.txt` exec channel (`solarpunk-live-hotload` memory). Reserve `tools/run.py` for a
clean deploy-and-launch or after changing the content pak.

**The exec channel needs `python tools/run.py --dev`.** It lives in `Scripts/dev/remote.lua`, which
a plain `/run` does not deploy — and actively prunes if a previous `--dev` deploy left it there.

## Stocking a fresh save for testing

A new world has no research, no recipes, a 29-slot pack and none of the pak items. After a `--dev`
deploy, `sps_testkit` in the console does the lot: every research card and recipe id unlocked
(which is also how the crafting-table and research-station *tiers* work — they are research rows,
not actor properties), backpack to tier 7 (50 slots), the wands / Tempest Codex / diamond rod /
sorting chest, a power rig (batteries, cable), the ship repair kit, both rites' offerings and bulk
materials. `sps_testkit status` reports without changing anything; `sps_testkit items <group>`
grants one group at a time when the pack is tight.
