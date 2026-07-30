#!/usr/bin/env python3
"""Generate the fishing drop tables: the Lua data block for features/fishing.lua and the
percentage breakdowns in docs/FISHING.md. ONE source spec so the shipped table and the
documented table can never drift.

Weights are integers per 10,000 (0.01% resolution -- needed for the 5% gold splits and the
10% diamond-rod split). The in-game roll is sum-relative (GetRandomItemWeighted), so only
ratios matter; 10,000 keeps the docs readable as basis points.

Tier semantics:
  tier=None       -> filler/common/uncommon: never multiplied
  tier="rare"     -> rides the rare/jackpot bonus multiplier
  tier="jackpot"  -> same multiplier; additionally the diamond minigame's exclusive pool
Bulk ores (iron/copper/quartz/cobalt) are deliberately NOT in the bonus band: they are volume
resources whose rates the table already opens up island-by-island; a 6x storm multiplier on a
21% band would starve every common slot (the band would mathematically eat the table).
"""
import sys

# (name, class, weight per 10000, tier) -- tier None/"rare"/"jackpot"
STARTER = [
    ("Leaf",                "BP_Leaf_Item_C",               3450, None),
    ("Raspberry",           "BP_Raspberry_Item_C",           950, None),
    ("Clay",                "BP_Clay_Item_C",                950, None),
    ("Stick",               "BP_Stick_Item_C",               950, None),
    ("Sand",                "BP_Sand_Item_C",                950, None),
    ("Cotton",              "BP_Cotton_Item_C",              950, None),
    ("Wood Waste",          "BP_Wood_Waste_Item_C",          600, None),
    ("Scrap Metal",         "BP_Scrap_Metal_Item_C",         500, None),
    ("Glass",               "BP_Glass_Item_C",               200, None),
    ("Mushroom",            "BP_Mushroom_Item_C",            160, None),
    ("Oak Sapling",         "BP_Sapling_Oak_Item_C",          80, None),
    ("Birch Sapling",       "BP_BirchSapling_Item_C",         80, None),
    ("Chicken Egg",         "BP_Egg_Item_C",                  76, "rare"),
    ("Fishing Rod (worn)",  "BP_ModFishingRod_Item_C",        45, "rare"),
    ("Cotton Seed",         "BP_Seed_Cotton_Item_C",          20, None),
    ("Diamond",             "BP_Diamond_Item_C",              20, "jackpot"),
    ("Diamond Rod (worn)",  "BP_DiamondFishingRod_Item_C",     5, "rare"),
    ("Diamond Rod (full)",  "BP_DiamondFishingRod_Item_C",     5, "jackpot"),
    ("Solar Panel",         "BP_SolarPanel_Item_C",            5, "jackpot"),
    ("Gold Egg",            "BP_GoldEgg_Item_C",               4, "jackpot"),
]

MID = [
    ("Leaf",                "BP_Leaf_Item_C",               1980, None),
    ("Island specialty",    "SPECIALTY",                     900, None),
    ("Raspberry",           "BP_Raspberry_Item_C",           850, None),
    ("Stick",               "BP_Stick_Item_C",               850, None),
    ("Sand",                "BP_Sand_Item_C",                850, None),
    ("Cotton",              "BP_Cotton_Item_C",              850, None),
    ("Clay",                "BP_Clay_Item_C",                850, None),
    ("Scrap Metal",         "BP_Scrap_Metal_Item_C",         600, None),
    ("Wood Waste",          "BP_Wood_Waste_Item_C",          500, None),
    ("Iron Ore",            "BP_IronOre_Item_C",             400, None),
    ("Copper Ore",          "BP_CopperOre_Item_C",           300, None),
    ("Glass",               "BP_Glass_Item_C",               240, None),
    ("Mushroom",            "BP_Mushroom_Item_C",            160, None),
    ("Maple Sapling",       "BP_MapleSapling_Item_C",         80, None),
    ("Alder Sapling",       "BP_AlderSapling_Item_C",         80, None),
    ("Tomato Seeds",        "BP_Seed_Tomato_Item_C",          80, None),
    ("Paprika Seeds",       "BP_Seed_Paprika_Item_C",         80, None),
    ("Chicken Egg",         "BP_Egg_Item_C",                  76, "rare"),
    ("Fishing Rod (worn)",  "BP_ModFishingRod_Item_C",        72, "rare"),
    ("Truffle",             "BP_Truffle_Item_C",              57, "jackpot"),
    ("Diamond",             "BP_Diamond_Item_C",              40, "jackpot"),
    ("Cable (wire)",        "BP_CableConnectorSmall_Item_C",  40, "rare"),
    ("Fish Statue",         "BP_KS_FishStatue_Item_C",        20, "jackpot"),
    ("Solar Panel",         "BP_SolarPanel_Item_C",           15, "jackpot"),
    ("Diamond Rod (full)",  "BP_DiamondFishingRod_Item_C",    10, "jackpot"),
    ("Diamond Rod (worn)",  "BP_DiamondFishingRod_Item_C",     8, "rare"),
    ("Algae Drone",         "BP_AutoFisher_Item_C",            5, "jackpot"),
    ("Gold Egg",            "BP_GoldEgg_Item_C",               4, "jackpot"),
    ("Gold Truffle",        "BP_GoldTruffle_Item_C",           3, "jackpot"),
]

LATE = [
    ("Algae",               "BP_Algae_Item_C",              3950, None),
    ("Iron Ore",            "BP_IronOre_Item_C",             800, None),
    ("Leaf",                "BP_Leaf_Item_C",                780, None),
    ("Scrap Metal",         "BP_Scrap_Metal_Item_C",         600, None),
    ("Copper Ore",          "BP_CopperOre_Item_C",           600, None),
    ("Quartz Ore",          "BP_QuartzOre_Item_C",           500, None),
    ("Pine Sapling",        "BP_Sapling_Pine_Item_C",        500, None),
    ("Wood Waste",          "BP_Wood_Waste_Item_C",          400, None),
    ("Glass",               "BP_Glass_Item_C",               300, None),
    ("Sand",                "BP_Sand_Item_C",                250, None),
    ("Clay",                "BP_Clay_Item_C",                250, None),
    ("Cobalt Ore",          "BP_CobaltOre_Item_C",           240, None),
    ("Circuitboard",        "BP_Circuitboard_Item_C",        160, "rare"),
    ("Truffle",             "BP_Truffle_Item_C",             152, "jackpot"),
    ("Diamond",             "BP_Diamond_Item_C",             100, "jackpot"),
    ("Fishing Rod (worn)",  "BP_ModFishingRod_Item_C",        90, "rare"),
    ("Battery",             "BP_Battery_Item_C",              80, "rare"),
    ("Cable (wire)",        "BP_CableConnectorSmall_Item_C",  80, "rare"),
    ("Chicken Egg",         "BP_Egg_Item_C",                  57, "rare"),
    ("Solar Panel",         "BP_SolarPanel_Item_C",           30, "jackpot"),
    ("Algae Drone",         "BP_AutoFisher_Item_C",           20, "jackpot"),
    ("Diamond Rod (full)",  "BP_DiamondFishingRod_Item_C",    20, "jackpot"),
    ("Fish Statue",         "BP_KS_FishStatue_Item_C",        20, "jackpot"),
    ("Diamond Rod (worn)",  "BP_DiamondFishingRod_Item_C",    10, "rare"),
    ("Gold Truffle",        "BP_GoldTruffle_Item_C",           8, "jackpot"),
    ("Gold Egg",            "BP_GoldEgg_Item_C",               3, "jackpot"),
]

GROUPS = [("starter", STARTER), ("mid", MID), ("late", LATE)]

def check():
    for name, tbl in GROUPS:
        total = sum(w for _, _, w, _ in tbl)
        assert total == 10000, f"{name} sums to {total}, not 10000"
        bonus = sum(w for _, _, w, t in tbl if t)
        # the strongest stack (diamond rod x2 * twilight x1.5 = x3; storm/rain moved off the
        # bands onto the skillshot chance) must leave the non-bonus pool with weight. Keep the
        # historical x6 headroom anyway so config tweaks can't starve the commons.
        assert bonus * 6 < 10000, f"{name} bonus band {bonus} has no headroom (x6 guard)"
        # rod split: diamond (worn) must be exactly 10% of total rod-drop weight.
        # The plain-rod drop is the MOD clone (2026-07-30): the vanilla BP_FishingRod_Item_C is
        # replaced everywhere -- recipe end product repointed in the pak, inventories migrated by
        # features/fishing.lua -- because its class sits in the game's hardcoded hand ladder
        # (UI close uncasts it) and its Catch() is VM-internal (forces the leaf-swap skillshot
        # hack). The clone row is vanilla-stats (durability 200) with the diamond rod's proven
        # tool interaction typing.
        assert not any(c == "BP_FishingRod_Item_C" for _, c, _, _ in tbl), \
            f"{name} still drops the replaced vanilla rod"
        rods = {t: w for _, c, w, t in tbl if c in ("BP_ModFishingRod_Item_C",)}
        dia_worn = sum(w for _, c, w, t in tbl if c == "BP_DiamondFishingRod_Item_C" and t == "rare")
        rod_norm = sum(rods.values())
        assert abs(dia_worn / (dia_worn + rod_norm) - 0.10) < 0.005, f"{name} rod split off"
        # gold splits: 5% of eggs, 5% of truffles
        egg = sum(w for _, c, w, _ in tbl if c == "BP_Egg_Item_C")
        gold = sum(w for _, c, w, _ in tbl if c == "BP_GoldEgg_Item_C")
        assert abs(gold / (egg + gold) - 0.05) < 0.005, f"{name} egg gold split off"
        tru = sum(w for _, c, w, _ in tbl if c == "BP_Truffle_Item_C")
        gtru = sum(w for _, c, w, _ in tbl if c == "BP_GoldTruffle_Item_C")
        if tru or gtru:
            assert abs(gtru / (tru + gtru) - 0.05) < 0.005, f"{name} truffle gold split off"
        print(f"{name}: total {total}, bonus band {bonus} ({bonus/100:.2f}%), max x3 -> {bonus*3/100:.1f}%")

def lua():
    out = []
    out.append("local TABLES = {")
    for name, tbl in GROUPS:
        out.append(f"  {name} = {{")
        for label, cls, w, tier in tbl:
            f = []
            f.append(f'cls = "{cls}"' if cls != "SPECIALTY" else "specialty = true, cls = false")
            f.append(f"w = {w}")
            if tier:
                f.append(f'tier = "{tier}"')
            out.append(f"    {{ {', '.join(f)} }},  -- {label}")
        out.append("  },")
    out.append("}")
    return "\n".join(out)

def pct(w, total=10000):
    s = f"{w/100:.2f}".rstrip("0").rstrip(".")
    return s + "%"

def boosted(tbl, m):
    """Effective percentages under multiplier m (bonus x m, non-bonus shrunk proportionally)."""
    bonus = sum(w for _, _, w, t in tbl if t)
    shrink = (10000 - m * bonus) / (10000 - bonus)
    rows = []
    for label, cls, w, t in tbl:
        eff = w * m if t else w * shrink
        rows.append((label, eff))
    return rows

def md():
    L = []
    L.append("# Fishing (SolarpunkSurvival)\n")
    L.append("Weights are basis points (1/100 of a percent) of a 10,000-point table; the game's")
    L.append("roll is sum-relative, so these read directly as percentages.\n")
    L.append("Groups: **Starter** = NewStart, Chair, LowerNice's second river. **Mid** = GoldenMid")
    L.append("(carrot), Land (wheat), both Worm rivers (algae), LowerNice's main river (sunflower).")
    L.append("**Late** = Start, WildWinter, UShape, SnowCave.\n")
    L.append("Multipliers (stack multiplicatively, applied to the rare+jackpot band; the balance")
    L.append("is taken proportionally from everything else): diamond rod **x2**, early morning /")
    L.append("early night **x1.5**. Full stack = **x3**. Rain and storms do NOT touch the loot")
    L.append("bands -- wet weather adds **+5pp** to the skillshot chance instead")
    L.append("(fishing_minigame_weather_bonus).")
    L.append("Bulk ores are deliberately outside the band -- see tools/gen_fishing_tables.py.\n")
    for name, tbl in GROUPS:
        L.append(f"\n## {name.capitalize()}\n")
        L.append("| Item | Tier | Base | Diamond rod (x2) | Twilight (x1.5) | Full stack (x3) |")
        L.append("|---|---|---|---|---|---|")
        eff = {m: dict((i, e) for i, (lab, e) in enumerate(boosted(tbl, m))) for m in (1.5, 2, 3)}
        for i, (label, cls, w, t) in enumerate(tbl):
            tier = t or ("filler" if w >= 600 else "common")
            L.append(f"| {label} | {tier} | {pct(w)} | {pct(eff[2][i])} | {pct(eff[1.5][i])} | {pct(eff[3][i])} |")
        bonus = sum(w for _, _, w, t in tbl if t)
        L.append(f"\nRare+jackpot band: **{pct(bonus)}** base -> {pct(bonus*1.5)} (x1.5) -> {pct(bonus*2)} (x2) -> {pct(bonus*3)} (x3).")
    return "\n".join(L)

if __name__ == "__main__":
    check()
    open(sys.argv[1] if len(sys.argv) > 1 else "fishing_tables.lua.txt", "w").write(lua() + "\n")
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(md() + "\n")
    print("written")
