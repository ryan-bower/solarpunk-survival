-- The airship's storage chest, without the in-game upgrade (2026-07-27, user spec: the chest
-- upgrade collides with the other ship upgrades, so the ship just HAS storage).
--
-- Design: a real BP_Chest_Buildable actor kept at the inside back of EACH ship -- the exact spot
-- the game's own chest-upgrade lid occupies (SM_Chest_Top sits at ship-relative (-239, 0, 56),
-- offline RE of BP_Airship, scratchpad re_ship/). Being a real placed chest buys everything the
-- spec asks for free of new machinery: the stock chest model, the native look-at interact while
-- on foot (BPC_InteractableLogic), inventory persistence through the game's own placeable save
-- (DataToJSON/SaveData), replication to friends, and the transfer UI -- W_ChestInventory already
-- draws the chest grid AND the player's own inventory side by side (GRID_PlayerInventory).
--
-- MP carriage model (2026-07-31, the review's trailing-chest fix): the chest actor REPLICATES
-- (inventory, existence) but its MOVEMENT replication is forced OFF by the host, and EVERY
-- machine glues its own copy to its own ship with K2_AttachToActor -- so each machine's chest
-- rides its locally-smoothed ship rigidly instead of trailing the raw replicated location by
-- the SmoothSync interpolation lag. The repMove=false signature is also how a client recognises
-- OUR chest (a player-built chest replicates movement; ours is the only one that does not).
-- The bench feature's ship watch drives the per-pass carry via ctx.services.shipChestCarry.
--
-- Anchor math reads the ship's PHYSICAL hull component (the actor transform goes stale while
-- parked -- Tick, which copies hull->actor, is disabled when docked). Full rotation: the chest
-- pose is authored ship-local after the glue, so it banks and rights with the hull.
--
-- Per-ship: every airship gets its own chest, keyed by AirshipID; the anchor is remembered per
-- ship in the mod's sidecar save, so a reload adopts the restored chest, never duplicates. The
-- old single-ship flag (ship_chest_at) is read once as a migration fallback.
local F = {}
local ctx

local function qmap() return ctx.map.qol or {} end
local function bmap() return ctx.map.bench or {} end

local function deferOnly(ms, fn)
  return pcall(ExecuteWithDelay, ms, fn) == true
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

-- Live, non-template instances (the local twin of qol's liveInstances; the CDO must never be
-- moved or opened).
local function liveOf(className)
  local out = {}
  for _, o in ipairs(ctx.uehelp.findAll(className)) do
    if ctx.uehelp.isValid(o) then
      local full; pcall(function() full = o:GetFullName() end)
      if full and not full:find("Default__", 1, true) then out[#out + 1] = o end
    end
  end
  return out
end

local function ships() return liveOf(qmap().airshipClass) end

local function guidStr(g)
  local s
  pcall(function()
    s = string.format("%08X%08X%08X%08X", g.A or 0, g.B or 0, g.C or 0, g.D or 0)
  end)
  return s
end

local function shipIdOf(ship)
  local okI, id = ctx.uehelp.get(ship, bmap().shipIdProp or "AirshipID")
  local s = okI and guidStr(id) or nil
  if s and s ~= string.rep("0", 32) then return s end
  local full; pcall(function() full = ship:GetFullName() end)
  return full
end

-- UE FRotationMatrix axes (the bench.lua math, local copy): a ship-local offset to world under
-- the FULL hull rotation, so the anchor stays on the tilted deck.
local function rotVec(rot, v)
  local p, y, r = math.rad(rot.Pitch or 0), math.rad(rot.Yaw or 0), math.rad(rot.Roll or 0)
  local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
  local f = { X = cp * cy, Y = cp * sy, Z = sp }
  local ri = { X = sr * sp * cy - cr * sy, Y = sr * sp * sy + cr * cy, Z = -sr * cp }
  local u = { X = -(cr * sp * cy + sr * sy), Y = cy * sr - cr * sp * sy, Z = cr * cp }
  return {
    X = v.X * f.X + v.Y * ri.X + v.Z * u.X,
    Y = v.X * f.Y + v.Y * ri.Y + v.Z * u.Y,
    Z = v.X * f.Z + v.Y * ri.Z + v.Z * u.Z,
  }
end

-- The ship's TRUE frame: the SCS `Root` StaticMeshComponent is the physical hull; the actor
-- transform only tracks it while Tick runs and Tick is disabled docked/parked (stale-origin
-- family -- the "host seated at the ship's center" bug came from exactly this).
local function hullFrame(ship)
  local loc, rot
  pcall(function()
    local hull = ship[bmap().hullProp or "Root"]
    if ctx.uehelp.isValid(hull) then
      local l = ctx.uehelp.vec(hull:K2_GetComponentLocation())
      local r = hull:K2_GetComponentRotation()
      if l and r and type(r.Yaw) == "number" then
        loc, rot = l, { Pitch = r.Pitch or 0.0, Yaw = r.Yaw, Roll = r.Roll or 0.0 }
      end
    end
  end)
  if not loc then
    pcall(function() loc = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
    local yaw; pcall(function() yaw = ship:K2_GetActorRotation().Yaw end)
    if not (loc and type(yaw) == "number") then return nil, nil end
    rot = { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
  end
  return loc, rot
end

-- Where the chest belongs RIGHT NOW: the ship's back-interior point off the hull frame.
local function anchorPoint(ship)
  local loc, rot = hullFrame(ship)
  if not loc then return nil, nil end
  local back  = tonumber(ctx.config.get("ship_chest_back"))  or -240.0
  local right = tonumber(ctx.config.get("ship_chest_right")) or 0.0
  local up    = tonumber(ctx.config.get("ship_chest_up"))    or 40.0
  local o = rotVec(rot, { X = back, Y = right, Z = up })
  return { X = loc.X + o.X, Y = loc.Y + o.Y, Z = loc.Z + o.Z }, rot
end

local function chestNear(pt, r2)
  if not pt then return nil end
  local best, bestD = nil, r2
  for _, c in ipairs(liveOf(qmap().chestClass)) do
    local cl; pcall(function() cl = ctx.uehelp.vec(c:K2_GetActorLocation()) end)
    if cl then
      local d = ctx.uehelp.dist2(cl, pt)
      if d <= bestD then best, bestD = c, d end
    end
  end
  return best
end

local function adoptRadius2()
  local r = tonumber(ctx.config.get("ship_chest_adopt_r")) or 300.0
  return r * r
end

-- The chest must never BLOCK anything (user 2026-07-30: even with the ship's mover ignoring
-- it, the attached chest ground against the hull and the flying ship jumped around; "it
-- should not block the player or ship in any way -- don't worry that the player clips
-- through"). Every response -> OVERLAP on PlaceableMesh (the BP's only collider, offline RE
-- re_ship/): an overlap never yields a blocking hit, so neither the hull sweep nor the pawn
-- is obstructed -- but it still FIRES overlap events, which the interact prompt lives on
-- (BP_MainPlayerCharacter's own InteractionMessageSphere overlapping the interactable is
-- what shows/arms the walk-up open; all-Ignore proved that live 2026-07-30: destroy kept
-- working, open died). Visibility stays Block -- pack-up and the hand traces ride it.
-- Never LESS response than Overlap while bodies may be inside; Block is never restored, so
-- there is no depenetration launch. Responses do not replicate -- every machine runs this
-- on its own copy. Latched per chest FULLNAME (which embeds the world, so a reload's fresh
-- names self-invalidate); ensure events re-force it in case the game re-asserted responses.
-- The walk-up OPEN is a LineTraceSingle on the game's custom "Interactable" TRACE channel
-- (TraceForInteractable bytecode: TraceTypeQuery3; the chest mesh's own template Blocks a
-- channel NAMED Interactable). A single trace needs ECR_Block -- Overlap is invisible to it
-- -- and blocking a TRACE channel can never obstruct movement (sweeps test OBJECT channels).
-- The ECC slot of a named custom channel is config-assigned, so resolve it from the engine's
-- CollisionProfile CDO (DefaultChannelResponses: Name/Channel/bTraceType), trace-type entries
-- only; ECC_GameTraceChannel1=14 (the first custom slot) is the fallback.
local interactableECC
local function interactableChannel()
  if interactableECC then return interactableECC end
  pcall(function()
    local prof = StaticFindObject("/Script/Engine.Default__CollisionProfile")
    if prof and prof:IsValid() then
      for _, e in ipairs(ctx.uehelp.arrayItems(prof.DefaultChannelResponses)) do
        local nm, ch, isTrace
        pcall(function() nm = e.Name:ToString() end)
        pcall(function() ch = tonumber(e.Channel) end)
        pcall(function() isTrace = e.bTraceType == true end)
        if nm == "Interactable" and ch and isTrace then
          interactableECC = ch
          break
        end
      end
    end
  end)
  if not interactableECC then
    ctx.log.warn("ship_chest: could not resolve the Interactable trace channel; assuming ECC 14")
    interactableECC = 14
  end
  ctx.log.debug("ship_chest: Interactable trace channel = ECC " .. tostring(interactableECC))
  return interactableECC
end

local chestDisarmed = {}   -- chest fullname -> responses already set (this world's names)
local function disarmChestCollision(chest, force)
  if not ctx.uehelp.isValid(chest) then return end
  local full; pcall(function() full = chest:GetFullName() end)
  if full and chestDisarmed[full] and not force then return end
  local mesh
  pcall(function() mesh = chest[(ctx.map.bench and ctx.map.bench.meshProp) or "PlaceableMesh"] end)
  if not ctx.uehelp.isValid(mesh) then return end
  local ok = ctx.uehelp.call(mesh, "SetCollisionResponseToAllChannels", 1) == true  -- ECR_Overlap
  ctx.uehelp.call(mesh, "SetCollisionResponseToChannel", 3, 2)   -- ECC_Visibility=3 -> Block
  ctx.uehelp.call(mesh, "SetCollisionResponseToChannel", interactableChannel(), 2)  -- open trace
  if ok and full then chestDisarmed[full] = true end
end

-- Once attached, the chest's pose is authored in SHIP-LOCAL space. The KeepWorld attach
-- freezes whatever relative offset exists at that instant -- attaching while the ship lay
-- TILTED (login mid-flip) baked the tilt in, so the righted ship wore a crooked chest
-- (player 2026-07-30). The explicit relative write makes it real ship geometry: it banks
-- and rights WITH the hull, whatever pose the attach happened in.
local function placeChestRelative(chest)
  local back  = tonumber(ctx.config.get("ship_chest_back"))  or -240.0
  local right = tonumber(ctx.config.get("ship_chest_right")) or 0.0
  local up    = tonumber(ctx.config.get("ship_chest_up"))    or 40.0
  local spin  = tonumber(ctx.config.get("ship_chest_yaw"))   or 90.0
  pcall(function() chest:K2_SetActorRelativeLocation({ X = back, Y = right, Z = up }, false, {}, false) end)
  pcall(function() chest:K2_SetActorRelativeRotation({ Pitch = 0.0, Yaw = spin, Roll = 0.0 }, false, {}, false) end)
end

local function isAttachedTo(chest, ship)
  local parent
  pcall(function() parent = chest:GetAttachParentActor() end)
  return ctx.uehelp.isValid(parent) and ctx.uehelp.sameObject(parent, ship)
end

-- THE ship's chest (per ship id, latched for the session). Host adoption is by location and
-- only from parked-context events (allowAdopt): nearest chest within the tight adopt radius
-- of the recorded per-ship spot first (where OURS provably was), then of the current anchor
-- (the reload-restore case). Clients recognise our chest by the repMove=false signature --
-- a player-built chest replicates movement, so the signature cannot steal one.
local chestLatch = {}   -- ship id -> chest fullname (this world)
local function findShipChest(ship, allowAdopt)
  if not ship then return nil, nil, nil end
  local anchor, rot = anchorPoint(ship)
  local id = tostring(shipIdOf(ship))
  local latched = chestLatch[id]
  if latched then
    for _, c in ipairs(liveOf(qmap().chestClass)) do
      local f; pcall(function() f = c:GetFullName() end)
      if f == latched then return c, anchor, rot end
    end
    chestLatch[id] = nil
  end
  local found
  if allowAdopt and ctx.net.isHost() then
    local at = ctx.save.getFlag("ship_chest_at_" .. id)
    if not (type(at) == "table" and at.X) then at = ctx.save.getFlag("ship_chest_at") end  -- pre-per-ship flag
    if type(at) == "table" and at.X then
      found = chestNear({ X = at.X, Y = at.Y, Z = at.Z }, adoptRadius2())
    end
    if not found then found = chestNear(anchor, adoptRadius2()) end
  elseif not ctx.net.isHost() then
    -- client latch (works mid-flight too -- a join during flight must not wait for a park):
    -- nearest chest of the class with movement replication OFF, our chest's unique signature
    local liveR = tonumber(ctx.config.get("ship_chest_adopt_live_r")) or 3000.0
    local best, bestD = nil, liveR * liveR
    if anchor then
      for _, c in ipairs(liveOf(qmap().chestClass)) do
        local okR, repMove = ctx.uehelp.get(c, "bReplicateMovement")
        if okR and repMove == false then
          local cl; pcall(function() cl = ctx.uehelp.vec(c:K2_GetActorLocation()) end)
          if cl then
            local d = ctx.uehelp.dist2(cl, anchor)
            if d <= bestD then best, bestD = c, d end
          end
        end
      end
    end
    found = best
  end
  if found then
    local f; pcall(function() f = found:GetFullName() end)
    if f then chestLatch[id] = f end
  end
  return found, anchor, rot
end

-- Glue one machine's copy of the chest to its ship. Every machine calls this (the bench ship
-- watch drives it per pass); the guards decide whether a write means anything here: the host
-- may always act; a client only touches a copy whose movement replication is off (= ours).
local chestShielded = {}   -- "shipFull|chestFull" -> hull sweep already ignores the chest
local function carryChest(ship, live)
  if not ctx.config.get("ship_chest") then return end
  local chest, anchor, rot = findShipChest(ship, not live)
  if not (chest and anchor) then return end
  disarmChestCollision(chest)
  local sf; pcall(function() sf = ship:GetFullName() end)
  local cf; pcall(function() cf = chest:GetFullName() end)
  local key = tostring(sf) .. "|" .. tostring(cf)
  if not chestShielded[key] then
    local shipRoot
    pcall(function() shipRoot = ship:K2_GetRootComponent() end)
    if ctx.uehelp.isValid(shipRoot) then
      if ctx.uehelp.call(shipRoot, "IgnoreActorWhenMoving", chest, true) then
        chestShielded[key] = true
      end
    end
  end
  if isAttachedTo(chest, ship) then return end
  if not ctx.net.isHost() then
    local okR, repMove = ctx.uehelp.get(chest, "bReplicateMovement")
    if okR and repMove == true then return end   -- the host's replication owns this copy
  end
  if ctx.log.isPoisoned("chest:attach") then
    -- attach is off on this build: soft-carry to the anchor so the chest at least follows
    pcall(function() chest:K2_SetActorLocation(anchor, false, {}, false) end)
    if rot then
      local spin = tonumber(ctx.config.get("ship_chest_yaw")) or 90.0
      pcall(function()
        chest:K2_SetActorRotation({ Pitch = rot.Pitch, Yaw = rot.Yaw + spin, Roll = rot.Roll }, false)
      end)
    end
    return
  end
  pcall(function() chest:K2_SetActorLocation(anchor, false, {}, false) end)
  ctx.log.step("shipchest.attach")
  ctx.log.risky("chest:attach", function()
    pcall(function() chest:K2_AttachToActor(ship, FName("None"), 1, 1, 1, false) end)
  end)
  if isAttachedTo(chest, ship) then
    placeChestRelative(chest)   -- ship-local pose is the authority once glued
    ctx.log.info("ship_chest: chest attached to the ship (engine-carried from here)")
  end
end

-- Host-side: make EVERY ship's chest exist and sit at its stern. Runs deferred, from events
-- only. Failures affect one ship only; the loop continues.
local repDisarmed = {}   -- chest fullname -> movement replication forced off
local function ensureOneChest(ship, reason)
  local anchor, rot = anchorPoint(ship)
  if not anchor then return end
  local chest = findShipChest(ship, true)
  if not chest then
    -- one latch tag ("chest:spawn") shared with qol's buffer shuffle: the THING being risked
    -- is the same either way -- spawning a BP_Chest_Buildable from Lua
    if ctx.log.isPoisoned("chest:spawn") then return end
    local cls = ctx.uehelp.classByName(qmap().chestClass,
      qmap().chestClassPath and (qmap().chestClassPath .. "." .. qmap().chestClass) or nil)
    if not cls then
      ctx.log.debug("ship_chest: chest class not resident yet (" .. tostring(qmap().chestClass) .. ")")
      return
    end
    ctx.log.step("shipchest.spawn")
    ctx.log.risky("chest:spawn", function()
      chest = ctx.uehelp.spawnActorAt(ctx.uehelp.playerController() or ship, cls, anchor)
    end)
    if not ctx.uehelp.isValid(chest) then
      ctx.log.warn("ship_chest: could not spawn the ship's chest")
      return
    end
    ctx.log.info("ship_chest: the ship grew a storage chest (" .. tostring(reason) .. ")")
  end
  local id = tostring(shipIdOf(ship))
  local cf; pcall(function() cf = chest:GetFullName() end)
  if cf then chestLatch[id] = cf end
  -- movement replication OFF, always (spawned or adopted): each machine glues its own copy to
  -- its own smoothed ship; raw location replication is what made the chest trail for riders.
  -- Also the client-recognition signature (see findShipChest).
  if cf and not repDisarmed[cf] then
    local okR, reps = ctx.uehelp.get(chest, "bReplicates")
    if okR and reps == true then
      if ctx.uehelp.call(chest, "SetReplicateMovement", false) then repDisarmed[cf] = true end
    else
      repDisarmed[cf] = true
    end
  end
  disarmChestCollision(chest, true)   -- ensure events re-force (the game may have re-asserted)
  carryChest(ship, false)
  if isAttachedTo(chest, ship) then placeChestRelative(chest) end   -- live offset tuning path
  ctx.save.setFlag("ship_chest_at_" .. id, { X = anchor.X, Y = anchor.Y, Z = anchor.Z })
end

local function ensureChest(reason)
  if not ctx.config.get("ship_chest") then return end
  if not ctx.net.isHost() then return end
  for _, ship in ipairs(ships()) do
    ensureOneChest(ship, reason)
  end
end

-- The ship whose storage the LOCAL player means: the airship they are possessing (at the
-- wheel the controller's pawn IS the ship), else the nearest ship to their character. Never
-- "the first ship FindAllOf lists" -- in co-op that opened and emptied someone else's chest.
local function myShip()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  local pawn
  if pc then pcall(function() pawn = pc:K2_GetPawn() end) end
  if ctx.uehelp.isValid(pawn) and ctx.uehelp.className(pawn) == qmap().airshipClass then
    return pawn
  end
  local loc
  if ctx.uehelp.isValid(pawn) then pcall(function() loc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end) end
  if not loc then return nil end
  local r = tonumber(ctx.config.get("qol_ship_chest_range")) or 3000.0
  local best, bestD = nil, r * r
  for _, s in ipairs(ships()) do
    local sl; pcall(function() sl = ctx.uehelp.vec(s:K2_GetActorLocation()) end)
    if sl then
      local d = ctx.uehelp.dist2(sl, loc)
      if d <= bestD then best, bestD = s, d end
    end
  end
  return best
end

-- Open the ship's storage UI: the chest grid + the player's own inventory, which is the transfer
-- view the wheel wants. Works wherever the chest actor currently is. Class-checked before the BP
-- call -- handing UI_OpenChestInventory the wrong class is a fatal ScriptCore assert, not an error.
local function openShipChestUI(pc)
  if not ctx.config.get("ship_chest") then return false end
  pc = pc or ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not pc then return false end
  local chest = findShipChest(myShip(), true)
  if not chest then return false end
  local inv
  pcall(function() inv = chest[(ctx.map.wand and ctx.map.wand.inventorySystemProp) or "InventorySystem"] end)
  if not (ctx.uehelp.isValid(inv) and ctx.uehelp.className(inv) == "BC_InventorySystem_C") then
    return false
  end
  return ctx.uehelp.call(pc, qmap().openChestUiFn, inv) == true
end

-- The airship's ReceiveUnpossessed = "someone just stopped driving", the exact moment the parked
-- ship should have its chest back at its stern. The hook is registered on the CLASS function, so
-- one registration covers every ship; the body re-ensures ALL of them. It is re-keyed when the
-- LOCAL CONTROLLER changes (world (re)load reloads class chains and a hook left on the old copy
-- dies silently -- proven live 2026-07-27 on the qol chest-grid hook). Old ids are dropped first
-- so a surviving class never accumulates duplicates.
local hookWorldPc       -- local controller fullname the current registration was armed under
local hookIds           -- { preId, postId, path }
local function armShipHook()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if not pcNow or pcNow == hookWorldPc then return end
  local ship = ships()[1]
  if not ship then return end
  local fn = qmap().shipUnpossessFn
  if not fn then return end
  local path = fullFuncPath(ship, fn)
  if not path then return end
  if hookIds then pcall(UnregisterHook, hookIds[3], hookIds[1], hookIds[2]) end
  hookIds = nil
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard("shipchest.unpossess", function()
    deferOnly(800, function()
      for _, s in ipairs(ships()) do
        disarmChestCollision(findShipChest(s, ctx.net.isHost()), true)  -- every machine: responses don't replicate
      end
      ensureChest("parked")
    end)
  end))
  if ok then
    hookWorldPc, hookIds = pcNow, { pre, post, path }
    -- world-scoped latches die with the world's names; fullname keys self-invalidate but the
    -- ship-id latch does not (AirshipID persists) -- clear it so re-latch happens fresh
    chestLatch, chestShielded = {}, {}
    ctx.log.debug("ship_chest: hooked " .. path)
  end
end

function F.init(context)
  ctx = context
  if not ctx.config.get("ship_chest") then
    ctx.log.info("ship_chest: disabled by config")
    return F
  end
  if not (qmap().airshipClass and qmap().chestClass and qmap().openChestUiFn) then
    ctx.log.warn("ship_chest: mapping incomplete; feature off")
    return F
  end

  -- qol's wheel keys consume these instead of duplicating the find/verify dance; bench's ship
  -- watch drives the per-pass carriage on every machine.
  ctx.services.shipChestOpen = openShipChestUI
  ctx.services.shipChestEnsure = function(reason) deferOnly(0, function() ensureChest(reason or "asked") end) end
  ctx.services.shipChestCarry = carryChest

  -- World entry: the same Character-notify channel every world-entry trigger rides (never a bare
  -- Actor/controller notify -- that family froze world load, see the gotchas). The ship streams
  -- in with the save, so the work sits a few seconds back from the notify.
  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, function()
        armShipHook()
        for _, s in ipairs(ships()) do
          disarmChestCollision(findShipChest(s, ctx.net.isHost()), true)
        end
        ensureChest("world entry")
      end)
    end)

  ctx.log.info("ship_chest: armed (chest at each ship's stern; TAB at the wheel opens transfer)")
  return F
end

return F
