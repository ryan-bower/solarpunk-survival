-- The Unlit: evil animals that ride the storm (the third rung of the codex's ladder).
--
-- Sacrifice a species to the pentagram once and the storm keeps its shape: from then on, every
-- storm spawns hostile "Unlit" copies of that species (chicken after the hydration rite, sheep
-- after the electrick rite) on open ground within evil_spawn_radius of the players -- up to
-- evil_cap_per_player each. They prowl at 2x an animal's own speed; inside evil_lockon_radius
-- they charge a player at 4x, crying their own calls pitched several steps down; inside
-- evil_bite_radius they bite everyone there every evil_bite_interval seconds (bird 10, lamb 20).
-- Tools put them down (base 20 / Metal 30 / Diamond 40; bird 30 HP, lamb 50), a bolt of
-- lightning puts them down instantly, and when the storm clears they all lie down (the Sleep
-- montage -- the same pose the living take in the rain) and are gone.
--
-- ARCHITECTURE (docs/RE-ANIMALS.md has the full offline RE):
--   * HOST simulation: spawned game-class animals replicate natively (movement, destroy). Their
--     behavior tree is stopped for good (BrainComponent:StopLogic) so BTD_ModifyWalkSpeed stops
--     restoring MaxWalkSpeed and BTTask_MoveTo stops fighting us; the host then drives the
--     DetourCrowd AIController directly (MoveToActor / MoveToLocation -- native pathfinding).
--   * MP beacon: the animal's `Name` is a REPLICATED StrProperty. The host writes
--     "Unlit <flavor>" (+ one apostrophe per landed tool hit, mod 4) or "Fallen <flavor>" when
--     dying; EVERY machine's FX watcher parses it and applies client-local dress: the corrupted
--     body material, the pitched-down voice, chatter cries, the red hit-blink on a tally change,
--     and silence for the fallen. No custom replication channel needed.
--   * Animal HP lives HERE, not in core/health.lua: identity.idOf keys moving actors by rounded
--     location, which drifts as they walk (and would leak transient records into the save).
--   * Damage to players runs through storms' services.damagePlayerBy -- the selfDamage-flagged
--     "Reduce Health" path -- or the lightning damage guard would zero every bite for 2.5 s
--     after each bolt (i.e. most of the storm).
--   * House safety rules apply throughout: token-guarded one-shot delay chains (never raw
--     timers), onGameThread + isValid re-checks at every fire, log.guard on every callback, and
--     NO component creation/attachment anywhere (the proven native-crash family).
local F = {}
local ctx

--------------------------------------------------------------------- pure helpers (unit-tested)
-- Parse a replicated animal name against the Unlit markers. Returns "alive"|"dead"|nil plus the
-- landed-hit tally (trailing apostrophes -- ASCII on purpose: FString round-trips it untouched).
function F.parseEvilName(name, alivePrefix, deadPrefix)
  if type(name) ~= "string" then return nil, 0 end
  if deadPrefix and #deadPrefix > 0 and name:sub(1, #deadPrefix) == deadPrefix then
    return "dead", 0
  end
  if alivePrefix and #alivePrefix > 0 and name:sub(1, #alivePrefix) == alivePrefix then
    local _, hits = name:gsub("'", "")
    return "alive", hits
  end
  return nil, 0
end

-- Tool damage from a held item-actor class name (BP_PickaxeMetal_Item_C / BP_Hoe_Diamond_Item_C
-- -- row->class is not 1:1, so match normalized substrings). nil = not a tool, no damage.
function F.toolDamageForClass(cn, dmg)
  if type(cn) ~= "string" then return nil end
  local n = cn:lower():gsub("_", "")
  if not (n:find("pickaxe", 1, true) or n:find("axe", 1, true) or n:find("hoe", 1, true)) then
    return nil
  end
  if n:find("diamond", 1, true) then return dmg.diamond end
  if n:find("metal", 1, true) then return dmg.metal end
  return dmg.base  -- base rows + the cosmetic Kickstarter variants
end

--------------------------------------------------------------------- state
local SPECIES = {
  chicken = { classKey = "chickenClass", riteKey = "hydration", flag = "evil_chicken",
              hpKey = "evil_hp_chicken", biteKey = "evil_bite_chicken",
              scaleKey = "evil_scale_chicken", atkSpeedKey = "evil_atkspeed_chicken",
              soundsKey = "soundsChicken", displayName = "Chicken" },
  sheep   = { classKey = "sheepClass", riteKey = "electrick", flag = "evil_sheep",
              hpKey = "evil_hp_sheep", biteKey = "evil_bite_sheep", rams = true,
              scaleKey = "evil_scale_sheep", atkSpeedKey = "evil_atkspeed_sheep",
              soundsKey = "soundsSheep", displayName = "Sheep" },
}

local unlocked   = { chicken = false, sheep = false }
local evils      = {}      -- key -> { key, actor, species, hp, hits, mode, baseSpeed, flavor,
                           --          inited, initTries, lastBite, nextHop, dying }
local nextKey    = 0
local stormOn    = false
local token      = 0       -- storm generation; bumped on every start/stop
local swingsHooked = false
local lastSwing  = {}      -- per-pawn-id swing debounce (input events fire multiple phases)
local straysSwept = false  -- one stray-cleanup per session, at the first storm

-- FX watcher (runs on EVERY machine, host included -- all its effects are client-local)
local fxToken     = 0
local fxLive      = false
local lastBoltSeen = -1e9  -- clients have no weather.changed; replicated bolt actors are their signal
local dressed     = {}     -- actor full name -> { origMat, mat, pitch, hits, dead, lastChatter, seen }

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function after(seconds, fn)  -- unguarded-by-token delay (death lingers must outlive the storm)
  local guarded = ctx.log.guard("evil.delay", function() onGameThread(fn) end)
  local ms = math.floor((seconds or 0) * 1000)
  if ms <= 0 then guarded(); return end
  if not pcall(ExecuteWithDelay, ms, guarded) then guarded() end
end

local function afterIfStorm(seconds, tok, fn)
  after(seconds, function()
    if stormOn and tok == token then fn() end
  end)
end

local function anyUnlocked()
  for k in pairs(SPECIES) do if unlocked[k] then return true end end
  return false
end

-- Seconds between one Unlit's attacks. Sheep ram: a long fixed recovery (they stand after each
-- ram); others use the base interval scaled by their atk-speed multiplier. Host bite cadence and
-- the client attack-cry cadence both read this so the sound lands with the bite.
local function attackGap(sp)
  if sp.rams then return ctx.config.get("evil_ram_recover") end
  return ctx.config.get("evil_bite_interval") / math.max(0.05, ctx.config.get(sp.atkSpeedKey))
end

--------------------------------------------------------------------- name beacon
local function nameOf(a)
  local ok, v = ctx.uehelp.get(a, ctx.map.animal.nameProp)
  if not ok or v == nil then return nil end
  if type(v) == "string" then return v end
  local s
  pcall(function() s = v:ToString() end)
  return s
end

local function setName(a, s)
  return ctx.uehelp.set(a, ctx.map.animal.nameProp, s)
end

local function parseEvil(name)
  return F.parseEvilName(name, ctx.config.get("evil_prefix_alive"), ctx.config.get("evil_prefix_dead"))
end

-- The tally is the blink channel: every landed tool hit changes the replicated name, every
-- watcher sees the change. Mod 4 keeps the plank readable.
local function aliveName(rec)
  return ctx.config.get("evil_prefix_alive") .. rec.flavor .. string.rep("'", (rec.hits or 0) % 4)
end

--------------------------------------------------------------------- host: lookups
local function speciesClass(spKey)
  return ctx.map.animal and ctx.map.animal[SPECIES[spKey].classKey]
end

local function playerPawns()
  local out = {}
  for _, p in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    if ctx.uehelp.isValid(p) then out[#out + 1] = p end
  end
  return out
end

-- A stable per-player key for the swing debounce. identity.idOf keys a MOVING pawn by rounded
-- world location, so it changes every step and leaks a fresh table entry per position swung from;
-- UniquePlayerID does not move (the wand keys its owner map on the same prop).
local function playerIdOf(pawn)
  local prop = ctx.map.pawn and ctx.map.pawn.playerIdProp
  if prop then
    local ok, v = ctx.uehelp.get(pawn, prop)
    if ok and v ~= nil and tostring(v) ~= "" then return "pid:" .. tostring(v) end
  end
  return "local"  -- single-player / unmapped: one shared debounce is correct enough
end

local function countAlive()
  local n = 0
  for _, rec in pairs(evils) do if not rec.dying then n = n + 1 end end
  return n
end

-- THE authoritative "is this one of ours?" check: object identity against the host's tracking
-- table, NOT the replicated Name (which a player can reproduce by renaming a pet via AnimalTag).
-- Host-only decisions -- ritual exclusion, and could-be more -- must use this, never the beacon.
local function isTrackedEvil(a)
  if not ctx.uehelp.isValid(a) then return false end
  for _, rec in pairs(evils) do
    if rec.actor == a or ctx.uehelp.sameObject(rec.actor, a) then return true end
  end
  return false
end

-- Daylight is lethal to the Unlit. Read the day/night manager's IsDay flag (BP_DayNightCycle_C);
-- fail-safe -- if it can't be read (unmapped/renamed on this build) it returns false, so nothing is
-- ever wrongly culled. The manager is cached and re-fetched only when the handle goes invalid.
local dayMgr
local function isDaytime()
  local w = ctx.map.weather
  if not (w and w.isDayProp) then return false end
  if not ctx.uehelp.isValid(dayMgr) then dayMgr = ctx.uehelp.findFirst(w.managerClass) end
  if not ctx.uehelp.isValid(dayMgr) then return false end
  local ok, v = ctx.uehelp.get(dayMgr, w.isDayProp)
  if ok and type(v) == "boolean" then return v end
  if w.isNightProp then
    local ok2, n = ctx.uehelp.get(dayMgr, w.isNightProp)
    if ok2 and type(n) == "boolean" then return not n end
  end
  return false
end

--------------------------------------------------------------------- host: spawning
-- Active light sources push back the dark: a lit torch/candle or a powered lamp/wireless light
-- forbids a spawn within its radius (evil_light_block_big 20 m / _small 10 m). Only lights that are
-- actually ON count -- each class's own flag is read (Burning for fire, IsOn for electric).
local function litLights()
  local out = {}
  local specs = ctx.map.animal and ctx.map.animal.spawnLights
  if not specs then return out end
  for _, s in ipairs(specs) do
    local r = ctx.config.get(s.radiusKey)
    if r and r > 0 then
      local r2 = r * r
      for _, a in ipairs(ctx.uehelp.findAll(s.cls)) do
        if ctx.uehelp.isValid(a) then
          local on = true
          if s.prop then local ok, v = ctx.uehelp.get(a, s.prop); on = ok and v == true end
          if on then
            local loc = ctx.identity.locationOf(a)
            if loc then out[#out + 1] = { loc = loc, r2 = r2 } end
          end
        end
      end
    end
  end
  return out
end

local function nearLitLight(loc, lights)
  for _, l in ipairs(lights) do
    local dx, dy = loc.X - l.loc.X, loc.Y - l.loc.Y
    if dx * dx + dy * dy <= l.r2 then return true end
  end
  return false
end

-- Open-ground check: a down-trace from above the ring point. The hit's owning actor classifies
-- the surface -- player-built pieces and water are rejected; the landscape itself usually
-- resolves to no BP class at all, which is exactly the "bare earth" we want.
local REJECT_HINTS = { "Water", "Buildable", "Placeable", "Preview", "Foundation", "Build",
                       "Floor", "Roof", "Wall", "Fence", "Bridge" }

-- Resolve the OWNING actor's class from an FHitResult, trying every field UE has stored it in
-- across versions -- FHitResult.Actor (UE4/early-5), HitObjectHandle (later 5), then the hit
-- component's owner. Reading only Component:GetOwner() proved fragile (it came back nil for a
-- greenhouse roof, so the built piece was mistaken for bare ground and an Unlit spawned on top).
local function hitOwnerClass(hit)
  local cls
  local function take(o) if ctx.uehelp.isValid(o) then local n = ctx.uehelp.className(o); if n and n ~= "" then cls = n end end end
  pcall(function() take(hit.Actor) end)
  if cls then return cls end
  pcall(function()
    local h = hit.HitObjectHandle
    if h then
      local act; pcall(function() act = h:GetManagingActor() end)
      if not ctx.uehelp.isValid(act) then pcall(function() act = h.Actor end) end
      take(act)
    end
  end)
  if cls then return cls end
  pcall(function()
    local comp = hit.Component
    if comp then local owner; pcall(function() owner = comp:GetOwner() end); take(owner) end
  end)
  return cls
end

local function groundPoint(pc, x, y, zref)
  local ksl = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
  if not ksl then return nil end
  local hitLoc, hitCls
  pcall(function()
    local hit = {}
    local red, green = { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }
    local a = { X = x, Y = y, Z = zref + 3000 }
    local b = { X = x, Y = y, Z = zref - 6000 }
    if ksl:LineTraceSingle(pc, a, b, 0, false, {}, 0, hit, true, red, green, 0.0) then
      local v = ctx.uehelp.vec(hit.ImpactPoint)
      if v then hitLoc = v end
      hitCls = hitOwnerClass(hit)
    end
  end)
  if not hitLoc then return nil end
  if hitCls then
    -- Every player buildable / placeable / deco / prop is a BP_ actor; the landscape and terrain
    -- resolve to engine classes (Landscape, etc.). So reject ANY BP_-owned surface outright -- that
    -- is the robust catch for the greenhouse (BP_Fence_Greenhouse_Buildable_C) and its kin.
    if hitCls:sub(1, 3) == "BP_" then return nil end
    for _, h in ipairs(REJECT_HINTS) do
      if hitCls:find(h, 1, true) then return nil end
    end
  end
  return hitLoc
end

local function pickSpawnSpot(pc, pawns)
  if #pawns == 0 then return nil end
  local anchor = pawns[math.random(#pawns)]
  local al = ctx.identity.locationOf(anchor)
  if not al then return nil end
  local lo, hi = ctx.config.get("evil_spawn_min"), ctx.config.get("evil_spawn_radius")
  local r = lo + math.random() * math.max(0, hi - lo)
  local ang = math.random() * 2 * math.pi
  return groundPoint(pc, al.X + math.cos(ang) * r, al.Y + math.sin(ang) * r, al.Z)
end

local function trySpawnOne(pc, pawns)
  pawns = pawns or playerPawns()
  local pool = {}
  for k in pairs(SPECIES) do if unlocked[k] then pool[#pool + 1] = k end end
  if #pool == 0 then return false end
  local spKey = pool[math.random(#pool)]
  local clsName = speciesClass(spKey)
  local paths = ctx.map.animal.classPaths or {}
  local cls = ctx.uehelp.classByName(clsName, paths[clsName])
  if not cls then ctx.log.debug("evil: class " .. tostring(clsName) .. " unresolved"); return false end
  -- Retry the ground pick: one bad spot (water / built / off-map / trace miss) must NOT burn the
  -- whole spawn interval -- that made spawns feel sparse. Try several ring points before giving up.
  local lights = litLights()
  local loc
  for _ = 1, math.max(1, ctx.config.get("evil_spawn_tries")) do
    local cand = pickSpawnSpot(pc, pawns)
    if cand and not nearLitLight(cand, lights) then loc = cand; break end
  end
  if not loc then return false end
  local a = ctx.uehelp.spawnActorAt(pc, cls, { X = loc.X, Y = loc.Y, Z = loc.Z + 30 })
  if not a then return false end
  nextKey = nextKey + 1
  local sp = SPECIES[spKey]
  local rec = {
    key = nextKey, actor = a, species = spKey,
    hp = ctx.config.get(sp.hpKey), hits = 0, mode = "wander",
    flavor = sp.displayName,   -- "Vengeful Chicken" / "Banished Sheep" on the nameplate
    inited = false, initTries = 0, lastBite = 0, nextHop = 0,
  }
  evils[rec.key] = rec
  setName(a, aliveName(rec))  -- the beacon goes up first: even pre-AI, every machine can dress it
  ctx.log.info(string.format("an %s slips out of the rain (%d/%d abroad)",
    aliveName(rec), countAlive(), ctx.config.get("evil_cap_per_player") * math.max(1, #pawns)))
  return true
end

-- AI possession happens a beat after spawn; the brain tick keeps trying until the controller
-- exists, then performs the one-time takeover: stop the behavior tree, learn the animal's own
-- MaxWalkSpeed as the multiplier baseline.
local function initEvil(rec)
  local m = ctx.map.animal
  local a = rec.actor
  local aic; pcall(function() aic = a.Controller end)
  if not ctx.uehelp.isValid(aic) then
    rec.initTries = rec.initTries + 1
    if rec.initTries == 6 then
      -- auto-possess never came: ask the pawn for its own default controller (native APawn fn)
      pcall(function() a:SpawnDefaultController() end)
    elseif rec.initTries > 12 then  -- ~8 s with no controller: a dud spawn; remove it
      pcall(function() a:K2_DestroyActor() end)
      evils[rec.key] = nil
    end
    return false
  end
  -- Stop the behavior tree for GOOD, or the host and the tree fight forever: BTD_ModifyWalkSpeed
  -- restores MaxWalkSpeed every branch (undoing our 2x/4x) and BTTask_MoveTo overrides our move
  -- orders. Try the mapped fn then the documented fallbacks (the exact name is build-dependent --
  -- RE-ANIMALS.md verify item 2). Do NOT latch inited unless we actually stopped it, so a build
  -- where the name differs keeps retrying instead of silently prowling at 1x with no lock-on.
  local brain; pcall(function() brain = aic[m.brainProp] end)
  if not ctx.uehelp.isValid(brain) then
    rec.initTries = rec.initTries + 1
    if rec.initTries > 12 then rec.inited = true end  -- give up cleanly rather than retry forever
    return rec.inited
  end
  local stopped = false
  for _, fn in ipairs(m.stopLogicFns or { m.stopLogicFn }) do
    if fn and ctx.uehelp.call(brain, fn, "unlit") then stopped = true; break end
  end
  if not stopped then
    rec.initTries = rec.initTries + 1
    if rec.initTries <= 12 then return false end       -- retry: the stop fn may register late
    ctx.log.warn("evil: could not stop the Unlit's behavior tree -- check animal.stopLogicFns")
  end
  local cm; pcall(function() cm = a[m.moveCompProp] end)
  if cm then
    local ok, v = ctx.uehelp.get(cm, m.maxWalkSpeedProp)
    if ok and type(v) == "number" and v > 0 then rec.baseSpeed = v end
  end
  rec.inited = true
  return true
end

--------------------------------------------------------------------- host: the brain
local function setSpeed(rec, mult)
  if not rec.baseSpeed then return end
  local cm; pcall(function() cm = rec.actor[ctx.map.animal.moveCompProp] end)
  if cm then ctx.uehelp.set(cm, ctx.map.animal.maxWalkSpeedProp, rec.baseSpeed * mult) end
end

-- Hold the animal's rendered pose. After StopLogic the Montage blackboard keeps its last value --
-- for an animal we hijacked mid-rest that is Sleep (the lie-down), which is why a stalled/stuck
-- Unlit "lay down". Pin it to Walk (moving) or Stand (frozen) so it only ever lies down on death
-- (killEvil sets Sleep). Latched: one write per change, no per-tick montage restart/stutter.
local function setMontage(rec, value)
  if not value or rec.montage == value then return end
  if ctx.uehelp.call(rec.actor, ctx.map.animal.montageSetFn, value) then rec.montage = value end
end

-- Move orders: full K2 arity first; a wrong arity is a SAFE Lua error (UE4SS validates the
-- param count before touching native), so the single-arg fallback costs nothing.
local function orderMoveToActor(aic, target)
  local fn = ctx.map.animal.moveToActorFn
  if ctx.uehelp.call(aic, fn, target, 60.0, true, true, false, nil, true) then return true end
  return ctx.uehelp.call(aic, fn, target)
end

local function orderMoveToLocation(aic, loc)
  local fn = ctx.map.animal.moveToLocationFn
  if ctx.uehelp.call(aic, fn, loc, 100.0, true, true, true, false, nil, true) then return true end
  return ctx.uehelp.call(aic, fn, loc)
end

-- Fell one Unlit: freeze it, lay it down (the Sleep montage -- the storm pose), flip the beacon
-- to Fallen, and take the body after evil_death_linger. The linger timer is deliberately NOT
-- storm-token-gated: storm-end death must complete even though the token just changed.
local function killEvil(rec, why)
  if rec.dying then return end
  rec.dying = true
  local a = rec.actor
  local m = ctx.map.animal
  if ctx.uehelp.isValid(a) then
    local aic; pcall(function() aic = a.Controller end)
    if ctx.uehelp.isValid(aic) and m.stopMovementFn then ctx.uehelp.call(aic, m.stopMovementFn) end
    if m.montageSetFn and m.montageSleepValue then
      ctx.uehelp.call(a, m.montageSetFn, m.montageSleepValue)
    end
    setName(a, ctx.config.get("evil_prefix_dead") .. rec.flavor)
  end
  ctx.log.info(string.format("the Unlit %s falls (%s)", rec.flavor, why or "slain"))
  after(ctx.config.get("evil_death_linger"), function()
    if ctx.uehelp.isValid(rec.actor) then pcall(function() rec.actor:K2_DestroyActor() end) end
    evils[rec.key] = nil
  end)
end

local function brainTick()
  local cfg = ctx.config
  local lock2 = cfg.get("evil_lockon_radius") ^ 2
  local bite2 = cfg.get("evil_bite_radius") ^ 2
  local pawns = playerPawns()
  local now = os.clock()
  if isDaytime() then  -- daylight is lethal: send every Unlit into its death throes at once
    for _, rec in pairs(evils) do killEvil(rec, "the daylight burns it away") end
    return
  end
  for _, rec in pairs(evils) do
    local a = rec.actor
    if not ctx.uehelp.isValid(a) then
      evils[rec.key] = nil
    elseif not rec.dying then
      if not rec.inited then
        initEvil(rec)
      else
        local al = ctx.identity.locationOf(a)
        if al then
          -- nearest player decides the mode
          local best, bestD2
          for _, p in ipairs(pawns) do
            local pl = ctx.identity.locationOf(p)
            local d2 = pl and ctx.uehelp.dist2(al, pl) or math.huge
            if d2 < (bestD2 or math.huge) then best, bestD2 = p, d2 end
          end
          local aic; pcall(function() aic = a.Controller end)
          if now < (rec.stunUntil or 0) then
            -- staggered by a tool hit, or a sheep recovering from a ram: stand in place, halt once
            if not rec.stunned then
              rec.stunned = true
              if ctx.uehelp.isValid(aic) and ctx.map.animal.stopMovementFn then
                ctx.uehelp.call(aic, ctx.map.animal.stopMovementFn)
              end
            end
            setMontage(rec, ctx.map.animal.montageStandValue)  -- frozen, but upright -- never asleep
          elseif best and bestD2 <= lock2 then
            rec.stunned = false
            if rec.mode ~= "chase" then
              rec.mode = "chase"
              ctx.log.debug("evil: " .. rec.flavor .. " locks on")
            end
            setSpeed(rec, cfg.get("evil_chase_mult"))
            setMontage(rec, ctx.map.animal.montageWalkValue)
            if ctx.uehelp.isValid(aic) then orderMoveToActor(aic, best) end
          else
            rec.stunned = false
            rec.mode = "wander"
            setSpeed(rec, cfg.get("evil_wander_mult"))
            setMontage(rec, ctx.map.animal.montageWalkValue)
            if now >= (rec.nextHop or 0) and ctx.uehelp.isValid(aic) then
              local hop = cfg.get("evil_wander_hop")
              local ang = math.random() * 2 * math.pi
              orderMoveToLocation(aic, { X = al.X + math.cos(ang) * hop,
                                         Y = al.Y + math.sin(ang) * hop, Z = al.Z })
              rec.nextHop = now + 2.0 + math.random() * 3.0
            end
          end
          -- the bite: everyone inside the circle, on the animal's own cooldown (attackGap: sheep use
          -- a long ram-recovery, others the atk-speed-scaled interval). A sheep RAMS -- it flings
          -- each bitten player up and back (an auto-jump), then stands frozen for the recovery.
          local sp = SPECIES[rec.species]
          if now < (rec.stunUntil or 0) then
            -- mid-recovery: no bite
          elseif now - (rec.lastBite or 0) >= attackGap(sp) then
            local bit = false
            for _, p in ipairs(pawns) do
              local pl = ctx.identity.locationOf(p)
              if pl and ctx.uehelp.dist2(al, pl) <= bite2 then
                local pc; pcall(function() pc = p.Controller end)
                if ctx.uehelp.isValid(pc) and ctx.services.damagePlayerBy then
                  ctx.services.damagePlayerBy(pc, cfg.get(sp.biteKey),
                    "the " .. aliveName(rec) .. " savages you")
                  bit = true
                  if sp.rams then  -- ram: fling the player up and back
                    local dx, dy = pl.X - al.X, pl.Y - al.Y
                    local len = math.sqrt(dx * dx + dy * dy)
                    local back = cfg.get("evil_ram_launch_back")
                    local vx = (len > 1 and dx / len or 0) * back
                    local vy = (len > 1 and dy / len or 0) * back
                    pcall(function()
                      p:LaunchCharacter({ X = vx, Y = vy, Z = cfg.get("evil_ram_launch_z") }, false, true)
                    end)
                  end
                end
              end
            end
            if bit then
              rec.lastBite = now
              if sp.rams then rec.stunUntil = now + cfg.get("evil_ram_recover") end  -- stand after ramming
            end
          end
        end
      end
    end
  end
end

local function brainChain(tok)
  if not stormOn or tok ~= token then return end
  afterIfStorm(ctx.config.get("evil_brain_interval"), tok, function()
    if ctx.net.isHost() then brainTick() end
    brainChain(tok)
  end)
end

local function spawnChain(tok)
  if not stormOn or tok ~= token then return end
  afterIfStorm(ctx.config.get("evil_spawn_interval"), tok, function()
    if ctx.net.isHost() and ctx.config.get("evil_animals") and anyUnlocked() and not isDaytime() then
      local pawns = playerPawns()  -- scanned ONCE per attempt; threaded into the cap + spawn spot
      local cap = ctx.config.get("evil_cap_per_player") * math.max(1, #pawns)
      local pc = ctx.uehelp.localController(ctx.map.player.controllerClass)
      if pc then
        -- a small burst per tick (each with its own ground-pick retries) so the world fills at a
        -- felt rate instead of at most one per interval; stop early at the cap or on a dry tick.
        for _ = 1, math.max(1, ctx.config.get("evil_spawn_per_tick")) do
          if countAlive() >= cap then break end
          if not trySpawnOne(pc, pawns) then break end
        end
      end
    end
    spawnChain(tok)
  end)
end

-- A previous session's Unlit that leaked into the game save (or survived a crash) wakes up as a
-- plain animal wearing our marker name. Sweeping them is DESTRUCTIVE and keyed on the spoofable
-- Name, so it is OFF by default (a player who renames a pet "Unlit Clucky" via AnimalTag must
-- never have it destroyed) and, when enabled, skips owned animals (a tamed/named pet reports
-- IsOwned). Untracked + our-marker + not-owned is the only thing it will remove.
local function isOwnedAnimal(a)
  local fn = ctx.map.animal.isOwnedFn
  if not fn then return false end
  local ok, res = ctx.uehelp.call(a, fn)
  return ok and res == true
end

local function sweepStrays()
  if straysSwept or not ctx.net.isHost() then return end
  straysSwept = true
  if not ctx.config.get("evil_sweep_strays") then return end
  local swept = 0
  for spKey in pairs(SPECIES) do
    for _, a in ipairs(ctx.uehelp.findAll(speciesClass(spKey))) do
      if ctx.uehelp.isValid(a) and parseEvil(nameOf(a) or "")
          and not isTrackedEvil(a) and not isOwnedAnimal(a) then
        pcall(function() a:K2_DestroyActor() end)
        swept = swept + 1
      end
    end
  end
  if swept > 0 then ctx.log.info("evil: swept " .. swept .. " stray Unlit from an older storm") end
end

-- ONE spawn + brain chain pair per storm generation, no matter how many triggers fire (storm
-- start, a mid-storm second rite, sps_evil unlock): a doubled chain silently doubles the spawn
-- rate -- the exact bug family the ambient-bolt `ambientLive` guard exists for.
local chainsFor = -1
local function startChains()
  if not (stormOn and ctx.net.isHost() and ctx.config.get("evil_animals") and anyUnlocked()) then
    return
  end
  if chainsFor == token then return end
  chainsFor = token
  sweepStrays()
  spawnChain(token)
  brainChain(token)
end

--------------------------------------------------------------------- host: tool combat
-- Held-tool identity, the wand's proven recipe: CurItemdataInHand (S_Item struct) -> ItemActor
-- member (a UClass) -> class name. GUID-suffixed member names are discovered once off the
-- struct type. An EMPTY hand returns ItemActor as a userdata wrapping NULL -- isValid is the
-- only safe guard (ia == nil lets it through and GetFName() on it is a native crash).
local structMembers
local structMemberTries = 0
local function itemStructMembers(pawn)
  if structMembers ~= nil then return structMembers or nil end
  local prop = ctx.map.wand and ctx.map.wand.handItemDataProp
  if not prop then structMembers = false; return nil end
  local found
  pcall(function()
    local cls = pawn:GetClass()
    if not (cls and cls.ForEachProperty) then return end
    cls:ForEachProperty(function(pr)
      local pn; pcall(function() pn = pr:GetFName():ToString() end)
      if pn == prop then
        local st
        pcall(function() st = pr:GetStruct() end)
        if not st then pcall(function() st = pr.Struct end) end
        if st and st.ForEachProperty then
          local mm = {}
          st:ForEachProperty(function(mp)
            local mn; pcall(function() mn = mp:GetFName():ToString() end)
            if mn then mm[mn:match("^(.-)_%d+_") or mn] = mn end
          end)
          if next(mm) then found = mm end
        end
      end
    end)
  end)
  if found then
    structMembers = found
  else
    -- cap the retries: a build where the struct never resolves must not re-walk every pawn
    -- property on every swing forever (the wand's own recipe caps at 5 -- keep them in step).
    structMemberTries = structMemberTries + 1
    if structMemberTries >= 5 then structMembers = false end
  end
  return found
end

local function heldToolDamage(pawn)
  local prop = ctx.map.wand and ctx.map.wand.handItemDataProp
  if not prop then return nil end
  local ok, data = ctx.uehelp.get(pawn, prop)
  if not (ok and data ~= nil) then return nil end
  local members = itemStructMembers(pawn)
  if not (members and members.ItemActor) then return nil end
  local ia; pcall(function() ia = data[members.ItemActor] end)
  if not ctx.uehelp.isValid(ia) then return nil end  -- empty hand: NULL wrapper, never GetFName it
  local cn; pcall(function() cn = ia:GetFName():ToString() end)
  return F.toolDamageForClass(cn, {
    base    = ctx.config.get("evil_dmg_base"),
    metal   = ctx.config.get("evil_dmg_metal"),
    diamond = ctx.config.get("evil_dmg_diamond"),
  })
end

-- Loose facing gate so a swing doesn't gut the Unlit sneaking up BEHIND the player. Fails open:
-- if any reflection step misses, range alone decides.
local function facingOK(pawn, pl, al)
  local ok = true
  pcall(function()
    local rot = pawn:K2_GetActorRotation()
    local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
    local fwd = kml and ctx.uehelp.vec(kml:GetForwardVector(rot))
    if not fwd then return end
    local dx, dy = al.X - pl.X, al.Y - pl.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return end
    ok = (fwd.X * dx / len + fwd.Y * dy / len) > 0.2
  end)
  return ok
end

local function onSwing(pawn)
  if not ctx.net.isHost() then return end             -- authority only (client swings: see note in init)
  if not ctx.uehelp.isValid(pawn) then return end
  if countAlive() == 0 then return end
  local pid = playerIdOf(pawn)  -- stable key: idOf drifts with the pawn's location and leaks entries
  local now = os.clock()
  if now - (lastSwing[pid] or 0) < 0.35 then return end -- input events fire multiple phases
  lastSwing[pid] = now
  local dmg = heldToolDamage(pawn)
  if not dmg then return end                          -- bare hands don't wound the Unlit
  local pl = ctx.identity.locationOf(pawn)
  if not pl then return end
  local reach2 = ctx.config.get("evil_melee_range") ^ 2
  local best, bestD2
  for _, rec in pairs(evils) do
    if not rec.dying and ctx.uehelp.isValid(rec.actor) then
      local al = ctx.identity.locationOf(rec.actor)
      local d2 = al and ctx.uehelp.dist2(pl, al) or math.huge
      if d2 <= reach2 and d2 < (bestD2 or math.huge) and facingOK(pawn, pl, al) then
        best, bestD2 = rec, d2
      end
    end
  end
  if not best then return end
  best.hp = best.hp - dmg
  best.hits = (best.hits or 0) + 1
  -- a landed hit staggers it: stand frozen for evil_hit_stun (max() so it can't shorten a longer
  -- ram-recovery already ticking on a sheep). brainTick reads stunUntil and halts movement.
  best.stunUntil = math.max(best.stunUntil or 0, os.clock() + ctx.config.get("evil_hit_stun"))
  setName(best.actor, aliveName(best))  -- tally change = the replicated blink signal
  -- floor dmg for the log: a fractional config override + "%d" throws "no integer representation"
  -- (Lua 5.3+), and log.guard would swallow it BEFORE the kill check below -- unkillable Unlit.
  ctx.log.info(string.format("your tool bites the Unlit %s -- %d (%d left)",
    best.flavor, math.floor(dmg), math.max(0, math.floor(best.hp))))
  if best.hp <= 0 then killEvil(best, "struck down") end
end

-- Same hook family as the wand's cast trigger (PressedHandInteraction + IA_HandInteract* --
-- left click, fires with any tool). RegisterHook is per-UFunction: if the game happens to run
-- any of these on the host for REMOTE pawns too (anim-sync), co-op swings work for free; if
-- not, clients' swings are a known v1 gap (no client->host carrier exists yet -- wand.lua:881).
local function hookSwings()
  if swingsHooked then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local exact  = ctx.map.wand and ctx.map.wand.castFnExact
  local prefix = ctx.map.wand and ctx.map.wand.castFnPrefix
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
    local ok = pcall(RegisterHook, path, ctx.log.guard("evil.swing", function(Context)
      local p; pcall(function() p = Context:get() end)
      onGameThread(function() onSwing(p) end)
    end))
    if ok then hooked = hooked + 1 end
  end
  if hooked > 0 then
    swingsHooked = true
    ctx.log.info("evil: tool swings armed (" .. hooked .. " hooks)")
  end
end

--------------------------------------------------------------------- every machine: FX watcher
-- All of this is client-local dress driven by the replicated Name: material, voice pitch,
-- chatter, the hit blink, and quiet for the fallen. It runs on the host too (the host is also a
-- viewer). Armed by weather.changed (host) or by seeing a bolt actor replicate in (clients).
local matCache = {}
local function materialByName(name)
  if not name or name == "" then return nil end
  local cached = matCache[name]
  if cached and ctx.uehelp.isValid(cached) then return cached end
  matCache[name] = nil
  local function find()
    for _, kind in ipairs({ "MaterialInstanceConstant", "Material" }) do
      local ok, mt = pcall(FindObject, kind, name)
      if ok and ctx.uehelp.isValid(mt) then return mt end
    end
    return nil
  end
  local mt = find()
  if not mt and ctx.map.wand and ctx.map.wand.materialDir and LoadAsset then
    pcall(LoadAsset, ctx.map.wand.materialDir .. name .. "." .. name)
    mt = find()
  end
  matCache[name] = mt
  return mt
end

local sndCache = {}
local function soundByName(name)
  if not name then return nil end
  local cached = sndCache[name]
  if cached and ctx.uehelp.isValid(cached) then return cached end
  sndCache[name] = nil
  local function find()
    for _, kind in ipairs({ "SoundWave", "SoundCue" }) do
      local ok, s = pcall(FindObject, kind, name)
      if ok and ctx.uehelp.isValid(s) then return s end
    end
    return nil
  end
  local s = find()
  if not s and ctx.map.animal.soundDir and LoadAsset then
    pcall(LoadAsset, ctx.map.animal.soundDir .. name .. "." .. name)
    s = find()
  end
  sndCache[name] = s
  return s
end

-- Spatial cry with arity fallbacks (the reflected PlaySoundAtLocation signature varies); the
-- last resort is 2D at distance-faded volume -- a cry the player still hears is worth more
-- than silent perfection.
local function cryAt(pc, snd, loc, vol, pitch)
  local gs = StaticFindObject and StaticFindObject("/Script/Engine.Default__GameplayStatics")
  if not (gs and snd) then return end
  local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
  if pcall(function() gs:PlaySoundAtLocation(pc, snd, loc, rot, vol, pitch, 0.0, nil, nil, nil) end) then return end
  if pcall(function() gs:PlaySoundAtLocation(pc, snd, loc, rot, vol, pitch, 0.0) end) then return end
  if pcall(function() gs:PlaySoundAtLocation(pc, snd, loc, rot, vol, pitch) end) then return end
  pcall(function() gs:PlaySound2D(pc, snd, vol, pitch, 0.0) end)
end

local function dressBody(a, d)
  local mesh; pcall(function() mesh = a.Mesh end)
  if not mesh then return end
  if not d.origMat then pcall(function() d.origMat = mesh:GetMaterial(0) end) end
  local body = materialByName(ctx.config.get("evil_mat_body"))
  if not body then return end  -- material not resident yet: DON'T latch d.mat -- retry next pass
  if pcall(function() mesh:SetMaterial(0, body) end) then d.mat = true end
end

local function blink(a, d)
  local flash = materialByName(ctx.config.get("evil_mat_blink"))
  if not flash then return end
  local mesh; pcall(function() mesh = a.Mesh end)
  if not mesh then return end
  pcall(function() mesh:SetMaterial(0, flash) end)
  after(ctx.config.get("evil_blink_seconds"), function()
    if not ctx.uehelp.isValid(a) then return end
    local m2; pcall(function() m2 = a.Mesh end)
    if not m2 then return end
    local back = (d.dead and materialByName(ctx.config.get("evil_mat_dead")))
      or materialByName(ctx.config.get("evil_mat_body")) or d.origMat
    if back then pcall(function() m2:SetMaterial(0, back) end) end
  end)
end

-- Red aura: a spawned MOVABLE PointLight that trails each living Unlit animal. A red BODY is
-- impossible (skeletal meshes render any material lacking the compiled bUsedWithSkeletalMesh flag
-- as black, and no red/fire material in the game carries it -- proven via the cooked M_* dumps), so
-- the menace-red is LIGHT, not fur. Per-machine local FX: a plain engine PointLight actor does not
-- replicate, so every machine spawns its own and no client double-lights. Tracked in the dress
-- record; destroyed when the animal falls, vanishes, or the storm clears.
local pointLightClass
local function lightClass()
  if ctx.uehelp.isValid(pointLightClass) then return pointLightClass end
  pointLightClass = nil
  if not StaticFindObject then return nil end
  local c; pcall(function() c = StaticFindObject("/Script/Engine.PointLight") end)
  if ctx.uehelp.isValid(c) then pointLightClass = c end
  return pointLightClass
end

local function lightCompOf(a)
  local comp
  pcall(function() comp = a.PointLightComponent end)
  if not comp then pcall(function() comp = a.LightComponent end) end
  return comp
end

local function spawnGlow(pc, a, loc)
  if not loc then return nil end
  local cls = lightClass()
  if not cls then return nil end
  local light = ctx.uehelp.spawnActorAt(pc, cls, loc)
  if not ctx.uehelp.isValid(light) then return nil end
  local comp = lightCompOf(light)
  if comp then
    local cfg = ctx.config
    -- spawned lights default to Stationary (can't move at runtime) -- make it Movable so it trails
    pcall(function() comp:SetMobility(2) end)  -- EComponentMobility::Movable
    local col = { R = cfg.get("evil_glow_r"), G = cfg.get("evil_glow_g"),
                  B = cfg.get("evil_glow_b"), A = 1.0 }
    if not pcall(function() comp:SetLightColor(col, false) end) then
      pcall(function() comp:SetLightColor(col) end)
    end
    pcall(function() comp:SetIntensity(cfg.get("evil_glow_intensity")) end)
    pcall(function() comp:SetAttenuationRadius(cfg.get("evil_glow_radius")) end)
    pcall(function() comp:SetCastShadows(false) end)  -- an aura, not a scene light -- keep it cheap
  end
  return light
end

local function moveGlow(light, loc)
  if not (ctx.uehelp.isValid(light) and loc) then return end
  local at = { X = loc.X, Y = loc.Y, Z = loc.Z + 40 }  -- lift to body-centre so the pool wraps it
  if ctx.uehelp.call(light, "K2_SetActorLocation", at, false, {}, false) then return end
  if ctx.uehelp.call(light, "K2_SetActorLocation", at, true) then return end
  ctx.uehelp.call(light, "SetActorLocation", at)
end

local function killGlow(d)
  if not (d and d.light) then return end
  local l = d.light; d.light = nil
  if ctx.uehelp.isValid(l) then pcall(function() l:K2_DestroyActor() end) end
end

-- Fast light-follow: trail each already-spawned aura to its animal's CURRENT location. Decoupled
-- from the heavier fxPass (findAll/material/sound) so it can run at ~10 Hz for a smooth follow with
-- almost no cost -- it walks only the tracked records, no scans. Per-machine + local (the lights
-- never replicate), so this stays free no matter how many players are in the lobby.
local function glowFollow()
  for _, d in pairs(dressed) do
    if d.light and not d.dead and ctx.uehelp.isValid(d.light) and ctx.uehelp.isValid(d.actor) then
      moveGlow(d.light, ctx.identity.locationOf(d.actor))
    end
  end
end

local function fxPass()
  local cfg = ctx.config
  local pc = ctx.uehelp.localController(ctx.map.player.controllerClass)
  if not pc then return end
  local myPawn; pcall(function() myPawn = pc:K2_GetPawn() end)
  local myLoc = ctx.uehelp.isValid(myPawn) and ctx.identity.locationOf(myPawn) or nil
  local lock2 = cfg.get("evil_lockon_radius") ^ 2
  local now = os.clock()
  local seenPass = now
  for spKey in pairs(SPECIES) do
    local sp = SPECIES[spKey]
    for _, a in ipairs(ctx.uehelp.findAll(speciesClass(spKey))) do
      if ctx.uehelp.isValid(a) then
        local state, hits = parseEvil(nameOf(a) or "")
        if state then
          local fn; pcall(function() fn = a:GetFullName() end)
          if fn then
            local d = dressed[fn]
            if not d then d = { hits = hits }; dressed[fn] = d end
            d.seen = seenPass
            d.actor = a  -- fresh handle so glowFollow() can trail the aura without a findAll
            if not d.mat then dressBody(a, d) end
            if not d.pitch then
              local comp; pcall(function() comp = a[ctx.map.animal.audioCompProp] end)
              if comp then
                if pcall(function() comp:SetPitchMultiplier(cfg.get("evil_sound_pitch")) end) then
                  d.pitch = true
                end
              end
            end
            -- size: loom at the species' scale (visual; every machine sets its own). Latch once.
            if not d.scaled then
              local scale = cfg.get(sp.scaleKey)
              if scale and scale ~= 1.0 then
                local v = { X = scale, Y = scale, Z = scale }
                local okc = ctx.uehelp.call(a, "SetActorScale3D", v)
                if not okc then
                  local root; pcall(function() root = a.RootComponent end)
                  if root then okc = ctx.uehelp.call(root, "SetWorldScale3D", v) end
                end
                if okc then d.scaled = true end
              else
                d.scaled = true  -- 1x: nothing to do, don't retry every pass
              end
            end
            if state == "alive" then
              -- blink on ANY tally change, not just an increase: the name encodes hits mod 4, so
              -- the 4th landed hit wraps 3 -> 0 and a `>` test would skip its flash.
              if hits ~= (d.hits or 0) then blink(a, d) end
              d.hits = hits
              local al = ctx.identity.locationOf(a)
              -- red aura: spawn once, then trail the body every pass (live toggle-off destroys it)
              if cfg.get("evil_glow") then
                if not ctx.uehelp.isValid(d.light) then d.light = spawnGlow(pc, a, al) end
                moveGlow(d.light, al)
              elseif d.light then
                killGlow(d)
              end
              -- chatter: its own calls, pitched down; frantic once it hunts the LOCAL player
              if al and myLoc then
                local hunting = ctx.uehelp.dist2(al, myLoc) <= lock2
                local gap = hunting and cfg.get("evil_chatter_chase") or cfg.get("evil_chatter_wander")
                if now - (d.lastChatter or 0) >= gap * (0.7 + math.random() * 0.6) then
                  d.lastChatter = now
                  local names = ctx.map.animal[sp.soundsKey] or {}
                  local pick = names[math.random(math.max(1, #names))]
                  if hunting and spKey == "chicken" and ctx.map.animal.screamChicken
                      and math.random() < 0.34 then
                    pick = ctx.map.animal.screamChicken
                  end
                  cryAt(pc, soundByName(pick), al, 1.0, cfg.get("evil_sound_pitch"))
                end
                -- attack cry: while actually biting the LOCAL player (within bite range), sound off
                -- on every bite -- its own voice, pitched down (sheep bite slower via atkSpeedKey).
                if ctx.uehelp.dist2(al, myLoc) <= cfg.get("evil_bite_radius") ^ 2 then
                  local abite = attackGap(sp)
                  if now - (d.lastAtk or 0) >= abite then
                    d.lastAtk = now
                    local anames = ctx.map.animal[sp.soundsKey] or {}
                    cryAt(pc, soundByName(anames[math.random(math.max(1, #anames))]), al, 1.0,
                      cfg.get("evil_sound_pitch"))
                  end
                end
              end
            elseif state == "dead" then
              killGlow(d)  -- the red aura dies with the animal; the fallen carry no light
              -- fallen: swap to the death tint (black) and fall silent. Don't latch d.dead until
              -- the swap actually takes -- the material may not be resident on the first pass.
              if not d.dead then
                local deadMat = materialByName(cfg.get("evil_mat_dead"))
                local mesh; pcall(function() mesh = a.Mesh end)
                if deadMat and mesh and pcall(function() mesh:SetMaterial(0, deadMat) end) then
                  d.dead = true
                end
              end
            end
          end
        end
      end
    end
  end
  -- forget dress records whose actors vanished (destroy replicated in)
  for fn, d in pairs(dressed) do
    if d.seen ~= seenPass then killGlow(d); dressed[fn] = nil end
  end
end

-- The fx chain stops calling fxPass the instant the storm window closes, so its own
-- vanish-cleanup can't reap the last lights. Sweep every glow (and dress record) here instead.
local function teardownFx()
  for fn, d in pairs(dressed) do killGlow(d); dressed[fn] = nil end
end

local function fxWindowOpen()
  return stormOn or (os.clock() - lastBoltSeen) < ctx.config.get("natural_storm_timeout")
end

local function fxChain(tok)
  if tok ~= fxToken or not fxWindowOpen() then fxLive = false; teardownFx(); return end
  after(ctx.config.get("evil_fx_interval"), function()
    if tok ~= fxToken then return end
    if not fxWindowOpen() then fxLive = false; teardownFx(); return end
    if ctx.config.get("evil_animals") then fxPass() end
    fxChain(tok)
  end)
end

-- Its own fast cadence, sharing fxToken so it dies with the fx window. No teardown here -- fxChain
-- owns light cleanup; a stray tick after teardownFx just walks an empty table (moveGlow is guarded).
local function glowChain(tok)
  if tok ~= fxToken or not fxWindowOpen() then return end
  after(ctx.config.get("evil_glow_follow"), function()
    if tok ~= fxToken or not fxWindowOpen() then return end
    if ctx.config.get("evil_animals") and ctx.config.get("evil_glow") then glowFollow() end
    glowChain(tok)
  end)
end

local function armFx()
  if fxLive then return end
  fxLive = true
  fxToken = fxToken + 1
  fxChain(fxToken)
  glowChain(fxToken)
end

--------------------------------------------------------------------- events + init
local function onWeather(e)
  local now = e and e.storm or false
  if now == stormOn then
    if now then armFx() end
    return
  end
  stormOn = now
  token = token + 1
  if stormOn then
    armFx()
    if ctx.net.isHost() and anyUnlocked() and ctx.config.get("evil_animals") then
      ctx.log.info("*** the storm remembers its due -- the Unlit are abroad ***")
    end
    startChains()
    hookSwings()  -- pawns certainly exist by the first storm
  else
    if ctx.net.isHost() then
      for _, rec in pairs(evils) do killEvil(rec, "the storm that made it has passed") end
    end
  end
end

local function onRitual(e)
  local rite = e and e.rite
  for spKey, sp in pairs(SPECIES) do
    if sp.riteKey == rite and not unlocked[spKey] then
      unlocked[spKey] = true
      if ctx.save.setFlag then ctx.save.setFlag(sp.flag, true) end
      ctx.log.info("*** the storm has tasted " .. spKey ..
        " blood -- from this night the Unlit " .. spKey .. "s walk in every storm ***")
      startChains()
    end
  end
end

local function onStrike(e)
  if not (ctx.net.isHost() and e and e.location) then return end
  local r2 = ctx.config.get("strike_radius") ^ 2
  for _, rec in pairs(evils) do
    if not rec.dying and ctx.uehelp.isValid(rec.actor) then
      local al = ctx.identity.locationOf(rec.actor)
      if al and ctx.uehelp.dist2(al, e.location) <= r2 then
        killEvil(rec, "taken back by the lightning")
      end
    end
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "evil_animals",
      { "animal.sheepClass", "animal.chickenClass", "animal.nameProp",
        "pawn.class", "player.controllerClass" }) then
    return false
  end

  for spKey, sp in pairs(SPECIES) do
    unlocked[spKey] = (ctx.save.getFlag and ctx.save.getFlag(sp.flag)) == true
  end

  ctx.bus.on("weather.changed",  ctx.log.guard("evil.weather", onWeather))
  ctx.bus.on("ritual.completed", ctx.log.guard("evil.ritual", onRitual))
  ctx.bus.on("lightning.strike", ctx.log.guard("evil.strike", onStrike))

  -- Clients get no weather.changed (storms is host-gated) -- but bolt ACTORS replicate to every
  -- machine. Seeing one opens the FX window, exactly like storms' own natural-storm tap.
  if ctx.map.weather and ctx.map.weather.boltActorClass then
    ctx.uehelp.onNewInstance("/Script/Engine.Actor", ctx.map.weather.boltActorClass,
      ctx.log.guard("evil.bolt", function()
        lastBoltSeen = os.clock()
        onGameThread(armFx)
      end))
  end

  -- Ritual detection must never claim an Unlit as an offering. ritual.lua is host-only, and the
  -- host spawned every Unlit, so use the authoritative tracking table (object identity) -- NOT the
  -- replicated Name, which a player-renamed pet ("Unlit Clucky") would falsely match and be barred
  -- from ever being sacrificed.
  ctx.services.isEvilAnimal = isTrackedEvil

  pcall(function()
    RegisterConsoleCommandHandler("sps_evil", function(_, parts)
      onGameThread(ctx.log.guard("evil.cmd", function()
        local sub = parts and parts[1] and tostring(parts[1]):lower() or ""
        if sub == "unlock" then
          local which = parts[2] and tostring(parts[2]):lower() or "all"
          for spKey, sp in pairs(SPECIES) do
            if which == "all" or which == spKey then
              unlocked[spKey] = true
              if ctx.save.setFlag then ctx.save.setFlag(sp.flag, true) end
            end
          end
          ctx.log.info("evil: unlocked " .. which .. " (dev)")
          startChains()
        elseif sub == "spawn" then
          if not (stormOn and ctx.net.isHost()) then
            ctx.log.warn("evil: spawn needs an active storm on the host")
          else
            local pc = ctx.uehelp.localController(ctx.map.player.controllerClass)
            if pc then trySpawnOne(pc) end
          end
        else
          local locked = {}
          for spKey in pairs(SPECIES) do
            locked[#locked + 1] = spKey .. "=" .. tostring(unlocked[spKey])
          end
          ctx.log.info(string.format("evil: storm=%s alive=%d %s (sps_evil unlock [sp]|spawn)",
            tostring(stormOn), countAlive(), table.concat(locked, " ")))
        end
      end))
      return true
    end)
  end)

  local names = {}
  for spKey in pairs(SPECIES) do if unlocked[spKey] then names[#names + 1] = spKey end end
  ctx.log.info("evil_animals: the Unlit are listening" ..
    (#names > 0 and (" -- already unbound: " .. table.concat(names, ", ")) or
     " -- no species unbound yet (sacrifice one)"))
  return true
end

return F
