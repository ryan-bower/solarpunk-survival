-- Reverse-engineering capture tool. Enumerates live actor classes (and their functions/
-- properties) to a file so mapping.lua can be filled in from real game symbols.
--
-- Usage in-game (UE4SS console): load your save, make the thing exist (start a storm, place a
-- build piece, board the airship, ...), then run:
--   sps_dump              -> writes dump/re_capture.txt (all live actor classes + members)
--   sps_find <substr>     -> prints matching class names to the log (quick lookups)
-- Send re_capture.txt back and mapping.lua gets populated.
local F = {}
local ctx

local function classOf(obj)
  local ok, n = pcall(function() return obj:GetClass():GetFName():ToString() end)
  if ok then return n end
  return nil
end

local function dumpMembers(cls, out)
  pcall(function()
    if cls.ForEachFunction then
      cls:ForEachFunction(function(fn)
        local ok, n = pcall(function() return fn:GetFName():ToString() end)
        if ok and n then out[#out + 1] = "    fn   " .. n end
      end)
    end
  end)
  pcall(function()
    if cls.ForEachProperty then
      cls:ForEachProperty(function(pr)
        local ok, n = pcall(function() return pr:GetFName():ToString() end)
        if ok and n then out[#out + 1] = "    prop " .. n end
      end)
    end
  end)
end

-- Returns (lines, seenSet). filter (optional) keeps only classes whose name contains it.
function F.capture(filter, withMembers)
  local seen, out = {}, {}
  local okd, d = pcall(os.date, "%c")
  out[#out + 1] = "# SolarpunkSurvival RE capture " .. (okd and d or "")
  local actors = ctx.uehelp.findAll("Actor")
  out[#out + 1] = "# live Actor instances scanned: " .. tostring(#actors)
  if filter then filter = filter:lower() end
  for _, a in ipairs(actors) do
    local cn = classOf(a)
    if cn and not seen[cn] and (not filter or cn:lower():find(filter, 1, true)) then
      seen[cn] = true
      out[#out + 1] = "CLASS " .. cn
      if withMembers then
        local ok, cls = pcall(function() return a:GetClass() end)
        if ok and cls then dumpMembers(cls, out) end
      end
    end
  end
  return out, seen
end

function F.writeDump()
  local out = F.capture(nil, true)
  local path = (ctx.modRoot or "") .. "dump/re_capture.txt"
  local f = io.open(path, "w")
  if not f then ctx.log.warn("recapture: cannot write " .. path); return end
  f:write(table.concat(out, "\n")); f:close()
  ctx.log.info(string.format("recapture: wrote %s (%d lines) — send this file back", path, #out))
end

function F.find(sub)
  local _, seen = F.capture(sub, false)
  local names = {}
  for k in pairs(seen) do names[#names + 1] = k end
  table.sort(names)
  ctx.log.info("recapture: classes matching '" .. tostring(sub) .. "' (" .. #names .. "):")
  for _, n in ipairs(names) do ctx.log.info("   " .. n) end
end

function F.init(c)
  ctx = c
  pcall(function()
    RegisterConsoleCommandHandler("sps_dump", function() F.writeDump(); return true end)
    RegisterConsoleCommandHandler("sps_find", function(_, p) F.find(p and p[1] or "") ; return true end)
  end)
  ctx.log.info("recapture: console `sps_dump` / `sps_find <substr>` ready (RE helper)")
  return true
end

return F
