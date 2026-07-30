# Solarpunk Survival

A co-op **total-conversion mod** that turns [Solarpunk](https://store.steampowered.com/app/1805110/Solarpunk/)
(Cyberwave, Unreal Engine 5) from a cozy builder into a survival experience: **deadly storms,
telegraphed lightning, destructible machines, dark-arts rites, and storm-forged wands** — all
working in host-authoritative co-op.

Two halves: a [UE4SS](https://docs.ue4ss.com/) Lua mod (all the behaviour) and a cooked content
pak (the new items — wands, the Tempest Codex, its research card).

---

## Install

**One command does everything, and everything is bundled** — a trimmed, runtime-only build of the
Solarpunk-patched [UE4SS](https://docs.ue4ss.com/), the Visual C++ runtime it links against, the
Lua mod and the content pak (`vendor/`, `mod/`, `paks/`). There is **nothing else to download**,
nothing installed machine-wide, and no developer tooling in what gets installed. The installer
finds your game through Steam, puts UE4SS next to the game exe with the right engine-version
settings, and copies in both the Lua mod and the content pak.

You need three things first:

| | |
|---|---|
| **Windows** or **Linux / Steam Deck** + **Solarpunk** on Steam | tested against build `24038177`. Linux / Steam Deck run through [Proton](#linux--steam-deck-proton) |
| **Python 3.8+** | almost certainly already there — if not, Windows: [python.org](https://www.python.org/downloads/) or the Microsoft Store. Linux / Steam Deck already have `python3`. `install.bat` checks for you and says where to get it |
| This mod — the **release zip**, or a clone of this repo | a clone has no content pak (game-derived data isn't committed); use the release zip, or build it yourself ([`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)) |

Then, with the game closed — double-click **`install.bat`**, or run:

```
python install.py
```

Launch Solarpunk. `Binaries\Win64\ue4ss\UE4SS.log` logs `SolarpunkSurvival v0.1.0 starting`.

<details>
<summary>Options</summary>

| Flag | |
|---|---|
| `--game-dir <path>` | skip auto-detection — pass the `Solarpunk` folder (or its `Binaries\Win64`) |
| `--skip-pak` | Lua mod only — no wands, no codex, no diamond rod, no sorting chest |
| `--no-vcredist` | don't check for / install the Visual C++ runtime (Windows) |
| `--vcrun` | Linux: also run `protontricks 1805110 vcrun2022` now |
| `--force` | reinstall the UE4SS core even if it's already there |
| `--status` | report what's installed and change nothing |
| `--uninstall` | remove the mod and the content pak (leaves UE4SS in place) |
| `--purge` | remove everything the installer ever wrote, UE4SS included |

</details>

**Updating:** `git pull` (or unzip the newer release) and run `python install.py` again — it's
idempotent, and it leaves your config and mod save alone.

**Multiplayer:** Solarpunk co-op is a host-authoritative listen server. All the logic runs on the
host, so **every player in the session needs this same install**. Unmodded clients are unsupported.

**Network access:** none. The Visual C++ 2015-2022 runtime UE4SS links against ships inside the
bundled payload and is placed *app-local*, next to the game exe — no machine-wide install, no UAC
prompt. (Only if those bundled DLLs were stripped **and** the machine has no runtime at all does
the installer fall back to fetching Microsoft's installer from `aka.ms`; `--no-vcredist` skips
even that.)

### Linux & Steam Deck (Proton)

There is **no native Linux build** of Solarpunk — it runs through **Proton**, and so can this mod.
Same command, with the game closed:

```bash
python3 install.py
```

It does the same filesystem work as on Windows — finds the game through Steam's
`libraryfolders.vdf` (native, Flatpak, and Deck SD-card libraries), installs the bundled UE4SS,
pins the engine version, and copies in the Lua mod and content pak — then prints the **two
Steam-side steps it can't do for you**:

1. **Launch option** (Steam ▸ Solarpunk ▸ Properties ▸ Launch Options), so Wine loads UE4SS's proxy
   DLL: `WINEDLLOVERRIDES="dwmapi=n,b" %command%`
2. **The MSVC runtime** in the game's Proton prefix: `protontricks 1805110 vcrun2022` — or run
   `python3 install.py --vcrun` to do it for you (needs the prefix to exist, so launch the game
   once first).

The Proton path is newer and less battle-tested than the Windows one — reports of what works on
Proton / the Deck are welcome.

Manual steps, troubleshooting and what goes where: [`docs/INSTALL.md`](docs/INSTALL.md).

## Playing

**Craft the Tempest Handbook first.** It is in the quick-craft (**F**) menu from the start for
1 log + 2 leaves — place it, press **E**, and it explains everything below in eight sections.

| | |
|---|---|
| **V** | draw / stow the wand |
| **left click** (wand drawn) | cast — a bolt where you look, or a pour / a drink for a teammate |
| **C** / **Left Ctrl** | crouch (tap to toggle, hold to crouch for the hold) |
| **B** | open the airship's storage chest |
| **TAB** (at the airship wheel) | ship ↔ pack transfer view |
| **SPACE** (at the airship wheel) | boost to 3× speed |
| **right click** a bench, empty-handed | sit / stand |

Storms arrive with the game's own weather. Console commands: `sps` (status + unmapped symbols),
`sps set <key> <value>`, `sps_storm` / `sps_storm_off`, `sps_wand`, `sps_codex`, `sps_handbook`,
`sps_fish`, `sps_bench`, `sps_trash`, `sps_sort`, `sps_repair`.

The two rites — the chicken's for water, the lamb's for fire — are written up in
[`docs/DARK-ARTS.md`](docs/DARK-ARTS.md), and in-game in the **Tempest Codex** (research
*The Dark Arts*, then craft the codex and a Mundane Wand at the bench).

**Tuning:** every number lives in `Mods/SolarpunkSurvival/config/config.json` (copy
`config.default.json` next to it and edit), or `sps set`. In co-op the host's values win.

## What's in it

| | |
|---|---|
| **Storms & lightning** | frequent telegraphed strikes with a ~1.2 s ground decal, bursts, and a 70 %-max-HP player hit — two bolts kill. Struck players are stunned, T-posed and whited out. |
| **Lightning vs the world** | batteries/generators charge to full, furnaces fuel themselves, other tech smokes then breaks on a second hit (half its components drop as salvage), trees fall. |
| **Lightning rod** | the game's own Weather Station redirects every strike within 25 m to itself, and charges an adjacent battery. |
| **Dark-arts rites** | a pentagram of fences + candles + five offerings around a sacrifice; the bolt that takes it turns every blank wand in the circle. |
| **Wands** | Mundane → **Hydration** (240 measures: fills growboxes, quenches teammates, refills on drinking/wading) or → **Electrick** (aimed bolts in any weather, recharges near strikes). One nature per rod, forever. |
| **Tempest Codex** | a real craftable, placeable, readable in-game book — five sections of lore, cooked into the content pak. |
| **Tempest Handbook** | a second readable book, in the quick-craft menu from the start: eight sections summarising every finished feature, so a new player can find out what changed. |

Design and roadmap: [`docs/DESIGN.md`](docs/DESIGN.md), [`docs/MILESTONE-2.md`](docs/MILESTONE-2.md).
Working on the mod itself (dev loop, building the content pak, tests): [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md).

## Caveats

- **Back up your save.** The mod writes persistent state (and the research migration touches the
  host save).
- Solarpunk has no mod API, so **a game update can break this mod** until it's re-mapped against
  a fresh dump.

## License

MIT — see [`LICENSE`](LICENSE). This project ships **no** Solarpunk game files, assets, or symbols.
The bundled UE4SS runtime (`vendor/`) is [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) (MIT), as
patched for Solarpunk; its license text ships inside the payload.
