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

-- The bisection itself is trash_slot's. It is the same probe over the same game call, and
-- trash's is the copy tests/spec.lua exercises headless ("extracted so the algorithm is
-- testable"); a second hand-rolled one only meant a fix to either could miss the other.
local bisect = require("features.trash_slot").bisect

local NS_CAP = 8        -- held classes discovered per pass (see the rotation below)
local NS_BUDGET = 12    -- whole-slot moves per pass; the next pass continues

local nsRot = {}        -- sorterKey -> where the candidate rotation starts next pass
local nsLinear = false  -- the class-array probe refused; scan one class at a time this session
local pathWarned = {}   -- class name -> true after the "cannot resolve" warn
local candWarnedAt = -1e9

-- Candidate class wrappers come from the game's own DB_Items map keys, filtered by the baked
-- name set -- the trash-slot-proven wrapper source for array marshals. Never from bulk
-- classByName: 238 short-name resolves held in a table proved to be a stale-pointer lottery
-- (rig 2026-08-06 -- Contains(full)=true while Contains(either half)=false, and a GetAmtOfItem
-- sweep through the same wrappers finding NOTHING in an inventory provably holding two weather
-- stations).
--
-- MEMOIZED PER WORLD, not per pass: the walk is a full DB_Items ForEach with two reflected
-- calls per key (~600 of them) and a settled sorter was paying it on every retry. The cache key
-- is the local controller's fullname -- the same world-change signal the interact hook uses --
-- because a UClass wrapper kept ACROSS a world load is a stale pointer waiting to be
-- dereferenced, which is the one thing this list must never hand out.
local candCache = { tag = nil, list = nil }

local function worldTag()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  return pcNow
end

local function nonstackCandidates()
  local tag = worldTag()
  if candCache.list and candCache.tag == tag then return candCache.list end
  local out = {}
  local tm = ctx.map.trash or {}
  local gi = tm.giClass and ctx.uehelp.findFirst(tm.giClass)
  if gi and tm.dbItemsProp then
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
  end
  if #out == 0 then
    -- SAY SO. These key wrappers "fail every direct method call yet marshal fine as arguments"
    -- (the chest_index lesson), so a build where GetFName refuses filters every candidate out
    -- and the whole feature goes inert with literally zero output -- indistinguishable from the
    -- bug it exists to fix. trash's discoverClass warns for exactly this reason. Throttled:
    -- a settled sorter retries this every ~30 s.
    if os.clock() - candWarnedAt > 60 then
      candWarnedAt = os.clock()
      ctx.log.warn("sort_chest: DB_Items gave no non-stackable classes (" ..
        tostring(tm.giClass) .. "/" .. tostring(tm.dbItemsProp) ..
        ") -- non-stackables cannot be filed")
    end
    return out
  end
  if tag then candCache.tag, candCache.list = tag, out end
  return out
end

-- A wrapper for ONE class, resolved from the baked ASSET PATH. uehelp.classByName is a
-- SHORT-NAME FindObject that only uses the path as a LoadAsset hint on a miss -- i.e. the very
-- lookup the comment above calls a stale-pointer lottery, and after a world reload it can hand
-- back the GC-pending old copy living under the same name. StaticFindObject takes the full
-- object path and cannot pick the wrong one. A total miss is WARNED, not swallowed: silently
-- treating it as "holds none" is how a discovered class does nothing, pass after pass.
local function classExact(name)
  local path = NONSTACK[name]
  local c
  if path then
    pcall(function() c = StaticFindObject(path) end)
    if not ctx.uehelp.isValid(c) and LoadAsset then
      pcall(LoadAsset, path)
      pcall(function() c = StaticFindObject(path) end)
    end
  end
  if ctx.uehelp.isValid(c) then return c end
  c = ctx.uehelp.classByName(name, path)
  if ctx.uehelp.isValid(c) then return c end
  if not pathWarned[name] then
    pathWarned[name] = true
    ctx.log.warn("sort_chest: cannot resolve " .. tostring(name) .. " (" .. tostring(path) ..
      ") -- that non-stackable will not be filed")
  end
  return nil
end

-- Does `inv` hold any of these classes? nil = the reflected call ITSELF failed (a marshal
-- refusal on the class array, a stale system) -- callers must treat that as UNKNOWN, never as
-- "no". trash_slot's own containsAny says so verbatim and keeps a linear-scan fallback for it;
-- collapsing it to false here meant one refused marshal silenced the whole feature at debug
-- level, reading exactly like the pre-fix bug.
local function containsAny(inv, entries)
  local arr = {}
  for i, e in ipairs(entries) do arr[i] = e.cls end
  local out = {}
  if not ctx.uehelp.call(inv, stmap().containsAnyFn, arr, out) then return nil end
  return unwrap(out.Contains) == true
end

-- Count of `cls` in `inv`. nil = the count call itself failed -- NEVER 0. craft_pull's invAmt
-- returns nil for exactly this reason: an unreadable recount read as "none left" credits a move
-- that never happened and reports a finished sort over items still sitting in the chest.
local function amtOf(ledger, inv, cls)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().amtFn, ledger.probeFor(cls), out) then return nil end
  return math.floor(tonumber(unwrap(out.Amount)) or 0)
end

local function freeSlotsIn(inv)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().freeSlotsFn, out) then return 0 end
  local v = unwrap(out.FreeSlots)
  if v == nil then local _, first = next(out) v = unwrap(first) end
  return math.floor(tonumber(v) or 0)
end

-- Which candidates does `inv` hold (at most `cap`)? Repeated bisection: each round costs
-- ~log2(N) set probes and drops the class it found. Second return is `probeAlive` -- false when
-- the probe path gave up, which the caller answers with a linear scan.
local function heldNonstack(inv, entries, cap)
  local found, list = {}, entries
  local probe = function(sub) return containsAny(inv, sub) end
  while #found < cap and #list > 0 do
    local hit, alive = bisect(list, probe)
    if not alive then return found, false end
    if not hit then break end
    found[#found + 1] = hit
    local rest = {}
    for _, e in ipairs(list) do if e ~= hit then rest[#rest + 1] = e end end
    list = rest
  end
  return found, true
end

-- The linear fallback for a refused class-array marshal: one GetAmtOfItem per candidate, the
-- same trade trash_slot makes when its own bisection probe stops answering.
local function heldLinear(ledger, inv, entries, cap)
  local found = {}
  for _, e in ipairs(entries) do
    if #found >= cap then break end
    local n = amtOf(ledger, inv, e.cls)
    if n and n > 0 then found[#found + 1] = e end
  end
  return found
end

-- The first EMPTY index in `inv`, asked of the game -- no Sort, no struct read.
-- GetFirstIndexForItem walks the array comparing each slot's Item CLASS to the probe's with ==
-- and nothing else (bytecode: CallFunc_EqualEqual_ClassClass over Array_Get_Item), so a probe
-- whose Item is left unset (nullptr) matches the first slot holding nothing.
--
-- This REPLACES calling the game's Sort on the receiving chest. Sort is not a read: it rewrites
-- that chest's whole array, merges stacks, clears the tail and saves -- and its bytecode DROPS
-- any stack whose GetItemByActor row lookup misses ("Unknown Item" ErrorPrint, the slot never
-- written back). Running it on the player's own storage just to make our first-empty arithmetic
-- work was a silent item-loss path, and it re-ordered chests the player had arranged by hand.
-- We now only ever write INTO a destination, never rewrite one.
local function firstEmptyIdx(ledger, inv)
  local out = {}
  if not ctx.uehelp.call(inv, stmap().firstIdxFn, ledger.probeFor(nil), out, {}) then return nil end
  if unwrap(out.ContainsItem) ~= true then return nil end
  local i = math.floor(tonumber(unwrap(out.Index)) or -1)
  return (i >= 0) and i or nil
end

-- Fallback when that probe refuses: the tail arithmetic, WITHOUT compacting anything. It is
-- right on a chest whose slots are already packed low (the common case) and merely wrong on a
-- fragmented one -- and wrong is harmless, because MoveItemDiffInv bounces off an occupied
-- target and the recount after every move refuses to credit a move that landed nothing.
local function tailIdx(inv)
  local free = freeSlotsIn(inv)
  if free <= 0 then return nil end
  local len = 0
  pcall(function() len = #inv.Inventory end)   -- length-only read: safe
  local i = len - free
  return (i >= 0 and i < len) and i or nil
end

-- File the sorter's non-stackables into chests that already hold that class. Nothing here reads
-- a slot struct and nothing here REWRITES a destination chest: the target index comes from the
-- game's own first-empty probe, and every move is verified by a recount -- a move that lands
-- nothing, or whose recount cannot be read, stops the loop cold (no churn, no false credit).
local function fileNonstackables(s, inv, ledger, targets)
  local cands = nonstackCandidates()
  if #cands == 0 then return 0 end        -- nonstackCandidates already warned
  -- ROTATE the candidate order per pass. The cap bounds DISCOVERY, so with a fixed order the
  -- first `cap` held classes are the only ones ever looked at: four machines no neighbour wants
  -- hid a fifth item forever -- the exact symptom this pass exists to cure. The next pass starts
  -- just PAST the last class this one discovered, so anything the cap cut off leads immediately
  -- and nothing can starve.
  local rot = (nsRot[s.key] or 0) % #cands
  local ordered, pos = {}, {}
  for i = 1, #cands do
    ordered[i] = cands[((rot + i - 1) % #cands) + 1]
    pos[ordered[i]] = i
  end

  local held
  if not nsLinear then
    local alive
    held, alive = heldNonstack(inv, ordered, NS_CAP)
    if not alive then
      nsLinear = true
      ctx.log.info("sort_chest: the class-array probe refused to marshal -- " ..
        "using linear scans for the rest of the session")
    end
  end
  if nsLinear then held = heldLinear(ledger, inv, ordered, NS_CAP) end
  local last = 0
  for _, e in ipairs(held) do last = math.max(last, pos[e] or 0) end
  nsRot[s.key] = (rot + last) % #cands
  ctx.log.debug("sort_chest: non-stackable discovery held " .. #held .. " class(es)")
  if #held == 0 then return 0 end
  local movedTotal, fed = 0, 0
  local budget = NS_BUDGET
  for _, h in ipairs(held) do
    -- the db-key wrapper stays in the Contains arrays (its proven marshal role); every STRUCT
    -- probe below gets a wrapper resolved from the baked asset path, exactly
    local cls = classExact(h.name)
    local amt = cls and amtOf(ledger, inv, cls) or nil
    for _, t in ipairs(targets) do
      if not amt or amt <= 0 or budget <= 0 then break end
      if t.entry.cls ~= smap().class then  -- sorters never feed each other
        local chest = ledger.actorOf(t.key, t.entry)
        local dstInv = chest and ledger.invOf(chest)
        -- The rule -- "only into a chest that already holds this class" -- is read LIVE off the
        -- chest. The ledger's cached count carries a 20 s TTL that only OUR OWN moves patch, so
        -- a chest the player just emptied by hand still reads as holding one, and the item would
        -- land somewhere it no longer belongs. Quick Stack enforces the same rule atomically;
        -- this path has to earn it.
        if dstInv and not uiBrowsing(dstInv) and (amtOf(ledger, dstInv, cls) or 0) > 0 then
          local before = amt
          while amt and amt > 0 and budget > 0 do
            local dstIdx = firstEmptyIdx(ledger, dstInv) or tailIdx(dstInv)
            if not dstIdx then break end             -- chest full, or both probes refused
            local out = {}
            if not ctx.uehelp.call(inv, stmap().firstIdxFn,
                ledger.probeFor(cls), out, {}) then break end
            if unwrap(out.ContainsItem) ~= true then break end
            local srcIdx = math.floor(tonumber(unwrap(out.Index)) or -1)
            if srcIdx < 0 then break end
            if not ctx.uehelp.call(inv, stmap().moveDiffFn,
                dstInv, srcIdx, math.floor(dstIdx)) then break end
            local now = amtOf(ledger, inv, cls)
            if now == nil then break end       -- recount unreadable: never credit the move
            if now >= amt then break end       -- nothing landed: stop, never spin
            movedTotal = movedTotal + (amt - now)
            amt = now
            budget = budget - 1
          end
          if amt and amt < before then
            fed = fed + 1
            -- the class and the exact delta are both known here, so patch the ledger instead of
            -- blowing the whole chest's entry away and paying for a re-read
            ledger.noteMove(t.key, cls, before - amt)
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
  -- one recount per target, not two: this target's "after" is the next one's "before"
  local remain = total
  for _, t in ipairs(targets) do
    -- only PLAIN chests receive; two sorters must never ping-pong a pile between them
    if t.entry.cls ~= smap().class then
      local chest = ledger.actorOf(t.key, t.entry)
      local dstInv = chest and ledger.invOf(chest)
      if dstInv then
        if ctx.uehelp.call(dstInv, stmap().quickStackFn, inv, {}) then
          local after = totalIn(inv)
          if after < remain then
            moved = moved + (remain - after)
            fed = fed + 1
            ledger.invalidate(t.key)
          end
          remain = after
          if remain == 0 then break end
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
  local left = remain
  if left > 0 then
    local okNS, movedNS = pcall(fileNonstackables, s, inv, ledger, targets)
    if okNS then
      moved = moved + (movedNS or 0)
    else
      ctx.log.warn("sort_chest: non-stackable pass errored: " .. tostring(movedNS))
    end
    left = totalIn(inv)
  end
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
  local pcNow = worldTag()
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
