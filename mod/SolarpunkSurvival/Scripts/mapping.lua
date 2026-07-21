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
  player   = { "controllerClass", "curHealthProp", "maxHealthProp", "addHealthFn", "reduceHealthFn", "dieFn", "respawnFn", "pingFn" },
  pawn     = { "class", "healthProp", "isShelteredFn", "worldLocationFn", "respawnFn", "dropInventoryFn" },
  build    = { "pieceClass", "stableIdProp", "demolishFn", "demolishRefund" },
  crop     = { "class", "killNoSeedFn" },
  battery  = { "class", "chargeProp", "maxChargeProp", "classHints", "chargePropCandidates", "maxChargePropCandidates" },
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
  tree     = { "classPrefix" },
  animal   = { "sheepClass" },
  ritual   = { "wandItemRow", "bookItemRow", "rodItemRow" },
  fx       = { "clientDamageRpcFn", "buzzSoundProp" },
  furnace  = { "classHints", "fuelPropCandidates", "fuelFnCandidates" },
  rod      = { "stationClassCandidates", "copperItemRow" },
}

M.profiles = {
  -- Values common to all builds. Only genuinely stable UE engine symbols belong here.
  default = {
    pawn = { worldLocationFn = "K2_GetActorLocation" }, -- standard AActor UFUNCTION
    net  = { hasAuthorityFn  = "HasAuthority" },         -- standard AActor UFUNCTION
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
    pawn = { class = "BP_MainPlayerCharacter_C" },
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
    },
    -- Every inventory item's actor class is BP_<Name>_Item_C, but row->name is NOT 1:1
    -- (HoeDiamond -> Hoe_Diamond, Weather_Station -> WeatherStation): core/items.lua tries the
    -- variants. All 300 item classes live flat in assetDir (verified live via full-object scan).
    items  = { classFmt = "BP_%s_Item_C", assetDir = "/Game/Code/Inventory_Items/ItemActors/" },
    tree   = { classPrefix = "BP_Tree_" },     -- BP_Tree_Birch_C confirmed live; suffix names the type
    animal = { sheepClass = "BP_Animal_Sheep_C" },
    -- Stand-ins until a cooked pak can add real items (docs/MILESTONE-2.md):
    ritual = {
      wandItemRow = "HoeDiamond",   -- "mundane wand": holdable + already late in the tech tree
      bookItemRow = "Handbook",     -- the dark-arts book prop
      rodItemRow  = "Weather_Station", -- what the wand transforms into (the lightning rod)
    },
    fx = {
      clientDamageRpcFn = "CLIENT_ReduceHealth", -- game's own client RPC: fires ON the victim's machine
      buzzSoundProp     = "ThunderSound",        -- weather-manager sound reused (pitched) as the buzz
    },
    -- Machine/furnace internals live in parent classes the capture didn't dump; classify by class
    -- NAME and probe candidate members (all pcall-guarded). Re-dump at a base to pin exact names.
    battery = {
      classHints = { "Battery" },
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
    rod = {
      stationClassCandidates = {
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
