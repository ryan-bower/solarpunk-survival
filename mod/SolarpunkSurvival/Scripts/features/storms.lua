-- Deadly Storms + Lightning (Milestone 1).
-- Host-authoritative: detects storms, schedules frequent (sometimes bursting) strikes, weights
-- targets by exposure/position, telegraphs each bolt, resolves the dodge, then classifies the
-- struck actor and emits a typed strike.<kind> event that the effect modules handle.
local F = {}
local ctx

local GRAN_MS      = 500     -- scheduler granularity
local stormActive  = false
local severity     = 0
local sinceLast    = 0
local schedulerOn  = false

--------------------------------------------------------------------- weather
function F.hookWeather()
  local w = ctx.map.weather
  if w.onChangedFn and w.managerClass then
    local hooked = pcall(RegisterHook, w.managerClass .. ":" .. w.onChangedFn,
      ctx.log.guard("weather.hook", function() F.readWeather() end))
    if hooked then ctx.log.info("storms: hooked " .. w.onChangedFn); return end
  end
  ctx.log.info("storms: polling weather state (no onChangedFn)")
  pcall(LoopAsync, 1000, ctx.log.guard("weather.poll", function() F.readWeather() end))
end

function F.readWeather()
  local w, u = ctx.map.weather, ctx.uehelp
  local mgr = u.findFirst(w.managerClass)
  if not mgr then return end
  local isStorm, sev = false, 0
  if w.currentProp then
    local ok, v = u.get(mgr, w.currentProp)
    if ok then
      if w.stormValue ~= nil then isStorm = (v == w.stormValue)
      else isStorm = (v ~= nil and v ~= 0) end
    end
  end
  if w.severityProp then
    local ok, v = u.get(mgr, w.severityProp)
    if ok and type(v) == "number" then sev = v end
  end
  if isStorm and sev <= 0 then sev = 1 end
  F.setStorm(isStorm, sev)
end

function F.setStorm(active, sev)
  severity = sev or 0
  if active ~= stormActive then
    stormActive = active
    ctx.bus.emit("weather.changed", { storm = active, severity = severity })
    if active then
      ctx.bus.emit("storm.warning", { lead = ctx.config.get("storm_warning_lead") })
      ctx.log.info(string.format("storm started (severity %.2f)", severity))
    else
      ctx.log.info("storm ended")
    end
  end
end

--------------------------------------------------------------------- exposure / position
function F.isSheltered(pawn)
  local p = ctx.map.pawn
  if p and p.isShelteredFn then
    local ok, v = ctx.uehelp.call(pawn, p.isShelteredFn)
    if ok and type(v) == "boolean" then return v end
  end
  return false
end

function F.distanceToLand(actor)
  local isl = ctx.map.island
  if not (isl and isl.class) then return nil end
  local loc = ctx.identity.locationOf(actor)
  if not loc then return nil end
  local best = math.huge
  for _, island in ipairs(ctx.uehelp.findAll(isl.class)) do
    local il = ctx.identity.locationOf(island)
    if il then best = math.min(best, ctx.uehelp.dist2(loc, il)) end
  end
  if best == math.huge then return nil end
  return math.sqrt(best)
end

function F.isFlying(pawn)
  -- TODO(RE): resolve whether the pawn is riding a flying airship (airship.isFlyingFn).
  return false
end

function F.isInOpen(pawn)
  if F.isSheltered(pawn) then return false end
  local d = F.distanceToLand(pawn)
  if d and d > ctx.config.get("open_distance_threshold") then return true end
  return true -- outdoors and not sheltered
end

--------------------------------------------------------------------- targeting
function F.gatherCandidates()
  local u, map, cfg = ctx.uehelp, ctx.map, ctx.config
  local cands = {}
  local function add(actor, kind, weight)
    if u.isValid(actor) and weight > 0 then
      cands[#cands + 1] = { actor = actor, kind = kind, weight = weight }
    end
  end

  if map.pawn and map.pawn.class then
    for _, p in ipairs(u.findAll(map.pawn.class)) do
      local w = 1.0
      if F.isInOpen(p) then w = w * cfg.get("open_target_bias") end
      local d = F.distanceToLand(p)
      if d and d > cfg.get("open_distance_threshold") then w = w * cfg.get("open_distance_mult") end
      if F.isFlying(p) then w = w * cfg.get("flying_strike_mult") end
      add(p, "player", w)
    end
  end
  for _, section in ipairs({ "crop", "battery" }) do
    local s = map[section]
    if s and s.class then
      for _, a in ipairs(u.findAll(s.class)) do add(a, section, 0.6) end
    end
  end
  if map.machine and map.machine.classes then
    for _, c in ipairs(map.machine.classes) do
      for _, a in ipairs(u.findAll(c)) do add(a, "machine", 0.6) end
    end
  end
  if map.build and map.build.pieceClass then
    local pieces = u.findAll(map.build.pieceClass)
    for i = 1, math.min(#pieces, 40) do add(pieces[i], "structure", 0.3) end
  end
  return cands
end

function F.weightedPick(cands)
  local total = 0
  for _, c in ipairs(cands) do total = total + c.weight end
  if total <= 0 then return nil end
  local r = math.random() * total
  for _, c in ipairs(cands) do
    r = r - c.weight
    if r <= 0 then return c end
  end
  return cands[#cands]
end

--------------------------------------------------------------------- strike lifecycle
function F.after(seconds, fn)
  local guarded = ctx.log.guard("delay", fn)
  local ms = math.floor((seconds or 0) * 1000)
  if ms <= 0 then guarded(); return end
  if not pcall(ExecuteWithDelay, ms, guarded) then guarded() end
end

function F.fireBolt()
  if not ctx.net.isHost() then return end
  local pick = F.weightedPick(F.gatherCandidates())
  if not pick then return end
  local loc = ctx.identity.locationOf(pick.actor)
  if not loc then return end

  -- Lightning Rod interception: redirect the strike to a covering rod.
  local target = pick
  local rod = ctx.services.rodIntercept and ctx.services.rodIntercept(loc)
  if rod then
    target = { actor = rod, kind = "rod" }
    loc = ctx.identity.locationOf(rod) or loc
  end

  local radius = ctx.config.get("strike_radius")
  local lead   = ctx.config.get("telegraph_lead")
  ctx.net.multicast("Multicast_Telegraph", { X = loc.X, Y = loc.Y, Z = loc.Z, radius = radius, lead = lead })
  ctx.bus.emit("lightning.telegraph", { location = loc, radius = radius, lead = lead })

  F.after(lead, function() F.resolveStrike(target, loc) end)
end

function F.resolveStrike(target, loc)
  if not ctx.net.isHost() or not ctx.uehelp.isValid(target.actor) then return end

  -- Players can dodge by leaving the strike radius before the bolt lands.
  if target.kind == "player" then
    local cur = ctx.identity.locationOf(target.actor)
    local r = ctx.config.get("strike_radius")
    if cur and ctx.uehelp.dist2(cur, loc) > r * r then
      ctx.bus.emit("lightning.strike", { location = loc, dodged = true })
      return
    end
  end

  ctx.net.multicast("Multicast_Bolt", { X = loc.X, Y = loc.Y, Z = loc.Z })
  ctx.bus.emit("lightning.strike", { location = loc })
  ctx.bus.emit("strike." .. target.kind, {
    actor = target.actor, id = ctx.identity.idOf(target.actor), location = loc,
  })
end

--------------------------------------------------------------------- scheduler
function F.startScheduler()
  if schedulerOn then return end
  schedulerOn = true
  pcall(LoopAsync, GRAN_MS, ctx.log.guard("storm.tick", function()
    if stormActive and ctx.net.isHost() then F.maybeFire() end
  end))
end

function F.maybeFire()
  local cfg = ctx.config
  sinceLast = sinceLast + GRAN_MS / 1000
  local rate = math.max(0.05, severity * cfg.get("lightning_chance"))
  local interval = cfg.get("strike_interval") / rate
  if sinceLast < interval then return end
  sinceLast = 0

  local n = 1
  if math.random() < cfg.get("burst_chance") then
    n = math.random(2, math.max(2, math.floor(cfg.get("burst_size"))))
  end
  for i = 1, n do
    F.after((i - 1) * 0.25, function() F.fireBolt() end)
  end
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "storms", { "weather.managerClass" }) then
    return false
  end
  F.hookWeather()
  F.startScheduler()
  ctx.log.info("storms: active")
  return true
end

return F
