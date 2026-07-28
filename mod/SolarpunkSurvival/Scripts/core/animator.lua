-- The per-frame lane. core/scheduler.lua caps ALL deferred work at its 50ms tick -- correct for
-- game logic, hopeless for animation (the fishing skillshot marker stepped 6% of the bar per
-- update). This module is the one sanctioned bypass: its own LoopAsync ticker (registered ONCE at
-- init, from the main state -- the same proven pattern as the scheduler and dev/remote) arms at
-- most one game-thread hop at a time through the REAL ExecuteInGameThread the scheduler captured
-- before shadowing the global. Hops drain once per engine tick, so a small interval converges on
-- one job call per rendered frame; the 50ms queue is never involved.
--
-- SAFETY (the scheduler's rules, unchanged):
--   * the ticker thread touches ONLY Lua values and os.clock -- never a UObject;
--   * the job body runs on the game thread and must revalidate its own tokens/UObjects each call
--     (a level transition can kill widgets between any two frames);
--   * one job slot, one outstanding hop, a lost hop re-arms after HOP_LOST_S;
--   * NO log.guard/breadcrumbs anywhere on this path -- at frame rate that is 2 file writes per
--     frame (the old marker driver paid exactly that).
-- The ticker only arms hops while a job is active, so outside a minigame bar this lane is a
-- single table-nil check per tick -- and save loads (the historical abort window) never see it.
local M = { ok = false }

local job = nil          -- { fn = function(now) -> "stop"|nil, token = n } or nil
local nextToken = 1
local hopPending = false
local hopArmedAt = 0
local errStreak = 0
local HOP_LOST_S = 2.0   -- a hop that never ran by now is gone (level change ate it); re-arm
local MAX_ERRS = 3       -- consecutive job errors before the job is dropped

function M.init(log, postGameThread, tickMs)
  if M.ok then return true end
  if not (LoopAsync and postGameThread) then
    if log then log.warn("animator: LoopAsync/postGameThread missing -- per-frame lane disabled") end
    return false
  end
  local ms = math.max(4, math.floor(tonumber(tickMs) or 8))

  -- Allocated once; runs on the game thread. Everything per-frame lives here.
  local hopFn = function()
    hopPending = false
    local j = job
    if not j then return end
    local ok, res = pcall(j.fn, os.clock())
    if ok then
      errStreak = 0
      if res == "stop" and job == j then job = nil end
    else
      errStreak = errStreak + 1
      if errStreak >= MAX_ERRS then
        if job == j then job = nil end
        errStreak = 0
        if log then log.error("animator: job failed " .. MAX_ERRS .. "x, dropped: " .. tostring(res)) end
      end
    end
  end

  local armed = pcall(LoopAsync, ms, function()
    -- Lua values + clock ONLY on this thread (the proven native-crash rule).
    if not job then return false end
    if hopPending then
      if os.clock() - hopArmedAt > HOP_LOST_S then hopPending = false end
      return false
    end
    hopPending, hopArmedAt = true, os.clock()
    if not pcall(postGameThread, hopFn) then hopPending = false end
    return false -- keep ticking
  end)
  if not armed then
    if log then log.warn("animator: LoopAsync registration failed -- per-frame lane disabled") end
    return false
  end

  M.ok = true
  if log then log.info("animator: per-frame lane ready (" .. ms .. "ms ticker, idle when no job)") end
  return true
end

-- fn(now) runs on the game thread ~once per rendered frame. Contract: build the closure once
-- (never per frame), revalidate your own tokens/UObjects inside it, return "stop" to end.
-- One slot: starting a new job replaces any current one.
function M.start(fn)
  if not M.ok or type(fn) ~= "function" then return nil end
  local token = nextToken
  nextToken = nextToken + 1
  job = { fn = fn, token = token }
  return token
end

function M.stop(token)
  if job and job.token == token then job = nil end
end

function M.active() return job ~= nil end

return M
