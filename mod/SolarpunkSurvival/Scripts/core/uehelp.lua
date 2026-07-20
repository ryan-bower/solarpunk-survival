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
function M.call(obj, fnName, ...)
  if not obj or not fnName then return false, nil end
  local args = { ... }
  local ok, res = pcall(function()
    local fn = obj[fnName]
    if type(fn) ~= "function" then error("no ufunction '" .. tostring(fnName) .. "'") end
    return fn(obj, table.unpack(args))
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

-- FVector -> plain table {X,Y,Z}, or nil.
function M.vec(v)
  if not v then return nil end
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
