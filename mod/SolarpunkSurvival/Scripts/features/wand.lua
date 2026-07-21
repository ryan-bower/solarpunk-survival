-- The wand: a REAL standalone tool, not a redressed inventory item.
--
-- Lua cannot mint a new inventory item ID (that needs a cooked content pak -- see
-- docs/MILESTONE-2.md), so the wand lives OUTSIDE the inventory entirely:
--
--   model    = StaticMeshComponents created ON the pawn via AddComponentByClass -- the ONLY
--              crash-free rig recipe (proven live 2026-07-21, probe P6). The Stick mesh is the
--              handle, the dropped-Cobalt mesh (3x) the tip; meshes are found BY NAME from the
--              loaded StaticMesh assets. Attaching ANY actor to the pawn (K2_AttachToActor or
--              K2_AttachToComponent) is a fatal engine error, as is reading properties off CDO
--              component templates -- neither appears here. See the gotchas memory.
--   obtain   = the dark-arts ritual forges it (`sps_wand forge` grants a test Mundane Wand).
--   carry    = press the draw key (V) or `sps_wand draw` to draw/stow it.
--   states   = Mundane Wand -> Lightning Wand (charged) -> Lightning Wand (uncharged).
--              charged: the cobalt wears the Diamond ore mesh's material + (optional) crackle.
--              uncharged: keeps the diamond color, loses only the crackle.
--   cast     = left click (PressedHandInteraction / IA_HandInteract -- fires with EMPTY hands)
--              while drawn + charged: a real bolt at the aimed point, ANY weather.
--   recharge = stand within wand_recharge_radius (5 m) of a strike that isn't your own cast
--              while the wand is drawn.
--
-- MP: wand state lives on the host (fully functional for the host player; remote players'
-- states are tracked host-side, but their draw key/visuals run on their own machine -- a
-- client->host carrier is future work, docs/MILESTONE-2.md). The rig is cosmetic only.
local F = {}
local ctx

local wands = {}    -- playerId -> "mundane" | "charged" | "uncharged"  (nil = owns no wand)
local drawn = {}    -- playerId -> true while the wand is out
local rigs  = {}    -- pawnId  -> { handle=comp, tip=comp, fx=NiagaraComponent }
local castHooked = false
local lastCast = -1e9
local meshCache     -- assetName -> UStaticMesh, filled once from the loaded-asset scan
local diamondMat    -- the diamond mesh asset's material, read once

local STATE_NAMES = { mundane = "Mundane Wand", charged = "Lightning Wand (charged)",
                      uncharged = "Lightning Wand (uncharged)" }

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

local function playerIdOf(pawn)
  local pc = pawnController(pawn)
  return pc and ctx.identity.idOf(pc) or ctx.identity.idOf(pawn)
end

local function localPlayerPawn()
  local pc = ctx.uehelp.findFirst(ctx.map.player.controllerClass)
  local pawn
  pcall(function() pawn = pc and pc:K2_GetPawn() end)
  if ctx.uehelp.isValid(pawn) then return pawn end
  return ctx.uehelp.findFirst(ctx.map.pawn.class)
end

--------------------------------------------------------------------- mesh + material donors
-- One-shot scan of loaded StaticMesh assets by NAME. Names-only iteration -- never read
-- properties off CDOs/templates (fatal, proven P1), never spawn item BPs for their looks.
local function meshByName(assetName)
  if not assetName then return nil end
  if meshCache then return meshCache[assetName] end
  meshCache = {}
  local want = {}
  for _, k in ipairs({ ctx.map.wand.stickMesh, ctx.map.wand.cobaltMesh, ctx.map.wand.diamondMesh }) do
    if k then want[k] = true end
  end
  local all = {}
  pcall(function() all = FindAllOf("StaticMesh") or {} end)
  for _, m in ipairs(all) do
    local nm; pcall(function() nm = m:GetFName():ToString() end)
    if nm and want[nm] then meshCache[nm] = m end
  end
  for k in pairs(want) do
    if not meshCache[k] then ctx.log.warn("wand: mesh asset '" .. k .. "' not loaded -- visual degrades") end
  end
  return meshCache[assetName]
end

local function diamondMaterial()
  if diamondMat ~= nil then return diamondMat or nil end
  local mat
  local m = meshByName(ctx.map.wand.diamondMesh)
  if m then pcall(function() mat = m:GetMaterial(0) end) end
  diamondMat = mat or false
  return mat
end

--------------------------------------------------------------------- the visual rig
local function tearRig(pawnId)
  local r = pawnId and rigs[pawnId]
  if not r then return end
  pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx) end end)
  for _, k in ipairs({ "tip", "handle" }) do
    pcall(function() if r[k] then r[k]:DestroyComponent(r[k]) end end)
  end
  rigs[pawnId] = nil
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
      -- (a wrong arity is a SAFE Lua error -- UE4SS validates the param count)
      if not pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false) end) then
        pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false, true, 0, false) end)
      end
      if fx then return fx end
    end
  end
  return nil
end

-- Create one StaticMeshComponent ON the pawn (born attached to its root -- no attach call).
local function addMeshComp(pawn, mesh, rel, scale)
  if not mesh then return nil end
  local smcCls
  pcall(function() smcCls = StaticFindObject(ctx.map.wand.smcPath) end)
  if not smcCls then return nil end
  local xf = {
    Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = rel,
    Scale3D     = { X = scale, Y = scale, Z = scale },
  }
  local comp
  pcall(function() comp = pawn:AddComponentByClass(smcCls, false, xf, false) end)
  if not comp then return nil end
  pcall(function() comp:SetStaticMesh(mesh) end)
  return comp
end

-- Build/refresh the in-hand wand model for a pawn according to its owner's state.
local function refreshRig(pawn)
  if not ctx.config.get("wand_rig") then return end
  if not ctx.uehelp.isValid(pawn) then return end
  local pawnId = ctx.identity.idOf(pawn)
  local id = playerIdOf(pawn)
  if not (pawnId and id) then return end
  if not (wands[id] and drawn[id]) then tearRig(pawnId); return end

  local r = rigs[pawnId]
  if not (r and r.handle and r.tip) then
    tearRig(pawnId)
    -- offsets are relative to the pawn root (capsule center): X fwd, Y right, Z up
    local fwd, side = ctx.config.get("wand_fwd"), ctx.config.get("wand_side")
    local handle = addMeshComp(pawn, meshByName(ctx.map.wand.stickMesh),
      { X = fwd, Y = side, Z = 0 }, 1.0)
    local tip = addMeshComp(pawn, meshByName(ctx.map.wand.cobaltMesh),
      { X = fwd, Y = side, Z = ctx.config.get("wand_tip_up") }, ctx.config.get("wand_cobalt_scale"))
    if not (handle or tip) then
      ctx.log.warn("wand: no rig components -- the wand is in your hand, just unseen")
      return
    end
    r = { handle = handle, tip = tip }
    rigs[pawnId] = r
  end

  -- forged wands (charged AND uncharged) wear the diamond's color; a fresh rig is plain cobalt,
  -- and no state ever returns to mundane, so there is nothing to paint back
  local state = wands[id]
  if r.tip then
    if state == "charged" or state == "uncharged" then
      local mat = diamondMaterial()
      if mat then pcall(function() r.tip:SetMaterial(0, mat) end) end
    end
    -- only the CHARGED wand crackles (wand_fx: OFF until the Niagara call is live-proven)
    if state == "charged" then
      if not r.fx and ctx.config.get("wand_fx") then r.fx = spawnElectricity(r.tip) end
    else
      pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx); r.fx = nil end end)
    end
  end
end

--------------------------------------------------------------------- state transitions
local function setState(pawn, state, quiet)
  local id = playerIdOf(pawn)
  if not id then return end
  local isNew = wands[id] == nil
  wands[id] = state
  if isNew then drawn[id] = true end   -- a freshly forged wand leaps straight into the hand
  if not quiet then
    if state == "charged" then
      ctx.log.info("*** LIGHTNING WAND (CHARGED) *** the cobalt burns diamond-bright. Left click to cast.")
    elseif state == "uncharged" then
      ctx.log.info("Lightning Wand (uncharged) -- the crackle fades. Stand near a strike (5 m) to recharge.")
    elseif state == "mundane" then
      ctx.log.info("a Mundane Wand -- a stick crowned with cobalt. The ritual will wake it.")
    end
  end
  -- refresh the rig OUTSIDE whatever call chain set the state (the ritual sets it from inside
  -- the bolt-impact chain; never build cosmetics in there)
  pcall(ExecuteWithDelay, 150, ctx.log.guard("wand.rig", function()
    onGameThread(function() refreshRig(pawn) end)
  end))
end

-- Ritual payout: every player inside the circle. No wand yet -> one is FORGED, already charged,
-- straight into their hand; an existing wand (mundane or spent) -> charged.
function F.chargeWands(center, radius)
  if not ctx.net.isHost() then return 0 end
  local r2 = (radius or ctx.config.get("ritual_radius")) ^ 2
  local forged, charged = 0, 0
  for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl and ctx.uehelp.dist2(pl, center) <= r2 then
      local id = playerIdOf(pawn)
      if id then
        if wands[id] == nil then forged = forged + 1 else charged = charged + 1 end
        setState(pawn, "charged", true)
      end
    end
  end
  local total = forged + charged
  if total > 0 then
    ctx.log.info(string.format(
      "*** the bolt is BOUND -- %d Lightning Wand(s) (charged): %d newly forged, %d awakened ***",
      total, forged, charged))
    ctx.log.info("    press V to draw/stow the wand; left click while it's drawn to cast")
  else
    ctx.log.info("ritual: no one stood inside the circle to receive the wand")
  end
  return total
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
          local hv = u.vec(v)
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
  local id = playerIdOf(pawn)
  if not (id and wands[id] == "charged" and drawn[id]) then return end
  lastCast = os.clock()
  local pc = pawnController(pawn)
  if not pc then return end
  if not ctx.net.isHost() then
    ctx.log.info("wand: casting is host-only until a client->host carrier exists")
    return
  end
  local loc = aimPoint(pc, pawn)
  if not loc then return end
  if ctx.services.castBolt and ctx.services.castBolt(loc, id) then
    ctx.log.info(string.format("*** the wand SPEAKS -- bolt cast at (%.0f,%.0f) ***", loc.X, loc.Y))
    setState(pawn, "uncharged")
  end
end

-- Hook the generic left-click on the pawn: PressedHandInteraction + every IA_HandInteract input
-- event (NOT AltHandInteract -- that is right click). These fire with empty hands, so the wand
-- needs no held tool. The debounce eats the multi-phase double-fire.
local function hookCast()
  if castHooked then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local exact, prefix = ctx.map.wand.castFnExact, ctx.map.wand.castFnPrefix
  local paths = {}
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if (exact and n == exact) or (prefix and n:sub(1, #prefix) == prefix) then
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
    ctx.log.info("wand: cast trigger armed (" .. hooked .. " left-click hooks)")
  end
end

--------------------------------------------------------------------- draw / stow
local function toggleDraw()
  local pawn = localPlayerPawn()
  if not pawn then return end
  local id = playerIdOf(pawn)
  if not id then return end
  if not wands[id] then
    ctx.log.info("you own no wand -- the dark-arts ritual forges one (docs/DARK-ARTS.md)")
    return
  end
  drawn[id] = not drawn[id]
  if drawn[id] then
    ctx.log.info("you draw the " .. STATE_NAMES[wands[id]] .. " (best with empty hands)")
  else
    ctx.log.info("you stow the wand")
  end
  refreshRig(pawn)
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "wand",
      { "pawn.class", "player.controllerClass",
        "wand.smcPath", "wand.stickMesh", "wand.cobaltMesh" }) then
    return false
  end

  ctx.services.chargeWands = function(center, radius) return F.chargeWands(center, radius) end

  -- Recharge: any strike within wand_recharge_radius of a drawn, spent wand recharges it --
  -- except the caster's own bolt (no self-recharge loop). Remote players' drawn flag is unknown
  -- host-side (nil), which counts as holding -- the generous reading.
  ctx.bus.on("lightning.strike", ctx.log.guard("wand.recharge", function(e)
    if not (ctx.net.isHost() and e and e.location) then return end
    local r2 = ctx.config.get("wand_recharge_radius") ^ 2
    for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
      local id = playerIdOf(pawn)
      if id and wands[id] == "uncharged" and id ~= e.castBy and drawn[id] ~= false then
        local pl = ctx.identity.locationOf(pawn)
        if pl and ctx.uehelp.dist2(pl, e.location) <= r2 then
          setState(pawn, "charged")
          ctx.log.info("*** the wand drinks the storm -- RECHARGED ***")
        end
      end
    end
  end))

  -- The draw key (config wand_draw_key, default V).
  local kname = ctx.config.get("wand_draw_key")
  pcall(function()
    if RegisterKeyBind and Key and kname and Key[kname] then
      RegisterKeyBind(Key[kname], ctx.log.guard("wand.key", function()
        onGameThread(toggleDraw)
      end))
    end
  end)

  -- Arm the cast hooks as soon as a pawn exists (now, on pawn spawn, and on storms as a retry);
  -- rebuild the rig after respawns (the old rig's components died with the old pawn).
  hookCast()
  ctx.uehelp.onNewInstance("/Script/Engine.Character", ctx.map.pawn.class,
    ctx.log.guard("wand.newpawn", function(p)
      hookCast()
      pcall(ExecuteWithDelay, 1500, ctx.log.guard("wand.respawnrig", function()
        onGameThread(function() refreshRig(p) end)
      end))
    end))
  ctx.bus.on("weather.changed", ctx.log.guard("wand.rearm", function() hookCast() end))

  pcall(function()
    RegisterConsoleCommandHandler("sps_wand", function(_, params)
      local sub = (params and params[1]) or "state"
      onGameThread(function()
        local pawn = localPlayerPawn()
        if not pawn then return end
        local id = playerIdOf(pawn)
        if sub == "forge" then
          if wands[id] then ctx.log.info("you already own a wand")
          else setState(pawn, "mundane") end
        elseif sub == "charge" then
          if wands[id] then setState(pawn, "charged")
          else ctx.log.info("no wand to charge (sps_wand forge first)") end
        elseif sub == "draw" then
          toggleDraw()
        else
          local owned = wands[id] and (STATE_NAMES[wands[id]] .. (drawn[id] and ", drawn" or ", stowed"))
                        or "none owned"
          ctx.log.info("wand: " .. owned .. "  (sps_wand forge|charge|draw)")
        end
      end)
      return true
    end)
  end)

  ctx.log.info("wand: its own tool now -- forged by the rite, drawn with [" ..
    tostring(kname) .. "], stick + cobalt, no hoe about it")
  return true
end

return F
