# Install

> **Every player in a co-op session must install the same version.** The host runs all
> authoritative logic; unmodded clients are unsupported.

The short version lives in the [README](../README.md): close the game and run

```
python install.py
```

Everything the mod needs ships with it — including a trimmed, runtime-only build of the
Solarpunk-patched UE4SS in `vendor/` — so there is nothing else to download. The installer is
pure Python (3.8+), the same file on Windows and Linux/Steam Deck. This page is the long
version — what that script actually does, how to do it by hand, and what to check when
something doesn't work.

## What gets installed, and where

`<game>` below is the folder holding `Binaries\` and `Content\`, normally
`C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk` (the installer finds it via the
Steam registry keys and `libraryfolders.vdf`, so second drives and non-default library folders work;
`--game-dir` overrides it).

| Dependency | Where it goes | Automatic? |
|---|---|---|
| **Visual C++ 2015-2022 x64 runtime** — UE4SS links against it | system | yes, downloaded from `aka.ms` and installed silently (one UAC prompt) if missing — the only network access in the whole install |
| **UE4SS** (Solarpunk-patched, runtime-only) | `<game>\Binaries\Win64\` — `dwmapi.dll` + `ue4ss\` beside the exe | yes — extracted from the bundled `vendor/UE4SS-Solarpunk-runtime.zip`; no downloads, no dev tooling (no debug symbols, debugger DLLs, or dumper configs) |
| **UE4SS settings** | `<game>\Binaries\Win64\ue4ss\UE4SS-settings.ini` | yes — console windows off, engine pinned to 5.7, scan budget 120 s |
| **The Lua mod** | `<game>\Binaries\Win64\ue4ss\Mods\SolarpunkSurvival\` | yes |
| **The content pak** (wands, Tempest Codex) | `<game>\Content\Paks\Solarpunk-Windows_1_P.{utoc,ucas,pak}` | yes, if the pak is present in the release zip's `paks\` or in `tools\pakkit\out\` |
| **`SolarpunkSteam-Win64-Shipping.pdb`** — UE4SS resolves symbols from it | ships with the game, beside the exe | verified; you're warned if it's gone |

Two settings in that ini matter and are easy to get wrong by hand: the game is **UE 5.7.1**, which
UE4SS cannot auto-detect (`MajorVersion = 5`, `MinorVersion = 7`), and its AOB scan needs longer
than the stock budget (`SecondsToScanBeforeGivingUp = 120`).

The pak name is not cosmetic. The game's own container is `Solarpunk-Windows_0_P` at mount
**order 104**; `_1_P` mounts at **204** and so overrides the base `DB_Items`. A `~mods\` install
lands at order **103** — *below* the base — where the same edit is silently shadowed and does
nothing.

## Doing it by hand

1. Install the [VC++ 2015-2022 x64 runtime](https://aka.ms/vs/17/release/vc_redist.x64.exe).
2. Unzip `vendor\UE4SS-Solarpunk-runtime.zip` and copy `dwmapi.dll` and the `ue4ss\` folder into
   `<game>\Binaries\Win64\`.
3. In `ue4ss\UE4SS-settings.ini` set `MajorVersion = 5`, `MinorVersion = 7`,
   `SecondsToScanBeforeGivingUp = 120`, and `ConsoleEnabled` / `GuiConsoleEnabled` /
   `GuiConsoleVisible` to `0` (they open extra dev console windows next to the game; everything
   they show also lands in `ue4ss\UE4SS.log` — set them to `1` only if you want them for debugging).
4. Copy `mod\SolarpunkSurvival\` into `<game>\Binaries\Win64\ue4ss\Mods\`, delete its
   `Scripts\dev\` folder (developer tools — the mod skips them when absent), and create an empty
   `dump\` folder inside it (the mod writes diagnostics there and can't create it itself).
5. Copy the pak triple into `<game>\Content\Paks\`, renamed `Solarpunk-Windows_1_P.utoc` / `.ucas` /
   `.pak`.

The mod ships an `enabled.txt`, which is what actually enables it — that file **overrides**
`Mods\mods.txt`, so a `SolarpunkSurvival : 1` line there is belt-and-braces only.

## Linux & Steam Deck (Proton)

Solarpunk has no native Linux build, so Linux and Steam Deck run it under **Proton** — and the mod
runs there too, injected into the game's Windows process inside the Wine prefix. The mod itself is
just Lua and a pak, platform-agnostic once UE4SS loads.

It's the **same installer**, with the game closed:

```bash
python3 install.py
```

It does the same filesystem work as on Windows: it locates the game through Steam's
`libraryfolders.vdf` (native `~/.steam` / `~/.local/share/Steam`, the Flatpak Steam under
`~/.var/app/com.valvesoftware.Steam/…`, and Deck SD-card libraries under `/run/media/…`), unpacks
the bundled UE4SS runtime beside the exe with the right `UE4SS-settings.ini` values
(`MajorVersion = 5`, `MinorVersion = 7`, `SecondsToScanBeforeGivingUp = 120`, console windows
off), copies the Lua mod into `ue4ss/Mods/SolarpunkSurvival/`, and installs the pak into
`Content/Paks/`. It takes the same flags as on Windows, plus `--vcrun` (below).

Two things live in Steam/Proton, not the filesystem, so the script prints them rather than setting
them:

1. **Make Wine load the UE4SS proxy DLL.** UE4SS injects through `dwmapi.dll`; Wine ignores a
   dropped-in system DLL unless told to prefer it. Set a Steam **launch option** on Solarpunk:

   ```
   WINEDLLOVERRIDES="dwmapi=n,b" %command%
   ```

   (`n,b` = native first, builtin fallback.)

2. **Install the MSVC runtime into the prefix.** UE4SS links against the VC++ 2015-2022 runtime; put
   it in Solarpunk's own Proton prefix (app id **1805110**):

   ```
   protontricks 1805110 vcrun2022
   ```

   `python3 install.py --vcrun` runs this for you when `protontricks` (native or the
   `com.github.Matoking.protontricks` Flatpak) is present and the prefix already exists — launch the
   game once first so Proton creates it under `compatdata/1805110`.

A recent Proton (or Proton-GE) is the most likely to work. On success `ue4ss/UE4SS.log` logs
`SolarpunkSurvival v0.1.0 starting`; if it doesn't, the Proton log (`PROTON_LOG=1
%command%`) is the place to look, and the Windows troubleshooting below still applies. Building the
content pak on Linux isn't supported (the `tools/pakkit` toolchain is Windows-only) — take the pak
from the release zip. Reports of what works on Proton / the Deck are welcome.

## First launch

UE4SS writes `<game>\Binaries\Win64\ue4ss\UE4SS.log` as the game starts; it should show:

```
[SolarpunkSurvival] SolarpunkSurvival v0.1.0 starting
[SolarpunkSurvival] SolarpunkSurvival ready
```

Load a save (the menu has no pawn, so most commands need a world), then press **P** for a storm.

## Configuration

Copy `config\config.default.json` to `config\config.json` in the installed mod folder and edit it,
or press **F7** in-game. Unknown keys are ignored, a malformed file falls back to the defaults, and
in co-op the host's values are the ones that count.

## Troubleshooting

**"Solarpunk is running - quit the game first."** The game holds `dwmapi.dll` and its paks open.
Quit it (not just to the menu — all the way out) and re-run.

**No `ue4ss\UE4SS.log` after a launch.** UE4SS didn't load — `dwmapi.dll` missing from
`Binaries\Win64`, or the VC++ runtime isn't installed. Re-run `python install.py --force` to
reinstall the core and rewrite the settings.

**The log exists, but no `SolarpunkSurvival` lines.** The mod folder isn't where UE4SS looks — it
must be `Binaries\Win64\ue4ss\Mods\SolarpunkSurvival\` with `Scripts\main.lua` inside, and it needs
its `enabled.txt`.

**The mod loads but there are no wands, no codex, no research card.** The content pak isn't
installed. Check for `Content\Paks\Solarpunk-Windows_1_P.*` — and make sure it isn't sitting in
`Content\Paks\~mods\`, where it would be shadowed by the base game (see above).

**`sps_wand give` warns that the class can't be found.** Same cause: the pak isn't mounted.

**The mod logs `DEGRADED` and disables features.** It couldn't resolve the game symbols it needs —
usually a game update. Press **F7** for the missing-symbol list, then re-map from a fresh dump
(**F8** in a loaded world) per [`REVERSE-ENGINEERING.md`](REVERSE-ENGINEERING.md).

**Symbols look wrong / UE4SS scan fails.** Confirm `SolarpunkSteam-Win64-Shipping.pdb` is still
beside the exe; Steam > Solarpunk > Properties > Installed Files > Verify integrity restores it.

**`python` isn't recognized.** Install Python 3.8+ from
[python.org](https://www.python.org/downloads/) or the Microsoft Store (on Windows 10/11, typing
`python` in a terminal opens the Store page). On Linux use `python3`.

## Uninstall

```
python install.py --uninstall
```

Removes the mod folder and the content pak; UE4SS itself is left in place (other mods may be using
it) — to remove that too, delete `dwmapi.dll` and the `ue4ss\` folder from `Binaries\Win64`.

Back up your save first: the mod adds persistent state to the host save.
