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
  weather  = { "managerClass", "currentProp", "severityProp", "onChangedFn", "stormValue" },
  pawn     = { "class", "healthProp", "isShelteredFn", "worldLocationFn", "respawnFn", "dropInventoryFn" },
  build    = { "pieceClass", "stableIdProp", "demolishFn", "demolishRefund" },
  crop     = { "class", "killNoSeedFn" },
  battery  = { "class", "chargeProp", "maxChargeProp" },
  machine  = { "classes" },
  airship  = { "class", "healthProp", "isFlyingFn", "crashFn" },
  island   = { "class" },
  unlock   = { "registerFn" },
  craft    = { "repairItemId", "addRecipeFn" },
  buildmenu = { "registerFn" },
  energy   = { "linkFn" },
  smoke    = { "shipDamageVfxFn" },
  net      = { "hasAuthorityFn", "playerStateClass" },
  save     = { "saveFn", "loadFn" },
}

M.profiles = {
  -- Values common to all builds. Only genuinely stable UE engine symbols belong here.
  default = {
    pawn = { worldLocationFn = "K2_GetActorLocation" }, -- standard AActor UFUNCTION
    net  = { hasAuthorityFn  = "HasAuthority" },         -- standard AActor UFUNCTION
  },

  -- ---- Current tested build. FILL FROM dumps/24038177/ ----
  ["24038177"] = {
    -- weather = {
    --   managerClass = "BP_WeatherManager_C",
    --   currentProp  = "CurrentWeather",
    --   severityProp = "StormIntensity",
    --   onChangedFn  = "OnWeatherChanged",   -- or leave nil to poll currentProp
    --   stormValue   = 2,                    -- enum/int meaning "storm"
    -- },
    -- build = { pieceClass = "BP_BuildPiece_C", demolishFn = "Demolish", demolishRefund = true },
    -- crop  = { class = "BP_Crop_C", killNoSeedFn = "DestroyNoDrop" },
    -- battery = { class = "BP_Battery_C", chargeProp = "Charge", maxChargeProp = "MaxCharge" },
    -- ... (see docs/REVERSE-ENGINEERING.md for the full list)
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
