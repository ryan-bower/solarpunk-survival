-- Stable actor identity: the key shared by health, save, and replication.
-- Prefers a mapped save/network id property; falls back to class + rounded world location.
local uehelp = require("core.uehelp")

local M = {}
M._map = nil
function M.init(map) M._map = map; return M end

function M.locationOf(actor)
  local fn = (M._map and M._map.pawn and M._map.pawn.worldLocationFn) or "K2_GetActorLocation"
  local ok, v = uehelp.call(actor, fn)
  if ok then return uehelp.vec(v) end
  return nil
end

function M.idOf(actor)
  if not uehelp.isValid(actor) then return nil end

  local b = M._map and M._map.build
  if b and b.stableIdProp then
    local ok, v = uehelp.get(actor, b.stableIdProp)
    if ok and v ~= nil and tostring(v) ~= "" then
      return "id:" .. tostring(v)
    end
  end

  local cls = uehelp.className(actor) or "?"
  local loc = M.locationOf(actor)
  if loc then
    -- round to 0.5 m grid so the id is stable across minor float jitter and save/load
    return string.format("%s@%d,%d,%d", cls,
      math.floor(loc.X / 50 + 0.5),
      math.floor(loc.Y / 50 + 0.5),
      math.floor(loc.Z / 50 + 0.5))
  end
  return "obj:" .. tostring(actor)
end

return M
