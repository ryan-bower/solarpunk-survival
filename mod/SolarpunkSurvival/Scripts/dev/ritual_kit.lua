-- Dev: one-shot "give me the needful" for either rite of the Dark Arts.
--
-- Stages everything a rite needs so it can be triggered on the spot instead of foraging for it:
--   * spawns the rite's ANIMAL at the pentagram center (chicken for hydration, sheep for electrick).
--     The center is YOUR LAST MAP PING: ping the pentagram, then run this. It is remembered across
--     restarts (dump/lastping.txt) and falls back to CENTER below if you've never pinged.
--   * grants the real MUNDANE WAND item (the rod the storm transmutes -- content pak required)
--   * grants ONE of each of the rite's five corner OFFERINGS into the inventory
--
-- Then the operator only has to lay the five offerings by the candles, hold the wand inside the
-- circle, and call the storm (H). The rite tableau + payout live in features/ritual.lua; this
-- module just fills the pantry.
--
-- Drive it two ways:
--   console:  sps_needful hydration [noanimal]   |   sps_needful electrick [noanimal]
--   remote:   ctx.services.stageRitualKit("hydration", { animal = false })   (dev/remote exec)
-- The optional "noanimal" (or nochicken/nosheep/here) skips the spawn when one already stands in
-- the circle -- grants only the rod + the five offerings.
--
-- Everything is host-side (DEBUG_SpawnItems + spawnActorAt) and pcall-guarded like the rest of dev/.
local F = {}
local ctx

-- Fallback pentagram center, used ONLY until the player pings (the ping is the live source of
-- truth -- see lastPing below). Updated 2026-07-23 to the user's relocated pentagram.
local CENTER = { X = 4686.5, Y = -3382.4, Z = -5188.3 }

-- The player's most recent map ping = where the animal spawns. Persisted to PING_FILE so a pinged
-- pentagram survives a restart; the ping hook writes it, init loads it back.
local lastPing = nil
local pingPath = nil   -- <modRoot>/dump/lastping.txt, resolved in init
local PING_FILE = "dump/lastping.txt"

-- The two rites -> what each needs. animalKey/offeringsKey index into mapping.animal / mapping.ritual
-- so a game update that moves a class only has to change mapping.lua, never this file.
local RITES = {
  hydration = { animalKey = "chickenClass", animalName = "the bird",
                offeringsKey = "hydrationOfferings" },
  electrick = { animalKey = "sheepClass",   animalName = "the lamb",
                offeringsKey = "electrickOfferings" },
}

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

-- A mapped offering is one class name or a LIST of acceptable ones (clay drops as its GrabItem
-- form). For GRANTING we want the plain inventory item, so prefer the "_Item_C" variant.
local function giveClassOf(cn)
  if type(cn) ~= "table" then return cn end
  for _, c in ipairs(cn) do if c:find("_Item_C$") then return c end end
  return cn[1]
end

-- Resolve (and if needed LoadAsset) the rite's animal UClass off mapping.animal.
local function animalClass(rite)
  local am = ctx.map.animal or {}
  local short = am[rite.animalKey]
  if not short then return nil, nil end
  local path = am.classPaths and am.classPaths[short]
  return ctx.uehelp.classByName(short, path), short
end

-- --- ping tracking: the pentagram center follows the player's last map ping -------------------
local function parsePing(s)
  if not s then return nil end
  local x, y, z = s:match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if x and y and z then return { X = x, Y = y, Z = z } end
  return nil
end

local function loadPing()
  if not pingPath then return end
  local f = io.open(pingPath, "r"); if not f then return end
  local s = f:read("*a"); f:close()
  local p = parsePing(s)
  if p then lastPing = p end
end

local function savePing(p)
  if not pingPath then return end
  local f = io.open(pingPath, "w"); if not f then return end
  f:write(string.format("%.1f %.1f %.1f\n", p.X, p.Y, p.Z)); f:close()
end

-- Resolve a UFunction's full object path off an instance (RegisterHook rejects short "Class:Fn").
-- Mirrors features/storms.fullFuncPath.
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

local pingHooked = false
-- Hook MULTI_Ping so every accepted map ping updates the spawn center. RegisterHook is per
-- UFunction (class-wide), so ONE resolved path covers all controllers -- we only need any live
-- controller to resolve it.
local function armPingHook()
  if pingHooked then return true end
  local pc = ctx.uehelp.findFirst(ctx.map.player and ctx.map.player.controllerClass)
  local fn = ctx.map.player and ctx.map.player.pingFn
  if not (pc and fn) then return false end
  local path = fullFuncPath(pc, fn)
  if not path then return false end
  local ok = pcall(RegisterHook, path, ctx.log.guard("ritual_kit.ping", function(_, LocationParam)
    local v = LocationParam
    pcall(function() v = LocationParam:get() end)
    local loc = ctx.uehelp.vec(v)
    if loc then
      lastPing = loc
      savePing(loc)
      ctx.log.info(string.format(
        "ritual_kit: pentagram set to your ping (%.0f, %.0f, %.0f) -- next sps_needful spawns here",
        loc.X, loc.Y, loc.Z))
    end
  end))
  pingHooked = ok == true
  return pingHooked
end

-- Stage the rite named by `key` ("hydration" | "electrick"). `opts.animal == false` skips the
-- spawn (the animal is already penned in the circle) and only grants the rod + offerings. Returns
-- a result table (also logged), so the remote exec channel can emit the outcome field by field.
function F.stage(key, opts)
  opts = opts or {}
  local rite = RITES[key]
  if not rite then
    ctx.log.warn("ritual_kit: unknown rite '" .. tostring(key) .. "' (hydration | electrick)")
    return { ok = false, reason = "unknown rite" }
  end

  local pc = ctx.uehelp.findFirst(ctx.map.player and ctx.map.player.controllerClass)
       or ctx.uehelp.playerController()
  if not pc then
    ctx.log.warn("ritual_kit: no controller (load a world first)")
    return { ok = false, reason = "no controller" }
  end

  local result = { ok = true, rite = key, offerings = {} }

  -- 1) the animal at the heart of the star (unless one is already penned there). Center priority:
  --    an explicit opts.loc, else your last map ping, else the CENTER fallback.
  result.animal = ctx.map.animal and ctx.map.animal[rite.animalKey]
  local center = opts.loc or lastPing or CENTER
  result.center = center
  result.centerSource = opts.loc and "opts" or (lastPing and "ping") or "fallback"
  if opts.animal == false then
    result.animalSkipped = true
  else
    local cls, short = animalClass(rite)
    local animal = cls and ctx.uehelp.spawnActorAt(pc, cls,
      { X = center.X, Y = center.Y, Z = center.Z + 80 })
    result.animalSpawned = ctx.uehelp.isValid(animal)
    if not result.animalSpawned then
      ctx.log.warn("ritual_kit: could not spawn " .. tostring(short) .. " (class not loaded?)")
    end
  end

  -- 2) the mundane rod the storm will transmute (real cooked item; needs the wand pak)
  local mundane = ctx.map.wand and ctx.map.wand.itemRows and ctx.map.wand.itemRows.mundane
  result.wand = mundane ~= nil and ctx.items.give(pc, mundane, 1) or false
  if mundane and not result.wand then
    ctx.log.warn("ritual_kit: could not grant " .. mundane ..
      " -- is the wand content pak installed? (Solarpunk-Windows_1_P.*)")
  end

  -- 3) one of each of the rite's five corner offerings
  local offerings = (ctx.map.ritual and ctx.map.ritual[rite.offeringsKey]) or {}
  local given, total = 0, 0
  for kind, cn in pairs(offerings) do
    total = total + 1
    local gc = giveClassOf(cn)
    local ok = ctx.items.giveByClass(pc, gc, 1)
    if ok then given = given + 1 end
    result.offerings[#result.offerings + 1] = { kind = kind, cls = gc, ok = ok }
  end
  result.given, result.total = given, total

  local where = string.format(" (%.0f, %.0f, %.0f, from %s)",
    center.X, center.Y, center.Z, result.centerSource)
  local animalPhrase = result.animalSkipped and (rite.animalName .. " already at the pentagram")
    or (result.animalSpawned and (rite.animalName .. " at the pentagram" .. where)
        or (rite.animalName .. " (SPAWN FAILED)"))
  ctx.log.info(string.format(
    "*** the needful for the %s rite: %s, a mundane rod%s, %d/%d offerings ***",
    key, animalPhrase, result.wand and "" or " (FAILED)", given, total))
  ctx.log.info("    lay the offerings by the candles, hold the rod in the circle, call the storm (H)")
  return result
end

function F.init(c)
  ctx = c
  -- expose to the remote exec channel and any other dev caller
  ctx.services.stageRitualKit = F.stage
  ctx.services.ritualCenter = function() return lastPing or CENTER, lastPing and "ping" or "fallback" end

  -- the spawn center follows the player's map pings; remember the last one across restarts
  pingPath = (ctx.modRoot or "") .. PING_FILE
  loadPing()
  -- arm now if a world is already loaded, else on the next controller (world load)
  if not armPingHook() then
    ctx.uehelp.onNewInstance("/Script/Engine.PlayerController",
      ctx.map.player and ctx.map.player.controllerClass,
      ctx.log.guard("ritual_kit.newpc", armPingHook))
  end

  pcall(function()
    RegisterConsoleCommandHandler("sps_needful", function(_, params)
      local key = (params and params[1]) or ""
      -- second word "noanimal"/"nochicken"/"nosheep"/"here" -> skip the spawn (one already stands)
      local flag = (params and params[2] or ""):lower()
      local skip = flag == "noanimal" or flag == "nochicken" or flag == "nosheep" or flag == "here"
      onGameThread(function()
        if RITES[key] then F.stage(key, { animal = not skip })
        else ctx.log.info("usage: sps_needful hydration|electrick [noanimal]") end
      end)
      return true
    end)
  end)

  ctx.log.info("ritual_kit: `sps_needful hydration|electrick [noanimal]` stages the animal +"
    .. " mundane rod + five offerings (animal spawns at your last map ping)")
  return true
end

return F
