-- =============================================================================
--  SINGLE SOURCE OF TRUTH for every game-specific symbol.
--  Fill these in from a UE4SS dump — see docs/REVERSE-ENGINEERING.md.
--  Anything left nil disables its feature (logged at startup). NEVER hardcode a
--  game class / function / property anywhere else in the codebase — only here.
--  On a game update, add a new profile keyed by the new build id and override only
--  what moved (see docs/RELEASE-CHECKLIST.md).
-- =============================================================================
local M = {}

-- Every symbol the mod can use, grouped by section. This schema drives the
-- startup "what's still missing" report; keep it in sync with the profiles below.
M.schema = {
  weather  = { "managerClass", "currentProp", "severityProp", "onChangedFn", "stormValue", "startStormFn", "stopStormFn", "thunderFn", "thunderLocXProp", "thunderLocYProp", "boltActorClass", "boltActorPath", "windIntensityProp", "setWindIntensityFn", "windAudioFn" },
  player   = { "controllerClass", "curHealthProp", "maxHealthProp", "addHealthFn", "reduceHealthFn", "dieFn", "respawnFn", "pingFn", "curThirstProp", "maxThirstProp", "addThirstFn", "clientAddThirstFn" },
  pawn     = { "class", "healthProp", "isShelteredFn", "worldLocationFn", "respawnFn", "dropInventoryFn", "playerIdProp" },
  build    = { "pieceClass", "stableIdProp", "demolishFn", "demolishRefund" },
  crop     = { "class", "killNoSeedFn" },
  battery  = { "class", "chargeProp", "maxChargeProp", "classHints", "chargePropCandidates", "maxChargePropCandidates",
               "componentProp", "curStoredProp", "maxStoredProp", "updateFn" },
  machine  = { "classes", "generatorHints", "techSuffixes", "excludeHints", "salvageDefault" },
  airship  = { "class", "healthProp", "isFlyingFn", "crashFn" },
  island   = { "class" },
  unlock   = { "registerFn" },
  craft    = { "repairItemId", "addRecipeFn" },
  buildmenu = { "registerFn" },
  energy   = { "linkFn" },
  smoke    = { "shipDamageVfxFn" },
  net      = { "hasAuthorityFn", "playerStateClass" },
  save     = { "saveFn", "loadFn" },
  items    = { "classFmt", "assetDir" },
  tree     = { "classPrefix", "fellFn", "growMeshesProp", "fakeMeshProp" },
  animal   = { "sheepClass", "chickenClass" },
  ritual   = { "bookItemRow", "hydrationOfferings", "electrickOfferings",
               "candleBurningProp", "candleBurnRepFn" },
  fx       = { "clientDamageRpcFn", "buzzSoundProp" },
  furnace  = { "classHints", "fuelPropCandidates", "fuelFnCandidates" },
  rod      = { "stationClassCandidates", "copperItemRow" },
  wand     = { "castFnExact", "castFnPrefix", "smcPath", "stickMesh", "cobaltMesh",
               "diamondMesh", "meshPaths", "niagaraCandidates", "handMeshFn", "handSlot1P",
               "handSlot3P", "handBlueprintFn", "handItemProp", "handItemMeshProps",
               "handItemDonor", "handItemDonorPath", "clearHandFn", "materialDir", "stashFn",
               "restoreFn", "hotbarChangedFn", "handRebuildFn", "durabilityFn", "localControllerProp",
               "hotbarWidgetProp", "hotbarRefreshFn", "inventorySystemProp", "invChangedFn",
               "itemRows", "holdItemFn", "handItemDataProp", "holdIndexFn", "removeQtyAtIndexFn",
               "overwriteSlotFn", "slotItemField", "slotQtyField", "slotSavedataField",
               "forceHandRefreshFn", "waterFxRpcFn",
               "waterStorageClass", "storageAddWaterFn", "consumeEffectsFn", "waterTouchFns",
               "drinkClasses", "wateringFxComponentClass", "sprayRegisterFn", "sprayPlayFn" },
  codex    = { "itemRow", "widgetClass", "widgetPath", "placeableClass", "placeablePath",
               "interactFnHint", "openFn", "wblPath", "closeFns", "inputUiFn", "inputGameFn",
               "guideProp", "researchId", "researchTierId", "researchHasFn", "researchSaveFn",
               "researchFieldId", "researchFieldDone" },
  foundation = { "previewPaths", "buildSystemClass", "buildSystemPath", "gateFn", "ruleFn",
                 "snapProp", "previewProp" },
}

M.profiles = {
  -- Values common to all builds. Only genuinely stable UE engine symbols belong here.
  default = {
    pawn = { worldLocationFn = "K2_GetActorLocation" }, -- standard AActor UFUNCTION
    net  = { hasAuthorityFn  = "HasAuthority" },         -- standard AActor UFUNCTION
    wand = { smcPath = "/Script/Engine.StaticMeshComponent" }, -- rig comps live ON the pawn
  },

  -- ---- Current tested build. Mapped live from re_capture_latest.txt (build 24038177). ----
  ["24038177"] = {
    -- Weather lives on BP_DayNightCycle_C. It exposes Instant* setters + PlayThunder (all no-arg).
    -- No safe "current weather" scalar was found (state is a struct we must not read), so storms
    -- are keybind-driven for now rather than polled — currentProp/severityProp intentionally nil.
    weather = {
      managerClass    = "BP_DayNightCycle_C",
      startStormFn    = "InstantThunderstorm",  -- instantly begins a thunderstorm
      stopStormFn     = "InstantSunny",         -- clears it
      thunderFn       = "PlayThunder",          -- audible/sky-flash thunder cue (NOT a located bolt)
      -- (StartThunderLoop exists but is a runaway loop that InstantSunny won't stop -- do NOT use it)
      thunderLocXProp = "Thunderimpactlocx",    -- impact loc the game's own loop writes (informational --
      thunderLocYProp = "Thunderimpactlocy",    -- verified live: PlayThunder does NOT read these to spawn a bolt)
      -- The REAL visible bolt (beam VFX + point light + scorch decal + NS_Thunder_Explode) is this
      -- self-contained actor; the game's thunder loop spawns it at the impact point. It must be
      -- DEFERRED-spawned (transform before BeginPlay) or its effects fire at the world origin.
      boltActorClass  = "BP_LightningPlayer_C",
      boltActorPath   = "/Game/Art/ArtBlueprints/BP_LightningPlayer.BP_LightningPlayer_C",
      -- InstantThunderstorm raises wind to ~5.0 and InstantSunny never lowers it (stuck high winds).
      -- Verified live: DEBUG_SetWindIntensity alone does NOT move the realtime value; writing the
      -- property directly + refreshing audio does. Storms restore the pre-storm value on stop.
      windIntensityProp  = "WindIntensityRealtime",
      setWindIntensityFn = "DEBUG_SetWindIntensity",
      windAudioFn        = "Set Wind Audio for Wind Intensity",
    },
    -- UniquePlayerID lives on BOTH the pawn and the controller (capture): the stable per-player
    -- key. identity.idOf's location-derived fallback drifts as a player walks -- never use it
    -- for state that must survive movement (the wand's owner map learned this the hard way).
    pawn = { class = "BP_MainPlayerCharacter_C", playerIdProp = "UniquePlayerID" },
    -- Player survival stats live on the controller (real HP -> genuinely deadly + native respawn).
    player = {
      controllerClass = "BP_MainPlayerController_C",
      curHealthProp   = "CurPlayerHealth",
      maxHealthProp   = "MaxPlayerHealth",
      addHealthFn     = "AddHealth",         -- AddHealth(AddBy): healing only -- does NOT handle death
      -- "Reduce Health"(ReduceBy) is the game's real damage entry: it clamps, and on reaching 0 it
      -- runs the native death flow (Die -> death-loot drop at the spot -> respawn -> HP reset).
      -- Damage MUST go through it; AddHealth(-dmg)+Respawn() leaves <=0 HP and drops no loot.
      reduceHealthFn  = "Reduce Health",
      dieFn           = "Die",               -- backstop only, if Reduce Health somehow didn't kill
      respawnFn       = "Respawn",           -- raw teleport-respawn; NOT part of the damage path
      -- MULTI_Ping(Location) is the "ping accepted, marker placed here" broadcast: on the host it
      -- fires exactly once per successful ping (the host's own AND every client's) with the final
      -- marker location. Do NOT hook SERVER_Ping -- that is the request RPC, upstream of the
      -- BlockPing/ResetPing cooldown gate, so it can fire for pings the game rejects (bolt with no
      -- visible marker). Verified live 2026-07-20: SERVER_Ping -> MULTI_Ping, identical Location.
      pingFn          = "MULTI_Ping",
      -- Thirst mirrors the health API exactly (offline RE of BP_MainPlayerController,
      -- 2026-07-21): AddThirst(Value, PlaySound) -> Success restores the drink meter;
      -- CLIENT_AddThirst(Value, PlaySound) is the game's own owning-client RPC (the thirst
      -- state lives on each player's machine, like CLIENT_ReduceHealth for damage) -- the
      -- Hydration Wand quenches REMOTE teammates through it.
      curThirstProp     = "CurPlayerThirst",
      maxThirstProp     = "MaxPlayerThirst",
      addThirstFn       = "AddThirst",
      clientAddThirstFn = "CLIENT_AddThirst",
    },
    -- Every inventory item's actor class is BP_<Name>_Item_C, but row->name is NOT 1:1
    -- (HoeDiamond -> Hoe_Diamond, Weather_Station -> WeatherStation): core/items.lua tries the
    -- variants. All 300 item classes live flat in assetDir (verified live via full-object scan).
    items  = { classFmt = "BP_%s_Item_C", assetDir = "/Game/Code/Inventory_Items/ItemActors/" },
    -- BP_Tree_Birch_C confirmed live; suffix names the type. Native felling symbols from the
    -- offline bytecode RE of _BP_Tree_MASTER (2026-07-21): TreeFall is the no-arg fell event
    -- (falling animation + FallingSound + ground-hit + grow-stage loot; replicates natively).
    -- Growth check = the tree's own `HasGrown?` logic replicated by reads (its out-param
    -- signature is awkward from Lua): FakeTreeMesh.StaticMesh equals the LAST GrowMeshes entry
    -- only when fully grown. GrowMeshes lives on the parent _BP_Plant_MASTER_C -- still a plain
    -- instance read off any tree.
    tree   = { classPrefix = "BP_Tree_", fellFn = "TreeFall",
               growMeshesProp = "GrowMeshes", fakeMeshProp = "FakeTreeMesh" },
    animal = { sheepClass = "BP_Animal_Sheep_C", chickenClass = "BP_Animal_Chicken_C" },
    -- The wand is NOT an inventory item: it is a mod-managed tool (see features/wand.lua).
    -- A truly new inventory item ID requires a cooked content pak (docs/MILESTONE-2.md).
    ritual = {
      bookItemRow = "Handbook",     -- the dark-arts book prop
      -- The five corner offerings, dropped on the ground by the pentagram's candles. These are
      -- the WORLD item-actor classes (dropped items spawn the row's ItemActor -- pawn RE:
      -- TryAddItemWithLeftoverSpawn -> SpawnLeftoverItem), verified against the legacy
      -- ItemActors dir. "Water clear of impurities" = the BOILED carafe's world actor;
      -- dirty water (BP_CarafeDirtWater_Item) does not count.
      -- Per-rite corner offerings (kind -> dropped item-actor class, or a LIST of acceptable
      -- classes; one of each kind by the candles). The boiled carafe IS the game's purified
      -- tier ("Water Bottle"); no bandage exists, so the wound-dressing is Cloth. Verified
      -- against db_items_src.json 2026-07-22.
      hydrationOfferings = {
        water = "BP_CarafeDrinkableWater_Item_C",  -- water clear of impurities
        -- user swapped honey -> beeswax 2026-07-22 (the wand IS a wax-sealed stick; the wax
        -- calls to the wax)
        wax   = "BP_Beeswax_Item_C",               -- wax of the honeybee
        leaf  = "BP_Leaf_Item_C",                  -- leaf of the trees
        -- clay dropped from inventory spawns the GRABITEM form, not the _Item actor (live
        -- census at the pentagram 2026-07-22; Stick/Stone share this dual-class pattern)
        clay  = { "BP_Clay_Item_C", "BP_Clay_GrabItem_C" },  -- clay of the earth
        berry = "BP_Raspberry_Item_C",             -- a berry nourished by the sun
      },
      electrickOfferings = {
        copper    = "BP_Copper_Item_C",                -- rounded refined copper (the smelted bar)
        ironore   = "BP_IronOre_Item_C",               -- raw iron ore
        purewater = "BP_CarafeDrinkableWater_Item_C",  -- purified water
        flower    = "BP_Sunflower_Item_C",             -- flower of the sun
        cloth     = "BP_Cloth_Item_C",                 -- cloth that dressed an old wound
      },
      -- Candle lighting (offline RE of BP_Candle_Plate/BP_Deco_Candle_Outdor Buildables):
      -- `Burning` is the replicated state bool; OnRep_Burning applies flame + PointLight
      -- visibility and starts the burn timer. Host sets the bool then calls the OnRep to apply
      -- it locally -- clients get it via native replication.
      candleBurningProp = "Burning",
      candleBurnRepFn   = "OnRep_Burning",
    },
    fx = {
      clientDamageRpcFn = "CLIENT_ReduceHealth", -- game's own client RPC: fires ON the victim's machine
      buzzSoundProp     = "ThunderSound",        -- weather-manager sound reused (pitched) as the buzz
    },
    -- Machine/furnace internals live in parent classes the capture didn't dump; classify by class
    -- NAME and probe candidate members (all pcall-guarded). Re-dump at a base to pin exact names.
    battery = {
      classHints = { "Battery" },
      -- The REAL charge state (offline RE of BP_Battery_Placeable + BPC_Battery_EnergySystem-
      -- Component 2026-07-22): the actor only mirrors `CurPowerStoredForReplication`; the
      -- authoritative int lives on the COMPONENT. Write CurPowerStored = MaxPowerStored, then
      -- call UpdateBattery(false) -- the game's own charge tick: it re-clamps, marks the
      -- property dirty, and fires OnBatteryCapacityChanged (-> display + replication mirror +
      -- periodic SaveData) and OnBatteryFull. Never write the replication mirror directly:
      -- the component overwrites it on its next tick.
      componentProp = "BPC_Battery_EnergySystemComponent",
      curStoredProp = "CurPowerStored",
      maxStoredProp = "MaxPowerStored",
      updateFn      = "UpdateBattery",   -- (Discharging: bool) -- false = one charge step
      -- Legacy actor-prop probes (pre-RE guesses; kept as the degrade path for a game update):
      chargePropCandidates    = { "CurCharge", "CurrentCharge", "Charge", "CurEnergy", "StoredEnergy", "CurPower", "Energy" },
      maxChargePropCandidates = { "MaxCharge", "MaxEnergy", "MaxPower", "Capacity" },
    },
    furnace = {
      classHints         = { "Furnace", "Furnance" },  -- game itself misspells "Furnance" in DB_Items
      fuelPropCandidates = { "BurnTimeLeft", "CurBurnTime", "FuelTime", "RemainingBurnTime", "BurnTime" },
      fuelFnCandidates   = { "AddFuel", "ConsumeFuel", "StartBurning", "AddBurnTime" },
    },
    machine = {
      generatorHints = { "Generator", "Windmill", "SkyTurbine", "Turbine", "Solarpanel" },
      techSuffixes   = { "_Buildable_C", "_Placeable_C" },
      excludeHints   = { "Candle", "Fence", "Deco_", "Sign", "Torch", "Preview" },
      salvageDefault = { ScrapMetal = 1, Iron = 1 },  -- half-components fallback (recipes unreadable from Lua)
    },
    -- The wand tool (RE'd live 2026-07-21, probes P1-P6 -- see the gotchas memory):
    wand = {
      -- Generic left click, independent of the held tool (fires with empty hands). AltHandInteract
      -- is right click -- the prefix below deliberately does not match it.
      castFnExact  = "PressedHandInteraction",
      castFnPrefix = "InpActEvt_IA_HandInteract",
      -- Mesh ASSETS by name (loaded-StaticMesh scan; CDO template reads are fatal):
      stickMesh   = "SM_Stick",       -- the wand handle
      cobaltMesh  = "SM_Cobalt",      -- blue material donor (Electric/uncharged tint)
      diamondMesh = "SM_Ore_Diamond", -- white material donor (Charged tint)
      -- Full object paths for LoadAsset when a mesh above is NOT already in memory. SM_Stick is
      -- only resident if a stick actor happens to exist in the world (the base Stick never renders
      -- in-hand), so the wand's visual MUST be able to force-load it. Paths verified against the
      -- retoc legacy extract (tools/pakkit/legacy/Solarpunk/Content/Art/StaticMeshes/).
      meshPaths = {
        SM_Stick       = "/Game/Art/StaticMeshes/SM_Stick.SM_Stick",
        SM_Cobalt      = "/Game/Art/StaticMeshes/SM_Cobalt.SM_Cobalt",
        SM_Ore_Diamond = "/Game/Art/StaticMeshes/SM_Ore_Diamond.SM_Ore_Diamond",
      },
      -- The game's flat materials dir: tint materials load from here BY NAME (config wand_mat_*).
      -- Verified against the legacy extract (Art/Materials/ -- M_Cobalt, M_Deco_Logs,
      -- M_Stick_Highlighted all live here).
      materialDir = "/Game/Art/Materials/",
      niagaraCandidates = { "NS_Electricity", "NS_Sparks", "NS_Dizzle" },
      -- How the game holds tools (from the capture): the selected hotbar item's mesh lives in
      -- two right-hand slot components on the pawn; the fns below are the game's own equip
      -- machinery, which the drawn wand rides (features/wand.lua).
      -- WARNING (proven fatal 2026-07-21 12:22, step-log): ATTACHING a component to these slot
      -- comps (K2_AttachToComponent) native-crashes -- the slots are position-READ only. The
      -- mesh-set path (handMeshFn) survived its live call but is currently unused.
      handMeshFn      = "SetHandRMeshForBoth",        -- set a tool mesh into both slots at once
                                                      -- (slots are never visible for consumables --
                                                      -- kept only as a do-no-harm fallback)
      handSlot1P      = "Mesh_Slot_1Person_Hand_R",   -- first-person right-hand tool slot
      handSlot3P      = "Mesh_Slot_3rdPerson_Hand_R", -- third-person right-hand tool slot
      -- THE real held-item render path (offline bytecode RE of BP_MainPlayerCharacter,
      -- 2026-07-21, tools/pakkit HOWTO "how held items render"): every VISIBLE held item is a
      -- spawned BP_HandItem_* actor. For consumables, UpdateHandConsumable does
      -- Map_Find(ClassesToActor, CurItemdataInHand.ItemActor) -> SetHandRBlueprintForBoth(found),
      -- where ClassesToActor is a 21-entry class->class map BAKED into the bytecode. Sticks (and
      -- our wand rows) are not in the map -> the game passes null -> empty palm. NOTE: the pawn
      -- has NO FoodMesh property -- that component lives on the consumable HAND-ITEM actors
      -- (the earlier "pawn.FoodMesh" mapping was a mis-probe; step log proved it missing).
      handBlueprintFn = "SetHandRBlueprintForBoth",   -- spawn+attach+track a hand-item actor; also
                                                      -- DESTROYS the previous one (game-owned lifecycle)
      handItemProp    = "CurHandItemFirstPerson",     -- pawn prop -> the spawned hand-item actor
      handItemMeshProps = { "FoodMesh", "MainMesh" }, -- mesh comps on that actor (first hit wins)
      handItemDonor   = "BP_HandItem_Carrot_C",       -- donor class: elongated food = stick stand-in
      handItemDonorPath = "/Game/Code/Character/HandItems/BP_HandItem_Carrot.BP_HandItem_Carrot_C",
      clearHandFn     = "ClearHandBlueprints",        -- pawn event: destroy held hand-item actors
      stashFn         = "StashHandItem",              -- park the held item (drawing does this first)
      restoreFn       = "RestoreHandItem",            -- re-equip the parked item (stowing)
      hotbarChangedFn = "HotbarSlotChanged",          -- fires on tool switch -> the wand stows
      handRebuildFn   = "UpdateHandMeshesAndModes",   -- the ONE equip chokepoint (offline RE
                                                      -- 2026-07-22): hotbar switches AND every
                                                      -- UI close (SetInputModeGame ->
                                                      -- ForceUpdateHotbarSlot) funnel through
                                                      -- it before SetHandRBlueprintForBoth
                                                      -- destroys+respawns the hand actor
      durabilityFn    = "DecreaseCurItemDurability",  -- pawn fn: step the held item's bar down.
                                                      -- TWO params (offline bytecode dump
                                                      -- 2026-07-22): DecreaseAmt + an OUT bool
                                                      -- ItemDestroyed. UE4SS REFUSES the call
                                                      -- unless the OUT slot gets a fresh Lua
                                                      -- TABLE (one arg or a scalar there =
                                                      -- pcall error, the frozen-bar bug); the
                                                      -- out value lands in the table (outVal).
                                                      -- At 0 the item IS destroyed (the
                                                      -- last-bolt transmute rides that).
      -- Real inventory removal (offline RE 2026-07-22, BC_InventorySystem dump). ConsumeItem
      -- is the consumable EAT path and silently no-ops on the rods -- it must never be used
      -- for item swaps (the transmute-duplication loop).
      holdIndexFn        = "GetInventoryIndexForCurHoldItem", -- pawn fn -> held slot's index (ret int)
      removeQtyAtIndexFn = "Remove Item Qty at Index",        -- InventorySystem fn (spaces in the
                                                              -- FName are real): Index, Qty,
                                                              -- out Success
      -- In-place slot rewrite (offline RE 2026-07-22): the watering-can behavior. Replaces a
      -- slot's item/qty/savedata wholesale WITHOUT freeing it -- transmutes and bar refills
      -- keep the wand in its slot instead of destroy+regrant (which landed the replacement
      -- wherever the spawner liked, or on the ground). Slot struct = S_InventorySlotSlim,
      -- passed as a Lua table keyed by full GUID field names (the proven struct-param path).
      -- Savedata JSON is byte-exact from a live .sav: '{\r\n\t"Durability": N\r\n}'.
      overwriteSlotFn    = "OverwriteAndSaveItemAtIndex",     -- InventorySystem fn: (NewItem, Index)
      slotItemField      = "Item_4_B9922CA845A5618A776EAFAB1A690E93",
      slotQtyField       = "Quantity_5_A1813C42482CE5E7961C589A983BD034",
      slotSavedataField  = "AdditionalSavedata_12_7C875E564155FCA4AA2B4597ACB03361",
      forceHandRefreshFn = "ForceUpdateHotbarSlot",           -- pawn fn, no args: re-read the
                                                              -- active slot into the hand
      waterFxRpcFn       = "SERVER_WaterCanParticles",        -- controller RPC (offline RE of
                                                              -- BP_HandItem_Watercan's watering
                                                              -- tick): (ParticleManager, State,
                                                              -- TargetPlayer) -- the can's pour
                                                              -- stream, on/off. BANNED for the
                                                              -- wand (live 2026-07-23): flips the
                                                              -- pawn's watering pose, kills our
                                                              -- hand actor, and the stream NS
                                                              -- rides the CAN hand item we lack
      -- Redrawing the charge bar (same RE): the decrement chain writes the inventory slot but
      -- never refreshes the HOST's hotbar UI (no OnRep on authority, no broadcast), so the bar
      -- only moved on a slot switch. The mod runs the game's own widget refresh after each step.
      localControllerProp = "LocalController",        -- pawn prop -> BP_MainPlayerController
      hotbarWidgetProp    = "UI_Hotbar",              -- controller prop -> W_PlayerHotbar
      hotbarRefreshFn     = "UpdateHotbar",           -- re-DisplayItems every hotbar slot
      inventorySystemProp = "InventorySystem",        -- pawn prop -> BC_InventorySystem_C
      invChangedFn        = "CallInventoryChanged",   -- refresh the open inventory grid too
      -- REAL cooked items added by the content pak (tools/pakkit, Solarpunk-Windows_1_P). These
      -- are DB_Items rows -> core/items resolves them to BP_<row>_Item_C. Only present when the
      -- pak is installed; `sps_wand give` grants them, no-ops with a warning otherwise.
      itemRows = { mundane = "MundaneWand", hydration = "HydrationWand",
                   electric = "ElectricWand", charged = "ChargedElectricWand" },
      -- The Hydration Wand's plumbing (offline RE 2026-07-21, BP_HandItem_Watercan +
      -- BC_WaterStorage + pawn dumps):
      --   * every waterable thing (growbox etc.) carries a replicated BC_WaterStorage_C
      --     component (MaxWaterLevel 20 on the growbox); AddWater(AddAmt) fills it and
      --     OnRep_CurWaterLevel carries it to clients -- host-side call is enough.
      --   * AddConsumeableEffects(ConsumeableClass) runs on the pawn for every eaten/drunk
      --     item -- the drink-refill hook reads the class param and matches the two carafes
      --     (pure or dirty; the wand does not judge).
      --   * PlayWaterFootstep/PlayWaterLand fire on the pawn when wading/landing in
      --     pond or river water -- the event-driven "standing in water" refill (a poll-free
      --     signal; free-running UObject timers are the proven native crash).
      waterStorageClass = "BC_WaterStorage_C",
      storageAddWaterFn = "AddWater",
      consumeEffectsFn  = "AddConsumeableEffects",
      waterTouchFns     = { "PlayWaterFootstep", "PlayWaterLand" },
      drinkClasses      = { "BP_CarafeDrinkableWater_Item_C", "BP_CarafeDirtWater_Item_C" },
      -- The watercan's splash, borrowed for the wand's pour (offline RE of BP_HandItem_Watercan +
      -- BC_WateringParticleManager): the WATERED TARGET (growbox and kin) carries the particle-
      -- manager component; register the pouring pawn, then play. Plain BP calls -- the component's
      -- own bytecode does the Niagara spawning (reflected Niagara statics from Lua are a PROVEN
      -- NATIVE CRASH -- the 2026-07-21 live experiment took the game down; never call them).
      wateringFxComponentClass = "BC_WateringParticleManager_C",
      sprayRegisterFn   = "RegisterWateringPlayer",   -- (WateringPlayerRef: BP_MainPlayerCharacter_C)
      sprayPlayFn       = "PlayParticleEffect",       -- (WatertickTime: float seconds)
      -- How the mod recognises that the REAL wand item is the one now in hand, so it can draw the
      -- stick+cobalt rig (a brand-new item can't be a first-class hand tool from pak data alone --
      -- the hoe-type path crashes world load -- so the mod supplies the in-hand look). RE probe
      -- 2026-07-21 (game running): `handItemDataProp` is the live S_Item struct; read its
      -- `ItemActor` member (a UClass, e.g. BP_MundaneWand_Item_C) to identify the wand -- the
      -- struct's DisplayName reads EMPTY at runtime. `holdItemFn` is a Blueprint fn with out-params
      -- (CurItem, EmptyHand), NOT a clean 0-arg getter, so it is documented but unused.
      holdItemFn       = "GetCurrentHoldItem",
      handItemDataProp = "CurItemdataInHand",
    },
    -- The Tempest Codex: a REAL readable book from the content pak (tools/pakkit build_wand_pak,
    -- "The Tempest Codex" in HOWTO.md). Craft by hand (starting recipe) -> place -> interact to
    -- read. The cooked chain clones the survival guide's UI: our widget + placeable + tips table.
    codex = {
      itemRow        = "TempestCodex",             -- DB_Items row (pak); DB_Buildables matches by this name
      widgetClass    = "W_TempestCodex_C",         -- the reader UI (clone of W_SurvivalGuide)
      widgetPath     = "/Game/UI/Widgets/W_TempestCodex.W_TempestCodex_C",
      placeableClass = "BP_TempestCodex_Placeable_C",
      placeablePath  = "/Game/Code/Building_Placing/Placeables/BP_TempestCodex_Placeable.BP_TempestCodex_Placeable_C",
      -- the placed book's interact entry: the clone keeps the guide's component-bound event name
      -- (BndEvt__..._OnInteractedWith...); features/codex.lua hooks any class fn containing this
      interactFnHint = "OnInteractedWith",
      openFn         = "Open",                     -- W_SurvivalGuide's own show fn (focus + sound)
      closeFns       = { "Close", "Hide" },        -- widget events that shut the cover
      -- the controller's own input-mode pair (offline RE of BP_MainPlayerController's ubergraph:
      -- every UI_Open* calls SetInputModeUI(widget, false, IsGamepad, false, true) and closes
      -- through SetInputModeGame(false, false, false)) -- codex.lua mirrors those exact calls
      inputUiFn      = "SetInputModeUI",
      inputGameFn    = "SetInputModeGame",
      -- the controller's named slot for the survival guide in its HARDCODED interactable-UI
      -- registry (Is An Interactable UIOpen / CloseOpenInteractableUIs / HideAllUI). While the
      -- codex is open, codex.lua repoints this property at our widget so the pawn's input gates
      -- and the ESC close path treat the codex exactly like the guide (all by-name virtuals).
      guideProp      = "UI_SurvivalGuide",
      wblPath        = "/Script/UMG.Default__WidgetBlueprintLibrary", -- CreateWidget from Lua
      -- "The Dark Arts" research-card migration (RE'd from BP_MainPlayerController):
      -- a card is visible iff the player's saved Researches array holds {id, Researched=false}.
      -- Old saves that already researched LvL_2 (id 9) never re-fire its unlock list, so
      -- features/codex.lua plants our card's entry once via Playerdata_SaveResearchForSelf,
      -- which takes S_SavedResearch as a Lua table keyed by the BP-struct's suffixed fields.
      researchId        = 3003,                     -- The Dark Arts (DB_Researchables)
      researchTierId    = 9,                        -- LvL_2 = station tier 2
      researchHasFn     = "HasPlayerResearch?",     -- (id, out CanResearch, out IsResearched)
      researchSaveFn    = "Playerdata_SaveResearchForSelf", -- (S_SavedResearch)
      researchFieldId   = "ResearchableID_2_DA642A8A46295C1414CDABA93A97CC99",
      researchFieldDone = "Researched_10_AA0B145346A35A6CF07D1E8C2C8D0CBD",
    },
    foundation = {
      -- Placement rule bypass (offline RE of BC_BuildSystem + the foundation previews):
      -- ComplyFunctionalBuildRules? asks the preview's TestAdvancedBuildingRule, whose
      -- foundation overrides line-trace all four GroundCheck corner components to the ground
      -- and veto the build if any corner floats. BC_BuildSystem.IsSnapping is true exactly
      -- while the preview sits on another buildable's snap point, so features/foundation.lua
      -- post-hooks each override and forces CanBuild back to true when snapping.
      previewPaths = {
        "/Game/Code/Building_Placing/AdvancedPreviews/BP_Foundation_AdvancedPlaceablePreview.BP_Foundation_AdvancedPlaceablePreview_C",
        "/Game/Code/Building_Placing/AdvancedPreviews/BP_BrickFoundation_AdvancedPlaceablePreview.BP_BrickFoundation_AdvancedPlaceablePreview_C",
        "/Game/Code/Building_Placing/AdvancedPreviews/BP_GlassFoundation_AdvancedPlaceablePreview.BP_GlassFoundation_AdvancedPlaceablePreview_C",
        "/Game/Code/Building_Placing/AdvancedPreviews/BP_ThinGlassFoundation_AdvancedPlaceablePreview.BP_ThinGlassFoundation_AdvancedPlaceablePreview_C",
      },
      buildSystemClass = "BC_BuildSystem_C",
      buildSystemPath  = "/Game/Code/Building_Placing/Framework_and_Data/BC_BuildSystem.BC_BuildSystem_C",
      gateFn           = "ComplyFunctionalBuildRules?",  -- build-mode-only; arms the preview hooks
      ruleFn           = "TestAdvancedBuildingRule",
      snapProp         = "IsSnapping",
      previewProp      = "BuildingPreview",
    },
    rod = {
      stationClassCandidates = {
        -- Placed class inferred from the live preview BP_WeatherStation_AdvancedPlaceablePreview_C.
        "BP_WeatherStation_AdvancedPlaceable_C",
        "BP_Weather_Station_Buildable_C", "BP_WeatherStation_Buildable_C",
        "BP_Weather_Station_Placeable_C", "BP_WeatherStation_Placeable_C",
      },
      copperItemRow = "Copper",
    },
    -- Still to map for later phases (from the dump):
    -- GameInstance = BP_SkyGameInstance_C, GameState = BP_SkyGameGameState_C,
    -- WorldStateManager = BP_WorldStateManager_C, DataTables DB_Items/DB_Buildables/...
  },
}

-- Resolve the effective map for a build id (build profile over default). Returns map, isKnownBuild.
function M.resolve(buildId)
  local prof = M.profiles[buildId]
  local base = M.profiles.default or {}
  local map = {}
  for section, keys in pairs(M.schema) do
    map[section] = {}
    for _, k in ipairs(keys) do
      local v
      if prof and prof[section] and prof[section][k] ~= nil then
        v = prof[section][k]
      elseif base[section] and base[section][k] ~= nil then
        v = base[section][k]
      end
      if v ~= nil then map[section][k] = v end
    end
  end
  return map, prof ~= nil
end

-- The still-nil symbols as sorted "section.key" strings (the RE punch-list).
function M.missing(map)
  local out = {}
  for section, keys in pairs(M.schema) do
    for _, k in ipairs(keys) do
      if not map[section] or map[section][k] == nil then
        out[#out + 1] = section .. "." .. k
      end
    end
  end
  table.sort(out)
  return out
end

return M
