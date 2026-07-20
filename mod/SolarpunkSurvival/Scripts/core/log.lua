-- Logging with a circuit-breaking guard wrapper.
-- Everything user-facing goes through UE4SS's print(), which lands in its console + log file.
local M = {}

local PREFIX = "[SolarpunkSurvival]"
local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
M.level = LEVELS.info

function M.setLevel(name)
  if LEVELS[name] then M.level = LEVELS[name] end
end

local function emit(lvl, tag, msg)
  if LEVELS[lvl] < M.level then return end
  local line = string.format("%s [%s] %s", PREFIX, tag, tostring(msg))
  if not pcall(print, line) then pcall(io.write, line .. "\n") end
end

function M.debug(msg) emit("debug", "DBG", msg) end
function M.info(msg)  emit("info",  "INF", msg) end
function M.warn(msg)  emit("warn",  "WRN", msg) end
function M.error(msg) emit("error", "ERR", msg) end

-- Wrap a callback so a failure is logged once and never propagates into the game thread.
-- After `maxFails` failures the callback is disabled (returns without running) to avoid log spam.
function M.guard(name, fn, maxFails)
  local fails = 0
  local disabled = false
  maxFails = maxFails or 10
  return function(...)
    if disabled then return end
    local ok, err = pcall(fn, ...)
    if not ok then
      fails = fails + 1
      M.error(string.format("'%s' failed (%d/%d): %s", tostring(name), fails, maxFails, tostring(err)))
      if fails >= maxFails then
        disabled = true
        M.error(string.format("'%s' disabled after %d failures", tostring(name), maxFails))
      end
    end
  end
end

return M
