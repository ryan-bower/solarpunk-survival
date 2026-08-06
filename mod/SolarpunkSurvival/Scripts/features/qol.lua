-- Quality-of-life batch (2026-07-26, overnight request): bigger chests, backpack inventory,
-- crouching, the airship's chest + inventory-while-flying + faster recall, the hotbar pulled up
-- to the open inventory, the pickup feed moved to mid-screen, dressed pings, and named/colored
-- player icons on the map.
--
-- Ground rules this module inherits from the crash post-mortems (see the gotchas memory):
--   * construction-notify work is DEFERRED off the notify thread (components may not exist yet
--     mid-construction, and a dying object mid-teardown is a native AV pcall cannot catch);
--   * hook bodies that OUR OWN Lua can trigger (ToggleInventory below) touch no UObjects --
--     they only schedule;
--   * no dynamic materials, no attach family, no timers polling UObjects. Colors come from the
--     game's own cooked materials (SetMaterial on STATIC mesh comps is the proven-safe path).
local F = {}
local ctx

local function qmap() return ctx.map.qol or {} end

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function defer(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then onGameThread(fn) end
end

-- Schedule-ONLY defer, for hook bodies. defer()'s fallback runs fn inline, and inline is the one
-- thing a hook body may never do here: our own Lua re-enters these hooks (openInvOnShip calls
-- ToggleInventory), so the fallback would run widget reads and SetRenderTranslation on the hook
-- thread -- the re-entrant hook-body-touches-UObjects shape that native-crashes uncatchably.
-- If there is no scheduler, the work is dropped: a hotbar that misses one sync beats a dead game.
local function deferOnly(ms, fn)
  if pcall(ExecuteWithDelay, ms, fn) then return true end
  ctx.log.debug("qol: no delay scheduler; skipped deferred work (hook bodies never run inline)")
  return false
end

-- Resolve a UFunction's full object path off a live instance (RegisterHook rejects short
-- "Class:Fn"). Mirrors features/storms.fullFuncPath.
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

-- Call a fn whose ONLY parameter is an out (the "IsControllingAirship?" shape): UE4SS wants a
-- fresh Lua table in the out slot and writes the result into it.
local function callOut1(obj, fnName)
  local out = {}
  local ok = ctx.uehelp.call(obj, fnName, out)
  if not ok then return nil end
  local v = rawget(out, 1)
  if v == nil then
    local _, first = next(out)
    v = first
  end
  if type(v) == "userdata" then pcall(function() local g = v:get(); v = g end) end
  return v
end

local function callOutBool(obj, fnName)
  local v = callOut1(obj, fnName)
  if type(v) == "boolean" then return v end
  return nil
end

local function localController()
  local pl = ctx.map.player
  return ctx.uehelp.localController(pl and pl.controllerClass) or ctx.uehelp.playerController()
end

-- Cooked-material loader (the wand/evil_animals pattern: find by name, LoadAsset the path on a
-- miss, re-find -- LoadAsset's return value is not trusted).
local matCache  = {}    -- name -> the material, once found
local matMissAt = {}    -- name -> os.clock() of the last failed lookup
local MAT_RETRY = 20    -- seconds before a miss is worth another look

local function matByName(name, dirOverride)
  if not name then return nil end
  local hit = matCache[name]
  if hit then
    if ctx.uehelp.isValid(hit) then return hit end
    matCache[name] = nil
  end
  -- A miss is REMEMBERED, never latched. The first ping of a session routinely fires before the
  -- palette package is in memory, and caching `false` for good meant that one early miss left
  -- that player's pings untinted for the rest of the session -- and only on that machine, so
  -- host and clients disagreed about ping colors, which is the one thing the palette must not do.
  local at = matMissAt[name]
  if at and (os.clock() - at) < MAT_RETRY then return nil end
  local function find()
    for _, kind in ipairs({ "Material", "MaterialInstanceConstant" }) do
      local ok, m = pcall(FindObject, kind, name)
      if ok and m and ctx.uehelp.isValid(m) then return m end
    end
    return nil
  end
  local mt = find()
  local dir = dirOverride or (ctx.map.wand and ctx.map.wand.materialDir)
  if not mt and dir and LoadAsset then
    pcall(LoadAsset, dir .. name .. "." .. name)
    mt = find()
  end
  if mt then matCache[name], matMissAt[name] = mt, nil
  else matMissAt[name] = os.clock() end
  return mt
end

-- Stable per-player palette slot, identical on every machine (a plain deterministic hash of the
-- player's name -- join order would disagree between host and clients).
local function paletteFor(name)
  local pal = qmap().palette or {}
  if #pal == 0 then return nil end
  local h = 0
  for i = 1, #tostring(name) do h = (h * 31 + tostring(name):byte(i)) % 65521 end
  return pal[(h % #pal) + 1]
end

-- Live instances of a class, and ONLY live ones. FindAllOf hands back the class default object
-- ("Default__BP_Foo_C") as well, and for widgets the archetype living in the class's :WidgetTree.
-- Neither is a thing on screen or in the world, and both are worse than useless to write to: a
-- property set on a template is inherited by every instance built afterwards, so scaling a dock's
-- timeline or replacing a chest's inventory array on the CDO silently rewrites the class itself.
local function liveInstances(className)
  local out = {}
  for _, o in ipairs(ctx.uehelp.findAll(className)) do
    if ctx.uehelp.isValid(o) then
      local full; pcall(function() full = o:GetFullName() end)
      if full and not full:find("Default__", 1, true) and not full:find(":WidgetTree", 1, true) then
        out[#out + 1] = o
      end
    end
  end
  return out
end

--------------------------------------------------------------------- chests hold double
-- The chest UI builds its grid from the Inventory ARRAY's length (offline RE of
-- W_ChestInventory: FillInventoryInGridPanel is Array_Length-driven; InventorySize is never
-- consulted), and nothing in the game grows that array at runtime -- it is born from the
-- component template's 12-entry default or from save JSON. So doubling = handing the game a
-- 24-entry array through its own bulk setter, "ForceReplace Inventory" (proven live
-- 2026-07-26: a Lua array of default-init slot tables marshals fine, len 12 -> 24, saved).
--
-- ONLY EMPTY chests are grown: rebuilding an occupied array would need per-slot struct READS,
-- and struct-array element access from Lua hard-wedges the Lua thread (proven live the same
-- night -- the probe froze the scheduler). An occupied chest doubles on the next pass after
-- it is emptied; fresh-placed chests are empty and double immediately. Host-only: the array
-- replicates to clients via the component's own OnRep_Inventory.
local chestSized = {}   -- inventory-system fullname -> true once grown (skip repeats)
local chestGrowFails = {} -- fullname -> abort count; three strikes and the chest is left alone
local sweepChests       -- forward: the shuffle re-arms the sweep to reach the next occupied chest
local shuffledThisPass = false

-- Game-side slot count (int out-params marshal fine; the ARRAY is never touched from Lua).
local function freeSlotCount(comp)
  local out = {}
  if not pcall(function() comp:GetNrOfFreeSlots(out) end) then return nil end
  local _, v = next(out)
  return tonumber(v)
end

-- Resize an OCCUPIED chest (grow OR shrink). The blocker was never ForceReplace -- it was that
-- rebuilding an occupied array needs the old slots, and reading struct-array elements from Lua
-- wedges the scheduler (proven live). The end-run (offline RE 2026-07-27 of BC_InventorySystem):
-- the game moves slots BETWEEN inventories by INDEX -- MoveItemDiffInv(TargetInventory,
-- OriginIndex, TargetIndex), plain BlueprintCallable, no reads required on our side. So: stand
-- up a buffer chest ON the same spot, move the slots across game-side, ForceReplace the
-- now-EMPTY chest to the new size, move the slots back, destroy the buffer (K2_DestroyActor --
-- the killGlow-proven call). Every phase is verified by GetNrOfFreeSlots counts, and on any
-- miscount the shuffle stops WITH the items wherever they are -- worst case the player finds a
-- second chest standing in the same spot holding their goods, never a deletion.
--
-- SHRINK (the sorting chest went 42 -> 21, user 2026-08-06) adds two rules: it refuses when the
-- chest holds more stacks than the smaller size seats, and before moving back it runs the
-- game's own Sort on the buffer (the chest UI's Sort button call) so every stack is compacted
-- into the low indexes the smaller array still has. If Sort ever stops compacting, the tail
-- stacks simply stay in the buffer chest standing on the same spot -- visible, never deleted.
local function growOccupied(chest, comp, fn, len, want, free)
  if not ctx.config.get("qol_chest_grow_occupied") then return false end
  if ctx.log.isPoisoned("chest:spawn") then return false end
  local used = len - free
  if used > want then
    ctx.log.warn("qol: chest holds " .. used .. " stacks, more than the target " .. want ..
                 " slots -- take some out and it will resize on its own")
    return false
  end
  local cls = ctx.uehelp.classByName(qmap().chestClass,
    qmap().chestClassPath and (qmap().chestClassPath .. "." .. qmap().chestClass) or nil)
  local loc; pcall(function() loc = ctx.uehelp.vec(chest:K2_GetActorLocation()) end)
  if not (cls and loc) then return false end

  local buffer
  ctx.log.step("qol.chest.buffer")
  ctx.log.risky("chest:spawn", function()
    buffer = ctx.uehelp.spawnActorAt(ctx.uehelp.playerController() or chest, cls, loc)
  end)
  if not ctx.uehelp.isValid(buffer) then return false end
  local okB, bComp = ctx.uehelp.get(buffer, ctx.map.wand and ctx.map.wand.inventorySystemProp or "InventorySystem")
  if not (okB and ctx.uehelp.isValid(bComp)) then
    pcall(function() buffer:K2_DestroyActor() end)
    return false
  end
  -- The buffer is OURS -- blind the chest-spawn notify to it immediately. A destroyed buffer
  -- lingers until GC with isValid still true and garbage free-slot counts, so a notify-driven
  -- sizeChest on it takes the occupied path and spawns ANOTHER buffer, whose notify does the
  -- same: live 2026-07-27, 1190 abort warns in 14 s until GC broke the chain.
  local bFn; pcall(function() bFn = bComp:GetFullName() end)
  if bFn then chestSized[bFn] = true end
  local bLen = -1
  pcall(function() bLen = #bComp.Inventory end)   -- length-only read is proven safe
  if bLen < len then
    -- A fresh buffer is a STOCK chest (12 slots): a source already grown past that would
    -- never fit, so every occupied re-grow (e.g. 24 -> a larger qol_chest_size) aborted three
    -- times and latched. The buffer is empty by construction, so the proven empty-grow applies.
    local barr = {}
    for i = 1, len do barr[i] = {} end
    if ctx.uehelp.call(bComp, "ForceReplace Inventory", barr, true) == true then
      ctx.uehelp.set(bComp, qmap().invSizeProp or "InventorySize", len)
      pcall(function() bLen = #bComp.Inventory end)
    end
  end
  if bLen < len then
    pcall(function() buffer:K2_DestroyActor() end)
    return false
  end

  ctx.log.step("qol.chest.shuffle.out")
  for i = 0, len - 1 do ctx.uehelp.call(comp, "MoveItemDiffInv", bComp, i, i) end
  local cFree, bFree = freeSlotCount(comp), freeSlotCount(bComp)
  if cFree ~= len or bFree ~= bLen - used then
    -- counts disagree: put everything back and leave the chest alone
    ctx.log.step("qol.chest.shuffle.rollback")
    for i = 0, len - 1 do ctx.uehelp.call(bComp, "MoveItemDiffInv", comp, i, i) end
    if freeSlotCount(bComp) == bLen then pcall(function() buffer:K2_DestroyActor() end) end
    ctx.log.warn("qol: occupied-chest grow aborted (moved out: chest free " .. tostring(cFree) ..
                 "/" .. len .. ", buffer free " .. tostring(bFree) .. "/" .. bLen ..
                 ", expected " .. (bLen - used) .. "); chest untouched")
    return false
  end

  if want < len then
    -- shrinking: compact the buffer game-side (the chest UI's own Sort button call) so all
    -- `used` stacks sit below index `want` before the smaller array is stood up
    ctx.log.step("qol.chest.shuffle.sort")
    if ctx.uehelp.call(bComp, "Sort", 0) ~= true then
      ctx.log.step("qol.chest.shuffle.rollback")
      for i = 0, len - 1 do ctx.uehelp.call(bComp, "MoveItemDiffInv", comp, i, i) end
      if freeSlotCount(bComp) == bLen then pcall(function() buffer:K2_DestroyActor() end) end
      ctx.log.warn("qol: buffer Sort refused during a chest shrink; chest untouched")
      return false
    end
  end
  local arr = {}
  for i = 1, want do arr[i] = {} end
  ctx.log.step("qol.chest.shuffle.grow")
  if ctx.uehelp.call(comp, "ForceReplace Inventory", arr, true) ~= true then
    for i = 0, len - 1 do ctx.uehelp.call(bComp, "MoveItemDiffInv", comp, i, i) end
    if freeSlotCount(bComp) == bLen then pcall(function() buffer:K2_DestroyActor() end) end
    return false
  end
  ctx.uehelp.set(comp, qmap().invSizeProp or "InventorySize", want)

  ctx.log.step("qol.chest.shuffle.back")
  -- a shrunk chest only HAS `want` indexes; after the compaction every stack lives below that
  for i = 0, math.min(len, want) - 1 do ctx.uehelp.call(bComp, "MoveItemDiffInv", comp, i, i) end
  if freeSlotCount(bComp) == bLen then
    pcall(function() buffer:K2_DestroyActor() end)
  else
    -- items still in the buffer: LEAVE IT (it stands on the chest's spot, contents intact)
    ctx.log.warn("qol: some items stayed in the transfer chest standing at the same spot -- " ..
                 "take them out and it can be demolished")
  end
  chestSized[fn] = true
  ctx.log.info("qol: occupied chest resized " .. len .. " -> " .. want .. " slots (" .. used .. " stacks ride along)")
  return true
end

local function sizeChest(chest, wantOverride)
  local want = tonumber(wantOverride) or tonumber(ctx.config.get("qol_chest_size")) or 0
  if want <= 0 or not ctx.net.isHost() then return end
  if not ctx.uehelp.isValid(chest) then return end
  -- Component var NAMES differ per Blueprint (the sorting chest is a furnace clone whose
  -- inventory lives under "BC_InventorySystem", not "InventorySystem" -- root-caused live
  -- 2026-07-30), so fall through the same alt list the chest ledger uses.
  local comp
  local names = { ctx.map.wand and ctx.map.wand.inventorySystemProp or "InventorySystem" }
  for _, alt in ipairs((ctx.map.stock and ctx.map.stock.invPropAlts) or {}) do
    if alt ~= names[1] then names[#names + 1] = alt end
  end
  for _, n in ipairs(names) do
    local ok2, c = ctx.uehelp.get(chest, n)
    if ok2 and ctx.uehelp.isValid(c) then comp = c break end
  end
  if not comp then return end
  local fn; pcall(function() fn = comp:GetFullName() end)
  -- never the class template: ForceReplace on the CDO's component would hand a 24-slot array to
  -- every chest the game builds (and to the save serializer) from then on
  if not fn or chestSized[fn] or fn:find("Default__", 1, true) then return end
  local len = -1
  pcall(function() len = #comp.Inventory end)
  if len <= 0 then return end
  if len == want then
    -- The array is already right -- but the two can fall out of step: a chest was found
    -- live carrying a 24-slot Inventory with InventorySize still reading 12 (the array grew in
    -- an earlier pass and the count write did not land). Keep the declared size honest, or the
    -- game is told a 24-slot chest only holds 12.
    local sizeProp = qmap().invSizeProp or "InventorySize"
    local okS, size = ctx.uehelp.get(comp, sizeProp)
    if okS and tonumber(size) and tonumber(size) ~= len then
      ctx.uehelp.set(comp, sizeProp, len)
      ctx.log.info("qol: chest InventorySize " .. tostring(size) .. " -> " .. len .. " (repaired)")
    end
    chestSized[fn] = true
    return
  end
  local free = freeSlotCount(comp)
  if free == nil then return end
  if free ~= len then
    -- OCCUPIED: the buffer shuffle (user 2026-07-27: "double chests should work for all existing
    -- chests, not just newly placed ones"). At most one ATTEMPT per sweep pass -- each is ~26
    -- game calls -- and the re-arm reaches the next occupied chest. Attempts are capped per
    -- chest: a chest that aborts three times is a zombie (destroyed pre-GC, garbage counts) or
    -- genuinely stuck, and retrying it spawns a buffer every pass.
    if not shuffledThisPass then
      shuffledThisPass = true
      if not growOccupied(chest, comp, fn, len, want, free) then
        chestGrowFails[fn] = (chestGrowFails[fn] or 0) + 1
        if chestGrowFails[fn] >= 3 then
          chestSized[fn] = true
          ctx.log.warn("qol: occupied chest failed to grow 3 times; leaving it at " .. len .. " slots")
        end
      end
      deferOnly(1500, sweepChests)
    end
    return
  end
  local arr = {}
  for i = 1, want do arr[i] = {} end
  local okR = ctx.uehelp.call(comp, "ForceReplace Inventory", arr, true)
  if okR then
    ctx.uehelp.set(comp, qmap().invSizeProp or "InventorySize", want)
    chestSized[fn] = true
    ctx.log.info("qol: chest resized " .. len .. " -> " .. want .. " slots")
  end
end

sweepChests = function()
  shuffledThisPass = false
  for _, c in ipairs(liveInstances(qmap().chestClass)) do sizeChest(c) end
  -- The sorting chest sizes like a chest but to its OWN target: 3 rows of 7 (user 2026-08-06,
  -- "reduce the inv of the autosort chest down to 3 rows" -- it is a working buffer, not bulk
  -- storage). The same pass heals 2-slot pre-template sorters up and 42-slot ones down.
  local sc = ctx.map.sortchest and ctx.map.sortchest.class
  local sw = tonumber(ctx.config.get("sort_chest_size")) or 0
  if sc and sw > 0 then for _, c in ipairs(liveInstances(sc)) do sizeChest(c, sw) end end
end

--------------------------------------------------------------------- backpack: a bigger pack
-- Is this FGuid all zeroes? An unlinked BC_InventorySystem carries the null GUID, and everything
-- it saves lands in a nowhere-entry keyed 0 that no load ever reads back.
local function nullGuid(g)
  if not g then return true end
  local ok, zero = pcall(function()
    return (g.A or 0) == 0 and (g.B or 0) == 0 and (g.C or 0) == 0 and (g.D or 0) == 0
  end)
  return ok and zero or false
end

-- Stamp the tier into the controller's Playerdata, which is the ONLY thing the save records --
-- SetInventoryUpgradeLevel just grows the live array. Getting this wrong does not merely lose the
-- bigger pack, it silently destroys the whole player save, because BP_MainPlayerCharacter's
-- "Apply Playerdata" restores inventory + inventory-GUID link + Health + Hunger + Thirst + effects
-- in ONE all-or-nothing branch gated on
--     len(saved inventory) == GetInvLengthForBackpackUpgradeTier(saved InventoryUpgrades)
-- (tier 0/1/3/7 -> 29/36/43/50 slots). Raising the live pack to tier 3 without stamping the tier
-- writes a 43-slot array against a tier-0 record, so every later load takes the else branch, prints
-- "<pawn> failed to load Inventory from save", and never reaches SetInventoryID -- after which the
-- pawn's InventoryID stays null and every save disappears into the GUID-0 entry. Location and
-- chests keep working throughout (both are applied elsewhere), which is exactly how this hid.
local function recordedTier()
  local q, pc = qmap(), localController()
  if not (pc and q.playerdataProp and q.playerdataTierField) then return nil end
  local cur
  pcall(function()
    local ok, pd = ctx.uehelp.get(pc, q.playerdataProp)
    if ok and pd then cur = tonumber(pd[q.playerdataTierField]) end
  end)
  return cur
end

local function stampBackpackTier(lvl)
  local q, pc = qmap(), localController()
  if not (pc and q.backpackTierFn and q.playerdataProp and q.playerdataTierField) then return end
  local cur = recordedTier()
  if cur == lvl then return end               -- already recorded; do not churn the save
  if ctx.uehelp.call(pc, q.backpackTierFn, lvl) then
    ctx.log.info("qol: backpack tier " .. lvl .. " written to the player save (was " ..
      tostring(cur) .. ")")
  end
end

-- Re-link a pawn whose InventoryID never got stamped, i.e. a save already broken by the above.
-- "Apply Playerdata" would have done this on login; when it bails, doing it here means THIS
-- session's inventory is written back to the player's real entry instead of the GUID-0 void
-- (SAVE_WorldSaveV1::UpdateSavedInventory only ever UPDATES an existing GUID, so an unlinked
-- inventory's every save is a silent no-op).
--
-- This decides WHICH inventory survives the repair, so it is a config switch. On: the inventory you
-- are holding right now becomes the saved one. Off: the last one the game managed to store -- the
-- snapshot from the session before the link broke -- is what the next load restores, and this
-- session's items are lost. Neither can keep both; the stored entry is the only surviving copy.
-- On is also the more certain repair: it rewrites the stored entry from the live array, so the next
-- load's length check matches by construction instead of by hoping the stored array is the size the
-- newly stamped tier expects.
local function relinkInventory()
  if not ctx.config.get("qol_backpack_relink") then return end
  local q, pc = qmap(), localController()
  local pawn = ctx.uehelp.localPawn()
  if not (pc and pawn and q.setInvIdFn and q.invIdProp and q.playerdataInvIdField) then return end
  local invProp = (ctx.map.wand and ctx.map.wand.inventorySystemProp) or "InventorySystem"
  local okInv, inv = ctx.uehelp.get(pawn, invProp)
  if not (okInv and ctx.uehelp.isValid(inv)) then return end
  local live; pcall(function() live = inv[q.invIdProp] end)
  if not nullGuid(live) then return end       -- already linked: leave the game's own link alone
  local saved
  pcall(function()
    local ok, pd = ctx.uehelp.get(pc, q.playerdataProp)
    if ok and pd then saved = pd[q.playerdataInvIdField] end
  end)
  if nullGuid(saved) then return end          -- no record to link to; a genuinely new player
  if ctx.uehelp.call(pc, q.setInvIdFn, inv, saved) then
    ctx.log.warn("qol: the pawn's inventory had no save GUID (a load that failed earlier) -- " ..
      "re-linked it to the player record so this session's inventory is saved")
  end
end

-- What length does a tier want? Asked of the game first (its own GetInvLengthForBackpackUpgradeTier
-- is the very function the save's length check uses), with the known ladder as the fallback so a
-- renamed symbol degrades to a stale number instead of to no check at all.
local TIER_SLOTS = { [0] = 29, [1] = 36, [3] = 43, [7] = 50 }
local function slotsForTier(pawn, lvl)
  local fn = qmap().invLenForTierFn
  if pawn and fn then
    local out = {}
    local ok, ret = ctx.uehelp.call(pawn, fn, lvl, out)
    if not ok then ok, ret = ctx.uehelp.call(pawn, fn, lvl) end
    if ok then
      local _, v = next(out)
      v = tonumber(v) or tonumber(ret)
      if v and v > 0 then return math.floor(v) end
    end
  end
  return TIER_SLOTS[lvl]
end

-- Live pack size and how much of it is in use. Both reads are the safe ones: the array LENGTH and
-- the game's own free-slot count. Nothing here indexes the array -- reading a struct-array element
-- from Lua wedges the scheduler on this build.
local function packCounts(pawn)
  local invProp = (ctx.map.wand and ctx.map.wand.inventorySystemProp) or "InventorySystem"
  local ok, inv = ctx.uehelp.get(pawn, invProp)
  if not (ok and ctx.uehelp.isValid(inv)) then return nil end
  local len; pcall(function() len = #inv.Inventory end)
  return tonumber(len), freeSlotCount(inv)
end

-- Nothing here runs during world load any more, and on a save that already records the tier
-- nothing runs AT ALL.
--
-- Once the tier is in Playerdata, the game applies it itself on login -- BP_MainPlayerController's
-- login ubergraph walks every player and calls CLIENT_UpdateBackpackVisuals + the pawn's
-- SetInventoryUpgradeLevel with the saved value. Calling it again from here achieves nothing and
-- is far from free: SetInventoryUpgradeLevel writes the inventory array, which fires
-- SERVER_Net_ApplyAndSaveInventory -> SetInventory -> OnRep_Inventory -> the hotbar and hand-mesh
-- rebuild, i.e. it kicks the whole equip chain during the busiest seconds of world load. So: read
-- the recorded tier first and do nothing if it already matches.
--
-- The repair path (a save this mod broke, tier still 0) does the work on a delay instead. It MUST
-- land after the game's own login apply, never before it: "Apply Playerdata" reads the tier
-- straight out of Playerdata, so stamping first would make a perfectly healthy save (29-slot
-- record, tier 0) fail its own length check -- the repair would become the bug.
local function applyBackpack()
  local lvl = tonumber(ctx.config.get("qol_backpack_level")) or -1
  if lvl < 0 then return end
  if not ctx.net.isHost() then return end     -- Playerdata is server-authoritative
  if recordedTier() == lvl then
    -- Nothing to do: the saved inventory already came back at the tier's length and the inventory
    -- UI reads the tier from Playerdata directly. The one thing skipped is the pack MESH on the
    -- character's back, which SetInventoryUpgradeLevel also toggles -- if that turns out to be
    -- missing, it wants re-adding on a long delay, well clear of world load, not here.
    ctx.log.debug("qol: backpack tier " .. lvl .. " already recorded; nothing to apply")
    return
  end
  defer(5000, function()
    local cur = recordedTier()
    if not ctx.net.isHost() or cur == lvl then return end
    -- playerPawn, NOT localPawn: five seconds after launch the only Character around can be a
    -- main-menu one, and SetInventoryUpgradeLevel is not something to aim at a guess.
    local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
    if not pawn then return end
    local want = slotsForTier(pawn, lvl)
    local len, free = packCounts(pawn)
    -- GOING DOWN is not the mirror of going up. Growing can only ever add empty slots; shrinking
    -- takes slots away, and the slots it takes may have things in them -- so a downgrade waits
    -- until the pack fits in the smaller one, and says why when it does not. The count is all
    -- that can be checked (per-slot reads wedge the scheduler), so this is deliberately
    -- conservative: items sitting in high slots of an otherwise-empty pack still ride on the
    -- game's own resize, which is the only code that knows how to move them.
    if want and len and free and lvl < (cur or lvl) then
      local used = len - free
      if used > want then
        ctx.log.warn(string.format("qol: not shrinking the backpack to tier %d (%d slots) -- " ..
          "you are carrying %d items. Stash them below %d first; nothing was changed.",
          lvl, want, used, want))
        return
      end
    end
    ctx.log.step("qol.backpack repair")
    if ctx.uehelp.call(pawn, qmap().invUpgradeFn, lvl) then
      ctx.log.info("qol: backpack upgrade level " .. lvl .. " applied")
    end
    -- The tier record and the array length have to agree or the next load fails its own check and
    -- takes the whole player save with it. Growing proves itself by construction; shrinking does
    -- not, because nothing here knows the game's downgrade path resizes at all -- so the stamp
    -- waits for the array to actually BE the tier's length.
    defer(600, function()
      local now = packCounts(pawn)
      if want and now and now ~= want then
        ctx.log.warn(string.format("qol: the inventory array is %d slots but tier %d wants %d -- " ..
          "leaving the recorded tier alone (a mismatch is what breaks the player save)",
          now, lvl, want))
        return
      end
      stampBackpackTier(lvl)
      relinkInventory()
    end)
  end)
end

--------------------------------------------------------------------- crouch: HOLD Ctrl or C
-- The engine does the whole job here and always did (proven live 2026-07-26): Crouch() takes on
-- the movement component's NEXT tick, the collision capsule drops 115 -> 45 with
-- bCrouchMaintainsBaseLocation set (so the feet stay planted and the HITBOX really is the short
-- one), the camera follows via CrouchedEyeHeight 32 vs 64, and MaxWalkSpeedCrouched caps the
-- shuffle at 300. What was broken was everything wrapped around it -- see ensureCanCrouch below
-- and the key resolution in bind().
local standHalf = nil          -- the standing capsule half-height, learned live (CDOs are poison)
local crouchProven = false     -- log the capsule shrink once per session, not once per press
local crouchWarnedAt = -1e9
local lastCrouchLift = nil     -- how far the last crouch dropped the actor origin...
local lastCrouchAt = -1e9      -- ...and when, for a death that outruns its own pawn

local function moveComp(pawn)
  local mv
  pcall(function() mv = pawn[(ctx.map.animal and ctx.map.animal.moveCompProp) or "CharacterMovement"] end)
  if not ctx.uehelp.isValid(mv) then pcall(function() mv = pawn.CharacterMovement end) end
  return ctx.uehelp.isValid(mv) and mv or nil
end

local function capsuleHalf(pawn)
  local h
  pcall(function() h = pawn.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
  return type(h) == "number" and h or nil
end

-- A repair, not a prerequisite.
--
-- This build ships the movement component with bCanCrouch ALREADY true, and the old code's
-- unconditional nested-struct write (`mv.NavAgentProps.bCanCrouch = true`) is a shape UE4SS
-- cannot always perform: against a pawn that is still constructing it logs "Tried setting member
-- variable 'bCanCrouch' but UObject instance is nullptr" and -- the trap -- raises NO Lua error,
-- so pcall reported success for a write that never landed (that exact line is in the 12:06 world
-- entry log). That bogus verdict was then cached per pawn AND used to gate the crouch, so the
-- keys could go dead for the rest of the session. Now: read first, write only when it is
-- genuinely off, and never let the outcome decide whether the player may crouch.
local function ensureCanCrouch(pawn)
  local mv = moveComp(pawn)
  if not mv then return end
  local ok, can = pcall(function() return mv.NavAgentProps.bCanCrouch end)
  if ok and can == true then return end
  pcall(function() mv.NavAgentProps.bCanCrouch = true end)
  local _, now = pcall(function() return mv.NavAgentProps.bCanCrouch end)
  if now ~= true then
    ctx.log.debug("qol: bCanCrouch is off and would not take -- the crouch may not engage")
  end
end

local function isLocalCharacter(pawn)
  local want = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
  return ctx.uehelp.className(pawn) == want
end

-- HOST: bCanCrouch=true on the server's copy of EVERY player pawn. The pawn's CMC does not
-- serialize NavAgentProps.bCanCrouch (offline RE of the cooked pawn), so it boots with the
-- engine default FALSE everywhere -- and crouch is server-authoritative: a client's crouch
-- flag arrives in its moves and the server DROPS it while its own copy says "can't crouch".
-- That is the whole "crouch works only for the host in MP" bug. The client-local ensure in
-- applyHold cannot reach the server copy; this can. Event-driven (the Character notify +
-- world entry), read-first idempotent writes -- safe to run repeatedly.
local function hostEnsureCrouchAll()
  if not ctx.net.isHost() then return end
  if not ctx.config.get("qol_crouch") then return end
  local cls = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
  for _, p in ipairs(ctx.uehelp.findAll(cls)) do
    local full; pcall(function() full = p:GetFullName() end)
    if ctx.uehelp.isValid(p) and full and not full:find("Default__", 1, true) then
      ensureCanCrouch(p)
    end
  end
end

-- HOLDING is the hard part, not the crouching. UE4SS hands a mod key-DOWN only -- there is no
-- release callback -- so "while the key is held" has to come from somewhere else. TWO safe
-- sources exist on this build, one per key:
--   Ctrl -- THE GAME'S OWN raw key events (mapping qol.crouchKeyEventFns): a UE InputKey node
--   compiles its Pressed and Released pins into two separate functions, so hooking both IS a
--   key-up subscription. The game declares raw key events for LeftControl only.
--   The letter key -- the OS KEY-REPEAT STREAM: while the key is held, Windows re-sends the down
--   event every few tens of ms; when the stream goes quiet for longer than the repeat gap, the
--   key is up. Release detection lags by the gap (~0.7s), so Ctrl's exact release stays the
--   better hold key -- but both keys hold, and both keys tap-toggle.
--
-- The third source is a PROVEN KILLER and must never come back: reading key state off the
-- controller (IsInputKeyDown / WasInputKeyJustReleased / GetInputKeyTimeDown / any FKey-taking
-- member) died on its very first live call -- 2026-07-27 09:04:42, dump/crouch_steps.txt named
-- it, AV reading 0x70 with zero game frames = UE4SS faulted marshalling the call itself. FKey is
-- a native struct wrapping an FName, the exact parameter shape every fatal member call on this
-- build shares (see the gotchas memory). pcall catches nothing; there is no safe probe shape, so
-- the whole poll apparatus is gone rather than latched.
local holdKeys  = { c = false, ctrl = false, cHeld = false }  -- latch / Ctrl held / letter held
-- The bench seat's crouch rides THROUGH this module (services.setCrouch) so the death-loot
-- bookkeeping below stays honest for a seated death, and while it is set the crouch keys
-- cannot stand a sitter up -- applyHold's reconcile treats it as an unconditional "crouched".
local benchSeatCrouch = false
local lastDownAt = { c = -1e9, ctrl = -1e9 }  -- last DOWN event per key, OS repeats included
local ctrlHooked = false        -- the game's own press/release events are driving Ctrl
local ctrlPressedAt = -1e9      -- when the Ctrl DOWN edge landed (tap vs hold is a duration)
local cPressAt = -1e9           -- when the current letter-key press began (fresh down, not repeat)
local cTapLatches = false       -- whether a letter-key TAP should latch when its release lands
local cWatchArmed = false       -- one letter-key release watcher at a time

-- Spacing that separates a fresh physical press from the OS repeating a held key. Must exceed
-- Windows' initial repeat delay (250-1000ms by setting; 500ms default) or a held key reads as
-- tap,press,tap,press; re-taps faster than this read as one press. Tunable for non-default OS
-- repeat settings: sps set qol_crouch_repeat_gap 1.1
local function repeatGap()
  local g = tonumber(ctx.config.get("qol_crouch_repeat_gap"))
  return (g and g > 0.2) and g or 0.65
end

-- THE one place crouch state is written: both keys feed booleans into holdKeys and this
-- reconciles them with the pawn. Game thread only. ownPawn, NEVER localPawn: the findFirst
-- fallback can hand back a TEAMMATE's pawn on a listen server, and this function WRITES --
-- reconciling benchSeatCrouch against a friend's body kept re-crouching them (review
-- 2026-07-31). No own pawn this frame = do nothing; the 300ms reconciler retries.
local function applyHold()
  local pawn = ctx.uehelp.ownPawn()
  if not ctx.uehelp.isValid(pawn) then return end
  -- at the airship wheel the possessed pawn IS the ship: nothing to crouch, and calling Crouch on
  -- a non-Character is exactly the wrong-class BP call the crash notes warn about
  if not isLocalCharacter(pawn) then
    holdKeys.c, holdKeys.ctrl, holdKeys.cHeld = false, false, false
    return
  end
  local _, isC = ctx.uehelp.get(pawn, "bIsCrouched")
  local half = capsuleHalf(pawn)
  if isC ~= true and half then standHalf = half end   -- standing height, learned (CDOs are poison)
  local want = benchSeatCrouch or holdKeys.c or holdKeys.ctrl or holdKeys.cHeld
  if want == (isC == true) then return end            -- already where the keys say we should be
  if want then ensureCanCrouch(pawn) end
  ctx.uehelp.call(pawn, want and "Crouch" or "UnCrouch", false)
  -- Crouch() only raises bWantsToCrouch; the component applies it (and resizes the capsule) on its
  -- next movement tick, so the state that proves it landed is a few frames out -- reading it inline
  -- always says "false", which is how a working crouch reads as a broken one.
  deferOnly(300, function()
    if not ctx.uehelp.isValid(pawn) then return end
    local _, now = ctx.uehelp.get(pawn, "bIsCrouched")
    local nowHalf = capsuleHalf(pawn)
    -- compare against what the keys want NOW, not what they wanted 300ms ago: with hold-to-crouch
    -- a quick tap is released well inside this window, and that is not a failure
    local stillWant = benchSeatCrouch or holdKeys.c or holdKeys.ctrl or holdKeys.cHeld
    if (now == true) ~= stillWant then
      if os.clock() - crouchWarnedAt > 10 then
        crouchWarnedAt = os.clock()
        ctx.log.warn("qol: crouch did not take (bIsCrouched=" .. tostring(now) ..
          ") -- mid-air, or something overhead is blocking standing back up")
      end
      return
    end
    if stillWant and nowHalf and standHalf and standHalf > nowHalf then
      -- Remembered for the death-loot fix: at death the pawn can already be gone by the time we
      -- get a safe moment to act, and this is the drop the game's loot spot needs undone.
      lastCrouchLift, lastCrouchAt = standHalf - nowHalf, os.clock()
      if not crouchProven then
        crouchProven = true
        ctx.log.info(string.format(
          "qol: crouched -- collision capsule %.0f -> %.0f, so the hitbox really is the short one",
          standHalf, nowHalf))
      end
    end
  end)
end

-- A crouch key went down in plain-TOGGLE mode. A held key brings the OS repeat storm, and a
-- repeat through a toggle re-toggles it -- live 2026-07-27: "you have to press C twice", because
-- a press lingering past the old 0.4s gate ate its own toggle with its first repeat. Repeats are
-- recognized by SPACING (anything inside repeatGap of the previous down is the same physical
-- press), so one press is one toggle no matter how long it lingers.
local function holdKeyDown(slot)
  if not ctx.config.get("qol_crouch") then return end
  local now = os.clock()
  local fresh = (now - lastDownAt[slot]) > repeatGap()
  lastDownAt[slot] = now
  if not fresh then return end
  holdKeys[slot] = not holdKeys[slot]
  applyHold()
end

-- The game's own LeftControl press/release events. The hook body itself touches NO UObject (our
-- own damage calls can re-enter game code, and a hook body doing UObject work inside a
-- Lua->native->Lua chain is the documented abort): it records the edge and schedules the
-- reconcile. Which function is which edge is bytecode, not a guess: in the pawn's Ubergraph the
-- ..._2 entry sets the node's gate bool TRUE and the ..._3 entry sets it FALSE -- a compiled
-- Pressed/Released pair, in that order in mapping crouchKeyEventFns.
--
-- A quick TAP latches the crouch instead of blinking it. Live 2026-07-27 09:13: six Ctrl taps,
-- and every press+release pair was fully processed before the deferred reconcile ran, so pure
-- hold semantics reconciled to "not held" six times out of six -- the key genuinely did nothing
-- on screen. So: tap = toggle (it folds into the letter key's latch), held past the tap window
-- = crouched for exactly the hold.
local TAP_S = 0.35
local function onCtrlKeyEvent(isDown)
  if not ctx.config.get("qol_crouch") then return end
  if ctx.config.get("qol_crouch_hold") == false then
    -- hold semantics off by config: the down edge toggles, the up edge is ignored
    if isDown then deferOnly(0, function() holdKeyDown("ctrl") end) end
    return
  end
  if isDown then
    ctrlPressedAt = os.clock()
    holdKeys.ctrl = true
  else
    holdKeys.ctrl = false
    if os.clock() - ctrlPressedAt < TAP_S then holdKeys.c = not holdKeys.c end
  end
  deferOnly(0, applyHold)
end

-- The letter key's release watcher: while repeats keep arriving the key is held; the first
-- quiet stretch longer than repeatGap IS the release. Only then can tap vs hold be told apart --
-- a tap's whole story is one down event, a hold's is a stream -- so a tap's latch lands here,
-- ~repeatGap late. (The crouch itself started at the press; only the LATCH decision waits.)
local function cWatch()
  if ctx.config.get("qol_crouch_hold") == false then cWatchArmed = false return end
  local now = os.clock()
  if now - lastDownAt.c <= repeatGap() then
    deferOnly(150, cWatch)                       -- still held: look again shortly
    return
  end
  cWatchArmed = false
  local wasTap = (lastDownAt.c - cPressAt) < TAP_S
  holdKeys.cHeld = false
  if wasTap and cTapLatches then holdKeys.c = true end   -- a tap latches: stay crouched
  cTapLatches = false
  applyHold()
end

-- The letter key went down -- a fresh press or an OS repeat, told apart by spacing. Fresh press:
-- crouch immediately (if latched, STAND immediately instead -- tap-to-stand must not wait out the
-- release watcher). Repeat: the key is genuinely held, keep the crouch pinned. Runs on the game
-- thread via bind().
local function cKeyDown()
  if not ctx.config.get("qol_crouch") then return end
  if ctx.config.get("qol_crouch_hold") == false then holdKeyDown("c") return end
  local now = os.clock()
  local fresh = (now - lastDownAt.c) > repeatGap()
  lastDownAt.c = now
  if fresh then
    cPressAt = now
    if holdKeys.c then
      -- already latched: this press means "stand", now. If repeats reveal it is really a hold,
      -- the repeat branch below re-crouches for the rest of the hold.
      holdKeys.c, holdKeys.cHeld = false, false
      cTapLatches = false
    else
      holdKeys.cHeld = true
      cTapLatches = true
    end
    applyHold()
    if not cWatchArmed then
      cWatchArmed = true
      deferOnly(math.floor(repeatGap() * 1000) + 150, cWatch)
    end
  elseif not holdKeys.cHeld then
    holdKeys.cHeld = true
    applyHold()
  end
end

--------------------------------------------------------------------- dying crouched, and the loot
-- Die crouched and your gear chest ended up UNDER the ground. Cause: crouching drops the pawn's
-- actor origin by the half-height difference (~70cm -- the feet stay planted, so the origin has to
-- come down), and the game stamps DeathLootSpawnLocation off that origin, then places the chest a
-- fixed STANDING height below it. Nothing in the game ever expected a crouched player, because the
-- game has no crouch.
--
-- The hook body may not touch a single UObject: mod damage (lightning, an Unlit bite) calls the
-- game's own Reduce Health, whose death flow reaches this function -- so it can fire inside a
-- Lua->native->Lua chain, the exact shape that aborted the process before. It records and
-- schedules; the correction runs a tick later, on the game thread, outside that chain. That is
-- also why the stored location is corrected rather than the pawn moved: by then the stamp is
-- taken, and the loot itself spawns later still (the game runs it off a respawn timer).
local lootStampPending = false

local function fixDeathLoot()
  lootStampPending = false
  if not ctx.config.get("qol_crouch_deathloot_fix") then return end
  local pc = localController()
  if not pc then return end
  -- The pawn may already be gone by now (death tears it down fast), so the crouch drop is taken
  -- live where possible and from the remembered one otherwise -- never guessed.
  local pawn = ctx.uehelp.localPawn()
  local alive = ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn)
  local isC, half
  if alive then
    local okC, v = ctx.uehelp.get(pawn, "bIsCrouched")
    isC = okC and v or nil
    half = capsuleHalf(pawn)
  end
  local lift
  local keysWant = benchSeatCrouch or holdKeys.c or holdKeys.ctrl or holdKeys.cHeld
  if isC == true and half and standHalf and standHalf > half then
    lift = standHalf - half
  elseif keysWant and lastCrouchLift then
    -- The pawn is unreadable (or the death flow already un-crouched it), but the keys still say
    -- CROUCHED -- and the mod's keys are the only crouch source this game has, so they are
    -- authoritative. Live 2026-07-27 09:40: died after staying crouched for minutes; the 3s
    -- memory below had long expired, this function concluded "died standing", and the loot box
    -- sank ~70cm under the terrain.
    lift = lastCrouchLift
  elseif lastCrouchLift and (os.clock() - lastCrouchAt) < 3.0 then
    lift = lastCrouchLift                             -- crouched a moment ago; the body is gone
  else
    return                                            -- died standing: the game's own spot is right
  end
  local prop = qmap().deathLootLocProp
  local okS, stamped = ctx.uehelp.get(pc, prop)
  local at = okS and ctx.uehelp.vec(stamped) or nil
  if not at then return end
  local here = alive and ctx.uehelp.vec(pawn:K2_GetActorLocation()) or nil
  -- Which convention did the game stamp in? If the spot already sits a CROUCHED half-height under
  -- the pawn origin it was computed correctly and must be left alone; anything else (the origin
  -- itself, or the origin minus a standing height) is short by exactly the crouch drop. With no
  -- pawn left to compare against, the drop is undone -- being 70cm high beats being buried.
  if here and half and math.abs(at.Z - (here.Z - half)) < 5.0 then
    ctx.log.debug("qol: death-loot spot already ground-correct -- left alone")
    return
  end
  local fixed = { X = at.X, Y = at.Y, Z = at.Z + lift }
  local okW = ctx.uehelp.set(pc, prop, fixed)
  local _, after = ctx.uehelp.get(pc, prop)
  local back = ctx.uehelp.vec(after)
  if okW and back and math.abs(back.Z - fixed.Z) < 1.0 then
    ctx.log.info(string.format("qol: died crouched -- death-loot spot raised %.0fcm (%.0f -> %.0f) so the chest lands on the ground",
      lift, at.Z, back.Z))
  elseif alive and here then
    -- The struct write did not stick. Fall back to standing the dying pawn up: anything that
    -- re-reads the pawn's location downstream then sees the standing origin. (Live-pawn only:
    -- a destroyed-but-pre-GC pawn passes isValid and calling into it is a native crash.)
    local moved = ctx.uehelp.call(pawn, "K2_SetActorLocation",
      { X = here.X, Y = here.Y, Z = here.Z + lift }, false, {}, true)
    ctx.log.warn(string.format("qol: could not rewrite %s (read back %s) -- lifted the pawn instead (ok=%s)",
      tostring(prop), tostring(back and back.Z), tostring(moved)))
  else
    ctx.log.warn(string.format("qol: could not rewrite %s (read back %s) and no live pawn to lift -- the loot box may sink",
      tostring(prop), tostring(back and back.Z)))
  end
end

--------------------------------------------------------------------- the airship
-- Driving swaps the bottom-of-screen hotbar for the airship control icons (the giveaway is
-- SERVER_LeaveAirship's client path, which flips exactly this pair back on stepping off) -- so
-- at the wheel the transfer view had no hotbar anywhere on screen, and the hotbar IS how a
-- chest UI shows your first 8 slots (its player grid deliberately skips them). While the view
-- is up, borrow the on-foot arrangement -- hotbar shown, control icons away -- and put it back
-- when the UI closes IF still at the wheel; leaving the wheel restores it natively, and the
-- restore stands down for that case.
local shipHotbarShown = false
local function overlayOf(pc)
  local ov; pcall(function() ov = pc[qmap().overlayProp or "PlayerOverlay"] end)
  if ctx.uehelp.isValid(ov) then return ov end
  return nil
end
local function showShipHotbar(pc)
  local ov = overlayOf(pc)
  if not ov then return end
  ctx.uehelp.call(ov, qmap().overlayShowHotbarFn or "SetShowHotbar", true)
  ctx.uehelp.call(ov, qmap().overlayShowShipCtlFn or "SetShowAirshipControls", false)
  shipHotbarShown = true
end
local function restoreShipHotbar()
  if not shipHotbarShown then return end
  shipHotbarShown = false
  local pc = localController()
  if not pc then return end
  if callOutBool(pc, qmap().controllingShipFn) ~= true then return end
  local ov = overlayOf(pc)
  if not ov then return end
  ctx.uehelp.call(ov, qmap().overlayShowHotbarFn or "SetShowHotbar", false)
  ctx.uehelp.call(ov, qmap().overlayShowShipCtlFn or "SetShowAirshipControls", true)
end

-- Its chest: the ship carries a real BC_InventorySystem of its own; the controller's
-- UI_OpenChestInventory(ChestInventorySystem) is the game's every-chest UI entry.
local shipChestHinted = false
local function openShipChest()
  local ship = liveInstances(qmap().airshipClass)[1]   -- a placed ship, never the CDO
  local pc = localController()
  if not (ship and pc) then return end
  local near = false
  local flying = callOutBool(pc, qmap().controllingShipFn) == true
  if not flying then
    local pawn = ctx.uehelp.localPawn()
    local pl, sl
    if pawn then pcall(function() pl = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end) end
    pcall(function() sl = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
    local r = tonumber(ctx.config.get("qol_ship_chest_range")) or 3000
    near = pl and sl and ctx.uehelp.dist2(pl, sl) <= r * r
  end
  if not (flying or near) then return end
  -- The mod-kept stern chest is the ship's storage now (features/ship_chest.lua) -- the upgrade
  -- component is only a fallback for a ship that happens to have it built.
  if ctx.services.shipChestOpen and ctx.services.shipChestOpen(pc) then
    if flying then showShipHotbar(pc) end
    ctx.log.debug("qol: ship storage opened (stern chest)")
    return
  end
  local inv
  local ok = pcall(function() inv = ship[ctx.map.wand and ctx.map.wand.inventorySystemProp or "InventorySystem"] end)
  if not (ok and ctx.uehelp.isValid(inv)) then
    if not shipChestHinted then
      shipChestHinted = true
      ctx.log.info("qol: the ship's stern chest is not there yet (host spawns it on world entry" ..
        " or the next park) and no chest upgrade is built either")
    end
    return
  end
  ctx.uehelp.call(ship, qmap().shipChestOpenFn)          -- the lid animation (cosmetic)
  ctx.uehelp.call(pc, qmap().openChestUiFn, inv)
  if flying then showShipHotbar(pc) end
  ctx.log.debug("qol: ship chest opened (upgrade component)")
end

-- The local CHARACTER, remembered while we are on foot. At the wheel the controller's Pawn IS
-- the airship, and in co-op FindAllOf hands back every player's character with no way to tell
-- them apart, so the only trustworthy handle on "my own body" while flying is the one we kept.
local lastCharacter = nil

local function myCharacter()
  local pawn = ctx.uehelp.localPawn()
  if ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn) then
    lastCharacter = pawn
    return pawn
  end
  if ctx.uehelp.isValid(lastCharacter) and isLocalCharacter(lastCharacter) then return lastCharacter end
  return nil
end

-- Is the player's inventory window on screen RIGHT NOW? nil when the widget cannot be read.
-- IsVisible only: the closed widget stays parked in the viewport, so IsInViewport reads true
-- forever (the same trap syncHotbar hit live on 2026-07-26).
local function invVisible(pc)
  local w
  pcall(function() w = pc[qmap().invWidgetProp] end)
  if not ctx.uehelp.isValid(w) then return nil end
  local v; pcall(function() v = w:IsVisible() end)
  if type(v) ~= "boolean" then return nil end
  return v
end

-- Last resort when the controller's own toggle is dead at the wheel: show YOUR inventory through
-- UI_OpenChestInventory, the game's every-inventory UI entry (the same call the ship chest uses).
-- Its bytecode dispatches straight through the parameter, and handing a game BP call an object of
-- the wrong class is a FATAL assert, not a catchable error -- so the class is checked, not assumed.
local function openOwnInvAsPanel(pc)
  local ch = myCharacter()
  if not ch then return false end
  local inv
  pcall(function() inv = ch[(ctx.map.wand and ctx.map.wand.inventorySystemProp) or "InventorySystem"] end)
  if not (ctx.uehelp.isValid(inv) and ctx.uehelp.className(inv) == "BC_InventorySystem_C") then return false end
  return (ctx.uehelp.call(pc, qmap().openChestUiFn, inv))
end

-- Is the transfer view still being DRAWN -- fully open, or inside its show/hide animation?
-- Plain IsVisible on purpose, NOT the widget's own `IsOpen?`: the widget only collapses itself
-- when the hide animation finishes, so a view the game began closing on THIS very press still
-- reads visible here -- which is exactly the read the toggle needs (see below). `IsOpen?` is
-- IsVisible AND not-animating, and that "not-animating" clause is what broke the first toggle
-- cut: mid-hide it reads false, "closed" and "closing" become indistinguishable, and the
-- handler re-opened every close.
local function chestUiDrawn()
  for _, w in ipairs(liveInstances(qmap().chestUiClass or "W_ChestInventory_C")) do
    local vis; pcall(function() vis = w:IsVisible() end)
    if vis == true then return true end
  end
  return false
end

-- Your own inventory while at the wheel -- ONLY while flying (on foot the game's own binding
-- already handles it). At the wheel the key TOGGLES the TRANSFER view (user spec 2026-07-27):
-- the ship's storage chest + your own inventory in one panel -- W_ChestInventory draws both.
--
-- The split of labor, settled by the 10:42 step log (2026-07-27): the game already OWNS the
-- close half. While the view is up the controller is in UI input mode, so the game's input
-- ACTIONS are off (ToggleInventory does not even run -- no qol.inv step on those presses) and
-- the focused widget's own key handling closes the view (SetInputModeGame fires with no toggle
-- in sight). So this handler owns ONLY the open, and only when the view is truly down: if the
-- widget still draws -- open, or the hide animation this same press just started -- the press's
-- work is done or in flight, and opening now would undo it (the "reopens on every press" bug).
-- Both orders of us-vs-widget on one press land right: widget first = we see it still drawn and
-- stand down; us first = we see it drawn and stand down, the widget then closes it.
--
-- The open attempt itself runs unguarded by any "did the game handle this press" referee: at
-- the wheel with no UI up the game's ToggleInventory runs and shows NOTHING (six presses, six
-- game toggles, zero UIs -- the earlier step log), so there is nothing to defer to. The
-- blind-toggle dance survives only as the open fallback for a ship whose chest is missing:
-- state the target and correct what actually happened a beat later, which is idempotent
-- whether the game's own toggle turns out to be dead (this build) or live (the re-assert
-- un-cancels it).
local function openInvOnShip()
  local pc = localController()
  if not pc then return end
  if callOutBool(pc, qmap().controllingShipFn) ~= true then return end
  -- The plain inventory already up means some earlier press got it open; leave the closing to
  -- ESC / the game rather than stacking the chest panel over it.
  if invVisible(pc) == true then return end
  if chestUiDrawn() then
    ctx.log.debug("qol: wheel inventory key -> view is up; the game's own close handles this press")
    return
  end
  if ctx.services.shipChestOpen and ctx.services.shipChestOpen(pc) then
    showShipHotbar(pc)   -- at the wheel by the gate above
    ctx.log.debug("qol: wheel inventory key -> ship storage transfer view")
    return
  end
  local seen = invVisible(pc)      -- false or nil here; true bailed above, so the target is OPEN
  ctx.uehelp.call(pc, qmap().toggleInvFn)
  if seen == nil then return end   -- widget unreadable: one honest toggle, no blind correction
  deferOnly(300, function()
    if invVisible(pc) ~= false then return end   -- open now, or unreadable -- leave it alone
    ctx.uehelp.call(pc, qmap().toggleInvFn)      -- something cancelled ours; put it back
    deferOnly(300, function()
      if invVisible(pc) ~= false then return end
      if openOwnInvAsPanel(pc) then
        ctx.log.info("qol: inventory opened at the wheel via the chest panel (ESC closes it)")
      else
        ctx.log.warn("qol: could not open the inventory while flying")
      end
    end)
  end)
end

-- Faster recall, take two. TimelineSpeed is a DEAD variable: BP_Dock's bytecode never reads it
-- (offline RE 2026-07-29 -- the only references in the whole asset are the property itself and
-- its 800.0 CDO default). The return flight is really the dock's tick VInterpTo_Constant-ing the
-- ship, with speed = a timeline curve x MapRangeClamped(distance, 0..2000 -> 30..1000/1200) --
-- every number a literal baked into bytecode. Writing 16000 into TimelineSpeed changed nothing,
-- which is exactly what the first live test showed.
--
-- So the mod flies the assist itself, boost-style: while a return is in flight, a bounded
-- 150 ms watch amplifies the ship's own frame delta by (mult - 1). Two legs get the treatment,
-- and both stay phase-safe against the dock's arrival checks (<1000-unit spheres + one exact
-- NearlyEqualVector) by standing down before them:
--   * the horizontal travel leg -- push capped so the ship never lands closer than
--     RECALL_STANDOFF (2D) to the dock;
--   * the long DESCENT -- "unstuck airship" stages the ship kilometers above the dock and the
--     return is a straight drop (user-confirmed vanilla behavior 2026-07-29; an earlier build
--     mistook that altitude for corrupted save data and TELEPORTED the ship to the dock, which
--     the user immediately called out as cheating -- removed, the flight is the feature) --
--     amplified only while moving TOWARD the dock's altitude, never through the last
--     RECALL_Z_STANDOFF of it, so the landing and docking cutscene stay 100% native.
-- The RAISE stays native either way: it moves AWAY from the dock's altitude, and its
-- completion checks live in bytecode this RE could not validate.
-- Host-only: the dock drives the ship on the host, so that is the one machine whose
-- SetActorLocation means anything. The watch arms off the dock hooks (see armHooks) and
-- disarms itself when no flight shows up -- never a free-running poll.
-- "In flight" is AirshipToReturn being non-null -- NOT AirshipCurrentlyReturning_Patrick.
-- Burned live 2026-07-29: the flag is only raised by the RAISE-first path; the common direct
-- return (ReturnToHome -> DirectReturnAirship, the exact pair the breadcrumbs caught) flies with
-- the flag still false, so a flag-gated watch sat blind through the whole flight. AirshipToReturn
-- is assigned at the top of every return entry and nulled in the one arrival-cleanup block
-- (right next to the flag's own = false), so presence-of-ship is the signal every path shares.
local RECALL_STANDOFF   = 2500.0   -- 2D units; > the 1000-unit arrival spheres with margin
local RECALL_Z_STANDOFF = 3000.0   -- vertical units kept native at the bottom of a descent
local recallTok   = 0            -- bumping orphans the in-flight watch chain
local recallUntil = 0            -- os.clock() deadline; a live flight keeps extending it
local recallLast  = {}           -- dock fullname -> ship position at the previous pass
local recallSaid  = {}           -- dock fullname -> logged this flight already
local recallDiagAt = 0           -- TEMP diagnostic throttle (1 line/s while a flight is live)

-- Pure core (unit-tested): the extra distance to push the ship this pass, or nil to stand down.
-- dx/dy/dz = the game's own movement since last pass, toDock = 2D distance ship -> dock.
function F.recallPush(dx, dy, dz, mult, toDock)
  local m = tonumber(mult) or 1.0
  if m <= 1.0 then return nil end
  local hxy = math.sqrt(dx * dx + dy * dy)
  if hxy < 20.0 then return nil end                    -- idle, or the slow native crawl
  if hxy <= 2.0 * math.abs(dz) then return nil end     -- raise/lower phase: vertical delta rules
  local push = hxy * (m - 1.0)
  local room = (tonumber(toDock) or 0) - RECALL_STANDOFF
  if room < push then push = room end
  if push <= 0 then return nil end
  return push, hxy
end

-- Pure core, the vertical twin: extra descent (or climb, for a dock above the ship) this pass,
-- or nil. Only fires when the delta is vertical-dominant AND headed toward the dock's altitude
-- -- the raise moves away from it and so never matches.
function F.recallPushZ(dz, hxy, mult, posZ, dockZ)
  local m = tonumber(mult) or 1.0
  if m <= 1.0 then return nil end
  local adz = math.abs(dz or 0)
  if adz < 20.0 then return nil end                    -- idle, or the slow native crawl
  if adz <= 2.0 * (hxy or 0) then return nil end       -- the travel leg owns this pass
  local toward = (tonumber(dockZ) or 0) - (tonumber(posZ) or 0)
  if dz * toward <= 0 then return nil end              -- climbing away: the raise stays native
  local push = adz * (m - 1.0)
  local room = math.abs(toward) - RECALL_Z_STANDOFF
  if room < push then push = room end
  if push <= 0 then return nil end
  return push
end

local function recallPass(tok)
  if tok ~= recallTok then return end
  local anyReturning = false
  for _, dock in ipairs(liveInstances(qmap().dockClass)) do
    local fn; pcall(function() fn = dock:GetFullName() end)
    if fn then
      local okS, ship = ctx.uehelp.get(dock, qmap().dockReturnShipProp)
      if okS and ctx.uehelp.isValid(ship) then
        anyReturning = true
        recallUntil = os.clock() + 30
        local pos
        pcall(function() pos = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
        local last = recallLast[fn]
        recallLast[fn] = pos
        local dockPos; pcall(function() dockPos = ctx.uehelp.vec(dock:K2_GetActorLocation()) end)
        if pos and last and dockPos then
          local rx, ry = dockPos.X - pos.X, dockPos.Y - pos.Y
          local toDock = math.sqrt(rx * rx + ry * ry)
          local dx, dy, dz = pos.X - last.X, pos.Y - last.Y, pos.Z - last.Z
          local mult = ctx.config.get("qol_recall_mult")
          local push, hxy = F.recallPush(dx, dy, dz, mult, toDock)
          local nx
          if push then
            nx = { X = pos.X + dx / hxy * push, Y = pos.Y + dy / hxy * push, Z = pos.Z }
          else
            push = F.recallPushZ(dz, math.sqrt(dx * dx + dy * dy), mult, pos.Z, dockPos.Z)
            if push then
              nx = { X = pos.X, Y = pos.Y, Z = pos.Z + (dz > 0 and push or -push) }
            end
          end
          -- Flight trace, one line per second while a return is live -- debug since the
          -- player-verified pass (2026-07-29); it earned its keep twice, keep it reachable.
          if os.clock() - recallDiagAt > 1.0 then
            recallDiagAt = os.clock()
            ctx.log.debug(string.format(
              "qol: recall watch: hxy=%.0f dz=%.0f toDock=%.0f push=%s",
              math.sqrt(dx * dx + dy * dy), dz, toDock, push and string.format("%.0f", push) or "--"))
          end
          if nx then
            if ctx.uehelp.call(ship, "K2_SetActorLocation", nx, false, {}, true)
                or ctx.uehelp.call(ship, "K2_SetActorLocation", nx, false, {}, false)
                or ctx.uehelp.call(ship, "SetActorLocation", nx) then
              recallLast[fn] = nx   -- next pass's delta = the game's own move, not ours
              if not recallSaid[fn] then
                recallSaid[fn] = true
                ctx.log.info(string.format("qol: recall assist x%.0f riding the return flight",
                  tonumber(mult) or 1))
              end
            else
              ctx.log.warn("qol: recall assist could not move the ship (SetActorLocation refused)")
            end
          end
        end
      else
        recallLast[fn], recallSaid[fn] = nil, nil
      end
    end
  end
  if not anyReturning and os.clock() > recallUntil then
    recallLast, recallSaid = {}, {}
    return   -- disarmed; the next dock interaction re-arms
  end
  deferOnly(150, function() onGameThread(function() recallPass(tok) end) end)
end

-- Called from the dock hook bodies (via deferOnly -- never inline in a hook). Re-arming while a
-- chain is alive just replaces it; recallLast survives, so no delta base is lost.
local function armRecallWatch(secs)
  if (tonumber(ctx.config.get("qol_recall_mult")) or 1.0) <= 1.0 then return end
  -- Release the LOCAL seat on EVERY machine, BEFORE the host gate: the assist
  -- K2_SetActorLocations the ship in multi-thousand-uu steps, and based movement moves a
  -- rider by the base delta WITH A SWEEP -- a seated passenger would be blocked by geometry
  -- and stranded or clipped. Each machine releases only its own player's seat (that is all
  -- benchReleaseAll can reach); the isHost gate below guards only the SHIP writes. The old
  -- order (gate first) meant a CLIENT rider was never released at all (review 2026-07-31).
  if ctx.services.benchReleaseAll then pcall(ctx.services.benchReleaseAll, "recall") end
  if not ctx.net.isHost() then return end   -- clients' writes to a replicated ship mean nothing
  local wasDead = os.clock() > recallUntil
  recallUntil = math.max(recallUntil, os.clock() + (secs or 120))
  recallTok = recallTok + 1
  local tok = recallTok
  if wasDead then ctx.log.info("qol: recall watch armed") end
  onGameThread(function() recallPass(tok) end)
end

--------------------------------------------------------------------- overlay: hotbar + drops
-- The live W_PlayerOverlay. Both of FindAllOf's impostors matter here: the archetype (its path
-- contains ":WidgetTree") and the CDO, which is constructed before any instance and therefore
-- tends to come back FIRST -- re-anchoring that one moves nothing on screen.
local function liveOverlay()
  return liveInstances(qmap().overlayClass)[1]
end

-- The pickup feed ("+4 Wood") re-anchored to mid-screen: its canvas slot is re-anchored to the
-- screen centre (resolution-independent), nudged by config. Falls back to a render translation
-- when the slot is not a canvas slot.
local function applyDrops()
  if not ctx.config.get("qol_drops_center") then return end
  local ov = liveOverlay()
  if not ov then return end
  local w
  local ok = pcall(function() w = ov[qmap().dropsProp] end)
  if not (ok and ctx.uehelp.isValid(w)) then return end
  local dx = tonumber(ctx.config.get("qol_drops_x")) or 0
  local dy = tonumber(ctx.config.get("qol_drops_y")) or 0
  local slot
  pcall(function() slot = w.Slot end)
  local anchored = false
  if ctx.uehelp.isValid(slot) then
    local a = pcall(function()
      slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
      slot:SetAlignment({ X = 0.5, Y = 0.5 })
      slot:SetAutoSize(true)
      slot:SetPosition({ X = dx, Y = dy })
    end)
    anchored = a == true
  end
  if not anchored then
    pcall(function() w:SetRenderTranslation({ X = dx, Y = dy }) end)
  end
  ctx.log.debug("qol: drops feed placed (" .. tostring(anchored and "anchored" or "translated") .. ")")
end

-- How many rows the inventory window is showing. A backpack upgrade adds whole rows to the grid
-- (W_PlayerInventory::ExpandGrid rebuilds it as GetRowCount x 7 slots, 3/4/5/6 rows for tier
-- 0/1/3/7). The window's canvas slot is anchored AND aligned at screen centre with auto-size
-- (cooked layout, offline RE 2026-07-27), so it grows SYMMETRICALLY: each row added moves the
-- bottom edge DOWN by half a row (40px of the 80px W_InventorySlot), and the hotbar has to come
-- down with it -- the first version of this shifted a full row UP per row and parked the hotbar
-- inside the window. GetRowCount is the game's own answer, read straight off
-- Playerdata.InventoryUpgrades, so it stays right whatever tier the pack is at.
local function inventoryRows(inv)
  local fn = qmap().invRowCountFn
  if not (fn and ctx.uehelp.isValid(inv)) then return nil end
  local n = tonumber(callOut1(inv, fn))
  -- a garbage read must not fling the hotbar off screen; the grid is 3..6 rows, so anything wild
  -- means the call did not land and the caller should stay on the configured lift alone
  if not n or n < 1 or n > 12 then return nil end
  return n
end

-- The hotbar rides up to meet the open inventory, and drops home when it closes. Sync reads
-- whether the inventory widget is on screen RIGHT NOW -- called (deferred) from both the
-- open path (ToggleInventory) and every UI close (SetInputModeGame).
local function syncHotbar()
  if not ctx.config.get("qol_hotbar_raise") then return end
  local pc = localController()
  if not pc then return end
  local hb, inv
  pcall(function() hb = pc[ctx.map.wand and ctx.map.wand.hotbarWidgetProp or "UI_Hotbar"] end)
  pcall(function() inv = pc[qmap().invWidgetProp] end)
  if not ctx.uehelp.isValid(hb) then return end
  -- IsVisible ONLY: the closed inventory widget stays parked in the viewport, so
  -- IsInViewport reads true forever and the hotbar would never come home (live 2026-07-26)
  local open = false
  if ctx.uehelp.isValid(inv) then
    pcall(function() open = inv:IsVisible() == true end)
  end
  local x, y = 0, 0
  if open then
    x = tonumber(ctx.config.get("qol_hotbar_x")) or 0
    y = tonumber(ctx.config.get("qol_hotbar_y")) or 0
    local base = tonumber(ctx.config.get("qol_hotbar_rows_base")) or 5
    local rows = inventoryRows(inv)
    if rows and rows ~= base then
      -- centre-anchored window: each row beyond the tuned count drops the bottom edge (and the
      -- hotbar with it, +down), each row short of it raises both
      y = y + (rows - base) * (tonumber(ctx.config.get("qol_hotbar_row_px")) or 40)
      ctx.log.debug("qol: hotbar placed for " .. rows .. " inventory rows -> y=" .. tostring(y))
    end
  end
  pcall(function() hb:SetRenderTranslation({ X = x, Y = y }) end)
end

--------------------------------------------------------------------- pings: flat, facing you
local lastPinger = nil        -- plain Lua string, stashed by the MULTI_Ping pre-hook
local lastPingerAt = -1e9

-- The ping marker's mesh component. Named props first (cheap), then a class lookup.
local function pingMesh(p)
  for _, prop in ipairs(qmap().pingMeshProps or {}) do
    local ok, c = ctx.uehelp.get(p, prop)
    if ok and ctx.uehelp.isValid(c) then return c end
  end
  local smc
  pcall(function()
    local cls = StaticFindObject and StaticFindObject("/Script/Engine.StaticMeshComponent")
    if cls then smc = p:GetComponentByClass(cls) end
  end)
  if ctx.uehelp.isValid(smc) then return smc end
  return nil
end

-- Is `name` a UFunction this object's class chain actually declares?
--
-- `obj[name] ~= nil` does NOT answer that. UE4SS hands back a callable wrapper for a member it
-- could not resolve, and invoking it faults inside UE4SS's own call setup -- an access violation
-- reading 0x70 with no game frame on the stack at all, which is exactly what
-- CreateDynamicMaterialInstance did to this build twice. Walking the reflected function list is
-- the only honest test.
--
-- Returns true / false / nil, and the nil matters: if reflection produced no function names at
-- ALL then it is UE4SS that has nothing to say, not the class -- refusing on that would silently
-- disable the feature on a build where the call is fine. Callers treat nil as "try it, latched".
local function declaresFn(obj, name)
  if not name then return false end
  local seen, found = 0, false
  pcall(function()
    local cls = obj:GetClass()
    for _ = 1, 24 do                                  -- guard: a broken super chain must not spin
      if not ctx.uehelp.isValid(cls) then break end
      pcall(function()
        cls:ForEachFunction(function(fn)
          seen = seen + 1
          local n = ""; pcall(function() n = fn:GetFName():ToString() end)
          if n == name then found = true end
        end)
      end)
      if found then break end
      -- SetMaterial and friends live on UMeshComponent, several classes above the component we
      -- are holding, and ForEachFunction lists one class's own functions -- so climb.
      local up; pcall(function() up = cls:GetSuperStruct() end)
      if not up or not ctx.uehelp.isValid(up) then break end
      cls = up
    end
  end)
  if found then return true end
  if seen == 0 then return nil end
  return false
end

-- ONE FLAT COLOUR, from a palette of whole cooked materials.
--
-- The colour is BAKED INTO the material chosen, never set afterwards: every door to a material
-- parameter is fatal on this build. CreateDynamicMaterialInstance crashed twice, and its
-- "safer" sibling SetVectorParameterValueOnMaterials crashed identically on 2026-07-27 00:05:37
-- -- the same access violation reading 0x70, the same all-UE4SS stack (+261bb1/+25ba75) with not
-- one game frame, meaning UE4SS died setting the call up and the engine never ran. That was the
-- last of the parameter family worth trying; see mapping.qol.setMaterialFn for the full record.
--
-- So each palette slot names an existing game material whose DEFAULT look is the slot's colour
-- (offline RE of the cooked binaries, scratchpad re_ping2/), and the one material op this build
-- has ever survived -- SetMaterial with a cooked material object -- is the only one made. The
-- map icon tint uses the same slot's r/g/b, so marker and map still agree per player.
local function colourPing(p, pal)
  local m = qmap()
  local smc = pingMesh(p)
  if not ctx.uehelp.isValid(smc) then return false end

  if declaresFn(smc, m.setMaterialFn) == false then
    ctx.log.debug("qol: ping mesh does not declare " .. tostring(m.setMaterialFn) ..
                  "; leaving the stock material")
    return false
  end
  if ctx.log.isPoisoned("ping:setmat") then return false end

  -- No slot material, no paint: a wrong colour is worse than none, because the colour IS the
  -- player's identity on every other machine.
  local base = pal.mat and matByName(pal.mat) or nil
  if not base then return false end

  -- SM_Ping is ONE flat plane (167x1103 units, origin at the base -- offline RE of the mesh,
  -- scratchpad re_ping2/SM_Ping.json) with two material sections: slot 1 (M_Ping1) is the tall
  -- gradient beam, slot 0 (M_Ping2) the icon quad at the bottom. NOTE the order -- it is the
  -- REVERSE of what this code first assumed, which is why "hide the icon" must go by these
  -- mapped indices and never by "paint the first N slots".
  --
  -- Rod-only: painted flat, the icon quad reads as a floating box at the marker's base
  -- (user-reported 2026-07-27), so it gets the engine's own draw-nothing material instead --
  -- NaniteHiddenSectionMaterial, a masked material whose mask clips every pixel. If that asset
  -- ever fails to resolve the icon keeps its STOCK glyph (small, inoffensive) rather than
  -- becoming the coloured box the option exists to remove.
  local beam = tonumber(m.pingBeamSlot) or 1
  local icon = tonumber(m.pingIconSlot) or 0
  local rodOnly = ctx.config.get("qol_ping_rod_only") and true or false
  local hide = rodOnly and matByName(m.pingHideMat, m.pingHideMatDir) or nil
  local painted = false
  ctx.log.step("qol.ping.setmat")
  ctx.log.risky("ping:setmat", function()
    smc:SetMaterial(beam, base)
    if hide then
      smc:SetMaterial(icon, hide)
    elseif not rodOnly then
      smc:SetMaterial(icon, base)
    end
    painted = true
  end)
  return painted
end

-- THE PING SWEEP: dress every marker, and keep them facing the camera.
--
-- Everything about a ping happens HERE, on the mod's own tick, and nothing happens in the actor
-- construction notify that spots one. That is not tidiness, it is the bug that crashed the game
-- the first time this shipped: the notify fires MID-CONSTRUCTION, and scaling / re-materialising /
-- rotating an actor that UE has not finished building is a native access violation no pcall can
-- catch. The notify's whole job is now to say "a ping exists, wake the sweep".
--
-- The sweep also holds NO actor reference between steps -- it re-finds its pings every time. A
-- marker lives about five seconds and then destroys itself; a wrapper stashed across a tick would
-- outlive the actor, and IsValid is blind to a pre-GC destroy.
--
-- Facing is yaw only. Tipping the plane to track a camera above or below it looks broken, and the
-- marker is meant to stand upright on the ground.
local facing = false
local dressed = {}      -- ping fullname -> true, so each marker is scaled and coloured once

local function scaleOne(p)
  local xy = tonumber(ctx.config.get("qol_ping_scale_xy")) or 1.0
  local z  = tonumber(ctx.config.get("qol_ping_scale_z")) or 1.0
  if xy == 1.0 and z == 1.0 then return end
  ctx.log.step("qol.ping.scale")
  pcall(function() p:SetActorScale3D({ X = xy, Y = xy, Z = z }) end)
end

local function faceStep(idle)
  local ms = tonumber(ctx.config.get("qol_ping_face_ms")) or 66
  local pings = liveInstances(qmap().pingClass)
  if #pings == 0 then
    -- two empty sweeps and the loop retires; `facing` must come down with it, including when the
    -- scheduler refuses the next step, or the next ping would find the loop "already running"
    if idle >= 1 or not deferOnly(ms, function() faceStep(idle + 1) end) then
      facing = false
      dressed = {}     -- no markers left: nothing to remember, and UE recycles object names
    end
    return
  end
  local who = (os.clock() - lastPingerAt) < 3.0 and lastPinger or nil
  local pal = (ctx.config.get("qol_ping_colors") and who) and paletteFor(who) or nil
  local face = ctx.config.get("qol_ping_face")
  ctx.log.step("qol.ping.eye")
  local eye  = face and ctx.uehelp.cameraLocation(localController()) or nil
  local yawOff = tonumber(ctx.config.get("qol_ping_face_yaw")) or 0.0
  for _, p in ipairs(pings) do
    local name
    pcall(function() name = p:GetFullName() end)
    if name then
      local d = dressed[name]
      if not d then d = { first = os.clock() }; dressed[name] = d end
      if not d.scaled then d.scaled = true; scaleOne(p) end
      -- The colour needs the pinger's name, which lands a tick or two after the marker does (the
      -- MULTI_Ping hook hands it to the scheduler rather than reading it inline). So a marker that
      -- has no palette YET is left for the next sweep -- but not forever: a ping whose owner never
      -- resolved is a real case (a late join, a name that would not unwrap) and it stays uncoloured
      -- rather than being re-tried every 66 ms for the rest of its life.
      if not d.coloured then
        if pal then
          d.coloured = true
          ctx.log.step("qol.ping.colour")
          if colourPing(p, pal) then ctx.log.debug("qol: ping coloured for " .. tostring(who)) end
        elseif os.clock() - d.first > 1.0 then
          d.coloured = true
        end
      end
    end
    if eye then
      local loc
      pcall(function() loc = ctx.uehelp.vec(p:K2_GetActorLocation()) end)
      if loc then
        local yaw = math.deg(math.atan(eye.Y - loc.Y, eye.X - loc.X)) + yawOff
        ctx.log.step("qol.ping.rotate")
        pcall(function()
          p:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw, Roll = 0.0 }, false)
        end)
      end
    end
  end
  ctx.log.step("qol.ping.swept")
  if not deferOnly(ms, function() faceStep(0) end) then facing = false end
end

-- Called from the construction notify. Touches nothing: it only schedules.
local function startFacing()
  if facing then return end
  facing = true
  if not deferOnly(tonumber(ctx.config.get("qol_ping_face_ms")) or 66,
                   function() faceStep(0) end) then
    facing = false
  end
end

--------------------------------------------------------------------- map: names + colors
-- The identity the palette hashes. It MUST be the same string every time it is asked, on every
-- machine, forever -- the whole point of a deterministic hash is that a player keeps their colour.
--
-- It was not. GetPlayerName() returns NIL on this build (probed live 2026-07-26), so every lookup
-- fell through to UniquePlayerID -- which arrives as an FString WRAPPER, not a string. tostring()
-- on a wrapper yields "FString: 000001AD19075BD8", the wrapper's ADDRESS, and UE hands back a
-- fresh wrapper per read: two reads one line apart gave ...5BD8 and ...5DD8. So the hash moved
-- every single time, which is why the map showed a different colour on every open and why a ping
-- never matched its owner's map icon. :ToString() unwraps it to the real value (the Steam ID),
-- which is stable for that player on every machine in the session.
--
-- Hence: never tostring() a wrapper here. Unwrap it, or return nil and let the caller skip.
local function unwrapStr(v)
  if type(v) == "string" then return v end
  if type(v) == "number" then return tostring(v) end
  if type(v) == "userdata" then
    local s; pcall(function() s = v:ToString() end)
    if type(s) == "string" then return s end
  end
  return nil
end

local function playerNameOf(pc)
  local nm
  pcall(function() nm = pc:GetPlayerName() end)
  nm = unwrapStr(nm)
  if nm and #nm > 0 then return nm end
  local ok, id = ctx.uehelp.get(pc, ctx.map.pawn and ctx.map.pawn.playerIdProp or "UniquePlayerID")
  if ok then
    local s = unwrapStr(id)
    if s and #s > 0 then return s end
  end
  return nil
end

-- SteamID64 -> the human name the game itself shows on nameplates. playerNameOf hands back the
-- raw UniqueID on this build (live 2026-07-29: labels read '7656119…'), but BP_SkyGameGameState
-- keeps a REPLICATED UniqueIDToPlayerNames array (rebuilt from the save's LastSeenPlayerName)
-- with GetPlayerNameFromUniqueID as its lookup -- PlayerName is an OUT param, so the call gets
-- the AddThirst {} placeholder. Successes cache for the world (applyAll clears); misses retry,
-- a player's name can land in the table after they do. Palette hashing stays keyed on the RAW
-- id everywhere so label/tooltip/ping colours keep agreeing.
local displayNames = {}
local function displayNameOf(raw)
  if raw == nil then return raw end
  raw = tostring(raw)
  if displayNames[raw] then return displayNames[raw] end
  if not raw:match("^%d%d%d%d%d%d%d%d%d+$") then return raw end  -- already a name, not an id
  local gs = ctx.uehelp.findFirst(qmap().gameStateClass)
  if gs then
    local out = {}
    local okCall = ctx.uehelp.call(gs, qmap().nameFromIdFn, raw, out)
    local nm = okCall and unwrapStr(out.PlayerName) or nil
    if nm and #nm > 0 then displayNames[raw] = nm return nm end
  end
  return raw
end

local function tintIcon(icon, name)
  if not ctx.uehelp.isValid(icon) then return end
  local pal = name and paletteFor(name)
  if pal then
    -- IMG_Player is a UObject PROPERTY, and a null one reads back as a truthy wrapper: calling
    -- straight off the read (icon[prop]:SetColorAndOpacity(...)) invokes a UFunction on nothing,
    -- which is a native access violation no pcall can catch. dressMap runs 150 ms after the map
    -- opens, so an icon being rebuilt right then -- a teammate leaving, a marker respawning -- is
    -- exactly the window that hits it. isValid() the read first, always.
    local okI, img = ctx.uehelp.get(icon, qmap().mapIconImgProp)
    if okI and ctx.uehelp.isValid(img) then
      pcall(function() img:SetColorAndOpacity({ R = pal.r, G = pal.g, B = pal.b, A = 1.0 }) end)
    end
  end
  if name and FText then
    pcall(function() icon:SetToolTipText(FText(tostring(displayNameOf(name)))) end)
  end
end

--------------------------------------------------------------------- map name labels
-- Always-visible name labels on the map: one raw TextBlock per live player, positioned straight
-- from the pawn's world location through WC_Map's own WorldToMapCoordinates. Deliberately NOT
-- through FriendsMarkers/SharedPlayerMapData -- their reconciliation is the "some players never
-- show up" bug (user 2026-07-29) these labels replace. Labels sit in CNV_Main with the same
-- centre anchors as the game's icons (offline RE of Create Map Player Icon) and follow at
-- 150 ms while the map is open: a token-guarded re-chained one-shot, never a free-running
-- timer, every UObject re-fetched fresh per pass. First construction failure latches the
-- feature off for the session (the fishing_ui capability-latch discipline).
local mapLabels = {}        -- name -> { tb = TextBlock }  (this world only; applyAll clears)
local labelsBroken = false  -- capability latch
local labelToken = 0

local function makeLabel(wc, canvas, name)
  local cls
  pcall(function() cls = StaticFindObject("/Script/UMG.TextBlock") end)
  if not cls then return nil end
  local addFn = (ctx.map.fishing and ctx.map.fishing.canvasAddFn) or "AddChildToCanvas"
  local tb
  local ok = pcall(function()
    tb = StaticConstructObject(cls, wc)
    tb:SetText(FText(tostring(displayNameOf(name))))
    local slot = canvas[addFn](canvas, tb)
    -- same anchor recipe the game gives its own icons; alignment (0.5, 1) floats the text
    -- just above the icon centre, autosize fits it to the name
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
    slot:SetAlignment({ X = 0.5, Y = 1.0 })
    slot:SetAutoSize(true)
    slot:SetZOrder(101)
    tb:SetRenderScale({ X = 0.7, Y = 0.7 })
    tb:SetVisibility(4)  -- SelfHitTestInvisible: visible, never eats map clicks
  end)
  if not (ok and tb) then return nil end
  -- the owner's palette colour, best-effort: FSlateColor marshals in as a plain table; a build
  -- that refuses it just keeps the default white text (readable either way)
  local pal = paletteFor(name)
  if pal then
    pcall(function()
      tb:SetColorAndOpacity({ SpecifiedColor = { R = pal.r, G = pal.g, B = pal.b, A = 1.0 },
                              ColorUseRule = 0 })
    end)
  end
  return tb
end

local function foldLabels()
  for _, l in pairs(mapLabels) do
    pcall(function() if ctx.uehelp.isValid(l.tb) then l.tb:SetVisibility(1) end end)
  end
end

-- The one map widget the player is actually looking at. The dock/ship-upgrade screen's minimap
-- is a WC_Map_C SUBCLASS the exact-class scan can never return (user 2026-07-29: dot on the
-- upgrade-station map, no name); it is checked FIRST, gated on its wrapper -- W_SimpleDock's
-- own isOpen? compiles to IsVisible && !IsInHideAni, and the wrapper hides ITSELF on close, so
-- that verdict is trustworthy. The big map's is NOT: WC_Map's own visibility flag reads true
-- even while its parent screen is hidden (proven live 23:07 -- the picker chose the hidden big
-- map over the open dock screen and the label landed on an invisible canvas), so the big map
-- is only ever the fallback, never the winner over an OPEN dock screen.
local function visibleMapComp()
  for _, dk in ipairs(liveInstances(qmap().dockUiClass)) do
    local open
    pcall(function()
      open = dk:IsVisible() and not dk[qmap().dockUiHideAniProp or "IsInHideAni"]
    end)
    if open then
      local okM, mw = ctx.uehelp.get(dk, qmap().dockUiMapProp)
      if okM and ctx.uehelp.isValid(mw) then return mw end
    end
  end
  for _, w in ipairs(liveInstances(qmap().mapCompClass)) do
    local vis; pcall(function() vis = w:IsVisible() end)
    if vis then return w end
  end
  return nil
end

-- TEMP DIAG (dock-map labels, 2026-07-29): one line per distinct event per chain, INFO so a
-- player repro + UE4SS.log tells the whole story. Remove once the station map shows names.
local labelDiagToken, labelDiagSeen = -1, {}
local function labelDiag(token, key, msg)
  if token ~= labelDiagToken then labelDiagToken, labelDiagSeen = token, {} end
  if labelDiagSeen[key] then return end
  labelDiagSeen[key] = true
  ctx.log.info("qol.labels[" .. tostring(token) .. "] " .. msg)
end

local function updateLabels(token, grace)
  if token ~= labelToken or labelsBroken then return end
  local wc = visibleMapComp()
  if not wc then
    foldLabels()
    -- The dock screen opens through an intro animation, and its arm trigger (the dock interact)
    -- fires before the widget reports visible: a freshly-triggered chain idles through a few
    -- passes instead of dying on the first. A chain that has already seen its map runs with no
    -- grace, so closing the map still retires it here; the open triggers re-arm.
    if (grace or 0) > 0 then
      labelDiag(token, "nowc", "no visible map widget yet (grace pass)")
      deferOnly(150, function() updateLabels(token, grace - 1) end)
    else
      labelDiag(token, "retired", "chain retired -- no map widget on screen")
    end
    return
  end
  -- Switched off with the map still OPEN. foldLabels is the only thing that collapses the
  -- TextBlocks, so returning bare here left every name drawn and frozen at its last position
  -- for the rest of the session. Keep the chain running (the map is up) so switching it back
  -- on takes effect live; closing the map still retires it through the branch above.
  if not ctx.config.get("qol_map_labels") then
    foldLabels()
    deferOnly(150, function() updateLabels(token) end)
    return
  end
  local wcClass; pcall(function() wcClass = wc:GetClass():GetFName():ToString() end)
  labelDiag(token, "wc:" .. tostring(wcClass), "map widget on screen: " .. tostring(wcClass))
  local canvas
  local okC, cv = ctx.uehelp.get(wc, qmap().mapCanvasProp)
  if okC and ctx.uehelp.isValid(cv) then canvas = cv end
  if not canvas then labelDiag(token, "nocanvas", "canvas prop missing/invalid on " .. tostring(wcClass)) end
  if canvas then
    -- which map widget these labels live on: a TextBlock built for the big map sits on the big
    -- map's canvas, and repositioning it while the DOCK map is the visible one draws nothing
    local wcFull; pcall(function() wcFull = wc:GetFullName() end)
    local seen = {}
    local nPawns, nNamed, nPlaced = 0, 0, 0
    for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
      if ctx.uehelp.isValid(pawn) then
        nPawns = nPawns + 1
        -- The owner comes from the PLAYER STATE, not the controller: APawn::Controller is
        -- replicated COND_OwnerOnly, so on a client every teammate's pawn reports no
        -- controller at all -- which is precisely the "some players never show up on the map"
        -- bug these labels exist to fix. PlayerState is replicated to everyone.
        local ps; pcall(function() ps = pawn:GetPlayerState() end)
        local nm = (ps and ctx.uehelp.isValid(ps)) and playerNameOf(ps) or nil
        if not nm then
          local pc; pcall(function() pc = pawn:GetController() end)
          nm = (pc and ctx.uehelp.isValid(pc)) and playerNameOf(pc) or nil
        end
        local loc = ctx.identity.locationOf(pawn)
        if nm and loc then
          nNamed = nNamed + 1
          seen[nm] = true
          local l = mapLabels[nm]
          if l and (not ctx.uehelp.isValid(l.tb) or l.wc ~= wcFull) then
            -- dead, or built for the OTHER map widget (big map <-> dock screen): collapse it on
            -- the canvas it lives on and rebuild on the one on screen
            pcall(function() if ctx.uehelp.isValid(l.tb) then l.tb:SetVisibility(1) end end)
            mapLabels[nm], l = nil, nil
          end
          if not l then
            local tb = makeLabel(wc, canvas, nm)
            if not tb then
              labelsBroken = true
              ctx.log.warn("qol: map name labels unavailable (TextBlock construction failed)")
              foldLabels()  -- the latch retires the chain: take the built ones down with it
              return
            end
            l = { tb = tb, wc = wcFull }
            mapLabels[nm] = l
          end
          -- the id can resolve to a real name AFTER the label was built (the GameState table
          -- fills as the save learns players): refresh the text when the resolution changes
          local disp = displayNameOf(nm)
          if l.disp ~= disp then
            pcall(function() l.tb:SetText(FText(tostring(disp))) end)
            l.disp = disp
          end
          local okW, r = ctx.uehelp.call(wc, qmap().mapWorldToMapFn,
            { X = loc.X, Y = loc.Y, Z = loc.Z })
          if okW and r then
            nPlaced = nPlaced + 1
            labelDiag(token, "pos:" .. nm,
              string.format("label '%s' at map (%.0f, %.0f)", nm, tonumber(r.X) or 0, tonumber(r.Y) or 0))
            pcall(function()
              l.tb:SetRenderTranslation({ X = r.X, Y = r.Y - 16 })
              l.tb:SetVisibility(4)
            end)
          else
            labelDiag(token, "nopos:" .. nm, "label '" .. nm .. "' -- " ..
              tostring(qmap().mapWorldToMapFn) .. " call failed")
          end
        end
      end
    end
    labelDiag(token, "count:" .. nPawns .. ":" .. nNamed .. ":" .. nPlaced,
      string.format("pass: %d pawn(s), %d named, %d placed", nPawns, nNamed, nPlaced))
    for nm, l in pairs(mapLabels) do
      if not seen[nm] then
        pcall(function() if ctx.uehelp.isValid(l.tb) then l.tb:SetVisibility(1) end end)
      end
    end
  end
  deferOnly(150, function() updateLabels(token) end)
end

-- Runs (deferred) each time the map opens: FriendsMarkers is WC_Map's own name->icon TMap, so
-- every teammate's icon gets that player's palette color + a hover tooltip with their name; the
-- local player's icon (WC_MainPlayer) gets their own.
local function dressMap()
  if not ctx.config.get("qol_map_names") then return end
  -- both map widgets: the big map, and the dock screen's minimap subclass the exact-class
  -- scan misses (it inherits FriendsMarkers/WC_MainPlayer, so the same dressing applies)
  local comps = liveInstances(qmap().mapCompClass)
  for _, w in ipairs(liveInstances(qmap().dockMapCompClass)) do comps[#comps + 1] = w end
  for _, wc in ipairs(comps) do
    pcall(function()
      local markers = wc[qmap().friendsMarkersProp]
      if markers and markers.ForEach then
        markers:ForEach(function(k, v)
          local key, icon = k, v
          pcall(function() key = k:get() end)
          pcall(function() icon = v:get() end)
          tintIcon(icon, tostring(key))
        end)
      end
    end)
    pcall(function()
      local mine = wc[qmap().mapSelfIconProp]
      local pc = localController()
      tintIcon(mine, pc and playerNameOf(pc) or nil)
    end)
  end
end

--------------------------------------------------------------------- arming
-- "owner:fn" -> true once its RegisterHook stuck. Qualified by OWNER, not the bare function name:
-- the map hooks and the controller hooks come from different classes, and two of them sharing a
-- short name (a plain "Open", say, after a mapping change) would leave the second never hooked.
-- Rebuild the chest UI's slot grid to fit the inventory it is showing. The widget builds its
-- grid ONCE per instance with 2x6 literals, so a 24-slot chest displayed 12 widgets forever.
-- Everything here is the proven-live 2026-07-27 sequence: ClearChildren, have the game's OWN
-- library build ceil(len/6)x6 fresh slots (a direct call from Lua goes through ProcessEvent,
-- where hooks and calls both work), collect the children back off the panel, hand them to
-- ChestSlots (a TArray of object refs DOES take a Lua table -- unlike struct arrays), and let
-- the widget's own SyncAndFill_Chest repopulate. Pure UI and idempotent: once the slot count
-- matches the inventory it fast-outs, and a half-failed rebuild heals on the next open.
-- Runs on host and clients alike -- clients see the replicated 24-slot inventory too.
--
-- The PLAYER side of the same widget gets the same treatment for the opposite reason: the game
-- DOES size it to the pack, but as a 3x7 main grid plus a separate backpack grid hidden behind
-- a switch button -- an upgraded pack reads as "only the first 3 rows of my inventory" (user
-- 2026-07-27). Rebuilt as ONE grid carrying every bag row, sized from the inventory ARRAY (so a
-- wrong Playerdata tier record cannot shrink it), backpack grid emptied, switch collapsed. The
-- game's fill loop skips the array's 8 leading hotbar entries, so bag slots = len - 8 -- a
-- whole number of 7-wide rows on every legal tier; anything else is left alone. The game's own
-- sizing pass cannot undo this: UpdateBackpackDisplayIfRequired rebuilds only when the TIER
-- changed since it last looked, and then this pass re-unifies 80 ms later.
-- The chest window is ONE vertical stack -- pack section on TOP, chest section below --
-- centered on screen in an auto-sized canvas slot (offline: W_ChestInventory CanvasPanelSlot_0,
-- anchors .5/.5, alignment .5/.5, position (0,-50)). With a 6-row pack AND a 6-row chest the
-- stack's desired height exceeds the 1080-unit design space (rig 2026-08-06: 714x1369), and
-- since the box is CENTER-anchored the overflow clips at the SCREEN TOP -- which is the pack
-- section: the user's "after closing and opening it its not showing my backpack's inv". Fit =
-- uniform RenderScale on the stack, shrinking it just enough that both ends stay on screen
-- (the -50 designer offset plus a hotbar reserve cost ~140 units of the height). Render
-- transforms scale hit-testing with the pixels, so tiles stay clickable; the show/hide
-- animation binds the two OVERLAY sections, never this box, so the two cannot fight. Runs
-- deferred after each rebuild: desired size is only current after a layout prepass.
local function fitChestWindows()
  local m = qmap()
  local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not (lib and pc) then return end
  local designH
  pcall(function()
    local sz = lib:GetViewportSize(pc)
    local sc = lib:GetViewportScale(pc)
    if sz and sc and sc > 0 then designH = sz.Y / sc end
  end)
  if not designH or designH <= 0 then return end
  for _, w in ipairs(FindAllOf(m.chestUiClass or "W_ChestInventory_C") or {}) do
    pcall(function()
      local fn = w:GetFullName()
      if not (fn and fn:find("Transient", 1, true)) then return end
      local main = w[m.chestUiMainBoxProp or "MainInventory"]
      local ov = main and main:GetParent()
      local vb = ov and ov:GetParent()
      if not vb then return end
      local h = 0
      pcall(function() h = vb:GetDesiredSize().Y end)
      if not (h and h > 0) then return end   -- the game's parked spare instance measures 0x0
      local s = math.min(1, (designH - 140) / h)
      vb:SetRenderScale({ X = s, Y = s })
      if s < 1 then
        ctx.log.debug(string.format("qol: chest window %.0f > %.0f units tall, scaled to %.2f",
          h, designH - 140, s))
      end
    end)
  end
end

local function rebuildChestGrids()
  local m = qmap()
  local cols = tonumber(m.chestGridCols) or 6
  local cdoPath = (m.slotGridLibPath or ""):gsub("%.([^%.]+)$", ".Default__%1")
  local cdo = StaticFindObject(cdoPath)
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not (pc and cdo and cdo:IsValid() and m.slotGridFn) then return end
  for _, w in ipairs(FindAllOf(m.chestUiClass or "W_ChestInventory_C") or {}) do
    local fn; pcall(function() fn = w:GetFullName() end)
    if fn and fn:find("Transient", 1, true) then
      pcall(function()
        local inv = w[m.chestUiInvRefProp or "ChestInventoryRef"]
        local invLen = inv and #inv.Inventory or 0
        local slots = w[m.chestUiSlotsProp or "ChestSlots"]
        local have = slots and #slots or 0
        -- Rebuild on ANY size mismatch, not just too-small: the fill loop overwrites only
        -- Inventory.Length tiles, so surplus tiles keep showing the PREVIOUS chest -- and those
        -- ghost tiles are live buttons whose cached CurItem duplicates on take (user 2026-07-31,
        -- via a 2-slot sorting chest under this 12+-tile grid). Compare whole rows: the builder
        -- only makes ceil(len/cols)*cols tiles, so comparing invLen itself never converges.
        if invLen > 0 and have ~= math.ceil(invLen / cols) * cols then
          local panel = w[m.chestUiPanelProp or "ChestInventory"]
          panel:ClearChildren()
          ctx.uehelp.call(cdo, m.slotGridFn, w, pc, panel, math.ceil(invLen / cols), cols, w, {})
          local n = panel:GetChildrenCount()
          local refs = {}
          for i = 0, n - 1 do refs[#refs + 1] = panel:GetChildAt(i) end
          w[m.chestUiSlotsProp or "ChestSlots"] = refs
          ctx.uehelp.call(w, m.chestUiSyncFn or "SyncAndFill_Chest")
          ctx.log.info("qol: chest UI grid rebuilt " .. have .. " -> " .. n .. " slots")
        end
      end)
      pcall(function()
        local inv = w[m.chestUiPlayerInvRefProp or "PlayerInventoryRef"]
        local invLen = inv and #inv.Inventory or 0
        local bag = invLen - (tonumber(m.invHotbarSlots) or 8)
        local panel = w[m.chestUiPlayerPanelProp or "GRID_PlayerInventory"]
        if bag > 21 and bag % 7 ~= 0 then
          ctx.log.debug("qol: player pack is " .. bag .. " bag slots -- not whole rows, leaving the grid alone")
        elseif bag > 21 and panel:GetChildrenCount() < bag then
          local have = panel:GetChildrenCount()
          panel:ClearChildren()
          pcall(function() w[m.chestUiBackpackPanelProp or "Grid_BackpackInventory"]:ClearChildren() end)
          ctx.uehelp.call(cdo, m.slotGridPlayerFn or "CreateItemSlotGridForPlayer",
            w, pc, panel, math.floor(bag / 7), 7, w, {})
          local n = panel:GetChildrenCount()
          local refs = {}
          for i = 0, n - 1 do refs[#refs + 1] = panel:GetChildAt(i) end
          w[m.chestUiPlayerSlotsProp or "PlayerSlots"] = refs
          -- the switch has nothing left to switch to: park the widget on the (now-complete)
          -- main view and hide the button (1 = Collapsed, 4 = SelfHitTestInvisible -- the same
          -- pair the widget's own open path writes)
          pcall(function() w[m.chestUiShowBackpackProp or "ShowBackpack"] = false end)
          pcall(function() w[m.chestUiMainBoxProp or "MainInventory"]:SetVisibility(4) end)
          pcall(function() w[m.chestUiBackpackBoxProp or "BackbackInventory"]:SetVisibility(1) end)
          pcall(function() w[m.chestUiBackpackToggleProp or "KeyItemsToggle"]:SetVisibility(1) end)
          ctx.uehelp.call(w, m.chestUiPlayerSyncFn or "SyncAndFill_Player")
          ctx.log.info("qol: chest UI player grid rebuilt " .. have .. " -> " .. n ..
            " slots (the whole pack, no backpack switch)")
        end
      end)
    end
  end
  -- after the grids settle into their real sizes, shrink-to-fit the whole window
  deferOnly(150, fitChestWindows)
end

-- The check stays a plain table lookup on purpose -- armHooks is re-run on every Character
-- construction notify, so resolving the UFunction path first would put a per-class function
-- enumeration in the storm's animal-spawn path.
local hooked = {}       -- key -> { preId, postId, path = funcPath }
local hookWorldPc       -- local controller fullname the current registrations belong to

-- World load GCs and RELOADS whole class chains -- live 2026-07-27: the chest-grid hook
-- registered fine in the MENU, the UI chain reloaded during LoadSave, and the grid built 2x6
-- with the hook sitting dead on the old class copy. A reloaded class keeps the SAME full path,
-- so staleness cannot be seen from here; instead every registration is dropped when the world
-- changes (detected below by the controller's instance name) and armHooks rebuilds them against
-- whatever is resident NOW. The unregister is a no-op on a fresh copy and removes our own hook
-- on a surviving one -- either way the re-register nets exactly one live hook.
local function clearHooks()
  for key, h in pairs(hooked) do
    if type(h) == "table" and h.path then pcall(UnregisterHook, h.path, h[1], h[2]) end
    hooked[key] = nil
  end
end

-- Returns true once this hook is live (now or on an earlier pass) -- the crouch keys need to know
-- whether the game's own key events are driving them or whether to fall back to a UE4SS bind.
local function armHook(pathOwner, fnName, tag, body)
  if not fnName then return false end
  local key = tostring(pathOwner) .. ":" .. fnName
  if hooked[key] then return true end
  local inst = ctx.uehelp.findFirst(pathOwner)
  if not inst then return false end
  local path = fullFuncPath(inst, fnName)
  if not path then return false end
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if ok then
    hooked[key] = { pre, post, path = path }
    ctx.log.debug("qol: hooked " .. path)
  end
  return ok == true
end

local function armHooks()
  local pl = ctx.map.player or {}
  -- Our own ship-inventory key calls ToggleInventory, so its hook body must touch no UObjects:
  -- it only schedules the sync. Same shape for the UI-close funnel.
  armHook(pl.controllerClass, qmap().toggleInvFn, "qol.inv", function()
    deferOnly(120, syncHotbar)
  end)
  armHook(pl.controllerClass, ctx.map.codex and ctx.map.codex.inputGameFn, "qol.uiclose", function()
    deferOnly(120, syncHotbar)
    deferOnly(150, restoreShipHotbar)   -- the wheel's transfer view borrowed the hotbar spot
  end)
  -- MULTI_Ping fires once per accepted ping ON EVERY MACHINE with the pinging controller as
  -- context: two guarded reads stash the pinger's name for the construction notify to use.
  -- MULTI_Ping fires once per accepted ping ON EVERY MACHINE with the pinging controller as
  -- context. Reading the name is two UObject calls (GetPlayerName, then UniquePlayerID:ToString),
  -- and a hook body is the one place those may not run: this one is reached through the game's own
  -- RPC dispatch, so the body hands the controller to the next tick and gets out. 0 ms is the very
  -- next scheduler pass -- long before the marker's sweep needs the name, and far too soon for a
  -- PlayerController to go anywhere.
  armHook(pl.controllerClass, pl.pingFn, "qol.ping", function(Context)
    local pc
    pcall(function() pc = Context:get() end)
    if not pc then return end
    deferOnly(0, function()
      if not ctx.uehelp.isValid(pc) then return end
      local nm = playerNameOf(pc)
      if nm then lastPinger, lastPingerAt = nm, os.clock() end
    end)
  end)
  armHook(qmap().mapCompClass, qmap().mapOpenFn, "qol.map", function()
    -- three dress passes: FriendsMarkers reconciles AFTER the open, so a single 150 ms pass
    -- missed icons born late (the "sometimes no tooltip/tint" report) -- idempotent, so cheap
    deferOnly(150, dressMap)
    deferOnly(700, dressMap)
    deferOnly(2000, dressMap)
    -- and the always-visible name labels (self-terminating chain; token orphans stale chains)
    labelToken = labelToken + 1
    local tok = labelToken
    deferOnly(200, function()
      labelDiag(tok, "arm", "chain armed by OpenMap")
      updateLabels(tok, 3)
    end)
  end)
  -- The chest UI builds a FIXED 2x6 slot grid -- RowCount/ColumnCount are LITERALS in
  -- W_ChestInventory's bytecode, and the build reaches BPL_UiFunctions through an
  -- EX_FinalFunction static call that UE4SS script hooks never see (proven live 2026-07-27:
  -- a hook armed before the first open fired on ProcessEvent calls but the game's own build
  -- sailed straight past it). So no flight rewrite: UI_OpenChestInventory IS hookable (it is
  -- a CustomEvent stub, reached via ProcessEvent even from the chest's Blueprint), and the
  -- grid is rebuilt from outside just after each open -- see rebuildChestGrids above.
  armHook(pl.controllerClass, qmap().openChestUiFn, "qol.chestui", function()
    deferOnly(80, rebuildChestGrids)
  end)
  -- Hold-to-crouch: the pawn's own LeftControl Pressed/Released pair is the key-up signal UE4SS
  -- cannot give us. Both bodies are state-only -- they record the edge and schedule the reconcile.
  -- Mapping order is the edge identity: index 1 is the DOWN function (bytecode-verified; see
  -- onCtrlKeyEvent).
  local pawnClass = ctx.map.pawn and ctx.map.pawn.class
  for i, fnName in ipairs(qmap().crouchKeyEventFns or {}) do
    local isDown = (i == 1)
    local live = armHook(pawnClass, fnName, "qol.crouchkey", function() onCtrlKeyEvent(isDown) end)
    if live then ctrlHooked = true end
  end
  -- Recall assist triggers. The interact bound event is the sure thing (component delegates
  -- broadcast through ProcessEvent, and every retrieve click starts with a hand on the dock);
  -- the custom events are belt-and-suspenders for whichever of them the dock UI reaches via
  -- ProcessEvent on this build -- a hook that never fires costs nothing. Bodies schedule only.
  armHook(qmap().dockClass, qmap().dockInteractFn, "qol.dock", function()
    deferOnly(0, function() armRecallWatch(120) end)
    -- The dock/ship-upgrade screen carries its own minimap, opened by W_SimpleDock's ubergraph
    -- calling OpenMap VM-INTERNALLY -- the qol.map hook below never sees it. The interact IS
    -- that screen's open moment: dress passes for icon tint/tooltips, and a label chain with
    -- enough grace to outlive the screen's intro animation.
    deferOnly(400, dressMap)
    deferOnly(1500, dressMap)
    labelToken = labelToken + 1
    local tok = labelToken
    deferOnly(300, function()
      labelDiag(tok, "arm", "chain armed by dock interact")
      updateLabels(tok, 10)
    end)
  end)
  -- The dock screen's Open is a CustomEvent stub the CONTROLLER calls cross-object
  -- (CLIENT_OpenDock -> UI_SimpleDock.Open: ProcessEvent, the proven-hookable family), so it is
  -- the precise "station screen just came up" moment. The interact hook above stays as the
  -- fallback: this one cannot arm until a W_SimpleDock instance exists for findFirst.
  armHook(qmap().dockUiClass, qmap().dockUiOpenFn, "qol.dockui", function()
    deferOnly(250, dressMap)
    labelToken = labelToken + 1
    local tok = labelToken
    deferOnly(300, function()
      labelDiag(tok, "arm", "chain armed by dock-screen Open")
      updateLabels(tok, 10)
    end)
  end)
  for _, fnName in ipairs(qmap().dockRecallFns or {}) do
    armHook(qmap().dockClass, fnName, "qol.recall", function()
      deferOnly(0, function() armRecallWatch(300) end)
    end)
  end
  -- Dying crouched used to bury the loot chest. Both RPC halves are hooked because which one runs
  -- depends on who is authoritative for this death; the correction itself is idempotent.
  for _, fnName in ipairs(qmap().deathLootStampFns or {}) do
    armHook(pl.controllerClass, fnName, "qol.deathloot", function()
      -- NO UObject reads here: mod damage reaches this function through the game's own
      -- Reduce Health, so this body can run inside a Lua->native->Lua chain.
      if lootStampPending then return end
      lootStampPending = true
      deferOnly(0, fixDeathLoot)
    end)
  end
end

-- Everything (re)applied when the LOCAL pawn changes -- world entry, respawn, hot reload.
local function applyAll()
  -- A brand-new local pawn means a new world, a reloaded save or a respawn -- and UE recycles
  -- object names, so a cache keyed by fullname can hand a FRESH chest the verdict reached about a
  -- dead one in the previous world (a 12-slot chest stuck at 12). Re-deciding costs one pass:
  -- the path fast-outs again the moment the work is already done.
  local step = ctx.log.step
  chestSized = {}
  chestGrowFails = {}
  facing = false     -- the old world's ping-facing loop cannot survive into this one
  mapLabels = {}     -- label widgets died with the old world's map; rebuild on next open
  displayNames = {}  -- id->name resolutions belong to the old world's GameState/save
  labelToken = labelToken + 1
  -- A new local controller instance = a world was (re)loaded = every class the last world's
  -- registrations lived on may be a dead copy. Drop them all; armHooks below rebuilds. Respawns
  -- and animal notifies keep the same controller, so this stays a no-op in steady play.
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if pcNow and pcNow ~= hookWorldPc then
    hookWorldPc = pcNow
    clearHooks()
  end
  step("qol.applyAll armHooks");   armHooks()
  step("qol.applyAll backpack");   applyBackpack()
  step("qol.applyAll chests");     sweepChests()
  step("qol.applyAll drops");      applyDrops()
  step("qol.applyAll hotbar");     syncHotbar()
  -- Standing on our own feet is the only moment "my character" is knowable in co-op, so the
  -- handle the flying-inventory fallback needs is taken now, not when it is already too late.
  step("qol.applyAll myCharacter"); myCharacter()
  -- A fresh pawn (world entry, respawn) is standing and holds no keys: drop any hold state left
  -- over from the last body, and let applyHold re-learn the standing capsule height off this one.
  -- The bench flag comes down with it -- bench releases its own seat on the same notify.
  holdKeys.c, holdKeys.ctrl, holdKeys.cHeld, benchSeatCrouch = false, false, false, false
  step("qol.applyAll hold");       applyHold()
  step("qol.applyAll done")
  -- the map widget (WC_Map) is created a beat after the pawn, so its OpenMap hook misses the
  -- first pass (seen live 2026-07-26); a couple of spaced retries catch every late class
  defer(10000, armHooks)
  defer(30000, armHooks)
end

local seenPawn = nil
local function onCharacter()
  -- animals are Characters too: this notify fires for every spawn, so gate on the local pawn
  -- actually being a new instance before doing the heavy sweeps. It must be the PLAYER's pawn --
  -- latching seenPawn onto a main-menu Character meant the real world's entry looked like a
  -- repeat and applyAll never ran for it.
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  local fn; if pawn then pcall(function() fn = pawn:GetFullName() end) end
  -- every trigger (world entry, respawn, a TEAMMATE joining -- their pawn constructing is
  -- what fired this notify): the host re-asserts crouch capability on all player pawns
  hostEnsureCrouchAll()
  if fn and fn ~= seenPawn then
    seenPawn = fn
    applyAll()
  else
    armHooks()   -- cheap and idempotent; catches late-loading widget classes
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "qol",
      { "qol.chestClass", "qol.dockClass", "qol.pingClass" }) then
    return false
  end

  -- keys
  --
  -- UE4SS's `Key` table has NO Ctrl/Shift/Alt members at all -- they live in a separate
  -- `ModifierKey` table, which only ever qualifies another key. So `Key["LEFT_CONTROL"]` was nil,
  -- the old `if ... Key[keyName]` guard quietly skipped the whole registration, and the Ctrl
  -- crouch bind never existed (verified against UE4SS.dll's own key-name table and live:
  -- Key.C/TAB/B are numbers, every Ctrl spelling is nil). RegisterKeyBind is perfectly happy with
  -- a raw Windows virtual-key code, so those keys are bound by number instead.
  local VK = {
    LEFT_CONTROL = 0xA2, RIGHT_CONTROL = 0xA3, CONTROL = 0x11, CTRL = 0x11,
    LEFT_SHIFT   = 0xA0, RIGHT_SHIFT   = 0xA1, SHIFT   = 0x10,
    LEFT_ALT     = 0xA4, RIGHT_ALT     = 0xA5, ALT     = 0x12,
  }
  -- Windows reports a Ctrl press as the sided code on some input paths and the generic one on
  -- others, so a sided name registers BOTH and the debounce below absorbs a press that arrives
  -- twice.
  local VK_ALSO = { [0xA2] = 0x11, [0xA3] = 0x11, [0xA0] = 0x10, [0xA1] = 0x10, [0xA4] = 0x12, [0xA5] = 0x12 }

  local function keyCodes(name)
    if type(name) == "number" then return { name } end
    if type(name) ~= "string" then return {} end
    local up = name:upper()
    if Key and type(Key[up]) == "number" then return { Key[up] } end
    local vk = VK[up]
    if not vk then return {} end
    local codes = { vk }
    if VK_ALSO[vk] then codes[#codes + 1] = VK_ALSO[vk] end
    return codes
  end

  -- One physical press must mean one action. Two things make that untrue here: the alias pair
  -- above can deliver the same Ctrl press twice, and a held key repeats -- and for a TOGGLE, an
  -- even number of triggers is indistinguishable from a dead keybind (press C, crouch, stand,
  -- crouch, stand -- nothing on screen). Runs on the input thread, so it touches nothing but
  -- Lua state and the clock.
  -- Short enough that letting go and pressing again straight away still ducks (hold-to-crouch
  -- makes that a normal thing to do), long enough to absorb both the sided/generic Ctrl pair
  -- arriving together and the OS key-repeat storm while a key is held down.
  local REPRESS = 0.12
  local function debounced(fn)
    local last = -1e9
    return function()
      local now = os.clock()
      if now - last < REPRESS then return end
      last = now
      fn()
    end
  end

  local function bind(keyName, tag, fn)
    local codes = keyCodes(keyName)
    if #codes == 0 then
      ctx.log.warn("qol: key '" .. tostring(keyName) .. "' is not a name UE4SS knows -- nothing bound")
      return false
    end
    local action = debounced(function() onGameThread(fn) end)   -- shared across a key's aliases
    local bound = false
    for _, code in ipairs(codes) do
      if pcall(function() RegisterKeyBind(code, ctx.log.guard(tag, action)) end) then bound = true end
    end
    if not bound then ctx.log.warn("qol: could not bind " .. tostring(keyName)) end
    return bound
  end

  if ctx.config.get("qol_crouch") then
    local cKey, ctrlKey = ctx.config.get("qol_crouch_key"), ctx.config.get("qol_crouch_key2")
    bind(cKey, "qol.crouch", cKeyDown)
    -- The Ctrl bind is a FALLBACK only: when the pawn's own LeftControl press/release events are
    -- hooked they drive the hold, and this would be a second, release-blind opinion on the same
    -- physical key.
    bind(ctrlKey, "qol.crouch2", function()
      if ctrlHooked then return end
      holdKeyDown("ctrl")
    end)
  end
  bind(ctx.config.get("qol_ship_chest_key"), "qol.shipchest", openShipChest)
  bind(ctx.config.get("qol_ship_inv_key"),   "qol.shipinv",   openInvOnShip)

  -- construction notifies (all multiplexed on the one Engine.Actor channel; work deferred)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().chestClass, function(obj)
    defer(150, function() sizeChest(obj) end)
    defer(1200, function() sizeChest(obj) end)   -- second pass: save-load init ordering
  end)
  -- the sorting chest sizes like a chest but to sort_chest_size, 3 rows (sweepChests reaches
  -- ones loaded from save; this reaches ones PLACED mid-session -- the pak template ships
  -- vanilla-chest-sized, 12)
  local scCls = ctx.map.sortchest and ctx.map.sortchest.class
  if scCls then
    local function sortWant() return tonumber(ctx.config.get("sort_chest_size")) or nil end
    ctx.uehelp.onNewInstance("/Script/Engine.Actor", scCls, function(obj)
      defer(150, function() sizeChest(obj, sortWant()) end)
      defer(1200, function() sizeChest(obj, sortWant()) end)
    end)
  end
  -- a dock built mid-session is the first moment its recall hooks CAN arm (armHook resolves
  -- the function path off a live instance); armHooks is idempotent, so this costs nothing
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().dockClass, function()
    defer(500, armHooks)
  end)
  -- No `obj` is captured and nothing is touched: the sweep re-finds every marker itself, so a
  -- notify for an actor UE is still building (or about to throw away) costs us nothing.
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().pingClass, function()
    startFacing()
  end)
  -- COALESCED. A save load streams in every animal on the map at once, and one queued action per
  -- Character meant dozens of identical 2s-later checks piling into the scheduler during the
  -- busiest seconds of the load -- the exact window the UE4SS action-list abort lives in. One
  -- pending check is worth the same as forty: onCharacter re-reads the world itself.
  local charPending = false
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    if charPending then return end
    charPending = true
    defer(2000, function() charPending = false; onCharacter() end)
  end)

  -- live tuning: any qol_* change re-applies the cheap visual state
  ctx.bus.on("config.changed", function(ev)
    if ev and type(ev.key) == "string" and ev.key:sub(1, 4) == "qol_" then
      -- (recall needs no re-apply here: the watch reads qol_recall_mult fresh every pass)
      chestSized = {}
      chestGrowFails = {}
      onGameThread(function() applyDrops(); syncHotbar(); sweepChests() end)
    end
  end)

  -- TEMP DIAG (dock-map labels, 2026-07-29): `sps_maplab` prints every input to the label
  -- decision on demand; `sps_maplab go` force-arms a fresh chain. Reads live UObjects, so it is
  -- user-triggered only, on the game thread -- the same work a normal label pass does. Remove
  -- together with the labelDiag breadcrumbs once the station map shows names.
  pcall(function()
    RegisterConsoleCommandHandler("sps_maplab", function(_, params)
      local sub = (params and params[1]) or "status"
      onGameThread(function()
        local L = ctx.log.info
        L("maplab: qol_map_labels=" .. tostring(ctx.config.get("qol_map_labels")) ..
          " broken=" .. tostring(labelsBroken) .. " token=" .. tostring(labelToken))
        local n = 0
        for _, w in ipairs(liveInstances(qmap().mapCompClass)) do
          n = n + 1
          local vis; pcall(function() vis = w:IsVisible() end)
          L("maplab: big map #" .. n .. " visible=" .. tostring(vis))
        end
        if n == 0 then L("maplab: no big-map (" .. tostring(qmap().mapCompClass) .. ") instances") end
        local d = 0
        for _, dk in ipairs(liveInstances(qmap().dockUiClass)) do
          d = d + 1
          local vis, hide
          pcall(function() vis = dk:IsVisible() end)
          pcall(function() hide = dk[qmap().dockUiHideAniProp or "IsInHideAni"] end)
          local okM, m = ctx.uehelp.get(dk, qmap().dockUiMapProp)
          local mOk = okM and ctx.uehelp.isValid(m)
          local cls; pcall(function() cls = mOk and m:GetClass():GetFName():ToString() or nil end)
          L("maplab: dock UI #" .. d .. " visible=" .. tostring(vis) .. " hideAni=" .. tostring(hide) ..
            " mapProp=" .. tostring(mOk) .. " mapClass=" .. tostring(cls))
        end
        if d == 0 then L("maplab: no dock UI (" .. tostring(qmap().dockUiClass) .. ") instances") end
        local wc = visibleMapComp()
        local cls; pcall(function() cls = wc and wc:GetClass():GetFName():ToString() or nil end)
        L("maplab: visibleMapComp -> " .. tostring(cls))
        local built = 0
        for nm, l in pairs(mapLabels) do
          built = built + 1
          L("maplab: label '" .. tostring(nm) .. "' valid=" .. tostring(ctx.uehelp.isValid(l.tb)))
        end
        L("maplab: " .. built .. " label widget(s) built this world")
        if sub == "go" then
          labelToken = labelToken + 1
          local tok = labelToken
          L("maplab: chain force-armed, token=" .. tostring(tok))
          deferOnly(150, function() updateLabels(tok, 20) end)
        end
      end)
      return true
    end)
  end)

  -- The bench feature's crouch entry: sitting crouches THROUGH this module so the death-loot
  -- fix keeps seeing crouch state it can trust, and so the crouch keys reconcile against the
  -- seat instead of fighting it (applyHold treats the flag as an unconditional "crouched").
  -- The pawn arg is a SAFETY CHECK, not a target: this module only ever reconciles the local
  -- player's OWN pawn (applyHold -> ownPawn). If a caller hands us some other body -- the
  -- listen-server localPawn fallback can be a teammate's -- the flag must not flip.
  ctx.services.setCrouch = function(pawn, want)
    if pawn ~= nil then
      local own = ctx.uehelp.ownPawn()
      if own and not ctx.uehelp.sameObject(pawn, own) then return end
    end
    benchSeatCrouch = want and true or false
    applyHold()
  end

  -- The dev test kit's entry point for growing the pack. It goes THROUGH applyBackpack rather
  -- than calling SetInventoryUpgradeLevel itself for one reason: every guard that keeps a tier
  -- change from destroying the player save lives in there (host check, the recorded-tier
  -- comparison, the refusal to shrink onto occupied slots, and the wait for the array to really
  -- be the tier's length before the record is stamped). Set the config value, then call this.
  ctx.services.applyBackpack = applyBackpack

  -- hot reload mid-session: a pawn may already exist
  defer(1500, onCharacter)
  ctx.log.info("qol: chests x2, backpack, crouch -- TAP " .. tostring(ctx.config.get("qol_crouch_key")) ..
    "/" .. tostring(ctx.config.get("qol_crouch_key2")) .. " toggles, HOLDING either crouches" ..
    " for the hold, ship chest (" ..
    tostring(ctx.config.get("qol_ship_chest_key")) .. "), ship inventory (" ..
    tostring(ctx.config.get("qol_ship_inv_key")) .. "), recall x" ..
    tostring(ctx.config.get("qol_recall_mult")) .. ", UI + pings + map names armed")
  return true
end

return F
