# Install

> **Every player in a co-op session must install the same version.** The host runs all
> authoritative logic; unmodded clients are unsupported.

The short version lives in the [README](../README.md): drop the Solarpunk-patched UE4SS zip in your
Downloads folder, close the game, and run

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

This page is the long version — what that script actually does, how to do it by hand, and what to
check when something doesn't work.

## What gets installed, and where

`<game>` below is the folder holding `Binaries\` and `Content\`, normally
`C:\Program Files (x86)\Steam\steamapps\common\Solarpunk\Solarpunk` (the installer finds it via the
Steam registry keys and `libraryfolders.vdf`, so second drives and non-default library folders work;
`-GameDir` overrides it).

| Dependency | Where it goes | Automatic? |
|---|---|---|
| **Visual C++ 2015-2022 x64 runtime** — UE4SS links against it | system | yes, downloaded from `aka.ms` and installed silently (one UAC prompt) if missing |
| **UE4SS** (Solarpunk-patched) | `<game>\Binaries\Win64\` — `dwmapi.dll` + `ue4ss\` beside the exe | from a local zip only: Nexus needs a login. Found automatically beside `install.ps1`, in `Downloads`, or on the `Desktop` |
| **UE4SS settings** | `<game>\Binaries\Win64\ue4ss\UE4SS-settings.ini` | yes — console on, engine pinned to 5.7, scan budget 120 s |
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
2. Unzip the patched UE4SS and copy `dwmapi.dll` and the `ue4ss\` folder into
   `<game>\Binaries\Win64\`.
3. In `ue4ss\UE4SS-settings.ini` set `ConsoleEnabled`, `GuiConsoleEnabled` and `GuiConsoleVisible`
   to `1`, `MajorVersion = 5`, `MinorVersion = 7`, `SecondsToScanBeforeGivingUp = 120`.
4. Copy `mod\SolarpunkSurvival\` into `<game>\Binaries\Win64\ue4ss\Mods\`, and create an empty
   `dump\` folder inside it (the dev dumper writes there and can't create it itself).
5. Copy the pak triple into `<game>\Content\Paks\`, renamed `Solarpunk-Windows_1_P.utoc` / `.ucas` /
   `.pak`.

The mod ships an `enabled.txt`, which is what actually enables it — that file **overrides**
`Mods\mods.txt`, so a `SolarpunkSurvival : 1` line there is belt-and-braces only.

## Linux & Steam Deck (Proton)

Solarpunk has no native Linux build, so Linux and Steam Deck run it under **Proton** — and the mod
runs there too, injected into the game's Windows process inside the Wine prefix. The mod itself is
just Lua and a pak, platform-agnostic once UE4SS loads.

`install.ps1` can't run here (it's Windows PowerShell, reads the Windows registry for the Steam path,
and installs the VC++ runtime as a Windows `.exe`), so use **`install.sh`** instead, with the game
closed:

```bash
bash install.sh
```

It mirrors the Windows installer for everything on the filesystem: it locates the game through
Steam's `libraryfolders.vdf` (native `~/.steam` / `~/.local/share/Steam`, the Flatpak Steam under
`~/.var/app/com.valvesoftware.Steam/…`, and Deck SD-card libraries under `/run/media/…`), unpacks the
patched UE4SS beside the exe, applies the same `UE4SS-settings.ini` edits (console on,
`MajorVersion = 5`, `MinorVersion = 7`, `SecondsToScanBeforeGivingUp = 120`), copies the Lua mod into
`ue4ss/Mods/SolarpunkSurvival/`, and installs the pak into `Content/Paks/`. It takes the same flags
as `install.ps1` (`--game-dir`, `--ue4ss-zip`, `--skip-pak`, `--force`, `--uninstall`), plus
`--vcrun` (below), and finds the patched UE4SS zip the same way — in `~/Downloads`, on the Desktop,
or beside the script.

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

   `install.sh --vcrun` runs this for you when `protontricks` (native or the
   `com.github.Matoking.protontricks` Flatpak) is present and the prefix already exists — launch the
   game once first so Proton creates it under `compatdata/1805110`.

A recent Proton (or Proton-GE) is the most likely to work. On success the UE4SS console still opens
and logs `SolarpunkSurvival v0.1.0 starting`; if it doesn't, the Proton log (`PROTON_LOG=1
%command%`) is the place to look, and the Windows troubleshooting below still applies. Building the
content pak on Linux isn't supported (`tools/pakkit/setup.ps1` is Windows-only) — take the pak from
the release zip. Reports of what works on Proton / the Deck are welcome.

## First launch

The UE4SS console window opens with the game and logs:

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

**No UE4SS console window.** Either UE4SS didn't load (`dwmapi.dll` missing from `Binaries\Win64`,
or the VC++ runtime isn't installed), or the console is off in `UE4SS-settings.ini`. Re-run
`install.ps1 -Force` to reinstall the core and rewrite the settings.

**Console opens, but no `SolarpunkSurvival` lines.** The mod folder isn't where UE4SS looks — it
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

**PowerShell refuses to run the script.** Use the full command with
`-ExecutionPolicy Bypass -File`, rather than right-click > Run with PowerShell.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
```

Removes the mod folder and the content pak; UE4SS itself is left in place (other mods may be using
it) — to remove that too, delete `dwmapi.dll` and the `ue4ss\` folder from `Binaries\Win64`.

Back up your save first: the mod adds persistent state to the host save.
