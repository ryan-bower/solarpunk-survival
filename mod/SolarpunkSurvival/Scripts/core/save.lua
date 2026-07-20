-- Host-only persistence of mod state. Preferred path once mapped: hook the game's own
-- save/load UFunctions (save.saveFn / save.loadFn) so our state rides the game save.
-- Until then, a host-side sidecar JSON file keyed to the mod install is used.
local json    = require("lib.json")
local health  = require("core.health")
local net     = require("core.net")
local log     = require("core.log")
local bus     = require("core.eventbus")

local M = {}
M.schemaVersion = 1
M._map = nil
M._path = nil
M._pending = nil

function M.init(map, modRoot)
  M._map = map
  M._path = (modRoot or "") .. "save/state.json"

  -- Persist on the game's save/load if those hooks are mapped; else save on demand.
  bus.on("save.write", function() M.write() end)
  bus.on("save.read",  function() M.read() end)
  -- Reconcile loaded state onto structures as their health records appear.
  bus.on("health.attached", function(e)
    if e and e.id and e.rec then M.restore(e.id, e.rec) end
  end)
  return M
end

function M.serialize()
  local data = { schema = M.schemaVersion, structures = {} }
  for id, rec in pairs(health.byId) do
    data.structures[id] = {
      current = rec.current, max = rec.max,
      damaged = rec.damaged, destroyed = rec.destroyed, kind = rec.kind,
    }
  end
  return data
end

function M.write()
  if not net.isHost() then return end
  local ok, str = pcall(json.encode, M.serialize(), true)
  if not ok then log.warn("save encode failed: " .. tostring(str)); return end
  local f = io.open(M._path, "w")
  if not f then log.warn("cannot write save file (" .. tostring(M._path) .. ") — does save/ exist?"); return end
  f:write(str); f:close()
  log.info("mod state saved")
end

function M.read()
  local f = io.open(M._path, "r")
  if not f then return end
  local raw = f:read("*a"); f:close()
  local ok, data = pcall(json.decode, raw)
  if not ok or type(data) ~= "table" then log.warn("save parse failed"); return end
  if data.schema ~= M.schemaVersion then
    log.warn(string.format("save schema %s != %s; ignoring old fields", tostring(data.schema), tostring(M.schemaVersion)))
  end
  M._pending = data
  log.info("mod state loaded (reconciling as actors appear)")
end

-- Apply loaded state to a freshly-attached health record.
function M.restore(id, rec)
  if not M._pending or not M._pending.structures then return end
  local s = M._pending.structures[id]
  if not s then return end
  rec.current   = s.current or rec.current
  rec.max       = s.max or rec.max
  rec.damaged   = s.damaged or false
  rec.destroyed = s.destroyed or false
end

return M
