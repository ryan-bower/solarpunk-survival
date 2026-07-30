-- Fishing Overhaul (Milestone 3, user spec 2026-07-27).
--
-- Five jobs, all riding the game's own fishing flow (offline RE: rod_uber/char_uber dumps):
--   * LOOT TABLES: every BP_River_C's Loottable (per-instance TArray, no DataTable) is rewritten
--     from the generated spec below -- three island groups (starter/mid/late), per-10000 weights.
--     The whole cast/bite/catch flow runs on the OWNING CLIENT, so each machine writing its own
--     rivers IS per-player luck: your diamond rod doubles YOUR odds, not your co-op partner's.
--   * LUCK MULTIPLIERS: the rare+jackpot band scales by dawn/dusk x1.5 and diamond rod x2
--     (multiplicative); commons shrink to keep the table at 10000. Tables are rebuilt on every
--     state flip (IsDay watchdog, hand rebuild). Rain/storm do NOT touch the bands -- wet
--     weather adds fishing_minigame_weather_bonus (+5pp) to the SKILLSHOT chance instead.
--   * SEATED RODS (the pak rods -- DiamondFishingRod AND the vanilla-replacing ModFishingRod):
--     the content-pak rows are T5-typed -- new cooked TOOL rows are the proven world-load
--     crash -- so the game's two hardcoded class switches don't know them. The mod seats the
--     real BP_HandItem_FishingRod_C on equip and routes clicks to the pawn's own
--     Interaction_FishingRod(), which drains OUR item's durability through the shared path.
--   * THE VANILLA ROD IS REPLACED (user spec 2026-07-30): the pak repoints the FishingRod
--     recipe's end product at ModFishingRod (same persisted RecipyID -- saves keep the unlock),
--     the loot tables below drop the clone instead, and migrateVanillaRods swaps rods already
--     sitting in ANY inventory at world entry (host, in-place overwrite, durability preserved).
--     ModFishingRod is vanilla stats (durability 200, same icon and display name) on the
--     diamond rod's row typing, so it keeps its cast through UI closes and runs the mod's
--     minigames with no leaf-swap hack. "vanilla" remains a live kind only for legacy/pakless
--     sessions -- all its old shims (recast, leaf swap) stay as its fallback path.
--   * BITE SPLASH: the game plays S_FishingRod_Splash at 1.0 exactly when a fish bites; the mod
--     layers (fishing_splash_gain - 1) more on top at the bobber -- "300% splash when you hook".
--   * SKILLSHOT: 5% of bites (diamond rod: 25%, fishing_minigame_chance_diamond), the catch
--     click reveals one of THREE minigames (~even three-way roll, fishing_wheel/vsync_share): the
--     sliding-marker BAR (sweep speed rolled 1x..2x per bar) or the spinner WHEEL (constant
--     spin + constant deceleration, so the click->rest offset is fixed (450 deg at defaults) -- a
--     skill the player learns; only the zone's angle is random). Winning either guarantees a
--     rare/jackpot roll (diamond rod: smaller zone/arc, jackpot-only). Rendering lives in
--     features/fishing_ui.lua (our own viewport widget), driven per rendered frame by
--     core/animator; the click is judged at the os.clock() STAMPED IN THE HOOK BODY against
--     the same clock+formula that draws, so what the player saw when they clicked is what is
--     judged -- no scheduler latency in either direction.
--     Vanilla rod (legacy): the game's own Catch() is VM-internal (unhookable), so its
--     unavoidable reveal-catch is fed a worthless leaf by swapping the bobber's river to an
--     all-leaf table, then restoring. Seated rods (modded/diamond): the game ignores the click
--     entirely, so the bar reveals with no drop at all. While the bar is up the water sits
--     still (the rod's bite roll is parked, see suppressBites) and the resolve click reels the
--     line in -- win reels in the prize.
--   * The TAB inventory (any hand rebuild) can kill the rod actor, uncasting a thrown line.
--     SEATED rods: fixed at the DATA level -- their rows keep the wand-safe ItemType (T5
--     primary; the full tool taxonomy is the 109fcd9 world-load crash) but carry the TOOL
--     ItemInteractionType (make_row interaction=1 in tools/pakkit/build_wand_pak.py), so
--     UpdateHandMeshesAndModes takes the tool branch, misses its hardcoded class ladder, and
--     returns WITHOUT touching the hand actor: closing the inventory never uncasts it. (The old
--     consumable I2 typing routed every rebuild through UpdateHandConsumable's baked food map,
--     which nulled the hand: destroy + failed respawn per close.) VANILLA rod: its class IS in
--     the ladder, so rebuilds still destroy+respawn natively; recastAfterRebuild tracks its line
--     via RodInUse?/roll ticks and re-throws after the rebuild, pity ramp included. Do NOT try
--     to preserve the actor from the rebuild pre-hook instead: the chokepoint re-enters itself
--     (SetHandRBlueprintForBoth -> SwitchHandItem -> UpdateHandMeshesAndModes) and sync UObject
--     work inside that nested hook dispatch was the 2026-07-28 all-UE4SS AV crash cluster.
--
-- Fished-up rods arrive "worn": a fresh rod item appearing in the inventory right after a catch
-- click is stamped a random durability via the game's own OverwriteAndSaveItemAtIndex (the wand's
-- proven in-place slot rewrite). A fresh DIAMOND rod rolls worn-vs-full by the two table entries'
-- own weights -- the catch path can't tell us which entry won, but the ratio reproduces it.
local F = {}
local ctx

--------------------------------------------------------------------- generated drop spec
-- GENERATED by tools/gen_fishing_tables.py -- regenerate there, don't hand-edit (the script
-- asserts totals, band caps and the rod/gold splits, and emits docs/FISHING.md percentages).
-- w = weight per 10000. tier "rare"/"jackpot" = the luck-multiplier band. specialty = replaced
-- per-river with that island's vanilla signature item (mid group only).
local TABLES = {
  starter = {
    { cls = "BP_Leaf_Item_C", w = 3450 },  -- Leaf
    { cls = "BP_Raspberry_Item_C", w = 950 },  -- Raspberry
    { cls = "BP_Clay_Item_C", w = 950 },  -- Clay
    { cls = "BP_Stick_Item_C", w = 950 },  -- Stick
    { cls = "BP_Sand_Item_C", w = 950 },  -- Sand
    { cls = "BP_Cotton_Item_C", w = 950 },  -- Cotton
    { cls = "BP_Wood_Waste_Item_C", w = 600 },  -- Wood Waste
    { cls = "BP_Scrap_Metal_Item_C", w = 500 },  -- Scrap Metal
    { cls = "BP_Glass_Item_C", w = 200 },  -- Glass
    { cls = "BP_Mushroom_Item_C", w = 160 },  -- Mushroom
    { cls = "BP_Sapling_Oak_Item_C", w = 80 },  -- Oak Sapling
    { cls = "BP_BirchSapling_Item_C", w = 80 },  -- Birch Sapling
    { cls = "BP_Egg_Item_C", w = 76, tier = "rare" },  -- Chicken Egg
    { cls = "BP_ModFishingRod_Item_C", w = 45, tier = "rare" },  -- Fishing Rod (worn)
    { cls = "BP_Seed_Cotton_Item_C", w = 20 },  -- Cotton Seed
    { cls = "BP_Diamond_Item_C", w = 20, tier = "jackpot" },  -- Diamond
    { cls = "BP_DiamondFishingRod_Item_C", w = 5, tier = "rare" },  -- Diamond Rod (worn)
    { cls = "BP_DiamondFishingRod_Item_C", w = 5, tier = "jackpot" },  -- Diamond Rod (full)
    { cls = "BP_SolarPanel_Item_C", w = 5, tier = "jackpot" },  -- Solar Panel
    { cls = "BP_GoldEgg_Item_C", w = 4, tier = "jackpot" },  -- Gold Egg
  },
  mid = {
    { cls = "BP_Leaf_Item_C", w = 1980 },  -- Leaf
    { specialty = true, cls = false, w = 900 },  -- Island specialty
    { cls = "BP_Raspberry_Item_C", w = 850 },  -- Raspberry
    { cls = "BP_Stick_Item_C", w = 850 },  -- Stick
    { cls = "BP_Sand_Item_C", w = 850 },  -- Sand
    { cls = "BP_Cotton_Item_C", w = 850 },  -- Cotton
    { cls = "BP_Clay_Item_C", w = 850 },  -- Clay
    { cls = "BP_Scrap_Metal_Item_C", w = 600 },  -- Scrap Metal
    { cls = "BP_Wood_Waste_Item_C", w = 500 },  -- Wood Waste
    { cls = "BP_IronOre_Item_C", w = 400 },  -- Iron Ore
    { cls = "BP_CopperOre_Item_C", w = 300 },  -- Copper Ore
    { cls = "BP_Glass_Item_C", w = 240 },  -- Glass
    { cls = "BP_Mushroom_Item_C", w = 160 },  -- Mushroom
    { cls = "BP_MapleSapling_Item_C", w = 80 },  -- Maple Sapling
    { cls = "BP_AlderSapling_Item_C", w = 80 },  -- Alder Sapling
    { cls = "BP_Seed_Tomato_Item_C", w = 80 },  -- Tomato Seeds
    { cls = "BP_Seed_Paprika_Item_C", w = 80 },  -- Paprika Seeds
    { cls = "BP_Egg_Item_C", w = 76, tier = "rare" },  -- Chicken Egg
    { cls = "BP_ModFishingRod_Item_C", w = 72, tier = "rare" },  -- Fishing Rod (worn)
    { cls = "BP_Truffle_Item_C", w = 57, tier = "jackpot" },  -- Truffle
    { cls = "BP_Diamond_Item_C", w = 40, tier = "jackpot" },  -- Diamond
    { cls = "BP_CableConnectorSmall_Item_C", w = 40, tier = "rare" },  -- Cable (wire)
    { cls = "BP_KS_FishStatue_Item_C", w = 20, tier = "jackpot" },  -- Fish Statue
    { cls = "BP_SolarPanel_Item_C", w = 15, tier = "jackpot" },  -- Solar Panel
    { cls = "BP_DiamondFishingRod_Item_C", w = 10, tier = "jackpot" },  -- Diamond Rod (full)
    { cls = "BP_DiamondFishingRod_Item_C", w = 8, tier = "rare" },  -- Diamond Rod (worn)
    { cls = "BP_AutoFisher_Item_C", w = 5, tier = "jackpot" },  -- Algae Drone
    { cls = "BP_GoldEgg_Item_C", w = 4, tier = "jackpot" },  -- Gold Egg
    { cls = "BP_GoldTruffle_Item_C", w = 3, tier = "jackpot" },  -- Gold Truffle
  },
  late = {
    { cls = "BP_Algae_Item_C", w = 3950 },  -- Algae
    { cls = "BP_IronOre_Item_C", w = 800 },  -- Iron Ore
    { cls = "BP_Leaf_Item_C", w = 780 },  -- Leaf
    { cls = "BP_Scrap_Metal_Item_C", w = 600 },  -- Scrap Metal
    { cls = "BP_CopperOre_Item_C", w = 600 },  -- Copper Ore
    { cls = "BP_QuartzOre_Item_C", w = 500 },  -- Quartz Ore
    { cls = "BP_Sapling_Pine_Item_C", w = 500 },  -- Pine Sapling
    { cls = "BP_Wood_Waste_Item_C", w = 400 },  -- Wood Waste
    { cls = "BP_Glass_Item_C", w = 300 },  -- Glass
    { cls = "BP_Sand_Item_C", w = 250 },  -- Sand
    { cls = "BP_Clay_Item_C", w = 250 },  -- Clay
    { cls = "BP_CobaltOre_Item_C", w = 240 },  -- Cobalt Ore
    { cls = "BP_Circuitboard_Item_C", w = 160, tier = "rare" },  -- Circuitboard
    { cls = "BP_Truffle_Item_C", w = 152, tier = "jackpot" },  -- Truffle
    { cls = "BP_Diamond_Item_C", w = 100, tier = "jackpot" },  -- Diamond
    { cls = "BP_ModFishingRod_Item_C", w = 90, tier = "rare" },  -- Fishing Rod (worn)
    { cls = "BP_Battery_Item_C", w = 80, tier = "rare" },  -- Battery
    { cls = "BP_CableConnectorSmall_Item_C", w = 80, tier = "rare" },  -- Cable (wire)
    { cls = "BP_Egg_Item_C", w = 57, tier = "rare" },  -- Chicken Egg
    { cls = "BP_SolarPanel_Item_C", w = 30, tier = "jackpot" },  -- Solar Panel
    { cls = "BP_AutoFisher_Item_C", w = 20, tier = "jackpot" },  -- Algae Drone
    { cls = "BP_DiamondFishingRod_Item_C", w = 20, tier = "jackpot" },  -- Diamond Rod (full)
    { cls = "BP_KS_FishStatue_Item_C", w = 20, tier = "jackpot" },  -- Fish Statue
    { cls = "BP_DiamondFishingRod_Item_C", w = 10, tier = "rare" },  -- Diamond Rod (worn)
    { cls = "BP_GoldTruffle_Item_C", w = 8, tier = "jackpot" },  -- Gold Truffle
    { cls = "BP_GoldEgg_Item_C", w = 3, tier = "jackpot" },  -- Gold Egg
  },
}
F.TABLES = TABLES

-- The 12 rivers of MainLevel, keyed by world position (instance NAMES are not stable across
-- loads; positions are level data). Offline census 2026-07-27 (loothunt over MainLevel.umap),
-- islands named via WC_Map canvas slots + the world->map transform (see the fishing-loot memory).
-- group: starter = the spawn ring, mid = the crop islands (each keeps its vanilla signature item
-- as `specialty`), late = the far/winter islands. Saplings per group match the biome's trees.
local RIVERS = {
  { x = 3576,    y = -7019,   group = "starter" },                                -- NewStart
  { x = 183442,  y = -71195,  group = "starter" },                                -- Chair
  { x = 140895,  y = 115673,  group = "starter" },                                -- LowerNice north bank
  { x = -137107, y = -44448,  group = "mid", specialty = "BP_Carrot_Item_C" },    -- GoldenMid (carrots)
  { x = 47872,   y = 88401,   group = "mid", specialty = "BP_Wheat_Item_C" },     -- Land (wheat)
  { x = -177869, y = 144840,  group = "mid", specialty = "BP_Algae_Item_C" },     -- Worm west (algae)
  { x = -182335, y = 173634,  group = "mid", specialty = "BP_Algae_Item_C" },     -- Worm east (algae)
  { x = 139427,  y = 111531,  group = "mid", specialty = "BP_Sunflower_Item_C" }, -- LowerNice (sunflower)
  { x = -114313, y = 423542,  group = "late" },                                   -- Start
  { x = -226098, y = -269373, group = "late" },                                   -- WildWinter
  { x = 70182,   y = 353680,  group = "late" },                                   -- UShape
  { x = 487688,  y = 65143,   group = "late" },                                   -- SnowCave
}
F.RIVERS = RIVERS

--------------------------------------------------------------------- pure logic (unit-tested)
-- Combined rare+jackpot multiplier for the current conditions. Weather is NOT in here:
-- rain/storm moved off the loot bands onto the skillshot chance (user spec 2026-07-28).
function F.luckMult(diamond, twilight, cfg)
  cfg = cfg or {}
  local m = 1.0
  if diamond then m = m * (cfg.diamond or 2.0) end
  if twilight then m = m * (cfg.twilight or 1.5) end
  return m
end

-- Compose a river's weight list: specialty substitution + the multiplier band. tier entries
-- scale by `mult`; the rest shrink so the table still sums to its original total (the game's
-- GetRandomItemWeighted just sums whatever is there, but honest percentages need the invariant).
-- Returns { {cls=short, w=int, tier=...}, ... } -- classes still short names, resolution is I/O.
function F.composeTable(group, specialty, mult)
  local spec = TABLES[group]
  if not spec then return nil end
  local total, bonus = 0, 0
  for _, e in ipairs(spec) do
    total = total + e.w
    if e.tier then bonus = bonus + e.w end
  end
  local m = mult or 1.0
  -- defensive cap: the band may never swallow the table (late x6 = 49.8%, well clear)
  if bonus > 0 and m * bonus >= total then m = (total * 0.9) / bonus end
  local shrink = (bonus < total) and (total - m * bonus) / (total - bonus) or 1.0
  local out = {}
  for _, e in ipairs(spec) do
    local cls = e.cls
    if e.specialty then cls = specialty end
    if cls then
      local w = e.tier and (e.w * m) or (e.w * shrink)
      w = math.floor(w + 0.5)
      if w < 1 then w = 1 end
      out[#out + 1] = { cls = cls, w = w, tier = e.tier }
    end
  end
  -- integer drift lands on the big base entry (always entry 1: Leaf/Algae), keeping sum == total
  local sum = 0
  for _, e in ipairs(out) do sum = sum + e.w end
  if out[1] then out[1].w = math.max(1, out[1].w + (total - sum)) end
  return out
end

-- The skillshot's guaranteed pool: the group's rare+jackpot entries (jackpot-only for diamond).
function F.rewardPool(group, jackpotOnly)
  local out = {}
  for _, e in ipairs(TABLES[group] or {}) do
    if e.tier and e.cls and (not jackpotOnly or e.tier == "jackpot") then out[#out + 1] = e end
  end
  return out
end

-- Weighted pick with an injected 0..1 roll (deterministic under test).
function F.weightedPick(pool, r)
  local total = 0
  for _, e in ipairs(pool) do total = total + e.w end
  if total <= 0 then return nil end
  local x, acc = r * total, 0
  for _, e in ipairs(pool) do
    acc = acc + e.w
    if x < acc then return e end
  end
  return pool[#pool]
end

-- Nearest baked river to a world point (rivers are km apart; the bobber is metres from the pawn).
function F.nearestRiver(x, y)
  local best, bestD
  for _, r in ipairs(RIVERS) do
    local d = (x - r.x) ^ 2 + (y - r.y) ^ 2
    if not bestD or d < bestD then best, bestD = r, d end
  end
  return best, bestD
end

-- Skillshot marker position 0..1: a ping-pong sweep, `period` seconds out and back.
function F.markerPos(elapsed, period)
  if not period or period <= 0 then period = 1.6 end
  local ph = (elapsed % period) / period
  return ph < 0.5 and ph * 2 or 2 - ph * 2
end

function F.zoneHit(pos, center, width)
  -- the epsilon eats float dust at the exact drawn edge: what looks in, IS in
  return math.abs(pos - center) <= width / 2 + 1e-9
end

-- Per-bar speed roll (user spec): uniform between the configured speed and maxMult x it.
-- Returned as the PERIOD the renderer and judge both use (faster = shorter period).
function F.rollPeriod(base, maxMult, r)
  base = tonumber(base) or 1.6
  local m = 1 + (r or 0) * ((tonumber(maxMult) or 2) - 1)
  if m < 1 then m = 1 end
  return base / m
end

-- The GAP-SYNC skillshot ("vsync"): two vertical lanes the length of the sliding bar. A thin
-- line ping-pongs the LEFT lane, GROWING the longer you wait; a rect-gap-rect trio ping-pongs
-- the RIGHT lane at its own speed. Click when they line up: the line slides right and either
-- slots into the gap (win) or slams the trio's edge (lose). All pure math here; the renderer
-- and the judge share these exact functions (the screenshot rule needs both on one formula).

-- Ping-pong position with a per-side random phase offset (both lanes use the marker's sweep).
function F.oscPos(elapsed, period, phase)
  return F.markerPos((elapsed or 0) + (phase or 0) * (period or 1), period)
end

-- The line's growth: starts at 1x its base height, grows `rate` x base per second, capped.
function F.vsyncScale(elapsed, rate, cap)
  local s = 1 + (tonumber(rate) or 2.0) * math.max(0, elapsed or 0)
  local c = tonumber(cap) or 9.0
  if s > c then s = c end
  return s
end

-- A rolled oscillation period in [min, max] seconds (the vsync speed band: the sliding bar's
-- fastest roll down to half that speed).
function F.vsyncPeriod(minP, maxP, r)
  local lo, hi = tonumber(minP) or 0.8, tonumber(maxP) or 1.6
  if hi < lo then lo, hi = hi, lo end
  return hi - (r or 0) * (hi - lo)
end

-- Centers along the lane, in pixels. The line's center runs the full lane; the trio (rect,
-- gap, rect -- `span` px tall) runs the lane minus its own height, its GAP center inset by
-- rectH + gapH/2 from the trio's top.
function F.vsyncLineCenter(p, len)
  return (p or 0) * (len or 420)
end

function F.vsyncGapCenter(p, len, span, rectH, gapH)
  return (p or 0) * ((len or 420) - (span or 108)) + (rectH or 36) + (gapH or 36) / 2
end

-- The verdict: does the line (grown to scale x lineH) fit inside the gap right now?
function F.vsyncFits(lineC, scale, lineH, gapC, gapH)
  local h = (lineH or 3.6) * (scale or 1)
  local room = ((gapH or 36) - h) / 2
  if room < 0 then return false end
  return math.abs((lineC or 0) - (gapC or 0)) <= room + 1e-9
end

-- The spinner wheel. Constant spin speed and constant deceleration (both config, never rolled),
-- so the click->rest offset speed^2/(2*decel) is FIXED -- the learnable skill the user asked
-- for. Only the zone's angle is random per wheel. All angles in degrees, needle starts at 0 (up).
function F.wheelAngle(elapsed, speed)
  return ((elapsed or 0) * (speed or 360)) % 360
end

function F.wheelStopOffset(speed, decel)
  speed = tonumber(speed) or 360
  decel = tonumber(decel) or 360
  if decel < 30 then decel = 30 end -- a near-zero decel would spin ~forever; clamp keeps it a game
  return speed * speed / (2 * decel)
end

-- Where the needle comes to rest for a click at clickElapsed seconds after the wheel started.
function F.wheelFinal(clickElapsed, speed, decel)
  return (F.wheelAngle(clickElapsed, speed) + F.wheelStopOffset(speed, decel)) % 360
end

-- The slow-down animation: needle angle `since` seconds after the click, plus a done flag.
function F.wheelSlowdownPos(since, thetaClick, speed, decel)
  speed = tonumber(speed) or 360
  decel = tonumber(decel) or 360
  if decel < 30 then decel = 30 end
  local stopT = speed / decel
  local t = since
  if t >= stopT then t = stopT end
  return (thetaClick + speed * t - 0.5 * decel * t * t) % 360, since >= stopT
end

-- Angular zone test with wrap-around (zone may straddle 0/360).
function F.angleHit(angle, center, width)
  local d = ((angle - center + 540) % 360) - 180
  return math.abs(d) <= (width or 0) / 2 + 1e-9
end

-- Skillshot arm chance for this bite: the diamond-rod override wins while the diamond rod is
-- held, unless it is negative (-1 = "follow the base chance"). Clamped to a probability.
function F.miniChance(isDiamond, base, diamondChance)
  local c = tonumber(base) or 0
  local d = tonumber(diamondChance) or -1
  if isDiamond and d >= 0 then c = d end
  if c < 0 then c = 0 elseif c > 1 then c = 1 end
  return c
end

-- Rod kinds: "vanilla" = the game's own BP_FishingRod_Item (legacy -- replaced 2026-07-30,
-- survives only in pakless sessions and unmigrated corners), "modded" = the pak's
-- vanilla-stats replacement, "diamond" = the upgrade. SEATED kinds are the mod-driven pak
-- rods: the game's hardcoded switches don't know their rows, so the mod seats the real hand
-- actor and drives clicks itself -- and their cast survives every hand rebuild (interaction=1
-- row typing). Diamond-only STATS (x2 luck, 25% skillshot, jackpot pool) stay keyed on
-- "diamond"; this predicate keys the MECHANICS.
function F.seatedRod(kind)
  return kind == "diamond" or kind == "modded"
end

-- A fished-up rod's remaining durability from a 0..1 roll.
function F.wornDurability(r, maxDur, minFrac, maxFrac)
  local frac = (minFrac or 0.1) + r * ((maxFrac or 0.6) - (minFrac or 0.1))
  local d = math.floor(maxDur * frac)
  if d < 1 then d = 1 end
  if d > maxDur then d = maxDur end
  return d
end

-- P(a fresh diamond rod from the table was the WORN entry): the two entries' own weight ratio.
function F.wornShare(group, shortCls)
  local worn, full = 0, 0
  for _, e in ipairs(TABLES[group] or {}) do
    if e.cls == shortCls then
      if e.tier == "jackpot" then full = full + e.w else worn = worn + e.w end
    end
  end
  if worn + full <= 0 then return 1.0 end
  return worn / (worn + full)
end

-- The Durability number out of a slot's AdditionalSavedata JSON (nil = factory-fresh slot).
function F.durabilityFromSavedata(sd)
  if type(sd) ~= "string" then return nil end
  local n = sd:match('"Durability"%s*:%s*(%-?%d+)')
  return n and tonumber(n) or nil
end

--------------------------------------------------------------------- helpers
local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function defer(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then onGameThread(fn) end
end

-- Schedule-ONLY defer for hook bodies (see qol.lua: the inline fallback is the one thing a hook
-- body may never do -- re-entrant hook-body-touches-UObjects native-crashes uncatchably).
local function deferOnly(ms, fn)
  if pcall(ExecuteWithDelay, ms, fn) then return true end
  return false
end

local function fullFuncPath(obj, fnName)
  local full
  pcall(function()
    local cls = obj:GetClass()
    if not (cls and cls.ForEachFunction) then return end
    cls:ForEachFunction(function(fn)
      local n = ""
      pcall(function() n = fn:GetFName():ToString() end)
      if n == fnName then pcall(function() full = fn:GetFullName() end) end
    end)
  end)
  if full then return (full:gsub("^%S+%s+", "")) end
  return nil
end

local function cfg(k) return ctx.config.get(k) end

--------------------------------------------------------------------- state
local hooked = {}        -- key -> { preId, postId, path } (cleared on world change, qol pattern)
local hookWorldPc        -- local controller fullname the current registrations belong to
local classCache = {}    -- short class name -> UClass | false (classes RELOAD on world change)
local tablesBroken = false -- struct-array assignment failed -> stop trying for the session

local stormNow = false
local twilightUntil = -1e9
local lastIsDay = nil    -- nil until first read; flips open the twilight window
local dayToken = 0
local diamondHeld = false
local lastAppliedKey = nil

local lastClickAt = -1e9 -- accepted (debounced) rod-click time
local lastBiteAt = -1e9  -- PlayerCanCatch flip time
local lastSeatAt = -1e9
local sweepToken = 0
local freshRodSlots = {} -- snapshot at bite: { [idx] = true } of already-fresh rod slots
local mgKnownReward = nil -- "worn"|"full": the skillshot TOLD us which rod entry it granted

-- minigame
local mgReady = nil      -- nil = unprobed, true/false after the widget probe
local mgPending = false  -- bite rolled the 5%; the NEXT catch click reveals the bar
local mgActive = false
local mgToken = 0
local mgStart = 0
local mgCenter, mgWidth = 0.5, 0.18
local mgDiamond = false  -- diamond STATS for this skillshot (harder zone, jackpot-only pool)
local mgSeated = false   -- mod-driven rod (modded/diamond): no leaf swap, we reel the line
local mgGroup = "starter"
local mgRiver = nil      -- the leaf-swapped river actor (restored on resolve)
local mgRod = nil        -- the rod actor whose bite roll we parked (see suppressBites)
local mgSavedBonus = nil -- the player's real pity bonus, put back on resume
local lineOut = false    -- the local rod's line is in the water (survives the actor's death)
local lastBonus = nil    -- last seen unsuppressed pity bonus, handed to a recast rod
local lastRecastAt = 0   -- rebuilds echo; one recast per line lost
local mgClickAt = nil    -- os.clock() stamped in the click-hook BODY while a bar is up; the
                         -- animator job consumes it next frame (resolve ~1 frame after the click)
local mgLate = nil       -- timeout grace: a click STAMPED before the bar timed out still counts
                         -- even when its deferred processing lands after the fold
local mgJob = nil        -- core/animator token for the live bar's marker job
local mgKind = "bar"     -- which skillshot this is: "bar" | "wheel" | "vsync" (rolled at reveal)
local mgPeriod = 1.6     -- the bar's ROLLED sweep period (speed 1x..2x base, per bar); the judge
                         -- and the renderer must share it, so it is state, not a config read
local mgAwaitClick = false -- pure-Lua gate the hook body reads: the decisive click is still owed
                         -- (false during the wheel's slow-down so extra clicks don't re-stamp)
local mgSlow = nil       -- wheel slow-down in flight: { clickAt, thetaClick, final, hit }
local mgWheel = nil      -- wheel params fixed at reveal: { speed, decel, zc, zw }
local mgVs = nil         -- vsync params fixed at reveal: { perL, perR, phL, phR, lineH, rectH,
                         --   gapH, len, span, rate, cap }
local mgSlide = nil      -- vsync slide in flight: { clickAt, hit, lineC, gapC, scale } -- the
                         -- verdict is SEALED here (screenshot rule); the slide is pure reveal
local UI = require("features.fishing_ui") -- the renderer; this module never touches a widget
local forceMini = false  -- sps_fish_mini: arm on every bite (live testing)

--------------------------------------------------------------------- class resolution
local function resolveClass(short)
  local c = classCache[short]
  if c ~= nil then return c or nil end
  local m = ctx.map.fishing
  local dir = ctx.map.items and ctx.map.items.assetDir
  local path
  if short == m.rodHandClass then
    path = m.rodHandPath
  elseif dir then
    path = dir .. short:gsub("_C$", "") .. "." .. short
  end
  local cls = ctx.uehelp.classByName(short, path)
  classCache[short] = cls or false
  return cls
end

-- Short class names of the two pak rods (nil while the mapping rows are absent = no pak).
local function diamondShort()
  local m = ctx.map.fishing
  if not (ctx.map.items and ctx.map.items.classFmt and m.diamondRow) then return nil end
  return string.format(ctx.map.items.classFmt, m.diamondRow)
end

local function modShort()
  local m = ctx.map.fishing
  if not (ctx.map.items and ctx.map.items.classFmt and m.modRodRow) then return nil end
  return string.format(ctx.map.items.classFmt, m.modRodRow)
end

--------------------------------------------------------------------- table writer
local function currentMult()
  local twilight = os.clock() < twilightUntil
  return F.luckMult(diamondHeld, twilight, {
    diamond = cfg("fishing_diamond_mult"),
    twilight = cfg("fishing_twilight_mult"),
  }), twilight
end

-- Turn a composed spec into the real struct array and assign it. Weights of classes that don't
-- resolve (no content pak -> no diamond/gold classes) fold into entry 1 (the Leaf/Algae base),
-- keeping the total honest. Returns true only when the readback length matches.
local function writeRiver(river, entries)
  local m = ctx.map.fishing
  local arr, fold = {}, 0
  for _, e in ipairs(entries) do
    local cls = resolveClass(e.cls)
    if cls then
      arr[#arr + 1] = { [m.lootItemField] = cls, [m.lootWeightField] = e.w }
    else
      fold = fold + e.w
    end
  end
  if #arr < 3 then return false end -- even the base classes missing = nothing sane to write
  if fold > 0 then arr[1][m.lootWeightField] = arr[1][m.lootWeightField] + fold end
  if not ctx.uehelp.set(river, m.loottableProp, arr) then return false end
  local got
  pcall(function() got = river[m.loottableProp] end)
  return #ctx.uehelp.arrayItems(got) == #arr
end

-- Rewrite EVERY resident river from the spec at the current multiplier. Idempotent and cheap
-- (12 assignments); called on world entry and every luck-state flip. NEVER while a skillshot
-- window is live: the 30s world-entry retry once fired 215ms into a spinning wheel and the
-- process aborted (fatal, 2026-07-28 14:48) -- a 12-river struct-array rewrite stalls the
-- game thread under the ~86Hz animator lane AND reallocates the bite's leaf-swapped
-- Loottable out from under the rod's in-flight evaluation. Park the pass, retry when calm
-- (this also stops the pass silently un-leafing the minigame river mid-game).
local tablesDeferred = nil
local function minigameHot()
  return mgRiver ~= nil or mgActive or mgPending
    or ((ctx.anim and ctx.anim.active and ctx.anim.active()) or false)
end

function F.applyTables(reason)
  if tablesBroken or not (cfg("fishing_enabled") and cfg("fishing_tables")) then return end
  if minigameHot() then
    if not tablesDeferred then
      tablesDeferred = reason or "deferred"
      defer(1000, ctx.log.guard("fishing.tablesdefer", function()
        local r = tablesDeferred
        tablesDeferred = nil
        if r then onGameThread(function() F.applyTables(r) end) end
      end))
    else
      tablesDeferred = reason or tablesDeferred
    end
    return
  end
  local m = ctx.map.fishing
  local rivers = ctx.uehelp.findAll(m.riverClass)
  if #rivers == 0 then return end
  local mult, twilight = currentMult()
  local wrote, failed = 0, 0
  for _, river in ipairs(rivers) do
    if ctx.uehelp.isValid(river) then
      local loc
      pcall(function() loc = river:K2_GetActorLocation() end)
      loc = ctx.uehelp.vec(loc)
      if loc then
        local baked = F.nearestRiver(loc.X, loc.Y)
        local spec = baked and F.composeTable(baked.group, baked.specialty, mult)
        if spec and writeRiver(river, spec) then wrote = wrote + 1 else failed = failed + 1 end
      end
    end
  end
  lastAppliedKey = string.format("%s|%s", tostring(diamondHeld), tostring(twilight))
  if wrote > 0 then
    ctx.log.info(string.format("fishing: %d/%d river tables set (%s, x%.1f luck band)",
      wrote, #rivers, tostring(reason), mult))
  elseif failed > 0 then
    -- every write failed on real rivers: the struct-array assignment doesn't take on this build.
    -- Stand down for the session -- vanilla loot beats retry-spam (splash/diamond shim still run).
    tablesBroken = true
    ctx.log.error("fishing: river Loottable assignment failed on every river -- vanilla loot stands")
  end
end

local function checkMult(reason)
  local _, twilight = currentMult()
  local key = string.format("%s|%s", tostring(diamondHeld), tostring(twilight))
  if key ~= lastAppliedKey then onGameThread(function() F.applyTables(reason) end) end
end

--------------------------------------------------------------------- twilight watchdog
-- IsDay sampling on a slow self-rechaining one-shot (the storms.naturalWatchdog shape --
-- free-running UObject timers are the proven native crash; this touches one prop per pass,
-- re-found fresh, fully guarded). A flip opens the fishing_twilight_secs window.
local snapshotRods -- forward: the rod ledger (defined with its section below)

local function dayWatch(tok)
  local ms = math.max(5, math.floor((tonumber(cfg("fishing_daywatch_secs")) or 20) * 1000))
  pcall(ExecuteWithDelay, ms, ctx.log.guard("fishing.daywatch", function()
    if tok ~= dayToken then return end
    onGameThread(function()
      if tok ~= dayToken then return end
      local w = ctx.map.weather
      local mgr = w and ctx.uehelp.findFirst(w.managerClass)
      if mgr and w.isDayProp then
        local ok, v = ctx.uehelp.get(mgr, w.isDayProp)
        if ok and type(v) == "boolean" then
          if lastIsDay ~= nil and v ~= lastIsDay then
            twilightUntil = os.clock() + (tonumber(cfg("fishing_twilight_secs")) or 300)
            ctx.log.info(v and "fishing: the sun rises -- the waters stir (x1.5 luck)"
                           or "fishing: the sun sets -- the waters stir (x1.5 luck)")
          end
          lastIsDay = v
        end
      end
      checkMult("twilight")  -- catches window expiry too
      if snapshotRods then snapshotRods("watch") end
      dayWatch(tok)
    end)
  end))
end

--------------------------------------------------------------------- held-item identity
-- CurItemdataInHand's members carry GUID-suffixed FNames; resolve them once per session off the
-- pawn class (the wand's proven recipe -- S_Item.DisplayName reads empty, ItemActor is the truth).
local structMembers
local structMemberTries = 0
local function itemStructMembers(pawn)
  if structMembers ~= nil then return structMembers or nil end
  local prop = ctx.map.wand and ctx.map.wand.handItemDataProp
  if not prop then return nil end
  local found
  pcall(function()
    local cls = pawn:GetClass()
    if not (cls and cls.ForEachProperty) then return end
    cls:ForEachProperty(function(pr)
      local pn
      pcall(function() pn = pr:GetFName():ToString() end)
      if pn == prop then
        local st
        pcall(function() st = pr:GetStruct() end)
        if not st then pcall(function() st = pr.Struct end) end
        if st and st.ForEachProperty then
          local mm = {}
          st:ForEachProperty(function(mp)
            local mn
            pcall(function() mn = mp:GetFName():ToString() end)
            if mn then mm[mn:match("^(.-)_%d+_") or mn] = mn end
          end)
          if next(mm) then found = mm end
        end
      end
    end)
  end)
  if found then
    structMembers = found
  else
    structMemberTries = structMemberTries + 1
    if structMemberTries >= 5 then structMembers = false end
  end
  return structMembers or nil
end

-- "vanilla" | "modded" | "diamond" | nil for the item currently in this pawn's hand.
local function heldRodKind(pawn)
  local m = ctx.map.fishing
  local wm = ctx.map.wand
  local classFmt = ctx.map.items and ctx.map.items.classFmt
  if not (wm and wm.handItemDataProp and classFmt) then return nil end
  local ok, data = ctx.uehelp.get(pawn, wm.handItemDataProp)
  if not (ok and data ~= nil) then return nil end
  local members = itemStructMembers(pawn)
  if not (members and members.ItemActor) then return nil end
  local ia
  pcall(function() ia = data[members.ItemActor] end)
  if not ctx.uehelp.isValid(ia) then return nil end -- empty slot = null wrapper, never touch it
  local cn
  pcall(function() cn = ia:GetFName():ToString() end)
  if cn == m.rodItemClass then return "vanilla" end
  local ds, ms = diamondShort(), modShort()
  if ds and cn == ds then return "diamond" end
  if ms and cn == ms then return "modded" end
  return nil
end

--------------------------------------------------------------------- worn-rod stamping
local function durabilitySavedata(n)
  -- byte-exact copy of the game's own .sav shape (see features/wand.lua)
  return "{\r\n\t\"Durability\": " .. math.floor(n) .. "\r\n}"
end

local function rodShortNames()
  local m = ctx.map.fishing
  local names = { [m.rodItemClass] = "vanilla" }
  local ds, ms = diamondShort(), modShort()
  if ds then names[ds] = "diamond" end
  if ms then names[ms] = "modded" end
  return names
end

-- Indices (game 0-based) of inventory slots holding a FACTORY-FRESH rod (no Durability savedata).
local function freshRods(pawn)
  local m = ctx.map.fishing
  local wm = ctx.map.wand
  local out = {}
  local inv
  pcall(function() inv = pawn[wm.inventorySystemProp or "InventorySystem"] end)
  if not ctx.uehelp.isValid(inv) then return out end
  local arr
  pcall(function() arr = inv[m.invArrayProp] end)
  if arr == nil then return out end
  local names = rodShortNames()
  local i = 0
  pcall(function()
    arr:ForEach(function(_, el)
      local e
      pcall(function() e = el:get() end)
      if e == nil then e = el end
      local cls, sd
      pcall(function() cls = e[wm.slotItemField] end)
      if ctx.uehelp.isValid(cls) then
        local cn
        pcall(function() cn = cls:GetFName():ToString() end)
        local kind = cn and names[cn]
        if kind then
          pcall(function()
            local raw = e[wm.slotSavedataField]
            if type(raw) == "string" then sd = raw else sd = raw:ToString() end
          end)
          if not (type(sd) == "string" and sd:find("Durability", 1, true)) then
            out[i] = kind
          end
        end
      end
      i = i + 1
    end)
  end)
  return out
end

-- Stamp every fresh rod that APPEARED since the bite snapshot. Plain rods (modded, or a legacy
-- vanilla one) are always worn; diamond rods roll worn-vs-full by the table entries' weight
-- ratio (or by what the skillshot said it granted). Runs a few spaced passes -- the spawned
-- loot flies to the player, but a slow pickup must not slip through at full durability.
local function sweepNewRods(pawn, group, tok)
  if tok ~= sweepToken or not ctx.uehelp.isValid(pawn) then return end
  local m = ctx.map.fishing
  local wm = ctx.map.wand
  if not (wm and wm.overwriteSlotFn and wm.slotItemField and wm.slotQtyField and wm.slotSavedataField) then return end
  local now = freshRods(pawn)
  for idx, kind in pairs(now) do
    if not freshRodSlots[idx] then
      freshRodSlots[idx] = kind -- one stamp per slot per bite window
      local short = (kind == "diamond") and diamondShort()
                 or (kind == "modded") and modShort()
                 or m.rodItemClass
      local maxDur = (kind == "diamond") and m.diamondDurability or m.rodDurability
      local worn = true
      if kind == "diamond" then
        if mgKnownReward then
          worn = (mgKnownReward == "worn")
          mgKnownReward = nil
        else
          worn = math.random() < F.wornShare(group or "starter", short)
        end
      else
        mgKnownReward = nil -- worn-vs-full only distinguishes diamond entries; never let a
                            -- plain-rod grant leave a stale verdict for the next diamond
      end
      if worn then
        local dur = F.wornDurability(math.random(), maxDur,
          tonumber(cfg("fishing_rod_wear_min")) or 0.1, tonumber(cfg("fishing_rod_wear_max")) or 0.6)
        local inv
        pcall(function() inv = pawn[wm.inventorySystemProp or "InventorySystem"] end)
        local cls = resolveClass(short)
        if ctx.uehelp.isValid(inv) and cls then
          local slot = {
            [wm.slotItemField] = cls,
            [wm.slotQtyField] = 1,
            [wm.slotSavedataField] = durabilitySavedata(dur),
          }
          local ok = ctx.uehelp.call(inv, wm.overwriteSlotFn, slot, idx)
          if ok then
            ctx.log.info(string.format("fishing: the river's old rod shows its years (%d/%d durability, slot %d)",
              dur, maxDur, idx))
            -- redraw the bar the game never refreshes on authority (the wand's lesson)
            local pc
            pcall(function() pc = pawn[wm.localControllerProp or "LocalController"] end)
            local hb
            if ctx.uehelp.isValid(pc) then pcall(function() hb = pc[wm.hotbarWidgetProp or "UI_Hotbar"] end) end
            if ctx.uehelp.isValid(hb) and wm.hotbarRefreshFn then ctx.uehelp.call(hb, wm.hotbarRefreshFn) end
            if wm.invChangedFn then ctx.uehelp.call(inv, wm.invChangedFn) end
          end
        end
      else
        ctx.log.info("fishing: a PRISTINE diamond rod out of the water -- jackpot")
      end
    end
  end
end

local function scheduleSweeps(pawn, group)
  sweepToken = sweepToken + 1
  local tok = sweepToken
  for _, ms in ipairs({ 700, 2500, 6000 }) do
    defer(ms, ctx.log.guard("fishing.sweep", function()
      onGameThread(function() sweepNewRods(pawn, group, tok) end)
    end))
  end
end

--------------------------------------------------------------------- rod ledger
-- The diamond rod INTERMITTENTLY vanishes across a quit+rejoin (user report 2026-07-30; a
-- quit-save held zero rods across all 1470 slots while the same pak's wands persisted, and the
-- player loads in WITH the rod on good days -- so the loss is at load or mid-session, then the
-- next save bakes it in). Until it is caught red-handed this ledger detects AND heals:
--   * snapshotRods: cheap PLAYER-inventory count+durability snapshot -- rides the daywatch tick
--     and every game save -- persisted as a sidecar flag (write is host-gated by core/save, so
--     the ledger is effectively host-only; on clients it is a harmless in-memory no-op).
--   * rodLedgerSweep (world entry, once): audits every BC_InventorySystem (players, chests,
--     ship, deathloot, trash backing store). Rods the ledger promised that no INVENTORY holds
--     are restored loudly with their recorded durability -- loose ground rods don't settle the
--     debt, they get flown back into the pack first (see restoreRods). The log then dates the
--     loss: gone at entry = load-time; a daywatch "LEFT the player inventory" line mid-session
--     = something ate it live.
-- Snapshots are GATED until the entry audit ran (ledgerDone) -- else the first post-load
-- snapshot would record the loss as the new truth before the sweep could act on it.
-- BOTH pak rods are tracked (2026-07-30): the ModFishingRod replacement is a pak row too and
-- inherits the diamond rod's vanish risk wholesale. One flag per kind; the diamond flag keeps
-- its historical name so live saves carry their promise across this refactor.
local INV_SYS_CLASS = "BC_InventorySystem_C" -- every inventory in the game is this component
local ledgerDone = false
local ledgerToken = 0
local ledgerHolds = 0    -- restores unverified (or failed): snapshots must NOT overwrite a
                         -- promise with the still-rodless truth (live-burned 2026-07-30:
                         -- DEBUG_SpawnItems "succeeded", delivered nothing, and the instant
                         -- snapshot zeroed the ledger -- the rod debt was erased). A COUNT,
                         -- not a flag: the two kinds restore independently.

-- The ledger'd rod kinds this session (absent mapping rows drop out = no pak, no ledger).
local function ledgerKinds()
  local m = ctx.map.fishing
  local out = {}
  local ds = diamondShort()
  if ds then
    out[#out + 1] = { kind = "diamond", flag = "diamond_rod_ledger", short = ds,
                      maxDur = m.diamondDurability or 999, label = "diamond rod" }
  end
  local ms = modShort()
  if ms then
    out[#out + 1] = { kind = "modded", flag = "mod_rod_ledger", short = ms,
                      maxDur = m.rodDurability or 200, label = "fishing rod" }
  end
  return out
end

-- Durabilities (full max when fresh) of every `target`-class rod in ONE inventory component.
local function rodsInInventory(inv, target, maxDur)
  local out = {}
  local m, wm = ctx.map.fishing, ctx.map.wand
  pcall(function()
    local arr = inv[m.invArrayProp]
    arr:ForEach(function(_, el)
      local e = el
      pcall(function() e = el:get() end)
      if e == nil then e = el end
      local it
      pcall(function() it = e[wm.slotItemField] end)
      if ctx.uehelp.isValid(it) then
        local cn
        pcall(function() cn = it:GetFName():ToString() end)
        if cn == target then
          local sd
          pcall(function()
            local raw = e[wm.slotSavedataField]
            sd = (type(raw) == "string") and raw or raw:ToString()
          end)
          out[#out + 1] = F.durabilityFromSavedata(sd) or maxDur or 999
        end
      end
    end)
  end)
  return out
end

snapshotRods = function(reason)
  if not (ledgerDone and cfg("fishing_rod_ledger")) or ledgerHolds > 0 then return end
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  if not ctx.uehelp.isValid(pawn) then return end
  local inv
  pcall(function() inv = pawn[ctx.map.wand.inventorySystemProp or "InventorySystem"] end)
  if not ctx.uehelp.isValid(inv) then return end
  for _, spec in ipairs(ledgerKinds()) do
    local dur = rodsInInventory(inv, spec.short, spec.maxDur)
    local prev = ctx.save.getFlag(spec.flag)
    local prevN = (type(prev) == "table" and tonumber(prev.n)) or 0
    if #dur < prevN then
      ctx.log.warn(string.format(
        "fishing: rod ledger -- %d %s(s) LEFT the player inventory mid-session (%s), %d -> %d (stored/traded is fine; if not, this line dates the loss)",
        prevN - #dur, spec.label, tostring(reason), prevN, #dur))
    end
    local same = (#dur == prevN)
    if same and type(prev) == "table" and type(prev.dur) == "table" then
      for i = 1, #dur do
        if dur[i] ~= tonumber(prev.dur[i]) then same = false; break end
      end
    elseif prevN > 0 or #dur > 0 then
      same = false
    end
    if not same then ctx.save.setFlag(spec.flag, { n = #dur, dur = dur }) end
  end
end

-- How many diamond rods the player carries right now (-1 = inventory unreadable).
local function playerRodCount(pawn, target)
  local inv
  pcall(function() inv = pawn[ctx.map.wand.inventorySystemProp or "InventorySystem"] end)
  if not ctx.uehelp.isValid(inv) then return -1 end
  return #rodsInInventory(inv, target)
end

-- Every `target`-class rod ITEM ACTOR lying loose in the world (non-CDO). DEBUG_SpawnItems makes
-- exactly these (decoded 2026-07-30 from bp_controller.json: it spawns the item actor at the
-- player's location +500Z with FlyToPlayer=FALSE and never touches an inventory) -- so a loose
-- rod is either the vanish bug's leavings or this ledger's own earlier litter.
local function groundRodActors(target)
  local out = {}
  for _, a in ipairs(ctx.uehelp.findAll(target)) do
    if ctx.uehelp.isValid(a) then
      local fn = ""
      pcall(function() fn = a:GetFullName() end)
      if not fn:find("Default__", 1, true) then out[#out + 1] = a end
    end
  end
  return out
end

-- Hand a loose rod actor to the player through the game's own pickup path: park it on the pawn
-- (fresh pickup overlap) with FlyToPlayer set -- the same flag the game's fishing loot rides.
local function deliverRodActor(a, pawn)
  if not (ctx.uehelp.isValid(a) and ctx.uehelp.isValid(pawn)) then return false end
  local loc
  pcall(function() loc = ctx.uehelp.vec(pawn:K2_GetActorLocation()) end)
  if not loc then return false end
  ctx.uehelp.set(a, "ManualPickup", false)
  ctx.uehelp.set(a, "NoPickupTime", 0)
  ctx.uehelp.set(a, "FlyToPlayer", true)
  local at = { X = loc.X, Y = loc.Y, Z = loc.Z + 120 }
  return ctx.uehelp.call(a, "K2_SetActorLocation", at, false, {}, false)
      or ctx.uehelp.call(a, "K2_SetActorLocation", at, true)
end

-- Make good on `missing` rods, preferring rods already lying in the world over fresh spawns.
-- DEBUG_SpawnItems is a WORLD DROP at the player (see groundRodActors) -- the 2026-07-30 dock
-- incident was this very function "restoring" one rod three spawn-rounds in a row onto the dock
-- in front of a boarding player, while its pack-only recount kept scoring every round a failure.
-- So now: fresh spawns are capped at `missing` for the WHOLE session, every round first
-- re-delivers loose rods via deliverRodActor, fresh drops get flown in the same way 700ms after
-- spawning, and only the pack recount decides success. On final failure the ledger keeps its
-- promise (the hold is kept) so the next session's audit tries again.
local function restoreRods(spec, missing, durs)
  local target = spec.short
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not (target and ctx.uehelp.isValid(pawn) and ctx.uehelp.isValid(pc)) then return end
  local wm = ctx.map.wand
  local before = freshRods(pawn) -- pre-grant: pristine rods the player already owned stay theirs
  local baseCount = playerRodCount(pawn, target)
  if baseCount < 0 then return end
  ledgerHolds = ledgerHolds + 1
  local holdDropped = false
  local function dropHold()
    if not holdDropped then holdDropped = true; ledgerHolds = math.max(0, ledgerHolds - 1) end
  end
  local spawnBudget = missing -- hard cap on NEW world drops across ALL rounds this session

  local function stampWear()
    local worn = {}
    for _, d in ipairs(durs or {}) do
      local n = tonumber(d)
      if n and n < spec.maxDur then worn[#worn + 1] = n end
    end
    if #worn == 0 or not (wm and wm.overwriteSlotFn and wm.slotItemField
                          and wm.slotQtyField and wm.slotSavedataField) then
      return
    end
    local now = freshRods(pawn)
    local inv
    pcall(function() inv = pawn[wm.inventorySystemProp or "InventorySystem"] end)
    local cls = resolveClass(target)
    if not (ctx.uehelp.isValid(inv) and cls) then return end
    local wi = 1
    for idx, kind in pairs(now) do
      if kind == spec.kind and not before[idx] and wi <= #worn then
        local slot = {
          [wm.slotItemField] = cls,
          [wm.slotQtyField] = 1,
          [wm.slotSavedataField] = durabilitySavedata(worn[wi]),
        }
        if ctx.uehelp.call(inv, wm.overwriteSlotFn, slot, idx) then wi = wi + 1 end
      end
    end
  end

  local attempt
  attempt = function(round)
    if not ctx.uehelp.isValid(pawn) then dropHold(); return end
    local owed = missing - (math.max(0, playerRodCount(pawn, target)) - baseCount)
    if owed > 0 then
      -- loose rods first: they ARE the debt (or our own earlier drops) -- fly them in
      local preNames, sent = {}, 0
      for _, a in ipairs(groundRodActors(target)) do
        local fn = ""
        pcall(function() fn = a:GetFullName() end)
        preNames[fn] = true
        if sent < owed and deliverRodActor(a, pawn) then sent = sent + 1 end
      end
      local toSpawn = math.min(owed - sent, spawnBudget)
      local failWhy
      for _ = 1, toSpawn do
        local ok, _, why = ctx.items.giveByClass(pc, target, 1)
        if ok then spawnBudget = spawnBudget - 1 else failWhy = why end
      end
      if failWhy == "class" then
        ctx.log.warn("fishing: rod ledger -- the rod's item class would not load at all"
          .. " (pak not mounted this session?) -- no spawn attempted, the debt stands")
      end
      if toSpawn > 0 then
        -- the fresh drops fell at the player's feet with FlyToPlayer=false: fly them in too
        defer(700, ctx.log.guard("fishing.ledgerfly", function()
          onGameThread(function()
            for _, a in ipairs(groundRodActors(target)) do
              local fn = ""
              pcall(function() fn = a:GetFullName() end)
              if not preNames[fn] then deliverRodActor(a, pawn) end
            end
          end)
        end))
      end
    end
    defer(2500, ctx.log.guard("fishing.ledgerverify", function()
      onGameThread(function()
        if not ctx.uehelp.isValid(pawn) then dropHold(); return end
        local landed = math.max(0, playerRodCount(pawn, target)) - baseCount
        if landed >= missing then
          ctx.log.warn(string.format(
            "fishing: rod ledger -- %d %s(s) returned to your pack (verified)", landed, spec.label))
          stampWear()
          dropHold()
          snapshotRods("restore")
        elseif round < 3 then
          ctx.log.info(string.format(
            "fishing: rod ledger -- %d of %d landed in the pack, re-delivering (round %d)",
            landed, missing, round + 1))
          attempt(round + 1)
        else
          ctx.log.warn(string.format(
            "fishing: rod ledger -- %s delivery failed this session (%d of %d in the pack after 3 rounds) -- the debt stands and the next load will try again",
            spec.label, landed, missing))
          -- the hold is never dropped: the promise survives this broken session untouched
        end
      end)
    end))
  end
  attempt(1)
end

-- The once-per-world-entry audit. Retries (the 45s pass) only while not ledgerDone -- a world
-- still streaming in (few live inventory systems) cannot be audited without risking a dupe.
local function rodLedgerSweep(tok)
  if tok ~= ledgerToken or ledgerDone then return end
  if not cfg("fishing_rod_ledger") then ledgerDone = true; return end
  local specs = ledgerKinds()
  if #specs == 0 then ledgerDone = true; return end
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  if not ctx.uehelp.isValid(pawn) then return end
  local anyPromised = false
  for _, spec in ipairs(specs) do
    spec.prev = ctx.save.getFlag(spec.flag)
    spec.promised = (type(spec.prev) == "table" and tonumber(spec.prev.n)) or 0
    spec.invTotal = 0
    if spec.promised > 0 then anyPromised = true end
  end
  if not anyPromised then
    ledgerDone = true
    snapshotRods("entry")
    return
  end
  local systems = ctx.uehelp.findAll(INV_SYS_CLASS)
  local live = 0
  for _, sys in ipairs(systems) do
    if ctx.uehelp.isValid(sys) then
      local fn = ""
      pcall(function() fn = sys:GetFullName() end)
      if not fn:find("Default__", 1, true) then
        live = live + 1
        for _, spec in ipairs(specs) do
          if spec.promised > 0 then
            spec.invTotal = spec.invTotal + #rodsInInventory(sys, spec.short, spec.maxDur)
          end
        end
      end
    end
  end
  if live < 4 then return end -- chests not streamed in yet; the later pass retries
  ledgerDone = true
  -- Only rods in an INVENTORY keep the promise (stored/moved/traded is fine). A rod on the
  -- ground does not -- the player doesn't have it; restoreRods flies it back in as delivery
  -- stock before it ever spawns a fresh one (the 2026-07-30 dock litter counted here as
  -- "accounted for" while the player stood over three rods they could not pick up).
  for _, spec in ipairs(specs) do
    if spec.promised > 0 then
      local ground = groundRodActors(spec.short)
      local missing = spec.promised - spec.invTotal
      if missing <= 0 then
        ctx.log.info(string.format(
          "fishing: rod ledger -- all %d promised %s(s) accounted for (%d inventories)",
          spec.promised, spec.label, live))
        if #ground > 0 then
          ctx.log.info(string.format(
            "fishing: rod ledger -- %d loose %s(s) also lying in the world (sps_fish_rescue reels them in)",
            #ground, spec.label))
        end
      else
        ctx.log.warn(string.format(
          "fishing: rod ledger -- %d %s(s) VANISHED across the reload (inventories hold %d of the %d promised, %d loose on the ground; %d inventories swept) -- restoring",
          missing, spec.label, spec.invTotal, spec.promised, #ground, live))
        restoreRods(spec, missing, (type(spec.prev) == "table" and spec.prev.dur) or {})
      end
    end
  end
  -- restores in flight hold this off (ledgerHolds); a clean audit snapshots the entry truth
  snapshotRods("entry")
end

--------------------------------------------------------------------- vanilla-rod migration
-- THE VANILLA ROD IS REPLACED (user spec 2026-07-30): the pak repoints the FishingRod recipe
-- at ModFishingRod (same persisted RecipyID -- saves keep their unlock and craft the clone),
-- the loot tables drop the clone, and this one-time-per-world sweep swaps rods that already
-- exist in ANY inventory (players, chests, ship, deathloot) via the wand's proven in-place
-- slot overwrite -- quantity and Durability savedata preserved byte-for-byte. Host-gated:
-- inventories are host-authoritative and the host sees them all. HARD GATE on the clone's
-- class resolving: migrating into an unloadable class would BE the vanish bug, deliberately.
-- The same walk also CLAMPS diamond rods whose recorded durability exceeds the new max
-- (user spec 2026-07-30: 2000 -> 999) so old saves' bars don't read overfull.
local migrateDone = false
local migrateToken = 0

local function migrateVanillaRods(tok)
  if tok ~= migrateToken or migrateDone then return end
  if not (cfg("fishing_enabled") and cfg("fishing_rod_replace")) then migrateDone = true; return end
  if not ctx.net.isHost() then migrateDone = true; return end
  local m, wm = ctx.map.fishing, ctx.map.wand
  local ms = modShort()
  if not (ms and wm and wm.overwriteSlotFn and wm.slotItemField and wm.slotQtyField
          and wm.slotSavedataField) then
    migrateDone = true
    return
  end
  local cls = resolveClass(ms)
  if not cls then
    migrateDone = true
    ctx.log.warn("fishing: ModFishingRod class would not load (pak absent?) -- vanilla rods left alone this session")
    return
  end
  local ds = diamondShort()
  local diaCls = ds and resolveClass(ds) or nil
  local diaMax = m.diamondDurability or 999
  local systems = {}
  for _, sys in ipairs(ctx.uehelp.findAll(INV_SYS_CLASS)) do
    if ctx.uehelp.isValid(sys) then
      local fn = ""
      pcall(function() fn = sys:GetFullName() end)
      if not fn:find("Default__", 1, true) then systems[#systems + 1] = sys end
    end
  end
  if #systems < 4 then return end -- world still streaming in; the later pass retries
  migrateDone = true
  local swapped, clamped, failed = 0, 0, 0
  for _, sys in ipairs(systems) do
    -- collect first, overwrite after the walk -- never mutate the array under its own ForEach
    local hits = {}
    pcall(function()
      local arr = sys[m.invArrayProp]
      local i = 0
      arr:ForEach(function(_, el)
        local e = el
        pcall(function() e = el:get() end)
        if e == nil then e = el end
        local it
        pcall(function() it = e[wm.slotItemField] end)
        if ctx.uehelp.isValid(it) then
          local cn
          pcall(function() cn = it:GetFName():ToString() end)
          if cn == m.rodItemClass or (ds and cn == ds) then
            local qty, sd = 1, ""
            pcall(function() qty = tonumber(e[wm.slotQtyField]) or 1 end)
            pcall(function()
              local raw = e[wm.slotSavedataField]
              sd = (type(raw) == "string") and raw or raw:ToString()
            end)
            if cn == m.rodItemClass then
              hits[#hits + 1] = { idx = i, qty = qty, sd = sd or "", to = cls, why = "swap" }
            else
              local d = F.durabilityFromSavedata(sd)
              if d and d > diaMax and diaCls then
                hits[#hits + 1] = { idx = i, qty = qty, sd = durabilitySavedata(diaMax),
                                    to = diaCls, why = "clamp" }
              end
            end
          end
        end
        i = i + 1
      end)
    end)
    for _, h in ipairs(hits) do
      local slot = {
        [wm.slotItemField] = h.to,
        [wm.slotQtyField] = h.qty,
        [wm.slotSavedataField] = h.sd,
      }
      if ctx.uehelp.call(sys, wm.overwriteSlotFn, slot, h.idx) then
        if h.why == "swap" then swapped = swapped + 1 else clamped = clamped + 1 end
      else
        failed = failed + 1
      end
    end
  end
  if swapped > 0 or clamped > 0 or failed > 0 then
    ctx.log.info(string.format(
      "fishing: rod migration -- %d vanilla rod(s) reforged to the mod's pattern, %d diamond rod(s) clamped to %d durability (%d inventories%s)",
      swapped, clamped, diaMax, #systems,
      failed > 0 and string.format(", %d overwrites FAILED and were left as-is", failed) or ""))
    -- the local hotbar may be showing a swapped slot: redraw it (the wand's authority lesson)
    local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
    if ctx.uehelp.isValid(pawn) then
      local pc
      pcall(function() pc = pawn[wm.localControllerProp or "LocalController"] end)
      local hb
      if ctx.uehelp.isValid(pc) then pcall(function() hb = pc[wm.hotbarWidgetProp or "UI_Hotbar"] end) end
      if ctx.uehelp.isValid(hb) and wm.hotbarRefreshFn then ctx.uehelp.call(hb, wm.hotbarRefreshFn) end
      local inv
      pcall(function() inv = pawn[wm.inventorySystemProp or "InventorySystem"] end)
      if ctx.uehelp.isValid(inv) and wm.invChangedFn then ctx.uehelp.call(inv, wm.invChangedFn) end
    end
  else
    ctx.log.debug("fishing: rod migration -- nothing to reforge")
  end
end

--------------------------------------------------------------------- skillshot bar (UI)
-- While the bar is up the water must sit still. The rod's looping 1.5 s roll weighs
-- clamp(0.3 + RandomCatchBonus, 0, 1) -- splash particle, splash sound and the catch window all
-- live inside the success branch (rod ubergraph), so parking the bonus at -1000 silences the
-- whole bite without touching the timer. resumeBites puts the player's real pity value back.
local function suppressBites(pawn)
  local prop = ctx.map.fishing.biteBonusProp
  if not prop then return end
  local rod
  pcall(function() rod = pawn[ctx.map.wand.handItemProp or "CurHandItemFirstPerson"] end)
  if not ctx.uehelp.isValid(rod) then return end
  local ok, bonus = ctx.uehelp.get(rod, prop)
  if not ok then return end
  mgRod, mgSavedBonus = rod, tonumber(bonus) or 0
  ctx.uehelp.set(rod, prop, -1000)
end

local function resumeBites()
  local rod, bonus = mgRod, mgSavedBonus
  mgRod, mgSavedBonus = nil, nil
  if bonus == nil or not ctx.uehelp.isValid(rod) then return end
  ctx.uehelp.set(rod, ctx.map.fishing.biteBonusProp, bonus)
end

-- One-time capability probe, now delegated: fishing_ui tries its surface ladder (own viewport
-- widget -> overlay group -> flat images) and this just records the verdict. The animator must
-- also be alive -- a bar with a frozen marker is worse than no bar. nil = no world surface yet,
-- re-probed by the next deferred world pass (no leaf-swaps, no lost bites in the meantime).
local function probeUI()
  if mgReady ~= nil then return end
  local probed = UI.probe()
  if probed == nil then return end
  mgReady = ((probed == true) and (ctx.anim and ctx.anim.ok == true)) or false
  if mgReady then
    ctx.log.debug("fishing: skillshot surface ready (" .. tostring(UI.mode()) .. " mode)")
  else
    ctx.log.warn("fishing: skillshot disabled (surface=" .. tostring(probed) ..
      " animator=" .. tostring(ctx.anim and ctx.anim.ok) .. ")")
  end
end

--------------------------------------------------------------------- skillshot flow
local function restoreMgRiver()
  local river = mgRiver
  mgRiver = nil
  if not (river and ctx.uehelp.isValid(river)) then return end
  local baked
  local loc
  pcall(function() loc = river:K2_GetActorLocation() end)
  loc = ctx.uehelp.vec(loc)
  if loc then baked = F.nearestRiver(loc.X, loc.Y) end
  if baked then
    local mult = currentMult()
    local spec = F.composeTable(baked.group, baked.specialty, mult)
    if spec then writeRiver(river, spec) end
  end
end

-- The bite that arms the skillshot. VANILLA rod (legacy): the game's own input will catch on
-- the next click no matter what, so the bobber's river is swapped to all-leaf -- the "catch"
-- lands a worthless leaf and the bar reveals. SEATED rods (modded/diamond): the game ignores
-- their clicks entirely (we drive them), so nothing needs swapping and NOTHING drops when the
-- bar appears.
local function armMinigame(pawn)
  if not mgReady then return end
  local m = ctx.map.fishing
  local loc
  pcall(function() loc = pawn:K2_GetActorLocation() end)
  loc = ctx.uehelp.vec(loc)
  if not loc then return end
  local baked = F.nearestRiver(loc.X, loc.Y)
  if not baked then return end
  local kind = heldRodKind(pawn)
  local seated = F.seatedRod(kind)
  local river = nil
  if not seated then
    local bestD
    for _, r in ipairs(ctx.uehelp.findAll(m.riverClass)) do
      local rl
      pcall(function() rl = r:K2_GetActorLocation() end)
      rl = ctx.uehelp.vec(rl)
      if rl then
        local d = (rl.X - loc.X) ^ 2 + (rl.Y - loc.Y) ^ 2
        if not bestD or d < bestD then river, bestD = r, d end
      end
    end
    if not river then return end
    local leaf = resolveClass("BP_Leaf_Item_C")
    if not leaf then return end
    if not ctx.uehelp.set(river, m.loottableProp, { { [m.lootItemField] = leaf, [m.lootWeightField] = 1 } }) then
      return
    end
  end
  mgRiver = river
  mgGroup = baked.group
  mgDiamond = (kind == "diamond")
  mgSeated = seated
  mgPending = true
  mgToken = mgToken + 1
  local tok = mgToken
  -- unanswered bite window: put the table back and forget the whole thing
  defer(2000, ctx.log.guard("fishing.mgexpire", function()
    onGameThread(function()
      if tok == mgToken and mgPending then
        mgPending = false
        restoreMgRiver()
      end
    end)
  end))
end

local function grantReward(pawn)
  local pool = F.rewardPool(mgGroup, mgDiamond)
  -- only entries whose class actually resolves on this install (no pak = no diamond/gold rows)
  local live = {}
  for _, e in ipairs(pool) do
    if resolveClass(e.cls) then live[#live + 1] = e end
  end
  local e = F.weightedPick(live, math.random())
  if not e then
    ctx.log.warn("fishing: skillshot won but no prize class resolves (pak not mounted?) -- nothing to give")
    return
  end
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not ctx.uehelp.isValid(pc) then
    ctx.log.warn("fishing: skillshot won but no local controller -- the prize was lost")
    return
  end
  local isRod = rodShortNames()[e.cls] ~= nil
  if isRod then mgKnownReward = (e.tier == "jackpot") and "full" or "worn" end
  freshRodSlots = freshRods(pawn) -- pre-grant snapshot: only the granted rod reads as "new"
  -- DEBUG_SpawnItems is a WORLD DROP (+500Z, FlyToPlayer=false -- see core/items.lua): won over
  -- water, the prize free-falls past the pickup overlap and sinks (live 2026-07-30: "the waters
  -- yield: Diamond", the player got nothing). Snapshot the class's loose actors, then fly the
  -- fresh drop to the pawn exactly the way the rod ledger delivers its restores.
  local preNames = {}
  for _, a in ipairs(groundRodActors(e.cls)) do
    local fn = ""
    pcall(function() fn = a:GetFullName() end)
    preNames[fn] = true
  end
  local ok, _, why = ctx.items.giveByClass(pc, e.cls, 1)
  if not ok then
    ctx.log.warn("fishing: skillshot prize refused to spawn (" .. tostring(why) .. ")")
    return
  end
  ctx.log.info("*** SKILLSHOT! the waters yield: " .. e.cls:gsub("^BP_", ""):gsub("_Item_C$", "") .. " ***")
  if isRod then scheduleSweeps(pawn, mgGroup) else mgKnownReward = nil end
  defer(700, ctx.log.guard("fishing.prizefly", function()
    onGameThread(function()
      if not ctx.uehelp.isValid(pawn) then return end
      for _, a in ipairs(groundRodActors(e.cls)) do
        local fn = ""
        pcall(function() fn = a:GetFullName() end)
        if not preNames[fn] then deliverRodActor(a, pawn) end
      end
    end)
  end))
end

-- The bar folds a beat after the resolve flash; token-guarded so a delayed fold can never tear
-- down the NEXT bar (UI.show also folds leftovers first -- this is belt and braces).
local function foldSoon(ms)
  local tok = mgToken
  defer(ms, ctx.log.guard("fishing.mgfold", function()
    onGameThread(function()
      if tok == mgToken then UI.fold() end
    end)
  end))
end

local function logBarStats()
  local s = UI.stats()
  if s and s.n and s.n > 1 then
    ctx.log.debug(string.format("fishing: bar frames n=%d min=%.1f avg=%.1f p95=%.1f max=%.1f ms",
      s.n, s.min, s.avg, s.p95, s.max))
  end
end

-- The decisive click also reels the line in: the game's own input already does it for the
-- legacy vanilla rod (line out, no catch window = reel), a seated rod only moves when we
-- drive it. Inside the bite's ~1 s catch window that same call would CATCH instead -- wait it out.
local function reelLine(pawn)
  if not mgSeated then return end
  local m = ctx.map.fishing
  local rod
  pcall(function() rod = pawn[ctx.map.wand.handItemProp or "CurHandItemFirstPerson"] end)
  local okC, cc = ctx.uehelp.get(rod, m.canCatchProp)
  if okC and cc == true then
    defer(600, ctx.log.guard("fishing.mgreel", function()
      onGameThread(function()
        if ctx.uehelp.isValid(pawn) then ctx.uehelp.call(pawn, m.useRodFn) end
      end)
    end))
  else
    ctx.uehelp.call(pawn, m.useRodFn)
  end
end

local function grantSoon(pawn)
  -- the prize lands as the reel-in finishes, not before it starts
  defer(400, ctx.log.guard("fishing.mgprize", function()
    onGameThread(function() grantReward(pawn) end)
  end))
end

-- BAR resolve: THE SCREENSHOT RULE -- the judged position IS the frame the marker froze on
-- (pDrawn, the job's last drawn p). Frozen and judged are the same number by construction, so
-- "it stopped inside but missed" cannot happen, at any speed, in either direction. Earlier
-- schemes judged the stamped clock through markerPos and diverged from the freeze by lead or
-- frame gap -- a time-based lead scales with bar speed and outgrew the diamond zone (a
-- dead-center freeze judged a miss; player-reported). Prediction, not reaction, times clicks
-- on a periodic sweep, so no latency trim belongs here. The deferred fallback path (no drawn
-- frame to trust) still judges the stamped clock minus fishing_click_lead and freezes there.
local function resolveMinigame(pawn, clickAt, pDrawn)
  if not mgActive then return end
  mgActive = false
  mgClickAt, mgAwaitClick = nil, false
  lastClickAt = clickAt
  local p = pDrawn
  if p == nil then
    local lead = tonumber(cfg("fishing_click_lead")) or 0
    p = F.markerPos(math.max(0, clickAt - lead - mgStart), mgPeriod)
    UI.setMarker(p) -- degraded path: freeze at the judged spot outright
  end
  resumeBites()
  reelLine(pawn)
  lineOut = false
  local hit = F.zoneHit(p, mgCenter, mgWidth)
  UI.flash(hit and "hit" or "miss")
  logBarStats()
  foldSoon((tonumber(cfg("fishing_flash_secs")) or 0.22) * 1000)
  if hit then
    grantSoon(pawn)
  else
    ctx.log.info(string.format("fishing: missed the %s zone (%.0f%% vs %.0f%%) -- it got away",
      mgDiamond and "diamond" or "golden", p * 100, mgCenter * 100))
  end
  return p
end

-- WHEEL click: the outcome is sealed HERE (the rest position is a pure function of the stamped
-- click), but it stays secret while the needle visibly spins down -- the reveal is the stop.
-- The line stays in the water through the spin-down (player ask): the reel rides the REVEAL,
-- so the suspense holds until the needle rests. (Vanilla rod: the game's own input reels at
-- the click natively -- only the mod-driven diamond reel can be held back.)
local function wheelClicked(pawn, clickAt)
  if not mgActive or mgSlow or not mgWheel then return end
  mgAwaitClick = false
  lastClickAt = clickAt
  local lead = tonumber(cfg("fishing_click_lead")) or 0
  local el = math.max(0, clickAt - lead - mgStart)
  local final = F.wheelFinal(el, mgWheel.speed, mgWheel.decel)
  mgSlow = {
    clickAt = clickAt,
    thetaClick = F.wheelAngle(el, mgWheel.speed),
    final = final,
    hit = F.angleHit(final, mgWheel.zc, mgWheel.zw),
  }
end

-- WHEEL stop: the needle has rested -- reveal, reel the line, pay out, fold. Water wakes here
-- (it stayed parked through the slow-down, same as while the bar was up).
local function finishWheel(pawn, slow)
  if not mgActive then return end
  mgActive = false
  mgSlow = nil
  resumeBites()
  reelLine(pawn)
  lineOut = false
  UI.flash(slow.hit and "hit" or "miss")
  logBarStats()
  foldSoon((tonumber(cfg("fishing_flash_secs")) or 0.22) * 1000)
  if slow.hit then
    grantSoon(pawn)
  else
    ctx.log.info(string.format("fishing: the wheel rests at %.0f (zone %.0f) -- it got away",
      slow.final, mgWheel and mgWheel.zc or 0))
  end
end

-- VSYNC click: the verdict is SEALED here from the LAST DRAWN frame (screenshot rule -- the
-- freeze the player sees is the exact geometry judged). The slide that follows is pure
-- theatre: the line rides right and either slots home or slams the trio's edge.
local function vsyncClicked(pawn, clickAt, drawn)
  if not mgActive or mgSlide or not mgVs then return end
  mgAwaitClick = false
  lastClickAt = clickAt
  local vs = mgVs
  local pL, pR, scale
  if drawn then
    pL, pR, scale = drawn.pL, drawn.pR, drawn.scale
  else
    -- degraded path (no drawn frame to trust): judge the stamped clock minus the lead
    local lead = tonumber(cfg("fishing_click_lead")) or 0
    local el = math.max(0, clickAt - lead - mgStart)
    pL = F.oscPos(el, vs.perL, vs.phL)
    pR = F.oscPos(el, vs.perR, vs.phR)
    scale = F.vsyncScale(el, vs.rate, vs.cap)
    UI.setVsync(pL, pR, scale) -- freeze the picture at the judged spot outright
  end
  local lineC = F.vsyncLineCenter(pL, vs.len)
  local gapC = F.vsyncGapCenter(pR, vs.len, vs.span, vs.rectH, vs.gapH)
  mgSlide = { clickAt = clickAt, hit = F.vsyncFits(lineC, scale, vs.lineH, gapC, vs.gapH),
              lineC = lineC, gapC = gapC, scale = scale }
end

-- VSYNC reveal: the slide has landed -- flash, reel, pay out (or not), fold.
local function finishVsync(pawn, slide)
  if not mgActive then return end
  mgActive = false
  mgSlide = nil
  resumeBites()
  reelLine(pawn)
  lineOut = false
  UI.flash(slide.hit and "hit" or "miss")
  logBarStats()
  foldSoon((tonumber(cfg("fishing_flash_secs")) or 0.22) * 1000)
  if slide.hit then
    grantSoon(pawn)
  else
    ctx.log.info(string.format(
      "fishing: the line strikes the frame (%.0fpx off, grown %.1fx) -- it got away",
      math.abs(slide.lineC - slide.gapC), slide.scale))
  end
end

-- The 6 s timeout. mgLate keeps this skillshot's parameters warm for a 0.4 s grace window: a
-- click STAMPED before the timeout but processed after it (the deferred fallback path) still
-- judges. The wheel's slow-down phase never times out -- it resolves itself in under a second.
local function timeoutMinigame()
  if not mgActive then return end
  mgActive = false
  mgClickAt, mgAwaitClick, mgSlow, mgSlide = nil, false, nil, nil
  mgLate = { untilT = os.clock() + 0.4, kind = mgKind, start = mgStart,
             center = mgCenter, width = mgWidth, period = mgPeriod, wheel = mgWheel,
             vs = mgVs, diamond = mgDiamond, seated = mgSeated, group = mgGroup }
  UI.flash("timeout")
  logBarStats()
  foldSoon(150)
  resumeBites() -- they let it slip; the water wakes back up
  ctx.log.info("fishing: too slow -- the big one slips away")
end

-- The per-frame BAR job (core/animator, game thread, ~once per rendered frame). Built ONCE
-- per bar -- the animator contract forbids per-frame allocations. Checks the stamped click
-- BEFORE the timeout so a buzzer-beater stamp inside the window always counts. On the click
-- the marker freezes exactly where the last frame drew it -- NO post-click correction (both a
-- teleport and an eased settle were player-rejected as "go back" jank) -- and that same
-- frozen p is what gets judged (the screenshot rule; see resolveMinigame).
local function makeMarkerJob(tok, pawn)
  local lastP = nil
  return function(now)
    if tok ~= mgToken or not mgActive then return "stop" end
    local t = mgClickAt
    if t then
      mgClickAt = nil
      resolveMinigame(pawn, t, lastP)
      return "stop"
    end
    if now - mgStart > (tonumber(cfg("fishing_minigame_timeout")) or 6) then
      timeoutMinigame()
      return "stop"
    end
    lastP = F.markerPos(now - mgStart, mgPeriod)
    if not UI.setMarker(lastP) then
      -- the world ate the widgets mid-bar: fold what is left and wake the water back up
      mgActive = false
      mgClickAt, mgAwaitClick = nil, false
      UI.fold()
      resumeBites()
      return "stop"
    end
  end
end

-- The per-frame WHEEL job: constant spin until the stamped click, then the fixed-decel
-- slow-down, then the reveal. Same token/timeout/widget-death contracts as the bar job.
local function makeWheelJob(tok, pawn)
  return function(now)
    if tok ~= mgToken or not mgActive then return "stop" end
    local wl = mgWheel
    if not wl then return "stop" end
    local slow = mgSlow
    if not slow then
      local t = mgClickAt
      if t then
        mgClickAt = nil
        wheelClicked(pawn, t)
        slow = mgSlow
        if not slow then return "stop" end
      elseif now - mgStart > (tonumber(cfg("fishing_minigame_timeout")) or 6) then
        timeoutMinigame()
        return "stop"
      else
        if not UI.setNeedle(F.wheelAngle(now - mgStart, wl.speed)) then
          mgActive = false
          mgClickAt, mgAwaitClick = nil, false
          UI.fold()
          resumeBites()
          return "stop"
        end
        return
      end
    end
    local theta, done = F.wheelSlowdownPos(now - slow.clickAt, slow.thetaClick, wl.speed, wl.decel)
    if not UI.setNeedle(theta) then
      mgActive = false
      mgSlow = nil
      UI.fold()
      resumeBites()
      return "stop"
    end
    if done then
      finishWheel(pawn, slow)
      return "stop"
    end
  end
end

-- The per-frame VSYNC job: both lanes ping-pong (the line growing all the while) until the
-- stamped click, then the sealed verdict rides the slide animation to its reveal. Same
-- token/timeout/widget-death contracts as the other jobs.
local function makeVsyncJob(tok, pawn)
  local last = nil  -- { pL, pR, scale } of the last DRAWN frame (the judged screenshot)
  return function(now)
    if tok ~= mgToken or not mgActive then return "stop" end
    local vs = mgVs
    if not vs then return "stop" end
    local slide = mgSlide
    if not slide then
      local t = mgClickAt
      if t then
        mgClickAt = nil
        vsyncClicked(pawn, t, last)
        slide = mgSlide
        if not slide then return "stop" end
      elseif now - mgStart > (tonumber(cfg("fishing_minigame_timeout")) or 6) then
        timeoutMinigame()
        return "stop"
      else
        local el = now - mgStart
        last = last or {}
        last.pL = F.oscPos(el, vs.perL, vs.phL)
        last.pR = F.oscPos(el, vs.perR, vs.phR)
        last.scale = F.vsyncScale(el, vs.rate, vs.cap)
        if not UI.setVsync(last.pL, last.pR, last.scale) then
          mgActive = false
          mgClickAt, mgAwaitClick, mgSlide = nil, false, nil
          UI.fold()
          resumeBites()
          return "stop"
        end
        return
      end
    end
    local secs = tonumber(cfg("fishing_vsync_slide_secs")) or 0.25
    local frac = secs > 0 and math.min(1, (now - slide.clickAt) / secs) or 1
    if not UI.vsyncSlide(frac, slide.hit) then
      -- The shell died under the animation, but the verdict was SEALED at the click. Pay it
      -- out exactly as a landed slide does: dropping it here threw away catches the player had
      -- already won (with no flash and no log line to show for it) and left lineOut true on a
      -- rod that was never reeled in.
      finishVsync(pawn, slide)
      return "stop"
    end
    if frac >= 1 then
      finishVsync(pawn, slide)
      return "stop"
    end
  end
end

--------------------------------------------------------------------- the bite
local splashWave
local function playExtraSplash(rod)
  local gain = tonumber(cfg("fishing_splash_gain")) or 3.0
  local extra = gain - 1.0
  if extra <= 0.05 then return end
  local m = ctx.map.fishing
  if not ctx.uehelp.isValid(splashWave) then
    splashWave = StaticFindObject and StaticFindObject(m.splashWavePath)
    if not ctx.uehelp.isValid(splashWave) and LoadAsset then
      pcall(LoadAsset, (m.splashWavePath:gsub("%..*$", "")))
      splashWave = StaticFindObject and StaticFindObject(m.splashWavePath)
    end
    if not ctx.uehelp.isValid(splashWave) then return end
  end
  local loc
  pcall(function() loc = rod[m.swimmerProp]:K2_GetComponentLocation() end)
  if not loc then pcall(function() loc = rod:K2_GetActorLocation() end) end
  loc = ctx.uehelp.vec(loc)
  if not loc then return end
  local gs = StaticFindObject and StaticFindObject("/Script/Engine.Default__GameplayStatics")
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not (gs and ctx.uehelp.isValid(pc)) then return end
  local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
  -- arity fallbacks: the reflected PlaySoundAtLocation signature varies (evil_animals' recipe)
  if pcall(function() gs:PlaySoundAtLocation(pc, splashWave, loc, rot, extra, 1.0, 0.0, nil, nil, nil) end) then return end
  if pcall(function() gs:PlaySoundAtLocation(pc, splashWave, loc, rot, extra, 1.0, 0.0) end) then return end
  pcall(function() gs:PlaySoundAtLocation(pc, splashWave, loc, rot, extra, 1.0) end)
end

-- Wet weather (rain OR storm) raises the SKILLSHOT chance instead of the loot bands (user
-- spec). Storms come from the mod's own flag; rain is the day-night cycle's rain-transition
-- TIMELINE position (see mapping.weather.rainTimelineProp -- the only readable wetness on
-- this build), read fresh per bite (event-driven -- never polled on a timer).
local function wetNow()
  if stormNow then return true end
  local w = ctx.map.weather
  if not (w and w.rainTimelineProp) then return false end
  local mgr = ctx.uehelp.findFirst(w.managerClass)
  if not ctx.uehelp.isValid(mgr) then return false end
  local pos
  pcall(function()
    local tl = mgr[w.rainTimelineProp]
    if tl and tl:IsValid() then pos = tl:GetPlaybackPosition() end
  end)
  return (tonumber(pos) or 0) > 0.5
end

-- Deferred body of the ChanceForLoot hook: this rod just ticked its 1.5 s roll. A fresh
-- PlayerCanCatch=true edge IS the bite -- the game played its splash this same frame.
local function onLootTick(rod)
  if not ctx.uehelp.isValid(rod) then return end
  local m = ctx.map.fishing
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  if not ctx.uehelp.isValid(pawn) then return end
  -- only the LOCAL player's rod: remote players' hand actors exist here too, but their fishing
  -- state ticks on their machine -- and this machine's inventory snapshot would be the wrong one
  local held
  pcall(function() held = pawn[ctx.map.wand.handItemProp or "CurHandItemFirstPerson"] end)
  if not ctx.uehelp.sameObject(rod, held) then return end
  -- every roll tick = the line is in the water; remember it (and the pity ramp) so a hand
  -- rebuild that kills this actor can put both back (see recastAfterRebuild)
  lineOut = true
  if mgRod == nil then
    local okB, b = ctx.uehelp.get(rod, m.biteBonusProp)
    if okB then lastBonus = tonumber(b) end
  end
  local ok, canCatch = ctx.uehelp.get(rod, m.canCatchProp)
  if not (ok and canCatch == true) then return end
  if os.clock() - lastBiteAt < 1.2 then return end -- one bite, one splash
  lastBiteAt = os.clock()
  -- no splash layering while a skillshot is pending/up -- the water is supposed to be still
  if not (mgPending or mgActive) then playExtraSplash(rod) end
  freshRodSlots = freshRods(pawn) -- pre-catch snapshot for the worn-rod stamp
  local chance = F.miniChance(diamondHeld, cfg("fishing_minigame_chance"),
                              cfg("fishing_minigame_chance_diamond"))
  if chance > 0 and wetNow() then
    chance = math.min(1, chance + (tonumber(cfg("fishing_minigame_weather_bonus")) or 0.05))
  end
  if (forceMini or (chance > 0 and math.random() < chance)) and not (mgPending or mgActive) then
    armMinigame(pawn)
  end
end

--------------------------------------------------------------------- clicks
-- Debounced, deferred body of the IA_HandInteract hooks. clickAt is the os.clock() STAMPED in
-- the hook body -- the physical click time, not this deferred body's run time. Four jobs, in
-- priority order: resolve an active skillshot (fallback -- the animator usually beat us to it),
-- honor a buzzer-beater stamp, reveal a pending bar, drive the diamond rod / stamp worn rods.
local function onClick(pawn, clickAt)
  if not ctx.uehelp.isValid(pawn) then return end
  clickAt = clickAt or os.clock()
  if clickAt - lastClickAt < (tonumber(cfg("fishing_click_debounce")) or 0.3) then return end
  lastClickAt = clickAt

  if mgActive then
    if mgKind == "wheel" then
      if mgAwaitClick then wheelClicked(pawn, clickAt) end -- clicks during the slow-down are noise
    elseif mgKind == "vsync" then
      if mgAwaitClick then
        -- fallback path (the animator usually beat us here): seal AND reveal immediately --
        -- with no live job there is nobody to drive the slide theatre
        vsyncClicked(pawn, clickAt)
        if mgSlide then finishVsync(pawn, mgSlide) end
      end
    else
      resolveMinigame(pawn, clickAt)
    end
    return
  end
  if mgLate and os.clock() < mgLate.untilT
     and clickAt <= mgLate.start + (tonumber(cfg("fishing_minigame_timeout")) or 6) then
    -- stamped before the skillshot timed out, processed after: the click still counts
    local late = mgLate
    mgLate = nil
    local lead = tonumber(cfg("fishing_click_lead")) or 0
    local el = math.max(0, clickAt - lead - late.start)
    local hit, missLine
    if late.kind == "wheel" and late.wheel then
      local final = F.wheelFinal(el, late.wheel.speed, late.wheel.decel)
      hit = F.angleHit(final, late.wheel.zc, late.wheel.zw)
      missLine = string.format("fishing: the wheel rests at %.0f (zone %.0f) -- it got away",
        final, late.wheel.zc)
    elseif late.kind == "vsync" and late.vs then
      local vs = late.vs
      local lineC = F.vsyncLineCenter(F.oscPos(el, vs.perL, vs.phL), vs.len)
      local gapC = F.vsyncGapCenter(F.oscPos(el, vs.perR, vs.phR), vs.len, vs.span,
        vs.rectH, vs.gapH)
      hit = F.vsyncFits(lineC, F.vsyncScale(el, vs.rate, vs.cap), vs.lineH, gapC, vs.gapH)
      missLine = string.format(
        "fishing: the line strikes the frame (%.0fpx off) -- it got away",
        math.abs(lineC - gapC))
    else
      local p = F.markerPos(el, late.period or 1.6)
      hit = F.zoneHit(p, late.center, late.width)
      missLine = string.format("fishing: missed the %s zone (%.0f%% vs %.0f%%) -- it got away",
        late.diamond and "diamond" or "golden", p * 100, late.center * 100)
    end
    if hit then
      mgGroup, mgDiamond = late.group, late.diamond
      if late.seated then ctx.uehelp.call(pawn, ctx.map.fishing.useRodFn) end -- reel the prize in
      lineOut = false
      ctx.log.info("fishing: right at the buzzer -- the click counts")
      grantSoon(pawn)
    else
      ctx.log.info(missLine)
    end
    return
  end
  if mgPending and clickAt - lastBiteAt < 1.4 then
    -- legacy vanilla rod: this click is the game's own Catch() and it lands the placeholder
    -- leaf. Seated rods: the game ignores the click and we deliberately do NOT drive it -- the
    -- bar reveals with no drop at all; the bite's catch window shuts itself.
    mgPending = false
    defer(1200, ctx.log.guard("fishing.mgrestore", function()
      -- linger past the ~1 s catch window so a lightning second click can only ever land
      -- another leaf, never a real-table catch
      onGameThread(restoreMgRiver)
    end))
    -- Which skillshot this catch is: a three-way roll (user spec: the gap-sync game joins as a
    -- roughly even third option). Each fancy game carries a capability downgrade to "bar" --
    -- the wheel needs widget rotation, the gap-sync needs render-scale and a nesting surface.
    local roll = math.random()
    local wheelShare = tonumber(cfg("fishing_wheel_share")) or 0.34
    local vsyncShare = tonumber(cfg("fishing_vsync_share")) or 0.33
    if roll < wheelShare then mgKind = "wheel"
    elseif roll < wheelShare + vsyncShare then mgKind = "vsync"
    else mgKind = "bar" end
    if mgKind == "wheel" and not UI.wheelOK() then mgKind = "bar" end
    if mgKind == "vsync" and not UI.vsyncOK() then mgKind = "bar" end
    local shown = false
    if mgKind == "wheel" then
      mgVs = nil
      mgWheel = {
        speed = tonumber(cfg("fishing_wheel_speed")) or 360,
        decel = tonumber(cfg("fishing_wheel_decel")) or 360,
        zw = tonumber(cfg(mgDiamond and "fishing_wheel_zone_diamond" or "fishing_wheel_zone"))
             or (mgDiamond and 24 or 40),
        zc = math.random() * 360,
      }
      shown = UI.showWheel({ diamond = mgDiamond, centerDeg = mgWheel.zc, widthDeg = mgWheel.zw })
      if not shown then mgKind = "bar" end -- rotation just broke: same skillshot, bar clothes
    end
    if mgKind == "vsync" then
      mgWheel = nil
      local lineH = tonumber(cfg("fishing_vsync_line")) or 3.6
      local pMin = tonumber(cfg("fishing_vsync_period_min")) or 0.8
      local pMax = tonumber(cfg("fishing_vsync_period_max")) or 1.6
      local perL = F.vsyncPeriod(pMin, pMax, math.random())
      local perR = F.vsyncPeriod(pMin, pMax, math.random())
      -- the two lanes must run at visibly DIFFERENT speeds (user spec); re-roll near-twins.
      -- The threshold is a tenth of the band, so retuning the speeds keeps the same feel.
      local twin = math.abs(pMax - pMin) * 0.1
      for _ = 1, 4 do
        if math.abs(perL - perR) >= twin then break end
        perR = F.vsyncPeriod(pMin, pMax, math.random())
      end
      local rectH = lineH * 10
      mgVs = {
        perL = perL, perR = perR, phL = math.random(), phR = math.random(),
        lineH = lineH, rectH = rectH, gapH = rectH, span = rectH * 3,
        len = tonumber(cfg("fishing_bar_w")) or 420,
        rate = tonumber(cfg("fishing_vsync_grow_rate")) or 2.0,
        cap = tonumber(cfg("fishing_vsync_grow_cap")) or 9.0,
      }
      shown = UI.showVsync({ diamond = mgDiamond, lineH = lineH, rectH = rectH,
                             gapH = rectH, len = mgVs.len })
      if not shown then mgKind = "bar"; mgVs = nil end -- scale/nesting broke: bar clothes
    end
    if mgKind == "bar" then
      mgWheel, mgVs = nil, nil
      mgWidth = tonumber(cfg(mgDiamond and "fishing_minigame_zone_diamond" or "fishing_minigame_zone"))
                or (mgDiamond and 0.10 or 0.18)
      mgCenter = 0.22 + math.random() * 0.56
      -- per-bar speed roll: 1x..maxMult x the configured sweep speed (user spec)
      mgPeriod = F.rollPeriod(tonumber(cfg("fishing_minigame_period")) or 1.6,
        tonumber(cfg("fishing_bar_speed_max_mult")) or 2.0, math.random())
      shown = UI.show({ diamond = mgDiamond, center = mgCenter, width = mgWidth })
    end
    if shown then
      mgActive = true
      mgClickAt, mgLate, mgSlow, mgSlide = nil, nil, nil, nil
      mgAwaitClick = true
      suppressBites(pawn)
      mgStart = os.clock()
      mgToken = mgToken + 1
      mgJob = ctx.anim.start(mgKind == "wheel" and makeWheelJob(mgToken, pawn)
                             or mgKind == "vsync" and makeVsyncJob(mgToken, pawn)
                             or makeMarkerJob(mgToken, pawn))
      if not mgJob then -- animator died since the probe: no motion, no game
        mgActive = false
        mgAwaitClick = false
        UI.fold()
        resumeBites()
        mgReady = false
        ctx.log.warn("fishing: animator unavailable -- minigame disabled")
        return
      end
      if mgKind == "wheel" then
        ctx.log.info(mgDiamond and "fishing: something HUGE -- stop the wheel on the diamond arc!"
                               or "fishing: something big -- stop the wheel on the golden arc!")
      elseif mgKind == "vsync" then
        ctx.log.info(mgDiamond and "fishing: something HUGE -- slot the line through the gap!"
                               or "fishing: something big -- slot the line through the gap!")
      else
        ctx.log.info(mgDiamond and "fishing: something HUGE -- hit the diamond zone!"
                               or "fishing: something big -- hit the golden zone!")
      end
    else
      mgReady = false
      ctx.log.warn("fishing: skillshot failed to build -- minigame disabled")
    end
    return
  end

  local kind = heldRodKind(pawn)
  if F.seatedRod(kind) and cfg("fishing_enabled") then
    -- the game's switches don't know our rows -- drive its own event (cast/reel + durability)
    ctx.uehelp.call(pawn, ctx.map.fishing.useRodFn)
  end
  if kind then
    -- the toggle has settled by now (the game ran first, or we just drove it): the actor's own
    -- RodInUse? is the truth of whether the line is out
    local rodActor
    pcall(function() rodActor = pawn[ctx.map.wand.handItemProp or "CurHandItemFirstPerson"] end)
    if ctx.uehelp.isValid(rodActor) then
      local okU, inUse = ctx.uehelp.get(rodActor, ctx.map.fishing.rodInUseProp)
      if okU then lineOut = (inUse == true) end
    end
  end
  if kind and clickAt - lastBiteAt < 1.4 then
    -- a catch attempt inside the reel window: whatever it landed may be a factory-fresh rod
    scheduleSweeps(pawn, (function()
      local loc
      pcall(function() loc = pawn:K2_GetActorLocation() end)
      loc = ctx.uehelp.vec(loc)
      local baked = loc and F.nearestRiver(loc.X, loc.Y)
      return baked and baked.group or "starter"
    end)())
  end
end

--------------------------------------------------------------------- seated rod equip shim
local function armRodHook() end -- forward decl (defined under hooks below)

-- Seat the game's own rod hand actor for a pak rod (modded/diamond) -- the game's equip
-- switch doesn't know their rows, so the mod does what its fishing branch would have done.
local function seatRod(pawn, kind)
  local m = ctx.map.fishing
  local wm = ctx.map.wand
  if os.clock() - lastSeatAt < 0.5 then return end
  local cur
  pcall(function() cur = pawn[wm.handItemProp or "CurHandItemFirstPerson"] end)
  if ctx.uehelp.isValid(cur) and ctx.uehelp.className(cur) == m.rodHandClass then
    defer(150, armRodHook)
    return -- already holding a live rod actor (an echo of our own seat)
  end
  local rodCls = resolveClass(m.rodHandClass)
  if not rodCls then return end
  lastSeatAt = os.clock()
  ctx.uehelp.call(pawn, wm.handBlueprintFn, rodCls) -- spawn+attach the game's own rod actor
  ctx.uehelp.call(pawn, m.equipModeFn, 0)           -- what the game's fishing branch does
  pcall(function()
    -- the fishing pose; harmless no-op if the anim names moved on an update
    local anim = pawn[m.handsMeshProp]:GetAnimInstance()
    if anim then anim[m.animItemEnumProp] = m.animItemEnumValue end
  end)
  if kind == "diamond" then
    ctx.log.info("fishing: the diamond rod gleams in your hand")
  else
    -- the modded rod is the everyday rod now -- an info line per equip would be spam
    ctx.log.debug("fishing: rod seated (mod drives the line)")
  end
  defer(200, armRodHook)
end

-- Every hand rebuild hands the player a fresh rod actor with its line reeled in. If the line
-- was in the water when the old actor died (closing the TAB inventory is the big one), throw it
-- straight back and re-apply the pity ramp -- opening/closing the inventory doesn't cost the
-- player their cast. RodInUse? on the fresh actor guards the toggle: already-out never re-drives.
local function recastAfterRebuild(pawn, kind, attempt)
  -- TEMP diag (info): every exit path logs why -- demote to debug once the vanilla-rod
  -- recast is player-verified
  if not (ctx.uehelp.isValid(pawn) and lineOut and cfg("fishing_enabled")) then
    ctx.log.info("fishing: recast diag -- bail (pawn/lineOut/cfg) lineOut=" .. tostring(lineOut))
    return
  end
  if heldRodKind(pawn) ~= kind then
    ctx.log.info("fishing: recast diag -- bail (held " .. tostring(heldRodKind(pawn))
      .. " ~= " .. tostring(kind) .. ")")
    return
  end
  local m = ctx.map.fishing
  local rod
  pcall(function() rod = pawn[ctx.map.wand.handItemProp or "CurHandItemFirstPerson"] end)
  if not (ctx.uehelp.isValid(rod) and ctx.uehelp.className(rod) == m.rodHandClass) then
    ctx.log.info("fishing: recast diag -- hand not a rod actor yet (attempt "
      .. tostring(attempt or 1) .. ", " .. tostring(ctx.uehelp.className(rod)) .. ")")
    if (attempt or 1) < 3 then -- the diamond seat is itself deferred; give it another beat
      defer(600, ctx.log.guard("fishing.recast", function()
        onGameThread(function() recastAfterRebuild(pawn, kind, (attempt or 1) + 1) end)
      end))
    end
    return
  end
  local okU, inUse = ctx.uehelp.get(rod, m.rodInUseProp)
  if not okU or inUse == true then
    ctx.log.info("fishing: recast diag -- retired (RodInUse ok=" .. tostring(okU)
      .. " inUse=" .. tostring(inUse) .. ")")
    return
  end
  if os.clock() - lastRecastAt < 1.5 then
    -- Rebuilds echo, and one throw per lost line is the rule. But a SECOND genuine rebuild
    -- inside the window is not an echo -- open and close the inventory twice quickly and
    -- dropping it outright left a fresh, reeled-in rod with lineOut still true and nothing
    -- ever scheduled to fix it: no bites for the rest of the session. Retry once the window
    -- closes instead; a real echo simply finds RodInUse? true above and retires there.
    ctx.log.info("fishing: recast diag -- inside the echo window, retrying (attempt "
      .. tostring(attempt or 1) .. ")")
    if (attempt or 1) < 5 then
      defer(math.floor((1.5 - (os.clock() - lastRecastAt)) * 1000) + 100,
        ctx.log.guard("fishing.recast", function()
          onGameThread(function() recastAfterRebuild(pawn, kind, (attempt or 1) + 1) end)
        end))
    end
    return
  end
  lastRecastAt = os.clock()
  ctx.uehelp.call(pawn, m.useRodFn)
  ctx.log.info("fishing: the line flies back out")
  local bonus = lastBonus
  if bonus and bonus > 0 then
    -- the bobber's water-landing zeroes RandomCatchBonus (rod ubergraph); restore it after
    defer(2500, ctx.log.guard("fishing.recastpity", function()
      onGameThread(function()
        if not (ctx.uehelp.isValid(rod) and lineOut) then return end
        local okA, again = ctx.uehelp.get(rod, m.rodInUseProp)
        if okA and again == true then ctx.uehelp.set(rod, m.biteBonusProp, bonus) end
      end)
    end))
  end
end

-- Deferred body of the UpdateHandMeshesAndModes hook -- the ONE equip chokepoint (hotbar
-- switches AND every UI close funnel through it). Deferred on purpose: the chokepoint re-enters
-- itself, and sync UObject work inside that nested dispatch is the proven AV crash class (see
-- the header). A seated rod's actor SURVIVES a UI-close rebuild (I1 row typing, see header):
-- seatRod sees it live and stands down, recastAfterRebuild retires on RodInUse?. The legacy
-- vanilla rod's actor is already gone by the time this runs -- its cast line is re-thrown by
-- recastAfterRebuild below, not rescued.
local function onHandRebuilt(pawn)
  if not ctx.uehelp.isValid(pawn) then return end
  if mgActive or mgPending then
    -- the rebuild tore the rod out from under the skillshot: fold the bar, salvage the real
    -- pity value we parked, and put the leaf river back
    mgActive, mgPending = false, false
    mgClickAt, mgLate, mgAwaitClick = nil, nil, false
    mgToken = mgToken + 1
    if mgJob then ctx.anim.stop(mgJob); mgJob = nil end
    UI.fold()
    if (mgSlow and mgSlow.hit) or (mgSlide and mgSlide.hit) then
      -- the outcome was sealed at the click (wheel slow-down / vsync slide); the rebuild only
      -- ate the reveal animation. The player won it -- pay out anyway.
      ctx.log.info("fishing: the catch was already sealed -- the prize is yours")
      grantSoon(pawn)
    end
    mgSlow, mgSlide = nil, nil
    if mgSavedBonus ~= nil then lastBonus = mgSavedBonus end
    -- Put the real bite roll BACK on the rod before letting go of the handle. Dropping
    -- mgRod/mgSavedBonus outright left any rod that outlived the rebuild parked at the -1000
    -- suppressBites wrote -- clamp(0.3 + bonus, 0, 1) = 0, so the line sat in the water and
    -- could never get another bite; the recast salvage cannot cover it either (it bails on
    -- RodInUse? while the line is still out).
    resumeBites()
    restoreMgRiver()
  end
  local kind = heldRodKind(pawn)
  if kind then -- TEMP diag: what every rod-in-hand rebuild decides (demote with the rest)
    ctx.log.info("fishing: rebuild diag -- kind=" .. kind .. " lineOut=" .. tostring(lineOut))
  end
  local was = diamondHeld
  diamondHeld = (kind == "diamond")
  if F.seatedRod(kind) then
    seatRod(pawn, kind)
  elseif kind == "vanilla" then
    defer(200, armRodHook) -- the game seats its own rod actor; hook its ChanceForLoot
  else
    lineOut = false -- bare hands / another tool: stowing the rod is the deliberate uncast
  end
  if kind and lineOut then
    defer(450, ctx.log.guard("fishing.recast", function()
      onGameThread(function() recastAfterRebuild(pawn, kind, 1) end)
    end))
  end
  if diamondHeld ~= was then
    ctx.log.info(diamondHeld and "fishing: x2 luck while the diamond rod is in hand"
                             or "fishing: the diamond rod is stowed")
    checkMult("rod")
  end
end

--------------------------------------------------------------------- hooks (qol re-arm pattern)
local function clearHooks()
  for key, h in pairs(hooked) do
    if type(h) == "table" and h.path then pcall(UnregisterHook, h.path, h[1], h[2]) end
    hooked[key] = nil
  end
end

local function armHook(ownerClass, fnName, tag, body)
  if not (ownerClass and fnName) then return false end
  local key = tostring(ownerClass) .. ":" .. fnName
  if hooked[key] then return true end
  local inst = ctx.uehelp.findFirst(ownerClass)
  if not inst then return false end
  local path = fullFuncPath(inst, fnName)
  if not path then return false end
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if ok then
    hooked[key] = { pre, post, path = path }
    ctx.log.debug("fishing: hooked " .. path)
  end
  return ok == true
end

armRodHook = function()
  local m = ctx.map.fishing
  armHook(m.rodHandClass, m.lootTickFn, "fishing.bite", function(Context)
    -- hook body: stash the instance and get out (the one thing a body may safely do)
    local rod
    pcall(function() rod = Context:get() end)
    if not rod then return end
    deferOnly(0, function() onGameThread(function() onLootTick(rod) end) end)
  end)
end

local function armClickHooks()
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn and ctx.map.pawn.class)
  if not pawn then return end
  local wm = ctx.map.wand
  local exact, prefix = wm.castFnExact, wm.castFnPrefix
  local paths = {}
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""
      pcall(function() n = fn:GetFName():ToString() end)
      if (exact and n == exact) or (prefix and n:sub(1, #prefix) == prefix) then
        local full
        pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  for _, path in ipairs(paths) do
    if not hooked["click:" .. path] then
      local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard("fishing.click", function(Context)
        -- hook bodies run synchronously at input dispatch: t IS the physical click time. The
        -- stamp write is pure Lua (sanctioned in a body); the animator job consumes it on the
        -- next frame, so an active bar resolves ~1 frame after the click instead of 2 scheduler
        -- hops later. The deferred onClick below is the fallback for the same click -- it
        -- self-cancels on the stamped debounce when the animator got there first.
        local t = os.clock()
        local p
        pcall(function() p = Context:get() end)
        if not p then return end
        if mgActive and mgAwaitClick and mgClickAt == nil
           and t - lastClickAt >= (tonumber(cfg("fishing_click_debounce")) or 0.3) then
          mgClickAt = t
        end
        deferOnly(0, function() onGameThread(function() onClick(p, t) end) end)
      end))
      if ok then hooked["click:" .. path] = { pre, post, path = path } end
    end
  end
end

local function armHooks()
  local pawnClass = ctx.map.pawn and ctx.map.pawn.class
  armHook(pawnClass, ctx.map.wand and ctx.map.wand.handRebuildFn, "fishing.equip", function(Context)
    local p
    pcall(function() p = Context:get() end)
    if not p then return end
    deferOnly(150, function() onGameThread(function() onHandRebuilt(p) end) end)
  end)
  armClickHooks()
  armRodHook() -- no-op until a rod hand actor is resident; re-tried on every equip
end

--------------------------------------------------------------------- world lifecycle
local function applyAll()
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if pcNow and pcNow ~= hookWorldPc then
    -- new world = reloaded classes: dead hooks, dead class refs, a dead half-played minigame
    hookWorldPc = pcNow
    clearHooks()
    classCache = {}
    splashWave = nil
    structMembers, structMemberTries = nil, 0
    tablesBroken = false
    mgReady, mgPending, mgActive, mgRiver = nil, false, false, nil
    mgClickAt, mgLate, mgAwaitClick, mgSlow, mgWheel, mgVs, mgSlide =
      nil, nil, false, nil, nil, nil, nil
    if mgJob then ctx.anim.stop(mgJob); mgJob = nil end
    UI.reset() -- the old world's widgets are dead; the surface mode survives (a build fact)
    mgRod, mgSavedBonus = nil, nil -- the old world's rod actor died and took its bonus with it
    lineOut, lastBonus = false, nil
    mgToken = mgToken + 1
    lastAppliedKey = nil
    tablesDeferred = nil
    diamondHeld = false
    lastIsDay = nil
    stormNow = (ctx.services.isStormy and ctx.services.isStormy()) or false
    -- rod ledger: audit the fresh world once its chests have streamed in (two chances)
    ledgerDone = false
    ledgerHolds = 0
    ledgerToken = ledgerToken + 1
    local ltok = ledgerToken
    for _, ms in ipairs({ 15000, 45000 }) do
      defer(ms, ctx.log.guard("fishing.ledger", function()
        onGameThread(function() rodLedgerSweep(ltok) end)
      end))
    end
    -- vanilla-rod replacement: reforge inventories once the world has streamed in (two chances,
    -- interleaved with the ledger passes -- both are idempotent and order-independent)
    migrateDone = false
    migrateToken = migrateToken + 1
    local mtok = migrateToken
    for _, ms in ipairs({ 12000, 40000 }) do
      defer(ms, ctx.log.guard("fishing.migrate", function()
        onGameThread(function() migrateVanillaRods(mtok) end)
      end))
    end
  end
  armHooks()
  -- rivers stream in with the level; spaced passes catch the stragglers (idempotent writes)
  for _, ms in ipairs({ 3000, 12000, 30000 }) do
    defer(ms, ctx.log.guard("fishing.tables", function()
      onGameThread(function()
        armHooks()
        F.applyTables("world")
        probeUI()
      end)
    end))
  end
end

local seenPawn = nil
local function onCharacter()
  local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
  local fn
  if pawn then pcall(function() fn = pawn:GetFullName() end) end
  if fn and fn ~= seenPawn then
    seenPawn = fn
    applyAll()
  else
    armHooks() -- cheap and idempotent; catches late-loading classes
  end
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  if not ctx.config.get("fishing_enabled") then
    ctx.log.info("fishing: disabled by config")
    return false
  end
  if not ctx.gate.require(ctx.log, ctx.map, "fishing",
      { "fishing.riverClass", "fishing.loottableProp", "fishing.lootItemField",
        "fishing.lootWeightField", "fishing.rodHandClass", "fishing.lootTickFn" }) then
    return false
  end
  UI.init(ctx) -- the renderer degrades on its own (surface ladder); never gates the feature

  -- luck-state feeds
  ctx.bus.on("weather.changed", function(ev)
    -- storms no longer touch the loot bands -- wetNow() reads this flag for the skillshot bonus
    stormNow = ev and ev.storm == true
  end)
  -- rod ledger: a game save is the moment the world's truth gets baked -- snapshot with it, so
  -- the ledger always describes the save the next load will read
  ctx.bus.on("save.write", function()
    deferOnly(0, function() onGameThread(function() snapshotRods("save") end) end)
  end)
  dayToken = dayToken + 1
  dayWatch(dayToken)

  -- world entry / respawn / hot reload (the qol shape: every Character construction funnels here)
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", ctx.map.pawn and ctx.map.pawn.class,
    ctx.log.guard("fishing.character", function()
      deferOnly(400, function() onGameThread(onCharacter) end)
    end))
  -- a rod hand actor appearing = someone started fishing on this machine: hook its bite tick
  ctx.uehelp.onNewInstance("/Script/Engine.Actor", ctx.map.fishing.rodHandClass,
    ctx.log.guard("fishing.rodspawn", function()
      deferOnly(300, function() onGameThread(armRodHook) end)
    end))

  pcall(function()
    RegisterConsoleCommandHandler("sps_fish", function()
      local mult, twilight = currentMult()
      local led = {}
      for _, spec in ipairs(ledgerKinds()) do
        local v = ctx.save.getFlag(spec.flag)
        led[#led + 1] = string.format("%s=%s", spec.kind,
          tostring(type(v) == "table" and v.n or 0))
      end
      ctx.log.info(string.format(
        "fishing: mult x%.1f (diamond=%s storm=%s twilight=%s) tables=%s minigame=%s ledger=%s/%s migrated=%s",
        mult, tostring(diamondHeld), tostring(stormNow), tostring(twilight),
        tablesBroken and "BROKEN" or "ok", tostring(mgReady),
        table.concat(led, ","), ledgerDone and "audited" or "pre-audit",
        tostring(migrateDone)))
      return true
    end)
    RegisterConsoleCommandHandler("sps_fish_tables", function()
      onGameThread(function() F.applyTables("console") end)
      return true
    end)
    -- reels every loose pak rod (diamond or modded) in the world into the player's pack via
    -- the game's own pickup path -- the manual cleanup for ledger litter and stranded rods
    RegisterConsoleCommandHandler("sps_fish_rescue", function()
      onGameThread(ctx.log.guard("fishing.rescue", function()
        local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
        if not ctx.uehelp.isValid(pawn) then
          ctx.log.info("fishing: rescue -- no player pawn yet")
          return
        end
        local n = 0
        for _, spec in ipairs(ledgerKinds()) do
          for _, a in ipairs(groundRodActors(spec.short)) do
            if deliverRodActor(a, pawn) then n = n + 1 end
          end
        end
        ctx.log.info(string.format(
          "fishing: rescue -- %d loose rod(s) sent flying to your pack", n))
      end))
      return true
    end)
    -- force the vanilla-rod migration sweep now (live testing / re-run after a failed pass)
    RegisterConsoleCommandHandler("sps_fish_migrate", function()
      migrateDone = false
      migrateToken = migrateToken + 1
      local mtok = migrateToken
      onGameThread(ctx.log.guard("fishing.migrate", function() migrateVanillaRods(mtok) end))
      return true
    end)
    RegisterConsoleCommandHandler("sps_fish_mini", function()
      forceMini = not forceMini
      ctx.log.info("fishing: skillshot on EVERY bite " .. (forceMini and "ON (testing)" or "off"))
      return true
    end)
    RegisterConsoleCommandHandler("sps_anim_test", function()
      -- 3 s dummy job through the REAL animator path (touches only a Lua table): the cadence
      -- proof that the per-frame lane actually runs at frame rate on this machine
      local buf, t0 = {}, os.clock()
      local tok
      tok = ctx.anim.start(function(now)
        buf[#buf + 1] = now
        if now - t0 > 3.0 then
          local ds = {}
          for i = 2, #buf do ds[#ds + 1] = (buf[i] - buf[i - 1]) * 1000 end
          table.sort(ds)
          local sum = 0
          for _, d in ipairs(ds) do sum = sum + d end
          if #ds > 0 then
            ctx.log.info(string.format(
              "fishing: anim cadence n=%d min=%.1f avg=%.1f p95=%.1f max=%.1f ms",
              #buf, ds[1], sum / #ds, ds[math.max(1, math.floor(#ds * 0.95))], ds[#ds]))
          end
          return "stop"
        end
      end)
      ctx.log.info("fishing: anim cadence test " .. (tok and "running (3s)" or "FAILED -- animator down"))
      return true
    end)
  end)

  applyAll()
  ctx.log.info("fishing: ready -- new tables, twilight/diamond luck, wet-weather skillshots, worn rods, vanilla rod replaced")
  return true
end

return F
