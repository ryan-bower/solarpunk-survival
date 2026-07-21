-- Lightning Rod: the game's own Weather Station buildable IS the rod -- a vane on a pole, already
-- researchable in the weather-tech group and placeable beside/on batteries (a genuinely new cooked
-- mesh cannot be authored from UE4SS Lua; docs/MILESTONE-2.md). Cosmetic best-effort: a Copper
-- item is stood vertically at the pole top of each station. Any strike targeted within
-- `lightning_rod_range` (25 m) of a station is redirected to the rod's ground position; grounded
-- strikes charge the nearest battery within 3 m.
local F = {}
local ctx
local stationClass = nil   -- exact class name, resolved from candidates or a one-off scan
local toppers = {}         -- station id -> copper actor (cosmetic)

local function resolveStationClass()
  if stationClass then return stationClass end
  local r = ctx.map.rod
  for _, cand in ipairs((r and r.stationClassCandidates) or {}) do
    if ctx.uehelp.classByName(cand) then
      stationClass = cand
      ctx.log.info("lightning_rod: station class = " .. cand)
      return stationClass
    end
  end
  -- one-off scan: find any live actor whose class name smells like the weather station.
  -- MUST skip placement previews (attaching to a *PlaceablePreview_C ghost is a native AV crash
  -- pcall cannot catch -- happened live 2026-07-21) and the carryable _Item actor.
  for _, a in ipairs(ctx.uehelp.findAll("Actor")) do
    local cls = ctx.uehelp.className(a)
    if cls and (cls:find("Weather_Station", 1, true) or cls:find("WeatherStation", 1, true))
        and not cls:find("Preview", 1, true) and not cls:find("_Item", 1, true) then
      stationClass = cls
      ctx.log.info("lightning_rod: station class discovered live = " .. cls)
      return stationClass
    end
  end
  return nil
end

local function stations()
  local cls = resolveStationClass()
  if not cls then return {} end
  return ctx.uehelp.findAll(cls)
end

-- Cosmetic copper topper: stand the copper item vertically at the pole top. Purely best-effort.
local function dressStation(st)
  if not ctx.config.get("rod_copper_topper") then return end
  if not ctx.net.isHost() then return end
  -- Never touch a placement preview or an item actor: attach on a preview is a native crash.
  local cn = ctx.uehelp.className(st)
  if not cn or cn:find("Preview", 1, true) or cn:find("_Item", 1, true) then return end
  local id = ctx.identity.idOf(st)
  if not id or (toppers[id] and ctx.uehelp.isValid(toppers[id])) then return end
  local row = ctx.map.rod and ctx.map.rod.copperItemRow
  local cls = row and ctx.items.classFor(row)
  local sl = cls and ctx.identity.locationOf(st)
  if not sl then return end
  local pc = ctx.uehelp.playerController()
  local copper = pc and ctx.uehelp.spawnActorAt(pc, cls, { X = sl.X, Y = sl.Y, Z = sl.Z + 260 })
  if not copper then return end
  pcall(function()
    copper:K2_AttachToActor(st, "None", 1, 1, 1, false)   -- keep-world attach to the pole
    copper:K2_SetActorRotation({ Pitch = 90, Yaw = 0, Roll = 0 }, false)
    copper:SetActorEnableCollision(false)
  end)
  toppers[id] = copper
end

-- Return rodActor, groundLoc for a strike aimed at `loc`, or nil (nearest station wins).
function F.intercept(loc)
  if not loc then return nil end
  local range = ctx.config.get("lightning_rod_range")
  local best, bestL, bestD = nil, nil, range * range
  for _, st in ipairs(stations()) do
    if ctx.uehelp.isValid(st) then
      local sl = ctx.identity.locationOf(st)
      if sl then
        local d = ctx.uehelp.dist2(sl, loc)
        if d <= bestD then best, bestL, bestD = st, sl, d end
      end
    end
  end
  if best then return best, bestL end
  return nil
end

function F.onStrikeRod(e)
  if not ctx.net.isHost() then return end
  if ctx.config.get("rod_charges_battery") and ctx.services.chargeBattery then
    local batt = F.linkedBattery(e.actor)
    if batt then
      ctx.services.chargeBattery(batt, ctx.uehelp.className(batt) or "battery")
    end
  end
  ctx.log.info("lightning grounded by the rod")
end

-- The battery under/next to the rod (3 m), probed by class-name hint.
function F.linkedBattery(rod)
  local hints = ctx.map.battery and ctx.map.battery.classHints
  local rl = ctx.identity.locationOf(rod)
  if not (hints and rl) then return nil end
  local LINK2 = 300 * 300
  local best, bestD = nil, LINK2
  for _, a in ipairs(ctx.uehelp.findAll("Actor")) do
    local cls = ctx.uehelp.className(a)
    if cls then
      for _, h in ipairs(hints) do
        if cls:find(h, 1, true) then
          local bl = ctx.identity.locationOf(a)
          if bl then
            local d = ctx.uehelp.dist2(rl, bl)
            if d <= bestD then best, bestD = a, d end
          end
          break
        end
      end
    end
  end
  return best
end

function F.init(c)
  ctx = c
  ctx.services.rodIntercept = function(loc) return F.intercept(loc) end
  ctx.bus.on("strike.rod", ctx.log.guard("rod.strike", function(e) F.onStrikeRod(e) end))
  -- Dress stations when a storm starts (cheap moment to look for new ones).
  ctx.bus.on("weather.changed", ctx.log.guard("rod.dress", function(e)
    if e and e.storm then
      for _, st in ipairs(stations()) do dressStation(st) end
    end
  end))
  ctx.log.info("lightning_rod: Weather Stations ground all strikes within 25 m (weather-tech unlock)")
  return true
end

return F
