-- Dev: `sps_testkit` -- fast-forward a save to "every mod feature is testable right now".
--
-- A fresh world has none of the progression the mod's features hang off: no researched cards, no
-- recipes, a 29-slot pack, and none of the pak items. Foraging all that by hand before every test
-- pass is the slow part of testing this mod, so this does it in one command.
--
--   sps_testkit                  research + recipes + backpack + the default item groups + power
--   sps_testkit research         every research card marked done, every recipe id unlocked
--   sps_testkit pack [tier]      backpack tier (0/1/3/7 -> 29/36/43/50 slots; default 7)
--   sps_testkit items [group]    grant one group (see GROUPS); no group = the default set
--   sps_testkit power            charge every placed battery nearby and force powered devices on
--   sps_testkit status           what is unlocked / what would be granted -- changes nothing
--
-- HOST ONLY. Playerdata is server-authoritative and every inventory write in this mod is
-- host-side; on a client this does nothing but say so.
--
-- Two things here are worth knowing before changing them:
--
--   * "Upgrading the crafting table / research station" is NOT an actor property. There is no
--     level field on BP_CraftingTable, BP_AdvancedCraftingTable or BP_ResearchTable at all -- the
--     station tiers are DB_Researchables rows flagged IsLevel (LvL_2..LvL_9, LVL_ENG_2..5). So
--     unlocking research IS the upgrade, and mapping.progress.levelIds names the tier rows purely
--     so `status` can report them.
--
--   * Granting items has two paths and the fast one is unproven. BC_InventorySystem's
--     AddItemForPlayer takes a real quantity and puts things straight in the pack; the mod has
--     never called it (see mapping stock.addPlayerFn). DEBUG_SpawnItems, which the rest of the
--     mod uses, delivers exactly ONE per call and does not touch the inventory at all -- it drops
--     a free-falling actor at the player +500Z with FlyToPlayer=false (core/items.lua:37-62). So
--     this tries AddItemForPlayer first and VERIFIES with GetAmtOfItem that the count actually
--     moved; only if it did not does it fall back to the spawner, and then it flies the drops in
--     the way features/fishing.lua's deliverRodActor does. Never trust the return value of
--     either path -- the recount is the proof.
local F = {}
local ctx

local CHUNK = 25       -- research/recipe writes per game-thread slice
local CHUNK_MS = 60    -- ...and the gap between slices, so a 260-call sweep cannot hitch a frame
local FLY_MS = 700     -- fishing.lua's proven delay before sweeping up fresh drops

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

-- The scheduler already routes ExecuteWithDelay onto the game thread; no second hop.
local function defer(ms, fn) pcall(ExecuteWithDelay, ms, fn) end

local function pmap() return (ctx.map and ctx.map.progress) or {} end
local function smap() return (ctx.map and ctx.map.stock) or {} end
local function wmap() return (ctx.map and ctx.map.wand) or {} end

local function unwrap(v)
  if type(v) == "userdata" then pcall(function() local g = v:get() v = g end) end
  return v
end

local function controller()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  return ctx.uehelp.isValid(pc) and pc or nil
end

local function pawnNow()
  return ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
end

local function hostOnly(what)
  if ctx.net.isHost() then return true end
  ctx.log.warn("test_kit: " .. what .. " is host-only (Playerdata and every inventory write here " ..
               "are server-authoritative) -- nothing done")
  return false
end

---------------------------------------------------------------- what the kit hands out
-- Rows resolve through core/items.lua (DB_Items row -> BP_<row>_Item_C, with its name variants);
-- `cls` entries name an item-actor class outright, for the pak items whose rows this file should
-- not be the one to know. Quantities are "enough to test with", not "enough to build a base".
local function modRows()
  local w, c, h, f = wmap(), ctx.map.codex or {}, ctx.map.handbook or {}, ctx.map.fishing or {}
  local rows = w.itemRows or {}
  return {
    { row = rows.mundane },    { row = rows.hydration },
    { row = rows.electric },   { row = rows.charged },      -- the charged wand powers casts
    { row = c.itemRow },       { row = h.itemRow },
    { row = f.diamondRow },    { row = "SortingChest" },
  }
end

local GROUPS = {
  -- The things a fresh save cannot get quickly, or at all without the content pak.
  mod = { label = "mod + pak items", build = modRows },
  -- Everything the sorting chest and the powered-device tests need.
  power = { label = "power rig", items = {
    { row = "Battery", n = 4 }, { row = "CableConnectorSmall", n = 30 },
    { row = "Solarpanel", n = 4 }, { row = "Skyturbine", n = 2 },
    { row = "Generator", n = 1 }, { row = "EnergyFurnace", n = 1 },
    { row = "Energy_Network_Display", n = 1 },
  } },
  -- Airship repair + dock work.
  ship = { label = "ship kit", items = {
    { row = "Repairkit", n = 5 }, { row = "AirshipTechComp", n = 10 },
    { row = "ScrapMetal", n = 20 }, { row = "AirshipLevelBlueprint", n = 3 },
  } },
  tools = { label = "tools", items = {
    { row = "AxeDiamond", n = 1 }, { row = "PickaxeDiamond", n = 1 }, { row = "HoeDiamond", n = 1 },
    { row = "Axe", n = 1 }, { row = "Pickaxe", n = 1 },   -- the 20/30/40 Unlit damage tiers
    { row = "Hammer", n = 1 }, { row = "Watercan", n = 1 }, { row = "FishingRod", n = 1 },
    { row = "Weather_Station", n = 2 },                   -- the lightning rod
  } },
  mats = { label = "bulk materials", items = {
    { row = "Log", n = 100 }, { row = "Stick", n = 50 }, { row = "Stone", n = 100 },
    { row = "Iron", n = 50 }, { row = "IronOre", n = 50 }, { row = "Copper", n = 50 },
    { row = "CopperOre", n = 50 }, { row = "Glass", n = 30 }, { row = "Clay", n = 30 },
    { row = "Brick", n = 30 }, { row = "Cloth", n = 30 }, { row = "Cotton", n = 30 },
    { row = "Leaf", n = 30 }, { row = "Beeswax", n = 20 }, { row = "Diamond", n = 20 },
    { row = "Cobalt", n = 20 }, { row = "Silicon", n = 20 }, { row = "Circuitboard", n = 20 },
    { row = "ElectricalComponent", n = 20 },
  } },
  -- Both rites' five corner offerings, off mapping.ritual so a moved class only changes there.
  ritual = { label = "rite offerings", build = function()
    local r, out, seen = ctx.map.ritual or {}, {}, {}
    for _, key in ipairs({ "hydrationOfferings", "electrickOfferings" }) do
      for _, cn in pairs(r[key] or {}) do
        -- a mapped offering is one class or a LIST (clay also drops as a GrabItem); grant the
        -- plain inventory form, exactly as dev/ritual_kit.lua does
        local cls = cn
        if type(cn) == "table" then
          cls = cn[1]
          for _, c in ipairs(cn) do if c:find("_Item_C$") then cls = c end end
        end
        if cls and not seen[cls] then seen[cls] = true; out[#out + 1] = { cls = cls, n = 3 } end
      end
    end
    return out
  end },
  -- A seat to sit on and something to sort into.
  build = { label = "buildables", items = {
    { row = "Chest", n = 4 }, { row = "CraftingTable", n = 1 }, { row = "ResearchTable", n = 1 },
    { row = "AdvancedCraftingTable", n = 1 }, { row = "Deco_Bench_White", n = 2 },
    { row = "Growbox", n = 2 }, { row = "Torch", n = 10 },
  } },
}

-- What a bare `sps_testkit items` grants: the hard-to-get things first, bulk last, because the
-- pack fills up and whatever does not fit is reported rather than silently dropped on the floor.
local DEFAULT_GROUPS = { "mod", "tools", "power", "ship", "ritual", "mats" }

local function groupItems(name)
  local g = GROUPS[name]
  if not g then return nil end
  local list = g.items or (g.build and g.build()) or {}
  local out = {}
  for _, it in ipairs(list) do
    if it.row or it.cls then out[#out + 1] = { row = it.row, cls = it.cls, n = it.n or 1 } end
  end
  return out, g.label
end

---------------------------------------------------------------- research + recipes
local function researchIds()
  local p = pmap()
  local ids, seen = {}, {}
  -- Live enumeration first: the GameInstance's own id->row map covers pak-added cards and a
  -- future game update without anyone editing mapping.lua.
  local gi = p.giClass and ctx.uehelp.findFirst(p.giClass)
  if ctx.uehelp.isValid(gi) and p.researchMapProp then
    pcall(function()
      gi[p.researchMapProp]:ForEach(function(k, _)
        local v = tonumber(unwrap(k))
        if v and not seen[v] then seen[v] = true; ids[#ids + 1] = v end
      end)
    end)
  end
  if #ids > 0 then return ids, "DB_ResearchMap" end
  for _, v in ipairs(p.researchIds or {}) do
    if not seen[v] then seen[v] = true; ids[#ids + 1] = v end
  end
  return ids, "mapping.progress.researchIds"
end

local function recipeIds()
  local out = {}
  for _, r in ipairs(pmap().recipeRanges or {}) do
    for i = r[1], r[2] do out[#out + 1] = i end
  end
  return out
end

-- Walk a list in slices so a few hundred reflected calls never land in one frame.
local function inSlices(list, apply, done)
  local i = 1
  local function slice()
    local stop = math.min(i + CHUNK - 1, #list)
    for k = i, stop do pcall(apply, list[k]) end
    i = stop + 1
    if i <= #list then defer(CHUNK_MS, slice) elseif done then done() end
  end
  slice()
end

-- HasPlayerResearch?(id, out CanResearch, out IsResearched). Both out-params key into the FIRST
-- fresh table by NAME, so `next()` on it would hand back whichever of the two hashed first --
-- CanResearch is the wrong answer and reads plausibly. Merge and look the name up.
local function isResearched(pc, id)
  local p = pmap()
  if not p.researchHasFn then return nil end
  local a, b = {}, {}
  if not ctx.uehelp.call(pc, p.researchHasFn, id, a, b) then return nil end
  local merged = {}
  for k, v in pairs(a) do merged[k] = v end
  for k, v in pairs(b) do merged[k] = v end
  local v = merged.IsResearched
  if v == nil then return nil end
  return unwrap(v) == true
end

function F.unlockAll(done)
  if not hostOnly("unlocking research") then return end
  local pc, p = controller(), pmap()
  if not pc then return ctx.log.warn("test_kit: no player controller (load a world first)") end
  if not (p.researchSaveFn and p.researchFieldId and p.researchFieldDone and p.recipeAddFn) then
    return ctx.log.warn("test_kit: mapping.progress is incomplete -- research unlock skipped")
  end

  local ids, src = researchIds()
  local rids = recipeIds()
  ctx.log.info(string.format("test_kit: unlocking %d research cards (from %s) and %d recipe ids...",
    #ids, src, #rids))

  inSlices(ids, function(id)
    ctx.uehelp.call(pc, p.researchSaveFn, {
      [p.researchFieldId] = id,
      [p.researchFieldDone] = true,
    })
  end, function()
    inSlices(rids, function(rid)
      ctx.uehelp.call(pc, p.recipeAddFn, rid)
    end, function()
      -- Prove it rather than announce it: re-ask the game about a couple of ids.
      local checked, ok = 0, 0
      for _, id in ipairs({ 9, 10, 28, 3003 }) do
        local r = isResearched(pc, id)
        if r ~= nil then checked = checked + 1; if r then ok = ok + 1 end end
      end
      if checked > 0 then
        ctx.log.info(string.format("test_kit: research done -- %d/%d spot-checked ids read back " ..
          "as researched (station tiers included)", ok, checked))
      else
        ctx.log.info("test_kit: research writes issued (HasPlayerResearch? unavailable to verify)")
      end
      ctx.log.info("test_kit: open a CRAFTING TABLE once -- its interact runs " ..
                   "FixMissingCraftingRecipies, which reconciles the recipe list")
      if done then done() end
    end)
  end)
end

---------------------------------------------------------------- items
local function invOf(pawn)
  local svc = ctx.services.chestIndex
  if svc and svc.invOf then
    local inv = svc.invOf(pawn)
    if inv then return inv end
  end
  local ok, inv = ctx.uehelp.get(pawn, smap().invProp or "InventorySystem")
  return (ok and ctx.uehelp.isValid(inv)) and inv or nil
end

local function probeFor(cls, qty)
  local svc = ctx.services.chestIndex
  if svc and svc.probeFor then return svc.probeFor(cls, qty) end
  local w = wmap()
  return {
    [w.slotItemField or "Item"] = cls,
    [w.slotQtyField or "Quantity"] = qty or 0,
    [w.slotSavedataField or "AdditionalSavedata"] = "",
  }
end

local function amtOf(inv, cls)
  local out = {}
  if not ctx.uehelp.call(inv, smap().amtFn, probeFor(cls), out) then return nil end
  return tonumber(unwrap(out.Amount))
end

local function freeSlots(inv)
  local out = {}
  if not ctx.uehelp.call(inv, smap().freeSlotsFn, out) then return nil end
  local _, v = next(out)
  return tonumber(unwrap(v))
end

-- Hand a loose item actor to the player through the game's own pickup path -- the treatment
-- features/fishing.lua's deliverRodActor applies to rods, which is the only thing proven to get
-- a DEBUG_SpawnItems drop into the pack reliably.
local function deliverActor(a, pawn)
  if not (ctx.uehelp.isValid(a) and ctx.uehelp.isValid(pawn)) then return false end
  local loc
  pcall(function() loc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end)
  if not loc then return false end
  ctx.uehelp.set(a, "ManualPickup", false)
  ctx.uehelp.set(a, "NoPickupTime", 0)
  ctx.uehelp.set(a, "FlyToPlayer", true)
  local at = { X = loc.X, Y = loc.Y, Z = loc.Z + 120 }
  return ctx.uehelp.call(a, "K2_SetActorLocation", at, false, {}, false)
      or ctx.uehelp.call(a, "K2_SetActorLocation", at, true)
end

-- Every non-CDO actor of a class lying loose in the world. The Default__ filter is mandatory:
-- FindAllOf returns the class default object too, and it is not a droppable thing.
local function looseActors(shortClass)
  local out = {}
  for _, a in ipairs(ctx.uehelp.findAll(shortClass)) do
    if ctx.uehelp.isValid(a) then
      local fn = ""
      pcall(function() fn = a:GetFullName() end)
      if not fn:find("Default__", 1, true) then out[#out + 1] = a end
    end
  end
  return out
end

-- One item type. Returns delivered, how ("add" | "spawn" | "none"), short class name.
local function grant(pc, pawn, inv, spec)
  local cls, short
  if spec.cls then
    short = spec.cls
    local it = ctx.map.items or {}
    local asset = it.assetDir and (it.assetDir .. short:gsub("_C$", "") .. "." .. short) or nil
    cls = ctx.uehelp.classByName(short, asset)
  elseif spec.row then
    cls, short = ctx.items.classFor(spec.row)
  end
  if not cls then return 0, "none", short or spec.row or "?" end

  local want = spec.n or 1
  local before = inv and amtOf(inv, cls) or nil

  -- Fast path: the game's own quantity-aware inventory add.
  if inv and smap().addPlayerFn then
    local out = {}
    local ok = ctx.uehelp.call(inv, smap().addPlayerFn, probeFor(cls, want), true, false, out)
    if not ok then ok = ctx.uehelp.call(inv, smap().addPlayerFn, probeFor(cls, want), true, false) end
    if ok and before then
      local after = amtOf(inv, cls)
      if after and after > before then return after - before, "add", short end
    end
  end

  -- Fallback: the debug spawner, one actor per call, then fly the drops in.
  local seen = {}
  for _, a in ipairs(looseActors(short)) do
    local fn = ""
    pcall(function() fn = a:GetFullName() end)
    seen[fn] = true
  end
  local n = math.min(want, 60)   -- the spawner is one deferred actor spawn each; stay sane
  for _ = 1, n do
    pcall(function() pc:DEBUG_SpawnItems(cls, 1) end)
  end
  defer(FLY_MS, function()
    for _, a in ipairs(looseActors(short)) do
      local fn = ""
      pcall(function() fn = a:GetFullName() end)
      if not seen[fn] then deliverActor(a, pawn) end
    end
  end)
  return n, "spawn", short
end

function F.giveGroup(name)
  if not hostOnly("granting items") then return end
  local pc, pawn = controller(), pawnNow()
  if not (pc and pawn) then
    return ctx.log.warn("test_kit: no controller/pawn yet (load a world first)")
  end
  local inv = invOf(pawn)

  local names = name and { name } or DEFAULT_GROUPS
  if name and not GROUPS[name] then
    local keys = {}
    for k in pairs(GROUPS) do keys[#keys + 1] = k end
    table.sort(keys)
    return ctx.log.info("test_kit: unknown group '" .. name .. "' -- try: " .. table.concat(keys, ", "))
  end

  local added, spawned, missed, stopped = 0, 0, {}, false
  for _, gname in ipairs(names) do
    local list, label = groupItems(gname)
    for _, spec in ipairs(list or {}) do
      -- Stop cleanly at a full pack instead of raining the rest onto the floor.
      local free = inv and freeSlots(inv)
      if free and free <= 1 then
        stopped = true
        ctx.log.warn(string.format("test_kit: pack full at group '%s' -- stash some and re-run " ..
          "(`sps_testkit pack 7` grows it to 50 slots)", gname))
        break
      end
      local got, how, short = grant(pc, pawn, inv, spec)
      if how == "add" then added = added + got
      elseif how == "spawn" then spawned = spawned + got
      else missed[#missed + 1] = short end
    end
    if stopped then break end
    ctx.log.info("test_kit: granted group '" .. gname .. "' (" .. (label or gname) .. ")")
  end

  ctx.log.info(string.format("test_kit: %d item(s) added straight to the pack, %d spawned as " ..
    "drops and flown in", added, spawned))
  if #missed > 0 then
    ctx.log.warn("test_kit: could not resolve a class for: " .. table.concat(missed, ", ") ..
                 " (content pak not mounted this session?)")
  end
  -- The hotbar and the inventory widget both cache; nudge them the way wand.lua does.
  local m = wmap()
  pcall(function()
    local c = pawn[m.localControllerProp or "LocalController"]
    local hb = c and c[m.hotbarWidgetProp or "UI_Hotbar"]
    if ctx.uehelp.isValid(hb) and m.hotbarRefreshFn then ctx.uehelp.call(hb, m.hotbarRefreshFn) end
  end)
  if inv and m.invChangedFn then ctx.uehelp.call(inv, m.invChangedFn) end
end

---------------------------------------------------------------- backpack
function F.pack(tier)
  tier = tonumber(tier) or 7
  if not ({ [0] = true, [1] = true, [3] = true, [7] = true })[tier] then
    return ctx.log.warn("test_kit: backpack tier must be 0, 1, 3 or 7 (29/36/43/50 slots)")
  end
  if not hostOnly("changing the backpack tier") then return end
  ctx.config.set("qol_backpack_level", tier)
  if ctx.services.applyBackpack then
    ctx.services.applyBackpack()
    ctx.log.info("test_kit: backpack tier " .. tier .. " requested -- qol applies it on a short " ..
                 "delay and refuses anything that would not fit")
  else
    ctx.log.warn("test_kit: qol is not loaded, so the tier was only recorded in config -- " ..
                 "it will apply on the next world entry")
  end
end

---------------------------------------------------------------- power
function F.power()
  if not hostOnly("forcing power") then return end
  local p = pmap()
  local charged, forced = 0, 0

  for _, b in ipairs(looseActors(p.batteryClass or "BP_Battery_Placeable_C")) do
    -- strike_world already owns "charge a battery to full"; reuse it so there is one
    -- implementation of the component-vs-replication-mirror rule, not two.
    if ctx.services.chargeBattery then
      pcall(ctx.services.chargeBattery, b, "test_kit")
      charged = charged + 1
    end
  end

  -- Powered mod devices: flip the replicated EnoughPower flag so the sorting chest runs without
  -- anyone having to build a generator and string cable first. This is a smoke-test shortcut --
  -- the real network still decides the moment anything recalculates.
  local sc = ctx.map.sortchest or {}
  if sc.class and sc.deviceGetFn and sc.enoughProp then
    for _, a in ipairs(looseActors(sc.class)) do
      local ok, dev = ctx.uehelp.call(a, sc.deviceGetFn)
      dev = ok and dev or nil
      if dev == nil then ok, dev = ctx.uehelp.get(a, p.energyDeviceProp or "") end
      if ctx.uehelp.isValid(dev) and ctx.uehelp.set(dev, sc.enoughProp, true) then
        forced = forced + 1
      end
    end
  end

  ctx.log.info(string.format("test_kit: %d battery/batteries charged, %d device(s) forced powered",
    charged, forced))
  if charged == 0 and forced == 0 then
    ctx.log.info("test_kit: nothing to power near you -- place a battery or the sorting chest first")
  end
end

---------------------------------------------------------------- status
function F.status()
  local pc, pawn = controller(), pawnNow()
  ctx.log.info("test_kit: host=" .. tostring(ctx.net.isHost()) ..
               " controller=" .. tostring(pc ~= nil) .. " pawn=" .. tostring(pawn ~= nil))
  local ids, src = researchIds()
  ctx.log.info(string.format("test_kit: %d research ids (%s), %d recipe ids, %d tier rows",
    #ids, src, #recipeIds(), #(pmap().levelIds or {})))
  if pc then
    local done, checked = 0, 0
    for _, id in ipairs(pmap().levelIds or {}) do
      local r = isResearched(pc, id)
      if r ~= nil then checked = checked + 1; if r then done = done + 1 end end
    end
    ctx.log.info(string.format("test_kit: station tiers researched: %d/%d", done, checked))
  end
  if pawn then
    local inv = invOf(pawn)
    local free = inv and freeSlots(inv)
    ctx.log.info("test_kit: free pack slots: " .. tostring(free) ..
                 " (config qol_backpack_level=" .. tostring(ctx.config.get("qol_backpack_level")) .. ")")
  end
  local names = {}
  for k in pairs(GROUPS) do names[#names + 1] = k end
  table.sort(names)
  ctx.log.info("test_kit: item groups -- " .. table.concat(names, ", ") ..
               "  (default: " .. table.concat(DEFAULT_GROUPS, ", ") .. ")")
end

---------------------------------------------------------------- everything
-- Order matters. qol applies a backpack tier on a 5 s delay (deliberately -- it has to land after
-- the game's own login apply, see qol.applyBackpack), so granting immediately would pour ~40 item
-- types into a 29-slot pack and stop half way. Research first, then wait out the resize, then fill.
local PACK_SETTLE_MS = 7000

function F.all()
  F.pack(7)
  F.unlockAll(function()
    ctx.log.info("test_kit: waiting for the backpack resize to land before stocking it...")
    defer(PACK_SETTLE_MS, function()
      F.giveGroup(nil)
      F.power()
      ctx.log.info("test_kit: done. Open a crafting table once to reconcile recipes, then " ..
                   "`sps_fish_mini` for the fishing skillshot and `sps_evil unlock all` for the Unlit.")
    end)
  end)
end

function F.init(c)
  ctx = c
  ctx.services.testKit = F   -- drivable from dev/remote's exec channel too

  pcall(function()
    RegisterConsoleCommandHandler("sps_testkit", function(_, params)
      local a = (params and params[1] or ""):lower()
      local b = params and params[2] or nil
      onGameThread(function()
        if a == "" or a == "all" then F.all()
        elseif a == "research" or a == "unlock" then F.unlockAll()
        elseif a == "items" or a == "give" then F.giveGroup(b and b:lower() or nil)
        elseif a == "pack" or a == "backpack" then F.pack(b)
        elseif a == "power" then F.power()
        elseif a == "status" then F.status()
        elseif GROUPS[a] then F.giveGroup(a)
        else
          ctx.log.info("usage: sps_testkit [all|research|items [group]|pack [tier]|power|status]")
        end
      end)
      return true
    end)
  end)

  ctx.log.info("test_kit: `sps_testkit` unlocks all research/recipes, grows the pack and stocks " ..
               "it -- `sps_testkit status` first if you want to look before you leap")
  return true
end

return F
