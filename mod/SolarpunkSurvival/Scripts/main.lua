-- SolarpunkSurvival — UE4SS Lua entry point.
-- Wires the core framework + Milestone 1 features. Everything is guarded: a failure in any one
-- module is logged and isolated, never propagated into the game thread.
local ok, err = pcall(function()
  -- Make require() resolve modules relative to this Scripts/ folder.
  local src = debug.getinfo(1, "S").source:sub(2)
  local scriptsDir = src:match("^(.*[/\\])") or "./"
  package.path = scriptsDir .. "?.lua;" .. package.path
  local modRoot = scriptsDir:match("^(.*[/\\])[Ss]cripts[/\\]$") or scriptsDir

  local log       = require("core.log")
  -- FIRST, before anything can schedule: shadow ExecuteWithDelay/ExecuteInGameThread with the
  -- queue-backed dispatcher (hook-thread function refs abort the process -- see the module).
  require("core.scheduler").init(log)
  local bus       = require("core.eventbus")
  local gate      = require("core.gate")
  local config    = require("core.config").init(modRoot)
  -- Breadcrumbs BEFORE any feature arms a hook: a native AV leaves nothing behind but this file,
  -- and its last line is the name of whatever was running when the process died.
  log.armSteps(modRoot, config.get("step_log") == true, config.get("step_log_notify") == true)
  local buildinfo = require("buildinfo").init()

  log.info("SolarpunkSurvival v0.1.0 starting")
  log.info(buildinfo.summary())
  if buildinfo.degraded then
    log.warn("DEGRADED: features disabled until Scripts/mapping.lua is filled for this build")
    log.warn("see docs/REVERSE-ENGINEERING.md — press " .. tostring(config.get("imgui_key")) ..
             " in-game for the unmapped-symbol list")
  end

  local uehelp   = require("core.uehelp")
  local net      = require("core.net").init(buildinfo.map)
  local identity = require("core.identity").init(buildinfo.map)
  local health   = require("core.health")
  local save     = require("core.save").init(buildinfo.map, modRoot)
  local items    = require("core.items").init(buildinfo.map)

  local ctx = {
    map = buildinfo.map, config = config, log = log, bus = bus, gate = gate,
    net = net, health = health, identity = identity, save = save, items = items,
    uehelp = uehelp, buildinfo = buildinfo, services = {}, modRoot = modRoot,
  }

  -- Load features before storms so their subscriptions/services exist when strikes fire. UI last.
  local features = {
    "features.player_effects",
    "features.destruction",
    "features.lightning_rod",
    "features.repair_tool",
    "features.strike_fx",
    "features.strike_world",
    "features.storms",
    "features.wand",         -- after storms: consumes services.castBolt; provides chargeWands
    "features.fishing",      -- after storms: consumes services.isStormy (storm luck); rewrites
                             -- river loot tables per-machine, diamond rod, splash, skillshot
    "features.ritual",       -- after storms/wand: consumes services.strikeAt + chargeWands
    "features.evil_animals", -- after storms/ritual: consumes services.damagePlayerBy + the
                             -- ritual.completed unlock; provides services.isEvilAnimal
    "features.codex",        -- the Tempest Codex: placed-book interact -> reader UI (content pak)
    "features.foundation",   -- snapped foundations skip the corners-touch-ground rule
    "features.qol",          -- chests x2, backpack, crouch, airship QoL, UI fixes, pings, map names
    "features.ship_chest",   -- after qol: provides services.shipChestOpen that qol's wheel keys use
    "features.manual_save",  -- a Save button in the pause menu (runs the game's own autosave)
    "ui.imgui_panel",
    -- dev.* are developer tools; the player install (install.py) excludes Scripts/dev
    -- entirely, and a missing dev module is skipped silently below. tools/run.py deploys them.
    "dev.recapture",
    "dev.remote",
    "dev.ritual_test",
    "dev.ritual_kit",        -- `sps_needful hydration|electrick`: stage a rite's animal + rod + offerings
  }
  for _, name in ipairs(features) do
    local okf, mod = pcall(require, name)
    if not okf then
      local absentDev = name:sub(1, 4) == "dev." and tostring(mod):find("not found", 1, true)
      if not absentDev then
        log.error("failed to load " .. name .. ": " .. tostring(mod))
      end
    else
      local oki, res = pcall(mod.init, ctx)
      if not oki then log.error(name .. " init error: " .. tostring(res)) end
    end
  end

  log.info("SolarpunkSurvival ready")
end)

if not ok then
  print("[SolarpunkSurvival] FATAL during init: " .. tostring(err))
end
