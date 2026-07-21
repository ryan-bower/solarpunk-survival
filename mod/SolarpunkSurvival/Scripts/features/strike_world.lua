-- What lightning does to the WORLD at the impact point (host-authoritative; all changes happen to
-- natively-replicating game actors, so clients see them without any custom carrier):
--   battery / generator  -> charge to 100%
--   furnace              -> powered as if it just consumed a wax briquette
--   any other tech       -> smoking + "broken"; struck again before repair -> destroyed,
--                           half its crafting components salvaged
--   tree                 -> felled: 4 logs + that tree type's sapling
--
-- Machine internals live in parent classes the RE capture didn't include, so actors are classified
-- by CLASS NAME and members are probed from candidate lists in mapping.lua (each probe is guarded;
-- a miss logs once and no-ops). A fresh `sps_dump` near a base will pin the real names.
local F = {}
local ctx

local function classifyName(cls)
  local m = ctx.map
  local function hasAny(hints)
    if not hints then return false end
    for _, h in ipairs(hints) do
      if cls:find(h, 1, true) then return true end
    end
    return false
  end
  if m.tree and m.tree.classPrefix and cls:sub(1, #m.tree.classPrefix) == m.tree.classPrefix then
    return "tree"
  end
  if hasAny(m.battery and m.battery.classHints) then return "battery" end
  if hasAny(m.machine and m.machine.generatorHints) then return "generator" end
  if hasAny(m.furnace and m.furnace.classHints) then return "furnace" end
  if hasAny(m.machine and m.machine.excludeHints) then return nil end
  for _, suf in ipairs((m.machine and m.machine.techSuffixes) or {}) do
    if cls:sub(-#suf) == suf then return "tech" end
  end
  return nil
end

-- First candidate property that reads as a number on obj -> name, value.
local function probeNumberProp(obj, candidates)
  for _, p in ipairs(candidates or {}) do
    local ok, v = ctx.uehelp.get(obj, p)
    if ok and type(v) == "number" then return p, v end
  end
  return nil
end

-- Nearest player controller to a location (for granting salvage/drops -- ground-spawning items
-- needs SpawnLeftoverItem's struct layout, still unmapped).
local function nearestController(loc)
  local pcls = ctx.map.pawn and ctx.map.pawn.class
  if not pcls then return nil end
  local best, bestD = nil, math.huge
  for _, pawn in ipairs(ctx.uehelp.findAll(pcls)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl then
      local d = ctx.uehelp.dist2(pl, loc)
      if d < bestD then
        local pc
        pcall(function() pc = pawn.Controller end)
        if ctx.uehelp.isValid(pc) then best, bestD = pc, d end
      end
    end
  end
  return best
end

local function giveItems(loc, row, amount)
  local pc = nearestController(loc)
  if not (pc and ctx.items.give(pc, row, amount)) then
    ctx.log.warn("strike_world: cannot grant " .. tostring(amount) .. "x " .. tostring(row))
    return false
  end
  return true
end

--------------------------------------------------------------------- handlers
function F.chargeToFull(actor, cls)
  local b = ctx.map.battery
  local prop = b and select(1, probeNumberProp(actor, b.chargePropCandidates))
  if not prop then
    ctx.log.info("strike_world: no charge prop found on " .. cls .. " (re-dump to map it)")
    return
  end
  local maxv = 100
  local mprop, mv = probeNumberProp(actor, b.maxChargePropCandidates)
  if mprop then maxv = mv end
  ctx.uehelp.set(actor, prop, maxv)
  ctx.log.info("lightning charged " .. cls .. " to " .. tostring(maxv) .. " (" .. prop .. ")")
end

function F.fuelFurnace(actor, cls)
  local f = ctx.map.furnace
  local secs = ctx.config.get("furnace_briquette_seconds")
  -- try a fuel/burn function first, then a burn-time property bump
  for _, fn in ipairs((f and f.fuelFnCandidates) or {}) do
    local okc = select(1, ctx.uehelp.call(actor, fn, secs))
    if okc then
      ctx.log.info("lightning fueled " .. cls .. " via " .. fn)
      return
    end
  end
  local prop, cur = probeNumberProp(actor, f and f.fuelPropCandidates)
  if prop then
    ctx.uehelp.set(actor, prop, (cur or 0) + secs)
    ctx.log.info("lightning fueled " .. cls .. " (+" .. secs .. "s " .. prop .. ")")
  else
    ctx.log.info("strike_world: no fuel member found on " .. cls .. " (re-dump to map it)")
  end
end

-- Tech: 1st strike = smoking/broken (repairable); 2nd strike before repair = destroyed + salvage.
function F.breakTech(actor, cls, loc)
  local id = ctx.identity.idOf(actor)
  if not id then return end
  local rec = ctx.health.attach(actor, {
    max = ctx.config.get("structure_hp_base"), kind = "machine", twoHit = true,
  })
  local wasDamaged = rec and rec.damaged
  local after = ctx.health.applyDamage(id, ctx.config.get("strike_structure_dmg"), { source = "lightning" })
  if after and after.destroyed then
    -- second hit: gone. Half the crafting components (curated table; recipes unreadable from Lua).
    local salvage = (ctx.map.machine and ctx.map.machine.salvageDefault) or {}
    for row, n in pairs(salvage) do giveItems(loc, row, n) end
    ctx.log.info("*** " .. cls .. " DESTROYED by a second strike -- salvage recovered")
  elseif after and after.damaged and not wasDamaged then
    ctx.log.info("*** " .. cls .. " is BROKEN and smoking -- repair it before the next strike!")
  end
end

-- Trees: fell (destroy replicates natively) + drop 4 logs and the matching sapling.
function F.fellTree(actor, cls, loc)
  local kind = cls:match("^BP_Tree_(%w+)")   -- Birch / Alder / Maple / Pine / Oak ...
  pcall(function() actor:K2_DestroyActor() end)
  giveItems(loc, "log", ctx.config.get("tree_wood_drop"))
  if kind then
    if not giveItems(loc, kind .. "Sapling", 1) then
      ctx.log.info("strike_world: no sapling item for tree type '" .. kind .. "'")
    end
  end
  ctx.log.info("lightning felled a " .. (kind or "?") .. " tree -- wood + sapling recovered")
end

--------------------------------------------------------------------- impact scan
function F.onStrike(e)
  if not ctx.net.isHost() then return end
  local loc = e and e.location
  if not loc then return end
  local r = ctx.config.get("strike_radius")
  local r2 = r * r

  -- One guarded scan per landed bolt (same access pattern as the manual RE capture).
  for _, a in ipairs(ctx.uehelp.findAll("Actor")) do
    if ctx.uehelp.isValid(a) then
      local al = ctx.identity.locationOf(a)
      if al and ctx.uehelp.dist2(al, loc) <= r2 then
        local cls = ctx.uehelp.className(a)
        local kind = cls and classifyName(cls)
        if kind == "battery" or kind == "generator" then
          F.chargeToFull(a, cls)
          ctx.bus.emit("strike.battery", { actor = a, id = ctx.identity.idOf(a), location = al })
        elseif kind == "furnace" then
          F.fuelFurnace(a, cls)
        elseif kind == "tech" then
          F.breakTech(a, cls, al)
        elseif kind == "tree" then
          F.fellTree(a, cls, al)
        end
      end
    end
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "strike_world", { "items.classFmt", "pawn.class" }) then
    return false
  end
  ctx.bus.on("lightning.strike", ctx.log.guard("strike_world", function(e)
    if not e.dodged then F.onStrike(e) end
  end))
  ctx.services.chargeBattery = function(actor, cls) F.chargeToFull(actor, cls or "battery") end
  ctx.log.info("strike_world: batteries charge, furnaces fuel, tech breaks, trees fall")
  return true
end

return F
