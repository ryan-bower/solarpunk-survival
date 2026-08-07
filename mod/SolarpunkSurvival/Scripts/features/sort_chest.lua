-- The blue SORTING CHEST: a powered chest (pak clone of BP_EnergyFurnace_Placeable -- it ships
-- with inventory + cable connector + energy device wired) that files its contents into nearby
-- chests. Drop items in; a loaded, powered sorter sweeps EVERY chest within sort_chest_range
-- closest-first in one pass, calling the game's own Quick Stack on each --
-- dstInv:QuickStack(sorterInv) pulls over exactly the item classes that chest ALREADY holds
-- (bytecode-verified), which is the user's sorting rule verbatim. Items no nearby chest wants
-- simply stay put; there is no fallback scatter. A sweep that moves NOTHING settles the sorter:
-- it then only re-sweeps every SETTLE_PASSES ticks (or the moment its item count changes),
-- because QuickStack saves both inventories even on a no-op -- hammering every neighbor each
-- tick forever is pure churn.
--
-- Power: the clone's device component draws sort_chest_power_active (as NEGATIVE
-- CurPowerConsumption, the engine's sign convention) while it holds items, idling at
-- sort_chest_power_idle when empty. Sorting only proceeds while the network says EnoughPower --
-- cutting the cable pauses mid-pile and resumes on re-power -- and an UNREADABLE device also
-- pauses it: "only work when powered" must fail closed, not free-run (warned once per sorter).
-- While the local player is browsing the sorter's own inventory the pass skips it -- the game
-- never mutates a chest mid-view, and neither do we.
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
local st = {}           -- sorterKey -> { total = count when settled, cool = passes to skip }
local blindWarned = {}  -- sorterKey -> true after the unreadable-device warn
local hooked = {}       -- interact-redirect hook registry

-- Passes a settled sorter waits before re-sweeping (a neighbor may have GAINED a matching
-- item since). At the 1.5 s default tick this is ~30 s between retries of a stuck pile.
local SETTLE_PASSES = 20

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
  -- Property read FIRST: GetEnergyComponent is just `Component = BPC_Device_...` (bytecode),
  -- but OBJECT out-params never come back through the reflected-call table on this build
  -- (rig 2026-08-06: call ok=true, out table empty -- scalar outs fill fine, objects don't).
  local ok, c = ctx.uehelp.get(sorter, smap().deviceProp or "BPC_Device_EnergySystemComponent")
  if ok and ctx.uehelp.isValid(c) then return c end
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

-- Is the LOCAL chest UI currently showing this inventory? Reuses the qol mapping's widget
-- names with the same literal fallbacks qol itself uses. Fail-open: any read error counts as
-- "not open" -- worst case the guard is inert, which is exactly today's behavior.
local function uiBrowsing(inv)
  local qm = ctx.map.qol or {}
  local open = false
  pcall(function()
    for _, w in ipairs(FindAllOf(qm.chestUiClass or "W_ChestInventory_C") or {}) do
      local full = w:GetFullName()
      if full and full:find("Transient", 1, true) and w:IsVisible()
         and ctx.uehelp.sameObject(w[qm.chestUiInvRefProp or "ChestInventoryRef"], inv) then
        open = true
      end
    end
  end)
  return open
end

--------------------------------------------------------------- non-stackables
-- Quick Stack cannot file these: BOTH its phases are bytecode-gated on MaxStackSize > 1
-- (BC_InventorySystem decoded 2026-08-06 -- the user's weather station stayed in the sorter).
-- They move with the game's own whole-slot MoveItemDiffInv instead, the buffer-shuffle-proven
-- call, so savedata (durability etc.) rides along. The sorter's slots can never be READ from
-- Lua (struct-array poison), so which non-stackables it holds is discovered by bisecting
-- candidate classes through "Contains one Of Given Items" -- ~log2(N) calls per held class,
-- one single call when it holds none. WHICH classes are non-stackable is baked offline from
-- DB_Items (tools/pakkit/gen_nonstackables.py) because stack sizes live in row structs Lua
-- must not touch at runtime.
local NONSTACK = require("data.nonstackables")   -- class NAME -> full asset path

-- Candidate class wrappers come from the game's own DB_Items map keys, fetched FRESH on
-- every discovery, filtered by the baked name set -- the trash-slot-proven wrapper source
-- for array marshals. Never from bulk classByName: 238 short-name resolves held in a table
-- proved to be a stale-pointer lottery (rig 2026-08-06 -- Contains(full)=true while
-- Contains(either half)=false, and a GetAmtOfItem sweep through the same wrappers finding
-- NOTHING in an inventory provably holding two weather stations).
local function nonstackCandidates()
  local out = {}
  local tm = ctx.map.trash or {}
  local gi = tm.giClass and ctx.uehelp.findFirst(tm.giClass)
  if not (gi and tm.dbItemsProp) then return out end
  pcall(function()
    local db = gi[tm.dbItemsProp]
    if db and db.ForEach then
      db:ForEach(function(k, _)
        local cls = k
        pcall(function() cls = k:get() end)
        if cls ~= nil then
          local nm
          pcall(function() nm = cls:GetFName():ToString() end)
          if nm and NONSTACK[nm] then out[#out + 1] = { cls = cls, name = nm } end
        end
      end)
    end
  end)
  return out
end

local function containsAny(inv, entries)
  local arr = {}
  for i, e in ipairs(entries) do arr[i] = e.cls end
  local out = {}
  if not ctx.uehelp.call(inv, stmap().containsAnyFn, arr, out) then return false end
  return unwrap(out.Contains) == true
end

-- Bisect `entries` down to the ones `inv` actually holds (at most `cap` of them).
local function heldNonstack(inv, entries, cap, found)
  found = found or {}
  if #found >= cap or #entries == 0 then return found end
  if not containsAny(inv, entries) then return found end
  if #entries == 1 then
    found[#found + 1] = entries[1]
    return found
  end
  local mid = math.floor(#entries / 2)
  local left, right = {}, {}
  for i = 1, mid do left[i] = entries[i] end
  for i = mid + 1, #entries do right[i - mid] = entries[i] end
  heldNonstack(inv, left, cap, found)
  heldNonstack(inv, right, cap, found)
  return found
end

local function amtOf(ledger, inv, cls)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().amtFn, ledger.probeFor(cls), out) then return 0 end
  return math.floor(tonumber(unwrap(out.Amount)) or 0)
end

local function freeSlotsIn(inv)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().freeSlotsFn, out) then return 0 end
  local v = unwrap(out.FreeSlots)
  if v == nil then local _, first = next(out) v = unwrap(first) end
  return math.floor(tonumber(v) or 0)
end

-- File the sorter's non-stackables into chests that already hold that class. The receiving
-- chest is compacted with the game's own Sort first, so its free slots are the TAIL and the
-- first empty index is pure arithmetic (len - free) -- no slot struct is ever read, and
-- MoveItemDiffInv only ever targets a provably EMPTY slot. Every move is verified by a
-- recount; a move that lands nothing stops the loop cold (no churn, no repeats).
local function fileNonstackables(s, inv, ledger, targets)
  local cands = nonstackCandidates()
  if #cands == 0 then return 0 end
  local held = heldNonstack(inv, cands, 4)
  ctx.log.debug("sort_chest: non-stackable discovery held " .. #held .. " class(es)")
  if #held == 0 then return 0 end
  local movedTotal, fed = 0, 0
  local budget = 12                       -- whole-slot moves per pass; the next pass continues
  for _, h in ipairs(held) do
    -- the db-key wrapper stays in the Contains arrays (its proven marshal role); every
    -- STRUCT probe below gets a fresh, path-exact wrapper resolved right before use
    local cls = ctx.uehelp.classByName(h.name, NONSTACK[h.name])
    local amt = cls and amtOf(ledger, inv, cls) or 0
    for _, t in ipairs(targets) do
      if amt <= 0 or budget <= 0 then break end
      if t.entry.cls ~= smap().class then  -- sorters never feed each other
        local chest = ledger.actorOf(t.key, t.entry)
        local dstInv = chest and ledger.invOf(chest)
        if dstInv and not uiBrowsing(dstInv)
            and ledger.amtIn(t.key, t.entry, cls) > 0 then
          local free = freeSlotsIn(dstInv)
          if free > 0 and ctx.uehelp.call(dstInv, stmap().sortFn, 0) == true then
            local len = 0
            pcall(function() len = #dstInv.Inventory end)   -- length-only read: safe
            local dstIdx = len - free
            local before = amt
            while amt > 0 and free > 0 and budget > 0 and dstIdx >= 0 and dstIdx < len do
              local out = {}
              if not ctx.uehelp.call(inv, stmap().firstIdxFn,
                  ledger.probeFor(cls), out, {}) then break end
              if unwrap(out.ContainsItem) ~= true then break end
              local srcIdx = math.floor(tonumber(unwrap(out.Index)) or -1)
              if srcIdx < 0 then break end
              if not ctx.uehelp.call(inv, stmap().moveDiffFn,
                  dstInv, srcIdx, math.floor(dstIdx)) then break end
              local now = amtOf(ledger, inv, cls)
              if now >= amt then break end       -- nothing landed: stop, never spin
              movedTotal = movedTotal + (amt - now)
              amt = now
              free = free - 1
              dstIdx = dstIdx + 1
              budget = budget - 1
            end
            if amt < before then
              fed = fed + 1
              ledger.invalidate(t.key)
            end
          end
        end
      end
    end
  end
  if movedTotal > 0 then
    ledger.invalidate(s.key)
    ctx.log.info(string.format(
      "sort_chest: filed %d non-stackable item(s) into %d chest(s) (whole-slot moves)",
      movedTotal, fed))
  end
  return movedTotal
end

-- One sorter, one pass: set the draw, and if powered + loaded + unwatched, sweep every nearby
-- chest closest-first with Quick Stack until the pile is gone or no chest wants the rest.
local function sortPass(s)
  local ledger = svc()
  if not ledger then return end
  local inv = ledger.invOf(s.actor)
  if not inv then return end
  local dev = deviceOf(s.actor)
  local total = totalIn(inv)
  local wantsToSort = total > 0
  if dev then
    blindWarned[s.key] = nil
    -- the draw states the chest's intent: loaded = working wattage even while the network
    -- can't feed it (that shortfall is exactly what keeps EnoughPower false); empty = idle
    ctx.uehelp.set(dev, smap().consumptionProp,
      -(wantsToSort and cfgn("sort_chest_power_active", 500.0)
                     or cfgn("sort_chest_power_idle", 100.0)))
  end
  if not wantsToSort then st[s.key] = nil return end
  if not dev then
    -- power gate fails CLOSED: a sorter whose energy component cannot be read must pause,
    -- not sort for free ("it should only work when powered")
    if not blindWarned[s.key] then
      blindWarned[s.key] = true
      ctx.log.warn("sort_chest: energy device unreadable on a loaded sorter (" ..
        tostring(smap().deviceProp) .. "/" .. tostring(smap().deviceGetFn) ..
        " both missed) -- sorting paused")
    end
    return
  end
  if hasPower(dev) ~= true then return end -- unpowered: pause, keep re-checking
  if uiBrowsing(inv) then return end       -- player is looking inside; hands off till close
  local prev = st[s.key]
  if prev and prev.total == total and prev.cool > 0 then
    prev.cool = prev.cool - 1
    return
  end
  local loc = ctx.identity.locationOf(s.actor)
  if not loc then return end
  local r = cfgn("sort_chest_range", 5000.0)
  local moved, fed = 0, 0
  local targets = ledger.chestsNear(loc, r * r, s.key)
  for _, t in ipairs(targets) do
    -- only PLAIN chests receive; two sorters must never ping-pong a pile between them
    if t.entry.cls ~= smap().class then
      local chest = ledger.actorOf(t.key, t.entry)
      local dstInv = chest and ledger.invOf(chest)
      if dstInv then
        local before = totalIn(inv)
        if ctx.uehelp.call(dstInv, stmap().quickStackFn, inv, {}) then
          local after = totalIn(inv)
          if after < before then
            moved = moved + (before - after)
            fed = fed + 1
            ledger.invalidate(t.key)
            if after == 0 then break end
          end
        end
      end
    end
  end
  if moved > 0 then
    ledger.invalidate(s.key)
    ctx.log.info(string.format("sort_chest: filed %d item(s) into %d chest(s)", moved, fed))
  end
  -- what Quick Stack left behind may be non-stackables it refuses by design. Own pcall: the
  -- chain swallows sortPass errors whole (pcall at the pass loop), and a silent death here
  -- would read exactly like "the weather station just didn't move".
  if totalIn(inv) > 0 then
    local okNS, movedNS = pcall(fileNonstackables, s, inv, ledger, targets)
    if okNS then
      moved = moved + (movedNS or 0)
    else
      ctx.log.warn("sort_chest: non-stackable pass errored: " .. tostring(movedNS))
    end
  end
  local left = totalIn(inv)
  if left > 0 and moved == 0 then
    -- nothing in range wants what's left: keep it here (the user's rule) and settle down
    st[s.key] = { total = left, cool = SETTLE_PASSES }
  else
    st[s.key] = nil
  end
end

-- NO runtime wire-port dressing. The user's "no wire hookup port" (2026-08-06) is fixed in the
-- CONTENT PAK: build_wand_pak.py cooks a PortMesh StaticMeshComponent (SM_CableConnector,
-- no-collision, undersized) into the clone's SCS at the SNAP box spot. A first cut here
-- spawned a StaticMeshActor and K2_AttachToActor'd it on every sorter -- the attach/spawn
-- family this project has been killed by three times before (component rig, preview ghost,
-- copper topper), and it struck again: uncatchable native AV within a second of the first
-- pass (rig 2026-08-06). Per the copper-topper postmortem: cosmetics belong in the pak.

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
  st = {}
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
    local ok, pre, post = pcall(RegisterHook, path,
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
      hooked.ids = hooked.ids or {}
      hooked.ids[#hooked.ids + 1] = { path = path, pre = pre, post = post }
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
          if worldChanged() then
            -- unregister FIRST: a class that survived the reload keeps its live hook, and
            -- re-arming without this stacks duplicate callbacks (one UI open per copy)
            for _, h in ipairs(hooked.ids or {}) do
              pcall(UnregisterHook, h.path, h.pre, h.post)
            end
            hooked = {}
          end
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
        local ledger = svc()
        for _, s in ipairs(sorters) do
          local inv = ledger and ledger.invOf(s.actor)
          local dev = deviceOf(s.actor)
          local p = st[s.key]
          ctx.log.info(string.format("  sorter: %s item(s), device %s, powered %s%s",
            inv and tostring(totalIn(inv)) or "?",
            dev and "ok" or "MISSING",
            dev and tostring(hasPower(dev)) or "-",
            p and (", settled (" .. p.cool .. " passes to retry)") or ""))
        end
        st = {}   -- forget every settle: the next tick re-sweeps immediately
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
