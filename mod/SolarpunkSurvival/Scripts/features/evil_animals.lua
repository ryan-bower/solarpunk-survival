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
              soundsKey = "soundsChicken", flavors = { "Bird", "Hen", "Pullet", "Cockerel" } },
  sheep   = { classKey = "sheepClass", riteKey = "electrick", flag = "evil_sheep",
              hpKey = "evil_hp_sheep", biteKey = "evil_bite_sheep",
              soundsKey = "soundsSheep", flavors = { "Ewe", "Ram", "Lamb", "Wether" } },
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

--------------------------------------------------------------------- host: spawning
-- Open-ground check: a down-trace from above the ring point. The hit's owning actor classifies
-- the surface -- player-built pieces and water are rejected; the landscape itself usually
-- resolves to no BP class at all, which is exactly the "bare earth" we want.
local REJECT_HINTS = { "Water", "Buildable", "Placeable", "Preview", "Foundation", "Build",
                       "Floor", "Roof", "Wall", "Fence", "Bridge" }

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
      local comp; pcall(function() comp = hit.Component end)
      if comp then
        local owner; pcall(function() owner = comp:GetOwner() end)
        if owner then hitCls = ctx.uehelp.className(owner) end
      end
    end
  end)
  if not hitLoc then return nil end
  if hitCls then
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
  if #pool == 0 then return end
  local spKey = pool[math.random(#pool)]
  local clsName = speciesClass(spKey)
  local paths = ctx.map.animal.classPaths or {}
  local cls = ctx.uehelp.classByName(clsName, paths[clsName])
  if not cls then ctx.log.debug("evil: class " .. tostring(clsName) .. " unresolved"); return end
  local loc = pickSpawnSpot(pc, pawns)
  if not loc then return end  -- bad ground this attempt; the chain simply tries again
  local a = ctx.uehelp.spawnActorAt(pc, cls, { X = loc.X, Y = loc.Y, Z = loc.Z + 30 })
  if not a then return end
  nextKey = nextKey + 1
  local sp = SPECIES[spKey]
  local rec = {
    key = nextKey, actor = a, species = spKey,
    hp = ctx.config.get(sp.hpKey), hits = 0, mode = "wander",
    flavor = sp.flavors[(nextKey % #sp.flavors) + 1] .. " " .. tostring(nextKey),
    inited = false, initTries = 0, lastBite = 0, nextHop = 0,
  }
  evils[rec.key] = rec
  setName(a, aliveName(rec))  -- the beacon goes up first: even pre-AI, every machine can dress it
  ctx.log.info(string.format("an %s slips out of the rain (%d/%d abroad)",
    aliveName(rec), countAlive(), ctx.config.get("evil_cap_per_player") * math.max(1, #pawns)))
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
          if best and bestD2 <= lock2 then
            if rec.mode ~= "chase" then
              rec.mode = "chase"
              ctx.log.debug("evil: " .. rec.flavor .. " locks on")
            end
            setSpeed(rec, cfg.get("evil_chase_mult"))
            if ctx.uehelp.isValid(aic) then orderMoveToActor(aic, best) end
          else
            rec.mode = "wander"
            setSpeed(rec, cfg.get("evil_wander_mult"))
            if now >= (rec.nextHop or 0) and ctx.uehelp.isValid(aic) then
              local hop = cfg.get("evil_wander_hop")
              local ang = math.random() * 2 * math.pi
              orderMoveToLocation(aic, { X = al.X + math.cos(ang) * hop,
                                         Y = al.Y + math.sin(ang) * hop, Z = al.Z })
              rec.nextHop = now + 2.0 + math.random() * 3.0
            end
          end
          -- the bite: everyone inside the circle, on the animal's own cooldown
          if now - (rec.lastBite or 0) >= cfg.get("evil_bite_interval") then
            local bit = false
            for _, p in ipairs(pawns) do
              local pl = ctx.identity.locationOf(p)
              if pl and ctx.uehelp.dist2(al, pl) <= bite2 then
                local pc; pcall(function() pc = p.Controller end)
                if ctx.uehelp.isValid(pc) and ctx.services.damagePlayerBy then
                  ctx.services.damagePlayerBy(pc, cfg.get(SPECIES[rec.species].biteKey),
                    "the " .. aliveName(rec) .. " savages you")
                  bit = true
                end
              end
            end
            if bit then rec.lastBite = now end
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
    if ctx.net.isHost() and ctx.config.get("evil_animals") and anyUnlocked() then
      local pawns = playerPawns()  -- scanned ONCE per attempt; threaded into the cap + spawn spot
      local cap = ctx.config.get("evil_cap_per_player") * math.max(1, #pawns)
      if countAlive() < cap then
        local pc = ctx.uehelp.localController(ctx.map.player.controllerClass)
        if pc then trySpawnOne(pc, pawns) end
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
    local back = materialByName(ctx.config.get("evil_mat_body")) or d.origMat
    if back then pcall(function() m2:SetMaterial(0, back) end) end
  end)
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
            if not d.mat then dressBody(a, d) end
            if not d.pitch then
              local comp; pcall(function() comp = a[ctx.map.animal.audioCompProp] end)
              if comp then
                if pcall(function() comp:SetPitchMultiplier(cfg.get("evil_sound_pitch")) end) then
                  d.pitch = true
                end
              end
            end
            if state == "alive" then
              -- blink on ANY tally change, not just an increase: the name encodes hits mod 4, so
              -- the 4th landed hit wraps 3 -> 0 and a `>` test would skip its flash.
              if hits ~= (d.hits or 0) then blink(a, d) end
              d.hits = hits
              -- chatter: its own calls, pitched down; frantic once it hunts the LOCAL player
              local al = ctx.identity.locationOf(a)
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
              end
            elseif state == "dead" and not d.dead then
              d.dead = true  -- fallen: no more chatter; the body keeps its corrupted coat
            end
          end
        end
      end
    end
  end
  -- forget dress records whose actors vanished (destroy replicated in)
  for fn, d in pairs(dressed) do
    if d.seen ~= seenPass then dressed[fn] = nil end
  end
end

local function fxWindowOpen()
  return stormOn or (os.clock() - lastBoltSeen) < ctx.config.get("natural_storm_timeout")
end

local function fxChain(tok)
  if tok ~= fxToken or not fxWindowOpen() then fxLive = false; return end
  after(ctx.config.get("evil_fx_interval"), function()
    if tok ~= fxToken then return end
    if not fxWindowOpen() then fxLive = false; return end
    if ctx.config.get("evil_animals") then fxPass() end
    fxChain(tok)
  end)
end

local function armFx()
  if fxLive then return end
  fxLive = true
  fxToken = fxToken + 1
  fxChain(fxToken)
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
