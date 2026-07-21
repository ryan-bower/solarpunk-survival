# The Mundane Grimoire — on the calling-down of sky-fire

*The in-game "book" is the Handbook item carried as a prop; this is its text. Lore lines also
narrate each stage in the UE4SS console as the rite progresses.*

## The Rite of the Grounded Bolt

The storm does not give. The storm trades.

1. **The offering.** Lead a sheep (a lamb will do; the sky does not measure age) to open ground.
2. **The circle.** Raise a pentagram of fences about the offering — fifteen posts at the least,
   within twenty meters of the beast.
3. **The five flames.** At each point of the star, a candle. Light them if you wish — the storm's
   first rain will snuff them regardless; it is the *placing* that the sky reads, not the flame.
4. **The storm.** Call the thunder (the old sign: **H**) or wait for true weather. When the
   pentagram hums, the storm has noticed. The next bolts belong to the circle.
5. **Stand within the circle.** Do not flinch.

When the bolt takes the offering, the rite FORGES the instrument: every soul inside the circle
receives a **Lightning Wand (charged)** — a stick crowned with an oversized cobalt that burns
diamond-bright and crackles with the storm's own static. It leaps straight into the hand; draw
or stow it thereafter with **V**. Aim and strike (left click, wand drawn) and the sky answers
WHERE YOU LOOK, in any weather. Each cast spends the charge — the wand dims to a **Lightning
Wand (uncharged)**, diamond-colored still, but silent. To refill it, stand within five meters
of a falling bolt with the wand drawn and let it drink.

The sheep does not survive. That is the trade.

## Practical footnotes (out of character)

- Conditions checked host-side during storms: 1 live sheep + >=15 fence pieces + >=5 candles (any
  state) within 20 m; every player inside the radius gets the payout when the sacrifice lands —
  a wand forged (charged) if they had none, their existing wand charged if they did
  (features/wand.lua owns the state machine).
- The wand is a mod-managed TOOL, not an inventory item (a truly new item ID needs a cooked
  content pak — future work). Its model is built from the game's own assets on engine
  StaticMeshActors: the Stick item's mesh as the handle, the dropped Cobalt item's mesh (3x) at
  the tip; forged wands wear the Diamond item's material, and only the charged wand crackles.
  Book = Handbook prop.
- Draw/stow: **V** (config `wand_draw_key`) or `sps_wand draw`. Casting: left click (the generic
  hand interaction — no held tool needed) while drawn + charged -> aimed bolt, ANY weather,
  spends the charge. Recharge: within 5 m of any strike you did not cast, wand drawn.
- `sps_wand` prints your wand state; `sps_wand forge` grants a test Mundane Wand; `sps_wand
  charge` charges it; `sps_ritual_test` stages the whole scene at the saved pentagram.
