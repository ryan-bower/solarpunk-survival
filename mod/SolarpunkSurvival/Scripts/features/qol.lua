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
local function callOutBool(obj, fnName)
  local out = {}
  local ok = ctx.uehelp.call(obj, fnName, out)
  if not ok then return nil end
  local v = rawget(out, 1)
  if v == nil then
    for _, x in pairs(out) do v = x; break end
  end
  if type(v) == "userdata" then pcall(function() local g = v:get(); v = g end) end
  if type(v) == "boolean" then return v end
  return nil
end

local function localController()
  local pl = ctx.map.player
  return ctx.uehelp.localController(pl and pl.controllerClass) or ctx.uehelp.playerController()
end

-- Cooked-material loader (the wand/evil_animals pattern: find by name, LoadAsset the path on a
-- miss, re-find -- LoadAsset's return value is not trusted).
local matCache = {}
local function matByName(name)
  if not name then return nil end
  if matCache[name] ~= nil then return matCache[name] or nil end
  local function find()
    for _, kind in ipairs({ "Material", "MaterialInstanceConstant" }) do
      local ok, m = pcall(FindObject, kind, name)
      if ok and m and ctx.uehelp.isValid(m) then return m end
    end
    return nil
  end
  local mt = find()
  local dir = ctx.map.wand and ctx.map.wand.materialDir
  if not mt and dir and LoadAsset then
    pcall(LoadAsset, dir .. name .. "." .. name)
    mt = find()
  end
  matCache[name] = mt or false
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

local function sizeChest(chest)
  local want = tonumber(ctx.config.get("qol_chest_size")) or 0
  if want <= 0 or not ctx.net.isHost() then return end
  if not ctx.uehelp.isValid(chest) then return end
  local ok2, comp = ctx.uehelp.get(chest, ctx.map.wand and ctx.map.wand.inventorySystemProp or "InventorySystem")
  if not (ok2 and ctx.uehelp.isValid(comp)) then return end
  local fn; pcall(function() fn = comp:GetFullName() end)
  if not fn or chestSized[fn] then return end
  local len = -1
  pcall(function() len = #comp.Inventory end)
  if len <= 0 or len >= want then
    if len >= want then chestSized[fn] = true end
    return
  end
  local out = {}
  pcall(function() comp:GetNrOfFreeSlots(out) end)
  local free; for _, v in pairs(out) do free = v; break end
  if free ~= len then return end   -- occupied: try again once it's been emptied
  local arr = {}
  for i = 1, want do arr[i] = {} end
  local okR = ctx.uehelp.call(comp, "ForceReplace Inventory", arr, true)
  if okR then
    ctx.uehelp.set(comp, qmap().invSizeProp or "InventorySize", want)
    chestSized[fn] = true
    ctx.log.info("qol: chest grown " .. len .. " -> " .. want .. " slots")
  end
end

local function sweepChests()
  for _, c in ipairs(ctx.uehelp.findAll(qmap().chestClass)) do sizeChest(c) end
end

--------------------------------------------------------------------- backpack: a bigger pack
local function applyBackpack()
  local lvl = tonumber(ctx.config.get("qol_backpack_level")) or -1
  if lvl < 0 then return end
  local pawn = ctx.uehelp.localPawn()
  if not pawn then return end
  local ok = ctx.uehelp.call(pawn, qmap().invUpgradeFn, lvl)
  if ok then ctx.log.info("qol: backpack upgrade level " .. lvl .. " applied") end
end

--------------------------------------------------------------------- crouch on Ctrl / C
local crouchReady = {}   -- pawn fullname -> bCanCrouch was enabled

local function enableCrouch(pawn)
  local fn; pcall(function() fn = pawn:GetFullName() end)
  if not fn or crouchReady[fn] then return crouchReady[fn] end
  local okW = pcall(function()
    local mv = pawn[ctx.map.animal and ctx.map.animal.moveCompProp or "CharacterMovement"]
    mv.NavAgentProps.bCanCrouch = true
  end)
  crouchReady[fn] = okW == true
  if not okW then ctx.log.warn("qol: could not enable crouching on the movement component") end
  return crouchReady[fn]
end

local function toggleCrouch()
  if not ctx.config.get("qol_crouch") then return end
  local pawn = ctx.uehelp.localPawn()
  if not pawn then return end
  if not enableCrouch(pawn) then return end
  local ok, isC = ctx.uehelp.get(pawn, "bIsCrouched")
  if ok and isC == true then
    ctx.uehelp.call(pawn, "UnCrouch", false)
  else
    ctx.uehelp.call(pawn, "Crouch", false)
  end
end

--------------------------------------------------------------------- the airship
-- Its chest: the ship carries a real BC_InventorySystem of its own; the controller's
-- UI_OpenChestInventory(ChestInventorySystem) is the game's every-chest UI entry.
local shipChestHinted = false
local function openShipChest()
  local ship
  for _, s in ipairs(ctx.uehelp.findAll(qmap().airshipClass)) do
    if ctx.uehelp.isValid(s) then
      local full = ""; pcall(function() full = s:GetFullName() end)
      -- FindAllOf hands back the class default object too; only a placed ship counts
      if not full:find("Default__", 1, true) then ship = s; break end
    end
  end
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
  local inv
  local ok = pcall(function() inv = ship[ctx.map.wand and ctx.map.wand.inventorySystemProp or "InventorySystem"] end)
  if not (ok and ctx.uehelp.isValid(inv)) then
    -- the ship's storage is a REAL game feature gated behind the airship chest upgrade (the
    -- inventory component only exists once it is built at the dock's upgrade station)
    if not shipChestHinted then
      shipChestHinted = true
      ctx.log.info("qol: this airship has no chest yet -- build the chest upgrade at the dock, then [" ..
        tostring(ctx.config.get("qol_ship_chest_key")) .. "] opens it")
    end
    return
  end
  ctx.uehelp.call(ship, qmap().shipChestOpenFn)          -- the lid animation (cosmetic)
  ctx.uehelp.call(pc, qmap().openChestUiFn, inv)
  ctx.log.debug("qol: ship chest opened")
end

-- Your own inventory while at the wheel: the game's inventory key is dead while controlling
-- the ship, so this key asks the controller directly -- but ONLY while flying (on foot the
-- game's own binding already handles it; firing both would double-toggle).
local function openInvOnShip()
  local pc = localController()
  if not pc then return end
  if callOutBool(pc, qmap().controllingShipFn) ~= true then return end
  ctx.uehelp.call(pc, qmap().toggleInvFn)
end

-- Faster recall: the dock's return flight is a timeline paced by its TimelineSpeed double
-- (800.0 stock). Scaled once per dock; a world reload resets the stock value, which the
-- target-mismatch check detects and re-scales.
local dockTarget = {}   -- dock fullname -> the value we set

local function speedDock(dock)
  local mult = tonumber(ctx.config.get("qol_recall_mult")) or 1.0
  if mult <= 1.0 or not ctx.uehelp.isValid(dock) then return end
  local fn; pcall(function() fn = dock:GetFullName() end)
  if not fn then return end
  local prop = qmap().dockSpeedProp or "TimelineSpeed"
  local ok, v = ctx.uehelp.get(dock, prop)
  if not (ok and type(v) == "number" and v > 0) then return end
  local t = dockTarget[fn]
  if t and math.abs(v - t) < 0.5 then return end   -- still at our value: done
  local nv = v * mult
  if ctx.uehelp.set(dock, prop, nv) then
    dockTarget[fn] = nv
    ctx.log.info(string.format("qol: airship recall %.0f -> %.0f (x%.1f)", v, nv, mult))
  end
end

local function sweepDocks()
  for _, d in ipairs(ctx.uehelp.findAll(qmap().dockClass)) do speedDock(d) end
end

--------------------------------------------------------------------- overlay: hotbar + drops
-- The live W_PlayerOverlay (FindAllOf hands back the archetype too; the archetype's path
-- contains ":WidgetTree").
local function liveOverlay()
  for _, w in ipairs(ctx.uehelp.findAll(qmap().overlayClass)) do
    if ctx.uehelp.isValid(w) then
      local full; pcall(function() full = w:GetFullName() end)
      if full and not full:find(":WidgetTree", 1, true) then return w end
    end
  end
  return nil
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
  end
  pcall(function() hb:SetRenderTranslation({ X = x, Y = y }) end)
end

--------------------------------------------------------------------- pings: tall + per-player
local lastPinger = nil        -- plain Lua string, stashed by the MULTI_Ping pre-hook
local lastPingerAt = -1e9

local function dressPing(p)
  if not ctx.uehelp.isValid(p) then return end
  local xy = tonumber(ctx.config.get("qol_ping_scale_xy")) or 1.0
  local z  = tonumber(ctx.config.get("qol_ping_scale_z")) or 1.0
  if xy ~= 1.0 or z ~= 1.0 then
    pcall(function() p:SetActorScale3D({ X = xy, Y = xy, Z = z }) end)
  end
  if not ctx.config.get("qol_ping_colors") then return end
  local who = (os.clock() - lastPingerAt) < 3.0 and lastPinger or nil
  if not who then return end
  local pal = paletteFor(who)
  local mt = pal and matByName(pal.mat)
  if not mt then return end
  -- the ping's static mesh comp (SetMaterial on STATIC mesh comps is the proven-safe family)
  local smc
  for _, prop in ipairs(qmap().pingMeshProps or {}) do
    local ok, c = ctx.uehelp.get(p, prop)
    if ok and ctx.uehelp.isValid(c) then smc = c; break end
  end
  if not smc then
    pcall(function()
      local cls = StaticFindObject and StaticFindObject("/Script/Engine.StaticMeshComponent")
      if cls then smc = p:GetComponentByClass(cls) end
    end)
  end
  if not ctx.uehelp.isValid(smc) then return end
  for slotIdx = 0, 1 do
    pcall(function() smc:SetMaterial(slotIdx, mt) end)
  end
  ctx.log.debug("qol: ping dressed for " .. tostring(who))
end

--------------------------------------------------------------------- map: names + colors
local function playerNameOf(pc)
  local nm
  pcall(function() nm = pc:GetPlayerName() end)
  if type(nm) == "userdata" then pcall(function() nm = tostring(nm:ToString()) end) end
  if type(nm) == "string" and #nm > 0 then return nm end
  local ok, id = ctx.uehelp.get(pc, ctx.map.pawn and ctx.map.pawn.playerIdProp or "UniquePlayerID")
  if ok and id ~= nil then return tostring(id) end
  return nil
end

local function tintIcon(icon, name)
  if not ctx.uehelp.isValid(icon) then return end
  local pal = name and paletteFor(name)
  if pal then
    pcall(function()
      icon[qmap().mapIconImgProp]:SetColorAndOpacity({ R = pal.r, G = pal.g, B = pal.b, A = 1.0 })
    end)
  end
  if name and FText then
    pcall(function() icon:SetToolTipText(FText(tostring(name))) end)
  end
end

-- Runs (deferred) each time the map opens: FriendsMarkers is WC_Map's own name->icon TMap, so
-- every teammate's icon gets that player's palette color + a hover tooltip with their name; the
-- local player's icon (WC_MainPlayer) gets their own.
local function dressMap()
  if not ctx.config.get("qol_map_names") then return end
  for _, wc in ipairs(ctx.uehelp.findAll(qmap().mapCompClass)) do
    if ctx.uehelp.isValid(wc) then
      local full; pcall(function() full = wc:GetFullName() end)
      if full and not full:find(":WidgetTree", 1, true) then
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
  end
end

--------------------------------------------------------------------- arming
local hooked = {}   -- fn-name -> true once its RegisterHook stuck

local function armHook(pathOwner, fnName, tag, body)
  if not fnName or hooked[fnName] then return end
  local inst = ctx.uehelp.findFirst(pathOwner)
  if not inst then return end
  local path = fullFuncPath(inst, fnName)
  if not path then return end
  local ok = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if ok then
    hooked[fnName] = true
    ctx.log.debug("qol: hooked " .. path)
  end
end

local function armHooks()
  local pl = ctx.map.player or {}
  -- Our own ship-inventory key calls ToggleInventory, so its hook body must touch no UObjects:
  -- it only schedules the sync. Same shape for the UI-close funnel.
  armHook(pl.controllerClass, qmap().toggleInvFn, "qol.inv", function()
    defer(120, syncHotbar)
  end)
  armHook(pl.controllerClass, ctx.map.codex and ctx.map.codex.inputGameFn, "qol.uiclose", function()
    defer(120, syncHotbar)
  end)
  -- MULTI_Ping fires once per accepted ping ON EVERY MACHINE with the pinging controller as
  -- context: two guarded reads stash the pinger's name for the construction notify to use.
  armHook(pl.controllerClass, pl.pingFn, "qol.ping", function(Context)
    local pc
    pcall(function() pc = Context:get() end)
    if pc then
      local nm = playerNameOf(pc)
      if nm then lastPinger, lastPingerAt = nm, os.clock() end
    end
  end)
  armHook(qmap().mapCompClass, qmap().mapOpenFn, "qol.map", function()
    defer(150, dressMap)
  end)
end

-- Everything (re)applied when the LOCAL pawn changes -- world entry, respawn, hot reload.
local function applyAll()
  armHooks()
  applyBackpack()
  sweepDocks()
  sweepChests()
  applyDrops()
  syncHotbar()
  local pawn = ctx.uehelp.localPawn()
  if pawn then enableCrouch(pawn) end
  -- the map widget (WC_Map) is created a beat after the pawn, so its OpenMap hook misses the
  -- first pass (seen live 2026-07-26); a couple of spaced retries catch every late class
  defer(10000, armHooks)
  defer(30000, armHooks)
end

local seenPawn = nil
local function onCharacter()
  -- animals are Characters too: this notify fires for every spawn, so gate on the local pawn
  -- actually being a new instance before doing the heavy sweeps
  local pawn = ctx.uehelp.localPawn()
  local fn; if pawn then pcall(function() fn = pawn:GetFullName() end) end
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
  local function bind(keyName, tag, fn)
    pcall(function()
      if RegisterKeyBind and Key and keyName and Key[keyName] then
        RegisterKeyBind(Key[keyName], ctx.log.guard(tag, function() onGameThread(fn) end))
      end
    end)
  end
  if ctx.config.get("qol_crouch") then
    bind(ctx.config.get("qol_crouch_key"),  "qol.crouch",  toggleCrouch)
    bind(ctx.config.get("qol_crouch_key2"), "qol.crouch2", toggleCrouch)
  end
  bind(ctx.config.get("qol_ship_chest_key"), "qol.shipchest", openShipChest)
  bind(ctx.config.get("qol_ship_inv_key"),   "qol.shipinv",   openInvOnShip)

  -- construction notifies (all multiplexed on the one Engine.Actor channel; work deferred)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().chestClass, function(obj)
    defer(150, function() sizeChest(obj) end)
    defer(1200, function() sizeChest(obj) end)   -- second pass: save-load init ordering
  end)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().dockClass, function(obj)
    defer(500, function() speedDock(obj) end)
  end)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", qmap().pingClass, function(obj)
    defer(150, function() dressPing(obj) end)
  end)
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    defer(2000, onCharacter)
  end)

  -- live tuning: any qol_* change re-applies the cheap visual state
  ctx.bus.on("config.changed", function(ev)
    if ev and type(ev.key) == "string" and ev.key:sub(1, 4) == "qol_" then
      dockTarget = {}
      chestSized = {}
      onGameThread(function() applyDrops(); syncHotbar(); sweepDocks(); sweepChests() end)
    end
  end)

  -- hot reload mid-session: a pawn may already exist
  defer(1500, onCharacter)
  ctx.log.info("qol: chests x2, backpack, crouch (" .. tostring(ctx.config.get("qol_crouch_key")) ..
    "/" .. tostring(ctx.config.get("qol_crouch_key2")) .. "), ship chest (" ..
    tostring(ctx.config.get("qol_ship_chest_key")) .. "), ship inventory (" ..
    tostring(ctx.config.get("qol_ship_inv_key")) .. "), recall x" ..
    tostring(ctx.config.get("qol_recall_mult")) .. ", UI + pings + map names armed")
  return true
end

return F
