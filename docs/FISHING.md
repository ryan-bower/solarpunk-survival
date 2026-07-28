# Fishing (SolarpunkSurvival)

Weights are basis points (1/100 of a percent) of a 10,000-point table; the game's
roll is sum-relative, so these read directly as percentages.

Groups: **Starter** = NewStart, Chair, LowerNice's second river. **Mid** = GoldenMid
(carrot), Land (wheat), both Worm rivers (algae), LowerNice's main river (sunflower).
**Late** = Start, WildWinter, UShape, SnowCave.

Multipliers (stack multiplicatively, applied to the rare+jackpot band; the balance
is taken proportionally from everything else): diamond rod **x2**, storm (rain or
lightning) **x2**, early morning / early night **x1.5**. Full stack = **x6**.
Bulk ores are deliberately outside the band -- see tools/gen_fishing_tables.py.


## Starter

| Item | Tier | Base | Diamond rod (x2) | Storm (x2) | Storm+rod (x4) | Full stack (x6) |
|---|---|---|---|---|---|---|
| Leaf | filler | 34.5% | 33.94% | 33.94% | 32.82% | 31.7% |
| Raspberry | filler | 9.5% | 9.35% | 9.35% | 9.04% | 8.73% |
| Clay | filler | 9.5% | 9.35% | 9.35% | 9.04% | 8.73% |
| Stick | filler | 9.5% | 9.35% | 9.35% | 9.04% | 8.73% |
| Sand | filler | 9.5% | 9.35% | 9.35% | 9.04% | 8.73% |
| Cotton | filler | 9.5% | 9.35% | 9.35% | 9.04% | 8.73% |
| Wood Waste | filler | 6% | 5.9% | 5.9% | 5.71% | 5.51% |
| Scrap Metal | common | 5% | 4.92% | 4.92% | 4.76% | 4.59% |
| Glass | common | 2% | 1.97% | 1.97% | 1.9% | 1.84% |
| Mushroom | common | 1.6% | 1.57% | 1.57% | 1.52% | 1.47% |
| Oak Sapling | common | 0.8% | 0.79% | 0.79% | 0.76% | 0.73% |
| Birch Sapling | common | 0.8% | 0.79% | 0.79% | 0.76% | 0.73% |
| Chicken Egg | rare | 0.76% | 1.52% | 1.52% | 3.04% | 4.56% |
| Fishing Rod (worn) | rare | 0.45% | 0.9% | 0.9% | 1.8% | 2.7% |
| Cotton Seed | common | 0.2% | 0.2% | 0.2% | 0.19% | 0.18% |
| Diamond | jackpot | 0.2% | 0.4% | 0.4% | 0.8% | 1.2% |
| Diamond Rod (worn) | rare | 0.05% | 0.1% | 0.1% | 0.2% | 0.3% |
| Diamond Rod (full) | jackpot | 0.05% | 0.1% | 0.1% | 0.2% | 0.3% |
| Solar Panel | jackpot | 0.05% | 0.1% | 0.1% | 0.2% | 0.3% |
| Gold Egg | jackpot | 0.04% | 0.08% | 0.08% | 0.16% | 0.24% |

Rare+jackpot band: **1.6%** base -> 3.2% (x2) -> 6.4% (x4) -> 9.6% (x6).

## Mid

| Item | Tier | Base | Diamond rod (x2) | Storm (x2) | Storm+rod (x4) | Full stack (x6) |
|---|---|---|---|---|---|---|
| Leaf | filler | 19.8% | 19.08% | 19.08% | 17.65% | 16.21% |
| Island specialty | filler | 9% | 8.67% | 8.67% | 8.02% | 7.37% |
| Raspberry | filler | 8.5% | 8.19% | 8.19% | 7.58% | 6.96% |
| Stick | filler | 8.5% | 8.19% | 8.19% | 7.58% | 6.96% |
| Sand | filler | 8.5% | 8.19% | 8.19% | 7.58% | 6.96% |
| Cotton | filler | 8.5% | 8.19% | 8.19% | 7.58% | 6.96% |
| Clay | filler | 8.5% | 8.19% | 8.19% | 7.58% | 6.96% |
| Scrap Metal | filler | 6% | 5.78% | 5.78% | 5.35% | 4.91% |
| Wood Waste | common | 5% | 4.82% | 4.82% | 4.46% | 4.09% |
| Iron Ore | common | 4% | 3.85% | 3.85% | 3.56% | 3.27% |
| Copper Ore | common | 3% | 2.89% | 2.89% | 2.67% | 2.46% |
| Glass | common | 2.4% | 2.31% | 2.31% | 2.14% | 1.96% |
| Mushroom | common | 1.6% | 1.54% | 1.54% | 1.43% | 1.31% |
| Maple Sapling | common | 0.8% | 0.77% | 0.77% | 0.71% | 0.65% |
| Alder Sapling | common | 0.8% | 0.77% | 0.77% | 0.71% | 0.65% |
| Tomato Seeds | common | 0.8% | 0.77% | 0.77% | 0.71% | 0.65% |
| Paprika Seeds | common | 0.8% | 0.77% | 0.77% | 0.71% | 0.65% |
| Chicken Egg | rare | 0.76% | 1.52% | 1.52% | 3.04% | 4.56% |
| Fishing Rod (worn) | rare | 0.72% | 1.44% | 1.44% | 2.88% | 4.32% |
| Truffle | jackpot | 0.57% | 1.14% | 1.14% | 2.28% | 3.42% |
| Diamond | jackpot | 0.4% | 0.8% | 0.8% | 1.6% | 2.4% |
| Cable (wire) | rare | 0.4% | 0.8% | 0.8% | 1.6% | 2.4% |
| Fish Statue | jackpot | 0.2% | 0.4% | 0.4% | 0.8% | 1.2% |
| Solar Panel | jackpot | 0.15% | 0.3% | 0.3% | 0.6% | 0.9% |
| Diamond Rod (full) | jackpot | 0.1% | 0.2% | 0.2% | 0.4% | 0.6% |
| Diamond Rod (worn) | rare | 0.08% | 0.16% | 0.16% | 0.32% | 0.48% |
| Algae Drone | jackpot | 0.05% | 0.1% | 0.1% | 0.2% | 0.3% |
| Gold Egg | jackpot | 0.04% | 0.08% | 0.08% | 0.16% | 0.24% |
| Gold Truffle | jackpot | 0.03% | 0.06% | 0.06% | 0.12% | 0.18% |

Rare+jackpot band: **3.5%** base -> 7% (x2) -> 14% (x4) -> 21% (x6).

## Late

| Item | Tier | Base | Diamond rod (x2) | Storm (x2) | Storm+rod (x4) | Full stack (x6) |
|---|---|---|---|---|---|---|
| Algae | filler | 39.5% | 35.92% | 35.92% | 28.77% | 21.62% |
| Iron Ore | filler | 8% | 7.28% | 7.28% | 5.83% | 4.38% |
| Leaf | filler | 7.8% | 7.09% | 7.09% | 5.68% | 4.27% |
| Scrap Metal | filler | 6% | 5.46% | 5.46% | 4.37% | 3.28% |
| Copper Ore | filler | 6% | 5.46% | 5.46% | 4.37% | 3.28% |
| Quartz Ore | common | 5% | 4.55% | 4.55% | 3.64% | 2.74% |
| Pine Sapling | common | 5% | 4.55% | 4.55% | 3.64% | 2.74% |
| Wood Waste | common | 4% | 3.64% | 3.64% | 2.91% | 2.19% |
| Glass | common | 3% | 2.73% | 2.73% | 2.19% | 1.64% |
| Sand | common | 2.5% | 2.27% | 2.27% | 1.82% | 1.37% |
| Clay | common | 2.5% | 2.27% | 2.27% | 1.82% | 1.37% |
| Cobalt Ore | common | 2.4% | 2.18% | 2.18% | 1.75% | 1.31% |
| Circuitboard | rare | 1.6% | 3.2% | 3.2% | 6.4% | 9.6% |
| Truffle | jackpot | 1.52% | 3.04% | 3.04% | 6.08% | 9.12% |
| Diamond | jackpot | 1% | 2% | 2% | 4% | 6% |
| Fishing Rod (worn) | rare | 0.9% | 1.8% | 1.8% | 3.6% | 5.4% |
| Battery | rare | 0.8% | 1.6% | 1.6% | 3.2% | 4.8% |
| Cable (wire) | rare | 0.8% | 1.6% | 1.6% | 3.2% | 4.8% |
| Chicken Egg | rare | 0.57% | 1.14% | 1.14% | 2.28% | 3.42% |
| Solar Panel | jackpot | 0.3% | 0.6% | 0.6% | 1.2% | 1.8% |
| Algae Drone | jackpot | 0.2% | 0.4% | 0.4% | 0.8% | 1.2% |
| Diamond Rod (full) | jackpot | 0.2% | 0.4% | 0.4% | 0.8% | 1.2% |
| Fish Statue | jackpot | 0.2% | 0.4% | 0.4% | 0.8% | 1.2% |
| Diamond Rod (worn) | rare | 0.1% | 0.2% | 0.2% | 0.4% | 0.6% |
| Gold Truffle | jackpot | 0.08% | 0.16% | 0.16% | 0.32% | 0.48% |
| Gold Egg | jackpot | 0.03% | 0.06% | 0.06% | 0.12% | 0.18% |

Rare+jackpot band: **8.3%** base -> 16.6% (x2) -> 33.2% (x4) -> 49.8% (x6).
