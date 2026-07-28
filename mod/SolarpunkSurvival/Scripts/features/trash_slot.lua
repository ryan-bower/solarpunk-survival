-- The trash-can slot (2026-07-28 request): one extra, red-marked inventory slot to the right of
-- the bag's bottom-right cell. Drop an item in and it is queued for deletion; drop another on top
-- and the previous one is destroyed while the new one takes its place; the survivor stays
-- retrievable until it is replaced or the session ends. Terraria's trash slot, in short.
--
-- HOW (all symbols + the full RE trail live in mapping.trash):
--   * The slot is a REAL W_InventorySlot, created by the game's own slot factory into the
--     inventory window's uniform grid at (last row, column 7) -- so every native behaviour
--     (carry in/out, stacking, half-splits, tooltips, quantity text, durability bar) comes free
--     and the cell rides the window wherever it goes.
--   * Its backing store is a DETACHED BC_InventorySystem: StaticConstructObject'd, never
--     registered, reachable only through a collapsed W_ChestInventory that exists to answer
--     GetSystemAndIndexForSlot with (our system, index 51). The chest widget is parked in the
--     viewport (Collapsed = never laid out, never hit-tested) because that is the one reference
--     the GC provably honours for a widget the game never adopted -- live testing showed the
--     unparked pair collected within a ~60s sweep, slot's parent stamp dangling. Its Construct
--     DOES run on the add and rewrites ChestSlots with 12 fresh slots, so the array is stamped
--     strictly AFTER parking. Nothing else in the game knows the system exists -- and because
--     its InventoryID is the zero GUID, the save path's
--     update-only-by-GUID write makes persistence structurally impossible: quit, and the trash
--     is forgotten. That is the spec, not an accident.
--   * "Replace deletes the previous item" is the one non-native behaviour. The game's own
--     occupied-slot handling is a SWAP: the old trash item ends up in the carried W_ClickAndDrop
--     widget (where an item exists ONLY as the widget's struct). So after every click on the
--     trash slot, a deferred pass classifies what happened -- and when the carry holds something
--     that (a) was not picked up FROM the trash and (b) displaced the previous occupant, it calls
--     the carry's own Destroy(): RemoveFromParent, no ground spawn, item gone.
--
-- CO-OP: everything here is local to each machine. Removing the carried item from the player's
-- real inventory is the game's own vanilla click path (whatever replication it does is what
-- chests already do for clients); our system is only ever a local buffer. Each player gets their
-- own trash; nobody else can see or touch it.
--
-- Crash-rule compliance (the gotchas ledger): hook bodies touch at most a GetFullName filter and
-- schedule; every UObject read is isValid-guarded; struct INSTANCES are never read (contents are
-- learned through GetAmtOfItem / Contains-one-Of class probes -- both marshal-safe); struct
-- arrays are only ever written through the game's ForceReplace bulk setter.
local F = {}
local ctx

local function tmap() return ctx.map.trash or {} end

local function cfg(key, fallback)
  local v = ctx.config.get(key)
  if v == nil then return fallback end
  return v
end

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function defer(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then onGameThread(fn) end
end

-- Schedule-ONLY defer for hook bodies (the qol/manual_save pattern): defer()'s fallback runs fn
-- inline, and a hook body must never run reflected work on the hook thread.
local function deferOnly(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then
    ctx.log.debug("trash: no delay scheduler; dropped deferred work")
  end
end

local function fullName(obj)
  local n
  pcall(function() n = obj:GetFullName() end)
  return n
end

-- Out-param values come back as RemoteUnrealParam userdata more often than not.
local function unwrap(v)
  if type(v) == "userdata" then pcall(function() v = v:get() end) end
  return v
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

--------------------------------------------------------------------- state
local S = {
  worldPc  = nil,   -- local controller fullname the wiring belongs to
  sys      = nil,   -- the detached BC_InventorySystem (the actual trash storage)
  chestW   = nil,   -- hidden W_ChestInventory: the slot's ParentInventoryWidget / sync driver
  slot     = nil,   -- our W_InventorySlot in the inventory window's grid
  slotName = nil,   -- its full object name (the click hook's filter)
  prevClass = nil,  -- UClass currently in the trash (nil = empty); Lua-side bookkeeping only
  prevName  = "",   -- its short name, for logs
  prevQty   = 0,
  pending   = false, -- a click pass is already scheduled
  linearOnly = false, -- Contains-one-Of's class-array param refused to marshal this session
  borderTried = false, -- SetBrushColor attempted (poison-latched once, never re-spammed)
}

local hooked = {}   -- key -> { preId, postId, path }

local function clearHooks()
  for key, h in pairs(hooked) do
    if type(h) == "table" and h.path then pcall(UnregisterHook, h.path, h[1], h[2]) end
    hooked[key] = nil
  end
end

local function armHook(inst, fnName, tag, body)
  if not (inst and fnName) then return false end
  local key = tostring(ctx.uehelp.className(inst)) .. ":" .. fnName
  if hooked[key] then return true end
  local path = fullFuncPath(inst, fnName)
  if not path then return false end
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if not ok then return false end
  hooked[key] = { pre, post, path = path }
  ctx.log.debug("trash: hooked " .. path)
  return true
end

--------------------------------------------------------------------- probes
-- Everything known about the trash's content is learned through class probes -- the slot structs
-- themselves are unreadable from Lua (the proven VM-wedge), but GetAmtOfItem takes a struct we
-- BUILD (marshal-proven direction) and matches by class only.

local function amtOf(cls)
  if not ctx.uehelp.isValid(cls) then return false, 0 end
  local m = tmap()
  local probe = {
    [m.slotItemField]     = cls,
    [m.slotQtyField]      = 0,
    [m.slotSavedataField] = "",
  }
  local out = {}
  local ok = ctx.uehelp.call(S.sys, m.sysAmtFn, probe, out)
  if not ok then return false, 0 end
  return true, tonumber(unwrap(out.Amount)) or 0
end

local function totalQty()
  local out = {}
  if not ctx.uehelp.call(S.sys, tmap().sysTotalFn, out) then return 0 end
  return tonumber(unwrap(out.TotalItems)) or 0
end

-- Does the trash hold any class in `list`? nil = the call itself failed (marshal refusal or a
-- stale system) -- callers must treat that as "unknown", never as "no".
local function containsAny(list)
  local out = {}
  local ok = ctx.uehelp.call(S.sys, tmap().sysContainsFn, list, out)
  if not ok then return nil end
  return unwrap(out.Contains) == true
end

-- All item-actor classes the game knows: the DB_Items map's keys. Fetched fresh per discovery
-- (a UClass wrapper cached across a world change is a stale pointer waiting to be dereferenced).
local function dbItemClasses()
  local m = tmap()
  local out = {}
  local gi = ctx.uehelp.findFirst(m.giClass)
  if not gi then return out end
  pcall(function()
    local db = gi[m.dbItemsProp]
    if db and db.ForEach then
      db:ForEach(function(k, _)
        local cls = k
        pcall(function() cls = k:get() end)
        if cls ~= nil then out[#out + 1] = cls end
      end)
    end
  end)
  return out
end

-- Narrow ~300 candidates to the one class in the trash. Pure bisection over the game's own
-- Contains-one-Of set probe (log2(n) calls); extracted so the algorithm is testable headless.
-- probe(sublist) -> true/false/nil(=call failed). Returns class or nil, plus false when the
-- probe path itself gave up (caller falls back to a linear scan).
function F.bisect(list, probe)
  if #list == 0 then return nil, true end
  local whole = probe(list)
  if whole == nil then return nil, false end
  if whole == false then return nil, true end
  while #list > 1 do
    local half = {}
    for i = 1, math.floor(#list / 2) do half[i] = list[i] end
    local hit = probe(half)
    if hit == nil then return nil, false end
    if hit then
      list = half
    else
      local rest = {}
      for i = math.floor(#list / 2) + 1, #list do rest[#rest + 1] = list[i] end
      list = rest
    end
  end
  return list[1], true
end

local function discoverClass()
  local classes = dbItemClasses()
  if #classes == 0 then
    ctx.log.warn("trash: DB_Items gave no classes; cannot identify the trashed item")
    return nil
  end
  if not S.linearOnly then
    local cls, probeAlive = F.bisect(classes, containsAny)
    if probeAlive then return cls end
    S.linearOnly = true
    ctx.log.info("trash: class-array probe refused to marshal; using linear scans this session")
  end
  for _, cls in ipairs(classes) do
    local ok, amt = amtOf(cls)
    if ok and amt > 0 then return cls end
  end
  return nil
end

--------------------------------------------------------------------- the click verdict
-- After the game has fully handled a click on the trash slot, decide what to do with the carry
-- widget. Pure and headless-testable; the caller gathers the five facts.
--   carryExists   a W_ClickAndDrop is live right now
--   senderIsTrash it was created by picking up FROM the trash (take-out / half-out)
--   occupiedNow   the backing slot holds something after the click
--   hadPrev       our bookkeeping says something was in the trash before the click
--   stillHasPrev  that previous class is still present (same-class stack/drip, or nothing landed)
-- "destroy" means: the carry is the swapped-out previous trash item -- delete it.
-- Anything uncertain answers "keep": a wrong keep is a quirk, a wrong destroy eats a player item.
function F.decide(carryExists, senderIsTrash, occupiedNow, hadPrev, stillHasPrev)
  if not carryExists then return "keep" end
  if senderIsTrash then return "keep" end
  if not occupiedNow then return "keep" end
  if not hadPrev then return "keep" end
  if stillHasPrev then return "keep" end
  return "destroy"
end

local function getCarry()
  local m = tmap()
  -- ONE out table: UE4SS writes EVERY out param into the first table sitting at an out-param
  -- position (live-proven on GetSystemAndIndex: two tables -> the first held System AND Index,
  -- the second stayed empty). Two tables here would leave Widget forever nil.
  local out = {}
  if not ctx.uehelp.call(S.slot, m.carryGetFn, out) then return nil end
  if unwrap(out.Success) ~= true then return nil end
  local w = unwrap(out.Widget)
  if not ctx.uehelp.isValid(w) then return nil end
  return w
end

--------------------------------------------------------------------- display
local function tint()
  if not ctx.uehelp.isValid(S.slot) then return end
  local m = tmap()
  local c = m.tint or { 1.0, 0.30, 0.30, 1.0 }
  local col = { R = c[1], G = c[2], B = c[3], A = c[4] }
  local okB, bg = ctx.uehelp.get(S.slot, m.slotBgProp)
  if okB and ctx.uehelp.isValid(bg) then
    pcall(function() bg:SetColorAndOpacity(col) end)
  end
  -- The selection border doubles as a literal red outline. SetBrushColor is a plain slate-brush
  -- setter (struct param, no FName) but it has never run on this build -- poison-latch its first
  -- call, and never spam the attempt on every repaint.
  if not S.borderTried then
    S.borderTried = true
    local okBo, border = ctx.uehelp.get(S.slot, m.slotBorderProp)
    if okBo and ctx.uehelp.isValid(border) then
      ctx.log.risky("trash.borderbrush", function()
        border:SetBrushColor(col)
        border:SetVisibility(4)   -- SelfHitTestInvisible: outline always on, clicks pass through
      end)
    end
  end
end

local function syncDisplay()
  if not (ctx.uehelp.isValid(S.chestW) and ctx.uehelp.isValid(S.slot)) then return end
  ctx.uehelp.call(S.chestW, tmap().chestSyncFn)
  tint()
end

--------------------------------------------------------------------- bookkeeping
local function rebook(qty)
  if qty <= 0 then
    if S.prevClass then ctx.log.debug("trash: now empty") end
    S.prevClass, S.prevName, S.prevQty = nil, "", 0
    return
  end
  if S.prevClass then
    local ok, amt = amtOf(S.prevClass)
    if ok and amt > 0 then S.prevQty = qty; return end
  end
  local cls = discoverClass()
  S.prevClass, S.prevQty = cls, qty
  S.prevName = ""
  if cls then pcall(function() S.prevName = cls:GetFName():ToString() end) end
  if cls then
    ctx.log.info("trash: holding " .. qty .. "x " .. S.prevName .. " (queued for deletion)")
  else
    ctx.log.warn("trash: occupied but the content's class could not be identified")
  end
end

-- The deferred pass after every click on the trash slot: classify what the game's own click
-- handling just did, destroy the swapped-out item when a replace happened, resync the display.
local function onTrashClick()
  S.pending = false
  if not (ctx.uehelp.isValid(S.sys) and ctx.uehelp.isValid(S.slot)) then return end
  local m = tmap()
  local qty = totalQty()
  local occupied = qty > 0
  local hadPrev = S.prevClass ~= nil

  local stillHasPrev = false
  if hadPrev then
    local ok, amt = amtOf(S.prevClass)
    -- a failed probe means "unknown" -- and unknown must land on the keep side of decide()
    stillHasPrev = (not ok) or amt > 0
  end

  local carry = getCarry()
  local senderIsTrash = false
  if carry then
    local okS, sender = ctx.uehelp.get(carry, m.carrySenderProp)
    senderIsTrash = (okS and ctx.uehelp.isValid(sender)
                     and ctx.uehelp.sameObject(sender, S.slot)) or false
  end

  if F.decide(carry ~= nil, senderIsTrash, occupied, hadPrev, stillHasPrev) == "destroy" then
    ctx.uehelp.call(carry, m.carryDestroyFn)
    ctx.log.info("trash: destroyed " .. S.prevQty .. "x " .. S.prevName .. " (replaced)")
  end
  rebook(qty)
  syncDisplay()
end

--------------------------------------------------------------------- building the slot
-- Returns ok, rebuilt. `rebuilt` is true whenever the chest widget was (re)created, (re)parked
-- in the viewport, or the system was (re)constructed -- in every one of those cases anything the
-- slot widget learned about the old objects (parent stamp, ChestSlots) is stale and the caller
-- must retire and remake the slot.
local function buildBacking(pc)
  local m = tmap()
  local rebuilt = false
  if not ctx.uehelp.isValid(S.chestW) then
    local cls = ctx.uehelp.classByName(m.chestUiClass, m.chestUiPath)
    if not cls then ctx.log.debug("trash: " .. tostring(m.chestUiClass) .. " not resident yet"); return false end
    local wbl = StaticFindObject and StaticFindObject(m.wblPath)
    if not wbl then ctx.log.warn("trash: no WidgetBlueprintLibrary"); return false end
    local w
    pcall(function() w = wbl:Create(pc, cls, pc) end)
    if not ctx.uehelp.isValid(w) then ctx.log.warn("trash: hidden chest widget create failed"); return false end
    S.chestW = w
    rebuilt = true
  end
  -- Park it in the viewport: the SObjectWidget the viewport holds is the GC root that keeps the
  -- pair alive (a bare wbl:Create widget was collected within a minute, live-proven). Collapsed
  -- means it is never laid out, painted or hit-tested. Construct fires during AddToViewport and
  -- rewrites ChestSlots -- which is why any (re)park reports `rebuilt`.
  local inVp = false
  pcall(function() inVp = S.chestW:IsInViewport() end)
  if not inVp then
    pcall(function() S.chestW:AddToViewport(0) end)
    pcall(function() S.chestW:SetVisibility(1) end)   -- 1 = Collapsed
    local nowVp = false
    pcall(function() nowVp = S.chestW:IsInViewport() end)
    if not nowVp then
      ctx.log.warn("trash: chest widget refused the viewport; GC would eat it -- disabled this pass")
      return false
    end
    rebuilt = true
  end
  if not ctx.uehelp.isValid(S.sys) then
    local scls = ctx.uehelp.classByName(m.invSysClass, m.invSysPath)
    if not scls then ctx.log.warn("trash: " .. tostring(m.invSysClass) .. " not resident"); return false end
    local sys
    pcall(function() sys = StaticConstructObject(scls, S.chestW) end)
    if not ctx.uehelp.isValid(sys) then ctx.log.warn("trash: inventory system construct failed"); return false end
    local arr = {}
    for i = 1, m.backingSize do arr[i] = {} end
    ctx.uehelp.call(sys, m.sysReplaceFn, arr, false)
    ctx.uehelp.set(sys, m.sysSizeProp, m.backingSize)
    -- length read-back is the only trustworthy verdict on whether the bulk write landed
    local len = 0
    pcall(function() len = #sys[m.sysInvProp] end)
    if len ~= m.backingSize then
      ctx.log.warn("trash: backing inventory sized " .. len .. " (wanted " .. m.backingSize .. "); disabled")
      return false
    end
    S.sys = sys
    rebuilt = true
    -- a fresh system is empty: whatever the books said was in the trash no longer exists
    if S.prevClass then
      ctx.log.info("trash: backing store was rebuilt; the queued " .. S.prevName .. " is gone")
    end
    S.prevClass, S.prevName, S.prevQty = nil, "", 0
  end
  -- always re-stamped: cheap, and a re-park must never leave the ref pointing anywhere stale
  ctx.uehelp.set(S.chestW, m.chestInvRefProp, S.sys)
  return true, rebuilt
end

local function slotStillPlaced(grid)
  if not ctx.uehelp.isValid(S.slot) then return false end
  local parent
  pcall(function() parent = S.slot:GetParent() end)
  return ctx.uehelp.isValid(parent) and ctx.uehelp.sameObject(parent, grid)
end

local function buildSlot(pc, grid)
  local m = tmap()
  local cdoPath = (m.slotFactoryLibPath or ""):gsub("%.([^%.]+)$", ".Default__%1")
  local lib = StaticFindObject and StaticFindObject(cdoPath)
  if not (lib and ctx.uehelp.isValid(lib)) then
    ctx.log.debug("trash: slot factory library not resident yet")
    return false
  end
  local before = 0
  pcall(function() before = grid:GetChildrenCount() end)
  -- Signature (UAssetAPI param order, live-burned 2026-07-28): ParentWidget, OwningPlayer,
  -- ItemGrid, RowCount, ColumnCount, __WorldContext, out ItemSlots. ParentWidget is FIRST --
  -- passing pc there stamps the slot's interface ref with a controller, and every click then
  -- resolves to (None, 0): deposits silently no-op and nothing roots the chest widget.
  if not ctx.uehelp.call(lib, m.slotFactoryFn, S.chestW, pc, grid, 1, 1, S.chestW, {}) then return false end
  local after = 0
  pcall(function() after = grid:GetChildrenCount() end)
  if after ~= before + 1 then
    ctx.log.warn("trash: slot factory changed the grid by " .. (after - before) .. " children")
    if after <= before then return false end
  end
  local slot
  pcall(function() slot = grid:GetChildAt(after - 1) end)
  if not ctx.uehelp.isValid(slot) then return false end
  S.slot = slot
  S.slotName = fullName(slot)
  S.borderTried = false
  ctx.uehelp.call(S.slot, m.slotIndexFn, m.backingIndex)
  -- ChestSlots gets the same widget at EVERY index: FillInventoryInGridPanel walks the backing
  -- array indexing this array in lockstep, so index 51's display must land on our one widget
  -- (and land LAST, which also restamps SetItemIndexInInventory(51)).
  local refs = {}
  for i = 1, m.backingSize do refs[i] = S.slot end
  if not ctx.uehelp.set(S.chestW, m.chestSlotsProp, refs) then
    ctx.log.warn("trash: ChestSlots assignment failed; slot left inert")
    return false
  end
  ctx.log.info("trash: slot built (backing index " .. m.backingIndex .. ")")
  return true
end

local function placeSlot(slotCount)
  local m = tmap()
  local cols = tonumber(m.gridCols) or 7
  local rows = math.max(1, math.floor(slotCount / cols))
  local okPS, ps = ctx.uehelp.get(S.slot, m.widgetSlotProp)
  if not (okPS and ctx.uehelp.isValid(ps)) then return end
  ctx.uehelp.call(ps, m.gridSlotRowFn, rows - 1)
  ctx.uehelp.call(ps, m.gridSlotColFn, cols)   -- one column past the bag = right of bottom-right
end

--------------------------------------------------------------------- arming
local ensure   -- forward declaration (the toggle hook body schedules it)

-- Armed the moment a controller exists -- BEFORE any widget checks can bail -- because this hook
-- is what brings ensure() back on the first inventory open (the grid may not exist until then).
-- Body touches no UObjects: qol's own ship key calls ToggleInventory, and hooks our own Lua can
-- trigger must only schedule.
local function armControllerHooks(pc)
  armHook(pc, tmap().toggleInvFn, "trash.inv", function()
    deferOnly(150, function() onGameThread(function() ensure("toggle") end) end)
  end)
end

-- The click watcher: OnMouseButtonDown is the one ProcessEvent funnel every slot click takes.
-- Fires for EVERY W_InventorySlot in the game; the body filters on our instance's full name and
-- only ever schedules (the GetFullName filter is the same shape manual_save's click hook has run
-- live since 07-26). Registered once our slot exists (the path resolves off its class).
local function armSlotHook()
  armHook(S.slot, tmap().slotMouseFn, "trash.click", function(Context)
    local obj
    pcall(function() obj = Context:get() end)
    if not obj then return end
    local nm
    pcall(function() nm = obj:GetFullName() end)
    if nm ~= S.slotName then return end
    if S.pending then return end
    S.pending = true
    deferOnly(80, function()
      local ok, err = pcall(onTrashClick)
      if not ok then
        S.pending = false
        ctx.log.warn("trash: click pass failed: " .. tostring(err))
      end
    end)
  end)
end

-- Everything the feature needs, (re)established whenever the world might be new or the window
-- might have rebuilt. Cheap and idempotent; every step fast-outs once its work stands.
ensure = function(why)
  if not cfg("trash_slot", true) then return end
  local m = tmap()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not ctx.uehelp.isValid(pc) then return end

  -- a new local controller instance = a world was (re)loaded: every object and registration
  -- from the last world is dead, and the trash's content is forgotten BY DESIGN (the spec's
  -- logout rule). Bookkeeping resets with it.
  local pcName = fullName(pc)
  if pcName and pcName ~= S.worldPc then
    S.worldPc = pcName
    clearHooks()
    S.sys, S.chestW, S.slot, S.slotName = nil, nil, nil, nil
    S.prevClass, S.prevName, S.prevQty = nil, "", 0
    S.pending, S.linearOnly, S.borderTried = false, false, false
  end
  armControllerHooks(pc)

  local okW, piw = ctx.uehelp.get(pc, m.invUiProp)
  if not (okW and ctx.uehelp.isValid(piw)) then return end
  local okG, grid = ctx.uehelp.get(piw, m.invGridProp)
  if not (okG and ctx.uehelp.isValid(grid)) then return end
  local slotCount = 0
  pcall(function() slotCount = #piw[m.invSlotsProp] end)
  if slotCount < (tonumber(m.gridCols) or 7) then return end  -- grid not built yet; next open retries

  local okB, backingRebuilt = buildBacking(pc)
  if not okB then return end
  if backingRebuilt and ctx.uehelp.isValid(S.slot) then
    -- The surviving slot was wired to pre-rebuild objects: its factory-stamped parent interface
    -- ref and/or the chest's ChestSlots array are stale, and a click through a stale interface
    -- pointer is a native crash. Retire it; the factory makes a correctly-wired replacement
    -- below. (The click hook stays -- it filters on S.slotName, which the rebuild updates.)
    pcall(function() S.slot:RemoveFromParent() end)
    S.slot, S.slotName = nil, nil
  end
  if not slotStillPlaced(grid) then
    -- the slot is gone (first run, a backing rebuild, or ExpandGrid's ClearChildren). The
    -- backing SYSTEM survives slot rebuilds, so the trash content rides through this.
    if not buildSlot(pc, grid) then return end
    armSlotHook()
  end
  placeSlot(slotCount)
  syncDisplay()
  ctx.log.debug("trash: ensured (" .. tostring(why) .. "), bag slots " .. slotCount)
end

--------------------------------------------------------------------- dev surface
-- Exec-channel smoke hooks (tools/run.py deploys dev; a player install never calls these).
-- _pass runs the same deferred pass a real click schedules; _state answers without UObject risk.
function F._pass() onTrashClick() end
function F._ensure(why) ensure(why or "dev") end
function F._state()
  return {
    slot = ctx.uehelp.isValid(S.slot) or false,
    sys = ctx.uehelp.isValid(S.sys) or false,
    chest = ctx.uehelp.isValid(S.chestW) or false,
    prevName = S.prevName, prevQty = S.prevQty,
    hasPrev = S.prevClass ~= nil,
    linearOnly = S.linearOnly,
    slotName = S.slotName,
  }
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "trash_slot", {
        "trash.invUiProp", "trash.invGridProp", "trash.invSlotsProp", "trash.slotMouseFn",
        "trash.slotIndexFn", "trash.carryGetFn", "trash.carryDestroyFn", "trash.carrySenderProp",
        "trash.chestUiClass", "trash.chestUiPath", "trash.chestSlotsProp", "trash.chestInvRefProp",
        "trash.chestSyncFn", "trash.invSysClass", "trash.invSysPath", "trash.sysReplaceFn",
        "trash.sysAmtFn", "trash.sysTotalFn", "trash.sysContainsFn", "trash.sysClearAtFn",
        "trash.slotFactoryLibPath", "trash.slotFactoryFn", "trash.wblPath",
        "trash.backingSize", "trash.backingIndex", "trash.giClass", "trash.dbItemsProp",
        "trash.toggleInvFn", "trash.slotItemField", "trash.slotQtyField", "trash.slotSavedataField",
      }) then
    return false
  end
  if not cfg("trash_slot", true) then
    ctx.log.info("trash: disabled (trash_slot = false)")
    return true
  end

  -- world entry rides the shared Engine.Character notify, coalesced exactly like manual_save's
  -- copy: a save load fires it once per streamed-in animal and one pending check answers them all.
  local pending = false
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    if pending then return end
    pending = true
    defer(2500, function()
      pending = false
      onGameThread(function() ensure("world") end)
    end)
  end)
  -- hot reload mid-session: the world may already be up
  defer(2000, function() onGameThread(function() ensure("boot") end) end)
  defer(12000, function() onGameThread(function() ensure("boot2") end) end)

  pcall(function()
    RegisterConsoleCommandHandler("sps_trash", function()
      if not ctx.uehelp.isValid(S.sys) then
        ctx.log.info("trash: not built yet (open the inventory once in a world)")
        return true
      end
      onGameThread(function()
        local qty = totalQty()
        ctx.log.info(string.format("trash: %s%s (slot %s, probes %s)",
          qty > 0 and (qty .. "x " .. (S.prevName ~= "" and S.prevName or "?")) or "empty",
          qty > 0 and " -- queued for deletion" or "",
          ctx.uehelp.isValid(S.slot) and "live" or "missing",
          S.linearOnly and "linear" or "bisect"))
      end)
      return true
    end)
    RegisterConsoleCommandHandler("sps_trash_clear", function()
      onGameThread(function()
        if not ctx.uehelp.isValid(S.sys) then return end
        ctx.uehelp.call(S.sys, tmap().sysClearAtFn, tmap().backingIndex)
        ctx.log.info("trash: cleared" .. (S.prevName ~= "" and (" (" .. S.prevName .. " gone)") or ""))
        rebook(0)
        syncDisplay()
      end)
      return true
    end)
  end)

  ctx.log.info("trash: slot armed (red cell right of the bag; last item in is recoverable "
    .. "until replaced or logout)")
  return true
end

return F
