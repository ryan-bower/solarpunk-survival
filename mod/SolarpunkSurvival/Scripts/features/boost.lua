-- Airship boost: SPACE at the wheel pushes the control to max speed and BOOSTS -- 3X the ship's
-- top speed, the game's own boost-wind loop, and a raised FOV. SPACE again (or holding the
-- slow-down control) glides back to normal max over boost_ramp_secs; keeping the slow-down held
-- past that decelerates normally, because by then the ship is back on its stock numbers.
--
-- HOW (offline RE 2026-07-29, bytecode of BP_Airship -- the mapping.boost comment carries the
-- full derivation): applied velocity = (CurrentSpeed + BoostAddition) * 50. BoostAddition is a
-- plain double only the native boost timeline writes, and that timeline only plays for the
-- dock-autopilot (LockedOntoTarget) -- in free flight the channel is OURS. So:
--   enter:  TargetSpeed = MaxSpeed, Throttle = 1 (control pushed to max),
--           BoostAddition = (boost_mult - 1) * MaxSpeed  (top speed becomes mult * MaxSpeed),
--           FOV eases up linearly to +boost_fov_add over boost_fov_in_secs, wind loop on,
--           NS_Airship_Speed shown.
--   exit:   BoostAddition and the FOV bump ease linearly to 0 over boost_ramp_secs, wind fades.
-- Transitions tick at ~33 ms with a FIXED dt per step (never a wall clock read): the glide is
-- perfectly linear no matter how unevenly the delay timer fires, and can only ever take LONGER
-- than the configured seconds, never collapse into a couple of visible jumps.
--
-- BOOST HINT: after boost_hint_secs at max speed WITHOUT boosting, a "Press SPACE to boost"
-- TextBlock shows on the player overlay for boost_hint_show_secs, once per turn at the wheel.
-- (The vanilla boost tooltip fires even when already at max speed -- this one is speed-gated.)
-- Armed by the ship's ReceivePossessed (the ship_chest ReceiveUnpossessed discipline: hook
-- re-keyed per ship instance, re-armed on the world-entry Character notify, body only
-- schedules); the watch is a 1 s token-guarded re-chained one-shot that dies the moment the
-- player leaves the wheel. First widget-construction failure latches the hint off for the
-- session (the fishing_ui capability-latch discipline).
-- The motor pitch rising with BoostAddition is the game's own reaction (it maps the value into
-- its rotor sound) -- free feedback, no work here.
--
-- Lifecycle rules honored: the SPACE bind body touches only plain Lua then schedules; every
-- UObject is re-fetched fresh per pass; the boost watch is a bounded re-chained one-shot (150 ms
-- while boosting only), never a free-running timer; nothing here registers instance hooks, so
-- world reloads cannot strand one (a reload kills the ship -> the watch sees no ship -> state
-- snaps clean).
local F = {}
local ctx

local boosting = false   -- steady boost engaged
local ramping  = false   -- exit glide running
local chainTok = 0       -- bumping orphans any in-flight watch/ramp chain
local baseFov            -- ship-camera FOV remembered at entry (restored exactly on exit)
local boostAdd = 0       -- the full BoostAddition this boost owns
local curAdd   = 0       -- the BoostAddition currently applied (eases during the exit glide)
local curBump  = 0       -- the FOV degrees currently applied on top of baseFov
local windComp           -- AudioComponent when SpawnSound2D hands one back (else nil)
local boostedFull        -- fullname of the ship THIS boost was lit on (clears must hit it)

local TICK_FAST = 33     -- ms between steps while FOV or speed is easing (~30 fps, smooth)
local TICK_SLOW = 150    -- ms between passes when steady (just watching for the exit signal)

local function bmap() return ctx.map.boost or {} end
local function cfg(k) return ctx.config.get(k) end

local function onGameThread(fn)
  if ExecuteInGameThread and pcall(ExecuteInGameThread, fn) then return end
  pcall(fn)
end

local function deferOnly(ms, fn)
  pcall(ExecuteWithDelay, ms, fn)
end

-- Pure ramp math (unit-tested): move `cur` toward `target` by `rate` units/second over a `dt`-
-- second step, clamping at the target (a non-positive rate snaps there), and the BoostAddition
-- that makes top speed mult * maxSpeed.
function F.stepToward(cur, target, rate, dt)
  cur, target = tonumber(cur) or 0, tonumber(target) or 0
  local step = (tonumber(rate) or 0) * (tonumber(dt) or 0)
  if step <= 0 then return target end
  if cur < target then
    cur = cur + step
    if cur > target then cur = target end
  elseif cur > target then
    cur = cur - step
    if cur < target then cur = target end
  end
  return cur
end

function F.boostAddFor(maxSpeed, mult)
  local m = tonumber(mult) or 3.0
  if m < 1 then m = 1 end
  return (tonumber(maxSpeed) or 0) * (m - 1)
end

-- Pure hint math (unit-tested): "at max speed" leaves 2% headroom because CurrentSpeed
-- integrates toward MaxSpeed asymptotically-ish and float crumbs must not starve the timer;
-- hintAccum returns the new consecutive-seconds count and whether the hint just became due
-- (any dip below max resets the count -- the 20 s must be UNBROKEN).
function F.atMaxSpeed(cur, max)
  cur, max = tonumber(cur), tonumber(max)
  if not (cur and max) or max <= 0 then return false end
  return cur >= max * 0.98
end

function F.hintAccum(accum, dt, atMax, needSecs)
  if not atMax then return 0, false end
  local a = (tonumber(accum) or 0) + (tonumber(dt) or 0)
  return a, a >= (tonumber(needSecs) or 20.0)
end

local function localController()
  local pl = ctx.map.player
  return ctx.uehelp.localController(pl and pl.controllerClass) or ctx.uehelp.playerController()
end

-- The airship the LOCAL player is actually driving: at the wheel the controller POSSESSES the
-- ship, so its pawn IS the airship actor. Never "the first ship FindAllOf lists" -- in co-op
-- that boosted a teammate's ship from the authoritative host (review 2026-07-31).
local function possessedShip()
  local pc = localController()
  if not pc then return nil end
  local pawn
  pcall(function() pawn = pc:K2_GetPawn() end)
  if ctx.uehelp.isValid(pawn) and ctx.uehelp.className(pawn) == bmap().shipClass then
    return pawn
  end
  return nil
end

-- Re-find a specific ship by fullname (the boosted ship is REMEMBERED so the exit/clear path
-- can never restore the wrong ship's numbers when instance order shifts).
local function shipByFull(full)
  if not full then return nil end
  local u = ctx.uehelp
  for _, s in ipairs(u.findAll(bmap().shipClass)) do
    local f; pcall(function() f = s:GetFullName() end)
    if u.isValid(s) and f == full then return s end
  end
  return nil
end

-- ANY live ship instance -- only for resolving the class's function path when arming hooks.
local function anyShip()
  local u = ctx.uehelp
  for _, s in ipairs(u.findAll(bmap().shipClass)) do
    local full
    pcall(function() full = s:GetFullName() end)
    if u.isValid(s) and full and not full:find("Default__") then return s end
  end
  return nil
end

-- "Am I at the wheel?" -- the controller's own IsControllingAirship? (single OUT bool).
local function drivingNow()
  local fn = ctx.map.qol and ctx.map.qol.controllingShipFn
  local pc = localController()
  if not (pc and fn) then return false end
  local out = {}
  if not ctx.uehelp.call(pc, fn, out) then return false end
  local v = rawget(out, 1)
  if v == nil then local _, first = next(out) v = first end
  if type(v) == "userdata" then pcall(function() local g = v:get() v = g end) end
  return v == true
end

--------------------------------------------------------------------- wind loop
local sndCache
local function windSound()
  if sndCache ~= nil then return sndCache or nil end
  local m = bmap()
  local snd
  pcall(function() snd = StaticFindObject(m.windSoundPath) end)
  if not snd and LoadAsset then pcall(function() snd = LoadAsset(m.windSoundPath) end) end
  sndCache = snd or false
  return snd
end

local function windOn()
  local snd = windSound()
  if not snd then return end
  local pc = localController()
  if not pc then return end
  local gs
  pcall(function() gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
  if not gs then return end
  local vol = tonumber(cfg("boost_volume")) or 1.0
  -- SpawnSound2D first (returns a stoppable AudioComponent); PlaySound2D is the fire-and-forget
  -- fallback -- arity ladders, the reflected signatures vary by build (evil_animals precedent).
  local comp
  if pcall(function() comp = gs:SpawnSound2D(pc, snd, vol, 1.0, 0.0, nil, false, false) end)
      and comp then windComp = comp return end
  if pcall(function() comp = gs:SpawnSound2D(pc, snd, vol, 1.0, 0.0) end)
      and comp then windComp = comp return end
  windComp = nil
  if pcall(function() gs:PlaySound2D(pc, snd, vol, 1.0, 0.0, nil, nil, nil) end) then return end
  pcall(function() gs:PlaySound2D(pc, snd, vol, 1.0, 0.0) end)
end

local function windOff()
  local comp = windComp
  windComp = nil
  if not comp then return end
  if pcall(function() comp:FadeOut(1.0, 0.0) end) then return end
  pcall(function() comp:Stop() end)
end

--------------------------------------------------------------------- FX + FOV
local function speedFx(ship, show)
  local okC, fx = ctx.uehelp.get(ship, bmap().speedFxProp)
  if okC and ctx.uehelp.isValid(fx) then
    pcall(function() fx:SetHiddenInGame(not show, false) end)
  end
end

local function shipCamera(ship)
  local okC, cam = ctx.uehelp.get(ship, bmap().cameraProp)
  if okC and ctx.uehelp.isValid(cam) then return cam end
  return nil
end

local function setFov(ship, fov)
  local cam = shipCamera(ship)
  if cam and fov then pcall(function() cam:SetFieldOfView(fov) end) end
end

--------------------------------------------------------------------- boost hint
local hintTb             -- our TextBlock on the player overlay (world reload kills it; rebuilt)
local hintBroken = false -- capability latch: first construction failure = hint off this session
local hintUp    = false  -- the hint is currently visible
local hintLeft  = 0      -- seconds the shown hint has left
local hintAcc   = 0      -- consecutive seconds at max speed without boosting
local hintShown = false  -- once per drive session (ReceivePossessed resets it)
local hintTok   = 0      -- bumping orphans any in-flight hint watch chain
local possHooked         -- ship-instance fullname the possess hook is currently armed off
local possIds            -- { preId, postId, path }

local VIS_SHOWN, VIS_HIDDEN = 4, 1  -- SelfHitTestInvisible / Collapsed (the qol-proven pair)
local HINT_TICK = 1000              -- ms; two double reads off the ship per pass, nothing hot

-- Root canvas of the always-on player overlay (the fishing_ui "flat"-surface recipe).
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
    tb:SetText(FText("Press " .. tostring(cfg("boost_key") or "SPACE") .. " to boost"))
    local slot = root[addFn](root, tb)
    -- anchored, not pixel-positioned: lower-center at every resolution, autosized to the text
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.72 }, Maximum = { X = 0.5, Y = 0.72 } })
    slot:SetAlignment({ X = 0.5, Y = 0.5 })
    slot:SetAutoSize(true)
    slot:SetZOrder(70)
    tb:SetVisibility(VIS_HIDDEN)
  end)
  if not (ok and tb and ctx.uehelp.isValid(tb)) then
    if tb then pcall(function() tb:RemoveFromParent() end) end
    hintBroken = true
    ctx.log.warn("boost: hint label construction failed -- boost hint off this session")
    return nil
  end
  hintTb = tb
  return tb
end

local function hideHint()
  hintUp, hintLeft = false, 0
  if hintTb and ctx.uehelp.isValid(hintTb) then
    pcall(function() hintTb:SetVisibility(VIS_HIDDEN) end)
  end
end

local function showHint()
  local tb = makeHint()
  if not tb then return false end
  hintUp = true
  hintLeft = tonumber(cfg("boost_hint_show_secs")) or 5.0
  pcall(function() tb:SetVisibility(VIS_SHOWN) end)
  return true
end

-- The hint watch: armed by ReceivePossessed, dies the moment the player leaves the wheel
-- (the next possession re-arms it). Same fixed-dt discipline as the boost glide.
local function hintPass(tok)
  if tok ~= hintTok then return end
  if hintBroken or not cfg("boost_hint") then hideHint() return end
  local ship = possessedShip()   -- the ship THIS player drives, never a teammate's
  if not ship then hideHint() return end
  local dt = HINT_TICK / 1000.0
  if boosting or ramping then
    hintShown = true  -- the key is clearly known; never nag this drive
    hintAcc = 0
    if hintUp then hideHint() end
  elseif hintUp then
    hintLeft = hintLeft - dt
    if hintLeft <= 0 then hideHint() end
  elseif not hintShown then
    local m = bmap()
    local okC, cur = ctx.uehelp.get(ship, m.currentSpeedProp)
    local okM, max = ctx.uehelp.get(ship, m.maxSpeedProp)
    local due
    hintAcc, due = F.hintAccum(hintAcc, dt,
      okC and okM and F.atMaxSpeed(tonumber(cur), tonumber(max)),
      tonumber(cfg("boost_hint_secs")))
    -- showHint can fail benignly (overlay mid-rebuild): stay due and retry next pass
    if due and showHint() then hintShown = true end
  end
  deferOnly(HINT_TICK, function() onGameThread(function() hintPass(tok) end) end)
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

-- Hook registration re-keyed to the SHIP INSTANCE (world reloads rebuild the ship on a possibly
-- reloaded class and silently kill hooks left on the old copy -- the ship_chest lesson). A ship
-- FIRST BUILT mid-session isn't seen until the next world entry re-arm; accepted, same as
-- ship_chest.
local function armPossessHook()
  if not cfg("boost_hint") then return end
  local ship = anyShip()   -- any instance: only the CLASS function path is read off it
  if not ship then return end
  local shipFn; pcall(function() shipFn = ship:GetFullName() end)
  if not shipFn or shipFn == possHooked then return end
  local fn = bmap().possessFn
  if not fn then return end
  local path = fullFuncPath(ship, fn)
  if not path then return end
  if possIds then pcall(UnregisterHook, possIds[3], possIds[1], possIds[2]) end
  possIds = nil
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard("boost.possess", function()
    -- hook body: plain Lua only, then schedule -- a fresh drive session begins
    hintShown, hintAcc = false, 0
    hintTok = hintTok + 1
    local tok = hintTok
    deferOnly(1000, function() onGameThread(function() hintPass(tok) end) end)
  end))
  if ok then
    possHooked, possIds = shipFn, { pre, post, path }
    ctx.log.debug("boost: hint hook armed on " .. path)
  end
end

--------------------------------------------------------------------- enter / exit
local function snapClear(ship)
  -- immediate, no glide: for unpossess / lost ship / world reload
  boosting, ramping = false, false
  chainTok = chainTok + 1
  windOff()
  hideHint()
  -- the clear must land on the ship the boost was LIT on -- instance order can shift, and a
  -- wrong-target clear leaves BoostAddition parked on a ship forever (review 2026-07-31)
  if not (ship and ctx.uehelp.isValid(ship)) then ship = shipByFull(boostedFull) end
  if ship and ctx.uehelp.isValid(ship) then
    ctx.uehelp.set(ship, bmap().boostAdditionProp, 0.0)
    if baseFov then setFov(ship, baseFov) end
    speedFx(ship, false)
  end
  baseFov, boostAdd, curAdd, curBump, boostedFull = nil, 0, 0, 0, nil
end

local startWatch  -- fwd decl

local function enterBoost(ship)
  local m = bmap()
  local okM, maxSpeed = ctx.uehelp.get(ship, m.maxSpeedProp)
  maxSpeed = okM and tonumber(maxSpeed) or nil
  if not maxSpeed or maxSpeed <= 0 then
    ctx.log.warn("boost: could not read the ship's MaxSpeed -- no boost")
    return
  end
  boostAdd = F.boostAddFor(maxSpeed, cfg("boost_mult"))
  curAdd = boostAdd
  -- control pushed to max, then the boost on top
  ctx.uehelp.set(ship, m.throttleProp, 1.0)
  ctx.uehelp.set(ship, m.targetSpeedProp, maxSpeed)
  ctx.uehelp.set(ship, m.boostAdditionProp, boostAdd)
  if not baseFov then
    -- `local okF, f = cam and get(...)` looks right and is not: Lua adjusts `and`'s right
    -- operand to ONE value, so f was always nil and baseFov always took the fallback --
    -- every exit glide then restored 105 instead of the FOV the camera actually had.
    local cam, f = shipCamera(ship), nil
    if cam then
      local okF, v = ctx.uehelp.get(cam, m.fovProp)
      if okF then f = tonumber(v) end
    end
    baseFov = f or 105.0
  end
  -- no FOV snap here: the watch chain eases curBump up to the full bump over boost_fov_in_secs
  -- (a re-light mid-glide keeps whatever bump is currently applied and climbs from there)
  speedFx(ship, true)
  -- gate on the loop itself, not on `boosting`: a re-light DURING the exit glide still has
  -- boosting == true (beginRamp only sets `ramping`) while windOff has already dropped the
  -- component, so a flag test left every re-lit boost silent for the rest of the flight
  if not windComp then windOn() end
  hintShown = true  -- they pressed the key; the nudge is moot for the rest of this drive
  hideHint()
  pcall(function() boostedFull = ship:GetFullName() end)
  boosting, ramping = true, false
  chainTok = chainTok + 1
  startWatch(chainTok)
  ctx.log.info(string.format("*** BOOST -- %.0fX the wind (top speed %.0f) ***",
    tonumber(cfg("boost_mult")) or 3, maxSpeed + boostAdd))
end

-- The exit glide: BoostAddition and the FOV bump ease linearly to zero over boost_ramp_secs.
-- When it lands, stock numbers rule again -- keeping the slow-down control held simply keeps
-- decelerating the normal way.
local function beginRamp()
  if not boosting or ramping then return end
  ramping = true
  windOff()
  ctx.log.info("boost: easing off the wind...")
end

startWatch = function(tok)
  local tickMs = TICK_FAST  -- the delay the CURRENT pass was scheduled with (= this step's dt)
  local function pass()
    if tok ~= chainTok then return end
    if not (boosting or ramping) then return end
    local ship = possessedShip()
    local sf; if ship then pcall(function() sf = ship:GetFullName() end) end
    if not ship or (boostedFull and sf ~= boostedFull) then
      snapClear(nil)  -- left the wheel/world (or swapped ships): clean the BOOSTED ship's numbers
      return
    end
    local m = bmap()
    local fovAdd = tonumber(cfg("boost_fov_add")) or 15.0
    local dt = tickMs / 1000.0
    local easing
    if ramping then
      local secs = tonumber(cfg("boost_ramp_secs")) or 3.0
      curAdd  = F.stepToward(curAdd, 0, boostAdd / secs, dt)
      curBump = F.stepToward(curBump, 0, fovAdd / secs, dt)
      ctx.uehelp.set(ship, m.boostAdditionProp, curAdd)
      if baseFov then setFov(ship, baseFov + curBump) end
      if curAdd <= 0 and curBump <= 0 then
        speedFx(ship, false)
        boosting, ramping = false, false
        baseFov, boostAdd, curAdd, curBump = nil, 0, 0, 0
        ctx.log.info("boost: back to honest sailing")
        return
      end
      easing = true
    else
      -- steady boost: ease the FOV bump up to full over boost_fov_in_secs, then hold it
      if curBump ~= fovAdd then
        local inSecs = tonumber(cfg("boost_fov_in_secs")) or 1.0
        curBump = F.stepToward(curBump, fovAdd, fovAdd / inSecs, dt)
        if baseFov then setFov(ship, baseFov + curBump) end
        easing = curBump ~= fovAdd
      end
      -- watch for the slow-down control (negative throttle = the exit signal)
      local okT, thr = ctx.uehelp.get(ship, m.throttleProp)
      if okT and tonumber(thr) and tonumber(thr) < -0.05 then
        beginRamp()
        easing = true
      end
    end
    -- fixed-dt stepping: each step advances by the delay it ASKED for, so a late timer only
    -- stretches the glide -- it can never skip ahead and turn the ease into visible jumps
    tickMs = easing and TICK_FAST or TICK_SLOW
    deferOnly(tickMs, function() onGameThread(pass) end)
  end
  onGameThread(pass)
end

local function onBoostKey()
  if not cfg("boost_enabled") then return end
  if not drivingNow() then return end  -- on foot SPACE stays the game's jump, untouched
  local ship = possessedShip()         -- THE ship under this player's hands, nothing else
  if not ship then return end
  if boosting and not ramping then
    beginRamp()
  else
    enterBoost(ship)  -- fresh boost, or re-lighting it mid-glide
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "boost",
      { "boost.shipClass", "boost.maxSpeedProp", "boost.boostAdditionProp" }) then
    return false
  end

  local kname = cfg("boost_key") or "SPACE"
  pcall(function()
    if RegisterKeyBind and Key and Key[kname] then
      RegisterKeyBind(Key[kname], ctx.log.guard("boost.key", function()
        -- key-bind body: plain Lua only, then the game thread does the real work
        onGameThread(onBoostKey)
      end))
    end
  end)

  pcall(function()
    RegisterConsoleCommandHandler("sps_boost", function(_, params)
      local sub = (params and params[1]) or "toggle"
      onGameThread(function()
        if sub == "status" then
          ctx.log.info(string.format(
            "boost: boosting=%s ramping=%s add=%.1f driving=%s hint(acc=%.0fs shown=%s up=%s hooked=%s broken=%s)",
            tostring(boosting), tostring(ramping), boostAdd, tostring(drivingNow()),
            hintAcc, tostring(hintShown), tostring(hintUp), tostring(possHooked ~= nil),
            tostring(hintBroken)))
        elseif sub == "hint" then
          -- force-show for a live look without 20 s at the wheel
          if showHint() then ctx.log.info("boost: hint shown (forced)")
          else ctx.log.info("boost: hint could not build (overlay down or latched broken)") end
        elseif sub == "off" then
          snapClear(possessedShip())   -- falls through to the remembered boosted ship
          ctx.log.info("boost: cleared")
        else
          onBoostKey()
        end
      end)
      return true
    end)
  end)

  -- Boost hint arming: the ship streams in with the save, so the work sits a few seconds back
  -- from the world-entry Character notify (the ship_chest channel + delay); the immediate arm
  -- covers a mod hot-load into an already-running world.
  if cfg("boost_hint") then
    ctx.uehelp.onNewInstance("/Script/Engine.Character",
      (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C", function()
        deferOnly(4000, function() onGameThread(armPossessHook) end)
      end)
    deferOnly(4000, function() onGameThread(armPossessHook) end)
  end

  ctx.log.info("boost: SPACE at the wheel = " .. tostring(cfg("boost_mult")) ..
    "X wind (SPACE again or slow-down to ease off)")
  return true
end

return F
