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
  actors (class name contains `Fence`) and >= 5 lit candle buildables (class contains `Candle`;
  lit-state probed from candidate bool props, presence counts as lit until the prop is verified)
  within 20 m (2000 uu).
- While satisfied: storm strikes target the sheep. On impact: sheep is sacrificed (bolt +
  destroy — no kill function known for animals yet), and every player within 20 m holding the
  wand gets a Weather Station (lightning rod) item; lore lines narrate the rite.
- **Mundane wand** = `HoeDiamond` stand-in (holdable, already gated late in the tech tree). A real
  new item (1 Cobalt + 1 Stick recipe) needs a cooked pak — documented as future work; the
  recipe/unlock functions (`UnlockResearch`, `Playerdata_AddUnlockedRecipyForSelf`) only toggle
  EXISTING entries.
- **Dark-arts book** = `Handbook` item as the physical prop + `docs/DARK-ARTS.md` ritual guide +
  in-game lore via log lines when the ritual stages fire.

## 5. Test staging (user's save)
- Pentagram center (user's candle pentagram): **X=6506 Y=-1165 Z=-5221**.
- `sps_ritual_test` console command (and staged auto-run via the remote channel on next launch):
  gives 1 wand (HoeDiamond) + 1 Handbook, teleports the player to ~6 m from the center, spawns a
  sheep at the center. No-ops safely in menus; auto-run rearms itself until a world is loaded.

## MP notes
- All authoritative logic behind `ctx.net.isHost()`. Victim FX ride the game's own
  `CLIENT_ReduceHealth` RPC. World changes (destroy/spawn/charge) are host-side on natively
  replicating actors. `ctx.net.multicast` stays a no-op until the BP carrier pak exists — nothing
  in M2 depends on it.

## Known approximations to revisit (next live session)
- Machine/furnace/battery prop names: candidate-probed; capture a dump at the player's base to pin
  them (`sps_dump`).
- Candle lit-prop name; fence class names.
- Sheep kill anim (currently destroy), tree fell anim (currently destroy + drops).
- Wand/book/rod-item are stand-ins (HoeDiamond / Handbook / Weather_Station).
- Buzz sound is pitched thunder until a real electricity cue is found.
- Ground-drop of salvage/loot uses nearest-player inventory until `SpawnLeftoverItem`'s struct is
  mapped.
