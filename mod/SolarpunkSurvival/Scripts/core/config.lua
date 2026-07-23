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
  bolt_impact_delay   = 4.7,     -- seconds from bolt-actor spawn to its BIG strike frame; damage
                                 -- and world effects land then (dodgeable). Timeline NewTrack_2
                                 -- fires at +1.97s but the VISIBLE big bolt is later -- 4.7 was
                                 -- dialed in live with the user watching (2026-07-21).
  native_strike_effects = true,  -- the game's own storm bolts also run our world effects (no extra
                                 -- player damage: native bolts already carry the game's damage)
  lightning_damage_guard = true, -- ground native bolt damage (vanilla splash reached ~10m); every
                                 -- bolt hurts through OUR radius-checked path at the impact frame
  lightning_guard_window = 2.5,  -- seconds after a bolt actually spawns during which non-mod
                                 -- damage is treated as lightning splash and grounded to 0. The
                                 -- hook cannot see WHO is dealing the damage, so every second
                                 -- this stays open is a second of fall damage / animal bites /
                                 -- starvation being nullified too. The native splash rides the
                                 -- bolt's own timeline (NewTrack_2 at +1.97s), so keep this just
                                 -- past that -- 4.0 covered up to two thirds of a storm.
  natural_storm_timeout  = 180.0, -- seconds without a native bolt before a game-weather storm is
                                  -- declared over (natural storms have no stop signal to hook)

  -- Ambient world strikes. The VANILLA thunder loop is not tunable from data: offline bytecode RE
  -- of ExecuteUbergraph_BP_DayNightCycle (2026-07-23) shows PlayThunder -> Delay(
  -- RandomIntegerInRange(10, 30)) -> loop, with the impact point taken from GetPlayerCharacter(0)
  -- + RandomFloatInRange(1500, 4000) / (-5000, -1500) per axis (sign by RandomBool) -- every one
  -- of those is an inline graph literal, and BP_DayNightCycle_C has no interval variable at all.
  -- So the mod runs its own copy of that loop on top, at a rate we control: bolts land AROUND the
  -- player (never on them, unlike the hunting scheduler), damage what they hit, and feed the rites.
  ambient_strikes      = true,   -- extra world bolts during any storm (ours or the game's own)
  ambient_interval_min = 6.0,    -- seconds; vanilla is 10
  ambient_interval_max = 14.0,   -- seconds; vanilla is 30
  ambient_ring_min     = 1500.0, -- cm (15 m) nearest an ambient bolt lands to the player
  ambient_ring_max     = 4000.0, -- cm (40 m) farthest -- both are vanilla's own ring

  -- lightning wand (a mod-managed tool, not an inventory item -- features/wand.lua)
  wand_cast_range      = 15000.0, -- cm; max aim distance for a cast bolt (150 m)
  wand_cast_debounce   = 0.5,     -- seconds between cast attempts (input events fire multiple phases)
  wand_recharge_radius = 500.0,   -- cm; hold the spent rod this close to a strike (not your own) to recharge
  wand_electric_charges = 3,      -- bolts per charged rod (cast this many, then recharge by storm)
  wand_transmute_items = true,    -- cast/recharge swaps the REAL charged/spent inventory items
  wand_cobalt_scale    = 0.75,    -- cobalt tip scale (the dropped model reads ~4x too big as a tip)
  wand_in_hand         = true,    -- draw = a real hand takeover: stash the held tool (the game's
                                  -- own StashHandItem; restored on stow) and spawn the game's
                                  -- hand-item actor for the stick. false = no takeover -- legacy
                                  -- slot-mesh fallback only (usually invisible; casts still work)
  wand_fwd             = 50.0,    -- capsule fallback only: cm forward of the pawn root (tune
                                  -- live -- any wand_* change rebuilds the rig immediately)
  wand_side            = 30.0,    -- capsule fallback only: cm to the right of the pawn root
  wand_up              = -30.0,   -- capsule fallback only: cm above the pawn root (hand height)
  wand_tip_up          = 0.0,     -- fine trim (cm) on the tip seat; the seat itself is computed
                                  -- from the stick mesh's bounds (its far end), not eye-tuned
  wand_tip_flip        = false,   -- seat the cobalt on the stick mesh's OTHER end
  wand_step_log        = true,    -- append each risky rig step to dump/wand_steps.txt so a native
                                  -- crash names its killer (the proven bisection method)
  storm_key            = "P",     -- key that toggles the storm on/off (any UE4SS Key name)
  wand_draw_key        = "V",     -- key that draws/stows the wand (any UE4SS Key name)
  wand_fx              = false,   -- electricity crackle on the charged wand -- OFF until the
                                  -- Niagara attach call is live-proven (probe it like P1-P6)
  wand_rig             = true,    -- in-hand visual. Every VISIBLE held item is a spawned
                                  -- BP_HandItem_* actor (game pipeline); our wand rows aren't in the
                                  -- game's baked item->hand-item map, so the mod spawns one itself
                                  -- via the game's own SetHandRBlueprintForBoth (donor: Carrot),
                                  -- re-meshes it to SM_Stick (force-loaded if needed) and tints it
                                  -- per state (wood/cobalt/diamond). Lifecycle stays game-owned --
                                  -- the game destroys the actor on every hotbar switch just like a
                                  -- berry's. false = no visual (pose only; casting still works).
  wand_hand_scale      = 1.0,     -- scale on the in-hand stick mesh comp (the donor hand item was
                                  -- sized for a carrot -- tune live, any wand_* change rebuilds)
  -- Per-state tint materials, by ASSET name in /Game/Art/Materials (see mapping wand.materialDir).
  -- Direct material assets, NOT mesh donors: the SM_Cobalt MESH ships with WorldGridMaterial (the
  -- engine's grey-white checker -- its real M_Cobalt was never assigned), and M_Stick's T_Bark
  -- reads pale in hand. Live-tunable: any wand_* change rebuilds the drawn rig.
  wand_mat_mundane     = "M_Trunk",             -- tree-bark DARK brown (M_Deco_Logs read as
                                                -- plain wood in hand -- user asked for darker)
  wand_mat_hydration   = "M_Cobalt",            -- river-blue (the quenched rod)
  wand_mat_electric    = "M_Beeswax",           -- waxy YELLOW (M_Statue_Gold read as bronze,
                                                -- not yellow -- and the rod IS sealed in beeswax)
  -- charged = uncharged's yellow family + a LIVE glow. Plant *_Shining materials are out (grass-
  -- wind WPO wobble + alien UVs on the stick -- seen live); textured materials are out (foreign
  -- UVs). M_Energy_On is a textureless powered-state material; swap candidates live via
  -- `sps set`: M_AirshipLight, M_Honey_Glass, M_Stick_Highlighted (bark + pickup shimmer).
  wand_mat_charged     = "M_Energy_On",
  -- The Hydration Wand's tank. Capacity = 2x the watering can's MaxWaterlevel of 120 (offline RE
  -- of BP_HandItem_Watercan); a growbox's BC_WaterStorage holds 20, so one full wand waters 12.
  wand_hydration_max   = 240.0,   -- water units the blue rod carries when full
  wand_pour_amount     = 20.0,    -- units per pour into a water storage (= one growbox, full)
  wand_spray_seconds   = 0.8,     -- how long the watercan splash FX plays on a wand pour
  wand_hydrate_cost    = 20.0,    -- units per teammate quench
  wand_hydrate_thirst  = 50.0,    -- thirst restored on a quenched teammate (AddThirst value)
  wand_pour_radius     = 300.0,   -- cm; how close to the aim point a storage/teammate must be
  wand_water_refill_debounce = 5.0, -- seconds between wade-refill triggers (footstep events spam)
  wand_from_item       = true,    -- still DETECT the equipped cooked wand on HotbarSlotChanged (for
                                  -- cast/charge state + logging); with wand_rig off this no longer
                                  -- touches the hand -- the game draws it. false = only V-key/ritual.
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
  ritual_corner_radius = 1000.0, -- cm; each of the five corner offerings must rest this close to
                                 -- one of the pentagram's candles (2.5m read as "by the candle
                                 -- and still missed" live 2026-07-22; user widened to 10m --
                                 -- anywhere in the circle's heart counts)
  ritual_payout_radius = 3000.0, -- cm (30 m); how far from the SACRIFICE a player may stand and
                                 -- still receive the rite's benefit (wider than the 20m circle:
                                 -- you can watch the bolt take the bird from safety)
  ritual_fences       = 15,      -- fence pieces required
  ritual_candles      = 5,       -- LIT candles required
  ritual_check_interval = 8.0,   -- seconds between condition checks during a storm
  rod_copper_topper   = false,   -- retired: the cosmetic copper topper spawned + attached an item
                                 -- actor at runtime, which is the native-crash family (see
                                 -- features/lightning_rod.lua). Kept as a known key so an old
                                 -- config.json with it set does not warn; nothing reads it.

  -- building
  foundation_snap_ignore_ground = true, -- snapped-to-a-buildable foundations skip the game's
                                        -- corners-must-touch-the-ground placement rule

  -- the Unlit (features/evil_animals.lua): storm-spawned hostile animals, unlocked per species
  -- by that species' first ritual sacrifice
  evil_animals        = true,    -- master switch
  evil_spawn_radius   = 20000.0, -- cm (200 m) farthest an Unlit spawns from a player
  evil_spawn_min      = 3000.0,  -- cm (30 m) nearest (never materialize in someone's face)
  evil_cap_per_player = 10,      -- live Unlit allowed per connected player
  evil_spawn_interval = 8.0,     -- seconds between spawn attempts while the storm holds
  evil_brain_interval = 0.7,     -- seconds between host AI ticks (movement/lock-on/bite checks)
  evil_lockon_radius  = 10000.0, -- cm (100 m); inside this an Unlit locks on and charges
  evil_wander_mult    = 2.0,     -- x the animal's own MaxWalkSpeed while prowling
  evil_chase_mult     = 4.0,     -- x while locked on
  evil_wander_hop     = 1500.0,  -- cm; length of one prowling leg between random move orders
  evil_bite_radius    = 200.0,   -- cm (2 m); players inside take the bite
  evil_bite_interval  = 2.0,     -- seconds between bites per animal
  evil_bite_chicken   = 10.0,    -- HP per Unlit-bird peck        (user: chicken 10, sheep 20)
  evil_bite_sheep     = 20.0,    -- HP per Unlit-lamb bite
  evil_hp_chicken     = 30.0,    -- Unlit bird hit points
  evil_hp_sheep       = 50.0,    -- Unlit lamb hit points
  evil_dmg_base       = 20.0,    -- tool damage: base pickaxe/axe/hoe (stone tier)
  evil_dmg_metal      = 30.0,    -- ...Metal rows (iron)
  evil_dmg_diamond    = 40.0,    -- ...Diamond rows
  evil_melee_range    = 350.0,   -- cm; how far a tool swing reaches an Unlit
  evil_death_linger   = 2.5,     -- seconds the fallen body lies (Sleep montage) before vanishing
  evil_fx_interval    = 1.2,     -- seconds between client-side FX watcher passes
  evil_sound_pitch    = 0.55,    -- pitch multiplier: the animal's own voice, several steps down
  evil_chatter_wander = 7.0,     -- seconds between pitched-down cries while prowling
  evil_chatter_chase  = 2.0,     -- ...while locked on (many noises AT you, per the design)
  evil_mat_body       = "M_Deco_Fireplace_Burned", -- whole-body corrupted look (one-slot meshes --
                                                   -- see docs/RE-ANIMALS.md; swap live via sps set)
  evil_mat_blink      = "M_Preview_Red",           -- the hit flash (the build system's own red)
  evil_blink_seconds  = 0.18,    -- how long the red flash holds
  evil_prefix_alive   = "Unlit ",  -- replicated-Name marker for a living Unlit (the MP beacon)
  evil_prefix_dead    = "Fallen ", -- ...and for one playing its death
  evil_sweep_strays   = false,   -- OFF by default: destroying animals by the spoofable Name marker
                                 -- can wipe a player pet renamed "Unlit ..." via AnimalTag. When on,
                                 -- the sweep still skips owned animals. Host decisions (ritual,
                                 -- lightning, tools) use the authoritative tracking table, not names.

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
