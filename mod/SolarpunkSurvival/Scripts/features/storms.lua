-- Deadly Storms + Lightning (Milestone 1).
--
-- Host-authoritative. A storm is started on demand (F6 keybind / `sps_storm`), which fires the
-- game's own InstantThunderstorm (full sky/rain/thunder visuals) and starts a self-chaining strike
-- scheduler. Each strike telegraphs near the local player, gives a dodge window, then lands: it
-- plays the game's thunder and deals real damage through the player's own health (70% max HP, so
-- two hits kill -> native death/respawn). F5 (or `sps_storm_off`) clears the weather and stops the
-- scheduler.
--
-- SAFETY: the scheduler is NOT a permanent LoopAsync (that native-crashes on level transitions).
-- It is a chain of one-shot ExecuteWithDelay callbacks that only continue while a storm is active,
-- keyed by `strikeToken` so stopping the storm instantly invalidates every pending strike. Every
-- UObject is re-fetched fresh (never cached) and isValid-checked before use.
local F = {}
local ctx

local stormActive = false
local severity    = 1.0
local strikeToken = 0       -- bumped on every start/stop; stale scheduled callbacks self-cancel
local preStormWind          -- wind intensity captured at storm start, restored on stop
local modBolts    = {}      -- FINAL FNames of bolt actors WE spawned (the native-bolt tap skips them)
local modBoltLocs = {}      -- { {loc,t} } of recent mod spawns -- the tap's proximity fallback
local selfDamage   = false  -- true while OUR damageController call is on the stack
local lastBoltSeen = -1e9   -- os.clock() when a bolt actor last appeared (ours or the game's)
local naturalStorm = false  -- a GAME-weather storm detected via its own bolts (no H press)

-- "Is lightning weather happening?" -- ours or the game's own.
local function stormy() return stormActive or naturalStorm end

-- Auto-strikes at the LOCAL player on a timer are OFF by default: with no visible bolt yet they read
-- as invisible random damage + confusing soft-deaths (an "aimbot"). H just sets the weather;
-- deliberate bolts come from the wand and the rites. Flip to true (or `sps_auto`) to re-enable
-- the hunting scheduler once the located-bolt VFX is solved.
local autoStrikePlayer = false

--------------------------------------------------------------------- helpers
local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function weatherMgr()
  return ctx.uehelp.findFirst(ctx.map.weather and ctx.map.weather.managerClass)
end

-- The LOCAL player's controller (has AddHealth / CurPlayerHealth / Respawn).
local function localController()
  local pl = ctx.map.player
  return (pl and ctx.uehelp.findFirst(pl.controllerClass)) or ctx.uehelp.playerController()
end

-- The LOCAL player's pawn, via the local controller (co-op has many pawns; this picks ours).
local function localPawn()
  local pc = localController()
  if pc then
    local ok, pawn = pcall(function() return pc:K2_GetPawn() end)
    if ok and ctx.uehelp.isValid(pawn) then return pawn end
  end
  return nil
end

local function locOf(actor)
  if not ctx.uehelp.isValid(actor) then return nil end
  local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
  if ok then return ctx.uehelp.vec(v) end
  return nil
end

-- The visible bolt. PlayThunder is only the audio/sky-flash cue; the real bolt (beam + point
-- light + scorch decal + explode VFX + impact sound) is the game's own BP_LightningPlayer actor,
-- deferred-spawned at the strike point exactly like the game's thunder loop does.
local function spawnBoltAt(loc)
  local w = ctx.map.weather
  if not (w and w.boltActorClass) then return end
  local cls = ctx.uehelp.classByName(w.boltActorClass, w.boltActorPath)
  local pc  = localController()
  lastBoltSeen = os.clock()  -- open the damage-guard window BEFORE BeginPlay can deal native damage
  local a   = cls and pc and ctx.uehelp.spawnActorAt(pc, cls, loc)
  if a then
    -- register by FINAL FName (spawnActorAt finished the spawn, so the name is settled) --
    -- the old location-grid id drifted between spawn and the tap's +delay re-read (the bolt
    -- repositions), so our own bolts read as NATURAL strikes (live 2026-07-22)
    local nm; pcall(function() nm = a:GetFName():ToString() end)
    if nm then modBolts[nm] = true end  -- consumed by the native-bolt tap's delayed check
    modBoltLocs[#modBoltLocs + 1] = { loc = loc, t = os.clock() }
  end
  return a
end

-- RegisterHook needs a UFunction's FULL object path (short "Class:Fn" is rejected). Resolve it live
-- off an instance of the class. e.g. -> "/Game/Code/Character/BP_MainPlayerController...:Reduce Health"
local function fullFuncPath(obj, fnName)
  local full
  pcall(function()
    obj:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n == fnName then pcall(function() full = fn:GetFullName() end) end
    end)
  end)
  if full then return (full:gsub("^%S+%s+", "")) end  -- drop the "Function " type prefix
  return nil
end

-- Run fn after `seconds`, but only if this storm generation is still current when it fires.
-- ExecuteWithDelay callbacks fire OFF the game thread; everything that touches UObjects (spawning
-- the bolt actor, PlayThunder, damage) must be marshalled back onto it.
local function afterIfActive(seconds, token, fn)
  local guarded = ctx.log.guard("storm.delay", function()
    onGameThread(function()
      if stormy() and token == strikeToken then fn() end
    end)
  end)
  local ms = math.floor((seconds or 0) * 1000)
  if ms <= 0 then guarded(); return end
  if not pcall(ExecuteWithDelay, ms, guarded) then guarded() end
end

--------------------------------------------------------------------- storm control
function F.startStorm()
  if not ctx.net.isHost() then ctx.log.warn("storm: only the host can start a storm"); return end
  local mgr = weatherMgr()
  if not mgr then ctx.log.warn("storm: weather manager (" ..
      tostring(ctx.map.weather and ctx.map.weather.managerClass) .. ") not found in world"); return end

  -- Remember the calm wind level so stopStorm can restore it (InstantThunderstorm pins it high).
  if not stormActive and ctx.map.weather.windIntensityProp then
    local okw, wv = ctx.uehelp.get(mgr, ctx.map.weather.windIntensityProp)
    if okw and type(wv) == "number" then preStormWind = wv end
  end

  ctx.uehelp.call(mgr, ctx.map.weather.startStormFn)  -- InstantThunderstorm()
  -- NOTE: do NOT call StartThunderLoop -- it's a persistent native loop that keeps cracking thunder
  -- and does NOT stop on InstantSunny (runaway). The weather visuals alone are enough for the storm.
  F.hookDamageGuard() -- (re)arm the lightning damage guard now that a controller definitely exists

  if not stormActive then
    stormActive = true
    strikeToken = strikeToken + 1
    ctx.bus.emit("weather.changed", { storm = true, severity = severity })
    ctx.bus.emit("storm.warning",  { lead = ctx.config.get("storm_warning_lead") })
    if autoStrikePlayer then
      ctx.log.info("*** STORM STARTED *** lightning is now hunting you — move to break line-of-sky!")
      F.scheduleNextStrike(strikeToken)
    else
      ctx.log.info("*** STORM STARTED *** the sky rages. (auto-strikes off: sps_auto to enable)")
    end
  else
    ctx.log.info("storm: refreshed")
  end
end

function F.stopStorm()
  local mgr = weatherMgr()
  if mgr and ctx.map.weather.stopStormFn then ctx.uehelp.call(mgr, ctx.map.weather.stopStormFn) end

  -- InstantSunny does NOT bring the storm wind back down (verified: stuck at ~5.0 forever).
  -- Restore the pre-storm intensity: the DEBUG setter alone doesn't move the realtime value, so
  -- also write the property directly, then refresh the wind audio so the howling stops now.
  local w = ctx.map.weather
  if mgr and w.windIntensityProp then
    local calm = preStormWind or 1.0
    if w.setWindIntensityFn then ctx.uehelp.call(mgr, w.setWindIntensityFn, calm) end
    ctx.uehelp.set(mgr, w.windIntensityProp, calm)
    if w.windAudioFn then ctx.uehelp.call(mgr, w.windAudioFn, calm) end
  end
  if stormActive then
    stormActive = false
    strikeToken = strikeToken + 1  -- invalidate every pending strike
    modBolts, modBoltLocs = {}, {} -- leak backstop (entries are normally consumed/expired)
    ctx.bus.emit("weather.changed", { storm = false, severity = 0 })
    ctx.log.info("storm stopped — skies clear")
  end
end

function F.toggleStorm()
  if stormActive then F.stopStorm() else F.startStorm() end
end

--------------------------------------------------------------------- scheduler
function F.scheduleNextStrike(token)
  if not stormActive or token ~= strikeToken then return end
  local cfg  = ctx.config
  local rate = math.max(0.05, severity * cfg.get("lightning_chance"))
  local interval = cfg.get("strike_interval") / rate
  afterIfActive(interval, token, function()
    F.fireBurst(token)
    F.scheduleNextStrike(token)
  end)
end

-- A strike is sometimes a burst of 2-3 bolts (the real killer: 2 hits = 140% HP = lethal).
function F.fireBurst(token)
  local cfg = ctx.config
  local n = 1
  if math.random() < cfg.get("burst_chance") then
    n = math.random(2, math.max(2, math.floor(cfg.get("burst_size"))))
  end
  for i = 1, n do
    afterIfActive((i - 1) * 0.35, token, function() F.fireBolt(token) end)
  end
end

function F.fireBolt(token)
  if not stormActive or token ~= strikeToken or not ctx.net.isHost() then return end
  local pawn = localPawn()
  local loc  = pawn and locOf(pawn)
  if not loc then return end

  -- Lightning rod: a bolt aimed within range of a Weather Station grounds at the rod instead.
  local rod
  if ctx.services.rodIntercept then
    local r, rl = ctx.services.rodIntercept(loc)
    if r and rl then rod, loc = r, rl end
  end

  local radius = ctx.config.get("strike_radius")
  local lead   = ctx.config.get("telegraph_lead")
  ctx.net.multicast("Multicast_Telegraph", { X = loc.X, Y = loc.Y, Z = loc.Z, radius = radius, lead = lead })
  ctx.bus.emit("lightning.telegraph", { location = loc, radius = radius, lead = lead })
  if rod then ctx.log.info("!! strike redirected to a lightning rod")
  else ctx.log.info(string.format("!! incoming strike in %.1fs -- MOVE (radius %.0f)", lead, radius)) end

  afterIfActive(lead, token, function() F.resolveStrike(loc, rod) end)
end

-- Stage 1 of a landing strike: the bolt actor + thunder cue. The bolt's own BeginPlay timeline
-- shows its ground telegraph FIRST and the big strike frame ~bolt_impact_delay later, so all
-- consequences (damage + world effects) are deferred to F.impact at that moment -- leaving the
-- radius while the ground crackles is a real dodge.
function F.resolveStrike(loc, rod)
  if not ctx.net.isHost() then return end
  spawnBoltAt(loc)
  local mgr = weatherMgr()
  if mgr and ctx.map.weather.thunderFn then ctx.uehelp.call(mgr, ctx.map.weather.thunderFn) end
  ctx.net.multicast("Multicast_Bolt", { X = loc.X, Y = loc.Y, Z = loc.Z })
  ctx.bus.emit("lightning.crackle", { location = loc, window = ctx.config.get("bolt_impact_delay") })
  afterIfActive(ctx.config.get("bolt_impact_delay"), strikeToken, function() F.impact(loc, rod) end)
end

-- Stage 2: the big strike frame. Damage whoever is STILL inside the radius now, and let the
-- world (batteries, trees, tech, rod grounding) react at the visible moment of impact.
function F.impact(loc, rod)
  if not ctx.net.isHost() then return end
  ctx.bus.emit("lightning.strike", { location = loc })
  if rod then ctx.bus.emit("strike.rod", { actor = rod, location = loc }) end
  local hits = F.damagePawnsAt(loc)
  local pawn = localPawn()
  local cur  = pawn and locOf(pawn)
  local r    = ctx.config.get("strike_radius")
  if hits == 0 and cur and ctx.uehelp.dist2(cur, loc) > r * r then
    ctx.log.info("...bolt landed -- MISS, you moved clear")
  else
    ctx.log.info("...bolt landed")
  end
end

-- Every player pawn inside the strike radius takes the hit -- in co-op the HOST damages each
-- victim through that victim's own controller; the game replicates health, death, loot and the
-- CLIENT_ReduceHealth RPC (which drives strike_fx on the victim's machine) natively.
function F.damagePawnsAt(loc)
  local pcls = ctx.map.pawn and ctx.map.pawn.class
  if not pcls then
    F.damageController(localController())  -- unmapped-build fallback: local player only
    return 1
  end
  local r2, hits = ctx.config.get("strike_radius") ^ 2, 0
  for _, pawn in ipairs(ctx.uehelp.findAll(pcls)) do
    local pl = locOf(pawn)
    if pl and ctx.uehelp.dist2(pl, loc) <= r2 then
      local pc
      pcall(function() pc = pawn.Controller end)
      if ctx.uehelp.isValid(pc) then
        hits = hits + 1
        ctx.bus.emit("strike.player", { actor = pawn, location = loc })
        F.damageController(pc)
      end
    end
  end
  return hits
end

-- Deal a lightning hit through the game's own damage path. "Reduce Health" natively handles the
-- kill: clamping, the Die flow, the death-loot drop at the death spot, and the respawn with reset
-- HP. Do NOT reimplement any of that here -- the old AddHealth(-dmg)+Respawn() shortcut teleported
-- players to spawn at <=0 HP without dropping their inventory.
function F.damageController(pc)
  local pl = ctx.map.player
  if not (pl and pc and (pl.reduceHealthFn or pl.addHealthFn)) then return end

  local maxhp = ctx.config.get("player_max_hp")
  if pl.maxHealthProp then
    local ok, mv = ctx.uehelp.get(pc, pl.maxHealthProp)
    if ok and type(mv) == "number" and mv > 0 then maxhp = mv end
  end
  local before
  if pl.curHealthProp then
    local ok, cv = ctx.uehelp.get(pc, pl.curHealthProp)
    if ok and type(cv) == "number" then before = cv end
  end
  local dmg = math.max(1, math.floor(maxhp * ctx.config.get("player_strike_pct")))

  selfDamage = true  -- lets our call through the lightning damage guard
  if pl.reduceHealthFn then
    ctx.uehelp.call(pc, pl.reduceHealthFn, dmg)
  else
    ctx.uehelp.call(pc, pl.addHealthFn, -dmg)  -- unmapped-build fallback (no native death handling)
  end
  selfDamage = false

  local hpNow
  if pl.curHealthProp then
    local ok, cv = ctx.uehelp.get(pc, pl.curHealthProp)
    if ok and type(cv) == "number" then hpNow = cv end
  end
  ctx.log.info(string.format("ZAP! -%d HP%s", dmg, hpNow and (" (now " .. math.floor(hpNow) .. ")") or ""))

  if before and before <= dmg then
    ctx.bus.emit("player.died", { actor = localPawn() })
    ctx.log.info("struck dead by lightning -- your gear drops where you fell")
  end
  -- Backstop: if the damage path somehow left us at <=0 without dying, trigger the native death.
  if hpNow ~= nil and hpNow <= 0 and pl.dieFn then
    ctx.uehelp.call(pc, pl.dieFn)
  end
end

-- Natural storms have no "stopped" signal, so a chained one-shot watchdog (timestamps only --
-- it touches NO UObjects) declares the storm over when no bolt has fallen for
-- natural_storm_timeout seconds.
function F.naturalWatchdog()
  pcall(ExecuteWithDelay, 60000, ctx.log.guard("storm.natural", function()
    if not naturalStorm then return end
    if os.clock() - lastBoltSeen > ctx.config.get("natural_storm_timeout") then
      naturalStorm = false
      if not stormActive then
        onGameThread(function()
          ctx.bus.emit("weather.changed", { storm = false, severity = 0 })
          ctx.log.info("the natural storm has passed")
        end)
      end
      return
    end
    F.naturalWatchdog()
  end))
end

--------------------------------------------------------------------- lightning damage guard
-- The game's own bolt logic hurts players far outside our kill radius (killed the user from ~10 m
-- during a ritual). Unified rule: NATIVE bolt damage is grounded to 0; instead every bolt (native
-- or ours) damages through our own radius-checked path at the impact frame.
--
-- REENTRANCY RULE (native "Abort" crash, live 2026-07-21): this hook fires INSIDE "Reduce Health",
-- which both the bolt's BeginPlay and our own Lua (damageController, inside FinishSpawningActor
-- call chains) invoke. A previous version scanned actors and read locations here and killed the
-- process. The callback must touch NO UObjects: plain Lua state + the one param write only.
local damageGuardHooked = false
function F.hookDamageGuard()
  if damageGuardHooked or not ctx.config.get("lightning_damage_guard") then return end
  local pl = ctx.map.player
  if not (pl and pl.controllerClass and pl.reduceHealthFn) then return end
  local pc = ctx.uehelp.findFirst(pl.controllerClass)
  if not pc then return end  -- menu; re-armed on storm start
  local path = fullFuncPath(pc, pl.reduceHealthFn)
  if not path then return end
  local ok = pcall(RegisterHook, path, function(_, ReduceBy)
    if selfDamage then return end  -- our own radius-checked damage: always passes
    if os.clock() - lastBoltSeen <= ctx.config.get("lightning_guard_window") then
      pcall(function() ReduceBy:set(0) end)
      ctx.log.info("lightning splash grounded -- only the strike core hurts")
    end
  end)
  damageGuardHooked = ok or false
  if damageGuardHooked then
    ctx.log.info("storms: lightning damage guard armed -- bolts only hurt inside strike_radius")
  end
end

-- Call a bolt down at an explicit world location (used by the ritual; scheduler uses fireBolt).
function F.strikeAt(loc, tag)
  if not ctx.net.isHost() or not stormy() then return end

  -- Lightning rod: ritual bolts within range of a Weather Station ground at the rod.
  local rod
  if ctx.services.rodIntercept then
    local r, rl = ctx.services.rodIntercept(loc)
    if r and rl then rod, loc, tag = r, rl, "rod" end
  end

  local radius = ctx.config.get("strike_radius")
  local lead   = ctx.config.get("telegraph_lead")
  local token  = strikeToken
  ctx.net.multicast("Multicast_Telegraph", { X = loc.X, Y = loc.Y, Z = loc.Z, radius = radius, lead = lead })
  ctx.bus.emit("lightning.telegraph", { location = loc, radius = radius, lead = lead })
  ctx.log.info(string.format("!! %s strike in %.1fs at (%.0f,%.0f)", tag or "targeted", lead, loc.X, loc.Y))
  afterIfActive(lead, token, function()
    spawnBoltAt(loc)
    local mgr = weatherMgr()
    if mgr then
      if ctx.map.weather.thunderLocXProp then ctx.uehelp.set(mgr, ctx.map.weather.thunderLocXProp, loc.X) end
      if ctx.map.weather.thunderLocYProp then ctx.uehelp.set(mgr, ctx.map.weather.thunderLocYProp, loc.Y) end
      if ctx.map.weather.thunderFn then ctx.uehelp.call(mgr, ctx.map.weather.thunderFn) end
    end
    ctx.net.multicast("Multicast_Bolt", { X = loc.X, Y = loc.Y, Z = loc.Z })
    ctx.bus.emit("lightning.crackle", { location = loc, window = ctx.config.get("bolt_impact_delay") })
    -- damage + world effects land with the big strike frame (see F.impact), not at spawn
    afterIfActive(ctx.config.get("bolt_impact_delay"), token, function() F.impact(loc, rod) end)
  end)
end

-- Cast a bolt at an explicit location in ANY weather (the electric wand). No storm gate and no
-- telegraph lead: the bolt's own ground-crackle phase IS the warning; consequences land at the
-- big strike frame. castBy tags the strike so the caster's own bolt cannot recharge their wand.
function F.castBolt(loc, casterId)
  if not ctx.net.isHost() or not loc then return false end
  spawnBoltAt(loc)
  local mgr = weatherMgr()
  if mgr and ctx.map.weather.thunderFn then ctx.uehelp.call(mgr, ctx.map.weather.thunderFn) end
  ctx.net.multicast("Multicast_Bolt", { X = loc.X, Y = loc.Y, Z = loc.Z })
  ctx.bus.emit("lightning.crackle",
    { location = loc, castBy = casterId, window = ctx.config.get("bolt_impact_delay") })
  local ms = math.floor(ctx.config.get("bolt_impact_delay") * 1000)
  pcall(ExecuteWithDelay, ms, ctx.log.guard("cast.impact", function()
    onGameThread(function()
      ctx.bus.emit("lightning.strike", { location = loc, castBy = casterId })
      F.damagePawnsAt(loc)
      ctx.log.info("...the cast bolt lands")
    end)
  end))
  return true
end

--------------------------------------------------------------------- native lightning tap
-- The game's OWN storms spawn the same BP_LightningPlayer_C bolt actor and apply their own player
-- damage (the "vanilla lightning sometimes hurts" mechanic). Tap every bolt the GAME spawns and run
-- our world effects (charge batteries, fell trees, break tech) at its impact frame too -- but no
-- extra player damage, or native strikes would hit twice. Our own bolts are skipped via modBolts.
function F.onBoltSpawned(bolt)
  -- open the damage-guard window on EVERY machine (clients see replicated native bolts too)
  lastBoltSeen = os.clock()
  if not ctx.net.isHost() or not ctx.config.get("native_strike_effects") then return end
  -- The crackle window OPENS at spawn: after a beat (our own spawnBoltAt registers the final
  -- name synchronously, so by now modBolts already holds it for our bolts), announce a genuinely
  -- NATIVE bolt's ground-charge so the wand's run-through recharge can watch this bolt too.
  -- READ-ONLY on modBolts/modBoltLocs -- the impact check below still consumes the entry.
  pcall(ExecuteWithDelay, 200, ctx.log.guard("bolt.crackle", function()
    onGameThread(function()
      local nm
      pcall(function() if ctx.uehelp.isValid(bolt) then nm = bolt:GetFName():ToString() end end)
      if nm and modBolts[nm] then return end  -- ours: the spawn site already emitted the crackle
      local loc = locOf(bolt)
      if not loc then return end
      for i = #modBoltLocs, 1, -1 do
        local e = modBoltLocs[i]
        if os.clock() - e.t <= 6
            and (loc.X - e.loc.X) ^ 2 + (loc.Y - e.loc.Y) ^ 2 <= 1000 * 1000 then
          return  -- proximity says ours (a second actor at the same strike)
        end
      end
      ctx.bus.emit("lightning.crackle", { location = loc, native = true,
        window = math.max(0.5, ctx.config.get("bolt_impact_delay") - 0.2) })
    end)
  end))
  local ms = math.floor(ctx.config.get("bolt_impact_delay") * 1000)
  pcall(ExecuteWithDelay, ms, ctx.log.guard("bolt.native", function()
    onGameThread(function()
      -- name must be read HERE: deferred-spawned actors only get their final name after
      -- FinishSpawningActor, so a name captured at notify time never matches modBolts
      local nm
      pcall(function() if ctx.uehelp.isValid(bolt) then nm = bolt:GetFName():ToString() end end)
      if nm and modBolts[nm] then modBolts[nm] = nil; return end  -- ours: F.impact handles it
      local loc = locOf(bolt)
      if not loc then return end
      -- proximity fallback (live 2026-07-22): a bolt near a recent mod spawn is OURS even if
      -- the name registry missed it (a second actor at the same strike). Misreading our own
      -- cast as a natural bolt armed a phantom "natural storm", dealt double damage, and
      -- opened the crash window on the doubled impact chain.
      for i = #modBoltLocs, 1, -1 do
        local e = modBoltLocs[i]
        if os.clock() - e.t > 6 then
          table.remove(modBoltLocs, i)
        elseif (loc.X - e.loc.X) ^ 2 + (loc.Y - e.loc.Y) ^ 2 <= 1000 * 1000 then
          return  -- ours (entry kept: one spawn can echo more than one actor; time expires it)
        end
      end
      -- a bolt we did not spawn, outside our storm = the GAME's weather is storming. Arm the
      -- machinery (ritual chain) exactly as if H had been pressed.
      if not stormy() then
        naturalStorm = true
        ctx.bus.emit("weather.changed", { storm = true, natural = true })
        ctx.log.info("*** a natural storm rages -- the dark arts are listening ***")
        F.naturalWatchdog()
      end
      ctx.bus.emit("lightning.strike", { location = loc, native = true })
      -- the guard grounded this bolt's own wide-range damage; deal ours (radius-checked) instead
      F.damagePawnsAt(loc)
      ctx.log.info(string.format("native bolt tapped at (%.0f,%.0f) -- world feels the strike", loc.X, loc.Y))
    end)
  end))
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "storms",
      { "weather.managerClass", "weather.startStormFn" }) then
    return false
  end

  -- H toggles the weather normal <-> stormy.
  pcall(function()
    if RegisterKeyBind and Key and Key.H then
      RegisterKeyBind(Key.H, ctx.log.guard("storm.key.toggle",
        function() onGameThread(function() F.toggleStorm() end) end))
    end
  end)
  pcall(function()
    RegisterConsoleCommandHandler("sps_storm",     function() onGameThread(function() F.toggleStorm() end); return true end)
    RegisterConsoleCommandHandler("sps_storm_off", function() onGameThread(function() F.stopStorm() end);  return true end)
    RegisterConsoleCommandHandler("sps_auto", function()
      autoStrikePlayer = not autoStrikePlayer
      ctx.log.info("storm auto-strikes " .. (autoStrikePlayer and "ON (lightning hunts you)" or "OFF"))
      if autoStrikePlayer and stormActive then F.scheduleNextStrike(strikeToken) end
      return true
    end)
  end)

  F.hookDamageGuard()

  -- Tap every bolt actor the game (or we) spawn, so NATIVE storm lightning also affects the world.
  if ctx.map.weather and ctx.map.weather.boltActorClass then
    ctx.uehelp.onNewInstance("/Script/Engine.Actor", ctx.map.weather.boltActorClass,
      ctx.log.guard("bolt.spawned", function(b) F.onBoltSpawned(b) end))
  end

  -- Expose for the remote dev channel / other features.
  ctx.services.startStorm = F.startStorm
  ctx.services.stopStorm  = F.stopStorm
  ctx.services.strikeAt   = F.strikeAt
  ctx.services.castBolt   = F.castBolt

  ctx.log.info("storms: ready -- H toggles storm on/off.")
  return true
end

return F
