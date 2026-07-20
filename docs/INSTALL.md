# Install

> For a private co-op group: **every player must install the same mod version.** The host runs all
> authoritative logic; unmodded clients are unsupported.

## 1. Install UE4SS for Solarpunk

This mod requires **UE4SS** (Unreal Engine Scripting System). Use the **Solarpunk-patched build**
so its symbol scanning matches the game.

- Get it from the Solarpunk mod hub (e.g. the "UE4SS" entry) or build official UE4SS against this game.
- Solarpunk's shipping binary is:
  `...\steamapps\common\Solarpunk\Solarpunk\Binaries\Win64\SolarpunkSteam-Win64-Shipping.exe`
- Install UE4SS into that **`Win64`** folder (so `dwmapi.dll` / `UE4SS` sit next to the exe),
  following the UE4SS install guide. Launch the game once and confirm the UE4SS console opens.

> The game ships its full `SolarpunkSteam-Win64-Shipping.pdb` next to the exe, which lets UE4SS
> resolve symbols reliably — keep it in place.

## 2. Install this mod

Copy the mod folder into the UE4SS `Mods` directory that UE4SS created:

```
...\Win64\ue4ss\Mods\SolarpunkSurvival\      <-- copy mod/SolarpunkSurvival/ here
        ├─ enabled.txt
        ├─ Scripts/
        └─ config/
```

(The exact `Mods` path depends on your UE4SS version/layout — it's wherever `Mods/mods.txt` or other
`Mods/<Name>/enabled.txt` mods live.)

## 3. (Later) Install the LogicMod paks

Once cooked, copy the replication carriers to:

```
...\Solarpunk\Content\Paks\LogicMods\BP_ModStateActor.pak
...\Solarpunk\Content\Paks\LogicMods\BP_HealthState.pak
```

Until these exist, the mod runs in single-player / degraded (no client sync of custom state).

## 4. First launch

Open the UE4SS console. `SolarpunkSurvival` prints its version, the detected game build, and — until
`Scripts/mapping.lua` is populated — a checklist of the game symbols it still needs. That checklist is
the reverse-engineering to-do list (see `REVERSE-ENGINEERING.md`).

## Configuration

Edit `Mods/SolarpunkSurvival/config/config.json` (copy from `config.default.json`) or use the in-game
ImGui panel (default toggle key: **F7**). The host's balance values are authoritative in co-op.

## Uninstall

Delete the `SolarpunkSurvival` mod folder and the two LogicMod paks. Back up your save first — the mod
adds persistent state to the host save.
