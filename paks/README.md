# Cooked content paks

The Lua mod stays engine-version-agnostic; anything Lua can't produce is a small, single-purpose
cooked `.pak`. These require the **Unreal Editor** (matching the game's UE version) to cook and are
**not** checked in as source here — only the built `.pak` outputs are distributed with releases.

## LogicMods (Blueprint-only, replication carriers)

Install to `...\Solarpunk\Content\Paks\LogicMods\`:

| Pak | Contents | Why |
|---|---|---|
| `BP_ModStateActor.pak` | `AActor`, `bReplicates=true`, replicated vars (storm severity, difficulty) + `Multicast_*` / `Server_*` CustomEvents (`Multicast_Telegraph`, `Multicast_Bolt`, `Multicast_Smoke`, `Multicast_Destroy`, `Multicast_PlayerHit`, `Multicast_AirshipCrash`, `Server_RequestDamage`) | Lets Unreal replicate custom state/effects to clients natively; Lua fires the events. |
| `BP_HealthState.pak` | replicated component (`Health`, `MaxHealth`, `bDestroyed`) | Per-actor HP visible to clients. |
| `BP_LightningRod.pak` | rod mesh + build piece (`BP_LightningRod_C`) | The buildable Lightning Rod. |

Until these exist, `net.lua` runs single-player / degraded (no client sync of custom state), and the
Lua event names above are the contract the Blueprints must implement.

## Content paks

Install to `...\Solarpunk\Content\Paks\~mods\`. Reserve for meshes/materials/VFX/UMG that can't be
reused from the game. Milestone 1 deliberately **reuses** the game's ship-damage smoke and vanilla
demolish VFX, so the content-pak surface is intentionally near-zero.
