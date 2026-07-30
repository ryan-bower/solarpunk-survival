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
--           Camera.FieldOfView += boost_fov_add, wind loop on, NS_Airship_Speed shown.
--   exit:   BoostAddition and the FOV bump lerp to 0 over boost_ramp_secs, wind fades.
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
local boostAdd = 0       -- the BoostAddition we currently own
local windComp           -- AudioComponent when SpawnSound2D hands one back (else nil)

local function bmap() return ctx.map.boost or {} end
local function cfg(k) return ctx.config.get(k) end

local function onGameThread(fn)
  if ExecuteInGameThread and pcall(ExecuteInGameThread, fn) then return end
  pcall(fn)
end

local function deferOnly(ms, fn)
  pcall(ExecuteWithDelay, ms, fn)
end

-- Pure ramp math (unit-tested): fraction of the boost still applied at `elapsed` seconds into
-- a `secs`-long exit glide, and the BoostAddition that makes top speed mult * maxSpeed.
function F.rampK(elapsed, secs)
  if not secs or secs <= 0 then return 0 end
  local k = 1 - (elapsed or 0) / secs
  if k < 0 then return 0 end
  if k > 1 then return 1 end
  return k
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
  baseFov, boostAdd = nil, 0
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
  setFov(ship, baseFov + (tonumber(cfg("boost_fov_add")) or 20.0))
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

-- The exit glide: BoostAddition and the FOV bump lerp to zero over boost_ramp_secs, stepped by
-- the same 150 ms chain. When it lands, stock numbers rule again -- keeping the slow-down
-- control held simply keeps decelerating the normal way.
local function beginRamp()
  if not boosting or ramping then return end
  ramping = true
  windOff()
  ctx.log.info("boost: easing off the wind...")
end

startWatch = function(tok)
  local rampStart
  local function pass()
    if tok ~= chainTok then return end
    if not (boosting or ramping) then return end
    local ship = liveShip()
    if not (ship and drivingNow()) then
      snapClear(ship)  -- left the wheel (or the world) -- no glide, just clean numbers
      return
    end
    local m = bmap()
    if ramping then
      rampStart = rampStart or os.clock()
      local secs = tonumber(cfg("boost_ramp_secs")) or 3.0
      local k = F.rampK(os.clock() - rampStart, secs)
      ctx.uehelp.set(ship, m.boostAdditionProp, boostAdd * k)
      if baseFov then
        setFov(ship, baseFov + (tonumber(cfg("boost_fov_add")) or 20.0) * k)
      end
      if k <= 0 then
        speedFx(ship, false)
        boosting, ramping = false, false
        baseFov, boostAdd = nil, 0
        ctx.log.info("boost: back to honest sailing")
        return
      end
    else
      -- steady boost: watch for the slow-down control (negative throttle = the exit signal)
      local okT, thr = ctx.uehelp.get(ship, m.throttleProp)
      if okT and tonumber(thr) and tonumber(thr) < -0.05 then
        beginRamp()
      end
    end
    deferOnly(150, function() onGameThread(pass) end)
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
