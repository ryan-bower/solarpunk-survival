-- Bench seating + the airship passenger bench (2026-07-30, user spec): right-click a bench with
-- empty hands to sit in an open slot (three side by side on a bench), right-click again to get
-- up. Every airship grows a bench at the stern (just forward of the storage chest, on the deck);
-- up to three OTHER players sit there and ride while the owner flies -- LOCKED IN until the
-- owner parks. The non-owner boarding wall (NonOwnerBlocker) is removed so friends can walk onto
-- a ship they do not own.
--
-- HOW (the plan's adversarially-reviewed core, offline RE of bp_airship.json +
-- BP_MainPlayerCharacter's name table -- see mapping.bench for the full derivation):
--   * SITTING NEVER TELEPORTS AND NEVER CHANGES MovementMode. A pawn in MOVE_Walking with
--     collision on is carried by the ship through the engine's based movement -- the ONLY
--     network-legal way for a client to ride (base-space error checking cancels the SmoothSync
--     lag; MOVE_None/MOVE_Flying clear the base and strand the rider). And a client pawn
--     teleported >1.7uu off the server's simulation is rubber-banded, so the MVP sit is "you
--     are standing in a free slot, pinned, crouched, facing out".
--   * THE PIN is Crouch() + MaxWalkSpeedCrouched = 0 + SetIgnoreMoveInput(true). While crouched
--     the ONLY speed cap is MaxWalkSpeedCrouched, which nothing in the pawn BP ever writes
--     (sprint/walk/terrain all fight over MaxWalkSpeed -- never touched here); crouching also
--     blocks jump for free (JumpIsAllowedInternal starts !bIsCrouched); SetIgnoreMoveInput
--     zeroes acceleration at the source and is strike_fx-proven on this build. bIsCrouched and
--     the pose replicate natively, so every machine sees the sitter without a custom channel.
--   * OCCUPANCY IS DERIVED FROM PAWN POSITIONS (each pawn claims only its NEAREST slot), which
--     replicate -- every machine agrees about who sits where with zero custom replication, and
--     the same-frame race on one slot dissolves into capsule collision.
--   * The crouch goes THROUGH qol (ctx.services.setCrouch): qol's crouch bookkeeping feeds the
--     death-loot fix (dying crouched used to bury the loot chest), and qol's reconciler holds
--     the pose so the crouch keys cannot stand a sitter up.
--   * SetIgnoreMoveInput is a COUNTER on the PlayerController and the controller SURVIVES death:
--     the inc/dec is guarded by a boolean (never double), released on death/respawn/world
--     change, and `sps_bench unstick` is the unconditional ResetIgnoreMoveInput escape.
--
-- Lifecycle rules honored: hook bodies touch only plain Lua then schedule; every UObject is
-- re-fetched fresh per pass; all watches are token-guarded re-chained one-shots that
-- self-terminate (seat watch dies with the seat, ship watch disarms once every ship is parked
-- and settled); hooks are re-keyed per instance so world-load class reloads cannot strand them.
local F = {}
local ctx

local function bmap() return ctx.map.bench or {} end
local function cfg(k) return ctx.config.get(k) end

local function onGameThread(fn)
  if ExecuteInGameThread and pcall(ExecuteInGameThread, fn) then return end
  pcall(fn)
end

local function deferOnly(ms, fn)
  return pcall(ExecuteWithDelay, ms, fn) == true
end

local function fullFuncPath(obj, fnName)  -- the ship_chest recipe, verbatim
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

local function liveOf(className)  -- live, non-template instances (never the CDO)
  local out = {}
  for _, o in ipairs(ctx.uehelp.findAll(className)) do
    if ctx.uehelp.isValid(o) then
      local full; pcall(function() full = o:GetFullName() end)
      if full and not full:find("Default__", 1, true) then out[#out + 1] = o end
    end
  end
  return out
end

local function localController()
  local pl = ctx.map.player
  return ctx.uehelp.localController(pl and pl.controllerClass) or ctx.uehelp.playerController()
end

-- Single-OUT-param call (the qol callOut1 shape: fresh table, value lands in it).
local function callOut1(obj, fnName)
  local out = {}
  local ok = ctx.uehelp.call(obj, fnName, out)
  if not ok then return nil end
  local v = rawget(out, 1)
  if v == nil then local _, first = next(out) v = first end
  if type(v) == "userdata" then pcall(function() local g = v:get() v = g end) end
  return v
end

local function isLocalCharacter(pawn)
  local want = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
  return ctx.uehelp.className(pawn) == want
end

-- THIS machine's own character, and nothing else (input hooks fire with the instance as
-- context; in co-op the class hook sees every player's pawn, and only the local one is ours).
local function isMyPawn(pawn)
  if not (ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn)) then return false end
  local mine = ctx.uehelp.localPawn()
  return mine ~= nil and ctx.uehelp.sameObject(pawn, mine)
end

--------------------------------------------------------------------- pure math (unit-tested)
-- dot(camForward, dir-to-target) and the distance, from plain {X,Y,Z} tables.
function F.aimScore(camLoc, camFwd, targetLoc)
  if not (camLoc and camFwd and targetLoc) then return -1, math.huge end
  local dx, dy, dz = targetLoc.X - camLoc.X, targetLoc.Y - camLoc.Y, targetLoc.Z - camLoc.Z
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dist < 1e-6 then return 1.0, 0.0 end
  local dot = (dx * camFwd.X + dy * camFwd.Y + dz * camFwd.Z) / dist
  return dot, dist
end

-- Best candidate index, or nil. candidates = { {loc={X,Y,Z}, key="stable string"}, ... }.
-- Deterministic: lowest distance wins, ties broken by the stable key -- never object order.
function F.pickBench(candidates, camLoc, camFwd, reach, minDot)
  local best, bestD, bestK
  for i, c in ipairs(candidates or {}) do
    local dot, dist = F.aimScore(camLoc, camFwd, c.loc)
    if dist <= (tonumber(reach) or 0) and dot >= (tonumber(minDot) or 1) then
      local k = tostring(c.key or i)
      if not best or dist < bestD or (dist == bestD and k < bestK) then
        best, bestD, bestK = i, dist, k
      end
    end
  end
  return best
end

-- Seat i of n in bench-local space: seats spread along local Y, centred on the origin.
function F.slotLocal(i, n, spacing, depth, up)
  local y = ((tonumber(i) or 1) - ((tonumber(n) or 1) + 1) / 2) * (tonumber(spacing) or 0)
  return { X = tonumber(depth) or 0, Y = y, Z = tonumber(up) or 0 }
end

-- ...and in world space: yaw-only rotation around the anchor (the ship_chest convention --
-- pitch/roll on a parked anchor are noise the seats must not inherit).
function F.slotWorld(anchorLoc, anchorYaw, i, n, c)
  local l = F.slotLocal(i, n, c and c.spacing, c and c.depth, c and c.up)
  local r = math.rad(tonumber(anchorYaw) or 0)
  local co, si = math.cos(r), math.sin(r)
  return {
    X = anchorLoc.X + l.X * co - l.Y * si,
    Y = anchorLoc.Y + l.X * si + l.Y * co,
    Z = anchorLoc.Z + l.Z,
  }
end

-- Full-rotation frame math (UE conventions: left-handed, Z-up, degrees; FRotationMatrix /
-- FRotator::Quaternion formulas verbatim). The ship pitches and rolls, and the MP symptom
-- "rider stays vertical / seats drift off the tilted deck" is exactly what yaw-only math does
-- under pitch -- so ship-local offsets go to world through the REAL rotation.
function F.rotAxes(rot)
  local p, y, r = math.rad(rot.Pitch or 0), math.rad(rot.Yaw or 0), math.rad(rot.Roll or 0)
  local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
  local fwd   = { X = cp * cy, Y = cp * sy, Z = sp }
  local right = { X = sr * sp * cy - cr * sy, Y = sr * sp * sy + cr * cy, Z = -sr * cp }
  local up    = { X = -(cr * sp * cy + sr * sy), Y = cy * sr - cr * sp * sy, Z = cr * cp }
  return fwd, right, up
end

-- A local {X,Y,Z} offset expressed in world space under a full rotator.
function F.rotVec(rot, v)
  local f, r, u = F.rotAxes(rot)
  return {
    X = v.X * f.X + v.Y * r.X + v.Z * u.X,
    Y = v.X * f.Y + v.Y * r.Y + v.Z * u.Y,
    Z = v.X * f.Z + v.Y * r.Z + v.Z * u.Z,
  }
end

-- Quaternion helpers (FRotator::Quaternion / FQuat::Rotator verbatim), for composing the
-- seated lean: Euler angles do not add, quats do.
function F.quatFromRotator(rot)
  local p, y, r = math.rad(rot.Pitch or 0) / 2, math.rad(rot.Yaw or 0) / 2, math.rad(rot.Roll or 0) / 2
  local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
  return {
    X = cr * sp * sy - sr * cp * cy,
    Y = -cr * sp * cy - sr * cp * sy,
    Z = cr * cp * sy - sr * sp * cy,
    W = cr * cp * cy + sr * sp * sy,
  }
end

function F.quatMul(a, b)   -- UE order: (a*b) applies b FIRST, then a
  return {
    W = a.W * b.W - a.X * b.X - a.Y * b.Y - a.Z * b.Z,
    X = a.W * b.X + a.X * b.W + a.Y * b.Z - a.Z * b.Y,
    Y = a.W * b.Y - a.X * b.Z + a.Y * b.W + a.Z * b.X,
    Z = a.W * b.Z + a.X * b.Y - a.Y * b.X + a.Z * b.W,
  }
end

function F.quatInv(q) return { X = -q.X, Y = -q.Y, Z = -q.Z, W = q.W } end

function F.rotatorFromQuat(q)
  local test = q.Z * q.X - q.W * q.Y
  local yawY, yawX = 2 * (q.W * q.Z + q.X * q.Y), 1 - 2 * (q.Y * q.Y + q.Z * q.Z)
  local deg = 180 / math.pi
  local pitch, yaw, roll
  if test < -0.4999995 then
    pitch, yaw = -90, math.atan(yawY, yawX) * deg
    roll = -yaw - 2 * math.atan(q.X, q.W) * deg
  elseif test > 0.4999995 then
    pitch, yaw = 90, math.atan(yawY, yawX) * deg
    roll = yaw - 2 * math.atan(q.X, q.W) * deg
  else
    local t = math.max(-1, math.min(1, 2 * test))
    pitch = math.asin(t) * deg
    yaw = math.atan(yawY, yawX) * deg
    roll = math.atan(-2 * (q.W * q.X + q.Y * q.Z), 1 - 2 * (q.X * q.X + q.Y * q.Y)) * deg
  end
  local function norm(a) while a > 180 do a = a - 360 end while a < -180 do a = a + 360 end return a end
  return { Pitch = norm(pitch), Yaw = norm(yaw), Roll = norm(roll) }
end

-- The seated lean: the mesh's new capsule-relative rotation so the body aligns with the
-- tilted deck while the capsule stays upright. relNew = capsule^-1 * tilt * capsule * defRel,
-- where tilt = shipFull * shipYawOnly^-1 (the world-frame pitch/roll the hull carries).
function F.leanRelRotation(shipRot, pawnYaw, defRel)
  local qShip = F.quatFromRotator(shipRot)
  local qShipYaw = F.quatFromRotator({ Pitch = 0, Yaw = shipRot.Yaw or 0, Roll = 0 })
  local qTilt = F.quatMul(qShip, F.quatInv(qShipYaw))
  local qCap = F.quatFromRotator({ Pitch = 0, Yaw = pawnYaw or 0, Roll = 0 })
  local qDef = F.quatFromRotator(defRel or { Pitch = 0, Yaw = 0, Roll = 0 })
  local qRel = F.quatMul(F.quatInv(qCap), F.quatMul(qTilt, F.quatMul(qCap, qDef)))
  return F.rotatorFromQuat(qRel)
end

local function dist2d2(a, b)
  local dx, dy = a.X - b.X, a.Y - b.Y
  return dx * dx + dy * dy
end

-- Which slots are taken: every pawn claims its NEAREST slot only (slot_r 70 > spacing 58, so
-- "within r of ANY slot" would let one sitter shadow all three seats), and only when within r.
-- Order-independent by construction: nearest-slot assignment does not depend on pawn order.
function F.slotOccupancy(slotPts, pawnPts, r)
  local occ = {}
  for i = 1, #(slotPts or {}) do occ[i] = false end
  local r2 = (tonumber(r) or 0) ^ 2
  for _, p in ipairs(pawnPts or {}) do
    local best, bestD
    for i, s in ipairs(slotPts) do
      local d = dist2d2(p, s)
      if not best or d < bestD then best, bestD = i, d end
    end
    if best and bestD <= r2 then occ[best] = true end
  end
  return occ
end

-- The free slot nearest the pawn, or nil.
function F.firstFreeSlot(occ, pawnPt, slotPts)
  local best, bestD
  for i, taken in ipairs(occ or {}) do
    if not taken and slotPts[i] then
      local d = pawnPt and dist2d2(pawnPt, slotPts[i]) or i
      if not best or d < bestD then best, bestD = i, d end
    end
  end
  return best
end

function F.inSlot(pawnPt, slotPt, r)
  if not (pawnPt and slotPt) then return false end
  return dist2d2(pawnPt, slotPt) <= (tonumber(r) or 0) ^ 2
end

-- cm/s from two positions a fixed dt apart (3D -- a descending ship is still "moving").
function F.shipSpeed(prev, now, dt)
  if not (prev and now) or (tonumber(dt) or 0) <= 0 then return 0 end
  local dx, dy, dz = now.X - prev.X, now.Y - prev.Y, now.Z - prev.Z
  return math.sqrt(dx * dx + dy * dy + dz * dz) / dt
end

-- Fixed-dt parked accumulator (the boost hintAccum shape): state = consecutive seconds under
-- the threshold; parked once it has held for holdSecs. Any burst of speed resets it.
function F.parkState(state, speed, threshold, dt, holdSecs)
  if (tonumber(speed) or 0) >= (tonumber(threshold) or 0) then return 0, false end
  local s = (tonumber(state) or 0) + (tonumber(dt) or 0)
  return s, s >= (tonumber(holdSecs) or 1.5)
end

-- Is the seat locked right now? 0 off, 1 piloted, 2 moving, 3 either.
function F.lockedNow(mode, piloted, parked)
  mode = tonumber(mode) or 0
  if mode == 1 then return piloted == true end
  if mode == 2 then return parked ~= true end
  if mode == 3 then return piloted == true or parked ~= true end
  return false
end

-- The stand-up nudge, as a world-space delta along the seat's facing.
function F.standOffset(anchorYaw, dist)
  local r = math.rad(tonumber(anchorYaw) or 0)
  local d = tonumber(dist) or 0
  return { dX = math.cos(r) * d, dY = math.sin(r) * d }
end

--------------------------------------------------------------------- hint (the boost recipe)
local hintTb             -- our TextBlock on the player overlay (world reload kills it; rebuilt)
local hintBroken = false -- capability latch: first construction failure = hints off this session
local hintTok = 0

local VIS_SHOWN, VIS_HIDDEN = 4, 1  -- SelfHitTestInvisible / Collapsed (the qol-proven pair)

local function overlayCanvas()
  local pc = localController()
  if not ctx.uehelp.isValid(pc) then return nil end
  local overlay
  pcall(function() overlay = pc[(ctx.map.qol and ctx.map.qol.overlayProp) or "PlayerOverlay"] end)
  if not ctx.uehelp.isValid(overlay) then return nil end
  local root
  pcall(function() root = overlay.WidgetTree.RootWidget end)
  if not ctx.uehelp.isValid(root) then return nil end
  return root, overlay
end

local function makeHint()
  if hintBroken then return nil end
  if hintTb and ctx.uehelp.isValid(hintTb) then return hintTb end
  hintTb = nil
  local root, overlay = overlayCanvas()
  local cls
  pcall(function() cls = StaticFindObject("/Script/UMG.TextBlock") end)
  if not (root and cls) then return nil end  -- overlay not up yet: retry, don't latch
  local addFn = (ctx.map.fishing and ctx.map.fishing.canvasAddFn) or "AddChildToCanvas"
  local tb
  local ok = pcall(function()
    tb = StaticConstructObject(cls, overlay)
    tb:SetText(FText(""))
    local slot = root[addFn](root, tb)
    -- anchored just under the boost hint's row: lower-center at every resolution
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.78 }, Maximum = { X = 0.5, Y = 0.78 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(true)
    slot:SetZOrder(70)
    tb:SetVisibility(VIS_HIDDEN)
  end)
  if not (ok and tb and ctx.uehelp.isValid(tb)) then
    if tb then pcall(function() tb:RemoveFromParent() end) end
    hintBroken = true
    ctx.log.warn("bench: hint label construction failed -- bench hints off this session")
    return nil
  end
  hintTb = tb
  return tb
end

local function hideHint()
  if hintTb and ctx.uehelp.isValid(hintTb) then
    pcall(function() hintTb:SetVisibility(VIS_HIDDEN) end)
  end
end

local function showHint(text, secs)
  local tb = makeHint()
  if not tb then ctx.log.info("bench: " .. tostring(text)) return false end
  pcall(function() tb:SetText(FText(tostring(text))) end)
  pcall(function() tb:SetVisibility(VIS_SHOWN) end)
  hintTok = hintTok + 1
  local tok = hintTok
  deferOnly(math.floor((tonumber(secs) or 3.0) * 1000), function()
    if tok == hintTok then hideHint() end
  end)
  return true
end

--------------------------------------------------------------------- geometry off live actors
local function actorLocYaw(a)
  local loc, yaw
  pcall(function() loc = ctx.uehelp.vec(a:K2_GetActorLocation()) end)
  pcall(function() yaw = a:K2_GetActorRotation().Yaw end)
  if not (loc and type(yaw) == "number") then return nil, nil end
  return loc, yaw
end

-- The ship's TRUE frame. The actor transform only tracks the hull while Tick runs
-- (SetActorTransformToRootTransform, per the bp_airship RE); Tick is DISABLED docked/parked,
-- so K2_GetActorLocation can be arbitrarily stale on a parked ship -- that stale origin is
-- the "host seated at the ship's center" bug. The SCS `Root` StaticMeshComponent IS the
-- physical hull (the actor root is a no-collision sphere): read the component transform.
local function shipFrame(ship)
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
    local l, yaw = actorLocYaw(ship)
    if not l then return nil, nil end
    loc, rot = l, { Pitch = 0.0, Yaw = yaw, Roll = 0.0 }
  end
  return loc, rot
end

local function seatSpecFor(className)
  local s = (bmap().seats or {})[className]
  return {
    n       = (s and tonumber(s.slots)) or 3,
    spacing = (s and tonumber(s.spacing)) or tonumber(cfg("bench_slot_spacing")) or 58.0,
    depth   = tonumber(cfg("bench_seat_depth")) or 0.0,
    up      = 0.0,   -- MVP: the pin is walking-based, the capsule stays on the floor
  }
end

-- A world bench's slot points + the sitter's facing.
local function benchSlots(bench)
  local loc, yaw = actorLocYaw(bench)
  if not loc then return nil end
  local spec = seatSpecFor(ctx.uehelp.className(bench))
  local pts = {}
  for i = 1, spec.n do
    pts[i] = F.slotWorld(loc, yaw, i, spec.n, { spacing = spec.spacing, depth = spec.depth, up = spec.up })
  end
  return pts, yaw + (tonumber(cfg("bench_face_yaw")) or 0.0)
end

-- The ship's PASSENGER slots, computed from the SHIP transform alone -- they work whether or
-- not a bench actor is visible on this machine (clients may never see a non-replicated prop;
-- the prop is decoration, the seat math never reads it). Sitters face the bow. Slots are
-- authored SHIP-LOCAL and carried to world through the FULL hull rotation, so they stay on
-- the tilted deck under pitch/roll and never read a stale parked actor origin.
local function shipSlots(ship)
  local loc, rot = shipFrame(ship)
  if not loc then return nil end
  local back  = tonumber(cfg("bench_ship_back"))  or -146.0
  local right = tonumber(cfg("bench_ship_right")) or 0.0
  local up    = tonumber(cfg("bench_ship_up"))    or -30.0
  local rowYaw = math.rad(tonumber(cfg("bench_ship_yaw")) or 0.0)
  local co, si = math.cos(rowYaw), math.sin(rowYaw)
  local spacing = tonumber(cfg("bench_slot_spacing")) or 58.0
  local aOff = F.rotVec(rot, { X = back, Y = right, Z = up })
  local anchor = { X = loc.X + aOff.X, Y = loc.Y + aOff.Y, Z = loc.Z + aOff.Z }
  local pts = {}
  for i = 1, 3 do
    local l = F.slotLocal(i, 3, spacing, 0, 0)
    local o = F.rotVec(rot, { X = back + l.X * co - l.Y * si,
                              Y = right + l.X * si + l.Y * co, Z = up })
    pts[i] = { X = loc.X + o.X, Y = loc.Y + o.Y, Z = loc.Z + o.Z }
  end
  return pts, rot.Yaw + (tonumber(cfg("bench_face_yaw")) or 0.0), anchor, rot
end

-- Every OTHER live player pawn's position (occupancy input; own pawn excluded by full name).
local function otherPawnPoints(myFull)
  local pts = {}
  for _, p in ipairs(liveOf((ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C")) do
    local full; pcall(function() full = p:GetFullName() end)
    if full and full ~= myFull then
      local loc; pcall(function() loc = ctx.uehelp.vec(p:K2_GetActorLocation()) end)
      if loc then pts[#pts + 1] = loc end
    end
  end
  return pts
end

-- Camera location + forward vector, as plain tables.
local function cameraRay()
  local pc = localController()
  if not pc then return nil end
  local loc, fwd
  pcall(function()
    local mgr = pc.PlayerCameraManager
    if ctx.uehelp.isValid(mgr) then
      loc = ctx.uehelp.vec(mgr:GetCameraLocation())
      local rot = mgr:GetCameraRotation()
      local pitch, yaw = math.rad(rot.Pitch), math.rad(rot.Yaw)
      fwd = { X = math.cos(pitch) * math.cos(yaw), Y = math.cos(pitch) * math.sin(yaw),
              Z = math.sin(pitch) }
    end
  end)
  if loc and fwd then return loc, fwd end
  return nil
end

-- Shared ship-bench state, declared ahead of every user (trySit needs the adopt radius for
-- its prop exclusion; findShipBench and the watch share the latch).
local function adoptR2()
  local r = tonumber(cfg("bench_ship_adopt_r")) or 600.0
  return r * r
end
local benchLatch = {}      -- ship id -> the adopted bench's fullname (this world only)
local benchDisarmed = {}   -- bench fullname -> Pawn collision already knocked off (this world)
local unblockedShips = {}  -- ship fullname -> boarding wall already down (this world; the
                           -- getter is NOT reflected, so state lives here, not in a read-back)

--------------------------------------------------------------------- the pin
-- The one seat this machine manages: its OWN player's. Everyone else's seats are just pawns
-- standing in slots, which replication already carries.
local seat = nil        -- { kind="world"|"ship", benchFull=, shipFull=, slot=i, faceYaw=,
                        --   savedCrouchSpeed=, locked=false, parkAcc=0, prevShipPos=nil }
local seatTok = 0       -- bumping orphans the seat watch chain
local inputPinned = false  -- OUR increment on the controller's IgnoreMoveInput counter --
                           -- strike_fx shares it, so this may never double-inc or double-dec
local SEAT_TICK = 250   -- ms between seat-watch passes (validity + lock state, nothing hot)

local function setCrouchVia(pawn, want)
  if ctx.services.setCrouch then
    pcall(ctx.services.setCrouch, pawn, want)
  else
    -- qol absent (disabled by config): degrade to the bare engine calls
    ctx.uehelp.call(pawn, want and (bmap().crouchFn or "Crouch") or (bmap().uncrouchFn or "UnCrouch"), false)
  end
end

local function playSitMontage(pawn, path)
  if (tonumber(cfg("bench_pose")) or 1) ~= 2 or not path then return end
  if ctx.log.isPoisoned("bench:montage") then return end
  ctx.log.step("bench.montage")
  ctx.log.risky("bench:montage", function()
    local m
    pcall(function() m = StaticFindObject(path) end)
    if not m and LoadAsset then
      pcall(LoadAsset, path)                       -- never trust LoadAsset's return: re-query
      pcall(function() m = StaticFindObject(path) end)
    end
    if not m then return end
    local anim
    pcall(function() anim = pawn.Mesh:GetAnimInstance() end)
    if ctx.uehelp.isValid(anim) then anim:Montage_Play(m, 1.0) end
  end)
end

local function sitPin(pawn, pc, faceYaw)
  -- the speed cap: save the live MaxWalkSpeedCrouched (stock 300 -- nothing in the game
  -- writes it, so this baseline cannot be clobbered while we sit) and zero it
  local mv
  pcall(function() mv = pawn[bmap().moveCompProp or "CharacterMovement"] end)
  local saved
  if ctx.uehelp.isValid(mv) then
    local okS, v = ctx.uehelp.get(mv, bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched")
    saved = okS and tonumber(v) or nil
    ctx.uehelp.set(mv, bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched", 0.0)
  end
  -- the pose (through qol so its crouch bookkeeping -- the death-loot fix -- stays honest)
  if (tonumber(cfg("bench_pose")) or 1) >= 1 then setCrouchVia(pawn, true) end
  playSitMontage(pawn, bmap().montageSitPath)
  -- movement input off at the source (counter-guarded; see inputPinned)
  if not inputPinned and pc then
    if ctx.uehelp.call(pc, bmap().ignoreMoveInputFn or "SetIgnoreMoveInput", true) then
      inputPinned = true
    end
  end
  -- rotation is safe to force (the server adopts client rotation from the move packets)
  if cfg("bench_face_out") and type(faceYaw) == "number" then
    pcall(function() pc:SetControlRotation({ Pitch = 0.0, Yaw = faceYaw, Roll = 0.0 }) end)
    pcall(function() pawn:K2_SetActorRotation({ Pitch = 0.0, Yaw = faceYaw, Roll = 0.0 }, false) end)
  end
  return saved
end

-- Undo everything the pin did. Safe against a half-dead world: every step is independent and
-- pcall'd; the input counter and qol's crouch flag are released even when the pawn is gone.
local function releasePin(standYaw, savedSpeed, pawnFull)
  -- qol's crouch flag FIRST and unconditionally (its service ignores the pawn arg): if the
  -- body is already gone the flag would otherwise survive into the respawn and hold every
  -- fresh pawn crouched forever
  if ctx.services.setCrouch then pcall(ctx.services.setCrouch, nil, false) end
  local pc = localController()
  if inputPinned and pc then
    if ctx.uehelp.call(pc, bmap().ignoreMoveInputFn or "SetIgnoreMoveInput", false) then
      inputPinned = false
    else
      -- the guarded decrement failed (controller mid-teardown): the unconditional reset is
      -- the lesser evil vs a permanently frozen player -- strike_fx re-incs on its next stun
      ctx.uehelp.call(pc, bmap().resetIgnoreMoveInputFn or "ResetIgnoreMoveInput")
      inputPinned = false
    end
  end
  -- never write another body: on a listen server localPawn's class-name fallback can hand
  -- back a TEAMMATE's pawn, so the restore only lands on the pawn that was pinned
  local pawn = ctx.uehelp.localPawn()
  local full
  if ctx.uehelp.isValid(pawn) then pcall(function() full = pawn:GetFullName() end) end
  if ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn)
      and (pawnFull == nil or full == pawnFull) then
    local mv
    pcall(function() mv = pawn[bmap().moveCompProp or "CharacterMovement"] end)
    if ctx.uehelp.isValid(mv) then
      ctx.uehelp.set(mv, bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched",
        tonumber(savedSpeed) or 300.0)
    end
    if not ctx.services.setCrouch then setCrouchVia(pawn, false) end
    playSitMontage(pawn, bmap().montageStandPath)
    -- host-only forward nudge out of the slot (a client teleport rubber-bands)
    local d = tonumber(cfg("bench_stand_offset")) or 0
    if d > 0 and ctx.net.isHost() and type(standYaw) == "number" then
      local loc; pcall(function() loc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end)
      if loc then
        local o = F.standOffset(standYaw, d)
        pcall(function()
          pawn:K2_SetActorLocation({ X = loc.X + o.dX, Y = loc.Y + o.dY, Z = loc.Z }, false, {}, false)
        end)
      end
    end
  end
end

local function release(reason)
  if not seat then return end
  local was = seat
  seat = nil
  seatTok = seatTok + 1
  releasePin(was.faceYaw, was.savedCrouchSpeed, was.pawnFull)
  ctx.log.info("bench: stood up (" .. tostring(reason) .. ")" ..
    (was.kind == "ship" and " -- ship seat" or ""))
end

--------------------------------------------------------------------- the seat watch
-- Runs only while seated; token-guarded; re-fetches every UObject fresh per pass. Releases on:
-- pawn invalid / replaced, bench or ship gone, drifted out of the slot, controller changed.
-- For ship seats it also maintains the LOCK verdict the stand-up path consults.
local function findBenchByFull(full)
  if not full then return nil end
  for _, clsName in ipairs(bmap().classes or {}) do
    for _, b in ipairs(liveOf(clsName)) do
      local f; pcall(function() f = b:GetFullName() end)
      if f == full then return b end
    end
  end
  return nil
end

local function findShipByFull(full)
  if not full then return nil end
  for _, s in ipairs(liveOf(bmap().shipClass)) do
    local f; pcall(function() f = s:GetFullName() end)
    if f == full then return s end
  end
  return nil
end

local function shipPiloted(ship)
  local okP, ps = ctx.uehelp.get(ship, bmap().shipPlayerStateProp or "PlayerState")
  return okP and ctx.uehelp.isValid(ps)
end

local function seatWatch(tok)
  if tok ~= seatTok or not seat then return end
  local pawn = ctx.uehelp.localPawn()
  if not (ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn)) then
    release("the body is gone")
    return
  end
  local pawnFull; pcall(function() pawnFull = pawn:GetFullName() end)
  if seat.pawnFull and pawnFull ~= seat.pawnFull then
    release("the body was replaced")   -- respawned mid-seat; the Character notify races this
    return
  end
  local myLoc; pcall(function() myLoc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end)
  local slotPt, margin
  if seat.kind == "ship" then
    local ship = findShipByFull(seat.shipFull)
    if not ship then release("the ship is gone") return end
    local pts = shipSlots(ship)
    slotPt = pts and pts[seat.slot] or nil
    margin = 3.0   -- host/client ship transforms disagree by the SmoothSync lag while flying
    -- the lock verdict, refreshed with fixed-dt speed tracking
    local dt = SEAT_TICK / 1000.0
    local pos; pcall(function() pos = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
    local speed = F.shipSpeed(seat.prevShipPos, pos, dt)
    seat.prevShipPos = pos
    local parked
    seat.parkAcc, parked = F.parkState(seat.parkAcc, speed,
      tonumber(cfg("bench_park_speed")) or 40.0, dt, tonumber(cfg("bench_park_hold")) or 1.5)
    seat.locked = F.lockedNow(cfg("bench_lock_mode"), shipPiloted(ship), parked)
  else
    local bench = findBenchByFull(seat.benchFull)
    if not bench then release("the bench is gone") return end
    local pts = benchSlots(bench)
    slotPt = pts and pts[seat.slot] or nil
    margin = 1.5
    seat.locked = false
  end
  if not slotPt then release("the seat could not be measured") return end
  local r = (tonumber(cfg("bench_slot_r")) or 70.0) * margin
  if myLoc and not F.inSlot(myLoc, slotPt, r) then
    release("moved off the seat")
    return
  end
  -- scheduler note: ExecuteWithDelay is the queue-backed shadow, and the queue is DRAINED ON
  -- THE GAME THREAD -- wrapping the re-chain in ExecuteInGameThread would just re-queue it for
  -- the NEXT 50ms tick (a pure +50ms tax per pass, measured against core/scheduler.lua)
  deferOnly(SEAT_TICK, function() seatWatch(tok) end)
end

--------------------------------------------------------------------- sitting down / standing up
local lastClickAt = -1e9

local function trySit(pawn)
  local pc = localController()
  if not pc then return end
  local myFull; pcall(function() myFull = pawn:GetFullName() end)
  local myLoc; pcall(function() myLoc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end)
  local camLoc, camFwd = cameraRay()
  if not (myLoc and camLoc) then return end
  local reach = tonumber(cfg("bench_reach")) or 300.0
  local minDot = tonumber(cfg("bench_aim_dot")) or 0.55

  -- ships first: each in-range ship contributes its passenger row (works with or without a
  -- visible bench prop -- the aim target is the row's centre, off the ship transform alone),
  -- and EVERY ship's anchor goes in the exclusion list below
  local cands, actors = {}, {}
  local shipR = tonumber(cfg("bench_ship_r")) or 1200.0
  local shipAnchors = {}
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    local sLoc = select(1, actorLocYaw(ship))
    if sLoc then
      local pts, faceYaw, anchor = shipSlots(ship)
      if anchor then
        shipAnchors[#shipAnchors + 1] = anchor
        if ctx.uehelp.dist2(myLoc, sLoc) <= shipR * shipR then
          local full; pcall(function() full = ship:GetFullName() end)
          if full then
            cands[#cands + 1] = { loc = anchor, key = "ship:" .. full }
            actors[#cands] = { kind = "ship", actor = ship, full = full,
                               pts = pts, faceYaw = faceYaw }
          end
        end
      end
    end
  end
  -- ...then every mapped seatable class in the world -- EXCEPT the ship's own decorative
  -- prop: it sits exactly on the anchor, so as a "world" candidate it would win pickBench's
  -- tie-break over the ship row and seat you kind="world" on a flying deck (no lock ever
  -- engages, and the 1.5x world margin loses to re-anchor lag = dumped mid-flight)
  local aR2 = adoptR2()
  for _, clsName in ipairs(bmap().classes or {}) do
    for _, b in ipairs(liveOf(clsName)) do
      local loc = select(1, actorLocYaw(b))
      local full; pcall(function() full = b:GetFullName() end)
      if loc and full then
        local shipProp = false
        if clsName == bmap().shipBenchClass then
          for _, a in ipairs(shipAnchors) do
            if ctx.uehelp.dist2(loc, a) <= aR2 then shipProp = true break end
          end
        end
        if not shipProp then
          cands[#cands + 1] = { loc = loc, key = full }
          actors[#cands] = { kind = "world", actor = b, full = full }
        end
      end
    end
  end
  local pick = F.pickBench(cands, camLoc, camFwd, reach, minDot)
  if not pick then return end   -- nothing seatable in the crosshair: not a sit gesture
  local target = actors[pick]

  local pts, faceYaw
  if target.kind == "ship" then
    pts, faceYaw = target.pts, target.faceYaw
  else
    pts, faceYaw = benchSlots(target.actor)
  end
  if not pts then return end
  local occ = F.slotOccupancy(pts, otherPawnPoints(myFull), tonumber(cfg("bench_slot_r")) or 70.0)
  local slot = F.firstFreeSlot(occ, myLoc, pts)
  if not slot then
    showHint("No free seat", 2.5)
    return
  end
  local slotR = tonumber(cfg("bench_slot_r")) or 70.0
  if not F.inSlot(myLoc, pts[slot], slotR) then
    -- the MVP never teleports (a moved client rubber-bands): the player IS the seating
    -- mechanism -- step into the open spot and click again
    if cfg("bench_snap") and ctx.net.isHost() then
      pcall(function()
        pawn:K2_SetActorLocation({ X = pts[slot].X, Y = pts[slot].Y, Z = myLoc.Z }, false, {}, false)
      end)
    else
      showHint("Step in front of the open seat", 2.5)
      return
    end
  end

  seat = {
    kind = target.kind, slot = slot, faceYaw = faceYaw,
    benchFull = target.kind == "world" and target.full or nil,
    shipFull  = target.kind == "ship" and target.full or nil,
    pawnFull  = myFull,   -- the release must never restore a DIFFERENT body (listen-server
                          -- localPawn falls back to findFirst, which can be a teammate)
    locked = false, parkAcc = 0,
  }
  seat.savedCrouchSpeed = sitPin(pawn, pc, faceYaw)
  seatTok = seatTok + 1
  local tok = seatTok
  deferOnly(SEAT_TICK, function() seatWatch(tok) end)
  ctx.log.info(string.format("bench: seated (%s, slot %d/%d)", seat.kind, slot, #pts))
end

local function onAltInteract(pawn)
  if not cfg("bench") then return end
  if not isMyPawn(pawn) then return end
  local now = os.clock()
  if now - lastClickAt < 0.3 then return end   -- enhanced events can double-fire per press
  lastClickAt = now
  if seat then
    if seat.locked then
      showHint("The pilot has the helm -- locked in until they park", 2.5)
    else
      release("right click")
    end
    return
  end
  -- the whole tool/wand gate: a sit gesture is an EMPTY right hand (the wand's drink and every
  -- tool alt-function carry a hand item; requiring nil makes bench and all of them mutually
  -- exclusive by construction)
  if cfg("bench_require_empty_hands") then
    local okH, hand = ctx.uehelp.get(pawn, bmap().handItemProp or "CurHandItemFirstPerson")
    if okH and ctx.uehelp.isValid(hand) then return end
  end
  trySit(pawn)
end

--------------------------------------------------------------------- the ship bench prop
-- A real placeable bench kept at the ship's stern (the ship_chest machinery wholesale): host
-- spawns it, adopt-by-proximity across reloads (the world save persists placeables -- without
-- adoption every load would grow another bench), ATTACHED to the ship with its pose authored
-- ship-local (real ship geometry: banks and rights with the hull), collision fully off, never
-- polled -- re-anchored from events and the bounded ship watch below.
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

local function benchAnchor(ship)
  local loc, rot = shipFrame(ship)
  if not loc then return nil, nil end
  local back  = tonumber(cfg("bench_ship_back"))  or -146.0
  local right = tonumber(cfg("bench_ship_right")) or 0.0
  local up    = tonumber(cfg("bench_ship_up"))    or -30.0
  local o = F.rotVec(rot, { X = back, Y = right, Z = up })
  -- the PROP's spin, separate from the seat-slot frame (bench_ship_yaw): the bench meshes'
  -- length runs their LOCAL X, so +-90 lays it across the hull; the white bench's front is
  -- local +Y (player-verified 2026-07-30 -- 90 faced the backrest at the bow), hence 270
  return { X = loc.X + o.X, Y = loc.Y + o.Y, Z = loc.Z + o.Z },
    rot.Yaw + (tonumber(cfg("bench_ship_prop_yaw")) or 270.0), rot
end

local function benchNear(pt, r2)
  if not pt then return nil end
  local best, bestD = nil, r2
  for _, b in ipairs(liveOf(bmap().shipBenchClass)) do
    local bl; pcall(function() bl = ctx.uehelp.vec(b:K2_GetActorLocation()) end)
    if bl then
      local d = ctx.uehelp.dist2(bl, pt)
      if d <= bestD then best, bestD = b, d end
    end
  end
  return best
end

-- The ship's bench. LATCHED per ship id once found: adopt-by-proximity may only run in a
-- parked context (allowAdopt), because a 6m-radius search re-run every watch pass while
-- FLYING adopts -- and yanks -- any player-built garden bench the flight path grazes.
local function findShipBench(ship, allowAdopt)
  local anchor, yaw, rot = benchAnchor(ship)
  local id = tostring(shipIdOf(ship))
  local latched = benchLatch[id]
  if latched then
    for _, b in ipairs(liveOf(bmap().shipBenchClass)) do
      local f; pcall(function() f = b:GetFullName() end)
      if f == latched then return b, anchor, yaw, rot end
    end
    benchLatch[id] = nil   -- destroyed, or a world reload renamed it: re-adopt when parked
  end
  if not allowAdopt then
    -- CLIENT mid-flight latch (a join during flight strands the prop's client copy at the
    -- join point forever if latching must wait for a park): OUR prop is the only bench of
    -- the class whose movement replication is OFF (the host forces it off so every machine
    -- glues its own copy to its own smoothed ship), so the signature cannot steal a
    -- player-built bench -- and the anchor/attach guards refuse replicated copies anyway.
    -- Hosts never take this path: a host can move anything, so it only adopts parked.
    if anchor and not ctx.net.isHost() then
      local liveR = tonumber(cfg("bench_ship_adopt_live_r")) or 3000.0
      local best, bestD = nil, liveR * liveR
      for _, b in ipairs(liveOf(bmap().shipBenchClass)) do
        local okR, repMove = ctx.uehelp.get(b, "bReplicateMovement")
        if okR and repMove == false then
          local bl; pcall(function() bl = ctx.uehelp.vec(b:K2_GetActorLocation()) end)
          if bl then
            local d = ctx.uehelp.dist2(bl, anchor)
            if d <= bestD then best, bestD = b, d end
          end
        end
      end
      if best then
        local f; pcall(function() f = best:GetFullName() end)
        if f then benchLatch[id] = f end
        return best, anchor, yaw, rot
      end
    end
    return nil, anchor, yaw, rot
  end
  local b = benchNear(anchor, adoptR2())
  if not b then
    local at = ctx.save.getFlag("bench_ship_at_" .. id)
    if type(at) == "table" and at.X then
      b = benchNear({ X = at.X, Y = at.Y, Z = at.Z }, adoptR2())
    end
  end
  if b then
    local f; pcall(function() f = b:GetFullName() end)
    if f then benchLatch[id] = f end
  end
  return b, anchor, yaw, rot
end

-- Kill ALL collision on the prop, not just the Pawn response: the placeable's colliders sit
-- INSIDE the hull, and the ship's own body sweeping against them shoved a PARKED ship around
-- (player 2026-07-30: "clipping into the ship, moving erratically without any power").
-- DISABLING collision around bodies is safe -- only RE-enabling depenetrates -- and the bench
-- is pure decoration: the seat math never reads it, sitting is our own aim test, no trace.
-- Called from EVERY anchor path (spawn AND watch), so client copies and mid-session adoptees
-- are disarmed too, and latched per bench so the write lands once per world, not at 20Hz.
local function disarmBenchCollision(bench)
  if cfg("bench_ship_collide") then return end
  local full; pcall(function() full = bench:GetFullName() end)
  if full and benchDisarmed[full] then return end
  local done = pcall(function() bench:SetActorEnableCollision(false) end)
  if not done then
    -- fallback: at least knock Pawn (ECC 2 -- 3 is Visibility) off the mesh
    local mesh
    pcall(function() mesh = bench[bmap().meshProp or "PlaceableMesh"] end)
    if ctx.uehelp.isValid(mesh) then
      done = ctx.uehelp.call(mesh, "SetCollisionResponseToChannel", 2, 0) == true
    end
  end
  if done and full then benchDisarmed[full] = true end
end

-- Move the prop to its anchor. Every machine may call this; whether a write means anything is
-- decided here: the host always anchors; a client only anchors a copy whose movement is not
-- replicated (fighting the host's replicated location at NetUpdateFrequency is visible jitter).
local function anchorBench(bench, anchor, yaw, rot)
  if not (ctx.uehelp.isValid(bench) and anchor) then return end
  if not ctx.net.isHost() then
    local okR, repMove = ctx.uehelp.get(bench, "bReplicateMovement")
    if okR and repMove == true then return end   -- the host's replication owns this copy
  end
  pcall(function() bench:K2_SetActorLocation(anchor, false, {}, false) end)
  if type(yaw) == "number" then
    -- carry the hull's pitch/roll too (Euler-composed: exact when parked, near enough while
    -- flying -- this is the LAST-RESORT carrier; the attach path is the real one)
    pcall(function()
      bench:K2_SetActorRotation({ Pitch = rot and rot.Pitch or 0.0, Yaw = yaw,
                                  Roll = rot and rot.Roll or 0.0 }, false)
    end)
  end
end

-- REAL attachment (user 2026-07-30: "they should ALWAYS be attached" -- a dock RETRIEVE moves
-- an unmanned ship, which fires none of our re-arm events, and the props stayed floating in
-- the sky). K2_AttachToActor carries the prop through every teleport with zero hook coverage;
-- its FName arg is the crash-ledger family, hence the poison latch: one fatal ever, then the
-- heartbeat watch below is the carrier. KeepWorld rules (1,1,1) -- position first, then glue.
local function isAttachedTo(prop, ship)
  local parent
  pcall(function() parent = prop:GetAttachParentActor() end)
  return ctx.uehelp.isValid(parent) and ctx.uehelp.sameObject(parent, ship)
end

local function attachProp(prop, ship)
  if isAttachedTo(prop, ship) then return true end
  if not ctx.net.isHost() then
    -- the host's movement replication owns this copy; a local attach would fight it
    local okR, repMove = ctx.uehelp.get(prop, "bReplicateMovement")
    if okR and repMove == true then return false end
  end
  if ctx.log.isPoisoned("bench:attach") then return false end
  ctx.log.step("bench.attach")
  ctx.log.risky("bench:attach", function()
    pcall(function() prop:K2_AttachToActor(ship, FName("None"), 1, 1, 1, false) end)
  end)
  local ok = isAttachedTo(prop, ship)   -- verify: the engine refuses some attaches silently
  if ok then ctx.log.info("bench: prop attached to the ship (engine-carried from here)") end
  return ok
end

-- Once glued, the prop's pose is authored in SHIP-LOCAL space. The KeepWorld attach above
-- freezes whatever relative offset exists at that instant -- and attaching while the ship lay
-- TILTED (login mid-flip) baked the tilt in, so the righted ship wore a crooked bench (player
-- 2026-07-30). Writing the relative transform explicitly makes the prop real ship geometry:
-- it banks, pitches and rights WITH the hull, whatever pose the attach happened in.
local function placeBenchRelative(prop)
  local back  = tonumber(cfg("bench_ship_back"))  or -146.0
  local right = tonumber(cfg("bench_ship_right")) or 0.0
  local up    = tonumber(cfg("bench_ship_up"))    or -30.0
  local spin  = tonumber(cfg("bench_ship_prop_yaw")) or 270.0
  pcall(function() prop:K2_SetActorRelativeLocation({ X = back, Y = right, Z = up }, false, {}, false) end)
  pcall(function() prop:K2_SetActorRelativeRotation({ Pitch = 0.0, Yaw = spin, Roll = 0.0 }, false, {}, false) end)
end

-- The ship's swept movement must never grind against its own cargo: an attached collider
-- inside the hull sweep shoved the FLYING ship around (player 2026-07-30 -- the chest; the
-- bench is collision-free but shielded too in case its disable ever fails). MoveIgnoreActors
-- is runtime state, not saved -- re-applied per world, latched so it lands once.
local moveShielded = {}   -- "shipFull|propFull" -> already ignored (this world)
local function shieldShipFromProp(ship, prop)
  local sf; pcall(function() sf = ship:GetFullName() end)
  local pf; pcall(function() pf = prop:GetFullName() end)
  local key = tostring(sf) .. "|" .. tostring(pf)
  if moveShielded[key] then return end
  local root
  pcall(function() root = ship:K2_GetRootComponent() end)
  if ctx.uehelp.isValid(root) then
    if ctx.uehelp.call(root, "IgnoreActorWhenMoving", prop, true) then
      moveShielded[key] = true
      ctx.log.debug("bench: ship movement ignores its prop")
    end
  end
end

-- The prop model changed mid-rollout (garden -> white -> curved, user 2026-07-30): destroy
-- OUR old prop so the ship does not wear two. The legacy classes are ALSO player-buildable
-- seatable benches, so this is a ONE-TIME migration per ship (sidecar flag), the radius is
-- tight (100cm -- our prop sat exactly at the anchor / recorded point), and it never runs
-- again once the flag is set: a bench the player builds near a parked ship stays theirs.
local function clearLegacyProps(ship, anchor)
  local id = tostring(shipIdOf(ship))
  if ctx.save.getFlag("bench_legacy_cleared_" .. id) then return end
  local pts = { anchor }
  local at = ctx.save.getFlag("bench_ship_at_" .. id)
  if type(at) == "table" and at.X then pts[#pts + 1] = { X = at.X, Y = at.Y, Z = at.Z } end
  for _, clsName in ipairs(bmap().shipBenchLegacy or {}) do
    if clsName ~= bmap().shipBenchClass then
      for _, b in ipairs(liveOf(clsName)) do
        local bl; pcall(function() bl = ctx.uehelp.vec(b:K2_GetActorLocation()) end)
        for _, p in ipairs(pts) do
          if bl and p and ctx.uehelp.dist2(bl, p) <= 100 * 100 then
            pcall(function() b:K2_DestroyActor() end)
            ctx.log.info("bench: removed the old ship bench prop (model changed)")
            break
          end
        end
      end
    end
  end
  ctx.save.setFlag("bench_legacy_cleared_" .. id, true)
end

-- One ship's bench: exists, movement-repl off (so every machine may glue its own copy),
-- disarmed, attached, posed ship-local. Failures affect THIS ship only -- the caller's loop
-- continues to the next one (a not-yet-resident class used to abort every remaining ship).
local repDisarmed = {}   -- bench fullname -> movement replication already forced off
local function ensureOneShipBench(ship, reason)
  local bench, anchor, yaw, rot = findShipBench(ship, true)
  if not anchor then return end
  clearLegacyProps(ship, anchor)
  if not bench then
    if ctx.log.isPoisoned("bench:spawn") then return end
    local clsName = bmap().shipBenchClass
    local cls = ctx.uehelp.classByName(clsName, (bmap().classPaths or {})[clsName])
    if not cls then
      ctx.log.debug("bench: ship bench class not resident yet (" .. tostring(clsName) .. ")")
      return
    end
    ctx.log.step("bench.spawn")
    ctx.log.risky("bench:spawn", function()
      bench = ctx.uehelp.spawnActorAt(ctx.uehelp.playerController() or ship, cls, anchor)
    end)
    if not ctx.uehelp.isValid(bench) then
      ctx.log.warn("bench: could not spawn the ship's bench")
      return
    end
    ctx.log.info("bench: the ship grew a passenger bench (" .. tostring(reason) .. ")")
  end
  -- ALWAYS (spawned or adopted): movement replication off, so each machine carries its own
  -- copy glued to its own locally-smoothed ship -- raw location replication is what made the
  -- chest/bench trail the hull for riders. Also the client-adopt signature (see findShipBench).
  local bf; pcall(function() bf = bench:GetFullName() end)
  if bf and not repDisarmed[bf] then
    local okR, reps = ctx.uehelp.get(bench, "bReplicates")
    if okR and reps == true then
      if ctx.uehelp.call(bench, "SetReplicateMovement", false) then repDisarmed[bf] = true end
    else
      repDisarmed[bf] = true   -- non-replicating placeable: nothing to disarm
    end
  end
  if bf then benchLatch[tostring(shipIdOf(ship))] = bf end
  disarmBenchCollision(bench)
  shieldShipFromProp(ship, bench)
  ctx.log.step("bench.place")
  if not isAttachedTo(bench, ship) then
    anchorBench(bench, anchor, yaw, rot)   -- soft landing so the attach never yanks visibly
    attachProp(bench, ship)
  end
  if isAttachedTo(bench, ship) then
    -- ship-local pose is the authority: heals a tilt baked in by an earlier attach and
    -- doubles as live offset tuning (`sps_bench ship` re-runs this; no detach needed)
    placeBenchRelative(bench)
  end
  ctx.save.setFlag("bench_ship_at_" .. tostring(shipIdOf(ship)),
    { X = anchor.X, Y = anchor.Y, Z = anchor.Z })
end

-- Host-side: make each ship's bench exist and sit at the stern. Deferred, event-driven only.
local function ensureShipBenches(reason)
  if not (cfg("bench") and cfg("bench_ship")) then return end
  if not ctx.net.isHost() then return end
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    -- ensure only runs from parked-context events (world entry, unpossess, sps_bench ship),
    -- so proximity adoption is allowed here
    ensureOneShipBench(ship, reason)
  end
end

--------------------------------------------------------------------- the boarding wall
-- NonOwnerBlocker is a capsule enclosing the ship interior that blocks ONLY Pawn (every other
-- channel already ignores, per the CDO) -- so Pawn->Ignore is the entire, surgical unblock.
-- GetCollisionResponseToChannel is NOT a reflected UFUNCTION (plain inline C++), so a
-- read-before-write guard can never work here: the "already down" state is the Lua latch
-- above, wiped whenever the game may have re-asserted the wall (watch re-arm, the door
-- overlap whose AirshipBlockReset timer exists to put it back, world change). `force` wipes
-- it inline. Never SetCollisionEnabled toggling while someone could be inside (depenetration).
local function unblockShips(force)
  if not (cfg("bench") and cfg("bench_open_ship")) then return end
  if force then unblockedShips = {} end
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    local full; pcall(function() full = ship:GetFullName() end)
    local blocker
    pcall(function() blocker = ship[bmap().blockerProp or "NonOwnerBlocker"] end)
    if ctx.uehelp.isValid(blocker) then
      if not (full and unblockedShips[full]) then
        local done = ctx.uehelp.call(blocker, "SetCollisionResponseToChannel", 2, 0) == true
        if not done then
          done = ctx.uehelp.call(blocker, "SetCollisionEnabled", 0) == true
        end
        if not done then
          -- last resort: the game's own per-character pardon, for every live character
          for _, p in ipairs(liveOf((ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C")) do
            ctx.uehelp.call(ship, bmap().unblockFn or "UnblockAirshipForCharacter", p, true)
          end
        end
        if done then
          if full then unblockedShips[full] = true end
          ctx.log.debug("bench: boarding wall down (Pawn -> Ignore)")
        end
      end
      if cfg("bench_open_doors") then
        local okD, open = ctx.uehelp.get(ship, bmap().doorsOpenProp or "DoorsOpen")
        if okD and open == false and not shipPiloted(ship) then
          ctx.uehelp.call(ship, bmap().openDoorsFn or "OpenDoors")
        end
      end
    end
  end
end

--------------------------------------------------------------------- seated-rider sidecars
-- Derived occupancy (replicated pawn positions -- identical on every machine) drives two
-- per-pass jobs with zero custom replication:
--  * HOST PIN MIRROR: a seated client's pin (crouch + crouched-speed 0) is all LOCAL writes,
--    so the server's copy of that pawn stayed unpinned -- server sim slid it and the rider
--    rubber-banded ("character flying a bit behind the ship"). The host mirrors the speed
--    cap onto ITS copy of every crouched pawn sitting in a ship slot. Crouch itself is NOT
--    forced: the client's own crouch arrives through the movement flags once bCanCrouch is
--    true server-side (qol's host enable), and forcing it would fight the client's moves.
--  * LEAN (every machine): a seated rider's MESH aligns with the tilted deck (capsules are
--    always upright; the game's Neigung channel is look-pitch, not ship lean). Mesh-only
--    relative rotation -- camera and collision untouched -- quat-composed, with the captured
--    default restored on unseat. Config bench_lean; first write failure latches it off.
local remotePin = {}    -- pawnFull -> saved MaxWalkSpeedCrouched (HOST only)
local leanState = {}    -- pawnFull -> { def = rotator } (this machine)
local leanBroken = false

local function pawnMoveComp(p)
  local mv; pcall(function() mv = p[bmap().moveCompProp or "CharacterMovement"] end)
  if ctx.uehelp.isValid(mv) then return mv end
  return nil
end

local function restoreLean(p, full)
  local st = leanState[full]
  if not st then return end
  leanState[full] = nil
  if not (p and ctx.uehelp.isValid(p)) then return end
  pcall(function()
    local mesh = p[bmap().pawnMeshProp or "Mesh"]
    if ctx.uehelp.isValid(mesh) then mesh:K2_SetRelativeRotation(st.def, false, {}, false) end
  end)
end

local function releaseSeatSidecars()
  local pawns = {}
  for _, p in ipairs(liveOf((ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C")) do
    local full; pcall(function() full = p:GetFullName() end)
    if full then pawns[full] = p end
  end
  for full, saved in pairs(remotePin) do
    local p = pawns[full]
    if p then
      local mv = pawnMoveComp(p)
      if mv then
        ctx.uehelp.set(mv, bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched",
          tonumber(saved) or 300.0)
      end
    end
  end
  remotePin = {}
  for full in pairs(leanState) do restoreLean(pawns[full], full) end
end

local function seatSidecarPass(ships)
  local host = ctx.net.isHost()
  local leanOn = cfg("bench_lean") and not leanBroken
  if not (host or leanOn) then return end
  local slotR = tonumber(cfg("bench_slot_r")) or 70.0
  local myPawn = ctx.uehelp.localPawn()
  local myFull
  if ctx.uehelp.isValid(myPawn) then pcall(function() myFull = myPawn:GetFullName() end) end
  local sets = {}
  for _, ship in ipairs(ships) do
    local pts, _, _, rot = shipSlots(ship)
    if pts then sets[#sets + 1] = { pts = pts, rot = rot } end
  end
  if #sets == 0 then return end
  local pawns, seated = {}, {}   -- full -> pawn; full -> the seating ship's rotator
  for _, p in ipairs(liveOf((ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C")) do
    local full; pcall(function() full = p:GetFullName() end)
    if full then
      pawns[full] = p
      local loc; pcall(function() loc = ctx.uehelp.vec(p:K2_GetActorLocation()) end)
      if loc then
        for _, s in ipairs(sets) do
          for _, pt in ipairs(s.pts) do
            -- 3x margin: host/client ship transforms disagree by the SmoothSync lag
            if F.inSlot(loc, pt, slotR * 3.0) then seated[full] = s.rot break end
          end
          if seated[full] then break end
        end
      end
    end
  end
  if host then
    local speedProp = bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched"
    for full, p in pairs(pawns) do
      if full ~= myFull and seated[full] and remotePin[full] == nil then
        local okC, crouched = ctx.uehelp.get(p, bmap().crouchedProp or "bIsCrouched")
        if okC and crouched == true then
          local mv = pawnMoveComp(p)
          if mv then
            local okS, v = ctx.uehelp.get(mv, speedProp)
            local saved = (okS and tonumber(v)) or 300.0
            if saved == 0 then saved = 300.0 end   -- never memorize a zero as the restore
            if ctx.uehelp.set(mv, speedProp, 0.0) then
              remotePin[full] = saved
              ctx.log.debug("bench: rider pin mirrored on the host (crouched-speed 0)")
            end
          end
        end
      end
    end
    for full, saved in pairs(remotePin) do
      local p = pawns[full]
      local drop = p == nil or not seated[full]
      if not drop then
        local okC, crouched = ctx.uehelp.get(p, bmap().crouchedProp or "bIsCrouched")
        drop = okC and crouched == false
      end
      if drop then
        if p then
          local mv = pawnMoveComp(p)
          if mv then ctx.uehelp.set(mv, speedProp, tonumber(saved) or 300.0) end
        end
        remotePin[full] = nil
      end
    end
  end
  if leanOn then
    for full, rot in pairs(seated) do
      local p = pawns[full]
      if p and rot and (math.abs(rot.Pitch or 0) > 1.0 or math.abs(rot.Roll or 0) > 1.0) then
        local ok = pcall(function()
          local mesh = p[bmap().pawnMeshProp or "Mesh"]
          if not ctx.uehelp.isValid(mesh) then return end
          local st = leanState[full]
          if not st then
            local d = mesh.RelativeRotation
            st = { def = { Pitch = d.Pitch or 0.0, Yaw = d.Yaw or 0.0, Roll = d.Roll or 0.0 } }
            leanState[full] = st
          end
          local pr = p:K2_GetActorRotation()
          mesh:K2_SetRelativeRotation(F.leanRelRotation(rot, pr.Yaw or 0.0, st.def),
            false, {}, false)
        end)
        if not ok then
          leanBroken = true
          ctx.log.warn("bench: seat lean write failed -- lean off this session")
        end
      elseif leanState[full] then
        restoreLean(p, full)
      end
    end
    for full in pairs(leanState) do
      if not seated[full] then restoreLean(pawns[full], full) end
    end
  end
end

--------------------------------------------------------------------- the ship watch
-- One bounded chain covering flight and settling: re-anchors each ship's bench (fast while
-- anything moves or is piloted, slow while parked), re-asserts the unblock, and runs the
-- seated-rider sidecars. Disarms once every ship has been parked and settled for a few slow
-- passes; re-armed by the possess / unpossess / door hooks and world entry.
local shipTok = 0
local shipPrev = {}     -- ship fullname -> position at the previous pass
local emptyLeft = 0     -- bounded 1s retries while FindAllOf reads zero ships (stream gap)

local function shipWatchPass(tok, settleLeft)
  if tok ~= shipTok then return end
  if not (cfg("bench") and (cfg("bench_ship") or cfg("bench_open_ship"))) then
    releaseSeatSidecars()
    return
  end
  local ships = liveOf(bmap().shipClass)
  if #ships == 0 then
    shipPrev = {}
    -- a ship mid-stream or mid-respawn (dock retrieve) reads as ZERO ships for a pass or
    -- two; dying here permanently killed the chain (the boarding wall came back and nothing
    -- re-anchored). Bounded retries bridge the gap; the ship-arrived Actor notify remains
    -- the long-stop re-arm.
    if emptyLeft > 0 then
      emptyLeft = emptyLeft - 1
      deferOnly(1000, function() shipWatchPass(tok, settleLeft) end)
    else
      releaseSeatSidecars()
      ctx.log.debug("bench: ship watch idle (no ships) -- waiting on the ship-arrived notify")
    end
    return
  end
  emptyLeft = 30
  unblockShips()
  local fast = tonumber(cfg("bench_reanchor_ms_fast")) or 50
  local slow = tonumber(cfg("bench_reanchor_ms_slow")) or 150
  local anyLive = false
  local allCarried = true   -- every found prop attached (or the host's replication's problem)
  for _, ship in ipairs(ships) do
    local full; pcall(function() full = ship:GetFullName() end)
    local pos; pcall(function() pos = ctx.uehelp.vec(ship:K2_GetActorLocation()) end)
    local moving = false
    if full and pos then
      local prev = shipPrev[full]
      shipPrev[full] = pos
      moving = prev ~= nil and ctx.uehelp.dist2(prev, pos) > 4.0   -- > 2 cm since last pass
    end
    local live = moving or shipPiloted(ship)
    if live then anyLive = true end
    if cfg("bench_ship") then
      -- host adoption is a parked-only act (a flying 6m search steals player-built benches);
      -- clients may signature-latch mid-flight (see findShipBench) and only ever move copies
      -- whose movement replication is off -- i.e. provably OUR prop
      local bench, anchor, yaw, rot = findShipBench(ship, not live)
      if bench and anchor then
        disarmBenchCollision(bench)   -- latched: clients and mid-session adoptees too
        shieldShipFromProp(ship, bench)
        local carried = isAttachedTo(bench, ship)
        if not carried then
          anchorBench(bench, anchor, yaw, rot)
          carried = attachProp(bench, ship)
          if carried then placeBenchRelative(bench) end   -- ship-local pose, tilt-proof
          if not carried and not ctx.net.isHost() then
            -- a movement-replicated copy on a client is the HOST's to carry, not ours
            local okR, repMove = ctx.uehelp.get(bench, "bReplicateMovement")
            carried = okR and repMove == true
          end
        end
        if not carried then allCarried = false end
      end
    end
    -- the storage chest rides the same carrier (ship_chest registers this service)
    if ctx.services.shipChestCarry then pcall(ctx.services.shipChestCarry, ship, live) end
  end
  seatSidecarPass(ships)
  if anyLive then
    settleLeft = 20                       -- keep settling passes in the bank for the park
  else
    settleLeft = (settleLeft or 0) - 1
    if settleLeft <= 0 then
      if allCarried then
        releaseSeatSidecars()
        ctx.log.debug("bench: ship watch settled -- props engine-carried; disarmed until the next event")
        return
      end
      -- attach is poisoned/refused on this build: the heartbeat IS the carrier. A dock
      -- RETRIEVE moves an unmanned ship with no event fired -- a fully-disarmed watch left
      -- the props floating in the sky (user 2026-07-30). 1s idle tick, escalates on motion.
      deferOnly(1000, function() shipWatchPass(tok, 1) end)
      return
    end
  end
  -- single hop: ExecuteWithDelay's queue already drains on the game thread (scheduler.lua);
  -- the 50ms ticker also quantizes the delay, so `fast` below 50 is effectively 50
  deferOnly(anyLive and fast or slow, function() shipWatchPass(tok, settleLeft) end)
end

local function armShipWatch(reason)
  shipTok = shipTok + 1
  local tok = shipTok
  unblockedShips = {}   -- the game may have re-blocked since the last watch died: re-assert
  emptyLeft = 30
  ctx.log.debug("bench: ship watch armed (" .. tostring(reason) .. ")")
  shipWatchPass(tok, 20)   -- every caller is already on the game thread
end

--------------------------------------------------------------------- hooks
local altHooked = false
local altHookIds = {}    -- { {path=, pre=, post=}, ... } for the unregister below
local classHooks = {}    -- "class:fn" -> {path=, pre=, post=} (per-world)
local hookWorldPc = nil

-- A world load reloads whole class chains and silently kills hooks left on the old copies
-- (the wand's dropDeadHookLatches lesson): drop every latch when the LOCAL CONTROLLER
-- instance changes, so the next arm pass re-registers on whatever is resident now -- and
-- UNREGISTER first (the qol clearHooks pattern): classes that SURVIVE the reload keep their
-- live hook, and re-registering on those without unregistering stacks duplicate callbacks.
local function dropDeadHookLatches()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if not (pcNow and pcNow ~= hookWorldPc) then return end
  hookWorldPc = pcNow
  for _, h in ipairs(altHookIds) do pcall(UnregisterHook, h.path, h.pre, h.post) end
  for _, h in pairs(classHooks) do
    if type(h) == "table" then pcall(UnregisterHook, h.path, h.pre, h.post) end
  end
  altHooked = false
  altHookIds = {}
  classHooks = {}
  -- world-scoped object state dies with the world's names (the sidecar tables too: their
  -- pawns are gone, so restores would write nothing -- just drop the bookkeeping)
  benchLatch, benchDisarmed, unblockedShips, shipPrev, moveShielded = {}, {}, {}, {}, {}
  remotePin, leanState, repDisarmed = {}, {}, {}
end

-- Right click (IA_AltHandInteract, Completed = fires once per click, on release). The wand
-- hooks the same functions for its drink; UE4SS runs both callbacks, and the empty-hands gate
-- makes the two mutually exclusive by construction.
local function hookAltInteract()
  if altHooked then return end
  local prefix = bmap().altFnPrefix
  if not prefix then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn and ctx.map.pawn.class)
  if not pawn then return end
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
    local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard("bench.sitclick", function(Context)
      -- hook body: take the context, schedule, get out
      local p; pcall(function() p = Context:get() end)
      onGameThread(function() onAltInteract(p) end)
    end))
    if ok then
      hooked = hooked + 1
      altHookIds[#altHookIds + 1] = { path = path, pre = pre, post = post }
    end
  end
  if hooked > 0 then
    altHooked = true
    ctx.log.debug("bench: sit trigger armed (" .. hooked .. " right-click hooks)")
  end
end

-- Class-keyed hooks resolved off a live instance (the qol armHook shape). Bodies only schedule.
local function armClassHook(ownerClass, fnName, tag, body)
  if not (ownerClass and fnName) then return end
  local key = tostring(ownerClass) .. ":" .. fnName
  if classHooks[key] then return end
  local inst = ctx.uehelp.findFirst(ownerClass)
  if not inst then return end
  local path = fullFuncPath(inst, fnName)
  if not path then return end
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if ok then
    classHooks[key] = { path = path, pre = pre, post = post }
    ctx.log.debug("bench: hooked " .. path)
  end
end

local function armHooks()
  dropDeadHookLatches()
  hookAltInteract()
  local shipCls = bmap().shipClass
  -- flight starts: the bench must ride (fast re-anchor) and the wall must stay down
  armClassHook(shipCls, ctx.map.boost and ctx.map.boost.possessFn, "bench.possess", function()
    deferOnly(500, function() armShipWatch("possessed") end)
  end)
  -- parked: one clean re-anchor + re-ensure (the ship_chest moment)
  armClassHook(shipCls, ctx.map.qol and ctx.map.qol.shipUnpossessFn, "bench.unpossess", function()
    deferOnly(800, function()
      ensureShipBenches("parked")
      armShipWatch("unpossessed")
    end)
  end)
  -- someone stepped through the doors: the game's block-reset timer may have re-armed the
  -- wall -- FORCE re-assert (the Lua latch cannot see the game's re-block, so wipe it)
  armClassHook(shipCls, bmap().tuerenOverlapFn, "bench.tueren", function()
    deferOnly(200, function() unblockShips(true) end)
  end)
  -- every eject path fights the seat lock: a storm-damage eject with three players locked in
  -- is a stuck-player report -- release first, argue never
  for _, fnName in ipairs(bmap().ejectFns or {}) do
    armClassHook(shipCls, fnName, "bench.eject", function()
      deferOnly(0, function() release("ejected") end)
    end)
  end
  -- dying seated: the input counter lives on the CONTROLLER, which survives death -- release
  -- before the respawn can inherit a frozen player (qol hooks the same pair; bodies stack)
  local pl = ctx.map.player or {}
  for _, fnName in ipairs((ctx.map.qol and ctx.map.qol.deathLootStampFns) or {}) do
    armClassHook(pl.controllerClass, fnName, "bench.death", function()
      deferOnly(0, function() release("death") end)
    end)
  end
end

--------------------------------------------------------------------- world entry / new pawn
local seenPawn = nil
local function onCharacter()
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  local fn; if pawn then pcall(function() fn = pawn:GetFullName() end) end
  if fn and fn ~= seenPawn then
    local firstPawn = seenPawn == nil
    seenPawn = fn
    -- a NEW local pawn = respawn or world (re)load: any seat state belongs to the old body
    if seat then release(firstPawn and "world entry" or "respawn") end
    armHooks()
    ensureShipBenches("world entry")
    armShipWatch("world entry")
  else
    armHooks()   -- cheap and idempotent; catches late-loading classes
  end
end

--------------------------------------------------------------------- sps_bench
local function cmdStatus()
  local L = ctx.log.info
  L(string.format("bench: enabled=%s seated=%s inputPinned=%s hintBroken=%s altHooked=%s",
    tostring(cfg("bench")), seat and (seat.kind .. " slot " .. seat.slot) or "no",
    tostring(inputPinned), tostring(hintBroken), tostring(altHooked)))
  if seat then
    L(string.format("bench: seat locked=%s parkAcc=%.1f lock_mode=%s",
      tostring(seat.locked), seat.parkAcc or 0, tostring(cfg("bench_lock_mode"))))
  end
  for i, ship in ipairs(liveOf(bmap().shipClass)) do
    local pts = shipSlots(ship)
    local occ = pts and F.slotOccupancy(pts, otherPawnPoints(nil), tonumber(cfg("bench_slot_r")) or 70) or {}
    local taken = 0
    for _, t in ipairs(occ) do if t then taken = taken + 1 end end
    local bench = findShipBench(ship)
    L(string.format("bench: ship #%d piloted=%s benchProp=%s seats %d/3 taken (id %s)",
      i, tostring(shipPiloted(ship)), tostring(bench ~= nil), taken,
      tostring(shipIdOf(ship)):sub(1, 8)))
  end
end

local function cmdProbe()
  local L = ctx.log.info
  for _, b in ipairs(liveOf(bmap().shipBenchClass)) do
    local okR, role = ctx.uehelp.get(b, "RemoteRole")
    local okRp, reps = ctx.uehelp.get(b, "bReplicates")
    local okM, repMove = ctx.uehelp.get(b, "bReplicateMovement")
    local mesh; pcall(function() mesh = b[bmap().meshProp or "PlaceableMesh"] end)
    local mob; if ctx.uehelp.isValid(mesh) then pcall(function() mob = mesh.Mobility end) end
    -- NOT `isValid(mesh) and call(...) or false`: `and` adjusts its right operand to ONE
    -- value (the boost.lua baseFov lesson), so the response would always read nil
    local respOk, resp
    if ctx.uehelp.isValid(mesh) then
      respOk, resp = ctx.uehelp.call(mesh, "GetCollisionResponseToChannel", 2)
    end
    L(string.format("bench probe [bench]: RemoteRole=%s bReplicates=%s bRepMove=%s Mobility=%s pawnResp=%s",
      tostring(okR and role), tostring(okRp and reps), tostring(okM and repMove),
      tostring(mob), tostring(respOk and resp)))
  end
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    local full; pcall(function() full = ship:GetFullName() end)
    local blocker; pcall(function() blocker = ship[bmap().blockerProp or "NonOwnerBlocker"] end)
    local en, prof
    if ctx.uehelp.isValid(blocker) then
      local okE, e = ctx.uehelp.call(blocker, "GetCollisionEnabled"); en = okE and e or nil
      -- the response getter is NOT reflected (never readable from Lua); the profile name IS
      -- BlueprintPure, and the authoritative "did we unblock" signal is the Lua latch
      local okP, p = ctx.uehelp.call(blocker, "GetCollisionProfileName")
      if okP then pcall(function() prof = tostring(p and p:ToString() or p) end) end
    end
    local okD, doors = ctx.uehelp.get(ship, bmap().doorsOpenProp or "DoorsOpen")
    local parked = callOut1(ship, bmap().dockedOrParkedFn)
    L(string.format("bench probe [ship]: piloted=%s DoorsOpen=%s IsDockedOrParked=%s blockerEnabled=%s profile=%s luaUnblocked=%s benchLatched=%s",
      tostring(shipPiloted(ship)), tostring(okD and doors), tostring(parked),
      tostring(en), tostring(prof), tostring(full and unblockedShips[full] or false),
      tostring(benchLatch[tostring(shipIdOf(ship))] ~= nil)))
  end
end

local function cmdSlots()
  local L = ctx.log.info
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    local pts = shipSlots(ship)
    if pts then
      local occ = F.slotOccupancy(pts, otherPawnPoints(nil), tonumber(cfg("bench_slot_r")) or 70)
      for i, p in ipairs(pts) do
        L(string.format("bench: ship slot %d at (%.0f, %.0f, %.0f) taken=%s",
          i, p.X, p.Y, p.Z, tostring(occ[i])))
      end
    end
  end
end

-- Strays are removed ONLY where OUR bench provably lived (the recorded bench_ship_at_<id>
-- spots) and only when that spot is no longer near any live ship's stern. The old sweep
-- ("any bench of the class not near an anchor") would have destroyed every player-built
-- bench of the same model anywhere in the world.
local function cmdShipClean()
  if not ctx.net.isHost() then ctx.log.info("bench: host only") return end
  local anchors, recorded = {}, {}
  for _, ship in ipairs(liveOf(bmap().shipClass)) do
    local a = benchAnchor(ship)
    if a then anchors[#anchors + 1] = a end
    local at = ctx.save.getFlag("bench_ship_at_" .. tostring(shipIdOf(ship)))
    if type(at) == "table" and at.X then recorded[#recorded + 1] = at end
  end
  local killed = 0
  for _, b in ipairs(liveOf(bmap().shipBenchClass)) do
    local bl; pcall(function() bl = ctx.uehelp.vec(b:K2_GetActorLocation()) end)
    local atOurs, near = false, false
    for _, p in ipairs(recorded) do
      if bl and ctx.uehelp.dist2(bl, p) <= 250 * 250 then atOurs = true break end
    end
    for _, a in ipairs(anchors) do
      if bl and ctx.uehelp.dist2(bl, a) <= adoptR2() then near = true break end
    end
    if bl and atOurs and not near then
      pcall(function() b:K2_DestroyActor() end)
      killed = killed + 1
    end
  end
  ctx.log.info("bench: " .. killed .. " stray ship bench(es) removed (recorded spots only)")
end

local function handleCmd(sub, params)
  if sub == "status" then cmdStatus()
  elseif sub == "probe" then cmdProbe()
  elseif sub == "slots" then cmdSlots()
  elseif sub == "sit" then
    local pawn = ctx.uehelp.localPawn()
    if ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn) then
      if seat then ctx.log.info("bench: already seated") else trySit(pawn) end
    end
  elseif sub == "up" then
    if seat and seat.locked and params[2] ~= "force" then
      ctx.log.info("bench: locked in (pilot flying) -- `sps_bench up force` overrides")
    else
      release(params[2] == "force" and "forced" or "asked")
      if params[2] == "force" then
        local pc = localController()
        if pc then ctx.uehelp.call(pc, bmap().resetIgnoreMoveInputFn or "ResetIgnoreMoveInput") end
        inputPinned = false
      end
    end
  elseif sub == "unstick" then
    -- the full escape hatch: seat state gone, input counter zeroed, crouch caps restored
    seat = nil
    seatTok = seatTok + 1
    inputPinned = false
    local pc = localController()
    if pc then ctx.uehelp.call(pc, bmap().resetIgnoreMoveInputFn or "ResetIgnoreMoveInput") end
    local pawn = ctx.uehelp.localPawn()
    if ctx.uehelp.isValid(pawn) and isLocalCharacter(pawn) then
      local mv; pcall(function() mv = pawn[bmap().moveCompProp or "CharacterMovement"] end)
      if ctx.uehelp.isValid(mv) then
        ctx.uehelp.set(mv, bmap().maxWalkSpeedCrouchedProp or "MaxWalkSpeedCrouched", 300.0)
      end
      setCrouchVia(pawn, false)
    end
    ctx.log.info("bench: unstuck -- input reset, crouch caps restored")
  elseif sub == "ship" then
    if params[2] == "clean" then cmdShipClean()
    else
      ensureShipBenches("asked")
      armShipWatch("asked")
    end
  elseif sub == "open" then
    ctx.config.set("bench_open_ship", params[2] ~= "off")
    if params[2] ~= "off" then unblockShips(true) end
    ctx.log.info("bench: boarding wall " .. (params[2] == "off" and "left to the game" or "down"))
  elseif sub == "hint" then
    showHint(table.concat(params, " ", 2), 4.0)
  else
    ctx.log.info("bench: status|sit|up [force]|unstick|slots|ship [clean]|open [off]|probe|hint <text>")
  end
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not cfg("bench") then
    ctx.log.info("bench: disabled by config")
    return F
  end
  if not ctx.gate.require(ctx.log, ctx.map, "bench",
      { "bench.classes", "bench.shipClass", "bench.altFnPrefix", "bench.crouchFn",
        "bench.ignoreMoveInputFn" }) then
    return false
  end

  -- consumed by qol (recall assist teleports would strand riders) and anyone else who must
  -- clear seats before moving the world under them
  ctx.services.benchReleaseAll = function(reason)
    onGameThread(function() release(reason or "released") end)
  end
  ctx.services.benchSeated = function() return seat ~= nil end

  pcall(function()
    RegisterConsoleCommandHandler("sps_bench", function(_, params)
      local sub = (params and params[1]) or "status"
      onGameThread(function() handleCmd(sub, params or {}) end)
      return true
    end)
  end)

  -- world entry (the ship + pawn stream in with the save: work sits behind the notify), and a
  -- deferred first pass for a mod hot-load into an already-running world
  ctx.uehelp.onNewInstance("/Script/Engine.Character",
    (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
      deferOnly(4000, onCharacter)
    end)
  deferOnly(4000, onCharacter)
  -- a ship that streams in LATE (bought mid-session, distant base loading in) arrives after
  -- every Character notify already fired -- without this the watch never learns it exists
  -- (the Actor channel is the qol dock-notify precedent; the body only schedules)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", bmap().shipClass, function()
    deferOnly(2000, function()
      armHooks()
      ensureShipBenches("ship arrived")
      armShipWatch("ship arrived")
    end)
  end)

  ctx.log.info("bench: right-click a bench (empty hands) to sit; the ship grew a passenger " ..
    "bench; non-owner boarding open")
  return true
end

return F
