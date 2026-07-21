-- The Mundane Wand -> Charged Electric Wand.
--
-- The wand ITEM is the Diamond Hoe (a new cooked item cannot be authored from Lua). While it is
-- held, the mod redresses it: the hoe's held visual is hidden and an oversized cobalt (3x the
-- dropped model) is stood at the hand slot -- handle + cobalt tip, the Mundane Wand. The ritual
-- charges it: the cobalt takes the diamond's material and crackles with electricity (Charged
-- Electric Wand). Left click (the hoe's IA_Till input) while charged casts a real bolt at the
-- aimed point in ANY weather, spending the charge. Standing within wand_recharge_radius (5 m) of
-- any OTHER lightning strike while holding the spent wand recharges it.
--
-- States per player: "mundane" (never ritual-forged; tills like a normal hoe), "charged",
-- "uncharged" (spent; recharges near strikes). MP: state + casting are host-side; a client's
-- left-click cast is a known gap until a client->host carrier exists (logged in docs).
local F = {}
local ctx

local states  = {}   -- playerId -> "mundane" | "charged" | "uncharged"
local dressed = {}   -- pawnId -> { cobalt=actor, fx=NiagaraComponent, origMat=mat, hidden=bool }
local castHooked, toolHooked = false, false
local lastCast = -1e9
local diamondMat     -- the diamond item's material, fetched lazily once

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function pawnController(pawn)
  local pc
  pcall(function() pc = pawn.Controller end)
  if ctx.uehelp.isValid(pc) then return pc end
  return nil
end

-- Best-effort read of the held item's class name (same probing ritual.lua uses; pcall-safe).
local function heldItemClassName(pawn)
  local name
  pcall(function()
    local held = pawn.CurItemdataInHand
    if held == nil then return end
    for _, field in ipairs({ "ItemClass", "Item Class", "Class", "Item" }) do
      local okf, v = pcall(function() return held[field] end)
      if okf and v ~= nil then
        local okn, n = pcall(function() return v:GetFName():ToString() end)
        if okn and n then name = n; return end
      end
    end
  end)
  return name
end

local function isWandHeld(pawn)
  local held = heldItemClassName(pawn)
  -- unreadable held-item = accept only if the player HAS a state already (they proved ownership)
  if held == nil then return states[ctx.identity.idOf(pawnController(pawn) or pawn)] ~= nil end
  return held == "BP_Hoe_Diamond_Item_C"
end

local function playerIdOf(pawn)
  local pc = pawnController(pawn)
  return pc and ctx.identity.idOf(pc) or ctx.identity.idOf(pawn)
end

local function stateOf(pawn)
  return states[playerIdOf(pawn)] or "mundane"
end

--------------------------------------------------------------------- cosmetics
local function meshCompOf(actor)
  for _, cand in ipairs(ctx.map.wand.meshCompCandidates or {}) do
    local ok, c = pcall(function() return actor[cand] end)
    if ok and c ~= nil then return c end
  end
  local ok, root = pcall(function() return actor.RootComponent end)
  if ok then return root end
  return nil
end

local function fetchDiamondMat(pc, near)
  if diamondMat ~= nil then return diamondMat end
  local cls = ctx.items.classFor(ctx.map.wand.diamondRow)
  if not cls then return nil end
  local probe = ctx.uehelp.spawnActorAt(pc, cls, { X = near.X, Y = near.Y, Z = near.Z - 2000 })
  if not probe then return nil end
  pcall(function()
    local mc = meshCompOf(probe)
    if mc then diamondMat = mc:GetMaterial(0) end
  end)
  pcall(function() probe:K2_DestroyActor() end)
  return diamondMat
end

local function spawnElectricity(comp)
  local nfl = StaticFindObject and StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
  if not nfl then return nil end
  for _, nm in ipairs(ctx.map.wand.niagaraCandidates or {}) do
    local sys; pcall(function() sys = FindObject("NiagaraSystem", nm) end)
    if sys then
      local fx
      local zero, rot = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }
      -- reflected signature varies across engine versions; try the two common arities
      if not pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false) end) then
        pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false, true, 0, false) end)
      end
      if fx then return fx end
    end
  end
  return nil
end

local function setHeldToolHidden(pawn, hidden)
  for _, p in ipairs(ctx.map.wand.heldItemProps or {}) do
    pcall(function()
      local c = pawn[p]
      if c then c:SetVisibility(not hidden, true) end
    end)
  end
end

local function undress(pawn)
  local id = ctx.identity.idOf(pawn)
  local d = id and dressed[id]
  if not d then
    if ctx.uehelp.isValid(pawn) then setHeldToolHidden(pawn, false) end
    return
  end
  pcall(function() if d.fx then d.fx:Deactivate(); d.fx:DestroyComponent(d.fx) end end)
  pcall(function() if ctx.uehelp.isValid(d.cobalt) then d.cobalt:K2_DestroyActor() end end)
  if ctx.uehelp.isValid(pawn) then setHeldToolHidden(pawn, false) end
  dressed[id] = nil
end

-- Dress the held wand: hide the hoe visual, stand the 3x cobalt at the hand slot; when charged,
-- give the cobalt the diamond's material + electricity. All best-effort and pcall-guarded --
-- failures degrade to "plain hoe" cosmetics, never errors.
local function dress(pawn)
  if not ctx.uehelp.isValid(pawn) then return end
  local id = ctx.identity.idOf(pawn)
  if not id then return end
  if not isWandHeld(pawn) then undress(pawn); return end

  local pc = pawnController(pawn)
  local state = stateOf(pawn)
  setHeldToolHidden(pawn, true)

  local d = dressed[id]
  if not (d and ctx.uehelp.isValid(d.cobalt)) then
    local cls = ctx.items.classFor(ctx.map.wand.cobaltRow)
    local pl = ctx.identity.locationOf(pawn)
    if not (cls and pl and pc) then return end
    local cobalt = ctx.uehelp.spawnActorAt(pc, cls, { X = pl.X, Y = pl.Y, Z = pl.Z + 90 })
    if not cobalt then return end
    pcall(function() cobalt:SetActorEnableCollision(false) end)
    pcall(function()
      local mc = meshCompOf(cobalt)
      if mc then mc:SetSimulatePhysics(false) end
    end)
    local slot
    for _, p in ipairs(ctx.map.wand.handSlotProps or {}) do
      local ok, c = pcall(function() return pawn[p] end)
      if ok and c ~= nil then slot = c; break end
    end
    pcall(function()
      if slot then
        cobalt:K2_AttachToComponent(slot, "None", 0, 0, 0, false)  -- keep-relative snap
        cobalt:K2_SetActorRelativeLocation({ X = 0, Y = 0, Z = ctx.config.get("wand_tip_up") }, false, {}, false)
      else
        cobalt:K2_AttachToActor(pawn, "None", 1, 1, 1, false)
      end
    end)
    local s = ctx.config.get("wand_cobalt_scale")
    pcall(function() cobalt:SetActorScale3D({ X = s, Y = s, Z = s }) end)
    local orig; pcall(function() local mc = meshCompOf(cobalt); if mc then orig = mc:GetMaterial(0) end end)
    d = { cobalt = cobalt, origMat = orig }
    dressed[id] = d
  end

  if state == "charged" then
    pcall(function()
      local mat = pc and fetchDiamondMat(pc, ctx.identity.locationOf(pawn) or { X = 0, Y = 0, Z = 0 })
      local mc = meshCompOf(d.cobalt)
      if mat and mc then mc:SetMaterial(0, mat) end
    end)
    if not d.fx then
      local mc = meshCompOf(d.cobalt)
      d.fx = mc and spawnElectricity(mc) or nil
    end
  else
    pcall(function()
      local mc = meshCompOf(d.cobalt)
      if d.origMat and mc then mc:SetMaterial(0, d.origMat) end
    end)
    pcall(function() if d.fx then d.fx:Deactivate(); d.fx:DestroyComponent(d.fx); d.fx = nil end end)
  end
end

local function redress(pawn, delay)
  pcall(ExecuteWithDelay, math.floor((delay or 0.2) * 1000), ctx.log.guard("wand.dress", function()
    onGameThread(function() dress(pawn) end)
  end))
end

--------------------------------------------------------------------- state transitions
local function setState(pawn, state, quiet)
  local id = playerIdOf(pawn)
  if not id then return end
  states[id] = state
  if not quiet then
    if state == "charged" then
      ctx.log.info("*** CHARGED ELECTRIC WAND *** the cobalt burns diamond-bright. Left click to cast.")
    elseif state == "uncharged" then
      ctx.log.info("the wand is spent -- stand within 5 m of a lightning strike to recharge it")
    end
  end
  redress(pawn, 0.1)
end

-- Ritual payout: every wand-holder in the circle gets a charged wand (replaces the old
-- Weather-Station item grant -- the wand itself is now the prize).
function F.chargeWands(center, radius)
  if not ctx.net.isHost() then return 0 end
  local r2 = (radius or ctx.config.get("ritual_radius")) ^ 2
  local blessed = 0
  for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl and ctx.uehelp.dist2(pl, center) <= r2 then
      local held = heldItemClassName(pawn)
      if held == nil or held == "BP_Hoe_Diamond_Item_C" then
        setState(pawn, "charged")
        blessed = blessed + 1
      end
    end
  end
  if blessed > 0 then
    ctx.log.info("*** the wand drinks the bolt -- " .. blessed .. " CHARGED ELECTRIC WAND(s) forged ***")
  else
    ctx.log.info("ritual: the bolt found no wand-bearer inside the circle")
  end
  return blessed
end

--------------------------------------------------------------------- casting
local function aimPoint(pc, pawn)
  local u = ctx.uehelp
  local cam; pcall(function() cam = pc.PlayerCameraManager end)
  if not cam then return nil end
  local cl = u.vec(cam:GetCameraLocation())
  local rot; pcall(function() rot = cam:GetCameraRotation() end)
  local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
  local fwd = (rot and kml) and u.vec(kml:GetForwardVector(rot)) or nil
  if not (cl and fwd) then return nil end
  local range = ctx.config.get("wand_cast_range")
  local endp = { X = cl.X + fwd.X * range, Y = cl.Y + fwd.Y * range, Z = cl.Z + fwd.Z * range }
  local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
  local hitLoc
  pcall(function()
    local hit = {}
    local red, green = { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }
    if ksl:LineTraceSingle(pc, cl, endp, 0, false, { pawn }, 0, hit, true, red, green, 0.0) then
      for _, f in ipairs({ "ImpactPoint", "Location" }) do
        local okf, v = pcall(function() return hit[f] end)
        if okf then
          local hv = ctx.uehelp.vec(v)
          if hv then hitLoc = hv; return end
        end
      end
    end
  end)
  return hitLoc or endp
end

local function tryCast(pawn)
  if os.clock() - lastCast < ctx.config.get("wand_cast_debounce") then return end
  if not ctx.uehelp.isValid(pawn) then return end
  if not isWandHeld(pawn) then return end
  if stateOf(pawn) ~= "charged" then return end  -- mundane/spent: the hoe just tills
  lastCast = os.clock()
  local pc = pawnController(pawn)
  if not pc then return end
  if not ctx.net.isHost() then
    ctx.log.info("wand: casting is host-only until a client->host carrier exists")
    return
  end
  local loc = aimPoint(pc, pawn)
  if not loc then return end
  local id = playerIdOf(pawn)
  if ctx.services.castBolt and ctx.services.castBolt(loc, id) then
    ctx.log.info(string.format("*** the wand SPEAKS -- bolt cast at (%.0f,%.0f) ***", loc.X, loc.Y))
    setState(pawn, "uncharged")
  end
end

-- Hook every IA_Till input event on the pawn class (the hoe's left-click, all trigger phases).
local function hookCast()
  if castHooked then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local prefix = ctx.map.wand.tillEventPrefix
  local paths = {}
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n:sub(1, #prefix) == prefix then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  local hooked = 0
  for _, path in ipairs(paths) do
    local ok = pcall(RegisterHook, path, ctx.log.guard("wand.cast", function(Context)
      local p; pcall(function() p = Context:get() end)
      onGameThread(function() tryCast(p) end)
    end))
    if ok then hooked = hooked + 1 end
  end
  if hooked > 0 then
    castHooked = true
    ctx.log.info("wand: cast trigger armed (" .. hooked .. " IA_Till hooks)")
  end
end

-- Re-dress whenever the player swaps tools (hide/unhide the hoe visual correctly).
local function hookToolChange()
  if toolHooked then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local fn = ctx.map.wand.toolChangeFn
  local full
  pcall(function()
    pawn:GetClass():ForEachFunction(function(f)
      local n = ""; pcall(function() n = f:GetFName():ToString() end)
      if n == fn then pcall(function() full = f:GetFullName() end) end
    end)
  end)
  if not full then return end
  local ok = pcall(RegisterHook, (full:gsub("^%S+%s+", "")), ctx.log.guard("wand.toolchange", function(Context)
    local p; pcall(function() p = Context:get() end)
    if p then redress(p, 0.25) end
  end))
  toolHooked = ok or false
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "wand",
      { "wand.tillEventPrefix", "pawn.class", "ritual.wandItemRow", "items.classFmt" }) then
    return false
  end

  ctx.services.chargeWands = function(center, radius) return F.chargeWands(center, radius) end

  -- Recharge: any strike within wand_recharge_radius of a spent-wand holder recharges it --
  -- except the caster's own bolt (no self-recharge loop).
  ctx.bus.on("lightning.strike", ctx.log.guard("wand.recharge", function(e)
    if not (ctx.net.isHost() and e and e.location) then return end
    local r2 = ctx.config.get("wand_recharge_radius") ^ 2
    for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
      local id = playerIdOf(pawn)
      if id and states[id] == "uncharged" and id ~= e.castBy then
        local pl = ctx.identity.locationOf(pawn)
        if pl and ctx.uehelp.dist2(pl, e.location) <= r2 and isWandHeld(pawn) then
          setState(pawn, "charged")
          ctx.log.info("*** the wand drinks the storm -- RECHARGED ***")
        end
      end
    end
  end))

  -- Arm hooks as soon as a pawn exists (now, on pawn spawn, and on storms as a retry).
  hookCast(); hookToolChange()
  ctx.uehelp.onNewInstance("/Script/Engine.Character", ctx.map.pawn.class,
    ctx.log.guard("wand.newpawn", function(p)
      hookCast(); hookToolChange(); redress(p, 1.0)
    end))
  ctx.bus.on("weather.changed", ctx.log.guard("wand.rearm", function() hookCast(); hookToolChange() end))

  pcall(function()
    RegisterConsoleCommandHandler("sps_wand", function()
      onGameThread(function()
        local pawn = ctx.uehelp.localPawn and ctx.uehelp.localPawn()
        if not pawn then
          local pc = ctx.uehelp.findFirst(ctx.map.player.controllerClass)
          pcall(function() pawn = pc:K2_GetPawn() end)
        end
        if pawn then
          local id = playerIdOf(pawn)
          ctx.log.info("wand state: " .. tostring(states[id] or "mundane"))
        end
      end)
      return true
    end)
  end)

  ctx.log.info("wand: the Mundane Wand awaits its ritual (hold the Diamond Hoe)")
  return true
end

return F
