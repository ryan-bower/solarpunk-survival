-- Headless unit tests for the game-independent logic. Run from the repo root:
--   lua tests/spec.lua
-- Stubs the UE4SS globals + the game-facing modules so the pure logic (json, eventbus, config,
-- mapping, gate, health/damage math) can be verified without the game. The last section goes
-- further and drives features/manual_save.lua against fake UObjects -- its double-save guard is
-- the one piece of feature code where being wrong costs the player their save file.
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
  eq(m.weather.hardStopFn, "DEBUG_StopWeather",
     "mapping: ending a storm needs the program stop, not just the InstantSunny repaint")
  eq(m.player.reduceHealthFn, "Reduce Health", "mapping: damage goes through Reduce Health")
  eq(m.ritual.bookItemRow, "Handbook", "mapping: ritual book item")
  eq(m.ritual.hydrationOfferings.water, "BP_CarafeDrinkableWater_Item_C",
     "mapping: water clear of impurities = the BOILED carafe's world actor")
  eq(m.ritual.hydrationOfferings.wax, "BP_Beeswax_Item_C",
     "mapping: wax of the honeybee (user swapped honey -> beeswax)")
  eq(m.ritual.hydrationOfferings.honey, nil, "mapping: honey is no longer an offering")
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
  eq(m.wand.gesturePourFn, "Watercan_Watering_Animation", "mapping: pour wrist-tilt gesture on")
  eq(m.wand.gesturePourStopFn, "StopWatercanAnimation", "mapping: pour wrist-tilt gesture off")
  eq(m.wand.gestureCastFn, "Swing Miss", "mapping: cast forward-swing gesture (byte param)")
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
  -- the world save + its pause-menu button
  eq(m.save.saveFn, "Save", "mapping: the save fn IS the autosave (the timer binds to it)")
  eq(m.save.gameStateClass, "BP_SkyGameGameState_C", "mapping: the save manager hangs off the game state")
  eq(m.save.managerProp, "BPC_SaveManager", "mapping: game-state prop holding the save manager")
  eq(m.save.autosaveArmFn, "InvalidateAndSetAutosaveInterval",
     "mapping: the game's own clear-and-re-arm for the autosave timer")
  ok(#m.save.saveDoneFns >= 2,
     "mapping: 'save finished' has a degrade path (the primary signal is GUID-named)")
  eq(m.save.saveDoneFns[1].class, "BPC_SaveManager_C", "mapping: primary save-done signal is the manager's own")
  eq(m.savemenu.menuClass, "W_IngameMenu_C", "mapping: the pause menu widget")
  eq(m.savemenu.resumeButtonProp, "BTN2_Resume", "mapping: Resume is the row the Save button parks under")
  eq(m.savemenu.buttonAngle, 180.0, "mapping: the pause menu's button box is rotated; buttons rotate back")
  eq(m.savemenu.setAngleFn, "SetRenderTransformAngle", "mapping: how a Lua-made widget joins that flip")
  eq(m.savemenu.boxAddFn, "AddChildToVerticalBox", "mapping: appending is the only insert Blueprint exposes")
  eq(m.savemenu.wblPath, "/Script/UMG.Default__WidgetBlueprintLibrary",
     "mapping: CreateWidget entry (shared with the codex)")
  ok(m.savemenu.buttonClickFn:find("OnButtonClickedEvent") ~= nil,
     "mapping: the button's click handler is hooked by name (Lua cannot bind a BP delegate)")
  -- The backpack tier is the one QoL value that can destroy a save if it is only half-applied:
  -- growing the live pack without recording the tier makes the game refuse its own player record.
  eq(m.qol.backpackTierFn, "Playerdata_SaveBackpackTier",
     "mapping: the tier must be RECORDED, not just applied to the live pawn")
  ok(m.qol.playerdataTierField:find("^InventoryUpgrades_") ~= nil,
     "mapping: S_Saved_Player members keep Blueprint's mangled FNames")
  ok(m.qol.playerdataInvIdField:find("^InventoryID_") ~= nil,
     "mapping: the saved inventory GUID field is mangled the same way")
  eq(m.qol.setInvIdFn, "SetInventoryID", "mapping: how a lost inventory-to-save link is restored")
  eq(m.qol.invLenForTierFn, "GetInvLengthForBackpackUpgradeTier",
     "mapping: the tier->length ladder the save's own check uses (a shrink is verified against it)")
  -- Ping colour: the ONLY safe material op on this build is SetMaterial with a cooked material --
  -- every parameter-setting door (CreateDynamicMaterialInstance, Set*ParameterValueOnMaterials)
  -- is a proven native crash (2026-07-26/27, three identical all-UE4SS dumps). So every palette
  -- slot must carry its colour twice: the map-icon r/g/b AND a material whose baked look matches.
  eq(m.qol.setMaterialFn, "SetMaterial", "mapping: the one survivable material call")
  eq(m.qol.setVecOnMatsFn, nil, "mapping: the parameter family stays banned (vector)")
  eq(m.qol.setScalarOnMatsFn, nil, "mapping: the parameter family stays banned (scalar)")
  eq(m.qol.flatMats, nil, "mapping: no shared flat-material list -- colour is per palette slot")
  -- SM_Ping slot order was read from the cooked mesh and is the REVERSE of the first guess:
  -- 0 = icon quad ("the box"), 1 = gradient beam (the rod). Pin it so a refactor can't swap back.
  eq(m.qol.pingIconSlot, 0, "mapping: icon quad is material slot 0 (M_Ping2)")
  eq(m.qol.pingBeamSlot, 1, "mapping: beam is material slot 1 (M_Ping1)")
  eq(m.qol.pingHideMat, "NaniteHiddenSectionMaterial",
     "mapping: rod-only hides the icon with the engine's draw-nothing material")
  ok(m.qol.pingHideMatDir:find("^/Engine/") ~= nil,
     "mapping: the hide material loads from Engine content, not the game's material dir")
  -- Chest grid: the UI dimensions are LITERALS in the chest widget's bytecode, and the build is
  -- an EX_FinalFunction static call UE4SS hooks cannot intercept -- so qol rebuilds the grid
  -- after each open through the game's own library. Pin every name that rebuild reaches for.
  eq(m.qol.slotGridFn, "CreateItemSlotGrid", "mapping: the grid-builder the rebuild calls")
  ok(m.qol.slotGridLibPath:find(":", 1, true) == nil and m.qol.slotGridLibPath:find("_C$") ~= nil,
     "mapping: grid library path is a class path (CDO derived from it at rebuild time)")
  eq(m.qol.chestGridRows, 2, "mapping: stock chest grid rows (reference)")
  eq(m.qol.chestGridCols, 6, "mapping: chest grid columns the rebuild preserves")
  eq(m.qol.chestUiClass, "W_ChestInventory_C", "mapping: the chest UI widget class")
  eq(m.qol.chestUiPanelProp, "ChestInventory", "mapping: the grid panel property")
  eq(m.qol.chestUiSlotsProp, "ChestSlots", "mapping: the slot-widget array the fill loop reads")
  eq(m.qol.chestUiInvRefProp, "ChestInventoryRef", "mapping: the inventory the widget is showing")
  eq(m.qol.chestUiSyncFn, "SyncAndFill_Chest", "mapping: the no-arg repopulate event")
  eq(m.qol.chestClassPath, "/Game/Code/Building_Placing/Placeables/BP_Chest_Buildable",
     "mapping: chest package path for the LoadAsset fallback")
  -- Ctrl crouch edges: ORDER IS MEANING -- index 1 must stay the Pressed function (_2 sets its
  -- gate bool TRUE in the pawn's Ubergraph; _3 sets it FALSE). Shuffling this list would silently
  -- invert press and release.
  eq(m.qol.crouchKeyEventFns[1], "InpActEvt_LeftControl_K2Node_InputKeyEvent_2",
     "mapping: crouch key DOWN edge is index 1 (bytecode: gate bool := true)")
  eq(m.qol.crouchKeyEventFns[2], "InpActEvt_LeftControl_K2Node_InputKeyEvent_3",
     "mapping: crouch key UP edge is index 2 (bytecode: gate bool := false)")
  eq(m.qol.shipUnpossessFn, "ReceiveUnpossessed", "mapping: the ship-chest re-anchor moment")
  ok(#m.qol.palette >= 3, "mapping: enough palette slots to tell players apart")
  for i, slot in ipairs(m.qol.palette) do
    ok(type(slot.mat) == "string" and #slot.mat > 0,
       "mapping: palette slot " .. i .. " names its baked-colour material")
    ok(type(slot.r) == "number" and type(slot.g) == "number" and type(slot.b) == "number",
       "mapping: palette slot " .. i .. " carries the map tint r/g/b")
  end
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

------------------------------------------------------------------ evil animals (the Unlit)
do
  local m = mapping.resolve("24038177")
  -- offline-RE'd animal symbols (docs/RE-ANIMALS.md)
  eq(m.animal.masterClass, "BP_Animal_MASTER_C", "animal: master class")
  eq(m.animal.pigClass, "BP_Animal_Pig_C", "animal: pig class (future species)")
  eq(m.animal.classPaths["BP_Animal_Sheep_C"],
     "/Game/Code/Animals/Chicken/BP_Animal_Sheep.BP_Animal_Sheep_C",
     "animal: sheep BP lives in the (misfiled) Chicken folder")
  eq(m.animal.nameProp, "Name", "animal: the replicated Name beacon")
  eq(m.animal.montageSetFn, "BB_SetMontage", "animal: blackboard montage setter")
  eq(m.animal.montageSleepValue, 3, "animal: Sleep montage byte (the lie-down)")
  eq(m.animal.montageWalkValue, 1, "animal: Walk montage byte (moving, upright)")
  eq(m.animal.montageStandValue, 2, "animal: Stand montage byte (frozen, upright)")
  eq(m.animal.moveCompProp, "CharacterMovement", "animal: movement comp (engine default profile)")
  eq(m.animal.stopLogicFn, "StopLogic", "animal: brain stop fn")
  ok(type(m.animal.stopLogicFns) == "table" and m.animal.stopLogicFns[1] == "StopLogic",
     "animal: brain-stop fallback list (build-dependent name)")
  eq(m.animal.isOwnedFn, "IsOwned", "animal: owned-pet probe (guards the stray sweep)")
  eq(m.animal.moveToActorFn, "MoveToActor", "animal: chase move order")
  eq(m.animal.audioCompProp, "S_Chicken_NoLicense", "animal: per-animal audio component prop")
  ok(#m.animal.soundsChicken == 7, "animal: seven chicken cries")
  ok(#m.animal.soundsSheep == 6, "animal: six sheep cries")
  eq(m.animal.screamChicken, "S_Chicken_Scream", "animal: the aggro cry")

  -- config tunables
  eq(config.get("evil_spawn_radius"), 20000.0, "evil: 200 m spawn ring")
  eq(config.get("evil_cap_per_player"), 10, "evil: 10 per player cap")
  eq(config.get("evil_lockon_radius"), 10000.0, "evil: 100 m lock-on")
  eq(config.get("evil_bite_radius"), 300.0, "evil: 3 m bite range")
  eq(config.get("evil_bite_interval"), 2.0, "evil: bite every 2 s")
  eq(config.get("evil_bite_chicken"), 10.0, "evil: bird pecks for 10")
  eq(config.get("evil_bite_sheep"), 20.0, "evil: lamb bites for 20")
  eq(config.get("evil_hp_chicken"), 90.0, "evil: bird has 90 HP (3x)")
  eq(config.get("evil_hp_sheep"), 150.0, "evil: lamb has 150 HP (3x)")
  eq(config.get("evil_wander_mult"), 2.0, "evil: prowl at 2x")
  eq(config.get("evil_chase_mult"), 8.0, "evil: charge at 8x")
  ok(config.get("evil_spawn_per_tick") >= 1, "evil: at least one spawn per tick")
  ok(config.get("evil_spawn_tries") >= 1, "evil: ground-pick retries per spawn")
  eq(config.get("evil_mat_dead"), "M_Deco_Fireplace_Burned", "evil: black death tint")
  eq(config.get("evil_scale_sheep"), 2.0, "evil: sheep loom at 2x size")
  eq(config.get("evil_scale_chicken"), 1.0, "evil: chickens stay 1x size")
  eq(config.get("evil_atkspeed_sheep"), 0.7, "evil: sheep attack at 70% speed")
  ok(config.get("evil_atkspeed_chicken") == 1.0, "evil: chicken attack speed baseline")
  eq(m.weather.isDayProp, "IsDay", "weather: daylight flag on the cycle manager")
  eq(m.weather.rainTimelineProp, "TL_RainTransition", "weather: rain timeline = the wetness readout")
  eq(config.get("evil_hit_stun"), 0.5, "evil: tool hit stuns for 0.5 s")
  eq(config.get("evil_ram_recover"), 1.5, "evil: sheep ram recovery 1.5 s")
  eq(config.get("evil_light_block_big"), 2000.0, "evil: 20 m light block")
  eq(config.get("evil_light_block_small"), 1000.0, "evil: 10 m small-light block")
  ok(type(m.animal.spawnLights) == "table" and #m.animal.spawnLights >= 6, "evil: light blockers mapped")
  eq(m.animal.spawnLights[1].prop, "Burning", "evil: torch lit-flag is Burning")
  eq(config.get("evil_glow"), true, "evil: red aura light on by default")
  ok(config.get("evil_glow_intensity") > 0, "evil: aura has positive intensity")
  ok(config.get("evil_glow_radius") > 0, "evil: aura has a reach radius")
  eq(config.get("evil_glow_r"), 1.0, "evil: aura is full red")
  ok(config.get("evil_glow_g") < 0.2 and config.get("evil_glow_b") < 0.2, "evil: aura stays red, not pink/white")
  eq(config.get("evil_glow_follow"), 0.1, "evil: aura trails at 10 Hz")
  eq(config.get("evil_prefix_alive"), "Vengeful ", "evil: living nameplate reads Vengeful")
  eq(config.get("evil_prefix_dead"), "Banished ", "evil: fallen nameplate reads Banished")
  eq(config.get("evil_dmg_base"), 20.0, "evil: base tools hit 20")
  eq(config.get("evil_dmg_metal"), 30.0, "evil: metal tools hit 30")
  eq(config.get("evil_dmg_diamond"), 40.0, "evil: diamond tools hit 40")
  ok(config.get("evil_sound_pitch") < 1.0, "evil: voices pitched DOWN")
  eq(config.get("evil_sweep_strays"), false, "evil: destructive stray sweep is OFF by default")

  -- pure helpers
  local evil = require("features.evil_animals")
  local A, D = "Unlit ", "Fallen "
  local st, hits = evil.parseEvilName("Unlit Ewe 3", A, D)
  eq(st, "alive", "parse: living Unlit"); eq(hits, 0, "parse: no hits yet")
  st, hits = evil.parseEvilName("Unlit Ewe 3''", A, D)
  eq(st, "alive", "parse: tallied Unlit"); eq(hits, 2, "parse: two landed hits")
  st = evil.parseEvilName("Fallen Ewe 3", A, D)
  eq(st, "dead", "parse: fallen Unlit")
  eq(evil.parseEvilName("Dolly", A, D), nil, "parse: a vanilla animal is no Unlit")
  eq(evil.parseEvilName(nil, A, D), nil, "parse: nil-safe")

  local dmg = { base = 20, metal = 30, diamond = 40 }
  eq(evil.toolDamageForClass("BP_Pickaxe_Item_C", dmg), 20, "tool: stone pickaxe 20")
  eq(evil.toolDamageForClass("BP_Axe_Item_C", dmg), 20, "tool: stone axe 20")
  eq(evil.toolDamageForClass("BP_Hoe_Item_C", dmg), 20, "tool: stone hoe 20")
  eq(evil.toolDamageForClass("BP_AxeMetal_Item_C", dmg), 30, "tool: metal axe 30")
  eq(evil.toolDamageForClass("BP_Axe_Metal_Item_C", dmg), 30, "tool: metal axe (underscored row) 30")
  eq(evil.toolDamageForClass("BP_Hoe_Diamond_Item_C", dmg), 40, "tool: diamond hoe 40")
  eq(evil.toolDamageForClass("BP_PickaxeDiamond_Item_C", dmg), 40, "tool: diamond pickaxe 40")
  eq(evil.toolDamageForClass("BP_Axe_Kickstarter_Item_C", dmg), 20, "tool: kickstarter skin = base")
  eq(evil.toolDamageForClass("BP_Hammer_Item_C", dmg), nil, "tool: the hammer is no weapon")
  eq(evil.toolDamageForClass("BP_Stick_Item_C", dmg), nil, "tool: a stick is no weapon")
  eq(evil.toolDamageForClass(nil, dmg), nil, "tool: empty hand nil-safe")
end

------------------------------------------------------------------ save flags
do
  local save = require("core.save")
  save.init(nil, "./__no_such_modroot__/")
  eq(save.getFlag("evil_chicken"), nil, "flags: unset reads nil")
  save.setFlag("evil_chicken", true)   -- write() fails silently on the missing dir; flag stays
  eq(save.getFlag("evil_chicken"), true, "flags: set/get roundtrip")
  ok(save.serialize().flags.evil_chicken == true, "flags: serialized with the save")
  -- serialize never persists a destroyed record (would ghost-collide with a rebuild at that grid)
  local health2 = require("core.health")
  health2.attach({ id = "s_dead" }, { max = 100, kind = "structure" })
  health2.applyDamage("s_dead", 999, { source = "lightning" })  -- -> destroyed
  ok(save.serialize().structures["s_dead"] == nil, "flags: destroyed structures are not persisted")
end

------------------------------------------------------------------ the poison latch
-- log.risky is the only thing standing between "one engine call crashes the game" and "one engine
-- call crashes the game every single launch forever", so it gets tested like it matters.
do
  local log = require("core.log")
  local root = "./tests/.tmp_latch/"
  local win = package.config:sub(1, 1) == "\\"
  os.execute(win and 'mkdir "tests\\.tmp_latch\\dump" >nul 2>nul'
                 or  'mkdir -p tests/.tmp_latch/dump 2>/dev/null')
  log.armSteps(root, false)

  local ran = 0
  local survived = log.risky("unit:survives", function() ran = ran + 1 end)
  eq(survived, true, "latch: a call that returns is reported ok")
  eq(ran, 1, "latch: and it actually ran")
  log.risky("unit:survives", function() ran = ran + 1 end)
  eq(ran, 2, "latch: a survivor is not latched -- it runs again next time")

  -- simulate a native crash: the marker is written and the process dies before it is removed
  local f = io.open(root .. "dump/risky_unit_crashes.txt", "w")
  if f then f:write("died\n"); f:close() end
  local ran2 = 0
  local rerun, why = log.risky("unit:crashes", function() ran2 = ran2 + 1 end)
  eq(rerun, false, "latch: a tag whose marker survived the last run is refused")
  eq(why, "poisoned", "latch: and says why")
  eq(ran2, 0, "latch: the call that killed the game last time is NOT made again")
  ok(log.isPoisoned("unit:crashes"), "latch: the tag reads as poisoned")
  ok(not log.isPoisoned("unit:survives"), "latch: an unrelated tag is unaffected")

  os.remove(root .. "dump/risky_unit_crashes.txt")
  os.remove(root .. "dump/risky_unit_survives.txt")

  -- stepv is the volume knob on the breadcrumb trail; if it leaks when off, a save load writes a
  -- file per streamed-in actor and the trail is useless exactly when it is needed
  local trail = root .. "dump/steps_crash.txt"
  os.remove(trail)
  local function trailHas(needle)
    local h = io.open(trail, "r"); if not h then return false end
    local body = h:read("*a"); h:close()
    return body:find(needle, 1, true) ~= nil
  end
  log.armSteps(root, true, false)
  log.step("unit-loud"); log.stepv("unit-quiet")
  ok(trailHas("unit-loud"),      "stepv: an ordinary step still writes")
  ok(not trailHas("unit-quiet"), "stepv: a verbose step is silent unless asked for")
  log.armSteps(root, true, true)
  log.stepv("unit-quiet")
  ok(trailHas("unit-quiet"), "stepv: and writes once step_log_notify is on")
  log.armSteps(root, false)          -- leave the singleton quiet for every block below
  os.remove(trail)
end

------------------------------------------------------------------ the deferred-work scheduler
-- core/scheduler.lua exists because UE4SS aborts the process when its own deferred-action list
-- goes bad, so the rules that keep our footprint in that list small are worth asserting: at most
-- ONE outstanding game-thread hop, a bounded batch per hop, and nothing dropped if a hop is
-- refused. Driven with a hand-cranked ticker -- no timers, no sleeping.
do
  local savedEWD, savedEIGT, savedLoop = _G.ExecuteWithDelay, _G.ExecuteInGameThread, _G.LoopAsync
  local tick
  _G.LoopAsync = function(_, fn) tick = fn end
  local hops, refuse = {}, false
  _G.ExecuteInGameThread = function(fn)
    if refuse then error("game thread refused") end
    hops[#hops + 1] = fn
  end

  local sched = require("core.scheduler")
  ok(sched.init(nil), "scheduler: init took over the async primitives")
  ok(type(tick) == "function", "scheduler: and registered exactly one ticker")

  local ran = 0
  for _ = 1, 30 do ExecuteWithDelay(0, function() ran = ran + 1 end) end
  tick()
  eq(#hops, 1, "scheduler: a tick with work arms one hop")
  tick(); tick()
  eq(#hops, 1, "scheduler: further ticks add nothing while that hop is outstanding")
  eq(ran, 0, "scheduler: and nothing has run off the game thread")

  hops[1]()
  eq(ran, 24, "scheduler: a hop drains at most MAX_PER_HOP actions")
  tick()
  eq(#hops, 2, "scheduler: the next tick picks up where it left off")
  hops[2]()
  eq(ran, 30, "scheduler: every queued action ran, none dropped")

  -- a refused hop must not eat the batch, and must not latch the scheduler shut forever
  ExecuteWithDelay(0, function() ran = ran + 1 end)
  refuse = true
  tick()
  eq(#hops, 2, "scheduler: a refused hop is not counted")
  refuse = false
  tick()
  eq(#hops, 3, "scheduler: the latch cleared -- deferred work is not dead")
  hops[3]()
  eq(ran, 31, "scheduler: the action the refused hop took off the queue was put back")

  _G.ExecuteWithDelay, _G.ExecuteInGameThread, _G.LoopAsync = savedEWD, savedEIGT, savedLoop
  package.loaded["core.scheduler"] = nil
end

------------------------------------------------------------------ playerPawn vs any old Character
-- localPawn() ends in "the first Character in the world" on purpose, but animals are Characters
-- and so is whatever the main menu is showing. Anything doing inventory or save work must be able
-- to ask for the real player and get nil instead of a cow.
do
  local savedFirst, savedAll = _G.FindFirstOf, _G.FindAllOf
  local cls = "BP_Animal_Cow_C"
  local body = {
    IsValid = function() return true end,
    GetClass = function()
      return { GetFName = function() return { ToString = function() return cls end } end }
    end,
  }
  _G.FindAllOf = function() return {} end
  _G.FindFirstOf = function(name) if name == "Character" then return body end return nil end

  local uehelp = require("core.uehelp")
  ok(uehelp.localPawn() == body, "playerPawn: localPawn still falls back to any Character")
  eq(uehelp.playerPawn("BP_MainPlayerCharacter_C"), nil, "playerPawn: a cow is not the player")
  ok(uehelp.playerPawn(nil) == body, "playerPawn: no class asked for means no class enforced")
  cls = "BP_MainPlayerCharacter_C"
  ok(uehelp.playerPawn("BP_MainPlayerCharacter_C") == body, "playerPawn: the real pawn comes back")

  _G.FindFirstOf, _G.FindAllOf = savedFirst, savedAll
end

------------------------------------------------------------------ pause-menu save guards
-- features/manual_save.lua is safety-critical (a second write landing on top of one already in
-- flight is exactly the corruption the button must never cause), so it is driven for real against
-- fake UObjects rather than trusted to review. Stubs from here down replace the module-level ones
-- above; this section is deliberately LAST.
do
  local hooks, objects = {}, {}

  -- A fake UObject: reflected props are plain fields, reflected UFunctions are plain methods, and
  -- the reflection surface uehelp needs (IsValid / GetFullName / GetClass -> ForEachFunction) is
  -- synthesised from the table itself.
  local function obj(class, fields)
    local o = fields or {}
    function o:IsValid() return true end
    function o:GetFullName() return class .. " /Game/Fake." .. class .. ":" .. tostring(o.__id or class) end
    function o:GetClass()
      return {
        GetFName = function() return { ToString = function() return class end } end,
        ForEachFunction = function(_, cb)
          for name, v in pairs(o) do
            if type(v) == "function" and name:sub(1, 2) ~= "__"
               and name ~= "IsValid" and name ~= "GetFullName" and name ~= "GetClass" then
              cb({ GetFName = function() return { ToString = function() return name end } end,
                   -- RegisterHook is handed this with the leading type word stripped
                   GetFullName = function() return "Function " .. class .. ":" .. name end })
            end
          end
        end,
      }
    end
    objects[class] = o
    return o
  end
  local function fire(path, ...) local cb = hooks[path]; if cb then cb(...) end; return cb ~= nil end

  local classes = { W_MenuButton_V2_C = { IsValid = function() return true end } }
  _G.FindObject       = function(_, name) return classes[name] end
  _G.FindFirstOf      = function(c) return objects[c] end
  _G.FindAllOf        = function(c) return objects[c] and { objects[c] } or {} end
  _G.RegisterHook     = function(path, cb) hooks[path] = cb end
  _G.ExecuteWithDelay = function(_, fn) fn() end
  _G.ExecuteInGameThread = function(fn) fn() end
  _G.FText            = function(s) return s end

  local saveCalls, rearmCalls, labels, removed = 0, 0, {}, {}

  local btn = obj("W_MenuButton_V2_C", { __id = "SaveBtn" })
  btn.SetText = function(_, t) labels[#labels + 1] = tostring(t) end
  btn.SetRenderTransformAngle = function(_, a) btn.__angle = a end
  btn["BndEvt__Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"] = function() end

  local slot = obj("VerticalBoxSlot", {}); slot.SetPadding = function() end
  local children, adds = {}, 0
  local box  = obj("VerticalBox", {})
  box.AddChildToVerticalBox = function(_, w) box.__last = w; children[w] = true; adds = adds + 1; return slot end
  box.RemoveChild = function(_, w) removed[#removed + 1] = w; children[w] = nil; return true end
  box.HasChild = function(_, w) return children[w] == true end

  -- the real BTN2_Resume carries a 180 counter-rotation against its rotated parent box
  local resume = obj("BTN2_Resume_C", { __id = "Resume", RenderTransform = { Angle = 180.0 } })
  local pc = obj("BP_MainPlayerController_C", {})
  pc.IsLocalPlayerController = function() return true end
  local menu = obj("W_IngameMenu_C", { BOX_MenuButtons = box, BTN2_Resume = resume })
  menu.Open = function() end

  local mgr = obj("BPC_SaveManager_C", { SaveIntervall = 300.0 })
  mgr.Save = function()
    saveCalls = saveCalls + 1
    fire("BPC_SaveManager_C:Save")          -- the game's pre-hook fires on every write, ours included
  end
  mgr.InvalidateAndSetAutosaveInterval = function(_, iv) rearmCalls = rearmCalls + 1; mgr.__iv = iv end
  mgr["Completed_BB33EECA440DCA1E1E27DABE0E75C18D"] = function() end
  obj("BP_SkyGameGameState_C", { BPC_SaveManager = mgr })

  _G.StaticFindObject = function(p)
    if p == "/Script/UMG.Default__WidgetBlueprintLibrary" then
      return { Create = function() return btn end }
    end
    return nil
  end

  local sidecar = 0
  bus.on("save.write", function() sidecar = sidecar + 1 end)
  config.init("./__no_such_modroot__/")
  local isHost = true
  local log = require("core.log")
  log.setLevel("error")   -- the refusals below are logged at info by design
  local F = require("features.manual_save")
  eq(F.init({
    map = mapping.resolve("24038177"), config = config, log = log, bus = bus, gate = gate,
    uehelp = require("core.uehelp"), net = { isHost = function() return isHost end },
  }), true, "save button: init succeeds")

  eq(box.__last, resume, "save button: Resume is re-appended last, so the Save row sits above it")
  eq(removed[1], resume, "save button: Resume left the box exactly once to make room")
  eq(labels[1], "Save Game", "save button: carries the idle label")
  eq(btn.__angle, 180.0, "save button: copies Resume's counter-rotation (or it renders upside down)")

  -- re-opening the menu must not stack a second button, but a button that is GONE from the box
  -- (the recycled-object-name case a bare IsValid would miss) must be rebuilt
  local addsAfterInject = adds
  fire("W_IngameMenu_C:Open")
  eq(adds, addsAfterInject, "save button: re-opening the menu does not add a second button")
  children[btn] = nil
  fire("W_IngameMenu_C:Open")
  eq(adds, addsAfterInject + 2, "save button: a button missing from the box is rebuilt (with Resume behind it)")

  local CLICK = "W_MenuButton_V2_C:BndEvt__Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
  local DONE  = "BPC_SaveManager_C:Completed_BB33EECA440DCA1E1E27DABE0E75C18D"
  ok(hooks[CLICK] ~= nil, "save button: the click handler is hooked")
  ok(hooks["BPC_SaveManager_C:Save"] ~= nil, "save button: the game's own Save is hooked")
  ok(hooks[DONE] ~= nil, "save button: the save-finished signal is hooked")
  local function click(who) fire(CLICK, { get = function() return who or btn end }) end

  click()
  eq(saveCalls, 1, "save button: a click saves")
  eq(rearmCalls, 1, "save button: a manual save re-arms the autosave timer")
  eq(mgr.__iv, 300.0, "save button: re-armed with the game's own interval")
  ok(sidecar >= 1, "save button: the mod's sidecar state rides the game save")

  click()
  eq(saveCalls, 1, "save button: a second click DURING the write is refused (no double save)")

  fire(DONE); click()
  eq(saveCalls, 1, "save button: a click inside the cooldown is refused")

  config.set("save_button_cooldown", 0); click()
  eq(saveCalls, 2, "save button: past the cooldown a click saves again")

  fire(DONE); fire("BPC_SaveManager_C:Save"); click()
  eq(saveCalls, 2, "save button: a click during the GAME's autosave is refused")
  fire(DONE)

  isHost = false; click()
  eq(saveCalls, 2, "save button: a client click is refused (only the host writes the world save)")
  isHost = true

  -- a completion signal that never arrives must not wedge the button shut for the session
  fire("BPC_SaveManager_C:Save")
  config.set("save_button_timeout", -1); click()
  eq(saveCalls, 3, "save button: a stale in-flight flag times out instead of locking the button")

  fire(DONE); mgr.SaveIntervall = 0
  local before = rearmCalls; click()
  eq(rearmCalls, before, "save button: an insane autosave interval leaves the game's timer alone")
  log.setLevel("info")
end

------------------------------------------------------------------ fishing overhaul
-- Pure drop-table math + skillshot math from features/fishing.lua (no game objects involved).
do
  local fishing = require("features.fishing")
  local m = mapping.resolve("24038177")

  -- mapping symbols the feature stands on
  eq(m.fishing.riverClass, "BP_River_C", "fishing: loot lives per BP_River instance")
  eq(m.fishing.loottableProp, "Loottable", "fishing: the river's weighted table prop")
  eq(m.fishing.lootItemField, "Item_2_1BBB738C4E44A3691F7D7FA72F18D942",
     "fishing: S_WeightedLootItem item field (GUID-suffixed BP struct member)")
  eq(m.fishing.lootWeightField, "Weight_5_FE32777043D4D4500ED27DB09FD53D95",
     "fishing: S_WeightedLootItem weight field")
  eq(m.fishing.lootTickFn, "ChanceForLoot", "fishing: the hookable 1.5s bite roll (SetTimer delegate)")
  eq(m.fishing.useRodFn, "Interaction_FishingRod",
     "fishing: diamond-rod clicks drive the game's own pawn event (durability drains free)")
  eq(m.fishing.rodDurability, 200, "fishing: vanilla rod durability")
  eq(m.fishing.diamondDurability, 2000, "fishing: diamond rod = 10x durability (user spec)")
  eq(m.fishing.userWidgetPath, "/Script/UMG.UserWidget", "fishing: own-widget shell class")
  eq(m.fishing.canvasPanelPath, "/Script/UMG.CanvasPanel", "fishing: raw canvas class")
  eq(m.fishing.wblPath, "/Script/UMG.Default__WidgetBlueprintLibrary", "fishing: widget library CDO")

  -- config defaults
  eq(config.get("fishing_minigame_chance"), 0.05, "fishing: 5% of bites are the skillshot")
  eq(config.get("fishing_splash_gain"), 3.0, "fishing: bite splash at 300%")
  eq(config.get("fishing_storm_mult"), nil, "fishing: storm no longer touches the loot bands")
  eq(config.get("fishing_minigame_weather_bonus"), 0.05, "fishing: rain/storm = +5pp skillshot chance")
  eq(config.get("fishing_space_cast"), nil, "fishing: the SPACE binding was removed (user pass)")
  eq(config.get("fishing_twilight_mult"), 1.5, "fishing: dawn/dusk x1.5")
  eq(config.get("fishing_flash_secs"), 0.22, "fishing: resolve flash before the bar folds")
  eq(config.get("fishing_click_lead"), 0.0, "fishing: no click-lead -- the frozen frame IS the judge")
  eq(config.get("fishing_ui_own_widget"), true, "fishing: own viewport widget preferred")
  eq(config.get("anim_tick_ms"), 8, "animator: per-frame lane ticks at 8ms")
  eq(config.get("fishing_bar_speed_max_mult"), 2.0, "fishing: bar speed rolls up to 2x (user spec)")
  -- three-way roll (user spec 2026-07-29: the gap-sync game joins as a ~even third option)
  eq(config.get("fishing_wheel_share"), 0.34, "fishing: wheel share of the three-way roll")
  eq(config.get("fishing_vsync_share"), 0.33, "fishing: gap-sync share of the three-way roll")
  eq(config.get("fishing_wheel_speed"), 360.0, "wheel: constant spin speed")
  eq(config.get("fishing_wheel_decel"), 144.0, "wheel: constant decel (learnable 450deg offset)")
  eq(config.get("fishing_wheel_zone"), 40.0, "wheel: golden arc width")
  eq(config.get("fishing_wheel_zone_diamond"), 24.0, "wheel: diamond arc is harder")

  -- baked river registry: 12 rivers, the census's group split
  eq(#fishing.RIVERS, 12, "fishing: 12 rivers baked")
  local groups = { starter = 0, mid = 0, late = 0 }
  for _, r in ipairs(fishing.RIVERS) do groups[r.group] = groups[r.group] + 1 end
  eq(groups.starter, 3, "fishing: 3 starter rivers")
  eq(groups.mid, 5, "fishing: 5 mid rivers (each with a specialty)")
  eq(groups.late, 4, "fishing: 4 late rivers")
  for _, r in ipairs(fishing.RIVERS) do
    ok(r.group ~= "mid" or type(r.specialty) == "string", "fishing: every mid river names its specialty")
  end

  -- classification by position (river instance names are not stable; positions are level data)
  eq(fishing.nearestRiver(3576, -7019).group, "starter", "fishing: NewStart river is starter")
  local gm = fishing.nearestRiver(-137107, -44448)
  eq(gm.group, "mid", "fishing: GoldenMid river is mid")
  eq(gm.specialty, "BP_Carrot_Item_C", "fishing: GoldenMid's specialty is the carrot")
  eq(fishing.nearestRiver(487688, 65143).group, "late", "fishing: SnowCave river is late")

  -- generated spec invariants (the gen script asserts these too; keep the Lua copy honest)
  for _, g in ipairs({ "starter", "mid", "late" }) do
    local sum = 0
    for _, e in ipairs(fishing.TABLES[g]) do sum = sum + e.w end
    eq(sum, 10000, "fishing: " .. g .. " spec sums to 10000")
  end

  -- composition: totals hold at every multiplier, band scales exactly, commons shrink
  for _, mult in ipairs({ 1, 1.5, 2, 3, 4, 6 }) do
    for _, g in ipairs({ "starter", "mid", "late" }) do
      local t = fishing.composeTable(g, "BP_Carrot_Item_C", mult)
      local sum = 0
      for _, e in ipairs(t) do sum = sum + e.w end
      eq(sum, 10000, string.format("fishing: %s at x%.1f still sums to 10000", g, mult))
    end
  end
  local late2 = fishing.composeTable("late", nil, 2)
  local bandOk, algae2 = true, nil
  for i, e in ipairs(fishing.TABLES.late) do
    if e.tier and late2[i].w ~= e.w * 2 then bandOk = false end
    if i == 1 then algae2 = late2[i].w end
  end
  ok(bandOk, "fishing: x2 doubles every rare/jackpot weight exactly")
  ok(algae2 < fishing.TABLES.late[1].w, "fishing: the common base shrinks to pay for the band")

  -- specialty substitution (mid) and clean drop without one
  local midC = fishing.composeTable("mid", "BP_Wheat_Item_C", 1)
  local foundWheat = false
  for _, e in ipairs(midC) do
    if e.cls == "BP_Wheat_Item_C" and e.w == 900 then foundWheat = true end
    ok(e.cls ~= false and e.cls ~= nil, "fishing: no unresolved specialty slots survive composition")
  end
  ok(foundWheat, "fishing: the island specialty fills its 9% slot at x1")

  -- skillshot reward pools
  local poolAll = fishing.rewardPool("late", false)
  local poolJack = fishing.rewardPool("late", true)
  local hasBattery, jackClean, hasDrone = false, true, false
  for _, e in ipairs(poolAll) do if e.cls == "BP_Battery_Item_C" then hasBattery = true end end
  for _, e in ipairs(poolJack) do
    if e.tier ~= "jackpot" then jackClean = false end
    if e.cls == "BP_AutoFisher_Item_C" then hasDrone = true end
  end
  ok(hasBattery, "fishing: normal skillshot pool spans rare+jackpot")
  ok(jackClean, "fishing: diamond skillshot pool is jackpot-only")
  ok(hasDrone, "fishing: the algae drone sits in the jackpot pool")

  -- weighted pick determinism
  local pool = { { cls = "a", w = 10 }, { cls = "b", w = 30 }, { cls = "c", w = 60 } }
  eq(fishing.weightedPick(pool, 0).cls, "a", "fishing: pick at r=0 is the first entry")
  eq(fishing.weightedPick(pool, 0.5).cls, "c", "fishing: pick lands by cumulative weight")
  eq(fishing.weightedPick(pool, 0.999).cls, "c", "fishing: pick at r~1 is the last entry")

  -- marker math: ping-pong 0..1..0 over one period
  eq(fishing.markerPos(0, 1.6), 0, "fishing: marker starts at 0")
  eq(fishing.markerPos(0.8, 1.6), 1, "fishing: marker peaks at half period")
  eq(fishing.markerPos(0.4, 1.6), 0.5, "fishing: marker mid-sweep")
  eq(fishing.markerPos(1.6, 1.6), 0, "fishing: marker returns at full period")
  ok(fishing.zoneHit(0.5, 0.5, 0.1), "fishing: dead-centre hits")
  ok(fishing.zoneHit(0.55, 0.5, 0.1), "fishing: zone edge counts")
  ok(not fishing.zoneHit(0.56, 0.5, 0.1), "fishing: just outside misses")

  -- per-bar speed roll: uniform 1x..maxMult x, expressed as the shared period
  eq(fishing.rollPeriod(1.6, 2, 0), 1.6, "fishing: speed roll r=0 keeps the base period")
  eq(fishing.rollPeriod(1.6, 2, 1), 0.8, "fishing: speed roll r=1 is 2x speed = half period")
  eq(fishing.rollPeriod(1.6, 2, 0.5), 1.6 / 1.5, "fishing: speed roll mid = 1.5x speed")
  eq(fishing.rollPeriod(1.6, 1, 1), 1.6, "fishing: maxMult 1 disables the roll")

  -- wheel math: constant spin, constant decel, fixed learnable stopping offset
  eq(fishing.wheelAngle(0, 360), 0, "wheel: needle starts up")
  eq(fishing.wheelAngle(0.25, 360), 90, "wheel: quarter second = quarter turn at 360deg/s")
  eq(fishing.wheelAngle(1.5, 360), 180, "wheel: angle wraps mod 360")
  eq(fishing.wheelStopOffset(360, 360), 180, "wheel: default physics stop 180deg past the click")
  eq(fishing.wheelFinal(0.25, 360, 360), 270, "wheel: click at 90 rests at 270")
  local th0, done0 = fishing.wheelSlowdownPos(0, 90, 360, 360)
  eq(th0, 90, "wheel: slowdown starts at the click angle")
  ok(not done0, "wheel: slowdown not done at t=0")
  local thEnd, doneEnd = fishing.wheelSlowdownPos(1.0, 90, 360, 360)
  eq(thEnd, 270, "wheel: slowdown ends exactly at click+offset")
  ok(doneEnd, "wheel: slowdown done at speed/decel seconds")
  local thPast = fishing.wheelSlowdownPos(5.0, 90, 360, 360)
  eq(thPast, 270, "wheel: past the stop the needle stays put")
  ok(fishing.angleHit(350, 0, 40), "wheel: zone straddling 0/360 hits from the left")
  ok(fishing.angleHit(10, 0, 40), "wheel: and from the right")
  ok(not fishing.angleHit(21, 0, 40), "wheel: just outside the wrapped zone misses")
  ok(fishing.angleHit(180, 180, 24), "wheel: plain mid-dial zone hits")

  -- gap-sync (vsync) math: growth, periods, centers, and the fit verdict
  eq(fishing.vsyncScale(0, 2, 9), 1, "vsync: line starts at 1x")
  eq(fishing.vsyncScale(1, 2, 9), 3, "vsync: +2x base per second")
  eq(fishing.vsyncScale(4, 2, 9), 9, "vsync: growth caps at 9x")
  eq(fishing.vsyncScale(99, 2, 9), 9, "vsync: cap holds forever")
  eq(fishing.vsyncPeriod(0.4, 0.8, 0), 0.8, "vsync: r=0 rolls the slowest period")
  eq(fishing.vsyncPeriod(0.4, 0.8, 1), 0.4, "vsync: r=1 rolls the fastest")
  eq(fishing.oscPos(0, 0.8, 0), 0, "vsync: phase 0 starts at the top")
  eq(fishing.oscPos(0, 0.8, 0.5), 1, "vsync: phase 0.5 starts at the far end")
  eq(fishing.vsyncLineCenter(0.5, 420), 210, "vsync: line centre in lane px")
  -- trio: span 108 (36 rect / 36 gap / 36 rect); gap centre inset 54 from the trio's top
  eq(fishing.vsyncGapCenter(0, 420, 108, 36, 36), 54, "vsync: gap centre at the top stop")
  eq(fishing.vsyncGapCenter(1, 420, 108, 36, 36), 366, "vsync: gap centre at the bottom stop")
  ok(fishing.vsyncFits(210, 1, 3.6, 210, 36), "vsync: dead-centre young line fits")
  ok(fishing.vsyncFits(210, 1, 3.6, 226, 36), "vsync: young line fits at the gap edge")
  ok(not fishing.vsyncFits(210, 1, 3.6, 227, 36), "vsync: just past the edge misses")
  ok(fishing.vsyncFits(210, 9, 3.6, 211.8, 36), "vsync: full-grown line still fits centred")
  ok(not fishing.vsyncFits(210, 9, 3.6, 212, 36), "vsync: full-grown margin is razor thin")
  ok(not fishing.vsyncFits(210, 11, 3.6, 210, 36), "vsync: a line taller than the gap never fits")

  -- minigame arm chance: the diamond override applies only in-hand and only when >= 0
  eq(fishing.miniChance(false, 0.05, -1), 0.05, "fishing: base chance without the diamond rod")
  eq(fishing.miniChance(true, 0.05, -1), 0.05, "fishing: -1 override follows the base chance")
  eq(fishing.miniChance(true, 0.05, 0.5), 0.5, "fishing: diamond override wins in-hand")
  eq(fishing.miniChance(false, 0.05, 0.5), 0.05, "fishing: override ignored bare-handed")
  eq(fishing.miniChance(true, 0.05, 1.5), 1, "fishing: chance clamps to a probability")
  eq(fishing.miniChance(false, nil, nil), 0, "fishing: garbage config reads as never")

  -- worn-rod durability roll and the worn-vs-full diamond split
  eq(fishing.wornDurability(0, 200, 0.1, 0.6), 20, "fishing: worst fished rod keeps 10%")
  eq(fishing.wornDurability(1, 200, 0.1, 0.6), 120, "fishing: best fished rod keeps 60%")
  ok(fishing.wornDurability(0, 2000, 0.1, 0.6) == 200, "fishing: diamond wear scales off its own max")
  eq(fishing.wornShare("starter", "BP_DiamondFishingRod_Item_C"), 0.5,
     "fishing: starter diamond rods split worn/full 50/50 (5w vs 5w)")
  ok(math.abs(fishing.wornShare("late", "BP_DiamondFishingRod_Item_C") - 1 / 3) < 1e-9,
     "fishing: late diamond rods are full 2 times in 3 (10w worn vs 20w full)")
  eq(fishing.wornShare("late", "BP_FishingRod_Item_C"), 1.0,
     "fishing: a fished vanilla rod is ALWAYS worn (no full entry exists)")

  -- luck multiplier ladder
  eq(fishing.luckMult(false, false), 1.0, "fishing: calm daylight bare rod = x1")
  eq(fishing.luckMult(true, false), 2.0, "fishing: diamond rod = x2")
  eq(fishing.luckMult(true, true), 3.0, "fishing: diamond at twilight = the full x3 stack")
  eq(fishing.luckMult(false, true), 1.5, "fishing: twilight alone = x1.5")
end

------------------------------------------------------------------ animator (per-frame lane)
-- Drives core/animator with a hand-cranked ticker + hop: the one-job-slot, one-outstanding-hop
-- and stop-before-hop contracts that the skillshot marker stands on.
do
  local anim = require("core.animator")
  local log = require("core.log")
  local ticker
  _G.LoopAsync = function(_, fn) ticker = fn end
  local posted = {}
  ok(anim.init(log, function(fn) posted[#posted + 1] = fn end, 8), "animator: init ok")
  ok(anim.ok, "animator: flagged ready")
  ticker()
  eq(#posted, 0, "animator: idle ticks arm no hops")

  local calls = 0
  local tok = anim.start(function() calls = calls + 1; if calls >= 2 then return "stop" end end)
  ok(tok ~= nil, "animator: start returns a token")
  ticker()
  eq(#posted, 1, "animator: active job arms a hop")
  ticker()
  eq(#posted, 1, "animator: only one hop outstanding at a time")
  posted[1]()
  eq(calls, 1, "animator: the hop ran the job")
  ticker(); posted[2]()
  eq(calls, 2, "animator: second frame ran and the job stopped itself")
  ticker()
  eq(#posted, 2, "animator: a stopped job arms nothing")

  local tok2 = anim.start(function() calls = calls + 1 end)
  anim.stop(tok2)
  ticker()
  eq(#posted, 2, "animator: stop() before the tick drops the job")
  ok(not anim.active(), "animator: inactive after stop")
end

------------------------------------------------------------------ trash slot
-- features/trash_slot.lua deletes player items on purpose, so the one decision that matters --
-- "is the carried widget the swapped-out previous trash item?" -- is a pure function, tested
-- against the full gesture table from the W_InventorySlot bytecode RE. A wrong "keep" is a
-- cosmetic quirk; a wrong "destroy" eats an item the player still holds. Uncertainty must keep.
do
  local T = require("features.trash_slot")
  local decide = T.decide
  -- decide(carryExists, senderIsTrash, occupiedNow, hadPrev, stillHasPrev)
  eq(decide(false, false, true,  false, false), "keep",
     "trash: deposit into empty (carry consumed natively)")
  eq(decide(false, false, true,  true,  true),  "keep",
     "trash: full-stack merge (carry destroyed natively)")
  eq(decide(true,  false, true,  true,  false), "destroy",
     "trash: swap -- the carry holds the previous trash item")
  eq(decide(true,  false, true,  true,  true),  "keep",
     "trash: same-class stack leftover / right-click drip stays in the player's hand")
  eq(decide(true,  true,  false, true,  false), "keep",
     "trash: take-out -- the player is retrieving, never destroy")
  eq(decide(true,  true,  true,  true,  true),  "keep",
     "trash: right-click half-out keeps the carried half")
  eq(decide(true,  false, true,  false, false), "keep",
     "trash: deposit into empty then a fast next pickup -- nothing was replaced")
  eq(decide(true,  false, false, true,  false), "keep",
     "trash: refused drop (nothing landed) leaves the carry alone")
  eq(decide(true,  false, true,  true,  true),  "keep",
     "trash: failed probe reads as still-has-prev = uncertainty keeps")

  -- the class-discovery bisection, driven by a fake Contains-one-Of oracle
  local classes = {}
  for i = 1, 300 do classes[i] = "cls" .. i end
  local function oracleFor(target, failAfter)
    local calls = 0
    return function(list)
      calls = calls + 1
      if failAfter and calls > failAfter then return nil end
      for _, c in ipairs(list) do if c == target then return true end end
      return false
    end, function() return calls end
  end
  local probe, calls = oracleFor("cls137")
  local hit, alive = T.bisect(classes, probe)
  eq(hit, "cls137", "trash: bisect finds the class")
  ok(alive, "trash: bisect reports the probe path alive")
  ok(calls() <= 11, "trash: bisect stays logarithmic (" .. calls() .. " probes for 300)")
  local hit2, alive2 = T.bisect(classes, oracleFor("not-present"))
  eq(hit2, nil, "trash: bisect on an absent class finds nothing")
  ok(alive2, "trash: absent class is a clean no-hit, not a probe failure")
  local probe3 = oracleFor("cls137", 2)
  local hit3, alive3 = T.bisect(classes, probe3)
  eq(hit3, nil, "trash: a mid-bisect marshal failure returns no class")
  ok(not alive3, "trash: ...and reports the probe path dead so the caller goes linear")
  local hit4, alive4 = T.bisect({}, function() return true end)
  eq(hit4, nil, "trash: empty candidate list finds nothing")
  ok(alive4, "trash: empty list is not a probe failure")
  local hit5 = T.bisect({ "only" }, function(l) return l[1] == "only" end)
  eq(hit5, "only", "trash: single-candidate list resolves without narrowing")

  -- mapping invariants the whole design leans on
  local m = mapping.resolve("24038177")
  ok(m.trash ~= nil, "trash: mapping section present")
  eq(m.trash.backingIndex, m.trash.backingSize - 1, "trash: backing index is the last slot")
  ok(m.trash.backingSize > 50,
     "trash: backing index must be out of range for every legal player inventory (max 50)")
  eq(m.trash.slotItemField, m.wand.slotItemField, "trash: slot struct field GUIDs match wand's")
  eq(m.trash.sysReplaceFn, "ForceReplace Inventory", "trash: bulk setter keeps its real spaces")
  eq(#(m.trash.tint), 4, "trash: tint is RGBA")
  ok((gate.check(m, { "trash.invUiProp", "trash.chestSyncFn", "trash.sysContainsFn" })),
     "trash: gate sees the trash keys")
  eq(config.get("trash_slot"), true, "trash: enabled by default")
end

------------------------------------------------------------------ airship boost (pure math)
do
  local B = require("features.boost")
  eq(B.boostAddFor(50.0, 3.0), 100.0, "boost: 3X of stock 50 adds 100")
  eq(B.boostAddFor(80.0, 3.0), 160.0, "boost: scales with upgraded MaxSpeed")
  eq(B.boostAddFor(50.0, 1.0), 0.0, "boost: 1X adds nothing")
  eq(B.boostAddFor(50.0, 0.5), 0.0, "boost: sub-1 mult clamps to no boost")
  eq(B.stepToward(100, 0, 25, 0.5), 87.5, "boost: glide steps down by rate*dt")
  eq(B.stepToward(10, 0, 25, 0.5), 0, "boost: glide clamps at zero, never undershoots")
  eq(B.stepToward(0, 15, 15, 0.5), 7.5, "boost: FOV eases up by rate*dt")
  eq(B.stepToward(14, 15, 15, 0.5), 15, "boost: FOV clamps at the full bump")
  eq(B.stepToward(15, 15, 15, 0.5), 15, "boost: at target stays at target")
  eq(B.stepToward(5, 0, 0, 1), 0, "boost: zero rate (zero-length glide) is instant")
end

------------------------------------------------------------------ recall assist (pure math)
do
  local Q = require("features.qol")
  -- the travel leg: 150 units of the game's own move at x20 pushes 19x further
  local push, hxy = Q.recallPush(150, 0, 0, 20, 100000)
  eq(push, 2850.0, "recall: amplifies the game's horizontal delta by (mult-1)")
  eq(hxy, 150.0, "recall: hands back the delta length for the direction math")
  -- the standoff cap: never lands closer than 2500 to the dock
  eq((Q.recallPush(150, 0, 0, 20, 4000)), 1500.0, "recall: push capped to toDock - standoff")
  eq(Q.recallPush(150, 0, 0, 20, 2500), nil, "recall: at the standoff ring, stands down")
  eq(Q.recallPush(150, 0, 0, 20, 1000), nil, "recall: inside the ring, stands down")
  -- phase safety: vertical movement (raise/lower) is never amplified
  eq(Q.recallPush(0, 0, 180, 20, 100000), nil, "recall: pure vertical raise is left native")
  eq(Q.recallPush(30, 0, 100, 20, 100000), nil, "recall: vertical-dominant delta is left native")
  -- off states
  eq(Q.recallPush(150, 0, 0, 1.0, 100000), nil, "recall: x1 means no assist")
  eq(Q.recallPush(150, 0, 0, nil, 100000), nil, "recall: unset mult means no assist")
  eq(Q.recallPush(5, 3, 0, 20, 100000), nil, "recall: a near-idle ship is not amplified")
  -- the vertical twin: the "unstuck" descent from kilometers above the dock
  eq(Q.recallPushZ(-310, 11, 20, 348000, -5377), 5890.0,
     "recallZ: a long descent toward the dock is amplified by (mult-1)")
  eq(Q.recallPushZ(180, 0, 20, -5000, -5377), nil,
     "recallZ: the raise climbs AWAY from the dock's altitude -- never amplified")
  eq(Q.recallPushZ(-100, 5, 20, -2377, -5377), nil,
     "recallZ: inside the vertical standoff, the landing stays native")
  eq((Q.recallPushZ(-100, 5, 20, 1623, -5377)), 1900.0,
     "recallZ: near the standoff the push is amplified but the cap has room")
  eq(Q.recallPushZ(-30, 100, 20, 348000, -5377), nil,
     "recallZ: horizontal-dominant deltas belong to the travel leg")
  eq((Q.recallPushZ(100, 10, 20, -10000, 0)), 1900.0,
     "recallZ: a dock ABOVE the ship amplifies the climb toward it too")
  eq(Q.recallPushZ(-310, 11, 1.0, 348000, -5377), nil, "recallZ: x1 means no assist")
end

------------------------------------------------------------------ wand drinking (pure math)
do
  local W = require("features.wand")
  -- the invariant: a full 0->100 drink spends exactly the whole wand
  local ch, cur, spent = 240.0, 0.0, 0.0
  local steps = 0
  while cur < 100 and steps < 1000 do
    local sip, cost = W.drinkStep(ch, cur, 100.0, 25.0, 0.25, 240.0)
    if sip <= 0 then break end
    cur, ch, spent = cur + sip, ch - cost, spent + cost
    steps = steps + 1
  end
  ok(math.abs(cur - 100.0) < 1e-6, "drink: reaches full thirst")
  ok(math.abs(spent - 240.0) < 1e-6, "drink: full drink spends exactly the whole wand")
  eq(steps, 17, "drink: 100 thirst at 25/s in 0.25s whole-point sips = 17 sips (16x6 + 4)")

  -- WHOLE points only: CurPlayerThirst is an int and AddThirst's Value>0 gate is
  -- Greater_IntInt -- a fractional sip marshals to 0 and the vessel refuses (the
  -- drink-never-works bug, live-proven 2026-07-29: 62.5 refused, 62 landed)
  local sip, cost = W.drinkStep(240.0, 0.0, 1000.0, 25.0, 0.25, 240.0)
  eq(sip, math.floor(sip), "drink: sips are whole thirst points")
  eq(sip, 62, "drink: 25%/s of 1000 in 0.25s ticks = 62-point sips")

  -- near-full thirst: the sip clamps to the gap, cost scales down with it
  sip, cost = W.drinkStep(240.0, 98.0, 100.0, 25.0, 0.25, 240.0)
  ok(math.abs(sip - 2.0) < 1e-6, "drink: sip clamps to the thirst gap")
  ok(math.abs(cost - 4.8) < 1e-6, "drink: clamped sip costs pro-rata measures")

  -- nearly-dry rod: the last measures buy the whole points they can still afford
  sip, cost = W.drinkStep(3.0, 0.0, 100.0, 25.0, 0.25, 240.0)
  ok(math.abs(cost - 3.0) < 1e-6, "drink: dry rod pays out its last measures")
  eq(sip, 1, "drink: last sip floored to the whole points the measures buy")

  -- the LIVE scale: MaxPlayerThirst is 1000 in real saves (probed 2026-07-29). rate is percent
  -- of max per second, so the whole-wand invariant and the 4s full drink hold at any scale.
  local ch2, cur2, spent2, steps2 = 240.0, 0.0, 0.0, 0
  while cur2 < 1000 and steps2 < 1000 do
    local sip2, cost2 = W.drinkStep(ch2, cur2, 1000.0, 25.0, 0.25, 240.0)
    if sip2 <= 0 then break end
    cur2, ch2, spent2, steps2 = cur2 + sip2, ch2 - cost2, spent2 + cost2, steps2 + 1
  end
  ok(math.abs(cur2 - 1000.0) < 1e-6, "drink: reaches full at the live 1000-point scale")
  ok(math.abs(spent2 - 240.0) < 1e-6, "drink: whole-wand invariant holds at 1000 scale")
  eq(steps2, 17, "drink: still a ~4-second (17-tick) full drink at 1000 scale")

  -- degenerate guards
  sip, cost = W.drinkStep(0.0, 0.0, 100.0, 25.0, 0.25, 240.0)
  eq(cost, 0.0, "drink: empty rod costs nothing")
  sip, cost = W.drinkStep(240.0, 100.0, 100.0, 25.0, 0.25, 240.0)
  eq(sip, 0.0, "drink: full thirst sips nothing")
  sip, cost = W.drinkStep(240.0, 50.0, nil, 25.0, 0.25, 240.0)
  ok(sip > 0, "drink: unreadable max falls back to 100")
end

------------------------------------------------------------------ chest trio (ledger / sort / pull)
-- The three chest modules are integration-shaped (every interesting move is a reflected call),
-- so the spec pins what CAN break silently at a distance: the mapping contract they share, the
-- config surface, and that each module still loads clean with its pure exports in place.
do
  local m = mapping.resolve("24038177")
  ok(m.stock ~= nil, "stock: mapping section present")
  ok(#(m.stock.chestClasses) >= 2, "stock: sorter + plain chest both registered as holders")
  eq(m.stock.quickStackFn, "Quick Stack", "stock: Quick Stack keeps its real space")
  eq(m.stock.removeAmtFn, "Remove Item Amt", "stock: Remove Item Amt keeps its real spaces")
  eq(m.stock.invSysClass, "BC_InventorySystem_C",
     "stock: inv component class pinned (wrong-class BP calls are fatal asserts)")
  eq(m.sortchest.class, "BP_SortingChest_Placeable_C", "sortchest: pak clone class name pinned")
  ok(({ ["BP_SortingChest_Placeable_C"] = true })[m.sortchest.class] ~= nil
     and (function() for _, c in ipairs(m.stock.chestClasses) do
            if c == m.sortchest.class then return true end end return false end)(),
     "sortchest: the sorter is itself a ledger chest class (craft_pull may draw from it)")
  eq(#(m.craftpull.openFns), 3, "craftpull: bench + energy bench + kitchen all hooked")
  ok(m.craftpull.itemActorField:find("^ItemActor_16_") ~= nil,
     "craftpull: item actor field is the S_Item GUID name, not a display name")
  ok(gate.check(m, { "stock.chestClasses", "stock.invProp", "stock.amtFn" }),
     "chest_index: gate sees its keys")
  ok(gate.check(m, { "sortchest.class", "stock.quickStackFn", "stock.totalFn" }),
     "sort_chest: gate sees its keys")
  ok(gate.check(m, { "craftpull.openFns", "craftpull.partSlotClass", "stock.removeAmtFn" }),
     "craft_pull: gate sees its keys")

  eq(config.get("sort_chest"), true, "sort_chest: enabled by default")
  eq(config.get("craft_pull"), true, "craft_pull: enabled by default")
  eq(config.get("sort_chest_power_active"), 500.0, "sort_chest: 500 draw while sorting (user spec)")
  eq(config.get("sort_chest_power_idle"), 100.0, "sort_chest: 100 draw idle (user spec)")
  eq(config.get("sort_chest_range"), 5000.0, "sort_chest: 50 m radius (user spec)")
  eq(config.get("craft_pull_range"), 5000.0, "craft_pull: 50 m radius (user spec)")
  ok(config.get("chest_index_ttl") > 0, "chest_index: cached counts expire")

  ok(pcall(require, "features.chest_index"), "chest_index: module loads")
  ok(pcall(require, "features.sort_chest"), "sort_chest: module loads")
  ok(pcall(require, "features.craft_pull"), "craft_pull: module loads")
  local CI = require("features.chest_index")
  eq(type(CI.probeFor), "function", "chest_index: probe builder exported for its consumers")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
