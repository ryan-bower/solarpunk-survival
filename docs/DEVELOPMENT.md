# Developing the mod

Player-facing install and play instructions live in the [README](../README.md); this page is the
developer side — the run loop, the dev tools, the content-pak toolchain, and the tests.

## The dev loop: deploy + relaunch in one step

```
python tools/run.py
```

One cross-platform script (Windows native, Linux/Steam Deck via Proton). It stops any running
instance, fast-syncs the current `mod/` + pak into the game install (changed files only, stale
files pruned — the installed `dump/` and `config/` are never touched), launches via Steam, and
tails `ue4ss/UE4SS.log` until the mod logs `SolarpunkSurvival vX.Y.Z starting`, failing fast if
the game process dies first. It even puts UE4SS in place when it's missing, extracted from the
bundled `vendor/UE4SS-Solarpunk-runtime.zip` — a fresh machine needs nothing but Steam, the game
and Python. All install logic is imported from `install.py` (the player installer), so the two
flows can't drift apart; `run.py` only adds kill-then-relaunch and the log tail.

**Plain `tools/run.py` deploys exactly what a player gets** — that's the point, so every launch
rehearses the real install. Dev tools need `--dev`, and a deploy *without* `--dev` prunes them
back out again.

| Flag | |
|---|---|
| `--dev` | also deploy `Scripts/dev` (RE dumper, exec channel, ritual kit, test kit) |
| `--no-install` | relaunch without redeploying |
| `--force` | reinstall the UE4SS core even if it's already there |
| `--wait <s>` | how long to wait for the startup line (default 120) |
| `--game-dir <path>` | skip auto-detection (the detected dir is cached in `tools/.gamedir`) |

`python install.py --status` prints what's installed right now (UE4SS, mod, whether dev tools are
present, pak, last loaded version) and changes nothing; `--purge` removes the lot, UE4SS included.

If the game is already running and you only changed Lua, you usually don't need a relaunch at
all — copy the changed file into the installed `Scripts/` and hot-reload it through the remote
exec channel below. That channel is itself a dev tool, so it only exists after a `--dev` deploy.

## Dev tools (`Scripts/dev/`)

The player install (`python install.py`, and `tools/run.py` without `--dev`) **excludes
`Scripts/dev` entirely** — players get no RE dumper, no remote exec channel, no ritual dev kit,
no test kit, and `main.lua` silently skips the missing modules. The tools:

| | |
|---|---|
| `dev/recapture.lua` | **F8** / `sps_dump` writes an RE dump; `sps_find <text>` searches live objects |
| `dev/remote.lua` | file-command channel: write one line to `<mod>/dump/cmd.txt`, read `dump/result.txt`; `exec` runs `dump/exec.lua` in the live game |
| `dev/ritual_test.lua` | `sps_ritual_test` — scripted end-to-end rite check |
| `dev/ritual_kit.lua` | `sps_needful hydration\|electrick [noanimal]` — stages a rite's animal + rod + offerings at your last map ping |
| `dev/test_kit.lua` | `sps_testkit` — fast-forwards a fresh save to "everything testable" (below) |

### `sps_testkit` — stocking a fresh save

| | |
|---|---|
| `sps_testkit` | everything: research + recipes, backpack tier 7, the default item groups, power |
| `sps_testkit research` | every research card marked done, every recipe id unlocked |
| `sps_testkit pack [tier]` | backpack tier 0/1/3/7 → 29/36/43/50 slots (default 7) |
| `sps_testkit items [group]` | one group: `mod`, `tools`, `power`, `ship`, `ritual`, `mats`, `build` |
| `sps_testkit power` | charge placed batteries, force powered devices on (sorting-chest smoke test) |
| `sps_testkit status` | report only — changes nothing |

Host only; Playerdata is server-authoritative and every inventory write in the mod is host-side.

Two things it encodes that are easy to get wrong:

- **There is no crafting-table "level" property.** No level/tier field exists on `BP_CraftingTable`,
  `BP_AdvancedCraftingTable` or `BP_ResearchTable`. The station tiers are `DB_Researchables` rows
  flagged `IsLevel` (`LvL_2..LvL_9`, `LVL_ENG_2..LVL_ENG_5`), so unlocking research *is* the
  upgrade. Same for the build rings (1001/1002) and the in-game map (2001), which carry no recipes
  at all and are read back through `HasPlayerResearch?`.
- **`UnlockResearch` takes the whole `S_Researchable` row struct**, whose nested `TArray` fields
  have never been marshalled from Lua here. The kit drives the two flat calls it ultimately makes
  instead — `Playerdata_SaveResearchForSelf{id, Researched=true}` (upsert by id) and
  `Playerdata_AddUnlockedRecipyForSelf(id)` (`Array_AddUnique`) — both already proven by
  `features/codex.lua`. Unknown recipe ids are harmless: the crafting UI runs `RemoveLockedRecipys`,
  which only intersects the saved list against the real DB.

Symbols live in `mapping.progress`. Open a crafting table once afterwards — its interact runs
`SkygameExtraFunctions.FixMissingCraftingRecipies`, which reconciles the recipe list.

The UE4SS console windows (`ConsoleEnabled` / `GuiConsoleEnabled` / `GuiConsoleVisible` in
`UE4SS-settings.ini`) are pinned **off** by the installer and `run.py` — everything they show
also lands in `ue4ss/UE4SS.log`. Flip them to `1` by hand if you want the live console; note the
next deploy pins them back.

## Building the content pak

Only needed if you're working from a clone (the release zip ships the pak). The pak is cooked
offline — no Unreal Editor — by round-tripping the game's own assets, so it can't be
redistributed in a public repo.

```
python tools/pakkit/setup.py           # one-time: every build dependency
python tools/pakkit/build_wand_pak.py  # -> tools/pakkit/out/z_SolarpunkWand_P.*
cp tools/pakkit/out/z_SolarpunkWand_P.{utoc,ucas,pak} paks/   # rename to Solarpunk-Windows_1_P.*
python tools/run.py                    # deploys the result and launches
```

**That copy is not optional.** `install.py` looks in `paks/` and nowhere else — it used to fall
back to `tools/pakkit/out/`, which meant an install quietly depended on a 2 GB developer tree
being present and produced a half-working mod on any machine without it. A missing pak is now a
hard error rather than a warning, because half the mod's items live in it (the wands, the Tempest
Codex and its research card, the Diamond Fishing Rod, the Sorting Chest, the gold fishing drops).
`--skip-pak` is the deliberate opt-out.

`setup.py` fetches git, the .NET SDK, Lua, retoc and UAssetAPI, builds the `wandsmith` CLI, and
extracts the game's own assets to work from. The single piece it can't fetch is `Solarpunk.usmap`,
which is dumped out of the *running* game — that step, and the toolchain's one very sharp gotcha,
are in [`tools/pakkit/HOWTO.md`](../tools/pakkit/HOWTO.md).

## Tests

```
lua tests/spec.lua
```

## When a game update lands

Solarpunk has no mod API — a game update can break the mod until it's re-mapped against a fresh
dump. See [`RELEASE-CHECKLIST.md`](RELEASE-CHECKLIST.md) and
[`REVERSE-ENGINEERING.md`](REVERSE-ENGINEERING.md).
