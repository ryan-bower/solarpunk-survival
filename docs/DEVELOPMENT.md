# Developing the mod

Player-facing install and play instructions live in the [README](../README.md); this page is the
developer side — the run loop, the dev tools, the content-pak toolchain, and the tests.

## The dev loop: deploy + relaunch in one step

```
python tools/run.py
```

One cross-platform script (Windows native, Linux/Steam Deck via Proton). It stops any running
instance, fast-syncs the current `mod/` + pak into the game install (changed files only, stale
files pruned — the installed `dump/` and `config/` are never touched), launches via Steam, and
tails `ue4ss/UE4SS.log` until the mod logs `SolarpunkSurvival vX.Y.Z starting`, failing fast if
the game process dies first. It even puts UE4SS in place when it's missing — the only thing it
can't fetch is the Solarpunk-patched UE4SS zip (Nexus needs a login); leave that in `Downloads`.

| Flag | |
|---|---|
| `--no-install` | relaunch without redeploying |
| `--force` | reinstall the UE4SS core even if it's already there |
| `--wait <s>` | how long to wait for the startup line (default 120) |
| `--game-dir <path>` | skip auto-detection (the detected dir is cached in `tools/.gamedir`) |

If the game is already running and you only changed Lua, you usually don't need a relaunch at
all — copy the changed file into the installed `Scripts/` and hot-reload it through the remote
exec channel below.

## Dev tools (`Scripts/dev/`)

The player installers (`install.ps1` / `install.sh`) **exclude `Scripts/dev` entirely** — players
get no RE dumper, no remote exec channel, no ritual dev kit, and `main.lua` silently skips the
missing modules. `tools/run.py` deploys them. The tools:

| | |
|---|---|
| `dev/recapture.lua` | **F8** / `sps_dump` writes an RE dump; `sps_find <text>` searches live objects |
| `dev/remote.lua` | file-command channel: write one line to `<mod>/dump/cmd.txt`, read `dump/result.txt`; `exec` runs `dump/exec.lua` in the live game |
| `dev/ritual_test.lua` | `sps_ritual_test` — scripted end-to-end rite check |
| `dev/ritual_kit.lua` | `sps_needful hydration\|electrick [noanimal]` — stages a rite's animal + rod + offerings at your last map ping |

The UE4SS console windows (`ConsoleEnabled` / `GuiConsoleEnabled` / `GuiConsoleVisible` in
`UE4SS-settings.ini`) are pinned **off** by the installers and `run.py` — everything they show
also lands in `ue4ss/UE4SS.log`. Flip them to `1` by hand if you want the live console; note the
next deploy pins them back.

## Building the content pak

Only needed if you're working from a clone (the release zip ships the pak). The pak is cooked
offline — no Unreal Editor — by round-tripping the game's own assets, so it can't be
redistributed in a public repo.

```powershell
powershell -ExecutionPolicy Bypass -File tools/pakkit/setup.ps1   # one-time: every build dependency
python tools/pakkit/build_wand_pak.py                             # -> tools/pakkit/out/z_SolarpunkWand_P.*
python tools/run.py                                               # deploys the result and launches
```

`setup.ps1` fetches Python, the .NET SDK, Lua, retoc and UAssetAPI, builds the `wandsmith` CLI, and
extracts the game's own assets to work from. The single piece it can't fetch is `Solarpunk.usmap`,
which is dumped out of the *running* game — that step, and the toolchain's one very sharp gotcha,
are in [`tools/pakkit/HOWTO.md`](../tools/pakkit/HOWTO.md).

## Tests

```
lua tests/spec.lua
```

## When a game update lands

Solarpunk has no mod API — a game update can break the mod until it's re-mapped against a fresh
dump. See [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md) and
[`REVERSE-ENGINEERING.md`](REVERSE-ENGINEERING.md).
