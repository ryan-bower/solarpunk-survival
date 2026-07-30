-- The airship's storage chest, without the in-game upgrade (2026-07-27, user spec: the chest
-- upgrade collides with the other ship upgrades, so the ship just HAS storage).
--
-- Design: a real BP_Chest_Buildable actor kept at the inside back of the ship -- the exact spot
-- the game's own chest-upgrade lid occupies (SM_Chest_Top sits at ship-relative (-239, 0, 56),
-- offline RE of BP_Airship, scratchpad re_ship/). Being a real placed chest buys everything the
-- spec asks for free of new machinery: the stock chest model, the native look-at interact while
-- on foot (BPC_InteractableLogic), inventory persistence through the game's own placeable save
-- (DataToJSON/SaveData), replication to friends, and the transfer UI -- W_ChestInventory already
-- draws the chest grid AND the player's own inventory side by side (GRID_PlayerInventory).
--
-- The chest IS attached to the ship (K2_AttachToActor under a poison latch -- one fatal ever,
-- then event re-anchoring is the fallback) and its pose is authored SHIP-LOCAL after the glue,
-- so it is real ship geometry: banks, rights and flies with the hull. It never blocks anything
-- (all collision responses Overlap -- non-blocking but the interact overlap still fires --
-- except Visibility which stays Block for the pack-up/hand traces; user 2026-07-30) and
-- is never followed on a timer (polling UObjects on a timer is the mod's oldest crash); ensure
-- runs on events: world entry and every ReceiveUnpossessed of the airship. Opening the storage
-- from the wheel works wherever the actor is -- the UI call only needs its InventorySystem.
--
-- The anchor is remembered in the mod's sidecar save (save/state.json rides every game save), so
-- after a reload the chest the game restored at the old spot is recognised and adopted, never
-- duplicated. Adoption is by location: "the chest within adopt-range of where the ship chest
-- belongs (or last was)" IS the ship chest. Host does all spawning/moving; clients only find the
-- replicated actor.
local F = {}
local ctx

local function qmap() return ctx.map.qol or {} end

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

local function theShip()
  return liveOf(qmap().airshipClass)[1]
end

-- Where the chest belongs RIGHT NOW: the ship's back-interior point, ship-relative offsets
-- rotated by the ship's yaw. Yaw only -- this is computed when the ship is parked (level), and a
-- parked ship's pitch/roll are noise the chest should not inherit.
local function anchorPoint(ship)
  local loc, yaw
  pcall(function() loc = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
  pcall(function() yaw = ship:K2_GetActorRotation().Yaw end)
  if not (loc and type(yaw) == "number") then return nil, nil end
  local back  = tonumber(ctx.config.get("ship_chest_back"))  or -240.0
  local right = tonumber(ctx.config.get("ship_chest_right")) or 0.0
  local up    = tonumber(ctx.config.get("ship_chest_up"))    or 40.0
  local r = math.rad(yaw)
  local c, s = math.cos(r), math.sin(r)
  return {
    X = loc.X + back * c - right * s,
    Y = loc.Y + back * s + right * c,
    Z = loc.Z + up,
  }, yaw
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
  local r = tonumber(ctx.config.get("ship_chest_adopt_r")) or 600.0
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
-- on its own copy; events are rare enough that re-applying beats a stale-able latch.
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

local function disarmChestCollision(chest)
  if not ctx.uehelp.isValid(chest) then return end
  local mesh
  pcall(function() mesh = chest[(ctx.map.bench and ctx.map.bench.meshProp) or "PlaceableMesh"] end)
  if not ctx.uehelp.isValid(mesh) then return end
  ctx.uehelp.call(mesh, "SetCollisionResponseToAllChannels", 1)  -- ECR_Overlap
  ctx.uehelp.call(mesh, "SetCollisionResponseToChannel", 3, 2)   -- ECC_Visibility=3 -> Block
  ctx.uehelp.call(mesh, "SetCollisionResponseToChannel", interactableChannel(), 2)  -- open trace
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

-- The ship chest, found fresh every time (never cached across ticks): nearest chest to where it
-- belongs, else nearest to where the sidecar remembers leaving it (the ship flew away, or a
-- reload restored the chest at its old spot).
local function findShipChest(ship)
  local anchor = ship and anchorPoint(ship) or nil
  local c = chestNear(anchor, adoptRadius2())
  if c then return c, anchor end
  local at = ctx.save.getFlag("ship_chest_at")
  if type(at) == "table" and at.X then
    return chestNear({ X = at.X, Y = at.Y, Z = at.Z }, adoptRadius2()), anchor
  end
  return nil, anchor
end

-- Host-side: make the ship's chest exist and sit at the ship's back. Runs deferred, from events
-- only. Move + rotate are the proven-safe K2 calls; the one genuinely new native op -- spawning a
-- placeable the build system usually births -- is under its own poison latch, so if this build
-- objects it costs one crash ever and the feature reports itself dead thereafter.
local function ensureChest(reason)
  if not ctx.config.get("ship_chest") then return end
  if not ctx.net.isHost() then return end
  local ship = theShip()
  if not ship then return end
  local anchor, yaw = anchorPoint(ship)
  if not anchor then return end
  local chest = findShipChest(ship)
  if not chest then
    -- one latch tag ("chest:spawn") shared with qol's buffer shuffle: the THING being risked is
    -- the same either way -- spawning a BP_Chest_Buildable from Lua
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
  -- Non-blocking by spec (see disarmChestCollision); IgnoreActorWhenMoving stays as belt and
  -- braces for the hull sweep. Runtime state, not saved: re-applied every ensure (idempotent).
  disarmChestCollision(chest)
  local shipRoot
  pcall(function() shipRoot = ship:K2_GetRootComponent() end)
  if ctx.uehelp.isValid(shipRoot) then
    ctx.uehelp.call(shipRoot, "IgnoreActorWhenMoving", chest, true)
  end
  local attachedParent
  pcall(function() attachedParent = chest:GetAttachParentActor() end)
  local attached = ctx.uehelp.isValid(attachedParent) and ctx.uehelp.sameObject(attachedParent, ship)
  if not attached then
    ctx.log.step("shipchest.place")
    pcall(function() chest:K2_SetActorLocation(anchor, false, {}, false) end)
    if type(yaw) == "number" then
      local spin = tonumber(ctx.config.get("ship_chest_yaw")) or 90.0
      pcall(function() chest:K2_SetActorRotation({ Pitch = 0.0, Yaw = yaw + spin, Roll = 0.0 }, false) end)
    end
    -- REAL attachment (user 2026-07-30: a dock RETRIEVE moved the unmanned ship -- no
    -- possess/unpossess fires -- and the chest stayed floating in the sky; "they should
    -- ALWAYS be attached"). KeepWorld attach right after placement, so the engine carries it
    -- through recall/retrieve with zero hook coverage. The FName arg is the crash-ledger
    -- family, hence the poison latch: one fatal ever, then the event-driven placement above
    -- remains the (holey) fallback. Host-only here; movement replication carries clients.
    if not ctx.log.isPoisoned("chest:attach") then
      ctx.log.step("shipchest.attach")
      ctx.log.risky("chest:attach", function()
        pcall(function() chest:K2_AttachToActor(ship, FName("None"), 1, 1, 1, false) end)
      end)
      pcall(function() attachedParent = chest:GetAttachParentActor() end)
      if ctx.uehelp.isValid(attachedParent) and ctx.uehelp.sameObject(attachedParent, ship) then
        ctx.log.info("ship_chest: chest attached to the ship (engine-carried from here)")
      end
    end
  end
  if ctx.uehelp.isValid(attachedParent) and ctx.uehelp.sameObject(attachedParent, ship) then
    -- ship-local pose is the authority once glued: heals a tilt an earlier attach baked in,
    -- and doubles as live offset tuning (re-runs on every ensure)
    placeChestRelative(chest)
  end
  ctx.save.setFlag("ship_chest_at", { X = anchor.X, Y = anchor.Y, Z = anchor.Z })
end

-- Open the ship's storage UI: the chest grid + the player's own inventory, which is the transfer
-- view the wheel wants. Works wherever the chest actor currently is. Class-checked before the BP
-- call -- handing UI_OpenChestInventory the wrong class is a fatal ScriptCore assert, not an error.
local function openShipChestUI(pc)
  if not ctx.config.get("ship_chest") then return false end
  pc = pc or ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not pc then return false end
  local chest = findShipChest(theShip())
  if not chest then return false end
  local inv
  pcall(function() inv = chest[(ctx.map.wand and ctx.map.wand.inventorySystemProp) or "InventorySystem"] end)
  if not (ctx.uehelp.isValid(inv) and ctx.uehelp.className(inv) == "BC_InventorySystem_C") then
    return false
  end
  return ctx.uehelp.call(pc, qmap().openChestUiFn, inv) == true
end

-- The airship's ReceiveUnpossessed = "someone just stopped driving", the exact moment the parked
-- ship should have its chest back at its stern. Hook body touches nothing; it only schedules.
-- The registration is re-keyed to the SHIP INSTANCE: a world (re)load builds a fresh airship on
-- a possibly-reloaded class, and a hook left on the old copy dies silently (proven live
-- 2026-07-27 on the qol chest-grid hook). Old ids are dropped first so a surviving class never
-- accumulates duplicates.
local hookedShip        -- fullname of the ship instance the current registration was armed off
local hookIds           -- { preId, postId, path }
local function armShipHook()
  local ship = theShip()
  if not ship then return end
  local shipFn; pcall(function() shipFn = ship:GetFullName() end)
  if not shipFn or shipFn == hookedShip then return end
  local fn = qmap().shipUnpossessFn
  if not fn then return end
  local path = fullFuncPath(ship, fn)
  if not path then return end
  if hookIds then pcall(UnregisterHook, hookIds[3], hookIds[1], hookIds[2]) end
  hookIds = nil
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard("shipchest.unpossess", function()
    deferOnly(800, function()
      disarmChestCollision(findShipChest(theShip()))   -- every machine: responses don't replicate
      ensureChest("parked")
    end)
  end))
  if ok then
    hookedShip, hookIds = shipFn, { pre, post, path }
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

  -- qol's wheel keys consume these instead of duplicating the find/verify dance.
  ctx.services.shipChestOpen = openShipChestUI
  ctx.services.shipChestEnsure = function(reason) deferOnly(0, function() ensureChest(reason or "asked") end) end

  -- World entry: the same Character-notify channel every world-entry trigger rides (never a bare
  -- Actor/controller notify -- that family froze world load, see the gotchas). The ship streams
  -- in with the save, so the work sits a few seconds back from the notify.
  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, function()
        armShipHook()
        disarmChestCollision(findShipChest(theShip()))   -- every machine: responses don't replicate
        ensureChest("world entry")
      end)
    end)

  ctx.log.info("ship_chest: armed (chest at the ship's stern; TAB at the wheel opens transfer)")
  return F
end

return F
