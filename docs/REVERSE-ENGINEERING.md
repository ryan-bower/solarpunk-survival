# Reverse-Engineering Checklist

This is the gate for everything: until these game symbols are found and written into
`mod/SolarpunkSurvival/Scripts/mapping.lua` (profile for build `24038177`), the mod loads but changes
nothing. Each row maps to a key in `mapping.lua`. The running mod prints exactly which of these are
still `nil`.

## How to dump

1. Install the Solarpunk-patched UE4SS (see `INSTALL.md`).
2. Enable dumpers in `UE4SS-settings.ini` (`GUObjectArrayDumper`, `CXXHeaderGenerator`) and launch.
3. Use the **Live View** (ImGui → Object Dumper / Live View) to watch instances change at runtime —
   e.g. force a storm and watch which object's fields change.
4. Save CXX headers + object dumps into `dumps/<buildid>/` (git-ignored) and run
   `python tools/dump-diff.py dumps/<old> dumps/<new>` after each game patch.

## Symbols to find

| `mapping.lua` key | What | How to find | Status |
|---|---|---|---|
| `weather.managerClass` | Weather/storm manager actor class | Search dumps for `Weather`/`Storm`/`Climate`/`Sky`; confirm in Live View during a storm | ☐ |
| `weather.currentProp` | Property holding current weather / storm state | Watch it flip when a storm starts | ☐ |
| `weather.severityProp` | Storm intensity (0–1 or enum) | Live View during light vs heavy storm | ☐ |
| `weather.onChangedFn` | UFunction fired on weather change (hook target) | Look for `SetWeather`/`OnWeatherChanged`; else poll `currentProp` | ☐ |
| `pawn.class` | Player pawn/character class | Live View on local player | ☐ |
| `pawn.healthProp` | Vanilla health, if any (else framework-only) | Likely **none** (cozy game) — confirm | ☐ |
| `pawn.isShelteredFn` | Signal for "under a roof / indoors / in airship" | Look for shelter/roof/indoor checks; may need a sky trace fallback | ☐ |
| `pawn.worldLocationFn` | Get pawn world location | Standard `K2_GetActorLocation` | ☐ |
| `pawn.respawnFn` | Respawn/teleport-to-base path | Search `Respawn`/`Sleep`/`Bed`/`Teleport` | ☐ |
| `pawn.dropInventoryFn` | Drop carried items on death | Search inventory/drop functions | ☐ |
| `build.pieceClass` | Base class of placed build pieces | Live View on a placed wall/floor | ☐ |
| `build.stableIdProp` | Save/network-stable id on a piece (if any) | Look for a GUID/save-id field; else derive from transform | ☐ |
| `build.demolishFn` | **Vanilla demolish/remove path** (preferred destruction) | Search `Demolish`/`Dismantle`/`RemoveBuildable` | ☐ |
| `build.demolishRefund` | Does demolish refund materials? (for salvage) | Inspect demolish function / inventory delta | ☐ |
| `crop.class` | Crop/plant actor class | Live View on a planted crop | ☐ |
| `crop.killNoSeedFn` | Remove crop without dropping a seed | Compare harvest vs destroy paths | ☐ |
| `battery.class` | Battery/energy-storage actor | Live View on a battery | ☐ |
| `battery.chargeProp` | Current charge property (set to max on strike) | Watch it change while charging | ☐ |
| `battery.maxChargeProp` | Max charge | Same object | ☐ |
| `machine.classes` | Drill/sprinkler/powered-machine classes | Live View on each | ☐ |
| `airship.class` | Airship/vehicle actor | Live View while boarding | ☐ |
| `airship.healthProp` | Airship HP (framework may own this) | Likely framework-only | ☐ |
| `airship.isFlyingFn` | Airborne vs docked signal | Watch a field while taking off | ☐ |
| `airship.crashFn` | Forced-descent / disable-on-crash path | May be framework-implemented | ☐ |
| `island.class` | Island/landmass actor (for distance-to-land) | Live View / FindAllOf on islands | ☐ |
| `unlock.registerFn` | Register a new unlockable into the progression system | Search unlock/research/tech data tables | ☐ |
| `craft.repairItemId` | The existing **ship-repair item** id/recipe (to clone cheaper) | Search item/recipe data tables | ☐ |
| `craft.addRecipeFn` | Register a new craftable item/recipe | Same tables | ☐ |
| `buildmenu.registerFn` | Add a new buildable to the build menu | Search build-menu registry | ☐ |
| `energy.linkFn` | Link a structure (rod) to a battery on the power net | Search energy-network connection code | ☐ |
| `smoke.shipDamageVfxFn` | The ship's existing **damage/smoke VFX** trigger (reuse on structures) | Damage the ship and watch the effect component | ☐ |
| `net.hasAuthorityFn` | Authority / net-mode accessor (host vs client) | `HasAuthority` / `GetNetMode` / `UKismetSystemLibrary.IsServer` | ☐ |
| `net.playerStateClass` | PlayerState class (RPC ownership + mod handshake) | Live View | ☐ |
| `save.saveFn` / `save.loadFn` | Game save/load UFunctions to hook | Search `SaveGame`/`GameInstance` save path; hook and log | ☐ |

Tick each box in `mapping.lua` as you fill it in. Anything left `nil` simply disables its feature.
