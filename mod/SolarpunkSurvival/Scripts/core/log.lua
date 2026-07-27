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

-- CRASH BREADCRUMBS.
--
-- A native access violation kills the process outright: no Lua error, no pcall, nothing in the
-- log that was still buffered. The only way to learn WHICH piece of mod code was running when it
-- died is to have written that name to disk *before* running it. Hence a plain append-and-close
-- per step -- an open handle would lose its buffer in exactly the crash we are chasing.
--
-- `step()` is deliberately free until armed: no module root, no arming, no file. main.lua arms it
-- once it knows where dump/ is; core/config sets the flag. Everything guarded below writes one
-- line, which makes the LAST line of dump/steps_crash.txt the name of the code that died.
local stepPath = nil
local riskyDir = nil
local stepVerbose = false

function M.armSteps(modRoot, on, verbose)
  riskyDir = (modRoot or "") .. "dump/"
  stepVerbose = verbose == true
  stepPath = on and ((modRoot or "") .. "dump/steps_crash.txt") or nil
  if stepPath then
    pcall(function()
      local f = io.open(stepPath, "a")
      if f then f:write("\n=== session " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===\n"); f:close() end
    end)
  end
end

local lastStep = nil

function M.step(s)
  if not stepPath then return end
  s = tostring(s)
  -- Some hooked functions fire per frame (the build previews are the worst). Collapsing a run of
  -- the same name keeps the file honest -- the last line still names what died -- without turning
  -- a crash hunt into a stutter.
  if s == lastStep then return end
  lastStep = s
  pcall(function()
    local f = io.open(stepPath, "a")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
  end)
end

-- A step that is only worth its open-write-close when the trail is being read line by line.
-- Object-construction notifies are the case this exists for: a save load streams in hundreds of
-- Characters, and one file write per listener per actor buries the rest of the trail AND slows
-- the exact seconds we are trying to keep quiet. Off unless step_log_notify is set.
function M.stepv(s)
  if stepVerbose then M.step(s) end
end

-- THE POISON LATCH.
--
-- Some engine calls cannot be made safe from Lua. pcall does not catch an access violation, so a
-- single bad UFunction call takes the whole game down -- and the next launch makes the same call
-- and takes it down again. This turns that into a ONE-TIME cost: drop a marker file, make the
-- call, delete the marker. A marker still on disk at startup means the process died inside that
-- exact call, so it is never attempted again.
--
-- Tag per THING attempted, not per call site (e.g. the material being tried), so a poisoned
-- attempt only rules out the thing that killed us and the caller can move on to the next candidate.
local poisoned = {}

local function riskyPath(tag)
  return riskyDir .. "risky_" .. tostring(tag):gsub("[^%w_%-%.]", "_") .. ".txt"
end

function M.isPoisoned(tag)
  if not riskyDir then return false end
  if poisoned[tag] ~= nil then return poisoned[tag] end
  local f = io.open(riskyPath(tag), "r")
  poisoned[tag] = f ~= nil
  if f then f:close() end
  if poisoned[tag] then
    M.warn("'" .. tostring(tag) .. "' killed the game last time it ran -- skipping it this session")
  end
  return poisoned[tag]
end

-- Returns ok, result. ok is false if the tag is poisoned or fn errored.
function M.risky(tag, fn)
  if not riskyDir then return pcall(fn) end   -- no dump dir to latch with; caller accepts the risk
  if M.isPoisoned(tag) then return false, "poisoned" end
  local p = riskyPath(tag)
  pcall(function()
    local f = io.open(p, "w")
    if f then f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n"); f:close() end
  end)
  local ok, res = pcall(fn)
  pcall(os.remove, p)                          -- survived: cleared, and cleared for every future run
  return ok, res
end

-- Wrap a callback so a failure is logged once and never propagates into the game thread.
-- After `maxFails` failures the callback is disabled (returns without running) to avoid log spam.
-- Every hook body in the mod comes through here, so the breadcrumb above covers them all at once.
function M.guard(name, fn, maxFails)
  local fails = 0
  local disabled = false
  maxFails = maxFails or 10
  return function(...)
    if disabled then return end
    -- "> name" on the way in, "< name" on the way out. The pair is what makes the trail readable:
    -- a file ending in "> x" died INSIDE x, one ending in "< x" died after it returned -- in
    -- deferred work, which is a different bug with a different fix.
    if stepPath then M.step("> " .. tostring(name)) end
    local ok, err = pcall(fn, ...)
    if stepPath then M.step("< " .. tostring(name)) end
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
