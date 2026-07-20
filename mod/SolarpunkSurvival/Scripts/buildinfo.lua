-- Runtime game-build detection + mapping-profile selection.
local mapping = require("mapping")
local config  = require("core.config")

local M = {}

-- The last build this mod was tested/mapped against (see manifest.json).
M.KNOWN_TESTED = "24038177"

-- Determine the current game build id.
--   1) explicit `game_build` override in config.json
--   2) TODO: read a version property off a mapped game UObject once available
--   3) fall back to the last tested build (flagged as "assumed")
function M.detect()
  local override = config.get("game_build")
  if override ~= nil then return tostring(override), "config" end
  -- TODO(RE): once a version accessor is mapped, read it here.
  return M.KNOWN_TESTED, "assumed"
end

function M.init()
  M.buildId, M.buildSource = M.detect()
  M.map, M.knownBuild = mapping.resolve(M.buildId)
  M.missing = mapping.missing(M.map)
  M.degraded = (not M.knownBuild) or (#M.missing > 0)
  return M
end

-- One-line human summary for the startup banner / ImGui.
function M.summary()
  return string.format("build %s (%s) — %s, %d symbol(s) unmapped",
    tostring(M.buildId), tostring(M.buildSource),
    M.knownBuild and "known" or "UNKNOWN profile",
    M.missing and #M.missing or 0)
end

return M
