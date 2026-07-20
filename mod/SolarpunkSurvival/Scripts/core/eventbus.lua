-- Tiny synchronous pub/sub. The decoupling layer between systems.
--
-- Canonical topics:
--   weather.changed    { storm=bool, severity=0..1 }
--   storm.warning      { lead=seconds }
--   lightning.telegraph{ location, radius, lead }
--   lightning.strike   { location }                       (bolt landed, pre-classification)
--   strike.player      { actor, id, location }
--   strike.crop        { actor, id, location }
--   strike.battery     { actor, id, location }
--   strike.machine     { actor, id, location }
--   strike.structure   { actor, id, location }
--   strike.airship     { actor, id, location }
--   strike.rod         { actor, id, location, battery }
--   damage.applied     { id, rec, amount, ctx }
--   structure.damaged  { id, rec }        structure.repaired { id, rec }
--   entity.destroyed   { id, rec, ctx }
--   player.died        { actor, id }
--   config.changed     { key, value }
--   save.write {}   save.read {}
local log = require("core.log")
local M = {}
local subs = {}

function M.on(topic, fn)
  subs[topic] = subs[topic] or {}
  table.insert(subs[topic], fn)
  return fn
end

function M.off(topic, fn)
  local list = subs[topic]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == fn then table.remove(list, i) end
  end
end

function M.emit(topic, payload)
  local list = subs[topic]
  if not list then return end
  for i = 1, #list do
    local ok, err = pcall(list[i], payload)
    if not ok then
      log.error(string.format("subscriber for '%s' failed: %s", topic, tostring(err)))
    end
  end
end

return M
