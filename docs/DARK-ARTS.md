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
4. **The instrument.** Craft the mundane wand *(one cobalt, one stick — the recipe reveals itself
   only late in one's studies)* and HOLD it. Stand within the circle. Do not flinch.
5. **The storm.** Call the thunder (the old sign: **H**) or wait for true weather. When the
   pentagram hums, the storm has noticed. The next bolts belong to the circle.

When the bolt takes the offering, every held wand within the circle drinks it and becomes a
**Charged Electric Wand** — the cobalt at its tip burns diamond-bright and crackles with the
storm's own static. Aim and strike (left hand, as if tilling) and the sky answers WHERE YOU
LOOK, in any weather. Each cast spends the charge; to refill it, stand within five meters of a
falling bolt with the spent wand in hand and let it drink.

The sheep does not survive. That is the trade.

## Practical footnotes (out of character)

- Conditions checked host-side during storms: 1 live sheep + >=15 fence pieces + >=5 candles (any
  state) within 20 m; wand-holders within the same radius have their wand CHARGED in place when
  the sacrifice lands (features/wand.lua owns the state machine).
- The wand item is the Diamond Hoe (a cooked pak would be needed for a real new item; the mod
  hides the hoe's held visual and stands a 3x cobalt at the hand slot -- mundane -- which takes
  the diamond's material + electricity FX when charged). Book = Handbook prop.
- Casting: left click (the hoe's IA_Till input) while charged -> aimed bolt, ANY weather, spends
  the charge. Recharge: within 5 m of any strike you did not cast, wand in hand. `sps_wand`
  prints your wand state; `sps_ritual_test` stages the whole scene at the saved pentagram.
