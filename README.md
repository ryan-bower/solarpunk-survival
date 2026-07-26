# Solarpunk Survival

A co-op **total-conversion mod** that turns [Solarpunk](https://store.steampowered.com/app/1805110/Solarpunk/)
(Cyberwave, Unreal Engine 5) from a cozy builder into a survival experience: **deadly storms,
telegraphed lightning, destructible machines, dark-arts rites, and storm-forged wands** — all
working in host-authoritative co-op.

Two halves: a [UE4SS](https://docs.ue4ss.com/) Lua mod (all the behaviour) and a cooked content
pak (the new items — wands, the Tempest Codex, its research card).

---

## Install

**One command does everything, and everything is bundled** — including a trimmed, runtime-only
build of the Solarpunk-patched [UE4SS](https://docs.ue4ss.com/) (`vendor/`). There is **nothing
else to download** and no developer tooling in what gets installed. The installer finds your game
through Steam, puts UE4SS next to the game exe with the right engine-version settings, and copies
in both the Lua mod and the content pak.

You need three things first:

| | |
|---|---|
| **Windows** or **Linux / Steam Deck** + **Solarpunk** on Steam | tested against build `24038177`. Linux / Steam Deck run through [Proton](#linux--steam-deck-proton) |
| **Python 3.8+** | Windows: [python.org](https://www.python.org/downloads/) or the Microsoft Store (`python` in a terminal walks you through it). Linux / Steam Deck already have `python3` |
| This mod — the **release zip**, or a clone of this repo | a clone has no content pak (game-derived data isn't committed); use the release zip, or build it yourself ([`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)) |

Then, with the game closed:

```
python install.py
```

Launch Solarpunk. `Binaries\Win64\ue4ss\UE4SS.log` logs `SolarpunkSurvival v0.1.0 starting`.

<details>
<summary>Options</summary>

| Flag | |
|---|---|
| `--game-dir <path>` | skip auto-detection — pass the `Solarpunk` folder (or its `Binaries\Win64`) |
| `--skip-pak` | Lua mod only — no wands, no codex |
| `--no-vcredist` | don't check for / install the Visual C++ runtime (Windows) |
| `--vcrun` | Linux: also run `protontricks 1805110 vcrun2022` now |
| `--force` | reinstall the UE4SS core even if it's already there |
| `--uninstall` | remove the mod and the content pak (leaves UE4SS in place) |

</details>

**Updating:** `git pull` (or unzip the newer release) and run `python install.py` again — it's
idempotent, and it leaves your config and mod save alone.

**Multiplayer:** Solarpunk co-op is a host-authoritative listen server. All the logic runs on the
host, so **every player in the session needs this same install**. Unmodded clients are unsupported.

**Network access:** none, with one exception — on a Windows machine that's missing the
Visual C++ 2015-2022 runtime (which UE4SS links against), the installer fetches Microsoft's
installer from `aka.ms` and runs it. Skip that with `--no-vcredist`.

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

| | |
|---|---|
| **P** | toggle the storm (`sps_storm` / `sps_storm_off`; `sps_auto` re-enables hunting auto-strikes) |
| **V** | draw / stow the wand |
| **left click** (wand drawn) | cast — a bolt where you look, or a pour / a drink for a teammate |
| **F7** | in-game config panel |

Other console commands: `sps_wand` (state, `forge`/`soak`/`charge`/`give`), `sps_codex`,
`sps_repair`.

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
