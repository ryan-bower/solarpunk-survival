# The Mundane Grimoire — on the calling-down of sky-fire

*The lore now lives IN THE GAME as the **Tempest Codex** — a real craftable book, placed
anywhere and read like the survival guide. Its five sections (Origins / Pentagram / Implements /
Hydration Wand / Electrick Wand) are cooked into the content pak (`tools/pakkit`, `CODEX_PAGES`
in build_wand_pak.py). Both crafts are gated behind ONE research card, "The Dark Arts"
(cost: 1 beeswax + 1 clay + 1 leaf), which unlocks the codex (1 log, 2 leaves, 1 clay) and the
Mundane Wand (1 stick + 1 beeswax) together — crafted at the crafting bench, not in the
quick-craft hand menu. The blank rod then takes exactly ONE nature at the pentagram — water by
the bird's rite, or fire by the lamb's — and a rod once turned never turns again. This file
remains the out-of-game copy of the same tradition; lore lines also narrate
each stage in the UE4SS console as the rites progress. Knowledge is the first sacrifice — the
shape is easily made; the shape is NOT the weapon.*

## The Rite of the Quenched Rod (the path of water)

The blank rod holds nothing and argues with no one. Of the two natures it may be given, water is
the humbler — and by far the kinder creditor.

1. **The offering.** Pen a chicken in the heart of the pentagram (same circle as below: 15+
   fences, 5 candles within 20 m).
2. **The five wet tributes.** At the corners, beside the candles, lay one of each: **clean water**
   (a boiled carafe — dirty is refused), **beeswax**, a **leaf**, **clay**, and a **raspberry**.
3. **The storm.** Wait (or call the thunder). When the bolt takes the bird, every player inside
   the circle **holding a Mundane Wand** finds it turned river-blue: a **Hydration Wand**,
   brimming with **240 measures** — twice what the watering can carries. A blue rod already held
   is refilled to the brim; an **electrick rod is passed over** (it is beyond water now).

The Hydration Wand, drawn (V) and cast (left click):

- aimed at a **growbox** (or anything with a water storage): pours 20 measures — a full growbox
  in one gesture.
- aimed at a **teammate**: quenches them where they stand (+50 thirst), at the full reach of
  your eye. The rod keeps its own ledger of measures.
- **refilling** costs no ceremony: drink any water (pure or foul — the rod does not judge), or
  wade into pond or river, and the rod fills itself to the brim.

## The Rite of the Grounded Bolt (the path of fire)

The storm does not give. The storm trades. And mark: **the fire takes only the rod that is still
nothing** — a rod already turned to water is passed over, for a rod once turned never turns again.

1. **The offering.** Lead a sheep (a lamb will do; the sky does not measure age) to open ground.
2. **The circle.** Raise a pentagram of fences about the offering — fifteen posts at the least,
   within twenty meters of the beast.
3. **The five flames.** At each point of the star, a candle. Light them if you wish — the storm's
   first rain will snuff them regardless; it is the *placing* that the sky reads, not the flame.
4. **The five offerings.** At each corner, lay one gift upon the ground beside its candle:
   **rounded refined copper**, **raw iron ore**, **purified water** (boil it — the sky refuses
   silt), a **flower of the sun**, and **cloth that dressed an old wound**. Bare corners keep
   the storm silent; the console whispers which gift is missing.
5. **The storm.** Call the thunder (the old sign: **P**) or wait for true weather. When the
   pentagram hums, the storm has noticed. The next bolts belong to the circle.
6. **Stand within the circle.** Do not flinch.

When the bolt takes the offering, the fire moves into the blank rod: every **Mundane Wand** (and
every already-electrick rod, refilled) inside the circle becomes a **Lightning Wand
(charged)** — burning BRIGHT YELLOW and crackling with the storm's own static. Hydration rods are
passed over (the water keeps its own), as are the empty-handed. Draw or stow with
**V**. Aim and strike (left click, wand drawn) and the sky answers WHERE YOU LOOK, in any
weather. Each cast spends the charge — the wand dims to a **Lightning Wand (uncharged)**, old
dim gold, and silent. To refill it, stand within five meters of a falling bolt with the wand
drawn and let it drink.

When the bolt falls it takes everything laid before it: the lamb and all five offerings are
consumed — and every candle of the pentagram bursts alight at once, rain be damned.

The sheep does not survive. That is the trade.

## Practical footnotes (out of character)

- Conditions checked host-side during storms: the rite's animal (sheep for fire, chicken for
  water) + >=15 fence pieces + >=5 candles (any state) within 20 m (`ritual_radius`), plus that
  rite's five offerings dropped within 10 m (`ritual_corner_radius`) of any of the circle's
  candles — world item actors, per `mapping.ritual`:
  fire = BP_Copper/IronOre/CarafeDrinkableWater/Sunflower/Cloth_Item;
  water = BP_CarafeDrinkableWater/Beeswax/Leaf/Clay(or Clay_GrabItem)/Raspberry_Item
  (boiled water only; dirty is refused). On impact the animal AND the five offerings are
  destroyed and every circle candle is lit (Burning=true + OnRep_Burning, native replication).
  Every player within `ritual_payout_radius` (30 m) of the sacrifice gets the payout, judged on
  the rod IN HAND (features/wand.lua owns the state machine).
- The wands are REAL cooked items now (content pak rows MundaneWand / HydrationWand /
  ElectricWand / ChargedElectricWand, `sps_wand give`), but their in-hand look is still
  mod-drawn: the game's own hand-item pipeline holds a tinted SM_Stick. Tints by state
  (config `wand_mat_*`): mundane = log brown, hydration = river blue (M_Cobalt), uncharged
  electrick = solid yellow (M_Statue_Gold), charged = the textureless powered-state glow
  (M_Energy_On; live-swappable -- M_AirshipLight / M_Honey_Glass / M_Stick_Highlighted are the
  other stick-safe candidates). Inventory icons match (brown / blue / yellow / light-yellow
  sticks).
- A hydration pour plays the watering can's own splash on the watered growbox (the target's
  `BC_WateringParticleManager` component is asked to `PlayParticleEffect` -- plain BP calls;
  `wand_spray_seconds`), and every pour/quench/refill message counts the measures left.
- Draw/stow: **V** (config `wand_draw_key`) or `sps_wand draw`. Casting: left click (the generic
  hand interaction — no held tool needed) while drawn. Charged electrick -> aimed bolt, ANY
  weather, spends the charge (recharge: within 5 m of any strike you did not cast, wand drawn).
  Hydration -> pours on the nearest water storage near the aim point, or quenches the nearest
  teammate there (teammates outrank growboxes; `wand_pour_radius` 3 m around the aim point).
- Hydration internals: capacity `wand_hydration_max` 240 (= 2x `BP_HandItem_Watercan.
  MaxWaterlevel`), pour `wand_pour_amount` 20 (a growbox's `BC_WaterStorage.MaxWaterLevel`),
  quench `wand_hydrate_cost` 20 / `wand_hydrate_thirst` +50 (controller `AddThirst`, remote
  teammates via the game's own `CLIENT_AddThirst` RPC). Refills ride two poll-free hooks:
  `AddConsumeableEffects` (either carafe class = drinking) and `PlayWaterFootstep`/
  `PlayWaterLand` (wading, debounced 5 s). Either rite requires HOLDING the rod when the bolt
  lands, and judges the rod IN HAND: a blank rod takes that rite's nature and keeps it forever
  (the legacy host-side tier state now only covers pre-item / V-forged rods).
- `sps_wand` prints your wand state (+ measures and rung); `sps_wand forge` grants a test
  Mundane Wand; `sps_wand soak` a full Hydration Wand; `sps_wand charge` jumps to charged;
  `sps_wand give mundane|hydration|electric|charged` grants the real cooked items;
  `sps_ritual_test` stages the sheep scene at the saved pentagram.
