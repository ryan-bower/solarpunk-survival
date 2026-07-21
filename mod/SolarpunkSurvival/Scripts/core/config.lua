-- Config: baked-in defaults (the source of truth) overlaid by an optional config.json.
-- A missing or malformed config.json never crashes the mod — defaults win.
local json = require("lib.json")
local log = require("core.log")
local bus = require("core.eventbus")

local M = {}

-- All tunables. UE distance/size units are centimetres (100 cm = 1 m).
M.defaults = {
  -- storm cadence
  lightning_chance    = 1.0,     -- multiplier on base strike rate during storms
  strike_interval     = 4.0,     -- seconds between strike opportunities at severity 1.0
  burst_chance        = 0.35,    -- chance a strike event is a multi-bolt burst
  burst_size          = 2,       -- max bolts in a burst
  telegraph_lead      = 1.2,     -- seconds of ground-decal warning before a bolt lands
  strike_radius       = 350.0,   -- cm; leave this radius before impact to dodge
  bolt_impact_delay   = 1.5,     -- seconds from bolt-actor spawn to its BIG strike frame; damage
                                 -- and world effects land then (dodgeable). Calibrate live via sps.
  native_strike_effects = true,  -- the game's own storm bolts also run our world effects (no extra
                                 -- player damage: native bolts already carry the game's damage)
  lightning_damage_guard = true, -- ground native bolt damage (vanilla splash reached ~10m); every
                                 -- bolt hurts through OUR radius-checked path at the impact frame
  lightning_guard_window = 4.0,  -- seconds after any bolt spawns during which non-mod damage is
                                 -- treated as lightning splash and grounded to 0
  storm_warning_lead  = 20.0,    -- seconds of "storm incoming" warning before lightning starts

  -- player
  player_max_hp       = 100.0,
  player_strike_pct   = 0.70,    -- fraction of max HP per strike (two hits = lethal)

  -- positioning / target weighting
  open_target_bias      = 3.0,     -- how strongly strikes prefer players in the open
  open_distance_threshold = 10000.0, -- cm (~100 m) from nearest land = "in the open"
  open_distance_mult    = 4.0,     -- strike-chance multiplier past that threshold
  flying_strike_mult    = 5.0,     -- strike-chance multiplier while flying in a storm

  -- structures
  structure_hp_base   = 200.0,
  strike_structure_dmg = 120.0,
  machine_two_hit     = true,    -- drills/sprinklers: smoking -> destroyed on 2nd strike
  salvage_frac        = 0.5,     -- fraction of build cost dropped on destruction

  -- airship
  airship_max_hp      = 300.0,
  airship_strike_frac = 0.3333,  -- fraction of airship HP per strike (~3 hits)
  airship_fall_damage = 40.0,    -- damage to occupants on a crash

  -- lightning rod
  lightning_rod_range = 2500.0,  -- cm (25 m) redirect radius
  rod_charges_battery = true,    -- redirected strikes charge a linked battery
  rod_takes_damage    = false,   -- rods absorb strikes without wear by default

  -- struck-player FX (client-local, triggered by the game's CLIENT_ReduceHealth RPC)
  fx_min_damage       = 40,      -- a reduce >= this is treated as a lightning hit
  stun_seconds        = 3.0,     -- movement locked + T-pose duration
  whiteout_hold       = 2.0,     -- seconds of solid white
  whiteout_fade       = 2.5,     -- seconds of the slow fade back
  buzz_volume         = 0.9,     -- electricity buzz (pitched thunder) volume
  buzz_pitch          = 2.2,     -- pitch multiplier that turns thunder into a crackle

  -- world-object strikes
  tree_wood_drop      = 4,       -- logs dropped when lightning fells a tree
  furnace_briquette_seconds = 160.0, -- burn time credited to a struck furnace (1 wax briquette)

  -- dark-arts ritual
  ritual_radius       = 2000.0,  -- cm (20 m) pentagram/sheep/wand radius
  ritual_fences       = 15,      -- fence pieces required
  ritual_candles      = 5,       -- LIT candles required
  ritual_check_interval = 8.0,   -- seconds between condition checks during a storm
  rod_copper_topper   = true,    -- cosmetic copper item attached atop each lightning rod

  -- misc
  friendly_fire       = true,
  imgui_key           = "F7",
  log_level           = "info",
  game_build          = nil,     -- optional manual build-id override for buildinfo
}

M.values = {}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local r = {}
  for k, v in pairs(t) do r[k] = deepcopy(v) end
  return r
end

function M.init(modRoot)
  M.values = deepcopy(M.defaults)
  M._path = (modRoot or "") .. "config/config.json"
  M.load()
  log.setLevel(M.get("log_level"))
  return M
end

function M.load()
  local f = io.open(M._path, "r")
  if not f then
    log.info("no config.json found; using defaults")
    return
  end
  local raw = f:read("*a"); f:close()
  local ok, parsed = pcall(json.decode, raw)
  if not ok or type(parsed) ~= "table" then
    log.warn("config.json parse failed; using defaults (" .. tostring(parsed) .. ")")
    return
  end
  local applied = 0
  for k, v in pairs(parsed) do
    if M.defaults[k] ~= nil or k == "game_build" then
      M.values[k] = v
      applied = applied + 1
    else
      log.warn("config.json: unknown key '" .. tostring(k) .. "' ignored")
    end
  end
  log.info(string.format("config loaded (%d overrides) from %s", applied, M._path))
end

function M.get(key)
  local v = M.values[key]
  if v == nil then v = M.defaults[key] end
  return v
end

function M.set(key, value)
  M.values[key] = value
  if key == "log_level" then log.setLevel(value) end
  bus.emit("config.changed", { key = key, value = value })
end

return M
