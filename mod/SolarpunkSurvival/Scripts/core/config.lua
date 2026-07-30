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
  -- Right-click DRINKING from the blue rod. Rate is percent-of-max thirst/second; the measure
  -- cost is derived so a full 0->100% drink spends the whole wand (wand_hydration_max scaled
  -- by the player's live MaxPlayerThirst). The live build binds IA_AltHandInteract to
  -- ETriggerEvent::Completed ONLY (offline binding-table decode + live guard trace,
  -- 2026-07-29): the event fires ONCE per click, on RELEASE -- a held button is invisible, so
  -- "toggle" is the shipping mode: one click starts drinking, it stops on its own at full
  -- thirst / dry rod, or on a second click. "hold" survives for builds whose event repeats
  -- while held (drink while events keep arriving, wand_drink_grace after the last one).
  wand_drink_mode      = "toggle",
  wand_drink_rate      = 25.0,    -- PERCENT of max thirst restored per second while drinking
                                  -- (live saves have MaxPlayerThirst=1000; percent keeps the
                                  -- "kinda quick" 4s full drink at any scale)
  wand_drink_tick      = 0.25,    -- seconds between drink steps (bounded re-chained one-shots)
  wand_drink_grace     = 0.4,     -- "hold" mode: seconds after the last alt event still counted as held
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
  strike_scan_min_gap = 1.0,     -- seconds between full-world impact scans on the host. Burst
                                 -- bolts land 0.35 s apart at the SAME point, so one sweep covers
                                 -- the whole burst; without this cap a heavy storm ran the sweep
                                 -- per bolt and melted the host's frame budget (live 2026-07-26)

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
  evil_spawn_interval = 5.0,     -- seconds between spawn ticks while the storm holds
  evil_spawn_tries    = 10,      -- ground-pick attempts per spawn: one bad spot (water/built/off-map)
                                 -- no longer burns the whole interval, so spawns feel steady
  evil_spawn_per_tick = 2,       -- Unlit spawned per tick (up to the cap) so the world fills faster
  evil_brain_interval = 0.7,     -- seconds between host AI ticks (movement/lock-on/bite checks)
  evil_lockon_radius  = 10000.0, -- cm (100 m); inside this an Unlit locks on and charges
  evil_wander_mult    = 2.0,     -- x the animal's own MaxWalkSpeed while prowling
  evil_chase_mult     = 8.0,     -- x while locked on (2x the old 4x -- "twice as fast coming at you")
  evil_wander_hop     = 1500.0,  -- cm; length of one prowling leg between random move orders
  evil_bite_radius    = 300.0,   -- cm (3 m); players inside take the bite
  evil_bite_interval  = 2.0,     -- seconds between bites per animal
  evil_bite_chicken   = 10.0,    -- HP per Unlit-bird peck        (user: chicken 10, sheep 20)
  evil_bite_sheep     = 20.0,    -- HP per Unlit-lamb bite
  evil_hp_chicken     = 90.0,    -- Unlit bird hit points (3x)
  evil_hp_sheep       = 150.0,   -- Unlit lamb hit points (3x)
  evil_scale_chicken  = 1.0,     -- model size multiplier (visual; applied on every machine)
  evil_scale_sheep    = 2.0,     -- the Unlit lambs loom at 2x
  evil_atkspeed_chicken = 1.0,   -- bite-rate multiplier (1.0 = every evil_bite_interval)
  evil_atkspeed_sheep = 0.7,     -- chicken/general slower factor; sheep use evil_ram_recover instead
  evil_hit_stun       = 0.5,     -- seconds an Unlit stands frozen after a tool hit lands on it
  evil_ram_recover    = 1.5,     -- sheep ONLY: stand + attack-cooldown after a ram (its bite gap)
  evil_ram_launch_z   = 750.0,   -- upward launch on a sheep ram (the auto-jump)
  evil_ram_launch_back = 250.0,  -- horizontal knockback away from the sheep on a ram
  evil_light_block_big  = 2000.0,-- cm (20 m): a lit torch / powered lamp / wireless light blocks spawns
  evil_light_block_small = 1000.0,-- cm (10 m): a lit candle / powered small lamp blocks spawns
  evil_dmg_base       = 20.0,    -- tool damage: base pickaxe/axe/hoe (stone tier)
  evil_dmg_metal      = 30.0,    -- ...Metal rows (iron)
  evil_dmg_diamond    = 40.0,    -- ...Diamond rows
  evil_melee_range    = 350.0,   -- cm; how far a tool swing reaches an Unlit
  evil_death_linger   = 2.5,     -- seconds the fallen body lies (Sleep montage) before vanishing
  evil_fx_interval    = 1.2,     -- seconds between client-side FX watcher passes (discovery/material/sound)
  evil_glow_follow    = 0.1,     -- seconds between red-aura reposition ticks (10 Hz) -- cheap, local-only
  evil_sound_pitch    = 0.55,    -- pitch multiplier: the animal's own voice, several steps down
  evil_chatter_wander = 7.0,     -- seconds between pitched-down cries while prowling
  evil_chatter_chase  = 2.0,     -- ...while locked on (many noises AT you, per the design)
  evil_mat_body       = "M_Plant_Tomato",          -- living Unlit body swap. A RED body is engine-blocked:
                                                   -- skeletal meshes render any material without a compiled
                                                   -- bUsedWithSkeletalMesh flag as the black Default Material,
                                                   -- and NO red/fire/energy material in the game carries it
                                                   -- (proven via cooked M_* dumps -- see RE-ANIMALS). So this
                                                   -- reads as a solid BLACK silhouette; the menace-red is the
                                                   -- point-light aura below, not the fur.
  evil_mat_dead       = "M_Deco_Fireplace_Burned", -- the fallen: charred black once it dies
  evil_mat_blink      = "M_Deco_Bench_White",      -- the hit flash: an opaque white, contrasts the dark body
  evil_blink_seconds  = 0.18,    -- how long the hit flash holds
  -- Red aura: a spawned movable PointLight that trails each LIVING Unlit (the achievable "glow" -- body
  -- red is impossible, above). Per-machine local FX; the light is destroyed when the animal falls/vanishes.
  evil_glow           = true,    -- master toggle for the red aura light
  evil_glow_intensity = 5000.0,  -- PointLight intensity (lumens on this build); tune live via `sps set`
  evil_glow_radius    = 700.0,   -- cm (~7 m) attenuation radius -- how far the red pool reaches
  evil_glow_r         = 1.0,     -- aura colour, linear RGB -- default a deep blood red
  evil_glow_g         = 0.02,
  evil_glow_b         = 0.0,
  evil_prefix_alive   = "Vengeful ", -- replicated-Name marker + nameplate for a living evil animal
  evil_prefix_dead    = "Banished ", -- ...and for one playing its death (the fallen)
  evil_sweep_strays   = false,   -- OFF by default: destroying animals by the spoofable Name marker
                                 -- can wipe a player pet renamed "Unlit ..." via AnimalTag. When on,
                                 -- the sweep still skips owned animals. Host decisions (ritual,
                                 -- lightning, tools) use the authoritative tracking table, not names.

  -- quality of life (features/qol.lua) -- all live-tunable via `sps set`
  qol_chest_grow_occupied = true,-- grow chests that HOLD things too, via the buffer shuffle
                                 -- (game-side index moves through a temporary chest; items are
                                 -- verified by count at every phase and never deleted)
  qol_chest_size      = 24,      -- chest slots (stock 12). Host grows chests to this size
                                 -- (the game's own bulk setter); an occupied chest grows on the
                                 -- next pass after it is emptied. Clients see it via replication.
  qol_backpack_level  = 0,       -- backpack upgrade tier applied on world entry (-1 = leave alone).
                                 -- Only 0/1/3/7 are real tiers -> 29/36/43/50 slots; anything else
                                 -- the game rounds down to 29 and your save stops loading.
                                 -- 0 is stock, i.e. no expansion (set back to 3 for the 43-slot
                                 -- pack). Going DOWN only happens with room to spare: a shrink is
                                 -- skipped, with a log line, while more is carried than the smaller
                                 -- pack holds, and the tier is not recorded until the array really
                                 -- did resize.
  qol_backpack_relink = true,    -- repair a save this mod already broke by upgrading the pack
                                 -- without recording the tier. On: your CURRENT inventory becomes
                                 -- the saved one. Off: the next load restores the older snapshot
                                 -- the game still has stored, and this session's items are lost.
  qol_crouch          = true,    -- crouch: TAP either key to toggle, HOLD either key to crouch
                                 -- for exactly the hold. Ctrl's release is exact (the pawn's own
                                 -- press/release events); the letter key's release is inferred
                                 -- from the OS key-repeat stream going quiet, so standing back
                                 -- up after a HELD letter key lags ~0.7s. Prefer Ctrl for holds.
  qol_crouch_hold     = true,    -- false = both keys are plain toggles (one press per toggle).
                                 -- Note there is NO safe direct key-state read on this build:
                                 -- IsInputKeyDown takes an FKey (a struct wrapping an FName) and
                                 -- is a proven process kill (2026-07-27).
  qol_crouch_key      = "C",
  qol_crouch_key2     = "LEFT_CONTROL",  -- Ctrl/Shift/Alt are absent from UE4SS's Key table; qol
                                 -- binds these by raw virtual-key code instead (see qol.bind)
  qol_crouch_repeat_gap = 0.65,  -- s; down-events closer together than this are the OS repeating
                                 -- a HELD key, farther apart are fresh presses. Raise it (e.g.
                                 -- 1.1) if Windows' keyboard repeat delay is set to Long and a
                                 -- held letter key flickers; lower toward 0.35 for Short.
  qol_crouch_deathloot_fix = true, -- dying crouched dropped the loot chest under the ground (the
                                 -- game stamps the drop spot off the pawn origin, which crouching
                                 -- lowers). Corrects the stamped spot back to standing height.
  qol_ship_chest_key  = "B",     -- open the airship's storage (near it or at the wheel)
  qol_ship_chest_range = 3000.0, -- cm (30 m); how far from the ship the chest key still works
  qol_ship_inv_key    = "TAB",   -- at the wheel this TOGGLES the TRANSFER view: the ship's
                                 -- storage chest + your own inventory in one panel; press again
                                 -- (or ESC) to close (on foot the game's own binding handles
                                 -- the key)

  -- The ship's storage chest (features/ship_chest.lua): a real chest kept at the inside back of
  -- the airship -- no in-game chest upgrade needed (that upgrade collides with the other ship
  -- upgrades). Real chest = stock model, native walk-up interact, contents ride the game save.
  ship_chest          = true,    -- the airship simply HAS storage
  ship_chest_back     = -240.0,  -- ship-relative offsets to where the chest sits; the default is
  ship_chest_right    = 0.0,     -- the exact spot the game parks its own chest-upgrade lid
  ship_chest_up       = 40.0,    -- (SM_Chest_Top at (-239, 0, 56), offline RE). Tune live with
                                 -- `sps set ship_chest_back -300` etc.; re-anchors on next park.
  ship_chest_yaw      = 90.0,    -- deg the chest is spun beyond the ship's own facing. At 0 it
                                 -- sat lengthwise (user 2026-07-27: quarter-turn it); 270 is the
                                 -- other quarter if the lid ends up opening into the hull.
  ship_chest_adopt_r  = 600.0,   -- cm; a chest within this range of the anchor (or of where the
                                 -- sidecar remembers leaving it) IS the ship chest -- adopted,
                                 -- moved, never duplicated
  -- Airship boost (features/boost.lua): SPACE at the wheel pushes the control to max and boosts
  -- to boost_mult x top speed with the game's own boost-wind loop + a raised FOV; SPACE again or
  -- holding the slow-down control ramps back to normal max over boost_ramp_secs.
  boost_enabled       = true,
  boost_mult          = 3.0,     -- top speed while boosting, as a multiple of the ship's MaxSpeed
  boost_fov_add       = 15.0,    -- degrees added to the ship camera's FOV while boosting
  boost_fov_in_secs   = 1.0,     -- seconds for the FOV to ease up to the full bump on boost
  boost_ramp_secs     = 3.0,     -- seconds to glide speed AND FOV back to normal on exit
  boost_volume        = 1.0,     -- wind loop volume
  boost_key           = "SPACE", -- UE4SS Key name; gated on IsControllingAirship? so on-foot
                                 -- SPACE stays the game's jump untouched
  boost_hint          = true,    -- "Press SPACE to boost" nudge at the wheel (the mod's own,
                                 -- speed-gated -- unlike the vanilla boost tooltip that fires
                                 -- even at max speed)
  boost_hint_secs     = 20.0,    -- seconds spent AT max speed without boosting before it shows
  boost_hint_show_secs = 5.0,    -- seconds the nudge stays up (shows once per turn at the wheel)
  qol_recall_mult     = 5.0,     -- airship recall multiplier -- the mod's own assist amplifies the
                                 -- return flight's travel leg AND the long "unstuck" descent (the
                                 -- raise, the final approach and the docking stay native;
                                 -- TimelineSpeed turned out to be a dead variable). NEVER a
                                 -- teleport -- the flight is the feature (user 2026-07-29).
                                 -- 5 is the user's pick after live-testing at 20 ("it worked!
                                 -- now bring it down to like 5X", 2026-07-29).
  -- The chest stock ledger (features/chest_index.lua) -- shared by sort_chest + craft_pull.
  chest_index_sweep   = 20.0,    -- secs between world sweeps for chests (lazy: only when asked)
  chest_index_ttl     = 20.0,    -- secs a cached per-(chest,item) amount stays trusted
  -- The blue SORTING CHEST (features/sort_chest.lua + pak clone BP_SortingChest_Placeable):
  -- powered chest that Quick Stacks its contents into nearby chests already holding the item.
  sort_chest          = true,
  sort_chest_range    = 5000.0,  -- cm; chests within 50 m can receive
  sort_chest_tick     = 1.5,     -- secs between sorting passes (one target chest per pass)
  sort_chest_power_active = 500.0, -- power draw while it holds items to sort
  sort_chest_power_idle   = 100.0, -- power draw while empty
  -- Crafting AUTO-PULL (features/craft_pull.lua): recipes on screen fetch their missing
  -- materials from chests within range into your inventory, so the counts turn real.
  craft_pull          = true,
  craft_pull_range    = 5000.0,  -- cm; chests within 50 m feed the crafting stations
  craft_pull_scan_ms  = 300,     -- ms between recipe-widget scans while a station is open
  qol_hotbar_raise    = true,    -- pull the hotbar up under the open inventory window
  qol_hotbar_x        = 0.0,     -- hotbar shift while the inventory is open (px at 1080p design res)
  qol_hotbar_y        = -240.0,  -- negative = up. LIVE geometry is unreadable from Lua
                                 -- (GetCachedGeometry marshals to an empty table); this constant
                                 -- was dialled in live (`sps set qol_hotbar_y -240` re-places it
                                 -- immediately) AT the row count below, and the per-row shift is
                                 -- taken from the COOKED layout instead (offline RE 2026-07-27,
                                 -- scratchpad re_ui/): the window's canvas slot is anchored AND
                                 -- aligned at screen centre with auto-size, so it grows
                                 -- symmetrically -- its bottom edge moves half a row per row.
                                 -- (-240 is the eyes-on 07-26 dial; an unverified -430 shipped
                                 -- overnight and parked the bar mid-window -- user report 07-27.)
  qol_hotbar_rows_base = 5,      -- the row count qol_hotbar_y was tuned against: dialled with the
                                 -- tier-3 backpack showing 5 rows
                                 -- (GetRowCount: tier 0/1/3/7 -> 3/4/5/6 rows).
  qol_hotbar_row_px   = 40.0,    -- how far the window's BOTTOM EDGE moves per row added: one
                                 -- W_InventorySlot is 80x80 in a padding-free UniformGridPanel
                                 -- with no ScaleBox in its chain, and the centre-anchored window
                                 -- splits that growth between top and bottom -> 40. Positive,
                                 -- because more rows push the hotbar DOWN (less lift).
  qol_drops_center    = true,    -- move the "+4 Wood" pickup feed to mid-screen
  qol_drops_x         = 0.0,     -- offset from dead centre (px); tune live with `sps set`
  qol_drops_y         = 120.0,   -- a touch below centre so it never sits on the crosshair
  qol_ping_scale_xy   = 1.5,     -- ping marker girth (1.0 = stock)
  qol_ping_scale_z    = 10.0,    -- ping marker height ("4X as tall" than the old 2.5 -- user spec
                                 -- 2026-07-27). The stock plane is ~11m, so this is a ~110m beacon.
                                 -- Safe to raise now that the marker turns to face you -- a tall
                                 -- plane no longer goes edge-on and vanishes.
  qol_ping_colors     = true,    -- paint each ping the pinging player's palette slot: a cooked
                                 -- material whose baked-in colour matches their map icon's tint.
                                 -- (Setting a material PARAMETER is a proven native crash on this
                                 -- build -- the colour must come baked into the material chosen.)
  qol_ping_rod_only   = true,    -- hide SM_Ping's icon quad (the "box" at the marker's base once
                                 -- painted flat) by dressing it in the engine's draw-nothing
                                 -- masked material -- leaving just the beam. false = paint the
                                 -- icon quad the palette colour too (the old two-slot look).
  qol_ping_face       = true,    -- turn the marker to face the camera while it is on the ground
  qol_ping_face_ms    = 66,      -- how often (ms). The loop only runs while a ping exists and
                                 -- re-finds it every step -- it never holds the actor across one.
  qol_ping_face_yaw   = 90.0,    -- SM_Ping's visible face is its Y axis, not +X: at 0 the facing
                                 -- loop presented the marker edge-on 90 degrees off (user-observed
                                 -- 2026-07-27). The beam is painted flat so front vs back is
                                 -- indistinguishable; if a stock glyph (rod_only fallback) ever
                                 -- reads mirrored, use 270.
  qol_map_names       = true,    -- map player icons: palette tint + name tooltip
  qol_map_labels      = true,    -- always-visible name labels riding each player's map position
                                 -- (positioned from live pawn locations, not FriendsMarkers --
                                 -- immune to the vanishing-icon reconciliation bug)

  -- manual save (features/manual_save.lua): a Save button in the pause menu that runs the game's
  -- own autosave on demand. HOST ONLY -- only the host holds the world save (see the module).
  save_button          = true,   -- add the button to the ESC menu, just above Resume
  save_button_label    = "Save Game",
  save_button_busy_label = "Saving...",  -- while a save is in flight (ours or the game's autosave)
  save_button_done_label = "Saved",      -- flashed when the write lands
  save_button_done_seconds = 3.0,        -- how long "Saved" lingers before the label reads normal
  save_button_cooldown = 10.0,   -- seconds after a completed save before another may be asked for.
                                 -- Not a corruption guard (the in-flight check is) -- it just stops
                                 -- an impatient double-click from queueing a second full write.
  save_button_timeout  = 60.0,   -- seconds after which an unfinished save is assumed dead. Only
                                 -- ever reached if the "write finished" hook failed to arm; without
                                 -- it a lost signal would wedge the button shut for the session.
  save_button_rearm_autosave = true, -- a manual save pushes the next autosave a full interval out,
                                 -- so the timer doesn't write again seconds after you just did.
                                 -- Skipped unless the game's own interval reads back sane.

  -- fishing overhaul (features/fishing.lua) -- all live-tunable via `sps set`
  fishing_enabled     = true,    -- master switch (tables + splash + diamond rod + minigame)
  fishing_tables      = true,    -- rewrite the rivers' loot tables (off = vanilla loot, the rest
                                 -- of the overhaul still runs)
  fishing_splash_gain = 3.0,     -- total loudness of the BITE splash vs stock ("300%" -- the mod
                                 -- layers gain-1 extra on top of the game's own 1.0 play)
  fishing_minigame_weather_bonus = 0.05, -- +5pp SKILLSHOT chance while it rains or storms (weather
                                 -- moved OFF the loot bands onto the minigame roll, user spec)
  fishing_twilight_mult = 1.5,   -- rare+jackpot band multiplier during the dawn/dusk window below
  fishing_diamond_mult  = 2.0,   -- ...while the Diamond Fishing Rod is in hand ("2x luck")
  fishing_twilight_secs = 300.0, -- how long after an IsDay flip the sun still counts as transitioning
  fishing_daywatch_secs = 20.0,  -- IsDay sampling cadence (slow self-rechaining watchdog; the
                                 -- storms.lua naturalWatchdog shape -- free-running UObject timers
                                 -- are the proven native crash)
  fishing_rod_wear_min = 0.10,   -- a FISHED-UP rod keeps between these fractions of its max
  fishing_rod_wear_max = 0.60,   -- durability ("random amount of durability remaining")
  fishing_rod_ledger  = true,    -- diamond rods vanish across some reloads (intermittent, cause
                                 -- unproven): snapshot the player's rods (count+durability) into
                                 -- the mod sidecar, audit the whole world at entry, and re-grant
                                 -- any rod that exists nowhere -- with its recorded wear
  fishing_minigame_chance = 0.05,-- 5% of bites: the catch click yields a leaf and reveals the
                                 -- skillshot bar; a second click in the golden zone = a rare/jackpot
                                 -- guarantee (diamond rod: smaller zone, jackpot-only)
  fishing_minigame_chance_diamond = 0.25, -- separate bite chance while the Diamond Fishing Rod
                                 -- is held (user spec 2026-07-29: 1 in 4); -1 = follow
                                 -- fishing_minigame_chance
  fishing_minigame_period = 1.6, -- seconds per full marker sweep (out and back)
  fishing_minigame_zone   = 0.18,-- golden-zone width as a fraction of the bar
  fishing_minigame_zone_diamond = 0.10, -- the diamond rod's harder zone
  fishing_minigame_timeout = 6.0,-- seconds before an unanswered bar counts as "the fish escaped"
  fishing_bar_x       = 750.0,   -- bar placement, absolute canvas px at 1080p design res (the
  fishing_bar_y       = 700.0,   -- overlay canvas scales the whole tree; tune live via `sps set`)
  fishing_bar_w       = 420.0,
  fishing_bar_h       = 26.0,
  fishing_click_debounce = 0.30, -- seconds between accepted rod clicks (input events multi-fire)
  fishing_bar_speed_max_mult = 2.0, -- each bar's sweep speed rolls uniform 1x..this x the base
                                 -- speed (fishing_minigame_period is the 1x sweep)
  fishing_wheel_share = 0.34,    -- chance a triggered skillshot is the WHEEL (with vsync_share
                                 -- below this makes wheel/gap-sync/bar a ~even three-way roll)
  fishing_vsync_share = 0.33,    -- chance it is the GAP-SYNC (two vertical lanes) game
  -- The gap-sync game's knobs. Sizes hang off the sliding bar's geometry: the lanes are
  -- fishing_bar_w long and fishing_bar_h wide; the line starts at 1/10 the sliding marker's
  -- 36 px length and grows 2x its base height per second up to 9x (the gap and its rects are
  -- 10x the base -- at full growth the fit margin is 1.8 px a side; tense, never impossible).
  fishing_vsync_line  = 3.6,     -- the line's base height, px
  fishing_vsync_grow_rate = 2.0, -- growth per second, in units of the base height
  fishing_vsync_grow_cap  = 9.0, -- growth ceiling, in units of the base height
  fishing_vsync_period_min = 1.6, -- fastest full ping-pong, seconds (user pass 2026-07-30:
                                 -- both lanes at HALF speed again -- periods doubled)
  fishing_vsync_period_max = 3.2, -- slowest -- half the fastest, so the band is still 2:1
  fishing_vsync_x     = 840.0,   -- left lane's left edge, canvas px at 1080p design res
  fishing_vsync_dx    = 70.0,    -- right lane's offset from the left lane (lanes are
                                 -- fishing_bar_h=26 wide, so this leaves a 44 px alley)
  fishing_vsync_y     = 300.0,   -- lanes' top edge (420 tall: 300..720, straddling center)
  fishing_vsync_slide_secs = 0.25, -- the click->reveal slide animation length
  fishing_wheel_speed = 360.0,   -- wheel spin, deg/s -- constant on purpose (learnable)
  fishing_wheel_decel = 144.0,   -- wheel slow-down, deg/s^2 -- constant on purpose; with speed
                                 -- these fix the click->rest offset at speed^2/(2*decel) = 450
                                 -- degrees (a lap and a quarter over 2.5s), the skill the
                                 -- player learns over time
  fishing_wheel_zone  = 40.0,    -- golden arc width in degrees
  fishing_wheel_zone_diamond = 24.0, -- the diamond rod's harder arc
  fishing_wheel_x     = 960.0,   -- wheel center, canvas px at 1080p design res (screen center:
  fishing_wheel_y     = 540.0,   -- the needle sweeps around the crosshair)
  fishing_wheel_r     = 90.0,    -- dial radius
  fishing_flash_secs  = 0.22,    -- hit/miss/timeout color flash shown before the bar folds
  fishing_click_lead  = 0.0,     -- seconds subtracted from the click stamp on the DEGRADED
                                 -- judge paths only (deferred fallback, wheel seal). The bar's
                                 -- normal judge is the frozen frame itself (screenshot rule) --
                                 -- a time lead scales with bar speed and outgrew the diamond
                                 -- zone (dead-center freeze judged a miss at 0.03)
  fishing_ui_own_widget = true,  -- probe a standalone viewport widget for the bar; false = go
                                 -- straight to the overlay-canvas fallback

  -- trash-can slot (features/trash_slot.lua): a red extra slot right of the bag's bottom-right
  -- cell. Items placed in it are queued for deletion -- the LAST one dropped in stays retrievable
  -- until something replaces it (the previous one is destroyed) or the session ends (the backing
  -- store is a detached inventory the save system cannot see, so logout forgets it by design).
  trash_slot          = true,

  -- misc
  anim_tick_ms        = 8,       -- core/animator per-frame lane ticker interval. Hops drain once
                                 -- per engine tick, so 8ms converges on one update per rendered
                                 -- frame. Restart-only (LoopAsync's interval fixes at registration).
  friendly_fire       = true,
  imgui_key           = "F7",
  log_level           = "info",
  step_log            = true,    -- write dump/steps_crash.txt: one line per guarded hook body,
                                 -- appended and closed BEFORE it runs. A native access violation
                                 -- takes the process down with nothing flushed, so this file's
                                 -- last line is the only thing that names what died. Cheap, but
                                 -- it is a crash-hunting tool -- turn it off once the hunt is over.
  step_log_notify     = false,   -- also breadcrumb every object-construction notify. A save load
                                 -- streams in hundreds of Characters, so this buries the rest of
                                 -- the trail and adds file I/O to the seconds being investigated:
                                 -- on only when the suspect IS a notify listener.
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
