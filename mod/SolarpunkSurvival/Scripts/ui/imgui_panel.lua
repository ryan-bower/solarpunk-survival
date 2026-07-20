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

function F.command(params)
  params = params or {}
  if params[1] == "set" and params[2] then
    local key = params[2]
    local val = tonumber(params[3])
    if val ~= nil then
      ctx.config.set(key, val)
      ctx.log.info("config: " .. key .. " = " .. tostring(val))
    else
      ctx.log.warn("usage: sps set <key> <number>")
    end
  else
    F.dumpStatus()
  end
end

return F
