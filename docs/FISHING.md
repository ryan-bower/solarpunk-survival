# Fishing (SolarpunkSurvival)

Weights are basis points (1/100 of a percent) of a 10,000-point table; the game's
roll is sum-relative, so these read directly as percentages.

Groups: **Starter** = NewStart, Chair, LowerNice's second river. **Mid** = GoldenMid
(carrot), Land (wheat), both Worm rivers (algae), LowerNice's main river (sunflower).
**Late** = Start, WildWinter, UShape, SnowCave.

Multipliers (stack multiplicatively, applied to the rare+jackpot band; the balance
is taken proportionally from everything else): diamond rod **x2**, early morning /
early night **x1.5**. Full stack = **x3**. Rain and storms do NOT touch the loot
bands -- wet weather adds **+5pp** to the skillshot chance instead
(fishing_minigame_weather_bonus).
Bulk ores are deliberately outside the band -- see tools/gen_fishing_tables.py.


## Starter

| Item | Tier | Base | Diamond rod (x2) | Twilight (x1.5) | Full stack (x3) |
|---|---|---|---|---|---|
| Leaf | filler | 34.5% | 33.94% | 34.22% | 33.38% |
| Raspberry | filler | 9.5% | 9.35% | 9.42% | 9.19% |
| Clay | filler | 9.5% | 9.35% | 9.42% | 9.19% |
| Stick | filler | 9.5% | 9.35% | 9.42% | 9.19% |
| Sand | filler | 9.5% | 9.35% | 9.42% | 9.19% |
| Cotton | filler | 9.5% | 9.35% | 9.42% | 9.19% |
| Wood Waste | filler | 6% | 5.9% | 5.95% | 5.8% |
| Scrap Metal | common | 5% | 4.92% | 4.96% | 4.84% |
| Glass | common | 2% | 1.97% | 1.98% | 1.93% |
| Mushroom | common | 1.6% | 1.57% | 1.59% | 1.55% |
| Oak Sapling | common | 0.8% | 0.79% | 0.79% | 0.77% |
| Birch Sapling | common | 0.8% | 0.79% | 0.79% | 0.77% |
| Chicken Egg | rare | 0.76% | 1.52% | 1.14% | 2.28% |
| Fishing Rod (worn) | rare | 0.45% | 0.9% | 0.68% | 1.35% |
| Cotton Seed | common | 0.2% | 0.2% | 0.2% | 0.19% |
| Diamond | jackpot | 0.2% | 0.4% | 0.3% | 0.6% |
| Diamond Rod (worn) | rare | 0.05% | 0.1% | 0.07% | 0.15% |
| Diamond Rod (full) | jackpot | 0.05% | 0.1% | 0.07% | 0.15% |
| Solar Panel | jackpot | 0.05% | 0.1% | 0.07% | 0.15% |
| Gold Egg | jackpot | 0.04% | 0.08% | 0.06% | 0.12% |

Rare+jackpot band: **1.6%** base -> 2.4% (x1.5) -> 3.2% (x2) -> 4.8% (x3).

## Mid

| Item | Tier | Base | Diamond rod (x2) | Twilight (x1.5) | Full stack (x3) |
|---|---|---|---|---|---|
| Leaf | filler | 19.8% | 19.08% | 19.44% | 18.36% |
| Island specialty | filler | 9% | 8.67% | 8.84% | 8.35% |
| Raspberry | filler | 8.5% | 8.19% | 8.35% | 7.88% |
| Stick | filler | 8.5% | 8.19% | 8.35% | 7.88% |
| Sand | filler | 8.5% | 8.19% | 8.35% | 7.88% |
| Cotton | filler | 8.5% | 8.19% | 8.35% | 7.88% |
| Clay | filler | 8.5% | 8.19% | 8.35% | 7.88% |
| Scrap Metal | filler | 6% | 5.78% | 5.89% | 5.56% |
| Wood Waste | common | 5% | 4.82% | 4.91% | 4.64% |
| Iron Ore | common | 4% | 3.85% | 3.93% | 3.71% |
| Copper Ore | common | 3% | 2.89% | 2.95% | 2.78% |
| Glass | common | 2.4% | 2.31% | 2.36% | 2.23% |
| Mushroom | common | 1.6% | 1.54% | 1.57% | 1.48% |
| Maple Sapling | common | 0.8% | 0.77% | 0.79% | 0.74% |
| Alder Sapling | common | 0.8% | 0.77% | 0.79% | 0.74% |
| Tomato Seeds | common | 0.8% | 0.77% | 0.79% | 0.74% |
| Paprika Seeds | common | 0.8% | 0.77% | 0.79% | 0.74% |
| Chicken Egg | rare | 0.76% | 1.52% | 1.14% | 2.28% |
| Fishing Rod (worn) | rare | 0.72% | 1.44% | 1.08% | 2.16% |
| Truffle | jackpot | 0.57% | 1.14% | 0.85% | 1.71% |
| Diamond | jackpot | 0.4% | 0.8% | 0.6% | 1.2% |
| Cable (wire) | rare | 0.4% | 0.8% | 0.6% | 1.2% |
| Fish Statue | jackpot | 0.2% | 0.4% | 0.3% | 0.6% |
| Solar Panel | jackpot | 0.15% | 0.3% | 0.23% | 0.45% |
| Diamond Rod (full) | jackpot | 0.1% | 0.2% | 0.15% | 0.3% |
| Diamond Rod (worn) | rare | 0.08% | 0.16% | 0.12% | 0.24% |
| Algae Drone | jackpot | 0.05% | 0.1% | 0.07% | 0.15% |
| Gold Egg | jackpot | 0.04% | 0.08% | 0.06% | 0.12% |
| Gold Truffle | jackpot | 0.03% | 0.06% | 0.04% | 0.09% |

Rare+jackpot band: **3.5%** base -> 5.25% (x1.5) -> 7% (x2) -> 10.5% (x3).

## Late

| Item | Tier | Base | Diamond rod (x2) | Twilight (x1.5) | Full stack (x3) |
|---|---|---|---|---|---|
| Algae | filler | 39.5% | 35.92% | 37.71% | 32.35% |
| Iron Ore | filler | 8% | 7.28% | 7.64% | 6.55% |
| Leaf | filler | 7.8% | 7.09% | 7.45% | 6.39% |
| Scrap Metal | filler | 6% | 5.46% | 5.73% | 4.91% |
| Copper Ore | filler | 6% | 5.46% | 5.73% | 4.91% |
| Quartz Ore | common | 5% | 4.55% | 4.77% | 4.09% |
| Pine Sapling | common | 5% | 4.55% | 4.77% | 4.09% |
| Wood Waste | common | 4% | 3.64% | 3.82% | 3.28% |
| Glass | common | 3% | 2.73% | 2.86% | 2.46% |
| Sand | common | 2.5% | 2.27% | 2.39% | 2.05% |
| Clay | common | 2.5% | 2.27% | 2.39% | 2.05% |
| Cobalt Ore | common | 2.4% | 2.18% | 2.29% | 1.97% |
| Circuitboard | rare | 1.6% | 3.2% | 2.4% | 4.8% |
| Truffle | jackpot | 1.52% | 3.04% | 2.28% | 4.56% |
| Diamond | jackpot | 1% | 2% | 1.5% | 3% |
| Fishing Rod (worn) | rare | 0.9% | 1.8% | 1.35% | 2.7% |
| Battery | rare | 0.8% | 1.6% | 1.2% | 2.4% |
| Cable (wire) | rare | 0.8% | 1.6% | 1.2% | 2.4% |
| Chicken Egg | rare | 0.57% | 1.14% | 0.85% | 1.71% |
| Solar Panel | jackpot | 0.3% | 0.6% | 0.45% | 0.9% |
| Algae Drone | jackpot | 0.2% | 0.4% | 0.3% | 0.6% |
| Diamond Rod (full) | jackpot | 0.2% | 0.4% | 0.3% | 0.6% |
| Fish Statue | jackpot | 0.2% | 0.4% | 0.3% | 0.6% |
| Diamond Rod (worn) | rare | 0.1% | 0.2% | 0.15% | 0.3% |
| Gold Truffle | jackpot | 0.08% | 0.16% | 0.12% | 0.24% |
| Gold Egg | jackpot | 0.03% | 0.06% | 0.04% | 0.09% |

Rare+jackpot band: **8.3%** base -> 12.45% (x1.5) -> 16.6% (x2) -> 24.9% (x3).
