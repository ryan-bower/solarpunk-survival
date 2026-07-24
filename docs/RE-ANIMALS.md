# Reverse engineering: the animal system

Source: offline dump of the game's animal Blueprints (build 24038177) via
`wandsmith tojson` over `tools/pakkit/legacy/Solarpunk/Content/Code/Animals/`
(2026-07-23). Names below are confirmed from cooked assets, not guessed.
Byte values for the user-defined enums are inferred from the cooked
name→value tables and should be sanity-checked live once (see the
verification list at the bottom).

## Class layout

```
BP_Animal_MASTER_C                     /Game/Code/Animals/Chicken/BP_Animal_MASTER
├─ BP_Animal_Chicken_C                 /Game/Code/Animals/Chicken/BP_Animal_Chicken
├─ BP_Animal_Sheep_C                   /Game/Code/Animals/Chicken/BP_Animal_Sheep   (misfiled in Chicken/)
└─ BP_Animal_Pig_C                     /Game/Code/Animals/Chicken/BP_Animal_Pig
```

All three species BPs live in the `Chicken/` folder. The master is a
**Character**: `CharMoveComp` (CharacterMovementComponent), `CharacterMesh0`,
an **AudioComponent** (`S_Chicken_NoLicense_GEN_VARIABLE` template),
`NavigationInvoker`, `BPC_InteractableLogic`, a `ChickenRadius` sphere and a
stack of TextRender components (name plank + needs debug text).

## AI

```
AIC_Master_C : DetourCrowdAIController   (AIC_Chicken_C / AIC_Sheep_C / AIC_Pig_C per species)
  ReceivePossess -> RunBehaviorTree(BT_Master) + seed blackboard from props
  props: LureDistance, IdleRadius, FoodSourceLocateRadius, ResourceLocateRadius,
         ShelterSearchRadius, ConsumeDuration, PickDuration, StandingDuration, AnimalType
```

Native pathfinding (PathFollowingComponent + CrowdFollowingComponent) — the
native `MoveToActor`/`MoveToLocation` family works on it, and
`BrainComponent` (`StopLogic`) is reachable from the controller.

**Blackboard `BB_Animals` keys** (exact spellings, `?` included):
`SelfActor, IdleWalkTarget, FollowTarget, IdleRadius, LureRadius,
ShelterSearchRadius, HomeShelter, Hunger, Water, Shelter, WaterSource,
FoodSource, Socialability, ResourceLocateRadius, Hungriness, Thirstiness,
LastThirstCheck, LastHungerCheck, AnimalType, IsInTransport?, IsInShelter?,
ShelterSleepLocation, Montage, PickDuration, ConsumeDuration,
StandingDuration`

**Enums** (display name = cooked byte value):

| enum | values |
|---|---|
| `EnumAnimalState` | 0 Sleeping, 1 RandomRoam, 2 TakeShelter, 3 Chasing, 4 EatDrink |
| `EAnimalMontage` | 0 Consume, 1 Walk, 2 Stand, 3 Sleep, 4 Pick |
| `EAnimalSpeed` | 0 Walk, 1 Run, 2 Sprint |
| `EAnimal` | Chicken, Sheep, Pig |

**Lure flow** (`SBT_Lure`): `BTD_ValidLuringTarget` + `BTD_ModifyWalkSpeed`
decorators over `BTTask_RunEQSQuery(EQS_FindLuringPlayer)` → sets
`FollowTarget` → `BTTask_MoveTo(FollowTarget)`. `BTD_ValidLuringTarget`
re-validates `PlayerHoldingItem(LuringItem)` + `PlayerInLuringDistance`
continuously, so writing `FollowTarget` from outside does NOT stick — the
decorator clears it unless the target player actually holds the lure item.
Per-species `LuringItem`: sheep = `BP_Corn_Item_C` (confirmed in the cooked
default); chicken = wheat, pig = carrot (wiki + gameplay confirmed).

**Speed**: `BTD_ModifyWalkSpeed` saves `OriginalMoveSpeed`, writes
`CharMoveComp.MaxWalkSpeed` (value selected by `EAnimalSpeed` ×
`AnimationSpeed`), and restores on branch exit. While the BT runs it fights
external MaxWalkSpeed writes; after `StopLogic` the value is ours.

**Montages**: `BTT_PlayMontage` does not play an asset — it sets the
blackboard `Montage` enum + a duration timer; the species AnimBP
(`AnmBP_Sheep_C`, chicken equivalent) renders the state. The lie-down visual
is `Sleep` (montage assets on disk: `M_Chicken_Sleeping` etc.).

## Replication (the interesting part for MP)

`BP_Animal_MASTER_C` replicated properties (CPF_Net):

| prop | type | note |
|---|---|---|
| **`Name`** | StrProperty | the animal's display name — host-writable, replicates to all clients |
| `ReplicatedShelterValue` | Double | needs mirror for UI |
| `ReplicatedThirstinessValue` | Double | needs mirror for UI |
| `ReplicatedHungrynessValue` | Double | needs mirror for UI |
| `PlacementID` | Int | save/placement id |

`Name` is the mod's cross-client side channel: the host encodes state in the
name; every client's mod reads it and applies local-only FX. Vanilla renders
the name on the plank; keep encoded names presentable.

## No health

Animals have **no health, no damage interface, no kill function** — nothing
in the master BP. Any hit-points system must be mod-side (`core/health.lua`),
with `K2_DestroyActor` as the only kill (replicates natively).

## Sounds

`/Game/Audio/SFX/Animals/`: `S_Sheep_1..6`, `S_Chicken_01..07`,
`S_Chicken_Scream` (+ `S_Chicken_NoLicense` component template). The master
BP's own `SoundLoop` plays `AnimalSounds` via `PlaySoundAtLocation` with an
explicit pitch argument. Each animal instance carries an AudioComponent —
`SetPitchMultiplier` on it is a per-client, safe, existing-component call.

## Meshes / materials

`SKM_Sheep_Skeletal` and `SKM_Chicken_Rig` each have exactly **one material
slot** (`M_Sheep` / `M_Chicken` in `/Game/Art/Animations/<species>/`).
Eye-only material work is impossible without authoring a new mesh/material —
runtime looks are whole-body `SetMaterial(0, ...)` swaps.

**A RED body is engine-blocked (proven, not guessed).** A skeletal mesh renders
any material lacking the compiled `bUsedWithSkeletalMesh` flag as the black
engine Default Material — the flag bakes a skeletal shader permutation offline
and cannot be set at runtime in a shipping build. Cooked-asset dumps
(`wandsmith tojson`) of every red/fire/energy candidate — `M_Preview_Red`
(also translucent), `M_Plant_Tomato`, `M_Campfire`, `M_CandleFlame`,
`M_Fire_VFX`, `M_Energy_On`, `M_Watertrough_Energy`, … — show **none** carry the
flag, so each renders black on the sheep/chicken. `M_Sheep` *does* carry it (it
renders) but the cooked material exposes **no** scalar/vector parameter, so a
runtime `MID` can't tint it either. Net: `SetMaterial(0, <red>)` on an animal is
always black. The menace-red is therefore delivered as a **spawned movable red
`PointLight` that trails each living Unlit** (light colour *is* runtime-settable),
not as body colour — see `evil_glow_*` in `core/config.lua` and `spawnGlow` in
`features/evil_animals.lua`.

## Husbandry layer (context)

Items/buildables (DB_Items / DB_Buildables): `AnimalFeed` →
`BP_FoodTrough_Buildable_C`; species shelters
`BP_AnimalShelter_{Chicken,Sheep,Pig}_Placeable_C`; products egg/milk/truffle
gated on `IsHappy`; `BP_AnimalReciever_Placeable_C` carries an `AnimalSpawn`
component (vanilla spawn anchor). `AnimalTag` renames (feeds the replicated
`Name`). Tool rows for damage tiers: `Pickaxe/Axe/Hoe` (base),
`{Pickaxe,Axe,Hoe}Metal`, `{Pickaxe,Axe,Hoe}Diamond`, `*_Kickstarter`
cosmetic variants.

## Live verification checklist (first in-game run)

- [ ] Enum byte order above (set BB `Montage=3`, expect Sleep pose on host).
- [ ] `StopLogic` reachable: `animal:GetAIController().BrainComponent:StopLogic("evil")`
      (fallback: `StopBehaviorTree`, or `BrainComponent:PauseLogic`).
- [ ] `MoveToActor` callable via reflection on AIC_*_C and respects nav.
- [ ] Whether clients see the Sleep montage without help (AnimBP may read
      server-only blackboard → likely NOT; then clients do it locally off the
      Name beacon).
- [ ] `AnimationSpeed` interplay when MaxWalkSpeed is raised (sliding feet?).
- [ ] `WorldSAVE_AddSavedAnimal` — do spawned animals auto-register into the
      game save? If yes, find the guard (`IsOwned`/`IsStartAnimal`?) so evil
      spawns never persist.
