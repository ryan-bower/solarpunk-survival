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
  weather  = { "managerClass", "currentProp", "severityProp", "onChangedFn", "stormValue", "startStormFn", "stopStormFn", "hardStopFn", "thunderFn", "thunderLocXProp", "thunderLocYProp", "boltActorClass", "boltActorPath", "windIntensityProp", "setWindIntensityFn", "windAudioFn", "isDayProp", "isNightProp", "rainTimelineProp" },
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
  save     = { "saveFn", "loadFn", "managerClass", "managerProp", "gameStateClass",
               "autosaveArmFn", "intervalProp", "saveDoneFns" },
  savemenu = { "menuClass", "menuOpenFn", "buttonsBoxProp", "resumeButtonProp", "buttonClass",
               "buttonPath", "buttonTextFn", "buttonClickFn",
               "boxAddFn", "boxRemoveFn", "boxHasFn", "slotPadFn", "wblPath",
               "setAngleFn", "renderTransformProp", "angleField", "buttonAngle" },
  items    = { "classFmt", "assetDir" },
  tree     = { "classPrefix", "fellFn", "growMeshesProp", "fakeMeshProp" },
  animal   = { "sheepClass", "chickenClass", "pigClass", "masterClass", "classPaths",
               "nameProp", "montageSetFn", "montageSleepValue", "montageWalkValue",
               "montageStandValue", "moveCompProp",
               "maxWalkSpeedProp", "brainProp", "stopLogicFn", "stopLogicFns", "isOwnedFn",
               "moveToActorFn", "moveToLocationFn", "stopMovementFn", "audioCompProp",
               "soundDir", "soundsChicken", "soundsSheep", "screamChicken", "spawnLights" },
  ritual   = { "bookItemRow", "hydrationOfferings", "electrickOfferings",
               "candleBurningProp", "candleBurnRepFn" },
  fx       = { "clientDamageRpcFn", "buzzSoundProp" },
  furnace  = { "classHints", "fuelPropCandidates", "fuelFnCandidates" },
  rod      = { "stationClassCandidates", "copperItemRow" },
  fishing  = { "riverClass", "loottableProp", "lootItemField", "lootWeightField",
               "rodHandClass", "rodHandPath", "lootTickFn", "canCatchProp", "swimmerProp",
               "biteBonusProp", "rodInUseProp",
               "splashWavePath", "useRodFn", "equipModeFn", "rodItemClass", "diamondRow",
               "rodDurability", "diamondDurability", "invArrayProp",
               "handsMeshProp", "animItemEnumProp", "animItemEnumValue",
               "imagePath", "canvasAddFn", "userWidgetPath", "canvasPanelPath", "wblPath" },
  wand     = { "castFnExact", "castFnPrefix", "smcPath", "stickMesh", "cobaltMesh",
               "diamondMesh", "meshPaths", "niagaraCandidates", "handMeshFn", "handSlot1P",
               "handSlot3P", "handBlueprintFn", "handItemProp", "handItemMeshProps",
               "handItemDonor", "handItemDonorPath", "clearHandFn", "materialDir", "stashFn",
               "restoreFn", "hotbarChangedFn", "handRebuildFn", "durabilityFn", "localControllerProp",
               "hotbarWidgetProp", "hotbarRefreshFn", "inventorySystemProp", "invChangedFn",
               "itemRows", "holdItemFn", "handItemDataProp", "holdIndexFn", "removeQtyAtIndexFn",
               "overwriteSlotFn", "slotItemField", "slotQtyField", "slotSavedataField",
               "forceHandRefreshFn", "waterFxRpcFn",
               "gesturePourFn", "gesturePourStopFn", "gestureCastFn",
               "waterStorageClass", "storageAddWaterFn", "consumeEffectsFn", "waterTouchFns",
               "drinkClasses", "wateringFxComponentClass", "sprayRegisterFn", "sprayPlayFn" },
  codex    = { "itemRow", "widgetClass", "widgetPath", "placeableClass", "placeablePath",
               "interactFnHint", "openFn", "wblPath", "closeFns", "inputUiFn", "inputGameFn",
               "guideProp", "researchId", "researchTierId", "researchHasFn", "researchSaveFn",
               "researchFieldId", "researchFieldDone" },
  foundation = { "previewPaths", "buildSystemClass", "buildSystemPath", "gateFn", "ruleFn",
                 "snapProp", "previewProp" },
  qol      = { "chestClass", "invSizeProp", "invUpgradeFn", "invLenForTierFn", "airshipClass", "shipChestOpenFn",
               "shipChestCloseFn", "openChestUiFn", "toggleInvFn", "controllingShipFn",
               "invWidgetProp", "invRowCountFn", "dockClass", "dockSpeedProp", "pingClass", "pingMeshProps",
               "overlayClass", "dropsProp", "mapCompClass", "mapOpenFn", "friendsMarkersProp",
               "mapIconImgProp", "mapSelfIconProp", "palette",
               "pingIconSlot", "pingBeamSlot", "pingHideMat", "pingHideMatDir", "setMaterialFn",
               "chestClassPath", "shipUnpossessFn",
               "slotGridLibPath", "slotGridFn", "chestGridRows", "chestGridCols",
               "chestUiClass", "chestUiPanelProp", "chestUiSlotsProp", "chestUiInvRefProp",
               "chestUiSyncFn", "slotGridPlayerFn", "chestUiPlayerPanelProp",
               "chestUiBackpackPanelProp", "chestUiPlayerSlotsProp", "chestUiPlayerInvRefProp",
               "chestUiPlayerSyncFn", "chestUiBackpackToggleProp", "chestUiMainBoxProp",
               "chestUiBackpackBoxProp", "chestUiShowBackpackProp", "invHotbarSlots",
               "overlayProp", "overlayShowHotbarFn", "overlayShowShipCtlFn",
               "crouchKeyEventFns", "deathLootStampFns", "deathLootLocProp",
               "backpackTierFn", "playerdataProp", "playerdataTierField", "playerdataInvIdField",
               "setInvIdFn", "invIdProp" },
  trash    = { "invUiProp", "invUiClass", "invGridProp", "invSlotsProp", "gridCols",
               "slotClass", "slotMouseFn", "slotIndexFn", "slotBgProp", "slotBorderProp",
               "carryClass", "carryGetFn", "carryDestroyFn", "carrySenderProp",
               "chestUiClass", "chestUiPath", "chestSlotsProp", "chestInvRefProp", "chestSyncFn",
               "invSysClass", "invSysPath", "sysSizeProp", "sysInvProp", "sysReplaceFn",
               "sysAmtFn", "sysTotalFn", "sysClearAtFn", "sysContainsFn",
               "slotFactoryLibPath", "slotFactoryFn", "wblPath",
               "gridSlotRowFn", "gridSlotColFn", "widgetSlotProp",
               "backingSize", "backingIndex", "giClass", "dbItemsProp", "toggleInvFn",
               "slotItemField", "slotQtyField", "slotSavedataField", "tint" },
}

M.profiles = {
  -- Values common to all builds. Only genuinely stable UE engine symbols belong here.
  default = {
    pawn = { worldLocationFn = "K2_GetActorLocation" }, -- standard AActor UFUNCTION
    net  = { hasAuthorityFn  = "HasAuthority" },         -- standard AActor UFUNCTION
    wand = { smcPath = "/Script/Engine.StaticMeshComponent" }, -- rig comps live ON the pawn
    -- UMG's own API, unchanged since UE4. NOTE what is NOT here: UPanelWidget::InsertChildAt and
    -- ShiftChild are plain C++, not UFUNCTIONs, so a Blueprint/Lua caller can only ever APPEND to
    -- a box -- features/manual_save.lua works around that by re-appending the button it wants to
    -- stay last.
    savemenu = {
      boxAddFn    = "AddChildToVerticalBox",  -- UVerticalBox -> the new UVerticalBoxSlot
      boxRemoveFn = "RemoveChild",            -- UPanelWidget (returns bool)
      boxHasFn    = "HasChild",               -- UPanelWidget: is this widget still OUR box's child?
      slotPadFn   = "SetPadding",             -- UVerticalBoxSlot (FMargin)
      wblPath     = "/Script/UMG.Default__WidgetBlueprintLibrary", -- CreateWidget from Lua
      -- The pause menu's button box is itself rotated 180 degrees (that is how the designer made a
      -- bottom-anchored menu grow upward), and every button in it carries a 180 counter-rotation so
      -- its own text reads the right way up. A widget we create has NO transform, so it inherits the
      -- container's flip and renders upside down -- we have to copy the siblings' counter-rotation.
      setAngleFn          = "SetRenderTransformAngle", -- UWidget (float degrees)
      renderTransformProp = "RenderTransform",         -- UWidget -> FWidgetTransform
      angleField          = "Angle",                   -- FWidgetTransform's degrees field
    },
    -- Stable engine symbols the Unlit ride (AAIController / ACharacter / UBrainComponent):
    animal = {
      moveCompProp     = "CharacterMovement", -- ACharacter's movement component property
      maxWalkSpeedProp = "MaxWalkSpeed",
      brainProp        = "BrainComponent",    -- AAIController -> UBrainComponent
      stopLogicFn      = "StopLogic",         -- UBrainComponent: halt the behavior tree for good
      -- tried in order until one exists on this build (RE-ANIMALS.md verify item 2 lists these):
      stopLogicFns     = { "StopLogic", "PauseLogic" },
      isOwnedFn        = "IsOwned",           -- animal-side: a player's tamed/named pet returns true
      moveToActorFn    = "MoveToActor",       -- AAIController: native pathfinding move orders
      moveToLocationFn = "MoveToLocation",
      stopMovementFn   = "StopMovement",      -- AController
    },
  },

  -- ---- Current tested build. Mapped live from re_capture_latest.txt (build 24038177). ----
  ["24038177"] = {
    -- Weather lives on BP_DayNightCycle_C. It exposes Instant* setters + PlayThunder (all no-arg).
    -- No safe "current weather" scalar was found (state is a struct we must not read), so storms
    -- are keybind-driven for now rather than polled — currentProp/severityProp intentionally nil.
    weather = {
      managerClass    = "BP_DayNightCycle_C",
      isDayProp       = "IsDay",                -- bool on the cycle manager -- daylight culls the Unlit
      isNightProp     = "IsNighttime",          -- inverse fallback if IsDay is renamed on a build
      startStormFn    = "InstantThunderstorm",  -- instantly begins a thunderstorm
      stopStormFn     = "InstantSunny",         -- repaints the sky sunny. A REPAINT ONLY: it does
                                                -- not stop the running weather program -- wind
                                                -- stays pinned and the native thunder loop keeps
                                                -- striking (the 2026-07-27 "storm never clears").
      hardStopFn      = "DEBUG_StopWeather",    -- the manager's own program stop; called BEFORE
                                                -- the repaint so ending a storm actually ends it
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
      -- Wetness readout (fishing's wet-weather skillshot bonus). The DNC exposes NO readable
      -- current-weather scalar (Weather/CurWeather/WeatherInt are function locals -- reads
      -- return the truthy nothing-wrapper), and the FadeIn/OutRain events are VM-internal
      -- (hooks never fire). PROBED LIVE 2026-07-28: this timeline component's playback
      -- position runs 0 -> 15s as rain fades in, HOLDS 15 while rain or storm is up (storms
      -- drive it too), and reverses to 0 on clear. position > 0.5 = wet.
      rainTimelineProp   = "TL_RainTransition",
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
    -- The animal system, RE'd OFFLINE from the cooked Blueprints (docs/RE-ANIMALS.md,
    -- wandsmith dump 2026-07-23). All three species BPs live in the Chicken/ folder (dev
    -- misfile). BP_Animal_MASTER_C is a Character; its AIC_*_C controller extends
    -- DetourCrowdAIController running BT_Master. `Name` is a REPLICATED StrProperty (CPF_Net)
    -- -- the mod's cross-client beacon: the host writes it, every client reads it.
    animal = {
      sheepClass   = "BP_Animal_Sheep_C",
      chickenClass = "BP_Animal_Chicken_C",
      pigClass     = "BP_Animal_Pig_C",       -- third species; not spawned yet (lured by carrot)
      masterClass  = "BP_Animal_MASTER_C",
      classPaths = {                          -- LoadAsset paths when no instance is resident
        BP_Animal_Sheep_C   = "/Game/Code/Animals/Chicken/BP_Animal_Sheep.BP_Animal_Sheep_C",
        BP_Animal_Chicken_C = "/Game/Code/Animals/Chicken/BP_Animal_Chicken.BP_Animal_Chicken_C",
        BP_Animal_Pig_C     = "/Game/Code/Animals/Chicken/BP_Animal_Pig.BP_Animal_Pig_C",
      },
      nameProp          = "Name",             -- replicated display name (the AnimalTag renames it)
      montageSetFn      = "BB_SetMontage",    -- animal-side blackboard write; the AnimBP renders it
      montageSleepValue = 3,                  -- EAnimalMontage: 0 Consume, 1 Walk, 2 Stand,
                                              -- 3 SLEEP (the lie-down), 4 Pick -- cooked byte
                                              -- order; verify live once (docs/RE-ANIMALS.md)
      montageWalkValue  = 1,                  -- held while a living Unlit is moving (keeps it upright)
      montageStandValue = 2,                  -- held while it stands (stun/idle) -- NEVER lies down alive
      audioCompProp     = "S_Chicken_NoLicense", -- the per-animal AudioComponent (master template
                                                 -- name; SetPitchMultiplier = client-local pitch)
      soundDir      = "/Game/Audio/SFX/Animals/",
      soundsChicken = { "S_Chicken_01", "S_Chicken_02", "S_Chicken_03", "S_Chicken_04",
                        "S_Chicken_05", "S_Chicken_06", "S_Chicken_07" },
      soundsSheep   = { "S_Sheep_1", "S_Sheep_2", "S_Sheep_3", "S_Sheep_4", "S_Sheep_5",
                        "S_Sheep_6" },
      screamChicken = "S_Chicken_Scream",     -- the aggro cry
      -- Lit/powered light placeables that forbid an Unlit spawn nearby. prop = the on/lit flag on
      -- that class (Burning for fire, IsOn for electric -- verified via offline BP dump); radiusKey
      -- picks the block distance. "Standing lamp" and "wireless light" both fall in the big group.
      spawnLights = {
        { cls = "BP_Torch_Standing_Placeable_C",      prop = "Burning", radiusKey = "evil_light_block_big" },
        { cls = "BP_Torch_Wall_Placeable_C",          prop = "Burning", radiusKey = "evil_light_block_big" },
        { cls = "BP_Lamp_Wireless_Placeable_C",        prop = "IsOn",    radiusKey = "evil_light_block_big" },
        { cls = "BP_ElecttronicLight_01_Placeable_C",  prop = "IsOn",    radiusKey = "evil_light_block_big" },
        { cls = "BP_Candle_Plate_Buildable_C",         prop = "Burning", radiusKey = "evil_light_block_small" },
        { cls = "BP_Deco_Candle_Outdor_Buildable_C",   prop = "Burning", radiusKey = "evil_light_block_small" },
        { cls = "BP_BedsideLamp_Wireless_Placeable_C", prop = "IsOn",    radiusKey = "evil_light_block_small" },
      },
    },
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
      -- Use-gestures (offline signature read 2026-07-23 from BP_MainPlayerCharacter's
      -- FunctionExports): all are param-less BlueprintCallable pawn events except the swing,
      -- which takes one byte (SwingMissType; 0 = the default tool whiff).
      gesturePourFn      = "Watercan_Watering_Animation",     -- wrist-tilt pour loop, on
      gesturePourStopFn  = "StopWatercanAnimation",           -- wrist-tilt pour loop, off
      gestureCastFn      = "Swing Miss",                      -- one-shot forward swing
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
    -- The QoL batch (features/qol.lua; offline RE 2026-07-26 of BP_Chest_Buildable,
    -- BC_InventorySystem, BP_MainPlayerCharacter/Controller, BP_Airship, BP_Dock, BP_Ping,
    -- W_PlayerOverlay, WC_Map -- scratchpad re_qol/ dumps).
    qol = {
      chestClass    = "BP_Chest_Buildable_C",
      -- Package path for a LoadAsset fallback when no chest is resident yet (a fresh world), so
      -- the ship can still grow its storage chest (features/ship_chest.lua).
      chestClassPath = "/Game/Code/Building_Placing/Placeables/BP_Chest_Buildable",
      -- The chest UI's slot grid is built ONCE per widget by a LIBRARY call with LITERAL
      -- dimensions -- W_ChestInventory's bytecode reads `CreateItemSlotGrid(self, player,
      -- ChestInventory, 2, 6, ...)` (offline RE 2026-07-27, scratchpad re_ui/) -- so a grown
      -- chest kept showing 12 widgets no matter how many slots the array held
      -- (FillInventoryInGridPanel populates only the widgets that exist). The build is an
      -- EX_FinalFunction static call, which UE4SS script hooks do NOT intercept (proven live
      -- 2026-07-27), so qol rebuilds the grid from outside after each UI_OpenChestInventory:
      -- these names are that rebuild's fingers into the widget.
      slotGridLibPath = "/Game/UI/Framework/BPL_UiFunctions.BPL_UiFunctions_C",
      slotGridFn      = "CreateItemSlotGrid",
      chestGridRows   = 2,                        -- stock grid, kept for reference/tests
      chestGridCols   = 6,                        -- column count the rebuild preserves
      chestUiClass      = "W_ChestInventory_C",
      chestUiPanelProp  = "ChestInventory",       -- UniformGridPanel the slots live in
      chestUiSlotsProp  = "ChestSlots",           -- TArray<W_InventorySlot*> the fill loop reads
      chestUiInvRefProp = "ChestInventoryRef",    -- BC_InventorySystem the widget is showing
      chestUiSyncFn     = "SyncAndFill_Chest",    -- no-arg event: repopulate from the inventory
      -- The PLAYER side of the same widget (offline RE 2026-07-27, scratchpad re_backpack\):
      -- UpdateBackpackDisplayIfRequired builds a 3x7 main grid plus a SEPARATE
      -- GetBackpackRows-sized grid behind a switch; rows come from Playerdata.InventoryUpgrades
      -- (bitmask 0/1/3/7 -> 0/1/2/3 rows), and its fill loop skips the inventory array's first
      -- 8 entries (the hotbar; bytecode literal `index > 7`).
      slotGridPlayerFn        = "CreateItemSlotGridForPlayer", -- BPL_UiFunctions, same arity as
                                                               -- CreateItemSlotGrid
      chestUiPlayerPanelProp  = "GRID_PlayerInventory",  -- UniformGridPanel, the 3x7 main grid
      chestUiBackpackPanelProp = "Grid_BackpackInventory", -- the switched-to backpack grid
      chestUiPlayerSlotsProp  = "PlayerSlots",           -- TArray<W_InventorySlot*> the player
                                                         -- fill loop reads (main + backpack)
      chestUiPlayerInvRefProp = "PlayerInventoryRef",    -- BC_InventorySystem of the player
      chestUiPlayerSyncFn     = "SyncAndFill_Player",    -- no-arg event: repopulate player side
      chestUiBackpackToggleProp = "KeyItemsToggle",      -- the main/backpack switch button
      chestUiMainBoxProp      = "MainInventory",         -- box holding the main grid
      chestUiBackpackBoxProp  = "BackbackInventory",     -- box holding the backpack grid (sic)
      chestUiShowBackpackProp = "ShowBackpack",          -- which box the open path shows
      invHotbarSlots          = 8,                       -- leading inventory entries = hotbar
      -- Driving the airship swaps the bottom-of-screen hotbar for the airship control icons;
      -- the giveaway is SERVER_LeaveAirship's client path, which undoes exactly this pair on
      -- stepping off (offline RE 2026-07-27). Both are events on the player overlay widget.
      overlayProp          = "PlayerOverlay",            -- the controller's overlay instance
      overlayShowHotbarFn  = "SetShowHotbar",            -- overlay event (bool)
      overlayShowShipCtlFn = "SetShowAirshipControls",   -- overlay event (bool)
      -- The airship BP implements the Pawn possession events (offline RE, scratchpad re_ship/):
      -- ReceiveUnpossessed = "someone just stopped driving" = the ship-chest re-anchor moment.
      shipUnpossessFn = "ReceiveUnpossessed",
      invSizeProp   = "InventorySize",            -- on the BC_InventorySystem component (int; chest stock 12)
      invUpgradeFn  = "SetInventoryUpgradeLevel", -- pawn fn (Level: int) -- the backpack tier apply
      -- The tier -> slot-count ladder, straight from the game rather than from a table here. It is
      -- the same function the save's own length check calls, so asking it is the only way to know
      -- what length a tier is SUPPOSED to be on this build.
      invLenForTierFn = "GetInvLengthForBackpackUpgradeTier", -- pawn fn (Tier: int) -> InvLength
      -- Backpack tier PERSISTENCE. SetInventoryUpgradeLevel only grows the live array; the tier
      -- itself lives in the controller's Playerdata and is written by this one event -- exactly what
      -- the game's own BLIB_DebugFunctions::SetInventoryLevel and BP_Backpack::OnCollect call.
      -- Skipping it desyncs the save (see features/qol.lua::applyBackpack for what that costs).
      backpackTierFn = "Playerdata_SaveBackpackTier", -- controller event (Level: int)
      playerdataProp = "Playerdata",                  -- controller prop -> S_Saved_Player
      -- S_Saved_Player members keep Blueprint's mangled <name>_<idx>_<guid> FNames.
      playerdataTierField  = "InventoryUpgrades_84_42A7B4124E8647560320D69F2EBAAE56",
      playerdataInvIdField = "InventoryID_60_9F40B03D435683709B5A9CA6D58906AE",
      setInvIdFn    = "SetInventoryID",           -- controller event (InventorySystem, ID: FGuid)
      invIdProp     = "InventoryID",              -- on BC_InventorySystem (FGuid; 0 = unlinked)
      airshipClass  = "BP_Airship_C",
      shipChestOpenFn  = "OpenChest",             -- airship events: the chest lid (no params)
      shipChestCloseFn = "CloseChest",
      openChestUiFn    = "UI_OpenChestInventory", -- controller fn (ChestInventorySystem) -- the
                                                  -- game's one chest-UI entry, any inventory system
      toggleInvFn      = "ToggleInventory",       -- controller fn, no params: open/close own inventory
      controllingShipFn = "IsControllingAirship?",-- controller fn, single OUT bool (fresh-table call)
      invWidgetProp    = "UI_PlayerInventory",    -- controller prop -> the open W_PlayerInventory
      invRowCountFn    = "GetRowCount",           -- W_PlayerInventory fn, single OUT int: how many
                                                  -- 7-wide rows the grid is showing right now
                                                  -- (3/4/5/6 for backpack tier 0/1/3/7). The window
                                                  -- grows by whole rows, so this is what the
                                                  -- hotbar's lift has to track.
      -- HOLD-to-crouch needs a key RELEASE, and UE4SS only ever reports key DOWN. The game hands
      -- us one: BP_MainPlayerCharacter declares raw LeftControl input-key events, and a UE
      -- InputKey node compiles its Pressed and Released pins into exactly this pair of functions --
      -- so hooking both IS a key-up subscription. (The game declares raw key events for only four
      -- keys -- LeftControl, Gamepad_RightTrigger, Nine, Semicolon -- so this trick is Ctrl-only;
      -- the letter key stays a pure toggle: sampling key state off the controller is the proven
      -- process-killing FKey call, 2026-07-27.)
      -- ORDER IS MEANING: { down, up }. Bytecode-verified in the pawn's Ubergraph -- the _2 entry
      -- sets its gate bool TRUE (Pressed), the _3 entry sets it FALSE (Released).
      crouchKeyEventFns = { "InpActEvt_LeftControl_K2Node_InputKeyEvent_2",
                            "InpActEvt_LeftControl_K2Node_InputKeyEvent_3" },
      -- Death loot: the controller stamps where your gear drops (DeathLootSpawnLocation) from the
      -- dying pawn's ACTOR location, then spawns the chest a standing-height below it -- which
      -- buries the chest when you die crouched, because crouching drops the actor origin by the
      -- half-height difference (the feet stay planted, so the origin has to come down).
      deathLootStampFns = { "SERVER_SetCurLocationAsDeathLootSpawn",
                            "CLIENT_SetCurLocationAsDeathLootSpawn" },
      deathLootLocProp  = "DeathLootSpawnLocation",
      dockClass     = "BP_Dock_C",
      dockSpeedProp = "TimelineSpeed",            -- double, stock 800.0 -- paces the recall flight
      pingClass     = "BP_Ping_C",
      pingMeshProps = { "StaticMesh", "SM_Ping", "Mesh" },  -- comp-prop candidates; first hit wins
      overlayClass  = "W_PlayerOverlay_C",
      dropsProp     = "SW_ItemsObtainedDisplay",  -- overlay prop -> the "+4 Wood" pickup feed
      mapCompClass  = "WC_Map_C",                 -- the pannable map inside W_ingameMap
      mapOpenFn     = "OpenMap",
      friendsMarkersProp = "FriendsMarkers",      -- TMap<FString, WC_MapPlayerIcon> -- name -> icon
      mapIconImgProp     = "IMG_Player",          -- the icon widget's single Image
      mapSelfIconProp    = "WC_MainPlayer",       -- the local player's own icon on WC_Map
      -- The marker's own materials, from the SM_Ping mesh (offline RE, scratchpad re_ping/ and
      -- re_ping2/SM_Ping.json): ONE flat plane, 167 wide x 1103 tall, origin at the base, and
      -- BP_Ping overrides neither slot (OverrideMaterials is [null, null]). Neither stock
      -- material declares a colour parameter, which is why tinting was never going to work.
      -- SLOT ORDER, read from StaticMaterials (it is the reverse of the first guess):
      --   slot 0 = M_Ping2, the Icon_Ping quad at the bottom of the plane ("the box")
      --   slot 1 = M_Ping1, the ObjectOrientation-gradient beam (the rod)
      pingIconSlot = 0,
      pingBeamSlot = 1,
      -- The engine's own draw-nothing material (BLEND_Masked, mask clips every pixel; it is what
      -- Nanite dresses hidden sections in). Cooked into the game (bIncludedInBaseGame), lives in
      -- Engine content rather than the game's material dir -- hence its own load path.
      pingHideMat    = "NaniteHiddenSectionMaterial",
      pingHideMatDir = "/Engine/EngineMaterials/",
      -- The ONE material call this build tolerates. The whole material-PARAMETER family is fatal
      -- on 24038177, and each member earned its entry the hard way:
      --   * CreateDynamicMaterialInstance -- crashed twice (2026-07-26 22:52 + 23:40).
      --   * SetVectorParameterValueOnMaterials -- crashed 2026-07-27 00:05:37, the moment it was
      --     tried as the "safer door".
      -- All three dumps are IDENTICAL: access violation reading 0x70, top frames UE4SS
      -- +261bb1/+25ba75, not one game-module frame. UE4SS dies setting the call up; the engine
      -- never runs, so neither the component nor the arguments were ever the problem. (Every
      -- member call this mod has proven safe passes no FName parameter; every one of these takes
      -- an FName. Unproven as the mechanism, but the pattern also swallows the "attach family"
      -- fatalities -- worth remembering before trying any FName-taking member next time.)
      -- Colour therefore cannot be APPLIED to a material at runtime, only CHOSEN: see palette.
      setMaterialFn = "SetMaterial",     -- (ElementIndex: int, Material) -- proven live 00:05:37
      -- Per-player colors. Each slot pairs the FLinearColor the MAP icon is tinted with (a UMG
      -- widget call, safe) and the cooked game material whose BAKED-IN look is that same colour,
      -- which is what the WORLD marker's slots are painted with -- flat colour without ever
      -- touching a material parameter. Deterministic name-hash slot assignment keeps host and
      -- clients agreeing without replication.
      --
      -- The materials (offline RE of the cooked binaries, scratchpad re_ping2/; same
      -- BLEND_TranslucentGreyTransmittance family as the stock ping materials, except Energy_On
      -- which is opaque emissive): M_Preview_Blue/Red are the build previews (exercised every
      -- session), M_Energy_On is the powered-device indicator (constant 0,4,0 emissive green),
      -- M_DockingBox is the airship docking guide's yellow.
      palette = {
        { r = 0.15, g = 0.45, b = 1.0,  mat = "M_Preview_Blue" },  -- river blue
        { r = 1.0,  g = 0.8,  b = 0.1,  mat = "M_DockingBox"   },  -- wax yellow
        { r = 1.0,  g = 0.15, b = 0.1,  mat = "M_Preview_Red"  },  -- tomato red
        { r = 0.2,  g = 1.0,  b = 0.55, mat = "M_Energy_On"    },  -- powered green
      },
    },
    -- The trash-can slot (features/trash_slot.lua; offline RE 2026-07-28 of W_PlayerInventory,
    -- W_InventorySlot, W_Inventory_MASTER, W_ClickAndDrop, W_ChestInventory, BC_InventorySystem,
    -- BPL_UiFunctions -- this session's scratchpad re_trash/ dumps).
    --
    -- The load-bearing findings, in the order they matter:
    --   * The game moves items with a CLICK-AND-CARRY model, not UMG drag-drop: clicking a slot
    --     with an item calls CreateClickAndDropWidget(CurItem) and Clear Single SlotAtIndex --
    --     while carried, the item exists ONLY in the W_ClickAndDrop widget's Item struct.
    --     W_ClickAndDrop:Destroy() is RemoveFromParent + CallStopMoving: destroying a loaded
    --     carry deletes the item outright (DropAndDestroy is the separate throw-to-ground path).
    --     CreateClickAndDropWidget stamps SenderSlot = the slot it was picked from.
    --   * A W_InventorySlot resolves its backing store per click through its ParentInventoryWidget
    --     (BPI_Inventory_Widgets.GetSystemAndIndexForSlot), and W_ChestInventory's implementation
    --     is Array_Contains(ChestSlots, slot) -> (ChestInventoryRef, slot.CurItemIndexInInventory).
    --     So one W_ChestInventory instance turns any slot widget into a fully native slot over
    --     any system. It must be PARKED IN THE VIEWPORT (Collapsed): the viewport's SObjectWidget
    --     is the only GC root the pair gets -- a bare-created widget plus its detached system were
    --     collected within a ~60s sweep live (the slot's factory-stamped interface ref did NOT
    --     keep them alive). Its Construct runs on AddToViewport and rewrites ChestSlots with 12
    --     fresh slots (plus benign anim/backpack-display work; ChestInventoryRef is only written
    --     by OpenChest, offset 917) -- so ChestSlots/ChestInventoryRef are stamped strictly AFTER
    --     parking, and any re-park retires + remakes the slot widget.
    --   * A detached BC_InventorySystem (StaticConstructObject, never registered, BeginPlay never
    --     run) works because every function the click path touches is pure array logic; its
    --     SaveInventory routes to pc.Net_ApplyAndSaveInventory -> SaveManager.UpdateSavedInventory,
    --     which is UPDATE-ONLY by GUID (the backpack-bug RE) -- a never-registered system has the
    --     zero GUID, so its "saves" are structural no-ops on host AND clients. Trash contents
    --     therefore CANNOT persist: exactly the feature's logout-forgets contract.
    --   * backingIndex 51 in a 52-slot system: W_PlayerInventory.GetSystemAndIndexForSlot returns
    --     (player system, slot.CurItemIndexInInventory) UNCONDITIONALLY, so a shift-click on a
    --     foreign slot would SwapItemPosition(ourIndex, ...) on the PLAYER inventory. 51 is out of
    --     range for every legal tier (max 50 slots), and Kismet's Array_Get returns a default /
    --     Array_Set(bSizeToFit=false) refuses on OOB -- the whole gesture becomes a no-op.
    --   * ChestSlots gets the SAME slot widget 52 times: FillInventoryInGridPanel walks the
    --     INVENTORY's length indexing GridSlots[i] in lockstep, so index 51's display (and the
    --     SetItemIndexInInventory(51) stamp) must land on our one widget LAST.
    trash = {
      invUiClass   = "W_PlayerInventory_C",
      invUiProp    = "UI_PlayerInventory",   -- controller prop; pre-created by StartupUI
      invGridProp  = "TestGrid",             -- the ONE UniformGridPanel with every bag slot
                                             -- (dev name is really "TestGrid"); rebuilt only by
                                             -- ExpandGrid, which only runs when ItemSlots is
                                             -- smaller than the tier says (backpack upgrade)
      invSlotsProp = "ItemSlots",            -- TArray<W_InventorySlot*> the fill loop walks; our
                                             -- slot stays OUT of it, so GetExpectedSlotCount
                                             -- never sees a wrong count
      gridCols     = 7,                      -- bag rows are 7 wide on every tier
      slotClass    = "W_InventorySlot_C",
      slotMouseFn  = "OnMouseButtonDown",    -- native->BP override = ProcessEvent = hookable;
                                             -- left AND right clicks funnel through it
      slotIndexFn  = "SetItemIndexInInventory",
      slotBgProp   = "Background",           -- UImage; DisplayItem only writes its OPACITY
                                             -- (0.5 empty / 0.8 filled), never its colour, so a
                                             -- SetColorAndOpacity tint survives every repaint
      slotBorderProp = "BORDER_Selected",    -- UBorder the game shows on focus/hover
      carryClass     = "W_ClickAndDrop_C",
      carryGetFn     = "GetClickAndDropWidget",  -- slot fn: (out Success, out Widget) --
                                                 -- TWO out placeholders required, BOTH values
                                                 -- come back in the FIRST table (the UE4SS
                                                 -- multi-out rule, burned twice 2026-07-28)
      carryDestroyFn = "Destroy",                -- deletes the carried item (no ground spawn)
      carrySenderProp = "SenderSlot",
      chestUiClass   = "W_ChestInventory_C",
      chestUiPath    = "/Game/UI/Widgets/W_ChestInventory.W_ChestInventory_C",
      chestSlotsProp = "ChestSlots",
      chestInvRefProp = "ChestInventoryRef",
      chestSyncFn    = "SyncAndFill_Chest",  -- mark-dirty + FillInventoryInGridPanel, nothing else
      invSysClass    = "BC_InventorySystem_C",
      invSysPath     = "/Game/Code/Inventory_Items/Framework_and_Data/BC_InventorySystem.BC_InventorySystem_C",
      sysSizeProp    = "InventorySize",
      sysInvProp     = "Inventory",          -- length reads only; element access wedges the VM
      sysReplaceFn   = "ForceReplace Inventory",      -- (Inventory, SaveAfterDone) -- real spaces
      sysAmtFn       = "GetAmtOfItem",                -- (slot struct, out Amount) -- matches by
                                                      -- CLASS only (Is Item in Slot Class Equal)
      sysTotalFn     = "GetTotalItemAmt",             -- (out TotalItems)
      sysClearAtFn   = "Clear Single SlotAtIndex",    -- (index)
      sysContainsFn  = "Contains one Of Given Items", -- (class array, out Contains) -- the bisect
                                                      -- probe; degrades to linear sysAmtFn scans
                                                      -- if the array param won't marshal
      slotFactoryLibPath = "/Game/UI/Framework/BPL_UiFunctions.BPL_UiFunctions_C",
      slotFactoryFn  = "CreateItemSlotGridForPlayer", -- (PARENTWIDGET, player, panel, rows, cols,
                                                      -- __WorldContext, out slots): creates the
                                                      -- slot, stamps ParentInventoryWidget from
                                                      -- arg ONE, centers it in its grid cell.
                                                      -- Live-burned 2026-07-28: guessing worldCtx
                                                      -- first stamped the interface ref with the
                                                      -- CONTROLLER -- clicks resolved to (None,0)
                                                      -- and deposits silently no-op'd. UAssetAPI's
                                                      -- LoadedProperties order IS the call order.
      wblPath        = "/Script/UMG.Default__WidgetBlueprintLibrary",
      gridSlotRowFn  = "SetRow",             -- UniformGridSlot (the widget's panel Slot object)
      gridSlotColFn  = "SetColumn",
      widgetSlotProp = "Slot",               -- UWidget -> its panel slot
      backingSize    = 52,                   -- > 50 (the largest legal player inventory) so the
      backingIndex   = 51,                   -- backing index can never alias a player slot
      giClass        = "BP_SkyGameInstance_C",
      dbItemsProp    = "DB_Items",           -- Map<item actor UClass, row struct>: the candidate
                                             -- list for discovering what just landed in the trash
      toggleInvFn    = "ToggleInventory",    -- controller input action; the re-ensure trigger
      -- the slot struct's GUID-suffixed FNames (same values as wand.slot*Field)
      slotItemField     = "Item_4_B9922CA845A5618A776EAFAB1A690E93",
      slotQtyField      = "Quantity_5_A1813C42482CE5E7961C589A983BD034",
      slotSavedataField = "AdditionalSavedata_12_7C875E564155FCA4AA2B4597ACB03361",
      tint = { 1.0, 0.30, 0.30, 1.0 },       -- the red that marks the slot as the trash
    },
    -- The world save (offline RE 2026-07-26 of BPC_SaveManager + SkygameExtraFunctions --
    -- scratchpad re_save/ dumps). The manager is a component on the GAME STATE; the library's
    -- GetSaveManager is literally GetSkyGameGameState().BPC_SaveManager, so the mod reads the
    -- property instead of marshalling an out-param library call.
    --
    -- `Save` IS the autosave: InvalidateAndSetAutosaveInterval binds a looping timer straight to
    -- it. It broadcasts OnAutoSaveStarting (every system flushes its state into CachedSave and the
    -- HUD's W_SaveIndicator lights up), then AsyncSaveCompressedGameToSlot(CachedSave,
    -- GetCurWorldSaveName) and broadcasts OnAutoSaveCompleted when the write lands. So a manual
    -- save is ONE call -- nothing reimplements saving. SaveToDisk is the sibling path that skips
    -- the OnAutoSaveStarting flush; never use it for a player-triggered save.
    save = {
      gameStateClass = "BP_SkyGameGameState_C",
      managerProp    = "BPC_SaveManager",       -- the component property on the game state
      managerClass   = "BPC_SaveManager_C",     -- fallback lookup if the game state moves
      saveFn         = "Save",                  -- the autosave entry point (no params)
      loadFn         = "LoadSaveFromDisk",
      autosaveArmFn  = "InvalidateAndSetAutosaveInterval",  -- (Interval) clear + re-arm the timer
      intervalProp   = "SaveIntervall",         -- the manager's own interval (game's spelling)
      -- "the write finished" signals, tried in order; the first that arms wins. The manager's own
      -- callback is authoritative but GUID-named (a BP recompile renames it on a game update),
      -- so the save indicator's stably-named handler -- bound to the same OnAutoSaveCompleted --
      -- is kept as the degrade path. If BOTH ever go missing the in-flight guard falls back to
      -- its timeout, so a lost signal costs a stale button label, never a stuck one.
      saveDoneFns = {
        { class = "BPC_SaveManager_C", fn = "Completed_BB33EECA440DCA1E1E27DABE0E75C18D" },
        { class = "W_SaveIndicator_C", fn = "AutoSaveStopped" },
      },
    },
    -- The pause menu (same dump session). BOX_MenuButtons is a plain UVerticalBox holding
    -- [socials, spacer, unstuck, spacer, Quit, BackToMenu, Host, Invite, Settings, Resume], and the
    -- box itself is rotated 180 degrees -- so VISUAL top-to-bottom is that list REVERSED (Resume on
    -- top, socials at the bottom) and the last child renders highest. Re-appending Resume after the
    -- Save button therefore parks Save directly under Resume. Every BTN2_ slot ships
    -- Padding {Bottom = 4}; the mod re-applies that so a re-added button keeps the menu's spacing.
    savemenu = {
      menuClass        = "W_IngameMenu_C",     -- pre-created by the controller (its UI_IngameMenu)
      menuOpenFn       = "Open",               -- fires every time ESC brings the menu up
      buttonsBoxProp   = "BOX_MenuButtons",
      resumeButtonProp = "BTN2_Resume",
      buttonClass      = "W_MenuButton_V2_C",  -- the menu's own button widget (label + click sound)
      buttonPath       = "/Game/UI/Widgets/WidgetComponents/W_MenuButton_V2.W_MenuButton_V2_C",
      buttonTextFn     = "SetText",            -- (FText) -> TXT_Main. The button's `Text`
                                               -- PROPERTY is deliberately never written -- see
                                               -- manual_save.setLabel for why.
      -- The button's OWN click handler. UE4SS cannot bind a Blueprint multicast delegate from
      -- Lua, so the mod hooks this class function instead and filters on the instance -- it fires
      -- for every W_MenuButton_V2 in the game, ours included.
      buttonClickFn    = "BndEvt__Button_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature",
      -- Fallback counter-rotation, used only if BTN2_Resume's own RenderTransform can't be read.
      -- Every BTN2_ directly in BOX_MenuButtons ships RenderTransform {Angle = 180}.
      buttonAngle      = 180.0,
    },
    -- The fishing overhaul (features/fishing.lua; offline RE 2026-07-27/28 of
    -- BP_HandItem_FishingRod + BP_MainPlayerCharacter -- scratchpad rod_uber/char_uber dumps).
    -- Loot is a per-BP_River-instance TArray<S_WeightedLootItem> (NO DataTable): GetLootFromWater
    -- line-traces the bobber to a BP_River_C and reads ITS Loottable. The whole cast/bite/catch
    -- flow runs on the OWNING CLIENT (every getter in the rod's ubergraph is local-player based),
    -- so each machine rewrites its own rivers' tables = per-player luck without replication.
    fishing = {
      riverClass    = "BP_River_C",
      loottableProp = "Loottable",
      -- S_WeightedLootItem members (BP struct -> GUID-suffixed FNames, read from the cooked
      -- BP_River dump; the SLOT-side struct fields are reused from the wand section):
      lootItemField   = "Item_2_1BBB738C4E44A3691F7D7FA72F18D942",     -- UClass of the item actor
      lootWeightField = "Weight_5_FE32777043D4D4500ED27DB09FD53D95",   -- int weight
      -- The rod HAND ACTOR (spawned by the game's equip path). ChanceForLoot is the 1.5 s looping
      -- bite roll -- a SetTimer delegate, so it dispatches via ProcessEvent = hookable. Catch(),
      -- GetLootFromWater and SpawnLootRandom are VM-internal from there -- NOT hookable.
      rodHandClass = "BP_HandItem_FishingRod_C",
      rodHandPath  = "/Game/Code/Character/HandItems/BP_HandItem_FishingRod.BP_HandItem_FishingRod_C",
      lootTickFn   = "ChanceForLoot",
      canCatchProp = "PlayerCanCatch",   -- true during the 1 s reel window after a bite
      swimmerProp  = "throw_swimmer",    -- the bobber component; splash/VFX play at its location
      -- The bite roll's pity ramp: each 1.5 s tick rolls RandomBoolWithWeight(clamp(0.3 + this,
      -- 0, 1)), +0.1 per miss, and the splash + catch window only exist inside the success
      -- branch. Parking it at -1000 is the mod's "hold the water still" switch (skillshot).
      -- The bobber's water-landing resets it to 0 (each cast starts pity fresh).
      biteBonusProp = "RandomCatchBonus",
      rodInUseProp  = "RodInUse?",       -- true while the line is thrown; the cast/reel truth
      -- The bite splash the game plays at volume 1.0 (rod ubergraph, PlaySoundAtLocation of
      -- import -227). The mod layers extra gain on top at the same spot -- an asset patch would
      -- also boost the cast-landing and reel-in splashes, which the user did not ask for.
      splashWavePath = "/Game/Audio/SFX/Player/S_FishingRod_Splash.S_FishingRod_Splash",
      -- Character-side: the interaction switch routes a left click to Interaction_FishingRod()
      -- when the held ItemActor == BP_FishingRod_Item_C (bytecode: EqualEqual_ClassClass chain).
      -- It is a plain pawn CustomEvent (ProcessEvent-callable): casts CurHandItemFirstPerson to
      -- the hand rod -> UseFishingRod() -> DecreaseCurItemDurability(RandomIntegerInRange(1,3)).
      -- The DIAMOND rod row is unknown to both hardcoded switches (new cooked tool-typed rows are
      -- the proven world-load crash, so the row ships T5-typed like the wands) -- the mod seats
      -- the real hand actor itself and calls this event from its own click hook.
      useRodFn    = "Interaction_FishingRod",
      equipModeFn = "EnterDefaultMode",       -- pawn fn; the game's fishing equip branch passes 0
      rodItemClass = "BP_FishingRod_Item_C",  -- the vanilla rod's DB_Items actor class
      diamondRow   = "DiamondFishingRod",     -- content-pak row (tools/pakkit); absent = no pak
      rodDurability     = 200,                -- vanilla rod durability (DB_Items)
      diamondDurability = 2000,               -- the pak row's durability (10x, user spec)
      invArrayProp = "Inventory",             -- BC_InventorySystem's slot array (offline RE re_qol);
                                              -- elements are S_InventorySlotSlim -- field names
                                              -- reused from wand.slotItemField/QtyField/SavedataField
      -- Anim pose for the mod-seated rod (harmless if these move on an update -- pcall'd):
      handsMeshProp    = "SKM_Hands",         -- pawn's first-person hands skeletal mesh comp
      animItemEnumProp = "ENUMItemInHand",    -- on its anim instance; 3 = the fishing pose
      animItemEnumValue = 3,
      -- Skillshot bar visuals (features/fishing_ui.lua): raw UMG Images layered into a canvas.
      -- Preferred shell is our OWN viewport widget (bare UserWidget + CanvasPanel root); the
      -- overlay's root canvas is the fallback surface when that construction fails the probe.
      imagePath   = "/Script/UMG.Image",
      canvasAddFn = "AddChildToCanvas",       -- UCanvasPanel -> the new CanvasPanelSlot
      userWidgetPath  = "/Script/UMG.UserWidget",
      canvasPanelPath = "/Script/UMG.CanvasPanel",
      wblPath = "/Script/UMG.Default__WidgetBlueprintLibrary", -- same object codex/savemenu use
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
