-- Health / damage component the game lacks. Host-authoritative. Records are keyed by
-- identity.idOf(actor) so they survive save/load and match across the network.
local bus      = require("core.eventbus")
local net      = require("core.net")
local identity = require("core.identity")

local M = {}
M.byId = {}   -- id -> { id, actor, max, current, kind, twoHit, damaged, destroyed }

-- opts: { max, kind, twoHit }
function M.attach(actor, opts)
  local id = identity.idOf(actor)
  if not id then return nil end
  opts = opts or {}
  local rec = M.byId[id]
  if not rec then
    local max = opts.max or 100
    rec = {
      id = id, actor = actor, max = max, current = max,
      kind = opts.kind or "structure", twoHit = opts.twoHit or false,
      damaged = false, destroyed = false,
    }
    M.byId[id] = rec
    bus.emit("health.attached", { id = id, rec = rec })
  else
    rec.actor = actor -- refresh possibly-stale pointer
  end
  return rec
end

function M.get(id) return M.byId[id] end

-- Host-authoritative damage entry. Clients must route requests through the state actor, never here.
function M.applyDamage(id, amount, ctx)
  if not net.isHost() then return nil end
  local rec = M.byId[id]
  if not rec or rec.destroyed then return rec end
  ctx = ctx or {}

  -- Two-hit machines (drills/sprinklers): first lightning hit -> smoking; second -> destroyed.
  if rec.twoHit and ctx.source == "lightning" then
    if not rec.damaged then
      rec.damaged = true
      rec.current = math.min(rec.current, rec.max * 0.5)
      bus.emit("damage.applied", { id = id, rec = rec, amount = amount, ctx = ctx })
      bus.emit("structure.damaged", { id = id, rec = rec })
      return rec
    end
    rec.current = 0
  else
    rec.current = math.max(0, rec.current - (amount or 0))
  end

  bus.emit("damage.applied", { id = id, rec = rec, amount = amount, ctx = ctx })
  if rec.current <= 0 and not rec.destroyed then
    rec.destroyed = true
    bus.emit("entity.destroyed", { id = id, rec = rec, ctx = ctx })
  end
  return rec
end

-- Clear the damaged/smoking state (used by the Storm Repair Tool).
function M.repair(id)
  local rec = M.byId[id]
  if not rec or rec.destroyed then return false end
  rec.damaged = false
  rec.current = rec.max
  bus.emit("structure.repaired", { id = id, rec = rec })
  return true
end

function M.heal(id, amount)
  local rec = M.byId[id]
  if not rec or rec.destroyed then return end
  rec.current = math.min(rec.max, rec.current + (amount or 0))
end

function M.forget(id) M.byId[id] = nil end

return M
