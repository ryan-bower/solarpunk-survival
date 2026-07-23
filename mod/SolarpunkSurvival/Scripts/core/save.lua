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
M._flags = {}   -- durable key -> value facts (e.g. the Unlit's per-species unlocks)

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
  -- Load once up front: flags must be readable at feature init, before any actor exists.
  M.read()
  return M
end

function M.serialize()
  local data = { schema = M.schemaVersion, structures = {}, flags = M._flags }
  for id, rec in pairs(health.byId) do
    -- Never persist a DESTROYED record. idOf keys structures by a 0.5 m world grid, so a
    -- tombstone (destroyed=true) would be reapplied by M.restore to whatever new structure is
    -- later built in that cell -- and health.applyDamage early-returns on destroyed, making the
    -- rebuilt structure silently immune to lightning forever. A gone structure has no state to keep.
    if not rec.destroyed then
      data.structures[id] = {
        current = rec.current, max = rec.max,
        damaged = rec.damaged, destroyed = false, kind = rec.kind,
      }
    end
  end
  return data
end

-- Durable flags: read anywhere, written host-side (write() is host-gated).
function M.getFlag(key) return M._flags[key] end

function M.setFlag(key, value)
  if M._flags[key] == value then return end
  M._flags[key] = value
  M.write()
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
  local schemaOk = data.schema == M.schemaVersion
  if not schemaOk then
    log.warn(string.format("save schema %s != %s; ignoring old fields", tostring(data.schema), tostring(M.schemaVersion)))
  end
  M._pending = data
  -- Only carry flags forward on a matching schema: a version bump is how incompatible state
  -- (e.g. an evil-species unlock) is meant to be cleared, so a stale flags table must NOT survive it.
  if schemaOk and type(data.flags) == "table" then
    for k, v in pairs(data.flags) do
      if M._flags[k] == nil then M._flags[k] = v end
    end
  end
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
