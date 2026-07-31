-- Authority + replication helper for the host-authoritative listen-server.
-- All authoritative gameplay must run under net.isHost(); custom state that clients need
-- must live on the replicated BP_ModStateActor / BP_HealthState (Lua tables never replicate).
local uehelp = require("core.uehelp")
local log    = require("core.log")

local M = {}
M._map = nil
M._isHostCache = nil
M._isHostKey = nil

function M.init(map)
  M._map = map
  return M
end

-- Best-effort host/authority check. Never fabricates client authority: with no controller to ask
-- it reports the last known answer (or host, single-player safe) WITHOUT caching it.
--
-- The cache is keyed by the controller's full object path, which embeds the world -- so a menu
-- answer can never leak into a joined session. This is load-bearing for real clients: the mod
-- boots at the main menu, where the local controller IS the authority (standalone world), and a
-- session-lifetime cache primed there reported isHost=true for the whole session. Nobody ever
-- called invalidate() on travel, so on a machine that then JOINED someone else's game every
-- host-gated feature ran as if it were the server (proven live 2026-07-31 on the two-instance
-- rig: cached true, fresh HasAuthority false).
function M.isHost()
  local pc = uehelp.playerController()
  local key
  if pc then pcall(function() key = pc:GetFullName() end) end
  if key and key == M._isHostKey and M._isHostCache ~= nil then return M._isHostCache end
  local fn = M._map and M._map.net and M._map.net.hasAuthorityFn
  if pc and key and fn then
    local ok, res = uehelp.call(pc, fn)
    if ok and type(res) == "boolean" then
      M._isHostCache, M._isHostKey = res, key
      return res
    end
  end
  if M._isHostCache ~= nil then return M._isHostCache end
  log.warn("authority undetermined; assuming host. Map/verify net.hasAuthorityFn to fix.")
  return true
end

-- Kept for callers that want an explicit re-evaluation (the fullname key already self-invalidates
-- across worlds). Also drops the state-actor miss: the new level spawns its own BP_ModStateActor,
-- and a miss cached in the old one (or on the menu) would keep multicast()/hasCarriers() dark for
-- the first minute of the new world -- exactly the opening storm the carrier exists to serve.
function M.invalidate()
  M._isHostCache = nil
  M._isHostKey = nil
  M._stateActorMissAt = nil
end

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
