-- Lightning Rod: a buildable that redirects every strike within `lightning_rod_range` to itself
-- and safely grounds it — or, if linked to a battery, fully charges that battery. Registers into
-- the game's existing build menu + unlock system.
local F = {}
local ctx
local ROD_CLASS = "BP_LightningRod_C"   -- the mod's cooked rod asset (LogicMod); tracked once it exists
local rods = {}

function F.init(c)
  ctx = c

  if ctx.gate.require(ctx.log, ctx.map, "lightning_rod:register",
        { "buildmenu.registerFn", "unlock.registerFn" }) then
    F.register()
  end

  pcall(NotifyOnNewObject, ROD_CLASS, ctx.log.guard("rod.new", function(o)
    if ctx.uehelp.isValid(o) then rods[#rods + 1] = o end
  end))
  for _, a in ipairs(ctx.uehelp.findAll(ROD_CLASS)) do rods[#rods + 1] = a end

  -- Expose interception to the storm targeting code.
  ctx.services.rodIntercept = function(loc) return F.intercept(loc) end
  ctx.bus.on("strike.rod", function(e) F.onStrikeRod(e) end)
  return true
end

-- Return a rod actor whose range covers `loc` (nearest wins), or nil.
function F.intercept(loc)
  local range = ctx.config.get("lightning_rod_range")
  local best, bestD = nil, range * range
  for i = #rods, 1, -1 do
    local rod = rods[i]
    if not ctx.uehelp.isValid(rod) then
      table.remove(rods, i)
    else
      local rl = ctx.identity.locationOf(rod)
      if rl then
        local d = ctx.uehelp.dist2(rl, loc)
        if d <= bestD then best, bestD = rod, d end
      end
    end
  end
  return best
end

function F.onStrikeRod(e)
  if not ctx.net.isHost() then return end
  if ctx.config.get("rod_charges_battery") then
    local batt = F.linkedBattery(e.actor)
    if batt then
      ctx.bus.emit("strike.battery", { actor = batt, id = ctx.identity.idOf(batt), location = e.location })
    end
  end
  if ctx.config.get("rod_takes_damage") and e.id then
    ctx.health.applyDamage(e.id, ctx.config.get("strike_structure_dmg"), { source = "lightning" })
  end
  ctx.net.multicast("Multicast_RodStrike", { id = e.id })
  ctx.log.debug("lightning grounded by rod")
end

-- Find the battery attached/linked to a rod. Placeholder proximity link (3 m) until the
-- game's energy-network link (energy.linkFn) is mapped.
function F.linkedBattery(rod)
  local map = ctx.map
  if not (map.battery and map.battery.class) then return nil end
  local rl = ctx.identity.locationOf(rod)
  if not rl then return nil end
  local LINK2 = 300 * 300
  local best, bestD = nil, LINK2
  for _, b in ipairs(ctx.uehelp.findAll(map.battery.class)) do
    local bl = ctx.identity.locationOf(b)
    if bl then
      local d = ctx.uehelp.dist2(rl, bl)
      if d <= bestD then best, bestD = b, d end
    end
  end
  return best
end

function F.register()
  -- TODO(RE): register the rod into the build menu (buildmenu.registerFn) and gate it behind the
  -- unlock system (unlock.registerFn). See docs/REVERSE-ENGINEERING.md.
  ctx.log.info("lightning_rod: register stub (build-menu + unlock hooks pending RE)")
end

return F
