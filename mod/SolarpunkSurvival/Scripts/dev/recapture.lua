-- Reverse-engineering capture tool. Streams live game symbols to a file so mapping.lua can be
-- filled from real classes/functions/properties.
--
-- SAFETY (learned the hard way -- three native crashes):
--   * pcall does NOT catch a native access violation. Calling a reflected member function on a bad
--     UObject pointer hard-crashes the game past every pcall.
--   * So this tool only ever touches objects returned live from FindFirstOf/FindAllOf, and reads
--     ONLY names (GetFName) off UClass reflection. It does NOT read instance property *values* and
--     does NOT probe type-specific property getters (GetPropertyClass/GetMetaClass/GetStruct/...):
--     those return a garbage pointer when called on the wrong property type, and reading it crashes.
--   * There is NO background/auto timer -- a periodic loop that touches UObjects crashes during
--     menu/level transitions. Capture is MANUAL only, triggered when you are standing still.
--   * Output is streamed with a flush after every line, so if anything still faults you get a
--     partial file whose LAST line names exactly what was being processed.
--
-- What it captures: the singleton ANCHORS (pawn, controller, player state, game state/mode, game
-- instance) with their function/property names; DataTable/DataAsset instance names; and every
-- distinct live Actor class with its function/property names.
--
-- Triggers: F8 keybind, or console `sps_dump` / `sps_find <substr>`.
-- Output: dump/re_capture_latest.txt (streamed) -> copied to re_capture_<stamp>.txt + re_capture.txt.
local F = {}
local ctx

local function onGameThread(fn)
  if ExecuteInGameThread then
    local ok = pcall(ExecuteInGameThread, fn)
    if ok then return end
  end
  pcall(fn)
end

local function classOf(obj)
  local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
  if ok then return n end
  return nil
end

local function nameOf(obj)
  local ok, n = pcall(function() return obj:GetFName():ToString() end)
  if ok then return n end
  return nil
end

-- Dump a live UClass's member NAMES only (safe: reflection on a valid UClass, no value reads).
local function dumpClass(cls, emit, indent)
  indent = indent or "    "
  pcall(function()
    if cls.ForEachFunction then
      cls:ForEachFunction(function(fn)
        local ok, n = pcall(function() return fn:GetFName():ToString() end)
        if ok and n then emit(indent .. "fn   " .. n) end
      end)
    end
  end)
  pcall(function()
    if cls.ForEachProperty then
      cls:ForEachProperty(function(pr)
        local ok, n = pcall(function() return pr:GetFName():ToString() end)
        if ok and n then emit(indent .. "prop " .. n) end
      end)
    end
  end)
end

local function dumpAnchor(label, obj, emit)
  if not obj then emit("ANCHOR " .. label .. " = <none>"); return end
  local cn = classOf(obj)
  if not cn then emit("ANCHOR " .. label .. " = <unreadable>"); return end
  emit("")
  emit("ANCHOR " .. label .. " : " .. cn)
  local ok, cls = pcall(function() return obj:GetClass() end)
  if ok and cls then dumpClass(cls, emit, "    ") end
end

local function captureNamed(baseClass, emit)
  local arr = ctx.uehelp.findAll(baseClass)
  if #arr == 0 then return end
  emit("")
  emit("# " .. baseClass .. " instances (" .. #arr .. "):")
  local names, seen = {}, {}
  for _, o in ipairs(arr) do
    local nm = nameOf(o)
    if nm and not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
  end
  table.sort(names)
  for _, nm in ipairs(names) do emit("  " .. baseClass .. " " .. nm) end
end

-- Actors: emit each distinct live class + member names, streaming as we go.
local function captureActors(emit)
  local actors = ctx.uehelp.findAll("Actor")
  emit("# live Actor instances scanned: " .. tostring(#actors))
  local seen = {}
  for _, a in ipairs(actors) do
    local cn = classOf(a)
    if cn and not seen[cn] then
      seen[cn] = true
      emit("CLASS " .. cn)
      local ok, cls = pcall(function() return a:GetClass() end)
      if ok and cls then dumpClass(cls, emit, "    ") end
    end
  end
end

function F.writeDump(tag)
  local dir = (ctx.modRoot or "") .. "dump/"
  local latest = dir .. "re_capture_latest.txt"
  local f = io.open(latest, "w")
  if not f then ctx.log.warn("recapture: cannot open " .. latest); return end
  local n = 0
  local function emit(line)
    f:write(line); f:write("\n"); f:flush() -- flush every line: a crash leaves a pinpoint partial
    n = n + 1
  end

  local okd, d = pcall(os.date, "%c")
  emit("# SolarpunkSurvival RE capture  [" .. tostring(tag or "manual") .. "]  " .. (okd and d or ""))
  emit("# build: " .. tostring(ctx.buildinfo and ctx.buildinfo.buildId or "?"))

  emit(""); emit("########## ANCHORS ##########")
  local pc = ctx.uehelp.playerController()
  local pawn = ctx.uehelp.localPawn()
  local ps = nil
  if pc then local okp, v = pcall(function() return pc.PlayerState end); if okp and ctx.uehelp.isValid(v) then ps = v end end
  dumpAnchor("PlayerPawn", pawn, emit)
  dumpAnchor("PlayerController", pc, emit)
  dumpAnchor("PlayerState", ps, emit)
  dumpAnchor("GameState", ctx.uehelp.findFirst("GameStateBase") or ctx.uehelp.findFirst("GameState"), emit)
  dumpAnchor("GameMode", ctx.uehelp.findFirst("GameModeBase") or ctx.uehelp.findFirst("GameMode"), emit)
  dumpAnchor("GameInstance", ctx.uehelp.findFirst("GameInstance"), emit)

  emit(""); emit("########## DATA ##########")
  captureNamed("DataTable", emit)
  captureNamed("DataAsset", emit)

  emit(""); emit("########## ACTOR CLASSES ##########")
  captureActors(emit)

  emit(""); emit("# END OK")
  f:close()

  -- Success: mirror to timestamped + back-compat names.
  local stamp = os.date("%Y%m%d_%H%M%S") or tostring(n)
  local blob
  do local rf = io.open(latest, "r"); if rf then blob = rf:read("*a"); rf:close() end end
  if blob then
    for _, p in ipairs({ dir .. "re_capture_" .. stamp .. ".txt", dir .. "re_capture.txt" }) do
      local wf = io.open(p, "w"); if wf then wf:write(blob); wf:close() end
    end
  end
  ctx.log.info(string.format("recapture[%s]: wrote %d lines -> dump/re_capture_latest.txt (send it back)", tostring(tag), n))
end

-- Filtered class-name search (for sps_find). Names only; safe.
function F.find(sub)
  if sub then sub = sub:lower() end
  local actors = ctx.uehelp.findAll("Actor")
  local names, seen = {}, {}
  for _, a in ipairs(actors) do
    local cn = classOf(a)
    if cn and not seen[cn] and (not sub or cn:lower():find(sub, 1, true)) then
      seen[cn] = true; names[#names + 1] = cn
    end
  end
  table.sort(names)
  ctx.log.info("recapture: classes matching '" .. tostring(sub) .. "' (" .. #names .. "):")
  for _, nm in ipairs(names) do ctx.log.info("   " .. nm) end
end

function F.init(c)
  ctx = c
  pcall(function()
    RegisterConsoleCommandHandler("sps_dump", function() onGameThread(function() F.writeDump("manual") end); return true end)
    RegisterConsoleCommandHandler("sps_find", function(_, p) onGameThread(function() F.find(p and p[1] or "") end); return true end)
  end)
  pcall(function()
    if RegisterKeyBind and Key and Key.F8 then
      RegisterKeyBind(Key.F8, function() onGameThread(function() F.writeDump("F8") end) end)
    end
  end)
  ctx.log.info("recapture: in a loaded world (standing still), press F8 or run `sps_dump` to capture")
  return true
end

return F
