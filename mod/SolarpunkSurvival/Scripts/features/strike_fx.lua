-- Struck-player FX: 3 s stun + T-pose, 2 s solid-white screen with an electric buzz, then a slow
-- fade back. Runs CLIENT-LOCAL on the victim's machine only, with no custom replication needed:
-- it hooks the game's own CLIENT_ReduceHealth RPC, which UE delivers exactly to the owning client
-- of the damaged player (and executes locally when the host player is the victim). Every big hit
-- (>= fx_min_damage) is treated as lightning -- the only large single-hit source in this mod.
local F = {}
local ctx
local armed = false
local fxBusy = false   -- don't stack FX if a burst lands multiple bolts

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function after(seconds, fn)
  local guarded = ctx.log.guard("strikefx.delay", function() onGameThread(fn) end)
  local ms = math.floor((seconds or 0) * 1000)
  if ms <= 0 then guarded(); return end
  if not pcall(ExecuteWithDelay, ms, guarded) then guarded() end
end

local function localController()
  local pl = ctx.map.player
  return (pl and ctx.uehelp.findFirst(pl.controllerClass)) or ctx.uehelp.playerController()
end

-- Resolve a hook path off a live instance (RegisterHook rejects short Class:Fn paths).
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

--------------------------------------------------------------------- the FX
local WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }

local function stunAndTPose(pc)
  local cfg = ctx.config
  pcall(function() pc:SetIgnoreMoveInput(true) end)
  local pawn
  pcall(function() pawn = pc:K2_GetPawn() end)
  local mesh
  if pawn then pcall(function() mesh = pawn.Mesh end) end
  -- AnimationSingleNode (1) with no asset drops the skeletal mesh to its reference pose (T-pose).
  if mesh then pcall(function() mesh:SetAnimationMode(1) end) end

  after(cfg.get("stun_seconds"), function()
    pcall(function() pc:SetIgnoreMoveInput(false) end)
    -- restore the AnimBlueprint (0) so the character animates again
    local pawn2
    pcall(function() pawn2 = pc:K2_GetPawn() end)
    if pawn2 then pcall(function()
      local m = pawn2.Mesh
      if m then m:SetAnimationMode(0) end
    end) end
  end)
end

local function whiteout(pc)
  local cfg = ctx.config
  local pcm
  pcall(function() pcm = pc.PlayerCameraManager end)
  if not pcm then return end
  -- snap to solid white and hold...
  pcall(function() pcm:StartCameraFade(1.0, 1.0, 0.05, WHITE, false, true) end)
  after(cfg.get("whiteout_hold"), function()
    -- ...then slowly fade the world back in
    local pc2 = localController()
    local pcm2
    if pc2 then pcall(function() pcm2 = pc2.PlayerCameraManager end) end
    if pcm2 then pcall(function()
      pcm2:StartCameraFade(1.0, 0.0, cfg.get("whiteout_fade"), WHITE, false, false)
    end) end
  end)
end

local function buzz(pc)
  local w, fx = ctx.map.weather, ctx.map.fx
  if not (w and fx and fx.buzzSoundProp) then return end
  local mgr = ctx.uehelp.findFirst(w.managerClass)
  if not mgr then return end
  local ok, sound = ctx.uehelp.get(mgr, fx.buzzSoundProp)
  if not (ok and sound) then return end
  pcall(function()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if gs then
      gs:PlaySound2D(pc, sound, ctx.config.get("buzz_volume"), ctx.config.get("buzz_pitch"), 0.0)
    end
  end)
end

function F.playLocal()
  if fxBusy then return end
  fxBusy = true
  after(math.max(ctx.config.get("stun_seconds"), ctx.config.get("whiteout_hold")) + 0.5,
    function() fxBusy = false end)
  local pc = localController()
  if not pc then fxBusy = false; return end
  stunAndTPose(pc)
  whiteout(pc)
  buzz(pc)
  ctx.log.info("*** STRUCK BY LIGHTNING *** (stunned)")
end

--------------------------------------------------------------------- arming
function F.arm()
  if armed then return end
  local fx = ctx.map.fx
  if not (fx and fx.clientDamageRpcFn) then return end
  local pc = localController()
  if not pc then return end -- menu; re-armed when a controller appears
  local path = fullFuncPath(pc, fx.clientDamageRpcFn)
  if not path then return end
  local ok = pcall(RegisterHook, path, ctx.log.guard("strikefx.hook", function(_, ReduceBy)
    local dmg = ReduceBy
    pcall(function() dmg = ReduceBy:get() end)
    if type(dmg) ~= "number" then return end
    if dmg > 0 then ctx.log.info("hit taken: -" .. math.floor(dmg) .. " HP") end  -- damage fingerprinting
    if dmg < ctx.config.get("fx_min_damage") then return end
    onGameThread(function() F.playLocal() end)
  end))
  if ok then
    armed = true
    ctx.log.info("strike_fx: victim FX armed (" .. fx.clientDamageRpcFn .. ")")
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "strike_fx",
      { "player.controllerClass", "fx.clientDamageRpcFn" }) then
    return false
  end
  F.arm()
  -- Re-arm when a controller comes to life (fresh world load / joined a session).
  -- NotifyOnNewObject needs a FULL path -- register on the native parent, filter to our BP class.
  ctx.uehelp.onNewInstance("/Script/Engine.PlayerController", ctx.map.player.controllerClass,
    ctx.log.guard("strikefx.newpc", function()
      onGameThread(function() F.arm() end)
    end))
  ctx.bus.on("weather.changed", function() F.arm() end)  -- belt & braces: storm start re-tries
  ctx.services.strikeFx = function() F.playLocal() end   -- manual trigger for other features/tests
  return true
end

return F
