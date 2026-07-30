-- Crafting AUTO-PULL: while a crafting station is open (bench, energy bench, kitchen), any
-- recipe you look at has its missing materials PULLED from chests within craft_pull_range into
-- your inventory -- so the "1/5" you'd have to go ferrying for becomes a real, craftable "5/5".
-- The row counters also COUNT nearby chest stock ("14/2" with 16 more in a chest reads
-- "30/2") -- a cosmetic re-stamp of TXT_Needed each pass; the craftable truth stays the pull.
--
-- WHY PRE-PULL (and not dressing the numbers): the recipe widgets recompute HaveAmt from the
-- REAL inventory at times Lua cannot see (their fns are VM-internal, hooks never fire), and the
-- craft click re-validates the real inventory in BP -- painted-on "20/5" would craft nothing.
-- True craft-FROM-chest would mean repatching that compiled validation; pulling is the honest
-- reachable version, and the BORROW ledger completes the illusion: whatever a browsed recipe
-- pulled and the player did not craft away flows back to its chests when the station closes.
--
-- Mechanics per shortfall (host-only): nearest chests first via the chest_index ledger, moved
-- by `transfer` -- a synchronous inventory-to-inventory hop (chest "Remove Item Amt" Success-
-- gated, player add recount-verified; see transfer's comment for why DEBUG_SpawnItems is
-- banned here). Reflected-call volume is bounded: the 300 ms scan reads plain ints off
-- widgets, and live chest calls only happen when the ledger says the item is actually there.
local F = {}
local ctx

local chainTok = 0
local chainLive = false
local hooked = {}
local lastTry = {}    -- clsKey -> os.clock() of the last pull attempt (debounce)
local pending = {}    -- clsKey -> { expect, at }: a pull happened, HaveAmt should reach expect
local dead = {}       -- clsKey -> strike count: deliveries that never landed (2 = stop pulling)
local blindPasses = 0 -- consecutive passes where rows existed but none resolved to a station

local function cmap() return ctx.map.craftpull or {} end
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

-- UE4SS hands back a TRUTHY wrapper even when the underlying object pointer is NULL (the
-- qol tintIcon lesson), and any member call on it -- GetFullName, GetOuter, anything -- is a
-- NATIVE access violation that pcall cannot catch (two crash dumps, 2026-07-30 00:23 and
-- 17:01, both dying in UE4SS's UObject member glue reading address 0x20 the moment a
-- crafting table opened). IsValid is the one probe that null-checks before dereferencing.
-- Distinction kept: a userdata WITHOUT IsValid (the DB_Items soft-class wrappers, which fail
-- every method as a plain Lua error) is allowed through -- its failures are catchable.
local function safeForCalls(o)
  if o == nil then return false end
  if type(o) ~= "userdata" then return false end
  local valid
  local has = pcall(function() valid = o:IsValid() end)
  if not has then return true end   -- not a UObject wrapper; worst case is a caught Lua error
  return valid == true
end

local function svc() return ctx.services.chestIndex end

local function clsKeyOf(cls)
  local n
  pcall(function() n = cls:GetFullName() end)
  return n or tostring(cls)
end

local function localPcAndPawn()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not ctx.uehelp.isValid(pc) then return nil, nil end
  local p
  pcall(function() p = pc:K2_GetPawn() end)
  if not ctx.uehelp.isValid(p) then return nil, nil end
  return pc, p
end

-- The station widgets that are open RIGHT NOW, by fullname. Empty when none is.
local function openStations()
  local u = ctx.uehelp
  local out = {}
  for _, wn in ipairs(cmap().stationWidgets or {}) do
    for _, w in ipairs(u.findAll(wn)) do
      if u.isValid(w) then
        local vis
        pcall(function() vis = w:IsVisible() end)
        if vis then
          local n
          pcall(function() n = w:GetFullName() end)
          if n then out[n] = true end
        end
      end
    end
  end
  return out
end

-- Is this part-slot really on screen under a station that is open right now? One climb up the
-- LIVE visual tree answers both halves at once:
--   * UWidget:IsVisible() reports the widget's OWN flag only -- a row parked inside a
--     collapsed list still says Visible, so every recipe the player has browsed this session
--     would keep qualifying. Checking visibility at every hop is what tests "on screen".
--   * ownership CANNOT come from the slot's own outer chain: the rows are created at runtime
--     (W_WorkbenchCrafting's designer tree holds no SW_MissingCraftingPartsSlot at all), so
--     their outer is the controller/game instance, never the station -- the old outer-only
--     match rejected every row, live 2026-07-30 ("widget layout unrecognised", 17 rows).
--     GetParent is what follows where the row was actually ADDED; when it dead-ends at a
--     widget tree's root, GetOuter hops WidgetTree -> owning UserWidget and the climb resumes
--     in the tree that hosts it, until a hop's fullname is one of the open stations.
local function slotIsLive(slot, stations, why)
  local vis0
  pcall(function() vis0 = slot:IsVisible() end)
  if not vis0 then
    if why then why[#why + 1] = "slot invisible" end
    return false
  end
  local node = slot
  for _ = 1, 48 do
    local up
    pcall(function() up = node:GetParent() end)
    if not (up ~= nil and safeForCalls(up)) then
      -- tree root (or a non-widget hop): cross to whoever owns this tree. A stale row from a
      -- CLOSED station climbs past its dead owner toward the package top, where GetOuter
      -- returns the truthy NULL wrapper -- one more member call on it kills the game, so
      -- safeForCalls gates every hop.
      up = nil
      pcall(function() up = node:GetOuter() end)
      if not (up ~= nil and safeForCalls(up)) then
        if why then why[#why + 1] = "chain died (no parent, no outer)" end
        return false
      end
    end
    node = up
    local vis
    pcall(function() vis = node:IsVisible() end)
    if vis == false then   -- nil = not a widget (WidgetTree, controller): pass through
      if why then
        local n = "?"; pcall(function() n = node:GetFullName() end)
        why[#why + 1] = "invisible ancestor " .. tostring(n)
      end
      return false
    end
    local n
    pcall(function() n = node:GetFullName() end)
    if n and stations[n] then return true end
    if why then why[#why + 1] = tostring(n) end
  end
  if why then why[#why + 1] = "48 hops without reaching a station" end
  return false
end

-- How many of `cls` can land in `pInv` RIGHT NOW without the spawner plopping the surplus on
-- the floor. Stacking headroom is exact and live. Empty slots are the tricky half: the game
-- exposes no max-stack-size anywhere Lua can read, so a free slot is only ever counted as the
-- ONE item that SEEDS it -- once seeded, GetFreeStackingSpaceForItem reports that new stack's
-- real room and the next chunk takes it. Chunking this way costs a handful of extra reflected
-- calls and never over-asks; the old "one free slot takes the whole stack" guess deleted the
-- chest side and left the remainder on the ground with no way to notice.
local function roomFor(pInv, cls)
  local ledger = svc()
  local room = ledger and ledger.freeFor(pInv, cls) or 0
  if room > 0 then return room end
  local out = {}
  if ctx.uehelp.call(pInv, stmap().freeSlotsFn, out)
      and (tonumber(unwrap(out.FreeSlots)) or 0) > 0 then
    return 1
  end
  return 0
end

-- Live count of `cls` in any BC_InventorySystem (player or chest) -- the trash-proven
-- GetAmtOfItem marshal. nil = the count could not be read (then NOTHING may move: every
-- transfer below is verified by recount, and an unreadable count has no truth to verify
-- against).
local function invAmt(inv, cls)
  local ledger = svc()
  local out = {}
  if not (ledger and ctx.uehelp.call(inv, stmap().amtFn, ledger.probeFor(cls), out)) then
    return nil
  end
  return tonumber(unwrap(out.Amount)) or 0
end

-- Move up to `n` of cls from srcInv into dstInv, SYNCHRONOUSLY, chunked against dst's live
-- room. This replaced DEBUG_SpawnItems entirely: that call is a WORLD DROP at the player
-- +500Z with FlyToPlayer=false (bp_controller RE) -- it never touches an inventory, and when
-- the proximity pickup didn't happen to grab the drop, the 3s debounce re-pulled forever and
-- drained chests onto the floor (the 18:53 live loop). Here the item only ever exists in the
-- two inventory arrays. Trust ladder per chunk: src remove is gated on its own Success out
-- (proven); dst add is `addPlayerFn`/`addFn`, whose outs LIE under this marshal (the items.lua
-- Amt==1 lesson) -- so the add is verified by RECOUNTING dst, and any shortfall is handed
-- straight back to src. `intoPlayer` picks the game's own give-the-player path (attributes,
-- replication) over the bare chest add.
local function transfer(srcInv, dstInv, cls, n, intoPlayer)
  local ledger = svc()
  if not ledger then return 0 end
  local moved = 0
  while moved < n do
    local room = roomFor(dstInv, cls)
    if room <= 0 then break end
    local take = math.min(room, n - moved)
    local dstBefore = invAmt(dstInv, cls)
    if dstBefore == nil then break end
    local outR = {}
    local okRm = ctx.uehelp.call(srcInv, stmap().removeAmtFn,
      ledger.probeFor(cls, take), true, outR)
    if not (okRm and unwrap(outR.Success) == true) then break end
    if intoPlayer then
      ctx.uehelp.call(dstInv, stmap().addPlayerFn, ledger.probeFor(cls, take),
        true, false, {}, {})
    else
      ctx.uehelp.call(dstInv, stmap().addFn, ledger.probeFor(cls, take),
        true, {}, {}, {}, {})
    end
    local got = math.max(0, math.min(take, (invAmt(dstInv, cls) or dstBefore) - dstBefore))
    if got < take then
      -- dst refused part of the chunk: hand the shortfall straight back to src
      local back = take - got
      local srcBefore = invAmt(srcInv, cls)
      ctx.uehelp.call(srcInv, stmap().addFn, ledger.probeFor(cls, back),
        true, {}, {}, {}, {})
      local backGot = srcBefore and math.max(0,
        math.min(back, (invAmt(srcInv, cls) or srcBefore) - srcBefore)) or -1
      if backGot < back then
        ctx.log.warn(string.format("craft_pull: %d item(s) fell out of a transfer and the "
          .. "give-back also failed -- count your stock", back - math.max(0, backGot)))
      end
      moved = moved + got
      break
    end
    moved = moved + got
  end
  return moved
end

-- Pull up to `wantAmt` of cls from nearby chests into the player inventory. Returns how many
-- items actually landed, plus per-chest {key, entry, n} sources for the borrow ledger.
local function pullFromChests(pawn, cls, wantAmt)
  local ledger = svc()
  if not ledger then return 0, {} end
  local loc = ctx.identity.locationOf(pawn)
  if not loc then return 0, {} end
  local okI, pInv = ctx.uehelp.get(pawn, stmap().invProp)
  if not (okI and ctx.uehelp.isValid(pInv)) then return 0, {} end
  if wantAmt <= 0 then return 0, {} end
  local r = cfgn("craft_pull_range", 5000.0)
  local moved, full, srcs = 0, false, {}
  for _, t in ipairs(ledger.chestsNear(loc, r * r)) do
    if moved >= wantAmt or full then break end
    local avail = ledger.amtIn(t.key, t.entry, cls)
    if avail > 0 then
      local chest = ledger.actorOf(t.key, t.entry)
      local cInv = chest and ledger.invOf(chest)
      if cInv then
        local want = math.min(avail, wantAmt - moved)
        local got = transfer(cInv, pInv, cls, want, true)
        if got > 0 then
          moved = moved + got
          ledger.noteMove(t.key, cls, -got)
          srcs[#srcs + 1] = { key = t.key, entry = t.entry, n = got }
        end
        if got < want then
          ledger.invalidate(t.key)  -- whatever stopped the transfer, re-count this chest
          if roomFor(pInv, cls) <= 0 then full = true end
        end
      end
    end
  end
  if full and moved < wantAmt then
    ctx.log.info("craft_pull: your inventory filled up before the recipe did")
  end
  return moved, srcs
end

-- The borrow ledger: what the auto-pull moved into the pack this station session, and from
-- where. On station close whatever the player did NOT craft away flows back to its chests --
-- so browsing recipes never leaves their pack cluttered, and the net effect of crafting is
-- "the chest paid for it". basis = the REAL have before the first pull of that class; the
-- return is clamp(haveNow - basis, 0, borrowed) per class, so mats the player owned all along
-- (or picked up meanwhile, or crafted away) are never shipped off to a chest.
local borrows = {}
local function returnBorrows()
  local b = borrows
  borrows = {}
  if next(b) == nil then return end
  local ledger = svc()
  local _, pawn = localPcAndPawn()
  if not (ledger and pawn) then return end
  local okI, pInv = ctx.uehelp.get(pawn, stmap().invProp)
  if not (okI and ctx.uehelp.isValid(pInv)) then return end
  local sentTotal = 0
  for _, e in pairs(b) do
    local now = invAmt(pInv, e.cls)
    local give = now and math.max(0, math.min(e.n, now - e.basis)) or 0
    for _, src in ipairs(e.srcs) do
      if give <= 0 then break end
      local chest = ledger.actorOf(src.key, src.entry)
      local cInv = chest and ledger.invOf(chest)
      if cInv then
        local sent = transfer(pInv, cInv, e.cls, math.min(give, src.n), false)
        give = give - sent
        sentTotal = sentTotal + sent
        if sent > 0 then ledger.noteMove(src.key, e.cls, sent) end
      end
    end
    -- source chest gone or full: any leftover simply stays in the pack
  end
  if sentTotal > 0 then
    ctx.log.info(string.format(
      "craft_pull: returned %d unused material(s) to the chests they came from", sentTotal))
  end
end

-- How much of `cls` sits in ledger chests within pull range of the pawn. Cached by the
-- ledger (20s TTL per chest+class), so per-pass cost is plain Lua on cache hits.
local function chestStock(pawn, cls)
  local ledger = svc()
  if not ledger then return 0 end
  local loc = ctx.identity.locationOf(pawn)
  if not loc then return 0 end
  local r = cfgn("craft_pull_range", 5000.0)
  local total = 0
  for _, t in ipairs(ledger.chestsNear(loc, r * r)) do
    total = total + ledger.amtIn(t.key, t.entry, cls)
  end
  return total
end

-- Rewrite the row's "14/2" counter to count nearby chest stock too ("30/2") -- the display
-- the player actually asked for. The game recomputes this text from the REAL inventory at
-- times Lua cannot see, so the stamp is re-applied every pass instead of latched; when the
-- chests hold none of the item the text is left alone (the game's number is already right).
local function stampReach(slot, m, cls, need, have, extra)
  if extra <= 0 then return end
  local okT, tb = ctx.uehelp.get(slot, m.needTextProp)
  if not (okT and ctx.uehelp.isValid(tb)) then return end
  pcall(function() tb:SetText(FText(tostring(have + extra) .. "/" .. tostring(need))) end)
end

local function scanPass(tok)
  if tok ~= chainTok then return end
  if not ctx.config.get("craft_pull") then chainLive = false returnBorrows() return end
  local stations = openStations()
  if next(stations) == nil then chainLive = false returnBorrows() return end
  if ctx.net.isHost() then
    local pc, pawn = localPcAndPawn()
    if pc and pawn then
      local m = cmap()
      local saw, took = 0, 0
      for _, cn in ipairs(m.partSlotClasses or {}) do
      for _, slot in ipairs(ctx.uehelp.findAll(cn)) do
        if ctx.uehelp.isValid(slot) then
          saw = saw + 1
          if slotIsLive(slot, stations) then
            took = took + 1
            local okN, need = ctx.uehelp.get(slot, m.needProp)
            local okH, have = ctx.uehelp.get(slot, m.haveProp)
            need, have = tonumber(need) or 0, tonumber(have) or 0
            if okN and okH then
              local cls
              pcall(function() cls = slot[m.itemDataProp][m.itemActorField] end)
              -- an unset ItemActor field reads as the truthy NULL wrapper; clsKeyOf's
              -- GetFullName on that is the uncatchable AV -- gate, don't trust ~= nil
              if safeForCalls(cls) then
                local ck = clsKeyOf(cls)
                -- landed-verify: a pull is only a success once HaveAmt actually reaches what
                -- was promised. Without this, one broken delivery re-pulls every debounce and
                -- DRAINS the chest (the 18:53 spawn-era loop). The clear MUST happen out here,
                -- not inside the shortfall branch: a landed delivery reads have==need, the
                -- shortfall branch is skipped, and a lingering flag then stalls the refill 8s
                -- (plus a bogus strike) after every CRAFT -- the 19:07 live symptom.
                local p = pending[ck]
                if p and have >= p.expect then
                  pending[ck], dead[ck], p = nil, nil, nil
                end
                if need > have then
                  if p and os.clock() - p.at > 8.0 then
                    pending[ck], p = nil, nil
                    dead[ck] = (dead[ck] or 0) + 1
                    if dead[ck] >= 2 then
                      ctx.log.warn("craft_pull: the recipe row never noticed materials the " ..
                        "pull delivered (widget not refreshing?) -- pulling of that item is " ..
                        "OFF until you reopen the station")
                    end
                  end
                  if not p and (dead[ck] or 0) < 2
                      and os.clock() - (lastTry[ck] or -1e9) > 3.0 then
                    lastTry[ck] = os.clock()
                    local got, srcs = pullFromChests(pawn, cls, need - have)
                    if got > 0 then
                      ctx.log.info(string.format(
                        "craft_pull: fetched %d from nearby chests (%d/%d in hand now)",
                        got, have + got, need))
                      local bw = borrows[ck]
                      if not bw then
                        bw = { cls = cls, n = 0, basis = have, srcs = {} }
                        borrows[ck] = bw
                      end
                      bw.n = bw.n + got
                      for _, s in ipairs(srcs) do bw.srcs[#bw.srcs + 1] = s end
                      pending[ck] = { expect = have + got, at = os.clock() }
                      have = have + got
                    end
                  end
                end
                stampReach(slot, m, cls, need, have, chestStock(pawn, cls))
              end
            end
          end
        end
      end
      end
      -- A station is open and rows exist, yet NOTHING passed the on-screen gate, pass after
      -- pass. That is the gate mis-reading this build's widget layout, not an idle player --
      -- say so once instead of letting the feature look like it is simply switched off.
      if saw > 0 and took == 0 then
        blindPasses = blindPasses + 1
        if blindPasses == 20 then
          ctx.log.warn("craft_pull: a station is open with " .. saw .. " recipe row(s), but " ..
            "none resolve to it -- auto-pull is idle (widget layout unrecognised)")
          -- one sample climb so the log shows WHERE the gate lost the trail
          for _, cn in ipairs(m.partSlotClasses or {}) do
            local done = false
            for _, slot in ipairs(ctx.uehelp.findAll(cn)) do
              if ctx.uehelp.isValid(slot) then
                local why = {}
                slotIsLive(slot, stations, why)
                ctx.log.warn("craft_pull: sample row climb: " .. table.concat(why, " | "))
                done = true
                break
              end
            end
            if done then break end
          end
        end
      else
        blindPasses = 0
      end
    end
  end
  deferOnly(cfgn("craft_pull_scan_ms", 300), function() onGameThread(function() scanPass(tok) end) end)
end

local function startScan()
  if chainLive then return end
  chainLive = true
  chainTok = chainTok + 1
  pending, dead = {}, {}  -- fresh station open = fresh delivery slate
  local tok = chainTok
  deferOnly(150, function() onGameThread(function() scanPass(tok) end) end)
end

local function fullFuncPath(obj, fnName)
  local full
  pcall(function()
    obj:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n == fnName then pcall(function() full = fn:GetFullName() end) end
    end)
  end)
  if full then return (full:gsub("^%S+%s+", "")) end
  return nil
end

-- The Character notify fires for EVERY Character constructed -- respawns and remote players
-- joining, not only world loads. Only a new local controller means the class-level hooks
-- really died; clearing the registry on a respawn would stack a second registration on the
-- same still-live function path.
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

local function armOpenHooks()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not pc then return end
  for _, fn in ipairs(cmap().openFns or {}) do
    if not hooked[fn] then
      local path = fullFuncPath(pc, fn)
      if path then
        local ok = pcall(RegisterHook, path, ctx.log.guard("craftpull.open", function()
          deferOnly(0, function() onGameThread(startScan) end)
        end))
        if ok then
          hooked[fn] = true
          ctx.log.debug("craft_pull: hooked " .. path)
        end
      end
    end
  end
end

function F.init(c)
  ctx = c
  if not ctx.config.get("craft_pull") then
    ctx.log.info("craft_pull: disabled by config")
    return F
  end
  if not ctx.gate.require(ctx.log, ctx.map, "craft_pull",
      { "craftpull.openFns", "craftpull.partSlotClasses", "craftpull.needTextProp",
        "stock.removeAmtFn" }) then
    return false
  end

  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, function() onGameThread(function()
        if worldChanged() then
          hooked = {}  -- new world = reloaded classes: those registrations are dead
          lastTry, pending, dead = {}, {}, {}
          borrows = {} -- chest handles died with the world; borrowed mats stay in the pack
        end
        armOpenHooks()
      end) end)
    end)
  deferOnly(2000, function() onGameThread(armOpenHooks) end)

  ctx.log.info("craft_pull: recipes fetch their materials from chests within " ..
    tostring(cfgn("craft_pull_range", 5000.0) / 100) .. " m of you")
  return F
end

return F
