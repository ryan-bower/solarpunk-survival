# Solarpunk Survival

A co-op **total-conversion mod** that turns [Solarpunk](https://store.steampowered.com/app/1805110/Solarpunk/)
(Cyberwave, Unreal Engine 5) from a cozy builder into a survival experience: **deadly storms,
telegraphed lightning, destructible machines, dark-arts rites, and storm-forged wands** — all
working in host-authoritative co-op.

Two halves: a [UE4SS](https://docs.ue4ss.com/) Lua mod (all the behaviour) and a cooked content
pak (the new items — wands, the Tempest Codex, its research card).

---

## Install

**One script does everything.** It finds your game, installs the Visual C++ runtime if it's
missing, puts UE4SS next to the game exe with the right engine-version settings, and copies in
both the Lua mod and the content pak.

You need three things first:

| | |
|---|---|
| **Windows** or **Linux / Steam Deck** + **Solarpunk** on Steam | tested against build `24038177`. Linux / Steam Deck run through Proton — use [`install.sh`](#linux--steam-deck-proton) instead of the PowerShell script |
| **[The Solarpunk-patched UE4SS](https://www.nexusmods.com/solarpunk/mods/4)** (`UE4SS-SP-Developer.zip`) | stock UE4SS can't scan this game's engine build. Nexus needs a login, so this is the one file the installer can't fetch for you — just leave it in your **Downloads** folder |
| This mod — the **release zip**, or a clone of this repo | a clone has no content pak (game-derived data isn't committed); [build it](#building-the-content-pak) or use the release zip |

Then, with the game closed:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Launch Solarpunk. `Binaries\Win64\ue4ss\UE4SS.log` logs `SolarpunkSurvival v0.1.0 starting`.

**Redeploy + relaunch in one step** (after editing the mod): `python tools/run.py` (Windows and
Linux) — it fast-syncs the changed files, launches the game, and waits for that startup line.

<details>
<summary>Options</summary>

| Flag | |
|---|---|
| `-GameDir <path>` | skip auto-detection — pass the `Solarpunk` folder (or its `Binaries\Win64`) |
| `-Ue4ssZip <path>` | point at the UE4SS zip explicitly |
| `-SkipPak` | Lua mod only — no wands, no codex |
| `-SkipVcRedist` | don't check for / install the Visual C++ runtime |
| `-Force` | reinstall the UE4SS core even if it's already there |
| `-Uninstall` | remove the mod and the content pak (leaves UE4SS in place) |

</details>

**Updating:** `git pull` (or unzip the newer release) and run `install.ps1` again — it's idempotent,
and it leaves your config and mod save alone.

**Multiplayer:** Solarpunk co-op is a host-authoritative listen server. All the logic runs on the
host, so **every player in the session needs this same install**. Unmodded clients are unsupported.

### Linux & Steam Deck (Proton)

There is **no native Linux build** of Solarpunk — it runs through **Proton**, and so can this mod.
Use the Linux installer instead of `install.ps1`, with the game closed:

```bash
bash install.sh
```

It does the same filesystem work as the Windows script — finds the game through Steam's
`libraryfolders.vdf` (native, Flatpak, and Deck SD-card libraries), installs the patched UE4SS, pins
the engine version, and copies in the Lua mod and content pak — then prints the **two Steam-side
steps it can't do for you**:

1. **Launch option** (Steam ▸ Solarpunk ▸ Properties ▸ Launch Options), so Wine loads UE4SS's proxy
   DLL: `WINEDLLOVERRIDES="dwmapi=n,b" %command%`
2. **The MSVC runtime** in the game's Proton prefix: `protontricks 1805110 vcrun2022` — or run
   `bash install.sh --vcrun` to do it for you (needs the prefix to exist, so launch the game once
   first).

Same prerequisite as Windows (drop the patched UE4SS zip in `~/Downloads`), and `install.sh` takes
the same flags: `--game-dir`, `--ue4ss-zip`, `--skip-pak`, `--force`, `--uninstall`. The Proton path
is newer and less battle-tested than the Windows one — reports of what works on Proton / the Deck are
welcome.

Manual steps, troubleshooting and what goes where: [`docs/INSTALL.md`](docs/INSTALL.md).

## Playing

| | |
|---|---|
| **P** | toggle the storm (`sps_storm` / `sps_storm_off`; `sps_auto` re-enables hunting auto-strikes) |
| **V** | draw / stow the wand |
| **left click** (wand drawn) | cast — a bolt where you look, or a pour / a drink for a teammate |
| **F7** | in-game config panel |
| **F8** | write an RE dump (`sps_dump`) — dev tool, safe to ignore |

Other console commands: `sps_wand` (state, `forge`/`soak`/`charge`/`give`), `sps_codex`,
`sps_repair`, `sps_find <text>`, `sps_ritual_test`.

The two rites — the chicken's for water, the lamb's for fire — are written up in
[`docs/DARK-ARTS.md`](docs/DARK-ARTS.md), and in-game in the **Tempest Codex** (a craftable book;
research *The Dark Arts*, then craft the codex and a Mundane Wand at the bench).

**Tuning:** every number lives in `Mods/SolarpunkSurvival/config/config.json` (copy
`config.default.json` next to it and edit), or press **F7**. In co-op the host's values win.

## What's in it

| | |
|---|---|
| **Storms & lightning** | frequent telegraphed strikes with a ~1.2 s ground decal, bursts, and a 70 %-max-HP player hit — two bolts kill. Struck players are stunned, T-posed and whited out. |
| **Lightning vs the world** | batteries/generators charge to full, furnaces fuel themselves, other tech smokes then breaks on a second hit (half its components drop as salvage), trees fall. |
| **Lightning rod** | the game's own Weather Station redirects every strike within 25 m to itself, and charges an adjacent battery. |
| **Dark-arts rites** | a pentagram of fences + candles + five offerings around a sacrifice; the bolt that takes it turns every blank wand in the circle. |
| **Wands** | Mundane → **Hydration** (240 measures: fills growboxes, quenches teammates, refills on drinking/wading) or → **Electrick** (aimed bolts in any weather, recharges near strikes). One nature per rod, forever. |
| **Tempest Codex** | a real craftable, placeable, readable in-game book — five sections of lore, cooked into the content pak. |

Design and roadmap: [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/MILESTONE-2.md`](docs/MILESTONE-2.md).

## Building the content pak

Only needed if you're working from a clone. The pak is cooked offline — no Unreal Editor — by
round-tripping the game's own assets, so it can't be redistributed in a public repo.

```powershell
powershell -ExecutionPolicy Bypass -File tools/pakkit/setup.ps1   # one-time: every build dependency
python tools/pakkit/build_wand_pak.py                             # -> tools/pakkit/out/z_SolarpunkWand_P.*
powershell -ExecutionPolicy Bypass -File install.ps1              # installs the result into the game
```

`setup.ps1` fetches Python, the .NET SDK, Lua, retoc and UAssetAPI, builds the `wandsmith` CLI, and
extracts the game's own assets to work from. The single piece it can't fetch is `Solarpunk.usmap`,
which is dumped out of the *running* game — that step, and the toolchain's one very sharp gotcha,
are in [`tools/pakkit/HOWTO.md`](tools/pakkit/HOWTO.md). Unit tests: `lua tests/spec.lua`.

## Caveats

- **Back up your save.** The mod writes persistent state (and the research migration touches the
  host save).
- Solarpunk has no mod API, so **a game update can break this mod** until it's re-mapped against a
  fresh dump — see [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md) and
  [`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md).

## License

MIT — see [`LICENSE`](LICENSE). This project ships **no** Solarpunk game files, assets, or symbols.
