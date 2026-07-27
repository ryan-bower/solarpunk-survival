-- Debug / status + live config panel.
-- MVP is a keybind + console command that always work (print to the UE4SS console). A full
-- ImGui overlay with sliders is a Phase 6 upgrade; this keeps the scaffold dependency-free.
--   Keybind (default F7): dump status + unmapped-symbol list.
--   Console: `sps`                -> status
--            `sps set <key> <num>`-> live-tune a config value
local F = {}
local ctx

local function resolveKey(name)
  if not Key then return nil end
  return Key[name] or Key.F7
end

function F.init(c)
  ctx = c
  local keyName = ctx.config.get("imgui_key")
  if pcall(function() RegisterKeyBind(resolveKey(keyName), ctx.log.guard("panel.key", F.dumpStatus)) end) then
    ctx.log.info("panel: press " .. tostring(keyName) .. " for status; console `sps` to tune")
  else
    ctx.log.warn("panel: keybind registration failed (console `sps` still works)")
  end
  pcall(function()
    RegisterConsoleCommandHandler("sps", function(_, params) F.command(params); return true end)
  end)
  return true
end

function F.dumpStatus()
  local bi = ctx.buildinfo
  ctx.log.info("=== SolarpunkSurvival status ===")
  ctx.log.info(bi.summary())
  ctx.log.info("host authority: " .. tostring(ctx.net.isHost()) ..
               " | client-sync carriers: " .. tostring(ctx.net.hasCarriers()))
  if bi.missing and #bi.missing > 0 then
    ctx.log.info("unmapped symbols (" .. #bi.missing .. "):")
    for _, m in ipairs(bi.missing) do ctx.log.info("   - " .. m) end
  end
  local n = 0
  for _ in pairs(ctx.health.byId) do n = n + 1 end
  ctx.log.info("tracked health records: " .. n)
end

-- Console values arrive as strings. Numbers were the only thing this ever accepted, which quietly
-- made every BOOLEAN setting untunable: `sps set qol_crouch_hold 0` stored the NUMBER zero, and
-- zero is true in Lua, so the switch you just "turned off" stayed on. A key whose default is a
-- boolean now takes on/off/true/false/1/0 and is stored as a boolean.
local function parseValue(key, raw)
  if raw == nil then return nil, "missing value" end
  local defaults = ctx.config.defaults or {}
  local word = tostring(raw):lower()
  if type(defaults[key]) == "boolean" then
    if word == "true" or word == "on" or word == "yes" or word == "1" then return true end
    if word == "false" or word == "off" or word == "no" or word == "0" then return false end
    return nil, key .. " is a switch -- use on/off"
  end
  if word == "true" or word == "false" then return (word == "true") end
  local n = tonumber(raw)
  if n ~= nil then return n end
  return nil, "value must be a number (or on/off for a switch)"
end

function F.command(params)
  params = params or {}
  if params[1] == "set" and params[2] then
    local key = params[2]
    local val, why = parseValue(key, params[3])
    if val ~= nil then
      ctx.config.set(key, val)
      ctx.log.info("config: " .. key .. " = " .. tostring(val))
    else
      ctx.log.warn("usage: sps set <key> <number|on|off>" .. (why and ("  -- " .. why) or ""))
    end
  else
    F.dumpStatus()
  end
end

return F
