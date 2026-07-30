-- Crafting AUTO-PULL: while a crafting station is open (bench, energy bench, kitchen), any
-- recipe you look at has its missing materials PULLED from chests within craft_pull_range into
-- your inventory -- so the "1/5" you'd have to go ferrying for becomes a real, craftable "5/5".
--
-- WHY PRE-PULL (and not dressing the numbers): the recipe widgets recompute HaveAmt from the
-- REAL inventory at times Lua cannot see (their fns are VM-internal, hooks never fire), and the
-- craft click re-validates the real inventory in BP -- painted-on "20/5" would craft nothing.
-- Pulling makes the display truthful instead of decorated. Known, accepted quirk: browsing a
-- recipe pulls its mats even if you never craft it; they simply stay in your inventory.
--
-- Mechanics per shortfall (host-only): nearest chests first via the chest_index ledger.
-- Chest side: "Remove Item Amt" -- its Success out is the truth gate (a stale ledger count
-- simply fails the remove; nothing moves). Player side: the controller's DEBUG_SpawnItems, one
-- call per item -- the mod's only LIVE-PROVEN grant primitive (AddItemForPlayer's multi-out
-- marshal is unproven; see items.lua for the Amt==1 lie that killed bulk grants once already).
-- Reflected-call volume is bounded: the 300 ms scan reads plain ints off widgets, and live
-- chest calls only happen when the ledger says the item is actually there.
local F = {}
local ctx

local chainTok = 0
local chainLive = false
local hooked = {}
local lastTry = {}    -- clsKey -> os.clock() of the last pull attempt (debounce)
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

-- Is this part-slot really on screen under a station that is open right now? Two independent
-- gates, because neither alone answers it:
--   * UWidget:IsVisible() reports the widget's OWN flag only -- a row parked inside a
--     collapsed list still says Visible, so every recipe the player has browsed this session
--     would keep qualifying. Walking the PARENT chain is what actually tests "on screen".
--   * the parent chain stops at the owning widget's root, so it cannot tell one station from
--     another; the OUTER chain (slot -> [WidgetTree] -> the station UserWidget) does.
local ownerBlind = false
local function slotIsLive(slot, stations)
  local vis
  pcall(function() vis = slot:IsVisible() end)
  if not vis then return false end
  local node = slot
  for _ = 1, 24 do
    local parent
    pcall(function() parent = node:GetParent() end)
    if not (parent and ctx.uehelp.isValid(parent)) then break end
    local pv
    pcall(function() pv = parent:IsVisible() end)
    if not pv then return false end
    node = parent
  end
  local o
  pcall(function() o = slot:GetOuter() end)
  if not o then
    -- GetOuter unavailable in this build: keep the feature alive on the visibility chain
    -- alone rather than pulling nothing forever, but say so once.
    if not ownerBlind then
      ownerBlind = true
      ctx.log.warn("craft_pull: cannot read widget outers -- recipe rows are matched by " ..
        "visibility only, so a second open station could contribute rows")
    end
    return true
  end
  for _ = 1, 6 do
    local n
    pcall(function() n = o:GetFullName() end)
    if n and stations[n] then return true end
    local nxt
    pcall(function() nxt = o:GetOuter() end)
    if not nxt then return false end
    o = nxt
  end
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

-- Pull up to `wantAmt` of cls from nearby chests into the player inventory. Returns how many
-- items actually landed.
local function pullFromChests(pc, pawn, cls, wantAmt)
  local ledger = svc()
  if not ledger then return 0 end
  local loc = ctx.identity.locationOf(pawn)
  if not loc then return 0 end
  local okI, pInv = ctx.uehelp.get(pawn, stmap().invProp)
  if not (okI and ctx.uehelp.isValid(pInv)) then return 0 end
  if wantAmt <= 0 then return 0 end
  local r = cfgn("craft_pull_range", 5000.0)
  local moved, full = 0, false
  for _, t in ipairs(ledger.chestsNear(loc, r * r)) do
    if moved >= wantAmt or full then break end
    local avail = ledger.amtIn(t.key, t.entry, cls)
    if avail > 0 then
      local chest = ledger.actorOf(t.key, t.entry)
      local cInv = chest and ledger.invOf(chest)
      if cInv then
        -- chunk against the inventory's REAL room, re-measured every round trip
        while moved < wantAmt and avail > 0 do
          local room = roomFor(pInv, cls)
          if room <= 0 then full = true break end
          local take = math.min(room, avail, wantAmt - moved)
          local outR = {}
          local okRm = ctx.uehelp.call(cInv, stmap().removeAmtFn,
            ledger.probeFor(cls, take), true, outR)
          if not (okRm and unwrap(outR.Success) == true) then
            ledger.invalidate(t.key) -- the ledger lied about this chest; re-count it next ask
            break
          end
          local got = 0
          for _ = 1, take do
            if pcall(function() pc:DEBUG_SpawnItems(cls, 1) end) then got = got + 1 end
          end
          moved, avail = moved + got, avail - take
          ledger.noteMove(t.key, cls, -take)
          if got < take then
            ctx.log.warn(string.format(
              "craft_pull: chest gave up %d but only %d landed in the inventory", take, got))
            full = true
            break
          end
        end
      end
    end
  end
  if full and moved < wantAmt then
    ctx.log.info("craft_pull: your inventory filled up before the recipe did")
  end
  return moved
end

local function scanPass(tok)
  if tok ~= chainTok then return end
  if not ctx.config.get("craft_pull") then chainLive = false return end
  local stations = openStations()
  if next(stations) == nil then chainLive = false return end
  if ctx.net.isHost() then
    local pc, pawn = localPcAndPawn()
    if pc and pawn then
      local m = cmap()
      local saw, took = 0, 0
      for _, slot in ipairs(ctx.uehelp.findAll(m.partSlotClass)) do
        if ctx.uehelp.isValid(slot) then
          saw = saw + 1
          if slotIsLive(slot, stations) then
            took = took + 1
            local okN, need = ctx.uehelp.get(slot, m.needProp)
            local okH, have = ctx.uehelp.get(slot, m.haveProp)
            need, have = tonumber(need) or 0, tonumber(have) or 0
            if okN and okH and need > have then
              local cls
              pcall(function() cls = slot[m.itemDataProp][m.itemActorField] end)
              if cls ~= nil then
                local ck = clsKeyOf(cls)
                if os.clock() - (lastTry[ck] or -1e9) > 3.0 then
                  lastTry[ck] = os.clock()
                  local got = pullFromChests(pc, pawn, cls, need - have)
                  if got > 0 then
                    ctx.log.info(string.format(
                      "craft_pull: fetched %d from nearby chests (%d/%d in hand now)",
                      got, have + got, need))
                  end
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
      { "craftpull.openFns", "craftpull.partSlotClass", "stock.removeAmtFn" }) then
    return false
  end

  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, function() onGameThread(function()
        if worldChanged() then
          hooked = {}  -- new world = reloaded classes: those registrations are dead
          lastTry = {}
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
