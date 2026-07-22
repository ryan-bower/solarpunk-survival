# Milestone 2 — Storm Interactions (spec + implementation notes)

Verbatim goals from the user (2026-07-21), with implementation decisions. Everything must work
host-authoritatively in co-op MP. **No code review until the user asks.**

## 1. Player struck by lightning
> take damage and should not be able to move for 3 seconds, their character goes into T pose,
> they see white on their screen for 2 seconds while the electricity buzz sound plays, then
> screen slowly fades back to normal.

- Damage: host calls the game's own `Reduce Health` on the victim's controller (native death/loot).
- FX are **client-local on the victim's machine**, triggered by hooking `CLIENT_ReduceHealth` —
  the game's own client-RPC that fires exactly on the owning client when they take damage. Damage
  >= `fx_min_damage` (default 40) is treated as a lightning hit. This is MP-correct with no custom
  replication: every machine runs the mod; only the victim's machine sees the RPC.
- Immobilize: `SetIgnoreMoveInput(true)` for `stun_seconds` (3).
- T-pose: victim pawn's Mesh -> `SetAnimationMode(AnimationSingleNode)` with no asset (= ref pose),
  restored to `AnimationBlueprint` after the stun.
- Whiteout: `PlayerCameraManager:StartCameraFade` to solid white, hold `whiteout_hold` (2 s), then
  slow fade back over `whiteout_fade` (2.5 s).
- Buzz: no electricity cue found in captures yet — plays the weather manager's `ThunderSound`
  2D at high pitch as the crackle. Swap to a proper cue when one is found (mapping fx.buzzSound*).

## 2. Lightning vs world objects (on bolt impact, host-side, radius = strike_radius)
> battery or generator -> charges to 100%. furnace -> powered as if it consumed a wax briquette.
> any other tech -> smoking and "broken", repair with repair kit; struck again before repair ->
> destroyed, drops half its crafting components. tree -> falls, drops 4 wood + its sapling.

- World targets are discovered at impact time by scanning live actors and classifying by class
  name (machine classes were not in the RE capture — they live in uncaptured parent classes):
  - `Battery` / `Generator|Windmill|SkyTurbine|Solarpanel` -> charge-to-full: probes candidate
    charge props (`mapping.battery.chargePropCandidates`) and sets to max (candidate max props,
    else 100).
  - `Furnace|Furnance` -> briquette-equivalent: probes candidate fuel props/functions
    (`mapping.furnace.*Candidates`). Until verified live this may no-op (logged).
  - other `_Buildable_C`/`_Placeable_C` tech (excl. candles/fences/deco/signs) -> health registry
    twoHit: 1st strike = damaged ("smoking": ship-damage VFX when mapped, else bolt VFX only),
    2nd strike before repair = destroyed + **half its crafting components** granted to the nearest
    player's inventory (curated `mapping.machine.salvage` table; DataTable recipe structs can't be
    read safely from Lua). Repair via the existing repair-tool service (`sps_repair` console cmd
    aims at the nearest damaged structure) until the repair item's use-action is mapped.
  - `BP_Tree_*` -> felled: destroys the tree actor (replicates natively) + drops 4x log + 1x
    matching sapling item (class-name match Birch/Alder/Maple/Pine/Oak) into the nearest player's
    reach (spawned via `DEBUG_SpawnItems` on the nearest controller — ground-drop via
    `SpawnLeftoverItem` needs its struct layout, still unmapped).

## 3. Lightning rod
> on a pole, use the weather vane for reference... looks like that weather station but with the
> copper item vertical at the top. strikes in a 25 m area redirect to the pole's ground position.
> can be built on top of batteries. part of weather tech unlock.

- **The game's Weather Station buildable IS the rod** (a vane on a pole, already researchable in
  the weather-tech group, already placeable next to/on batteries) — a brand-new cooked mesh cannot
  be authored from UE4SS Lua. Cosmetic best-effort: a Copper item actor is attached vertically at
  the pole top of each detected station (`rod_copper_topper`, on host; replicated as an actor).
- Redirect: before a strike telegraphs, if its target point is within `lightning_rod_range`
  (2500 uu = 25 m) of a placed Weather Station, the strike is retargeted to the rod's ground
  position. Rod strikes charge the nearest battery within 3 m (`rod_charges_battery`).

## 4. Dark-arts ritual (the way you "craft" a lightning rod)
> bring a lamb or sheep as sacrifice... book that guides you on the dark arts... pentagram of
> fences with LIT candles on the tips (just check 15 fences and 5 LIT candles in 20 m around the
> sheep) and hold the mundane wand (1 cobalt 1 stick, unlocked late). during a storm lightning
> targets the spot, transforms anyone holding a mundane wand in the 20 m radius [their wand
> becomes a lightning rod] and kills the sheep.

- Ritual check runs host-side only while a storm is active (chained one-shot delays, every ~8 s —
  never a free-running UObject timer). Conditions: a live `BP_Animal_Sheep_C` with >= 15 fence
  actors (class name contains `Fence`) and >= 5 candle buildables in ANY state (class contains
  `Candle`) within 20 m (2000 uu). **Lit is deliberately NOT required** — the storm's rain snuffs
  candles, which would make the rite impossible in the weather it needs (user rule change
  2026-07-21). Verified live: 27x `BP_WoodenFence_Buildable_C` + 5x `BP_Candle_Plate_Buildable_C`
  detected, ritual strike + sacrifice completed.
- While satisfied: storm strikes target the sheep. On impact: sheep is sacrificed (bolt +
  destroy — no kill function known for animals yet), and every player within 20 m receives the
  payout: a **Lightning Wand (charged)** — newly forged if they owned none, charged in place if
  they did; lore lines narrate the rite.
- **The wand is now a REAL cooked inventory item** (2026-07-21, `tools/pakkit`). The earlier
  "Lua can't mint an item ID" limitation is LIFTED by a content pak: `MundaneWand` +
  `ElectricWand` are added to the game's `DB_Items` DataTable and shipped with two new
  item-actor Blueprints, all cooked offline (retoc + UAssetAPI, no Unreal Editor). Install as
  `Solarpunk-Windows_1_P.{utoc,ucas,pak}` in `Content/Paks` (Order 204 > the base 104, so the
  DataTable override wins). Live-proven: clean boot, 311 rows, both wands present, item class
  resolves from the pak. Grant with `sps_wand give [mundane|electric]`. See
  `tools/pakkit/HOWTO.md` for the build + the retoc row-key name-index gotcha.
- **A brand-new item CANNOT be a first-class hand tool from pak data alone.** Giving the wand
  the Hoe-type taxonomy (`ItemType [1,0]` + durability) — which would earn it the game's real
  in-hand grip and material — pulls it into the compiled tool-integration path, which expects
  uncooked tool/shader data that only exists for the game's built-in tools, and **crashes world
  load** ("Tried to access an uncooked shader map ID in a cooked application"). The row itself
  loads fine (DataTable = 311); the crash is a background worker after load. So the cooked item
  is a **Repairkit/resource-type** row (loads clean, equips) and the **mod supplies the in-hand
  look** (next bullet). Do not re-attempt the Hoe-type row — proven fatal (commit `109fcd9`).
- **THREE cooked wand items, one per state, each a distinct-colored stick in the inventory**
  (user spec 2026-07-21): `MundaneWand` = **dark brown**, `ElectricWand` (spent) = **blue**,
  `ChargedElectricWand` = **white**. Each icon is the vanilla 256×256 `Icon_Stick` (uncompressed
  PF_B8G8R8A8) recolored by a luminance→tint ramp and staged as a NEW texture (`Icon_StickBrown`
  / `_Blue` / `_White`) — never an override of `Icon_Stick`, which would tint every real stick.
  See `build_wand_pak.py::make_icons`. Grant any with `sps_wand give mundane|electric|charged`.
  Row keys are placed by their **sorted position inside `DB_Items`'s alphabetical key block** (NOT
  at the DB_Items boundary — retoc prunes the boundary name; see HOWTO / the toolchain memory).
- **The mod draws the stick+cobalt rig off the REAL equipped item** (`wand_from_item`, default
  on): on `HotbarSlotChanged`, `equippedWandKind` reads `CurItemdataInHand`'s **`ItemActor`**
  member (the item's UClass, e.g. `BP_MundaneWand_Item_C`) and matches it to a wand row — the
  robust identity (RE probe: `GetCurrentHoldItem` has out-params and the struct's `DisplayName`
  reads EMPTY at runtime, so neither is usable; the S_Item struct members carry GUID suffixes, so
  the real names are discovered once by walking the struct type). When it is our wand it seats the
  approved rig in that item's look (brown=cobalt, blue=diamond, white=diamond+crackle); switching
  away stows it. Kill-switch `wand_from_item=false` reverts to the V-key/ritual-only draw.
  **Not yet live-confirmed:** the rig appearing on equip (the first detection attempt drew nothing
  because the old code read the unusable fields; the ItemActor fix is unverified in-world).
- **The mod-managed rig still exists in parallel** (state machine Mundane -> charged ->
  uncharged in `features/wand.lua`; draw/stow with **V**; forged tip wears the Diamond material,
  charged adds a Niagara crackle; cast = generic left click `PressedHandInteraction` /
  `IA_HandInteract`, empty hands, any weather). Now that the real item exists, the rig's job
  narrows to the cast/charge behavior; the in-hand look can come from the real item once its BP
  carries the cobalt tip. Not yet wired: ritual grants the real item; real item casts.
- **The wand BEHAVES like the game's own tools** (2026-07-21, "act like a tool item" pass). RE
  capture: a held tool = its mesh in two right-hand slot components on the pawn
  (`Mesh_Slot_1Person_Hand_R` / `Mesh_Slot_3rdPerson_Hand_R`, set via `SetHandRMeshForBoth`),
  with `StashHandItem`/`RestoreHandItem` parking the held item and `HotbarSlotChanged` firing on
  tool switches. Drawing the wand stashes the held item (game's own stash — survived live);
  stowing restores it; picking a hotbar tool auto-stows the wand. The rig (stick + cobalt tip at
  0.75 scale, seated at the stick's far end **computed from mesh bounds**) is built from our own
  pawn-root components and **auto-seated at the hand slot's world position (read-only)**.
  **Maiden flight 2026-07-21 12:22 proved `K2_AttachToComponent` (component→component, tip →
  hand slot) is a NATIVE CRASH** — same family as actor attach; the step log
  (`dump/wand_steps.txt`) named it on the first try. The slot mesh-set call itself survived but
  is unused for now (a slot-held stick would animate away from a root-held tip). Kill-switch
  `wand_in_hand=false` = fixed capsule offsets, no stash. Player identity keys off the game's
  `UniquePlayerID` (pawn + controller) — the old location-derived fallback id drifted as the
  player walked, silently orphaning wand state.
- **Dark-arts book** = `Handbook` item as the physical prop + `docs/DARK-ARTS.md` ritual guide +
  in-game lore via log lines when the ritual stages fire.

## 5. Test staging (user's save)
- Pentagram center (user's candle pentagram): **X=6506 Y=-1165 Z=-5221**.
- `sps_ritual_test` console command (and staged auto-run via the remote channel on next launch):
  gives 1 Handbook, teleports the player to ~6 m from the center, spawns a sheep at the center
  (the wand is forged by the ritual itself). No-ops safely in menus; auto-run rearms itself until
  a world is loaded. `sps_wand forge|charge|draw` covers wand-only testing.

## MP notes
- All authoritative logic behind `ctx.net.isHost()`. Victim FX ride the game's own
  `CLIENT_ReduceHealth` RPC. World changes (destroy/spawn/charge) are host-side on natively
  replicating actors. `ctx.net.multicast` stays a no-op until the BP carrier pak exists — nothing
  in M2 depends on it.

## Strike timing (2026-07-21)
- A strike is two stages: bolt actor spawn (its BeginPlay timeline shows the ground telegraph) and
  the **big strike frame** `bolt_impact_delay` (default 1.5 s) later. Damage, world effects, the
  ritual sacrifice, and rod grounding all land at the strike frame — leaving `strike_radius` during
  the telegraph is a real dodge (pawns are re-scanned at impact).
- **Native lightning tap**: every `BP_LightningPlayer_C` the *game* spawns (vanilla storm strikes,
  which carry the game's own player damage) triggers our world effects at its strike frame too —
  batteries charge, trees fall, tech breaks under natural lightning. No extra player damage is
  added (vanilla already hurts); our own bolts are excluded via a spawn-id set.

## Known approximations to revisit (next live session)
- ~~`bolt_impact_delay` estimate~~ MEASURED live 2026-07-21 by hooking the bolt's timeline event
  functions: `Timeline__NewTrack_2__EventFunc` (the explode) fires at **+1.97 s** after BeginPlay,
  `NewTrack_0` at +2.07 s, Finished at +2.68 s. Default set to 2.0 s.
- Machine/furnace/battery prop names: candidate-probed; capture a dump at the player's base to pin
  them (`sps_dump`).
- Candle lit-prop name; fence class names.
- Sheep kill anim (currently destroy), tree fell anim (currently destroy + drops).
- Book is a stand-in (Handbook). ~~The wand needs a cooked pak for a true inventory item~~ DONE
  (`tools/pakkit`): the wand is a real item now, with a blue inventory icon, and the mod draws the
  rig when it is equipped (see the wand bullets in §4). Remaining wand polish: the ritual/forge
  still grants the mod rig state, not the real item into inventory; the real item doesn't yet
  drive the cast/charge state (casting is still the V-drawn path). The rig is hand-SEATED but
  root-attached (no safe recipe for a mesh that FOLLOWS the hand: slot attach crashes, per-tick
  follow = the timer gotcha), so it sits at the hand's rest pose rather than tracking finger
  animation. Wand states are not persisted across restarts. **Not yet live-confirmed:** the
  held-item detection (`GetCurrentHoldItem`/`CurItemdataInHand`) — verify the rig appears on equip
  and the stale hand mesh clears; if the stale mesh persists, add an explicit empty-hands call.
- Buzz sound is pitched thunder until a real electricity cue is found.
- Ground-drop of salvage/loot uses nearest-player inventory until `SpawnLeftoverItem`'s struct is
  mapped.
