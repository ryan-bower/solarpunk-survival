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

-- ONE CALL PER ITEM, deliberately.
--
-- `DEBUG_SpawnItems(Item, Amt)` takes an amount and returns cleanly for any value, but it only
-- ever DELIVERS for Amt == 1. Proven live 2026-07-26: asking for 30 muffins returned true and put
-- nothing in the inventory; the identical call with 1 landed exactly one; sixty calls of 1 landed
-- sixty. Every bulk grant in the mod rode on that lie and silently handed the player nothing --
-- a lightning-felled tree grants `tree_wood_drop` (4) logs and destroyed tech drops its half-cost
-- salvage, so both logged their success line while dropping not a single item.
--
-- And it is NOT an inventory grant (decoded 2026-07-30 from bp_controller.json ubergraph 49144):
-- it BeginDeferredActorSpawns the ITEM ACTOR at the player's location +500Z with
-- ManualPickup=false, NoPickupTime=0, FlyToPlayer=FALSE, then FinishSpawningActor. The drop
-- free-falls; it only reaches the pack if it lands on the player's pickup overlap. A caller that
-- needs guaranteed delivery must find the dropped actor afterwards and fly it in itself
-- (fishing.lua deliverRodActor does exactly that).
local MAX_GRANT = 200   -- runaway-loop backstop; every real caller asks for single digits

local function spawnN(pc, cls, amount)
  local n = math.floor(tonumber(amount) or 1)
  if n < 1 then n = 1 elseif n > MAX_GRANT then n = MAX_GRANT end
  local got = 0
  for _ = 1, n do
    if pcall(function() pc:DEBUG_SpawnItems(cls, 1) end) then got = got + 1 end
  end
  return got == n, got
end

-- Grant `amount` of a row's item to a controller's player via the game's debug spawner.
function M.give(pc, row, amount)
  local cls = M.classFor(row)
  if not (cls and pc) then return false end
  return (spawnN(pc, cls, amount))
end

-- Grant `amount` of an item named by its ITEM-ACTOR class short name (e.g. "BP_Beeswax_Item_C").
-- The ritual offerings (mapping.ritual.*Offerings) are mapped as world item-actor classes, not
-- DB_Items rows, so M.give's row->class formatting doesn't fit them -- resolve the class directly,
-- LoadAsset-ing it from the flat item-actor dir if it isn't resident yet.
-- Returns ok, spawnedCount, why -- why is "class" when the class would not resolve/load at all
-- (no spawn was even attempted; a pak-degraded session looks exactly like a delivery failure
-- otherwise) and "spawn" when the spawner ran.
function M.giveByClass(pc, shortClass, amount)
  if not (pc and shortClass) then return false, 0, "args" end
  local it = M._map and M._map.items
  local asset
  if it and it.assetDir then
    asset = it.assetDir .. shortClass:gsub("_C$", "") .. "." .. shortClass
  end
  local cls = uehelp.classByName(shortClass, asset)
  if not cls then return false, 0, "class" end
  local ok, got = spawnN(pc, cls, amount)   -- one call per item; see spawnN
  return ok, got, "spawn"
end

return M
