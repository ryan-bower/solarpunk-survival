-- Lightning Rod: the game's own Weather Station buildable IS the rod -- a vane on a pole, already
-- researchable in the weather-tech group and placeable beside/on batteries (a genuinely new cooked
-- mesh cannot be authored from UE4SS Lua; docs/MILESTONE-2.md). Cosmetic best-effort: a Copper
-- item is stood vertically at the pole top of each station. Any strike targeted within
-- `lightning_rod_range` (25 m) of a station is redirected to the rod's ground position; grounded
-- strikes charge the nearest battery within 3 m.
local F = {}
local ctx
local stationClass = nil   -- exact class name, resolved from candidates or a one-off scan
local fullScanDone = false  -- the whole-world fallback sweep is genuinely one-shot (see below)

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
  -- Fallback: sweep every live actor for one whose class name smells like the weather station.
  -- This MUST be truly one-shot. It reflects GetClass() on EVERY actor in the world, and doing that
  -- to an actor caught mid-teardown is an uncatchable native abort -- which is exactly what happened
  -- live on 2026-07-23: with no candidate ever resolving, this ran on every single strike (~90x over
  -- one storm), and one sweep during the storm's placeable-destruction touched a dying actor and took
  -- the process down. The cheap candidate fast-path above still picks up a station built later (its
  -- class blueprint loads and classByName resolves it), so gating the sweep costs no real coverage.
  -- MUST also skip placement previews (touching a *PlaceablePreview_C ghost is a native AV crash
  -- pcall cannot catch -- happened live 2026-07-21) and the carryable _Item actor.
  if fullScanDone then return nil end
  fullScanDone = true
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

-- REMOVED (2026-07-23 code review): the cosmetic copper topper.
--
-- It spawned a bare BP_Copper_Item_C as a prop and then K2_AttachToActor'd it onto the station --
-- both members of the attach/spawn family this project has already been killed by twice (the
-- component rig on the pawn, the preview-ghost attach). A native access violation is not
-- catchable by pcall, and since the natural-storm tap now emits weather.changed on the game's OWN
-- first bolt, this ran with no player input: build a Weather Station, wait for weather, crash.
--
-- The rod's actual job -- grounding every strike within lightning_rod_range and charging the
-- battery under it -- never needed the prop. If the look matters, it belongs in the content pak
-- as a cooked mesh on the buildable, not in a runtime attach.

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
  ctx.log.info("lightning_rod: Weather Stations ground all strikes within 25 m (weather-tech unlock)")
  return true
end

return F
