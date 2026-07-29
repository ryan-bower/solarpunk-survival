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

local function stationOpen()
  local u = ctx.uehelp
  for _, wn in ipairs(cmap().stationWidgets or {}) do
    for _, w in ipairs(u.findAll(wn)) do
      if u.isValid(w) then
        local vis
        pcall(function() vis = w:IsVisible() end)
        if vis then return true end
      end
    end
  end
  return false
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
  -- pre-flight capacity: existing-stack headroom, or any free slot at all -- a full inventory
  -- must not have the spawner plopping pulled mats onto the floor
  local headroom = ledger.freeFor(pInv, cls)
  if headroom < wantAmt then
    local out = {}
    if ctx.uehelp.call(pInv, stmap().freeSlotsFn, out)
        and (tonumber(unwrap(out.FreeSlots)) or 0) > 0 then
      headroom = wantAmt -- a fresh slot takes the stack
    end
  end
  wantAmt = math.min(wantAmt, headroom)
  if wantAmt <= 0 then return 0 end
  local r = cfgn("craft_pull_range", 5000.0)
  local moved = 0
  for _, t in ipairs(ledger.chestsNear(loc, r * r)) do
    if moved >= wantAmt then break end
    local avail = ledger.amtIn(t.key, t.entry, cls)
    if avail > 0 then
      local chest = ledger.actorOf(t.key, t.entry)
      local cInv = chest and ledger.invOf(chest)
      if cInv then
        local take = math.min(avail, wantAmt - moved)
        local outR = {}
        local okRm = ctx.uehelp.call(cInv, stmap().removeAmtFn,
          ledger.probeFor(cls, take), true, outR)
        if okRm and unwrap(outR.Success) == true then
          local got = 0
          for _ = 1, take do
            if pcall(function() pc:DEBUG_SpawnItems(cls, 1) end) then got = got + 1 end
          end
          moved = moved + got
          ledger.noteMove(t.key, cls, -take)
          if got < take then
            ctx.log.warn(string.format(
              "craft_pull: chest gave up %d but only %d landed in the inventory", take, got))
          end
        else
          ledger.invalidate(t.key) -- the ledger lied about this chest; re-count it next ask
        end
      end
    end
  end
  return moved
end

local function scanPass(tok)
  if tok ~= chainTok then return end
  if not ctx.config.get("craft_pull") then chainLive = false return end
  if not stationOpen() then chainLive = false return end
  if ctx.net.isHost() then
    local pc, pawn = localPcAndPawn()
    if pc and pawn then
      local m = cmap()
      for _, slot in ipairs(ctx.uehelp.findAll(m.partSlotClass)) do
        if ctx.uehelp.isValid(slot) then
          local vis
          pcall(function() vis = slot:IsVisible() end)
          if vis then
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
      hooked = {}    -- new world, new controller: dead hooks
      lastTry = {}
      deferOnly(4000, function() onGameThread(armOpenHooks) end)
    end)
  deferOnly(2000, function() onGameThread(armOpenHooks) end)

  ctx.log.info("craft_pull: recipes fetch their materials from chests within " ..
    tostring(cfgn("craft_pull_range", 5000.0) / 100) .. " m of you")
  return F
end

return F
