-- DB_Items row -> loaded item-actor UClass. Row names do NOT map 1:1 to class names
-- (verified live: HoeDiamond -> BP_Hoe_Diamond_Item_C, Weather_Station -> BP_WeatherStation_Item_C,
-- log -> BP_Log_Item_C), so several naming variants are tried, each with a LoadAsset fallback from
-- the flat item-actor asset directory.
local uehelp = require("core.uehelp")

local M = {}
M._map = nil
function M.init(map) M._map = map; return M end

local function variants(row)
  local out, seen = {}, {}
  local function add(r) if r and not seen[r] then seen[r] = true; out[#out + 1] = r end end
  add(row)
  add(row:gsub("_", ""))                    -- Weather_Station -> WeatherStation
  add(row:gsub("(%l)(%u)", "%1_%2"))        -- HoeDiamond -> Hoe_Diamond
  add(row:gsub("^%l", string.upper))        -- log -> Log
  return out
end

-- Returns class, resolvedShortName (nil if the row can't be resolved to a loaded/loadable class).
function M.classFor(row)
  local it = M._map and M._map.items
  if not (it and it.classFmt and row) then return nil end
  for _, r in ipairs(variants(row)) do
    local short = string.format(it.classFmt, r)
    local asset
    if it.assetDir then
      asset = it.assetDir .. short:gsub("_C$", "") .. "." .. short
    end
    local cls = uehelp.classByName(short, asset)
    if cls then return cls, short end
  end
  return nil
end

-- Grant `amount` of a row's item to a controller's player via the game's debug spawner.
function M.give(pc, row, amount)
  local cls = M.classFor(row)
  if not (cls and pc) then return false end
  return pcall(function() pc:DEBUG_SpawnItems(cls, amount or 1) end) == true
end

return M
