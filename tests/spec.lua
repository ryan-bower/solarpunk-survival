-- Headless unit tests for the game-independent logic. Run from the repo root:
--   lua tests/spec.lua
-- Stubs the UE4SS globals + the game-facing modules so the pure logic (json, eventbus, config,
-- mapping, gate, health/damage math) can be verified without the game.
local ROOT = "mod/SolarpunkSurvival/Scripts/"
package.path = ROOT .. "?.lua;" .. package.path

-- --- stub UE4SS globals (referenced at load/runtime) ---
_G.FindFirstOf = function() return nil end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end
_G.NotifyOnNewObject = function() end
_G.RegisterKeyBind = function() end
_G.RegisterConsoleCommandHandler = function() end
_G.LoopAsync = function() end
_G.ExecuteWithDelay = function() end
_G.Key = setmetatable({}, { __index = function() return 0 end })

local passed, failed = 0, 0
local function ok(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
  ok(a == b, (msg or "eq") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

------------------------------------------------------------------ json
local json = require("lib.json")
do
  local r = json.decode('{"a":1,"b":[true,false,null,"x"],"c":{"d":2.5}}')
  eq(r.a, 1, "json a"); eq(r.b[1], true, "json b[1]"); eq(r.b[4], "x", "json b[4]"); eq(r.c.d, 2.5, "json nested")
  local r2 = json.decode(json.encode({ x = 1, y = { 2, 3 } }))
  eq(r2.x, 1, "json roundtrip x"); eq(r2.y[2], 3, "json roundtrip y[2]")
  eq(json.decode('// comment\n{"z":9}').z, 9, "json tolerates // comment")
end

------------------------------------------------------------------ eventbus
local bus = require("core.eventbus")
do
  local got
  local fn = bus.on("t", function(p) got = p.v end)
  bus.emit("t", { v = 42 }); eq(got, 42, "bus emit")
  bus.off("t", fn); got = nil
  bus.emit("t", { v = 7 }); eq(got, nil, "bus off unsubscribes")
end

------------------------------------------------------------------ gate
local gate = require("core.gate")
do
  local map = { weather = { managerClass = "X" } }
  ok((gate.check(map, { "weather.managerClass" })), "gate: present passes")
  ok(not (gate.check(map, { "weather.currentProp" })), "gate: missing fails")
end

------------------------------------------------------------------ mapping
local mapping = require("mapping")
do
  local m, known = mapping.resolve("24038177")
  ok(known, "mapping: 24038177 is a known build")
  eq(m.pawn.worldLocationFn, "K2_GetActorLocation", "mapping: default worldLocationFn")
  eq(m.net.hasAuthorityFn, "HasAuthority", "mapping: default hasAuthorityFn")
  ok(#mapping.missing(m) > 0, "mapping: reports unmapped symbols")
  local _, known2 = mapping.resolve("does-not-exist")
  ok(not known2, "mapping: unknown build falls back")
  -- Milestone 2 sections
  eq(m.items.classFmt, "BP_%s_Item_C", "mapping: item class format")
  eq(string.format(m.items.classFmt, "Log"), "BP_Log_Item_C", "mapping: item class formats a row")
  eq(m.player.pingFn, "MULTI_Ping", "mapping: ping hook is the validated broadcast")
  eq(m.player.reduceHealthFn, "Reduce Health", "mapping: damage goes through Reduce Health")
  eq(m.ritual.bookItemRow, "Handbook", "mapping: ritual book item")
  eq(m.ritual.hydrationOfferings.water, "BP_CarafeDrinkableWater_Item_C",
     "mapping: water clear of impurities = the BOILED carafe's world actor")
  eq(m.ritual.hydrationOfferings.honey, "BP_Honey_Item_C", "mapping: comb of the honeybee")
  eq(m.ritual.hydrationOfferings.leaf, "BP_Leaf_Item_C", "mapping: leaf of the trees")
  eq(type(m.ritual.hydrationOfferings.clay), "table",
     "mapping: clay of the earth accepts multiple dropped forms")
  eq(m.ritual.hydrationOfferings.clay[1], "BP_Clay_Item_C", "mapping: clay _Item form accepted")
  eq(m.ritual.hydrationOfferings.clay[2], "BP_Clay_GrabItem_C",
     "mapping: clay GrabItem form accepted (what an inventory drop actually spawns)")
  eq(m.ritual.hydrationOfferings.berry, "BP_Raspberry_Item_C", "mapping: a berry nourished by the sun")
  eq(m.ritual.electrickOfferings.copper, "BP_Copper_Item_C", "mapping: rounded refined copper")
  eq(m.ritual.electrickOfferings.ironore, "BP_IronOre_Item_C", "mapping: raw iron ore")
  eq(m.ritual.electrickOfferings.purewater, "BP_CarafeDrinkableWater_Item_C", "mapping: purified water")
  eq(m.ritual.electrickOfferings.flower, "BP_Sunflower_Item_C", "mapping: flower of the sun")
  eq(m.ritual.electrickOfferings.cloth, "BP_Cloth_Item_C", "mapping: cloth that dressed an old wound")
  eq(m.ritual.candleBurningProp, "Burning", "mapping: candle replicated lit-state bool")
  eq(m.ritual.candleBurnRepFn, "OnRep_Burning", "mapping: candle rep-notify applies flame + timer")
  eq(m.wand.castFnExact, "PressedHandInteraction", "mapping: wand cast rides the generic left click")
  eq(m.wand.castFnPrefix, "InpActEvt_IA_HandInteract", "mapping: wand cast input-event prefix")
  eq(m.wand.stickMesh, "SM_Stick", "mapping: wand handle mesh asset")
  eq(m.wand.cobaltMesh, "SM_Cobalt", "mapping: wand tip mesh asset")
  eq(m.wand.meshPaths[m.wand.stickMesh], "/Game/Art/StaticMeshes/SM_Stick.SM_Stick",
     "mapping: stick mesh LoadAsset path (the in-hand visual force-loads it)")
  eq(m.wand.meshPaths[m.wand.cobaltMesh], "/Game/Art/StaticMeshes/SM_Cobalt.SM_Cobalt",
     "mapping: cobalt tint-donor LoadAsset path")
  eq(m.wand.meshPaths[m.wand.diamondMesh], "/Game/Art/StaticMeshes/SM_Ore_Diamond.SM_Ore_Diamond",
     "mapping: diamond tint-donor LoadAsset path")
  eq(m.wand.handBlueprintFn, "SetHandRBlueprintForBoth",
     "mapping: the game's spawn-a-hand-item equip call (the ONLY visible held-item path)")
  eq(m.wand.handItemProp, "CurHandItemFirstPerson", "mapping: pawn prop tracking the hand-item actor")
  eq(m.wand.handItemDonor, "BP_HandItem_Carrot_C", "mapping: donor hand-item class (stick stand-in)")
  eq(m.wand.handItemDonorPath, "/Game/Code/Character/HandItems/BP_HandItem_Carrot.BP_HandItem_Carrot_C",
     "mapping: donor hand-item LoadAsset path")
  eq(m.wand.handItemMeshProps[1], "FoodMesh", "mapping: hand-item actor's food mesh comp (first hit wins)")
  eq(m.wand.clearHandFn, "ClearHandBlueprints", "mapping: pawn event that destroys held hand items")
  eq(m.wand.materialDir, "/Game/Art/Materials/", "mapping: flat materials dir (wand tint LoadAsset)")
  eq(m.wand.smcPath, "/Script/Engine.StaticMeshComponent", "mapping: rig comps live on the pawn")
  eq(m.wand.handMeshFn, "SetHandRMeshForBoth", "mapping: wand rides the game's hand-mesh setter")
  eq(m.wand.handSlot1P, "Mesh_Slot_1Person_Hand_R", "mapping: first-person hand slot")
  eq(m.wand.handSlot3P, "Mesh_Slot_3rdPerson_Hand_R", "mapping: third-person hand slot")
  eq(m.wand.stashFn, "StashHandItem", "mapping: drawing stashes the held item")
  eq(m.wand.restoreFn, "RestoreHandItem", "mapping: stowing restores the held item")
  eq(m.wand.hotbarChangedFn, "HotbarSlotChanged", "mapping: hotbar switch stows the wand")
  eq(m.wand.handRebuildFn, "UpdateHandMeshesAndModes", "mapping: the one equip chokepoint (UI close heals)")
  eq(m.wand.durabilityFn, "DecreaseCurItemDurability", "mapping: held item's bar steps down by name")
  eq(m.wand.hotbarWidgetProp, "UI_Hotbar", "mapping: controller's hotbar widget (bar redraw)")
  eq(m.wand.hotbarRefreshFn, "UpdateHotbar", "mapping: hotbar redraw fn (host never auto-refreshes)")
  eq(m.wand.localControllerProp, "LocalController", "mapping: pawn -> local controller prop")
  eq(m.wand.inventorySystemProp, "InventorySystem", "mapping: pawn -> inventory system comp")
  eq(m.wand.itemRows.mundane, "MundaneWand", "mapping: real Mundane Wand item row (content pak)")
  eq(m.wand.itemRows.hydration, "HydrationWand", "mapping: real Hydration Wand item row (content pak)")
  eq(m.wand.itemRows.electric, "ElectricWand", "mapping: real Electric Wand item row (content pak)")
  eq(m.wand.itemRows.charged, "ChargedElectricWand", "mapping: real Charged Electric Wand item row")
  -- the Hydration Wand's plumbing (watering-can/water-storage/thirst RE)
  eq(m.wand.waterStorageClass, "BC_WaterStorage_C", "mapping: waterable-thing storage component")
  eq(m.wand.storageAddWaterFn, "AddWater", "mapping: storage fill fn (replicated via OnRep)")
  eq(m.wand.consumeEffectsFn, "AddConsumeableEffects", "mapping: drink hook (consumed class param)")
  ok(type(m.wand.waterTouchFns) == "table" and #m.wand.waterTouchFns >= 1,
     "mapping: wading water-touch events present")
  ok(type(m.wand.drinkClasses) == "table" and #m.wand.drinkClasses == 2,
     "mapping: both carafes (pure + dirty) count as drinking")
  eq(m.player.addThirstFn, "AddThirst", "mapping: quench fn (host player)")
  eq(m.player.clientAddThirstFn, "CLIENT_AddThirst", "mapping: quench RPC (remote teammates)")
  -- the pour splash rides the target's own watering-particle component (BP calls only)
  eq(m.wand.wateringFxComponentClass, "BC_WateringParticleManager_C",
     "mapping: watered-target splash component")
  eq(m.wand.sprayRegisterFn, "RegisterWateringPlayer", "mapping: splash pourer registration")
  eq(m.wand.sprayPlayFn, "PlayParticleEffect", "mapping: splash play fn (seconds param)")
  eq(m.wand.holdItemFn, "GetCurrentHoldItem", "mapping: held-item getter (real-item rig trigger)")
  eq(m.wand.handItemDataProp, "CurItemdataInHand", "mapping: held-item S_Item data prop")
  eq(string.format(m.items.classFmt, m.wand.itemRows.mundane), "BP_MundaneWand_Item_C",
     "mapping: wand item row resolves to its cooked BP class")
  eq(m.pawn.playerIdProp, "UniquePlayerID", "mapping: stable per-player id prop")
  eq(m.animal.sheepClass, "BP_Animal_Sheep_C", "mapping: sheep class")
  eq(m.animal.chickenClass, "BP_Animal_Chicken_C", "mapping: chicken class (hydration rite)")
  eq(m.tree.classPrefix, "BP_Tree_", "mapping: tree prefix")
  eq(m.tree.fellFn, "TreeFall", "mapping: native fell event (anim + sound + loot)")
  eq(m.tree.growMeshesProp, "GrowMeshes", "mapping: growth-stage mesh array (on _BP_Plant_MASTER_C)")
  eq(m.tree.fakeMeshProp, "FakeTreeMesh", "mapping: displayed trunk mesh comp (growth check)")
  ok(type(m.battery.chargePropCandidates) == "table" and #m.battery.chargePropCandidates > 0,
     "mapping: battery charge candidates present")
  ok(type(m.rod.stationClassCandidates) == "table", "mapping: rod station candidates present")
  eq(m.fx.clientDamageRpcFn, "CLIENT_ReduceHealth", "mapping: victim FX rides the client damage RPC")
  -- the Tempest Codex (content pak: clone of the survival guide's data-driven book UI)
  eq(m.codex.itemRow, "TempestCodex", "mapping: codex item row (pak)")
  eq(m.codex.widgetClass, "W_TempestCodex_C", "mapping: codex reader widget class")
  eq(m.codex.widgetPath, "/Game/UI/Widgets/W_TempestCodex.W_TempestCodex_C",
     "mapping: codex widget LoadAsset path")
  eq(m.codex.placeableClass, "BP_TempestCodex_Placeable_C", "mapping: placed codex class")
  eq(m.codex.placeablePath,
     "/Game/Code/Building_Placing/Placeables/BP_TempestCodex_Placeable.BP_TempestCodex_Placeable_C",
     "mapping: placed codex LoadAsset path")
  eq(m.codex.interactFnHint, "OnInteractedWith", "mapping: codex interact bound-event hint")
  eq(m.codex.openFn, "Open", "mapping: codex reader show fn")
  eq(m.codex.guideProp, "UI_SurvivalGuide",
     "mapping: controller slot the codex repoints to ride the interactable-UI registry")
  eq(m.codex.wblPath, "/Script/UMG.Default__WidgetBlueprintLibrary",
     "mapping: WidgetBlueprintLibrary CDO path (CreateWidget from Lua)")
  eq(string.format(m.items.classFmt, m.codex.itemRow), "BP_TempestCodex_Item_C",
     "mapping: codex item row resolves to its cooked BP class")
  -- "The Dark Arts" research card: tier-2 gate + old-save migration identifiers
  eq(m.codex.researchId, 3003, "mapping: The Dark Arts researchable id")
  eq(m.codex.researchTierId, 9, "mapping: LvL_2 gates the card (station tier 2)")
  eq(m.codex.researchHasFn, "HasPlayerResearch?", "mapping: research presence probe fn")
  eq(m.codex.researchSaveFn, "Playerdata_SaveResearchForSelf", "mapping: research plant fn")
  ok(m.codex.researchFieldId:find("^ResearchableID_") ~= nil,
     "mapping: S_SavedResearch id field carries its BP suffix")
  ok(m.codex.researchFieldDone:find("^Researched_") ~= nil,
     "mapping: S_SavedResearch done field carries its BP suffix")
  -- foundation snap rule bypass
  eq(#m.foundation.previewPaths, 4, "mapping: all four foundation previews are hooked")
  for _, p in ipairs(m.foundation.previewPaths) do
    ok(p:find("Foundation_AdvancedPlaceablePreview") ~= nil,
       "mapping: foundation preview path shape: " .. p)
  end
  eq(m.foundation.ruleFn, "TestAdvancedBuildingRule", "mapping: the corner-ground rule fn")
  eq(m.foundation.snapProp, "IsSnapping", "mapping: build-system snap state prop")
end

------------------------------------------------------------------ config
local config = require("core.config").init("./__no_such_modroot__/")
do
  eq(config.get("player_strike_pct"), 0.70, "config: default strike pct")
  eq(config.get("lightning_rod_range"), 2500.0, "config: default rod range")
  eq(config.get("wand_cobalt_scale"), 0.75, "config: cobalt tip is dropped-model / 4")
  eq(config.get("wand_in_hand"), true, "config: wand defaults to the game's hand slots")
  eq(config.get("wand_from_item"), true, "config: the real cooked item drives the in-hand rig")
  eq(config.get("wand_tip_up"), 0.0, "config: tip seat is computed, trim defaults to zero")
  eq(config.get("wand_mat_mundane"), "M_Trunk", "config: mundane tint = tree-bark dark brown")
  eq(config.get("wand_mat_hydration"), "M_Cobalt", "config: hydration tint = river blue")
  eq(config.get("wand_mat_electric"), "M_Beeswax", "config: uncharged-electrick tint = beeswax yellow")
  eq(config.get("wand_mat_charged"), "M_Energy_On",
     "config: charged tint = textureless powered-state glow")
  eq(config.get("wand_spray_seconds"), 0.8, "config: pour splash duration")
  eq(config.get("wand_hydration_max"), 240.0, "config: blue rod carries 2x the watering can (120)")
  ok(config.get("wand_pour_amount") > 0, "config: a pour moves water")
  ok(config.get("wand_hydrate_thirst") > 0, "config: a quench restores thirst")
  eq(config.get("wand_electric_charges"), 3, "config: a charged rod holds three bolts")
  eq(config.get("foundation_snap_ignore_ground"), true,
     "config: snapped foundations skip the corner-ground rule by default")
  eq(config.get("wand_transmute_items"), true, "config: cast/recharge swaps the real rod items")
  eq(config.get("ritual_corner_radius"), 1000.0, "config: corner offerings sit within 10 m of a candle")
  eq(config.get("ritual_payout_radius"), 3000.0,
     "config: the rite's benefit reaches players within 30 m of the sacrifice")
  local changedKey
  bus.on("config.changed", function(p) changedKey = p.key end)
  config.set("player_strike_pct", 0.9)
  eq(config.get("player_strike_pct"), 0.9, "config: set overrides")
  eq(changedKey, "player_strike_pct", "config: set emits config.changed")
end

------------------------------------------------------------------ health / damage math
-- stub the game-facing modules health depends on
package.loaded["core.net"] = { init = function() end, isHost = function() return true end,
                               multicast = function() end, hasCarriers = function() return false end }
package.loaded["core.identity"] = { init = function() end, idOf = function(a) return a.id end,
                                    locationOf = function() return nil end }
local health = require("core.health")
do
  -- player: 70% per strike -> survives one (at 30), dies on the second
  health.attach({ id = "p1" }, { max = 100, kind = "player" })
  local pDead = false
  bus.on("entity.destroyed", function(e) if e.id == "p1" then pDead = true end end)
  health.applyDamage("p1", 70, { source = "lightning" })
  ok(not pDead, "player: survives 1 strike")
  eq(health.get("p1").current, 30, "player: at 30 HP after 1 strike")
  health.applyDamage("p1", 70, { source = "lightning" })
  ok(pDead, "player: dies on 2nd strike (double strike lethal)")

  -- machine two-hit: 1st strike smokes (damaged), 2nd destroys
  health.attach({ id = "m1" }, { max = 200, kind = "machine", twoHit = true })
  local smoked, mDead = false, false
  bus.on("structure.damaged", function(e) if e.id == "m1" then smoked = true end end)
  bus.on("entity.destroyed", function(e) if e.id == "m1" then mDead = true end end)
  health.applyDamage("m1", 120, { source = "lightning" })
  ok(smoked, "machine: smokes on 1st strike")
  ok(not mDead, "machine: survives 1st strike")
  ok(health.get("m1").damaged, "machine: damaged flag set")
  health.applyDamage("m1", 120, { source = "lightning" })
  ok(mDead, "machine: destroyed on 2nd strike")

  -- repair clears the smoking state and restores HP
  health.attach({ id = "m2" }, { max = 200, kind = "machine", twoHit = true })
  health.applyDamage("m2", 120, { source = "lightning" })
  ok(health.repair("m2"), "repair returns true")
  ok(not health.get("m2").damaged, "repair: clears smoking")
  eq(health.get("m2").current, 200, "repair: restores full HP")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
