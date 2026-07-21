-- The wand: a REAL standalone tool, not a redressed inventory item.
--
-- Lua cannot mint a new inventory item ID (that needs a cooked content pak -- see
-- docs/MILESTONE-2.md), so the wand lives OUTSIDE the inventory -- but it is HELD the way the
-- game holds its own tools. Real tools work like this (RE capture, BP_MainPlayerCharacter_C):
-- the selected hotbar item's mesh is placed into two right-hand slot components --
-- Mesh_Slot_1Person_Hand_R (first person) and Mesh_Slot_3rdPerson_Hand_R (third person) -- via
-- SetHandRMeshForBoth; StashHandItem / RestoreHandItem park and re-equip the held item; and
-- HotbarSlotChanged fires when the player switches tools. The drawn wand rides exactly that
-- machinery:
--
--   model    = stick + seated cobalt tip built as OUR pawn-root components (AddComponentByClass,
--              the only crash-free recipe -- probe P6), auto-seated at the world position of the
--              game's right-hand tool slot (read-only) so it sits in the hand with no eye-tuned
--              offsets. The tip sits at the stick's far end computed from mesh bounds, at
--              wand_cobalt_scale (0.75: the dropped-cobalt model is ~4x too big for a tip).
--              The rig does NOT put the mesh into the slot components and does NOT attach to
--              them: component->component K2_AttachToComponent is a NATIVE CRASH on this build
--              (proven 2026-07-21 12:22, step-log bisection), same family as actor attach and
--              CDO template reads (gotchas memory). Risky steps append to dump/wand_steps.txt.
--              Kill-switch wand_in_hand=false reverts to fixed capsule offsets (wand_fwd/side/up).
--   obtain   = the dark-arts ritual forges it (`sps_wand forge` grants a test Mundane Wand).
--   carry    = press the draw key (V) or `sps_wand draw` to draw/stow. Drawing stashes the held
--              item (the game's own StashHandItem); stowing restores it; picking a hotbar tool
--              while the wand is out stows the wand -- exactly like swapping tools.
--   states   = Mundane Wand -> Lightning Wand (charged) -> Lightning Wand (uncharged).
--              charged: the cobalt wears the Diamond ore mesh's material + (optional) crackle.
--              uncharged: keeps the diamond color, loses only the crackle.
--   cast     = left click (PressedHandInteraction / IA_HandInteract) while drawn + charged: a
--              real bolt at the aimed point, ANY weather. The stash means the game still sees
--              EMPTY hands while the wand is drawn, so the generic left click keeps firing --
--              and no real tool's action can double-trigger under a cast.
--   recharge = stand within wand_recharge_radius (5 m) of a strike that isn't your own cast
--              while the wand is drawn.
--
-- MP: wand state lives on the host (fully functional for the host player; remote players'
-- states are tracked host-side, but their draw key/visuals run on their own machine -- a
-- client->host carrier is future work, docs/MILESTONE-2.md). The rig is cosmetic only; stash/
-- restore of the held item runs ONLY on the local player's pawn (never on a remote replica).
local F = {}
local ctx

local wands = {}    -- playerId -> "mundane" | "charged" | "uncharged"  (nil = owns no wand)
local drawn = {}    -- playerId -> true while the wand is out
local rigs  = {}    -- playerId -> { pawn, mode="hand"|"capsule", handle?, tips={}, slots={}, fx?, stashed? }
local castHooked = false
local hotbarHooked = false
local lastCast = -1e9
local lastHandAction = -1e9  -- our own stash/restore fires HotbarSlotChanged; this window ignores it
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

-- Crash bisection: one line per risky rig step, appended to dump/wand_steps.txt. A native crash
-- kills the process before the next line, so the file names the killer (the proven P1-P6 method).
local function mark(s)
  if not ctx.config.get("wand_step_log") then return end
  pcall(function()
    local f = io.open((ctx.modRoot or "") .. "dump/wand_steps.txt", "a")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
  end)
end

local function pawnController(pawn)
  local pc
  pcall(function() pc = pawn.Controller end)
  if ctx.uehelp.isValid(pc) then return pc end
  return nil
end

-- Stable per-player key. The game's own UniquePlayerID is preferred: identity.idOf falls back to
-- a location-derived key for pawns/controllers, which DRIFTS as the player walks -- and a tool
-- must keep working while its owner moves (draw, walk, cast).
local function playerIdOf(pawn)
  local prop = ctx.map.pawn.playerIdProp
  if prop then
    local candidates = {}
    local pc = pawnController(pawn)
    if pc then candidates[#candidates + 1] = pc end
    candidates[#candidates + 1] = pawn
    for _, obj in ipairs(candidates) do
      local ok, v = ctx.uehelp.get(obj, prop)
      if ok and v ~= nil then
        local s
        if type(v) == "userdata" then pcall(function() s = v:ToString() end) else s = tostring(v) end
        if s and s ~= "" then return "uid:" .. s end
      end
    end
  end
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

local function isLocalPawn(pawn)
  local lp = localPlayerPawn()
  return lp ~= nil and playerIdOf(lp) == playerIdOf(pawn)
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

-- Local-space bounding box of a loaded StaticMesh ASSET (reflected UFunction calls on the asset,
-- same proven-safe family as GetMaterial). Returns min, max tables or nil.
local function meshBounds(mesh)
  if not mesh then return nil end
  local u = ctx.uehelp
  local mn, mx
  pcall(function()
    local box = mesh:GetBoundingBox()
    if box then mn, mx = u.vec(box.Min), u.vec(box.Max) end
  end)
  if not (mn and mx) then
    pcall(function()
      local b = mesh:GetBounds()
      local o, e = u.vec(b.Origin), u.vec(b.BoxExtent)
      if o and e then
        mn = { X = o.X - e.X, Y = o.Y - e.Y, Z = o.Z - e.Z }
        mx = { X = o.X + e.X, Y = o.Y + e.Y, Z = o.Z + e.Z }
      end
    end)
  end
  if mn and mx then return mn, mx end
  return nil
end

-- Where the cobalt sits, in the stick's local space: the far end of the stick's LONGEST axis
-- (that is the tip), centered on the other two axes, with the cobalt's own pivot corrected so
-- the crystal's CENTER seats on the stick end. wand_tip_up stays as a fine trim; wand_tip_flip
-- picks the stick's other end. Returns rel, scale (rel nil if bounds are unreadable).
local function tipTransform()
  local scale = ctx.config.get("wand_cobalt_scale")
  local smin, smax = meshBounds(meshByName(ctx.map.wand.stickMesh))
  if not smin then return nil, scale end
  local axis = "X"
  if (smax.Y - smin.Y) > (smax[axis] - smin[axis]) then axis = "Y" end
  if (smax.Z - smin.Z) > (smax[axis] - smin[axis]) then axis = "Z" end
  local rel = { X = (smin.X + smax.X) / 2, Y = (smin.Y + smax.Y) / 2, Z = (smin.Z + smax.Z) / 2 }
  rel[axis] = ctx.config.get("wand_tip_flip") and smin[axis] or smax[axis]
  local cmin, cmax = meshBounds(meshByName(ctx.map.wand.cobaltMesh))
  if cmin then
    rel.X = rel.X - (cmin.X + cmax.X) / 2 * scale
    rel.Y = rel.Y - (cmin.Y + cmax.Y) / 2 * scale
    rel.Z = rel.Z - (cmin.Z + cmax.Z) / 2 * scale
  end
  rel.Z = rel.Z + ctx.config.get("wand_tip_up")
  return rel, scale
end

--------------------------------------------------------------------- the visual rig
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

-- opts.handsBack=false skips the stashed-item re-equip (used when the game itself just took
-- the hand back, e.g. the player picked a hotbar tool while the wand was out).
local function tearRig(id, opts)
  local r = id and rigs[id]
  if not r then return end
  local handsBack = not (opts and opts.handsBack == false)
  pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx) end end)
  for _, tip in ipairs(r.tips or {}) do
    pcall(function() tip:DestroyComponent(tip) end)
  end
  pcall(function() if r.handle then r.handle:DestroyComponent(r.handle) end end)
  if r.stashed and handsBack and ctx.map.wand.restoreFn and ctx.uehelp.isValid(r.pawn) then
    lastHandAction = os.clock()
    mark("restore held item")
    ctx.uehelp.call(r.pawn, ctx.map.wand.restoreFn)
  end
  rigs[id] = nil
end

-- Where the wand sits, relative to the pawn root: the world position of the game's own
-- right-hand tool slot when readable (the wand seats itself at the hand -- nothing to eye-tune),
-- else the configured capsule offsets. READ-ONLY on the slot: nothing is attached to it and no
-- game component is written. tip:K2_AttachToComponent(slot) was the maiden-flight fatal
-- (2026-07-21 12:22, step log) -- component->component attach crashes natively on this build,
-- same family as actor attach. Do not reintroduce any attach call here.
local function baseOffset(pawn)
  if ctx.config.get("wand_in_hand") then
    local u = ctx.uehelp
    for _, sname in ipairs({ ctx.map.wand.handSlot3P, ctx.map.wand.handSlot1P }) do
      local slot
      if sname then pcall(function() slot = pawn[sname] end) end
      if u.isValid(slot) then
        local okL, wl = u.call(slot, "K2_GetComponentLocation")
        local sl = okL and u.vec(wl) or nil
        local pl = ctx.identity.locationOf(pawn)
        local yaw
        local okR, rot = u.call(pawn, "K2_GetActorRotation")
        if okR then pcall(function() yaw = rot.Yaw end) end
        if sl and pl and yaw then
          -- world delta -> pawn-local (the root component only ever yaws)
          local dx, dy, dz = sl.X - pl.X, sl.Y - pl.Y, sl.Z - pl.Z
          local c, s = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
          return { X = c * dx + s * dy, Y = -s * dx + c * dy, Z = dz }, "hand"
        end
      end
    end
  end
  return { X = ctx.config.get("wand_fwd"), Y = ctx.config.get("wand_side"),
           Z = ctx.config.get("wand_up") }, "capsule"
end

-- Build the stick + seated cobalt as OUR OWN pawn-root components (the proven P6 recipe).
-- Acting like a tool comes from the game's item machinery AROUND the rig: drawing stashes the
-- held item (StashHandItem -- survived live), stowing restores it, a hotbar switch auto-stows.
-- The rig is seated AT the hand but rides the pawn root -- a safe hand-follow recipe does not
-- exist yet (see baseOffset).
local function buildRig(pawn, r)
  local m = ctx.map.wand
  -- park the held item the way the game itself does (local player only; harmless when empty)
  if ctx.config.get("wand_in_hand") and m.stashFn and isLocalPawn(pawn) then
    lastHandAction = os.clock()
    mark("stash held item")
    if ctx.uehelp.call(pawn, m.stashFn) then r.stashed = true end
  end
  local base, how = baseOffset(pawn)
  mark("build rig (" .. how .. " seat)")
  local handle = addMeshComp(pawn, meshByName(m.stickMesh), base, 1.0)
  local rel, scale = tipTransform()
  local tipRel = rel and { X = base.X + rel.X, Y = base.Y + rel.Y, Z = base.Z + rel.Z }
                      or { X = base.X, Y = base.Y, Z = base.Z + 55.0 } -- bounds unreadable: old seat
  local tip = addMeshComp(pawn, meshByName(m.cobaltMesh), tipRel, scale)
  if not (handle or tip) then return end
  r.handle = handle
  if tip then r.tips[1] = tip end
  r.mode = how
end

-- Repaint tips + fx for the owner's current state. Forged wands (charged AND uncharged) wear
-- the diamond's color; a fresh rig is plain cobalt, and no state ever returns to mundane, so
-- there is nothing to paint back. Only the CHARGED wand crackles (wand_fx: OFF until the
-- Niagara call is live-proven).
local function paintState(r, state)
  if state == "charged" or state == "uncharged" then
    local mat = diamondMaterial()
    if mat then
      for _, tip in ipairs(r.tips) do pcall(function() tip:SetMaterial(0, mat) end) end
    end
  end
  if state == "charged" then
    if not r.fx and ctx.config.get("wand_fx") and r.tips[1] then r.fx = spawnElectricity(r.tips[1]) end
  else
    pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx); r.fx = nil end end)
  end
end

-- Build/refresh the in-hand wand model for a pawn according to its owner's state.
local function refreshRig(pawn)
  if not ctx.config.get("wand_rig") then return end
  if not ctx.uehelp.isValid(pawn) then return end
  local id = playerIdOf(pawn)
  if not id then return end
  if not (wands[id] and drawn[id]) then tearRig(id); return end

  local r = rigs[id]
  if not (r and r.mode) then
    tearRig(id)
    r = { pawn = pawn, tips = {} }
    buildRig(pawn, r)
    if not r.mode then
      -- total failure: give back anything the hand attempt stashed before giving up
      if r.stashed and ctx.map.wand.restoreFn then
        lastHandAction = os.clock()
        ctx.uehelp.call(pawn, ctx.map.wand.restoreFn)
      end
      ctx.log.warn("wand: no rig components -- the wand is in your hand, just unseen")
      return
    end
    rigs[id] = r
  end
  paintState(r, wands[id])
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

--------------------------------------------------------------------- tool-like hand behavior
-- The player picked a hotbar tool while the wand was out: the game already took the hand back,
-- so the wand simply stows (visuals only -- no slot restore, no stash re-equip).
local function onHotbarChanged(pawn)
  if os.clock() - lastHandAction < 1.0 then return end  -- our own stash/restore echoes here
  if not ctx.uehelp.isValid(pawn) then return end
  local id = playerIdOf(pawn)
  if not (id and drawn[id] and rigs[id]) then return end
  drawn[id] = false
  tearRig(id, { handsBack = false })
  ctx.log.info("you stow the wand to take up a tool")
end

-- Watch the game's own tool-switch signal so the wand steps aside like any other tool would.
local function hookHotbar()
  if hotbarHooked then return end
  local fnName = ctx.map.wand.hotbarChangedFn
  if not fnName then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local path
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n == fnName then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then path = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  if not path then return end
  -- this can fire re-entrantly inside our OWN stash/restore calls -- the hook body touches no
  -- UObjects beyond the param read; all real work is deferred out of the call chain (gotcha)
  local ok = pcall(RegisterHook, path, ctx.log.guard("wand.hotbar", function(Context)
    local p; pcall(function() p = Context:get() end)
    pcall(ExecuteWithDelay, 120, ctx.log.guard("wand.hotbar2", function()
      onGameThread(function() onHotbarChanged(p) end)
    end))
  end))
  if ok then
    hotbarHooked = true
    ctx.log.info("wand: hotbar watch armed (picking a tool stows the wand)")
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
    ctx.log.info("you draw the " .. STATE_NAMES[wands[id]])
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

  -- Arm the cast + hotbar hooks as soon as a pawn exists (now, on pawn spawn, and on storms as
  -- a retry); rebuild the rig after respawns (the old rig's components died with the old pawn).
  hookCast()
  hookHotbar()
  ctx.uehelp.onNewInstance("/Script/Engine.Character", ctx.map.pawn.class,
    ctx.log.guard("wand.newpawn", function(p)
      hookCast()
      hookHotbar()
      pcall(ExecuteWithDelay, 1500, ctx.log.guard("wand.respawnrig", function()
        onGameThread(function() refreshRig(p) end)
      end))
    end))
  ctx.bus.on("weather.changed", ctx.log.guard("wand.rearm", function() hookCast(); hookHotbar() end))

  -- Live rig tuning: any wand_* config change rebuilds drawn rigs immediately (no restart).
  -- Snapshot first: tearRig/refreshRig mutate `rigs` and pairs() must not see that churn.
  ctx.bus.on("config.changed", ctx.log.guard("wand.retune", function(e)
    if not (e and type(e.key) == "string" and e.key:sub(1, 5) == "wand_") then return end
    onGameThread(function()
      local torebuild = {}
      for id, r in pairs(rigs) do torebuild[#torebuild + 1] = { id = id, pawn = r.pawn } end
      for _, t in ipairs(torebuild) do
        tearRig(t.id)
        if ctx.uehelp.isValid(t.pawn) then refreshRig(t.pawn) end
      end
    end)
  end))

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
        elseif sub == "give" then
          -- Grant the REAL cooked item (from the content pak) into the inventory. This is the
          -- true item, not the mod-managed rig: it stacks, has an icon/name, and the game holds
          -- it through its own tool system. Needs the wand pak installed (Solarpunk-Windows_1_P);
          -- with no pak the row/class won't resolve and this no-ops with a warning.
          local which = (params and params[2]) or "mundane"
          local row = ctx.map.wand.itemRows and ctx.map.wand.itemRows[which]
          if not row then ctx.log.info("sps_wand give mundane|electric"); return end
          local pc = pawnController(pawn)
          if pc and ctx.items and ctx.items.give(pc, row, 1) then
            ctx.log.info("granted the real " .. row .. " item -- check your inventory/hotbar")
          else
            ctx.log.info("could not grant " .. row ..
              " -- is the wand content pak installed? (Solarpunk-Windows_1_P.*)")
          end
        else
          local owned = wands[id] and (STATE_NAMES[wands[id]] .. (drawn[id] and ", drawn" or ", stowed"))
                        or "none owned"
          ctx.log.info("wand: " .. owned .. "  (sps_wand forge|charge|draw|give)")
        end
      end)
      return true
    end)
  end)

  ctx.log.info("wand: a real tool now -- drawn with [" .. tostring(kname) ..
    "] into the game's own hand slots; hotbar swaps stow it like any tool")
  return true
end

return F
