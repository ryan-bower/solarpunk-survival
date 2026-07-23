-- One stable dispatcher for ALL deferred work (the Abort-crash fix, 2026-07-22).
--
-- WHY (PDB-symbolicated UECC dump, three aborts in one evening -- 20:06, 20:57, 21:47):
--   engine_tick_hook -> process_simple_actions -> LuaMadeSimple::Registry::get_function_ref
--   -> luaL_error -> luaD_throw -> abort()
-- UE4SS's ExecuteWithDelay/ExecuteInGameThread store the callback as a function ref in the
-- registry of the LUA THREAD THAT CALLED THEM. RegisterHook / NotifyOnNewObject callbacks run
-- in transient hook threads -- when one is collected before its delayed action fires,
-- get_function_ref throws with NO error handler on the C stack and the process aborts. The
-- mod schedules delays from hook context constantly (rig heals, transmute re-reads, bolt
-- impact timers), so every strike/equips window was a dice roll.
--
-- FIX: this module shadows the two globals. A scheduled action becomes a PLAIN Lua value in
-- a queue table -- no per-call registry ref exists at all. One LoopAsync ticker (registered
-- ONCE at init, from the main state -- the same pattern dev/remote.lua has always used
-- safely) drains due actions and hops to the game thread through the REAL
-- ExecuteInGameThread captured at init. Call sites keep their exact API and semantics:
-- actions may fire up to one tick (~50ms) later than before, nothing else changes.
--
-- SAFETY: the ticker itself touches only Lua tables and os.clock -- never a UObject (the
-- proven native-crash rule); all queued actions run on the game thread inside the hop.
local M = {}

local TICK_MS = 50
local queue = {}   -- array of { due = os.clock() seconds, fn = function }; drained slots hold false
local deadSlots = 0

function M.init(log)
  local realLoop = LoopAsync
  local realEIGT = ExecuteInGameThread
  if not (realLoop and realEIGT) then
    if log then log.warn("scheduler: LoopAsync/ExecuteInGameThread missing -- engine primitives kept") end
    return false
  end

  ExecuteWithDelay = function(ms, fn)
    if type(fn) ~= "function" then return end
    queue[#queue + 1] = { due = os.clock() + (tonumber(ms) or 0) / 1000, fn = fn }
  end
  ExecuteInGameThread = function(fn)
    if type(fn) ~= "function" then return end
    queue[#queue + 1] = { due = 0, fn = fn }
  end

  pcall(realLoop, TICK_MS, function()
    -- Lua tables + clock ONLY on this thread; UObjects are game-thread only.
    if #queue > 0 then
      local now = os.clock()
      local due
      -- NEVER rebuild `queue` from a snapshot: a hook thread appends with `queue[#queue + 1]`
      -- while this walk runs, and reassigning the table threw those actions away silently.
      -- Instead mark drained slots `false` (a value, so the array stays dense and `#` stays
      -- correct for appenders) and compact only on a tick where nothing was appended.
      local n = #queue
      for i = 1, n do
        local e = queue[i]
        if e and e.due <= now then
          due = due or {}; due[#due + 1] = e.fn
          queue[i] = false
        end
      end
      if due then
        -- Compact on a quiet tick. If appends keep landing mid-walk we skip it and try again
        -- next tick; `deadSlots` is the backstop so a busy hook storm cannot grow the array
        -- without bound (then we compact the whole live table, appends included).
        local appended = #queue - n
        deadSlots = deadSlots + #due
        if appended == 0 or deadSlots > 256 then
          local w, last = 0, #queue
          for i = 1, last do
            local e = queue[i]
            if e then w = w + 1; queue[w] = e end
          end
          for i = last, w + 1, -1 do queue[i] = nil end
          deadSlots = 0
        end
        pcall(realEIGT, function()
          for i = 1, #due do
            local ok, err = pcall(due[i])
            if not ok and log then log.warn("scheduler: deferred action failed: " .. tostring(err)) end
          end
        end)
      end
    end
    return false -- keep ticking
  end)

  if log then
    log.info("scheduler: deferred work centralized (" .. TICK_MS .. "ms ticker; no hook-thread refs)")
  end
  return true
end

return M
