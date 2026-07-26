-- Authority + replication helper for the host-authoritative listen-server.
-- All authoritative gameplay must run under net.isHost(); custom state that clients need
-- must live on the replicated BP_ModStateActor / BP_HealthState (Lua tables never replicate).
local uehelp = require("core.uehelp")
local log    = require("core.log")

local M = {}
M._map = nil
M._isHostCache = nil

function M.init(map)
  M._map = map
  return M
end

-- Best-effort host/authority check, cached. Refined once net.hasAuthorityFn is verified.
-- Never fabricates client authority: on failure it assumes host (single-player safe).
function M.isHost()
  if M._isHostCache ~= nil then return M._isHostCache end
  local pc = uehelp.playerController()
  local fn = M._map and M._map.net and M._map.net.hasAuthorityFn
  if pc and fn then
    local ok, res = uehelp.call(pc, fn)
    if ok and type(res) == "boolean" then
      M._isHostCache = res
      return res
    end
  end
  log.warn("authority undetermined; assuming host. Map/verify net.hasAuthorityFn to fix.")
  M._isHostCache = true
  return true
end

-- Call on level travel / session change so authority is re-evaluated.
function M.invalidate() M._isHostCache = nil end

-- The replicated global mod-state actor (from BP_ModStateActor.pak). nil until cooked+installed.
-- The miss is CACHED (retried once a minute): no LogicMod pak ships today, and the old shape ran
-- a full object-array FindFirstOf for this never-existing class on every telegraph AND every bolt
-- -- measurable host lag during a heavy storm for a lookup that can never succeed mid-session.
M._stateActorMissAt = nil
function M.stateActor()
  if M._stateActorMissAt and os.clock() - M._stateActorMissAt < 60 then return nil end
  local actor = uehelp.findFirst("BP_ModStateActor_C")
  M._stateActorMissAt = actor == nil and os.clock() or nil
  return actor
end

-- Multicast a transient effect to all clients via a replicated CustomEvent on the state actor.
-- Host-local no-op until the LogicMod pak exists (returns false).
function M.multicast(eventName, arg)
  local actor = M.stateActor()
  if not actor then
    log.debug("multicast('" .. tostring(eventName) .. "') skipped: no BP_ModStateActor")
    return false
  end
  local ok = uehelp.call(actor, eventName, arg)
  return ok
end

-- Whether the client-sync layer (replication carriers) is available yet.
function M.hasCarriers()
  return M.stateActor() ~= nil
end

return M
