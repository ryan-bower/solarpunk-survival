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

local function liveShip()
  local u = ctx.uehelp
  for _, s in ipairs(u.findAll(bmap().shipClass)) do
    local full
    pcall(function() full = s:GetFullName() end)
    if u.isValid(s) and full and not full:find("Default__") then return s end
  end
  return nil
end

local function localController()
  local pl = ctx.map.player
  return ctx.uehelp.localController(pl and pl.controllerClass) or ctx.uehelp.playerController()
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

--------------------------------------------------------------------- enter / exit
local function snapClear(ship)
  -- immediate, no glide: for unpossess / lost ship / world reload
  boosting, ramping = false, false
  chainTok = chainTok + 1
  windOff()
  if ship and ctx.uehelp.isValid(ship) then
    ctx.uehelp.set(ship, bmap().boostAdditionProp, 0.0)
    if baseFov then setFov(ship, baseFov) end
    speedFx(ship, false)
  end
  baseFov, boostAdd, curAdd, curBump = nil, 0, 0, 0
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
    local ship = liveShip()
    if not (ship and drivingNow()) then
      snapClear(ship)  -- left the wheel (or the world) -- no glide, just clean numbers
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
  local ship = liveShip()
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
          ctx.log.info(string.format("boost: boosting=%s ramping=%s add=%.1f driving=%s",
            tostring(boosting), tostring(ramping), boostAdd, tostring(drivingNow())))
        elseif sub == "off" then
          snapClear(liveShip())
          ctx.log.info("boost: cleared")
        else
          onBoostKey()
        end
      end)
      return true
    end)
  end)

  ctx.log.info("boost: SPACE at the wheel = " .. tostring(cfg("boost_mult")) ..
    "X wind (SPACE again or slow-down to ease off)")
  return true
end

return F
