# Solarpunk Survival

A co-op **total-conversion mod** that turns [Solarpunk](https://store.steampowered.com/app/1805110/Solarpunk/)
(Cyberwave, Unreal Engine 5) from a cozy builder into a survival / base-defense
experience: **deadly storms & lightning, destructible structures, defense buildings,
enemies, and weapons** — all working in co-op.

Built with [UE4SS](https://docs.ue4ss.com/) (Lua scripting + Blueprint hooking).

> ### ⚠️ Status: pre-alpha scaffold
> The **core framework and all storm/lightning/destruction logic are implemented**, but
> they are **mapping-driven** and the game-specific hooks are **not yet filled in**.
> On first run the mod loads safely, detects your game build, and prints the exact list of
> game symbols it still needs (see [`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md)).
> **It does not change gameplay yet** — it will once `Scripts/mapping.lua` is populated from a
> UE4SS dump of the current build.

---

## What's in Milestone 1 (Deadly Storms)

| Feature | Behavior |
|---|---|
| **Frequent, telegraphed lightning** | Strikes far more often, sometimes in bursts of 2–3. A glowing ground decal warns ~1.2 s before impact — move or take it. |
| **Player strike** | **70 % max HP** per hit, so a double strike is lethal. Dodgeable via the telegraph. Death → respawn at base, drop carried items. |
| **Per-target effects** | Crop → killed, no seed. Battery → fully charged. Drill/sprinkler → smokes, breaks if struck again unrepaired. Airship in flight → −1/3 HP, crashes at 0. |
| **Lightning Rod** (new build) | 25 m range; redirects every strike in range to itself. Link to a battery to charge it from storms. |
| **Storm Repair Tool** (new item) | Cheaper clone of the ship-repair item; clears the "smoking" damaged state. |
| **Destruction** | Only strikes damage structures (no passive erosion). Destroyed pieces drop partial salvage. |

All numbers are tunable at runtime — see [`mod/SolarpunkSurvival/config/config.default.json`](mod/SolarpunkSurvival/config/config.default.json).
New items/buildings register into the game's existing unlock system.

Full design & roadmap: [`docs/DESIGN.md`](docs/DESIGN.md).

## Multiplayer

Solarpunk co-op is a **host-authoritative listen-server**. This mod runs all authoritative
logic on the host and replicates to clients, so **every player in the session must install the
same version of the mod**. Unmodded clients are unsupported.

## Requirements & install

1. Install **UE4SS** for Solarpunk (the Solarpunk-patched build — see `docs/INSTALL.md`).
2. Copy `mod/SolarpunkSurvival/` into your UE4SS `Mods/` folder.
3. (Later) Copy the LogicMod paks into `Solarpunk/Content/Paks/LogicMods`.

Detailed steps: [`docs/INSTALL.md`](docs/INSTALL.md).

- **Tested game build:** `24038177` (Steam App 1805110)
- Because Solarpunk has no official mod API, **game updates can break this mod** until it is
  re-mapped. See [`docs/RELEASE-CHECKLIST.md`](docs/RELEASE-CHECKLIST.md).
- **Back up your save** before playing — the mod adds persistent state.

## Contributing / reverse-engineering

The only thing standing between the scaffold and a playable build is filling in
`Scripts/mapping.lua` from a UE4SS dump. Start at [`docs/REVERSE-ENGINEERING.md`](docs/REVERSE-ENGINEERING.md).

## License

MIT — see [`LICENSE`](LICENSE). This project ships **no** Solarpunk game files, assets, or symbols.
