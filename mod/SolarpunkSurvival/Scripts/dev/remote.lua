-- Remote file-command channel for dev / reverse-engineering.
--
-- Lets the developer drive the running game by writing ONE command line to  <mod>/dump/cmd.txt .
-- The mod runs it and writes output to  <mod>/dump/result.txt . No keybind or console needed.
--
-- SAFETY: the poll loop only ever touches the FILESYSTEM (io/os) -- never a UObject -- so it is
-- safe across menu/level transitions (the thing that native-crashes is touching a UObject on a
-- background tick). The dispatched command DOES touch UObjects, so only write cmd.txt while you are
-- standing still in a loaded world.
--
-- Commands (write to dump/cmd.txt):
--   dump                              full RE capture (dev.recapture)
--   sig <substr>                      signatures (ordered param names) of anchor functions matching <substr>
--   rows <PropName>                   row names of the DataTable at GameInstance.<PropName>  (e.g. rows DB_Items)
--   get  <ShortClass> <Prop>          read a property value (best-effort) off a found instance
--   call <ShortClass> <Fn> [args..]   call a reflected function with scalar args (num/true/false/string|FName)
local F = {}
local ctx
local busy = false
local out = {}

local function emit(s) out[#out + 1] = tostring(s) end

local function readFile(p) local f = io.open(p, "r"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function writeFile(p, s) local f = io.open(p, "w"); if not f then return false end f:write(s); f:close(); return true end

local function anchors()
  local pc = ctx.uehelp.playerController()
  return {
    { "PlayerPawn",       ctx.uehelp.localPawn() },
    { "PlayerController",  pc },
    { "GameState",         ctx.uehelp.findFirst("GameStateBase") or ctx.uehelp.findFirst("GameState") },
    { "GameMode",          ctx.uehelp.findFirst("GameModeBase") or ctx.uehelp.findFirst("GameMode") },
    { "GameInstance",      ctx.uehelp.findFirst("GameInstance") },
  }
end

-- Ordered param names of a UFunction (reflection only; safe). Marks the return value.
local function fnParams(fn)
  local params = {}
  pcall(function()
    if fn.ForEachProperty then
      fn:ForEachProperty(function(pr)
        local ok, n = pcall(function() return pr:GetFName():ToString() end)
        if ok and n then
          local tag = ""
          pcall(function() if pr:HasAnyPropertyFlags(0x0000000000000400) then tag = "=ret" end end) -- CPF_ReturnParm
          params[#params + 1] = n .. (tag ~= "" and (" " .. tag) or "")
        end
      end)
    end
  end)
  return params
end

local function cmd_sig(sub)
  sub = (sub or ""):lower()
  for _, a in ipairs(anchors()) do
    local label, obj = a[1], a[2]
    if obj then
      local cn = ctx.uehelp.className(obj) or "?"
      local ok, cls = pcall(function() return obj:GetClass() end)
      if ok and cls then
        pcall(function()
          cls:ForEachFunction(function(fn)
            local okn, n = pcall(function() return fn:GetFName():ToString() end)
            if okn and n and (sub == "" or n:lower():find(sub, 1, true)) then
              local ps = fnParams(fn)
              emit(label .. " [" .. cn .. "] :: " .. n .. "(" .. table.concat(ps, ", ") .. ")")
            end
          end)
        end)
      end
    end
  end
  if #out == 0 then emit("(no matching functions)") end
end

-- Iterate a UE4SS array result across the API variants (ForEach vs numeric index).
local function forEachArray(arr, cb)
  local ok = pcall(function()
    if type(arr) == "table" or arr.ForEach then
      if arr.ForEach then arr:ForEach(function(_, e)
          local v = e
          pcall(function() v = e:get() end)
          cb(v)
        end)
      else
        for _, v in ipairs(arr) do cb(v) end
      end
      return
    end
    error("no-foreach")
  end)
  if not ok then
    pcall(function()
      local n = #arr
      for i = 1, n do cb(arr[i]) end
    end)
  end
end

local function toStr(v)
  local ok, s = pcall(function() return v:ToString() end)
  if ok and s then return s end
  return tostring(v)
end

local function cmd_rows(propName)
  if not propName then emit("usage: rows <PropName>"); return end
  local gi = ctx.uehelp.findFirst("GameInstance")
  if not gi then emit("no GameInstance"); return end
  local okv, dt = pcall(function() return gi[propName] end)
  if not okv or not dt then emit("no property " .. tostring(propName) .. " on GameInstance"); return end
  emit("prop " .. propName .. " class=" .. (ctx.uehelp.className(dt) or "?"))
  local count = 0
  -- 1) reflected GetRowNames on the datatable
  pcall(function()
    if dt.GetRowNames then
      local names = dt:GetRowNames()
      if names then forEachArray(names, function(rn) count = count + 1; emit("  row " .. toStr(rn)) end) end
    end
  end)
  -- 2) fallback: DataTableFunctionLibrary CDO
  if count == 0 and StaticFindObject then
    pcall(function()
      local fl = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
      if fl and fl.GetDataTableRowNames then
        local names = fl:GetDataTableRowNames(dt)
        if names then forEachArray(names, function(rn) count = count + 1; emit("  row " .. toStr(rn)) end) end
      end
    end)
  end
  emit("  (" .. count .. " rows)")
end

-- Enumerate rows of the actual UDataTable asset whose object name matches <sub>.
local function cmd_dtrows(sub)
  if not sub then emit("usage: dtrows <NameSubstr>"); return end
  local tables = ctx.uehelp.findAll("DataTable")
  local target, tname
  for _, dt in ipairs(tables) do
    local ok, on = pcall(function() return dt:GetFName():ToString() end)
    if ok and on and on:lower():find(sub:lower(), 1, true) then target, tname = dt, on; break end
  end
  if not target then emit("no DataTable matching '" .. sub .. "' (" .. #tables .. " tables live)"); return end
  emit("DataTable " .. tname)
  local count = 0
  pcall(function()
    if target.GetRowNames then
      local names = target:GetRowNames()
      if names then forEachArray(names, function(rn) count = count + 1; emit("  " .. toStr(rn)) end) end
    end
  end)
  if count == 0 and StaticFindObject then
    pcall(function()
      local fl = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
      if fl and fl.GetDataTableRowNames then
        local names = fl:GetDataTableRowNames(target)
        if names then forEachArray(names, function(rn) count = count + 1; emit("  " .. toStr(rn)) end) end
      end
    end)
  end
  emit("(" .. count .. " rows)")
end

-- Dump the keys of a Map/Set/Array property (e.g. GameInstance.DB_Items name->struct map).
local function cmd_mapkeys(cls, prop)
  if not cls or not prop then emit("usage: mapkeys <ShortClass> <Prop>"); return end
  local obj = ctx.uehelp.findFirst(cls)
  if not obj then emit("no instance of " .. cls); return end
  local ok, m = pcall(function() return obj[prop] end)
  if not ok or m == nil then emit("no prop " .. tostring(prop)); return end
  local count = 0
  local okFE = pcall(function()
    if m.ForEach then
      m:ForEach(function(k, _)
        local ks = k
        pcall(function() ks = k:get() end)
        pcall(function() ks = ks:ToString() end)
        emit("  " .. tostring(ks)); count = count + 1
      end)
      return
    end
    error("no-foreach")
  end)
  if not okFE and type(m) == "table" then
    for k in pairs(m) do emit("  " .. tostring(k)); count = count + 1 end
  end
  emit("(" .. count .. " keys)")
end

local function cmd_get(cls, prop)
  if not cls or not prop then emit("usage: get <ShortClass> <Prop>"); return end
  local obj = ctx.uehelp.findFirst(cls)
  if not obj then emit("no instance of " .. cls); return end
  local ok, v = pcall(function() return obj[prop] end)
  if not ok then emit("read failed: " .. tostring(v)); return end
  local cn
  pcall(function() cn = v:GetClass():GetFName():ToString() end)
  emit(cls .. "." .. prop .. " = " .. tostring(v) .. (cn and ("  <" .. cn .. ">") or ""))
end

local function parseArg(s)
  if s == "true" then return true elseif s == "false" then return false end
  local n = tonumber(s); if n ~= nil then return n end
  return s
end

local function cmd_call(cls, fn, parts)
  if not cls or not fn then emit("usage: call <ShortClass> <Fn> [args..]"); return end
  local obj = ctx.uehelp.findFirst(cls)
  if not obj then emit("no instance of " .. cls); return end
  local args = {}
  for i = 4, #parts do args[#args + 1] = parseArg(parts[i]) end
  local ok, res = ctx.uehelp.call(obj, fn, table.unpack(args))
  emit("call " .. cls .. "::" .. fn .. "(" .. #args .. " args) -> ok=" .. tostring(ok) .. " res=" .. tostring(res))
end

-- Runs on the game thread (touches UObjects). Never called from the poll tick directly.
local function dispatch(line)
  out = {}
  local parts = {}
  for w in line:gmatch("%S+") do parts[#parts + 1] = w end
  emit("# cmd: " .. line:gsub("%s+$", ""))
  local c = (parts[1] or ""):lower()
  local ok, err = pcall(function()
    if c == "dump" then
      local rc = require("dev.recapture"); rc.writeDump("remote"); emit("dumped -> dump/re_capture_latest.txt")
    elseif c == "sig" then cmd_sig(parts[2])
    elseif c == "rows" then cmd_rows(parts[2])
    elseif c == "dtrows" then cmd_dtrows(parts[2])
    elseif c == "mapkeys" then cmd_mapkeys(parts[2], parts[3])
    elseif c == "get" then cmd_get(parts[2], parts[3])
    elseif c == "call" then cmd_call(parts[2], parts[3], parts)
    elseif c == "exec" then
      -- Run arbitrary Lua from dump/exec.lua with `emit`, `ctx`, `print` in scope. Ultimate RE hook.
      local path = (ctx.modRoot or "") .. "dump/exec.lua"
      local env = setmetatable({ emit = emit, ctx = ctx,
        print = function(...) local t = table.pack(...); local s = {}; for i = 1, t.n do s[i] = tostring(t[i]) end; emit(table.concat(s, "\t")) end },
        { __index = _G })
      local chunk, lerr = loadfile(path, "t", env)
      if not chunk then emit("exec load error: " .. tostring(lerr))
      else
        local ok2, r = pcall(chunk)
        if not ok2 then emit("exec runtime error: " .. tostring(r))
        elseif r ~= nil then emit("returned: " .. tostring(r)) end
      end
    else emit("unknown cmd: " .. tostring(c)) end
  end)
  if not ok then emit("ERROR: " .. tostring(err)) end
  writeFile((ctx.modRoot or "") .. "dump/result.txt", table.concat(out, "\n") .. "\n")
  ctx.log.info("remote: ran '" .. c .. "' -> dump/result.txt")
  busy = false
end

function F.init(c)
  ctx = c
  local cmdPath = (ctx.modRoot or "") .. "dump/cmd.txt"
  if LoopAsync then
    pcall(LoopAsync, 1000, function()
      -- FILESYSTEM ONLY here -- safe on every tick.
      if not busy then
        local s = readFile(cmdPath)
        if s and s:gsub("%s", "") ~= "" then
          os.remove(cmdPath)
          busy = true
          local line = s
          if ExecuteInGameThread then pcall(ExecuteInGameThread, function() dispatch(line) end) else dispatch(line) end
        end
      end
      return false -- keep polling
    end)
    ctx.log.info("remote: file-command channel ready (write dump/cmd.txt -> read dump/result.txt)")
  else
    ctx.log.warn("remote: LoopAsync unavailable; channel disabled")
  end
  return true
end

return F
