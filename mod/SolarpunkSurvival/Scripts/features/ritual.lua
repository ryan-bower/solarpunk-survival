-- The Dark Arts: the pentagram now works TWO rites, the two rungs of the codex's ladder.
--
--   Rite of the Quenched Rod (first rung):  a live CHICKEN penned in the star + one of each of
--     the rite's five offerings (water clear of impurities, comb of the honeybee, leaf of the
--     trees, clay of the earth, a berry nourished by the sun) resting by the candles. The bolt
--     takes the bird and every mundane rod held inside the circle turns river-blue -> Hydration
--     Wand (features/wand.lua hydrateWands).
--   Rite of the Grounded Bolt (second rung): a live SHEEP + its own five offerings (rounded
--     refined copper, raw iron ore, purified water, flower of the sun, cloth that dressed an old
--     wound). The bolt takes the lamb and only rods that have already drunk the deluge are made
--     Electrick (chargeWands -- mundane rods are passed over).
--   Each rite lists its corners in mapping.ritual (hydrationOfferings / electrickOfferings:
--   kind -> item-actor class).
--
-- While a storm rages, the host checks every `ritual_check_interval` seconds for either tableau:
-- the rite's animal with >= `ritual_fences` fence pieces and >= `ritual_candles` candles (any
-- state -- the storm's rain snuffs flames, so lit cannot be required) within `ritual_radius`
-- (20 m), plus that rite's corner items within `ritual_corner_radius` of the circle's candles.
-- When a rite is ready, the storm turns on the offering: the next bolts target it. On impact the
-- animal AND the corner items are consumed, every candle bursts alight (Burning + OnRep_Burning,
-- native replication), and the rite's payout runs for every player inside the circle.
--
-- MP: everything here is host-side; the bolt, the animal's demise, the vanishing offerings and
-- the candle flames all ride native replication. The check is a chain of one-shot delays alive
-- only during storms -- never a free-running UObject timer (those native-crash on level
-- transitions).
local F = {}
local ctx

local stormOn   = false
local token     = 0        -- bumped when the storm state flips; stale delays self-cancel
local announced = false    -- "the pentagram hums" fires once per readiness
local striking  = false    -- a ritual bolt is in flight
local lastLack  = nil      -- last "the corners lack ..." message (log only on change, not per tick)
local pendingRite, pendingAnimal, pendingLoc     -- the rite + offering the in-flight bolt is aimed at
local pendingOfferings, pendingCandles           -- corner items to consume + candles to light on impact

-- Friendly names for the corner offerings (log flavor).
local OFFERING_NAMES = {
  water     = "water clear of impurities",
  honey     = "comb of the honeybee",
  leaf      = "leaf of the trees",
  clay      = "clay of the earth",
  berry     = "a berry nourished by the sun",
  copper    = "rounded refined copper",
  ironore   = "raw iron ore",
  purewater = "purified water",
  flower    = "flower of the sun",
  cloth     = "cloth that dressed an old wound",
}

-- The two rites, in ladder order (checked top-down; the first full tableau takes the bolt).
-- Each wants ONE of each of its five offering kinds (mapping.ritual[offeringsKey]: kind ->
-- item-actor class) resting by the circle's candles.
local RITES = {
  { key = "hydration", animalKey = "chickenClass", animalName = "the bird",
    offeringsKey = "hydrationOfferings", payout = "hydrateWands",
    accepted = "*** the sacrifice is accepted -- the bird and the five offerings (%d) are no"
             .. " more; %d candles burst alight around the pentagram ***" },
  { key = "electrick", animalKey = "sheepClass", animalName = "the lamb",
    offeringsKey = "electrickOfferings", payout = "chargeWands",
    accepted = "*** the sacrifice is accepted -- the lamb and the five offerings (%d) are no"
             .. " more; %d candles burst alight around the pentagram ***" },
}

local function riteOfferingMap(rite)
  return (ctx.map.ritual and ctx.map.ritual[rite.offeringsKey]) or {}
end

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

-- One guarded world scan shared by both rites: fences, candles, and every dropped offering-kind
-- item actor. The candle match excludes "_Item" classes: a candle still in item form on the
-- ground is no pentagram point (and would otherwise be double-counted against the offerings).
local function scanWorld()
  local wanted = {}   -- item-actor class name -> true (union of BOTH rites' corner classes;
                      -- riteCorners re-matches per rite, so one class may serve either rite)
  for _, rite in ipairs(RITES) do
    for _, cn in pairs(riteOfferingMap(rite)) do wanted[cn] = true end
  end
  local fences, candles, offerings = {}, {}, {}
  for _, a in ipairs(ctx.uehelp.findAll("Actor")) do
    local cls = ctx.uehelp.className(a)
    if cls then
      if wanted[cls] then
        offerings[#offerings + 1] = { cls = cls, actor = a }
      elseif cls:find("Fence", 1, true) then
        fences[#fences + 1] = a
      elseif cls:find("Candle", 1, true) and not cls:find("Preview", 1, true)
          and not cls:find("_Item", 1, true) then
        candles[#candles + 1] = a
      end
    end
  end
  return fences, candles, offerings
end

-- Fence/candle circle around a location, or nil if the pentagram doesn't stand there.
local function circleAround(sl, fences, candles)
  local r2 = ctx.config.get("ritual_radius") ^ 2
  local nf = 0
  for _, f in ipairs(fences) do
    local fl = ctx.identity.locationOf(f)
    if fl and ctx.uehelp.dist2(fl, sl) <= r2 then nf = nf + 1 end
  end
  if nf < ctx.config.get("ritual_fences") then return nil end
  local circle = {}
  for _, cd in ipairs(candles) do
    local cl = ctx.identity.locationOf(cd)
    if cl and ctx.uehelp.dist2(cl, sl) <= r2 then circle[#circle + 1] = cd end
  end
  if #circle < ctx.config.get("ritual_candles") then return nil end
  return nf, circle
end

-- Is this offering actor resting by one of the circle's candles?
local function byACandle(ol, circle, cr2)
  for _, cd in ipairs(circle) do
    local cl = ctx.identity.locationOf(cd)
    if cl and ctx.uehelp.dist2(cl, ol) <= cr2 then return true end
  end
  return false
end

-- The corner items for a rite -- one of each of ITS five kinds, each resting by a candle of the
-- circle -- or nil + a "lacking" whisper string. Returns a list of world actors to consume on
-- impact. A single dropped item can only stand for one kind (`used` guards double-claiming when
-- two kinds map to the same class across rites).
local function riteCorners(rite, sl, circle, offerings)
  local r2 = ctx.config.get("ritual_radius") ^ 2
  local cr2 = ctx.config.get("ritual_corner_radius") ^ 2
  local classFor = riteOfferingMap(rite)
  local chosen, used = {}, {}
  for kind, cn in pairs(classFor) do
    for _, o in ipairs(offerings) do
      if o.cls == cn and not used[o.actor] and ctx.uehelp.isValid(o.actor) then
        local ol = ctx.identity.locationOf(o.actor)
        if ol and ctx.uehelp.dist2(ol, sl) <= r2 and byACandle(ol, circle, cr2) then
          chosen[kind] = o.actor
          used[o.actor] = true
          break
        end
      end
    end
  end
  local list, missing = {}, {}
  for kind in pairs(classFor) do
    if chosen[kind] then list[#list + 1] = chosen[kind]
    else missing[#missing + 1] = OFFERING_NAMES[kind] or kind end
  end
  if #missing == 0 then return list end
  table.sort(missing)
  return nil, "the pentagram stands, but the corners lack: " .. table.concat(missing, ", ")
end

-- The first rite whose full tableau stands, with everything the impact needs. Also whispers
-- (once per change) what an otherwise-standing pentagram still lacks.
local function findReadyRite()
  local fences, candles, offerings = scanWorld()
  local lack
  for _, rite in ipairs(RITES) do
    local cls = ctx.map.animal and ctx.map.animal[rite.animalKey]
    if cls then
      for _, animal in ipairs(ctx.uehelp.findAll(cls)) do
        if ctx.uehelp.isValid(animal) then
          local sl = ctx.identity.locationOf(animal)
          if sl then
            local nf, circle = circleAround(sl, fences, candles)
            if nf then
              local items, why = riteCorners(rite, sl, circle, offerings)
              if items then
                lastLack = nil
                return rite, animal, sl, nf, #circle, circle, items
              end
              lack = lack or why
            end
          end
        end
      end
    end
  end
  if lack and lack ~= lastLack then
    lastLack = lack
    ctx.log.info(lack)
  end
  return nil
end

--------------------------------------------------------------------- the rite
local function performSacrifice(rite, animal, loc, offerings, candles)
  -- the bolt itself (VFX + thunder + radius damage) is delivered by storms.strikeAt
  if ctx.uehelp.isValid(animal) then pcall(function() animal:K2_DestroyActor() end) end
  -- the corner items are consumed with the offering (destroy replicates natively)
  local eaten = 0
  for _, a in pairs(offerings or {}) do
    if ctx.uehelp.isValid(a) then
      pcall(function() a:K2_DestroyActor() end)
      eaten = eaten + 1
    end
  end
  -- every candle of the pentagram bursts alight: set the replicated Burning bool, then run the
  -- OnRep on the host so flame + light + burn timer apply locally (clients get the rep notify)
  local lit = 0
  local rt = ctx.map.ritual
  for _, cd in ipairs(candles or {}) do
    if ctx.uehelp.isValid(cd) and rt.candleBurningProp
        and ctx.uehelp.set(cd, rt.candleBurningProp, true) then
      if rt.candleBurnRepFn then ctx.uehelp.call(cd, rt.candleBurnRepFn) end
      lit = lit + 1
    end
  end
  ctx.log.info(string.format(rite.accepted, eaten, lit))
  -- the wand feature owns the payout: hydrateWands quenches mundane rods (first rung),
  -- chargeWands wakes quenched rods into Electrick (second rung)
  local payout = ctx.services[rite.payout]
  if payout then
    payout(loc, ctx.config.get("ritual_radius"))
  else
    ctx.log.warn("ritual: wand feature disabled -- the bolt finds no vessel")
  end
  ctx.bus.emit("ritual.completed", { location = loc, rite = rite.key })
end

--------------------------------------------------------------------- storm-time check chain
local function checkChain(tok)
  if not stormOn or tok ~= token then return end
  afterIfStorm(ctx.config.get("ritual_check_interval"), tok, function()
    if ctx.net.isHost() and not striking then
      local rite, animal, loc, nf, nc, circle, items = findReadyRite()
      if rite and ctx.services.strikeAt then
        if not announced then
          announced = true
          ctx.log.info(string.format(
            "*** the pentagram hums (%d fences, %d candles, %s at the heart, the corners laid)"
            .. "... the storm has noticed ***", nf, nc, rite.animalName))
        end
        striking = true
        pendingRite, pendingAnimal, pendingLoc = rite, animal, loc
        pendingOfferings, pendingCandles = items, circle
        -- the sacrifice itself fires on the "lightning.strike" IMPACT event (see init), so the
        -- offering dies exactly on the bolt's big strike frame -- no parallel timer to race it.
        ctx.services.strikeAt(loc, "ritual")
      end
    end
    checkChain(tok)
  end)
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "ritual",
      { "animal.sheepClass", "pawn.class" }) then
    return false
  end
  ctx.bus.on("weather.changed", ctx.log.guard("ritual.weather", function(e)
    local now = e and e.storm or false
    if now == stormOn then return end
    stormOn = now
    token = token + 1
    announced, striking, lastLack = false, false, nil
    pendingRite, pendingAnimal, pendingLoc = nil, nil, nil
    pendingOfferings, pendingCandles = nil, nil
    if stormOn then checkChain(token) end
  end))

  -- The sacrifice lands WITH the bolt: storms emits "lightning.strike" at the big strike frame.
  -- A strike near the pending offering consumes it; a strike drawn elsewhere (a lightning rod
  -- grounding the rite) releases the latch so the chain simply tries again.
  ctx.bus.on("lightning.strike", ctx.log.guard("ritual.impact", function(e)
    if not (striking and pendingLoc and e and e.location) then return end
    if ctx.uehelp.dist2(e.location, pendingLoc) <= 400 * 400 then
      performSacrifice(pendingRite, pendingAnimal, pendingLoc, pendingOfferings, pendingCandles)
    else
      ctx.log.info("...the bolt was drawn away from the circle -- the rite holds (a rod nearby?)")
    end
    striking, pendingRite, pendingAnimal, pendingLoc = false, nil, nil, nil
    pendingOfferings, pendingCandles = nil, nil
  end))
  ctx.log.info("ritual: the dark arts are listening -- two rites: the bird + its five offerings"
    .. " -> the Hydration Wand; the lamb + its five -> the Electrick Wand (in a storm)")
  return true
end

return F
