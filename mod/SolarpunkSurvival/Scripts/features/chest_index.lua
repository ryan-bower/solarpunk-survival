-- The chest stock ledger: a demand-driven, memoized "how much of class X is in chest Y" cache
-- shared by the auto-sort chest and the crafting auto-pull. NOT a contents mirror -- full-chest
-- enumeration is impossible from Lua anyway (slot structs in the Inventory ARRAY are the proven
-- VM-wedge); every fact here comes from the inventory component's own query functions, probed
-- with slot structs we BUILD (the trash-slot-proven marshal direction).
--
-- Design rules:
--   * zero timers of its own -- consumers pay for every lookup; an idle ledger costs nothing
--   * actor handles are re-found and isValid'd at every use, never trusted across a pass
--   * ALL state resets when the local controller's fullname changes (UE recycles object names
--     across worlds -- a cache keyed by fullname would hand a fresh chest a dead chest's counts)
--   * per-(chest, class) amounts carry a TTL; our OWN moves patch both sides immediately
local F = {}
local ctx

local reg = {}        -- chestKey -> { cls = className, loc = {x,y,z}, seenAt }
local counts = {}     -- chestKey -> { [clsKey] = { amt, at } }
local lastSweepAt = 0
local worldPc = nil   -- the controller fullname this state belongs to

local function smap() return ctx.map.stock or {} end
local function cfgn(k, d) return tonumber(ctx.config.get(k)) or d end

local function onGameThread(fn)
  if ExecuteInGameThread and pcall(ExecuteInGameThread, fn) then return end
  pcall(fn)
end

local function unwrap(v)
  if type(v) == "userdata" then pcall(function() local g = v:get() v = g end) end
  return v
end

-- The probe struct every count/space query passes in (S_InventorySlotSlim, wand's field GUIDs).
local function probeFor(cls, qty)
  local w = ctx.map.wand or {}
  return {
    [w.slotItemField or "Item"] = cls,
    [w.slotQtyField or "Quantity"] = qty or 0,
    [w.slotSavedataField or "AdditionalSavedata"] = "",
  }
end
F.probeFor = probeFor  -- sort/pull build their move payloads with the same shape

-- Class wrappers from DB_Items fail every direct method call yet marshal fine as arguments
-- (the trash lesson). Key them by tostring of a GetFullName attempt, falling back to address.
local function clsKey(cls)
  local n
  pcall(function() n = cls:GetFullName() end)
  return n or tostring(cls)
end

local function worldChanged()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if pcNow and pcNow ~= worldPc then
    worldPc = pcNow
    reg, counts, lastSweepAt = {}, {}, 0
    return true
  end
  return false
end

-- Sweep the world's chests into the registry (lazy: at most once per chest_index_sweep secs,
-- and only when a consumer actually asks).
local function sweep()
  worldChanged()
  local now = os.clock()
  if now - lastSweepAt < cfgn("chest_index_sweep", 20.0) then return end
  lastSweepAt = now
  local u = ctx.uehelp
  local live = {}
  for _, cn in ipairs(smap().chestClasses or {}) do
    for _, c in ipairs(u.findAll(cn)) do
      local full
      pcall(function() full = c:GetFullName() end)
      if u.isValid(c) and full and not full:find("Default__") then
        local loc = ctx.identity.locationOf(c)
        if loc then
          live[full] = true
          -- a chest that RIDES something (the ship's storage: attached, or Lua-carried with
          -- movement replication forced off) can be kilometres from its cached spot within
          -- one sweep period -- mark it so range tests re-read the live actor (the ledger
          -- once kept feeding a flying ship's stores to the crafting stations below)
          local mobile = false
          pcall(function()
            local parent = c:GetAttachParentActor()
            if u.isValid(parent) then mobile = true end
          end)
          if not mobile then
            local okR, repMove = u.get(c, "bReplicateMovement")
            local okB, reps = u.get(c, "bReplicates")
            if okR and okB and reps == true and repMove == false then mobile = true end
          end
          local e = reg[full]
          if not e then
            reg[full] = { cls = cn, loc = loc, seenAt = now, mobile = mobile }
          else
            e.loc, e.seenAt, e.mobile = loc, now, mobile
          end
        end
      end
    end
  end
  for k in pairs(reg) do
    if not live[k] then reg[k], counts[k] = nil, nil end -- demolished / unstreamed
  end
end

-- Re-find a registry entry's live actor (never cache the handle itself).
local function actorOf(key, e)
  local u = ctx.uehelp
  for _, c in ipairs(u.findAll(e.cls)) do
    local full
    pcall(function() full = c:GetFullName() end)
    if full == key and u.isValid(c) then return c end
  end
  return nil
end

-- The chest's inventory component, class-checked -- handing a game BP call a wrong-class
-- object is a fatal assert, not a Lua error (the ship_chest lesson). The property NAME varies
-- by donor BP (the vanilla chest calls it InventorySystem, the furnace -- and so our sorting
-- chest clone -- BC_InventorySystem), so every candidate in invProp + invPropAlts is tried.
local function invOf(chest)
  local m = smap()
  local names = { m.invProp }
  for _, alt in ipairs(m.invPropAlts or {}) do names[#names + 1] = alt end
  for _, prop in ipairs(names) do
    local okI, inv = ctx.uehelp.get(chest, prop)
    if okI and ctx.uehelp.isValid(inv) then
      local cn
      pcall(function() cn = inv:GetClass():GetFName():ToString() end)
      if not m.invSysClass or cn == m.invSysClass then return inv end
    end
  end
  return nil
end
F.invOf = invOf

-- A registry entry's location RIGHT NOW: cached for static placeables, re-read off the live
-- actor for mobile ones (the ship chest moves between sweeps). Updates the cache as a side
-- effect; nil when the actor cannot be found.
local function liveLocOf(key, e)
  if not e.mobile then return e.loc end
  local c = actorOf(key, e)
  if not c then return nil end
  local loc = ctx.identity.locationOf(c)
  if loc then e.loc = loc end
  return loc or e.loc
end

-- Chests within sqrt(r2) of `loc`, nearest first: { key, entry, d2 } triples. `exceptKey`
-- lets the sorter exclude itself. Mobile entries are measured at their LIVE position -- a
-- chest that just flew away on the airship is out of range NOW, not in 20 s.
local function chestsNear(loc, r2, exceptKey)
  sweep()
  local out = {}
  for k, e in pairs(reg) do
    if k ~= exceptKey then
      local at = liveLocOf(k, e)
      local d2 = at and ctx.uehelp.dist2(at, loc)
      if d2 and d2 <= r2 then out[#out + 1] = { key = k, entry = e, d2 = d2 } end
    end
  end
  table.sort(out, function(a, b) return a.d2 < b.d2 end)
  return out
end

-- Cached per-(chest, class) amount; miss/expiry costs one live GetAmtOfItem.
local function amtIn(key, e, cls)
  local ck = clsKey(cls)
  local c = counts[key]
  local hit = c and c[ck]
  if hit and os.clock() - hit.at < cfgn("chest_index_ttl", 20.0) then return hit.amt end
  local chest = actorOf(key, e)
  local inv = chest and invOf(chest)
  if not inv then return 0 end
  local out = {}
  if not ctx.uehelp.call(inv, smap().amtFn, probeFor(cls), out) then return 0 end
  local amt = tonumber(unwrap(out.Amount)) or 0
  counts[key] = counts[key] or {}
  counts[key][ck] = { amt = amt, at = os.clock() }
  return amt
end

-- Always-live stacking headroom (it gates actual moves; never cached).
local function freeFor(inv, cls)
  local out = {}
  if not ctx.uehelp.call(inv, smap().freeFn, probeFor(cls), out) then return 0 end
  return tonumber(unwrap(out.FreeStackingSpace)) or 0
end

-- Our own transfer just moved `delta` of cls into (positive) or out of (negative) chestKey.
-- Patch the amount but DELIBERATELY leave `at` alone: the timestamp measures how long ago we
-- last saw the chest for real, and our own move teaches us nothing about the deposits we
-- cannot see (a hand drop, a teammate's dump). Re-stamping here let a cached zero blind the
-- ledger to a chest someone had just filled, for a fresh full TTL after every mod-driven pull.
local function noteMove(key, cls, delta)
  local ck = clsKey(cls)
  local hit = counts[key] and counts[key][ck]
  if hit then
    hit.amt = math.max(0, hit.amt + delta)
  end
end

local function invalidate(key)
  counts[key] = nil
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "chest_index",
      { "stock.chestClasses", "stock.invProp", "stock.amtFn" }) then
    return false
  end
  ctx.services.chestIndex = {
    sweep = sweep,
    chestsNear = chestsNear,
    actorOf = actorOf,
    invOf = invOf,
    amtIn = amtIn,
    freeFor = freeFor,
    probeFor = probeFor,
    noteMove = noteMove,
    invalidate = invalidate,
    liveLocOf = liveLocOf,
  }
  -- new chests join the registry as they stream/build in; the notify only voids the sweep
  -- timestamp (plain Lua) so the NEXT consumer pass picks them up on the game thread
  for _, cn in ipairs(smap().chestClasses or {}) do
    pcall(function()
      ctx.uehelp.onNewInstance("/Script/Engine.Actor", cn, function()
        lastSweepAt = 0
      end)
    end)
  end
  ctx.log.info("chest_index: stock ledger ready (" ..
    tostring(#(smap().chestClasses or {})) .. " chest classes)")
  return true
end

return F
