-- Thin, defensive wrappers over UE4SS globals. Everything returns nil/false on failure
-- instead of throwing, so a symbol that moved after a patch degrades one call, not the mod.
-- Exact accessors (local pawn, net mode) are verified during reverse-engineering.
local log = require("core.log")
local M = {}

function M.isValid(obj)
  if not obj then return false end
  local ok, v = pcall(function() return obj:IsValid() end)
  return ok and v == true
end

function M.findFirst(className)
  if not className then return nil end
  local ok, obj = pcall(FindFirstOf, className)
  if ok and M.isValid(obj) then return obj end
  return nil
end

function M.findAll(className)
  if not className then return {} end
  local ok, arr = pcall(FindAllOf, className)
  if ok and type(arr) == "table" then return arr end
  return {}
end

function M.playerController()
  -- FindFirstOf is a reasonable default; refine to the *local* PC during RE if needed.
  return M.findFirst("PlayerController")
end

function M.localPawn()
  local pc = M.playerController()
  if pc then
    local ok, pawn = pcall(function() return pc.Pawn end)
    if ok and M.isValid(pawn) then return pawn end
  end
  return M.findFirst("Character")
end

-- Call a reflected UFunction by name. Returns ok, result.
-- NOTE: UE4SS exposes reflected methods as *userdata* (callable), NOT a Lua `function`, so we must
-- NOT type-check for "function" here. obj[fnName](obj, ...) is the method-call form and works for
-- both engine and Blueprint UFunctions (verified: DEBUG_SpawnItems, InstantThunderstorm, AddHealth).
function M.call(obj, fnName, ...)
  if not obj or not fnName then return false, nil end
  local args = { ... }
  local n = select("#", ...)
  local ok, res = pcall(function()
    local fn = obj[fnName]
    if fn == nil then error("no ufunction '" .. tostring(fnName) .. "'") end
    return fn(obj, table.unpack(args, 1, n))
  end)
  if not ok then log.debug("call " .. tostring(fnName) .. " failed: " .. tostring(res)) end
  return ok, res
end

-- Read / write a reflected property by name.
function M.get(obj, propName)
  if not obj or not propName then return false, nil end
  return pcall(function() return obj[propName] end)
end

function M.set(obj, propName, value)
  if not obj or not propName then return false end
  local ok, err = pcall(function() obj[propName] = value end)
  if not ok then log.debug("set " .. tostring(propName) .. " failed: " .. tostring(err)) end
  return ok
end

function M.className(obj)
  local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
  if ok and name then return name end
  return nil
end

-- Is `obj` an instance of (or derived from) a class whose short name == className?
function M.isA(obj, className)
  if not obj or not className then return false end
  local ok, res = pcall(function()
    -- IsA takes a UClass; fall back to name compare if we can't resolve one cheaply.
    local n = M.className(obj)
    return n == className
  end)
  return ok and res == true
end

-- Find a loaded UClass by short name (Blueprint classes first, then native). If not in memory yet
-- and an asset path is given, LoadAsset it. NOTE: FindAllOf("BlueprintGeneratedClass") returns
-- nothing -- only FindObject(kind, name) resolves class objects.
function M.classByName(name, path)
  if not name then return nil end
  local function find()
    for _, kind in ipairs({ "BlueprintGeneratedClass", "Class" }) do
      local ok, c = pcall(FindObject, kind, name)
      if ok and c and M.isValid(c) then return c end
    end
    return nil
  end
  local c = find()
  if c then return c end
  if path and LoadAsset then
    pcall(LoadAsset, path)
    -- LoadAsset's return value is unreliable, but it loads the package as a side effect --
    -- ALWAYS re-query after it (verified live: trusting the return left the bolt invisible).
    return find()
  end
  return nil
end

-- NotifyOnNewObject REJECTS short class names ("must contain at least two parts") -- it needs a
-- full object path. Register on a native parent path and filter to the BP class in the callback.
function M.onNewInstance(nativePath, shortClass, cb)
  return pcall(NotifyOnNewObject, nativePath, function(obj)
    -- the notify callback runs mid-construction with no outer guard: never let an error escape
    pcall(function()
      if not shortClass or M.className(obj) == shortClass then cb(obj) end
    end)
  end)
end

-- Deferred-spawn an actor class at a world location so its BeginPlay (VFX, timelines) runs at the
-- right spot. Verified live on this build: UWorld:SpawnActor silently ignores a location table
-- (the actor lands at the origin); GameplayStatics BeginDeferredActorSpawnFromClass +
-- FinishSpawningActor(Actor, Transform, ScaleMethod) places it exactly. Returns the actor or nil.
function M.spawnActorAt(worldCtx, cls, loc)
  if not (worldCtx and cls and loc) then return nil end
  if not StaticFindObject then return nil end
  local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  if not gs then return nil end
  local xf = {
    Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
    Scale3D     = { X = 1, Y = 1, Z = 1 },
  }
  local a
  local ok, err = pcall(function()
    a = gs:BeginDeferredActorSpawnFromClass(worldCtx, cls, xf, 1, nil, 0)
    if a then gs:FinishSpawningActor(a, xf, 0) end
  end)
  if not ok then log.debug("spawnActorAt failed: " .. tostring(err)); return nil end
  if M.isValid(a) then return a end
  return nil
end

-- FVector -> plain table {X,Y,Z}, or nil.
function M.vec(v)
  if not v then return nil end
  -- stale hook params have leaked plain functions here (seen live 2026-07-21); only userdata and
  -- tables can carry an FVector
  local tv = type(v)
  if tv ~= "userdata" and tv ~= "table" then return nil end
  local okx, x = pcall(function() return v.X end)
  local oky, y = pcall(function() return v.Y end)
  local okz, z = pcall(function() return v.Z end)
  if okx and oky and okz then return { X = x, Y = y, Z = z } end
  return nil
end

function M.dist2(a, b)
  if not a or not b then return math.huge end
  local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
  return dx * dx + dy * dy + dz * dz
end

return M
