-- The Dark Arts: sacrifice a sheep inside a candle-ringed pentagram to forge a lightning rod.
--
-- While a storm rages, the host checks every `ritual_check_interval` seconds for a live sheep
-- with >= `ritual_fences` fence pieces and >= `ritual_candles` candles (any state -- the storm's
-- rain snuffs flames, so lit cannot be required) within `ritual_radius` (20 m). When the rite is ready, the storm turns on the sheep: the next bolts target it. When a
-- bolt lands, the sheep is consumed, and every player within the circle holding the mundane wand
-- has it transmuted into a lightning rod (Weather Station).
--
-- MP: everything here is host-side; the bolt, the sheep's demise and the granted items all ride
-- native replication. The check is a chain of one-shot delays alive only during storms -- never a
-- free-running UObject timer (those native-crash on level transitions).
local F = {}
local ctx

local stormOn   = false
local token     = 0        -- bumped when the storm state flips; stale delays self-cancel
local announced = false    -- "the pentagram hums" fires once per readiness
local striking  = false    -- a ritual bolt is in flight
local pendingSheep, pendingLoc  -- the offering the in-flight bolt is aimed at

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function afterIfStorm(seconds, tok, fn)
  local guarded = ctx.log.guard("ritual.delay", function()
    onGameThread(function()
      if stormOn and tok == token then fn() end
    end)
  end)
  local ms = math.floor((seconds or 0) * 1000)
  if ms <= 0 then guarded(); return end
  if not pcall(ExecuteWithDelay, ms, guarded) then guarded() end
end


--------------------------------------------------------------------- condition checks
-- Candles count in ANY state: the storm's own rain snuffs the flames, so requiring "lit" would
-- make the rite impossible in the very weather it needs (user-decided rule change).

-- A sheep whose surroundings satisfy the pentagram, or nil.
local function findRitualSheep()
  local sheepClass = ctx.map.animal and ctx.map.animal.sheepClass
  if not sheepClass then return nil end
  local sheep = ctx.uehelp.findAll(sheepClass)
  if #sheep == 0 then return nil end

  local r2 = ctx.config.get("ritual_radius") ^ 2
  local needF = ctx.config.get("ritual_fences")
  local needC = ctx.config.get("ritual_candles")

  -- One guarded actor scan (only reached while a storm is on AND a sheep exists).
  local fences, candles = {}, {}
  for _, a in ipairs(ctx.uehelp.findAll("Actor")) do
    local cls = ctx.uehelp.className(a)
    if cls then
      if cls:find("Fence", 1, true) then
        fences[#fences + 1] = a
      elseif cls:find("Candle", 1, true) and not cls:find("Preview", 1, true) then
        candles[#candles + 1] = a
      end
    end
  end

  for _, s in ipairs(sheep) do
    if ctx.uehelp.isValid(s) then
      local sl = ctx.identity.locationOf(s)
      if sl then
        local nf = 0
        for _, f in ipairs(fences) do
          local fl = ctx.identity.locationOf(f)
          if fl and ctx.uehelp.dist2(fl, sl) <= r2 then nf = nf + 1 end
        end
        local nc = 0
        for _, cd in ipairs(candles) do
          local cl = ctx.identity.locationOf(cd)
          if cl and ctx.uehelp.dist2(cl, sl) <= r2 then nc = nc + 1 end
        end
        if nf >= needF and nc >= needC then return s, sl, nf, nc end
      end
    end
  end
  return nil
end

--------------------------------------------------------------------- the rite
-- Best-effort read of what a pawn holds; nil when unreadable (struct layout not yet mapped).
local function heldItemClassName(pawn)
  local name
  pcall(function()
    local held = pawn.CurItemdataInHand
    if held == nil then return end
    for _, field in ipairs({ "ItemClass", "Item Class", "Class", "Item" }) do
      local okf, v = pcall(function() return held[field] end)
      if okf and v ~= nil then
        local okn, n = pcall(function() return v:GetFName():ToString() end)
        if okn and n then name = n; return end
      end
    end
  end)
  return name
end

local function transformWandHolders(center)
  local rit = ctx.map.ritual
  local wandCls = ctx.items.classFor(rit.wandItemRow)
  local wandName = nil
  pcall(function() wandName = wandCls and wandCls:GetFName():ToString() end)
  local rodCls = ctx.items.classFor(rit.rodItemRow)
  if not rodCls then ctx.log.warn("ritual: rod item class missing"); return end

  local r2 = ctx.config.get("ritual_radius") ^ 2
  local blessed = 0
  for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl and ctx.uehelp.dist2(pl, center) <= r2 then
      local held = heldItemClassName(pawn)
      -- unreadable held-item = accept (approximation, logged in docs/MILESTONE-2.md)
      if held == nil or (wandName and held == wandName) then
        local pc
        pcall(function() pc = pawn.Controller end)
        if ctx.uehelp.isValid(pc) then
          if pcall(function() pc:DEBUG_SpawnItems(rodCls, 1) end) then blessed = blessed + 1 end
        end
      end
    end
  end
  if blessed > 0 then
    ctx.log.info("*** the wand drinks the bolt -- " .. blessed ..
      " lightning rod(s) forged. Place your Weather Station; the storm will bend to it.")
  else
    ctx.log.info("ritual: the bolt found no wand-bearer inside the circle")
  end
end

local function performSacrifice(sheep, loc)
  -- the bolt itself (VFX + thunder + radius damage) is delivered by storms.strikeAt
  if ctx.uehelp.isValid(sheep) then pcall(function() sheep:K2_DestroyActor() end) end
  ctx.log.info("*** the sacrifice is accepted -- the sheep is no more ***")
  transformWandHolders(loc)
  ctx.bus.emit("ritual.completed", { location = loc })
end

--------------------------------------------------------------------- storm-time check chain
local function checkChain(tok)
  if not stormOn or tok ~= token then return end
  afterIfStorm(ctx.config.get("ritual_check_interval"), tok, function()
    if ctx.net.isHost() and not striking then
      local sheep, loc, nf, nc = findRitualSheep()
      if sheep and ctx.services.strikeAt then
        if not announced then
          announced = true
          ctx.log.info("*** the pentagram hums (" .. nf .. " fences, " .. nc ..
            " candles)... the storm has noticed the offering ***")
        end
        striking = true
        pendingSheep, pendingLoc = sheep, loc
        -- the sacrifice itself fires on the "lightning.strike" IMPACT event (see init), so the
        -- sheep dies exactly on the bolt's big strike frame -- no parallel timer to race it.
        ctx.services.strikeAt(loc, "ritual")
      end
    end
    checkChain(tok)
  end)
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "ritual",
      { "animal.sheepClass", "ritual.wandItemRow", "ritual.rodItemRow", "items.classFmt", "pawn.class" }) then
    return false
  end
  ctx.bus.on("weather.changed", ctx.log.guard("ritual.weather", function(e)
    local now = e and e.storm or false
    if now == stormOn then return end
    stormOn = now
    token = token + 1
    announced, striking = false, false
    pendingSheep, pendingLoc = nil, nil
    if stormOn then checkChain(token) end
  end))

  -- The sacrifice lands WITH the bolt: storms emits "lightning.strike" at the big strike frame.
  -- A strike near the pending offering consumes it; a strike drawn elsewhere (a lightning rod
  -- grounding the rite) releases the latch so the chain simply tries again.
  ctx.bus.on("lightning.strike", ctx.log.guard("ritual.impact", function(e)
    if not (striking and pendingLoc and e and e.location) then return end
    if ctx.uehelp.dist2(e.location, pendingLoc) <= 400 * 400 then
      performSacrifice(pendingSheep, pendingLoc)
    else
      ctx.log.info("...the bolt was drawn away from the circle -- the rite holds (a rod nearby?)")
    end
    striking, pendingSheep, pendingLoc = false, nil, nil
  end))
  ctx.log.info("ritual: the dark arts are listening (sheep + 15 fences + 5 candles + wand, in a storm)")
  return true
end

return F
