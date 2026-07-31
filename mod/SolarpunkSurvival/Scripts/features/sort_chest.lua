-- The blue SORTING CHEST: a powered chest (pak clone of BP_EnergyFurnace_Placeable -- it ships
-- with inventory + cable connector + energy device wired) that files its contents into nearby
-- chests. Drop items in; every pass it picks the next chest within sort_chest_range and calls
-- the game's own Quick Stack on it -- dstInv:QuickStack(sorterInv) pulls over exactly the item
-- classes that chest ALREADY holds (bytecode-verified), which is the user's sorting rule
-- verbatim. Items no nearby chest wants simply stay put; there is no fallback scatter.
--
-- Power: the clone's device component draws sort_chest_power_active (as NEGATIVE
-- CurPowerConsumption, the engine's sign convention) while it holds items, idling at
-- sort_chest_power_idle when empty. Sorting itself only proceeds while the network says
-- EnoughPower -- cutting the cable pauses mid-pile and resumes on re-power.
--
-- Interact: the clone's OnInteractedWith trampoline is STUBBED at cook time (natively E does
-- nothing), but the delegate still broadcasts through ProcessEvent, so the hook below fires and
-- opens the plain chest UI itself -- the codex-proven pattern; no furnace widget ever appears.
-- Sorting itself is host-only, like every inventory-writing feature here.
local F = {}
local ctx

local chainTok = 0      -- orphans stale sort chains
local chainLive = false
local dryPasses = 0     -- consecutive passes with no live sorter -> chain stops
local rr = {}           -- sorterKey -> round-robin cursor over its target chests
local hooked = {}       -- interact-redirect hook registry

local function smap() return ctx.map.sortchest or {} end
local function stmap() return ctx.map.stock or {} end
local function cfgn(k, d) return tonumber(ctx.config.get(k)) or d end

local function onGameThread(fn)
  if ExecuteInGameThread and pcall(ExecuteInGameThread, fn) then return end
  pcall(fn)
end

local function deferOnly(ms, fn)
  pcall(ExecuteWithDelay, ms, fn)
end

local function unwrap(v)
  if type(v) == "userdata" then pcall(function() local g = v:get() v = g end) end
  return v
end

local function svc() return ctx.services.chestIndex end

local function liveSorters()
  local u = ctx.uehelp
  local out = {}
  for _, s in ipairs(u.findAll(smap().class)) do
    local full
    pcall(function() full = s:GetFullName() end)
    if u.isValid(s) and full and not full:find("Default__") then
      out[#out + 1] = { actor = s, key = full }
    end
  end
  return out
end

local function deviceOf(sorter)
  local out = {}
  if not ctx.uehelp.call(sorter, smap().deviceGetFn, out) then return nil end
  local v = rawget(out, 1)
  if v == nil then local _, first = next(out) v = first end
  v = unwrap(v)
  return ctx.uehelp.isValid(v) and v or nil
end

local function hasPower(dev)
  local out = {}
  if not ctx.uehelp.call(dev, smap().hasPowerFn, out) then return nil end
  local v = rawget(out, 1)
  if v == nil then local _, first = next(out) v = first end
  return unwrap(v) == true
end

local function totalIn(inv)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().totalFn, out) then return 0 end
  return tonumber(unwrap(out.TotalItems)) or 0
end

-- One sorter, one pass: set the draw, and if powered + loaded, Quick Stack into the next
-- nearby chest on the rotation.
local function sortPass(s)
  local ledger = svc()
  if not ledger then return end
  local inv = ledger.invOf(s.actor)
  if not inv then return end
  local dev = deviceOf(s.actor)
  local total = totalIn(inv)
  local wantsToSort = total > 0
  if dev then
    -- the draw states the chest's intent: loaded = working wattage even while the network
    -- can't feed it (that shortfall is exactly what keeps EnoughPower false); empty = idle
    ctx.uehelp.set(dev, smap().consumptionProp,
      -(wantsToSort and cfgn("sort_chest_power_active", 500.0)
                     or cfgn("sort_chest_power_idle", 100.0)))
  end
  if not wantsToSort then rr[s.key] = nil return end
  if dev and hasPower(dev) ~= true then return end -- unpowered: pause, keep re-checking
  local loc = ctx.identity.locationOf(s.actor)
  if not loc then return end
  local r = cfgn("sort_chest_range", 5000.0)
  local targets = {}
  for _, t in ipairs(ledger.chestsNear(loc, r * r, s.key)) do
    -- only PLAIN chests receive; two sorters must never ping-pong a pile between them
    if t.entry.cls ~= smap().class then targets[#targets + 1] = t end
  end
  if #targets == 0 then return end
  local idx = ((rr[s.key] or 0) % #targets) + 1
  rr[s.key] = idx
  local t = targets[idx]
  local chest = ledger.actorOf(t.key, t.entry)
  local dstInv = chest and ledger.invOf(chest)
  if not dstInv then return end
  local before = totalIn(inv)
  if ctx.uehelp.call(dstInv, stmap().quickStackFn, inv, {}) then
    local moved = before - totalIn(inv)
    if moved > 0 then
      ledger.invalidate(t.key)
      ledger.invalidate(s.key)
      ctx.log.info(string.format("sort_chest: filed %d item(s) into a chest %dm away",
        moved, math.floor(math.sqrt(t.d2) / 100)))
    end
  end
end

-- Put every live sorter back on the idle draw. Used when the feature is switched off at
-- runtime: the last pass may have left a loaded chest asking the network for the working
-- wattage, and nothing else would ever write that property again.
local function releaseDraw()
  for _, s in ipairs(liveSorters()) do
    local dev = deviceOf(s.actor)
    if dev then
      ctx.uehelp.set(dev, smap().consumptionProp, -cfgn("sort_chest_power_idle", 100.0))
    end
  end
  rr = {}
end

local function startChain()
  if chainLive then return end
  chainLive = true
  dryPasses = 0
  chainTok = chainTok + 1
  local tok = chainTok
  local paused = false
  local function pass()
    if tok ~= chainTok then return end
    if not ctx.config.get("sort_chest") then
      -- switched off at runtime: PARK, do not die. Nothing watches the config for it coming
      -- back (startChain is only reached from a world entry, a sorter spawn, init, or
      -- sps_sort), so a pass that returned here left the blue chest inert -- and stranded
      -- whatever draw it last wrote -- until the player reloaded the world.
      if not paused then
        paused = true
        if ctx.net.isHost() then pcall(releaseDraw) end
        ctx.log.info("sort_chest: switched off -- parked, draw released")
      end
      deferOnly(math.floor(cfgn("sort_chest_tick", 1.5) * 4000),
        function() onGameThread(pass) end)
      return
    end
    if paused then
      paused = false
      ctx.log.info("sort_chest: switched back on -- sorting resumes")
    end
    local sorters = ctx.net.isHost() and liveSorters() or {}
    if #sorters == 0 then
      dryPasses = dryPasses + 1
      if dryPasses >= 3 then chainLive = false return end -- notify/world-entry re-arms
    else
      dryPasses = 0
      for _, s in ipairs(sorters) do
        pcall(sortPass, s)
      end
    end
    deferOnly(math.floor(cfgn("sort_chest_tick", 1.5) * 1000),
      function() onGameThread(pass) end)
  end
  deferOnly(0, function() onGameThread(pass) end)
end

--------------------------------------------------------------------- interact hook
-- Did the LOCAL CONTROLLER change? That -- not "a Character was constructed" -- is the real
-- "new world, the class hooks died" signal.
local hookWorldPc = nil
local function worldChanged()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if pcNow and pcNow ~= hookWorldPc then
    hookWorldPc = pcNow
    return true
  end
  return false
end

-- Codex pattern: find the clone class's OnInteractedWith event(s) and hook them. The event body
-- is a cook-time stub, so the game does nothing on E; we open the chest UI for the local
-- interactor. Callback signature per BPC_InteractableLogic's delegate:
-- (Context = the placeable, comp, hit, controller, tool).

local function armInteractHook()
  if hooked.interact then return end
  local u, m = ctx.uehelp, smap()
  local chestFn = ctx.map.qol and ctx.map.qol.openChestUiFn
  if not chestFn then return end
  local cls = u.classByName(m.class, m.placeablePath)
  if not cls then return end -- no sorting chest loaded yet; a spawn notify re-arms
  local paths = {}
  pcall(function()
    cls:ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n:find(m.interactFnHint or "OnInteractedWith", 1, true) then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  for _, path in ipairs(paths) do
    local ok = pcall(RegisterHook, path,
      ctx.log.guard("sortchest.interact", function(Context, comp, hit, controller, tool)
        local actor, pc
        pcall(function() actor = Context:get() end)
        pcall(function() pc = controller:get() end)
        -- real work OUT of the hook call chain, and only for the LOCAL interactor (on the host
        -- the event also fires for remote players -- their UI is not ours to open)
        deferOnly(0, function()
          onGameThread(function()
            if not ctx.uehelp.isValid(actor) then return end
            local localPc = ctx.uehelp.localController(
              ctx.map.player and ctx.map.player.controllerClass)
            if ctx.uehelp.isValid(pc) and not ctx.uehelp.sameObject(pc, localPc) then return end
            local ledger = svc()
            local inv = ledger and ledger.invOf(actor)
            if not inv then
              -- E reached us but the inventory component is unreadable -- say so, a silent
              -- return here reads as "the chest is broken" in-game (the invProp-name lesson)
              ctx.log.warn("sort_chest: interact fired but no inventory on the sorter"
                .. " (invProp/invPropAlts miss?)")
              return
            end
            if localPc then ctx.uehelp.call(localPc, chestFn, inv) end
          end)
        end)
      end))
    if ok then
      hooked.interact = true
      ctx.log.debug("sort_chest: interact hook armed (" .. path .. ")")
    end
  end
end

function F.init(c)
  ctx = c
  if not ctx.config.get("sort_chest") then
    ctx.log.info("sort_chest: disabled by config")
    return F
  end
  if not ctx.gate.require(ctx.log, ctx.map, "sort_chest",
      { "sortchest.class", "stock.quickStackFn", "stock.totalFn" }) then
    return false
  end

  -- world entry + sorter spawn both (re)arm the chain and the interact hook; the chain is
  -- guarded by startChain's own latch, the hook by the registry below
  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, function()
        onGameThread(function()
          -- This notify fires for EVERY Character constructed -- respawns and remote players
          -- joining, not only world loads. OnInteractedWith is hooked on the CLASS function
          -- path, which survives a respawn, so clearing the registry unconditionally stacked
          -- a second live registration each time and opened the chest UI once per copy.
          if worldChanged() then hooked = {} end
          armInteractHook()
          startChain()
        end)
      end)
    end)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", smap().class, function()
    -- first sorter ever placed/streamed: the class is finally resolvable -> hook now
    deferOnly(1000, function() onGameThread(function() armInteractHook() startChain() end) end)
  end)
  deferOnly(2000, function() onGameThread(function() armInteractHook() startChain() end) end)

  pcall(function()
    RegisterConsoleCommandHandler("sps_sort", function()
      onGameThread(function()
        local sorters = liveSorters()
        ctx.log.info(string.format("sort_chest: %d sorter(s), chain %s",
          #sorters, chainLive and "running" or "parked"))
        startChain()
      end)
      return true
    end)
  end)

  ctx.log.info("sort_chest: the blue chest files into neighbors within " ..
    tostring(cfgn("sort_chest_range", 5000.0) / 100) .. " m (needs cable power)")
  return F
end

return F
