# pakkit — the Solarpunk content-pak toolchain

Builds `z_SolarpunkWand_P.{utoc,ucas,pak}`: a cooked IoStore content pak that adds the
**Mundane Wand** and **Electric Wand** as real inventory items, plus the **Tempest Codex** —
a craftable, placeable, fully readable in-game book — no Unreal Editor required.

The Lua mod can't mint new item IDs (that's why the wand started life as a mod-managed rig).
This pak does it properly, by editing the game's own `DB_Items` DataTable and shipping new
item-actor Blueprints (and a whole cloned book UI), all offline via binary asset round-tripping.

## Layout (most of it is git-ignored — see `.gitignore`)

| Path | What | Committed? |
|---|---|---|
| `build_wand_pak.py` | the whole build pipeline | ✅ |
| `wandsmith/` (`Program.cs`, `.csproj`) | tiny UAssetAPI CLI: `tojson` / `fromjson` with schema preload | ✅ (src only) |
| `retoc.exe` | [trumank/retoc](https://github.com/trumank/retoc) v0.1.5 — IoStore ⇄ legacy | downloaded |
| `UAssetAPI/` | [atenfyr/UAssetAPI](https://github.com/atenfyr/UAssetAPI) — asset (de)serializer | cloned |
| `UAssetGUI.exe` | GUI/CLI front-end (unused by the script; kept for manual inspection) | downloaded |
| `Solarpunk.usmap` | reflection mappings, dumped live via UE4SS `DumpUSMAP()` | regenerated |
| `legacy/` | the game's assets, `retoc to-legacy`-extracted (~2 GB, copyright) | ignored |
| `staged/`, `out/`, `verify*/` | build scratch + outputs | ignored |

## Prerequisites (one-time)

- **.NET 10 SDK** (`winget install Microsoft.DotNet.SDK.8` pulls the runtime; UAssetAPI targets
  net10.0 — install the matching SDK). Build wandsmith: `dotnet build -c Release wandsmith`.
- **retoc.exe** — download the `x86_64-pc-windows-msvc` zip from the retoc releases.
- **UAssetAPI** — `git clone --depth 1 https://github.com/atenfyr/UAssetAPI`.
- **Solarpunk.usmap** — in-game, run the mod's remote channel `exec` with `DumpUSMAP()` (it needs
  the item framework loaded first: `LoadAsset` the `_BP_ItemActor_MASTER`, `BP_Stick_Item`,
  `S_Item`, `S_ItemAttribute`, and the `EItem*` enums, THEN `DumpUSMAP()`), copy the resulting
  `Solarpunk-*.usmap` here as `Solarpunk.usmap`, and drop a copy in
  `%APPDATA%/UAssetGUI/Mappings/` if you use the GUI.
- **legacy/** — `retoc to-legacy "<game>/Content/Paks" legacy`.

## Build

```
python build_wand_pak.py          # -> out/z_SolarpunkWand_P.{utoc,ucas,pak}
```

Install by copying the triple into `<game>/Content/Paks/` **renamed to a patch layer above the
game's own** — `Solarpunk-Windows_1_P.{utoc,ucas,pak}`. The game's base container is
`Solarpunk-Windows_0_P` at mount Order 104; a `_1_P` name mounts at Order 204 and therefore
*overrides* the base `DB_Items`. (A `~mods/` install lands at Order 103 — BELOW the base — so the
edit would be shadowed and do nothing. This bit us once; use the `_1_P` name.)

## The one non-obvious gotcha (cost TWO debugging arcs — do not relearn it)

**Root cause (found 2026-07-21 via `exp_namecut.py`, superseding the earlier "boundary insert"
theory): the UE5 package-summary field `NamesReferencedFromExportDataCount`.** UE5 splits a
package's name map into a *prefix* of names that export blobs may reference by raw index, and a
tail referenced only from headers/imports. `retoc to-zen` keeps exactly that prefix (plus any
name it can *see* referenced — import table, export headers) and prunes the rest; it cannot
scan export blobs (it can't parse `S_Item`), so it must trust the count. **UAssetAPI preserves
the BASE asset's count verbatim** — for `DB_Items` that's `290`. Inserting new row-key names
into the low block grows the prefix past the stale count, and the block's TAIL names (the
game's own last-alphabetical row keys — `WirelessLight01`, `WirelessSprinkler`, `Wood_Waste`)
get pruned on repack:

- reference still lands inside the rebuilt map → the row is **silently misnamed** (the 3-key
  wand pak shipped this way — `Wood_Waste` read back as `DB_Items` and nobody noticed);
- reference walks off the end → `Fatal: ObjectSerializationError: ... DB_Items: Bad name index
  292/292` **on game launch** (the 5-key pak — this is the crash signature).

Fix (in `build_wand_pak.py::fix_name_count`, called on every table we write): set
`NamesReferencedFromExportDataCount = len(NameMap)` before `fromjson` — every name survives the
repack and every blob index stays valid. The old lore still applies in weakened form: row keys
are still inserted **sorted, interior to the low block** (`add_rowkey_name`), property/enum/text
names are reused from cloned rows, and import class names (`BP_*_Item_C`) can be appended
anywhere — the import table keeps them alive.

Verify offline before booting (the readback rows are `RawExport` without global context, which
is expected): `verify_pak()` round-trips the built pak and asserts, for each patched table, that
the rebuilt NameMap's **prefix up to the table's own name is IDENTICAL, in order,** to the map
we wrote — membership-only checks miss both failure modes above.

## What the pak contains

- `DB_Items` (314 rows = game's 309 + MundaneWand + HydrationWand + ElectricWand +
  ChargedElectricWand + TempestCodex). Each wand row is a Stick clone re-typed as a hold-tool
  (Repairkit's `ItemType` + `ItemInteractionType`), stack size 1, pointing `ItemActor` at the
  matching new BP below, with its own display name + description; the codex row is a
  Handbook-shaped placeable book. Wand icons are recolored stick icons: brown (mundane), blue
  (hydration), dim gold (spent electrick), bright yellow (charged).
- `BP_MundaneWand_Item` / `BP_ElectricWand_Item` — Stick-item clones (mesh = `SM_Stick`). The
  `ItemMesh` on these BPs is the *dropped/world* look only — it is **never** what appears in the
  player's hand (see below), so an `SM_Cobalt` SCS node here would only affect ground items.

## How held items render (bytecode RE of `BP_MainPlayerCharacter`, 2026-07-21)

Every **visible** held item is a spawned `BP_HandItem_*` actor
(`/Game/Code/Character/HandItems/`), attached to `Mesh_Slot_1Person_Hand_R` and tracked in
`CurHandItemFirstPerson`. For consumables the pawn's `UpdateHandConsumable` does:

```
ClassesToActor = { BP_Raspberry_Item_C → BP_HandItem_Raspberry_C, … 21 foods }   # baked literal
SetHandRBlueprintForBoth( Map_Find(ClassesToActor, CurItemdataInHand.ItemActor) )
```

The map is a **literal in the pawn's compiled bytecode** — new items can never be added to it from
a content pak short of re-cooking the whole pawn BP. A missing entry (the base Stick, and our wand
rows) means `SetHandRBlueprintForBoth(null)` → empty palm-out hand. `SetHandRBlueprintForBoth`
also destroys the previous hand-item actor on every call, so hand-item lifecycle is fully
game-owned. The Lua mod exploits exactly this: it calls `SetHandRBlueprintForBoth` itself with a
donor class (`BP_HandItem_Carrot_C`) and re-dresses the spawned actor's `FoodMesh` as a tinted
`SM_Stick` (`features/wand.lua`). Note the pawn has **no** `FoodMesh` property — `FoodMesh` lives
on the consumable hand-item actors (a mis-probe that once pointed the mod at a nonexistent
component). The offline dump recipe: `wandsmith tojson` on `BP_MainPlayerCharacter.uasset`
(VER_UE5_6) and walk the `ScriptBytecode` of the `FunctionExport`s.

## The Tempest Codex (survival-guide clone chain, RE 2026-07-21)

The survival guide is fully data-driven, which makes a *second book* a pure cloning job:

```
W_SurvivalGuide ──reads──> DB_GameplayTips (rows: S_GameplayTip = Icon + Tip FText + Category[])
      │                          categories = EGameplayTipCategory (UserDefinedEnum)
      ├─ buttons: WC_SurvivalGuideCategory  (label = Conv_NumericPropertyToText on its Category
      │                                      property → the ENUM's DisplayNameMap)
      └─ rows:    WC_GameplayTip            (type-clean; takes icon + preformatted text)
BP_SurvivalGuide_Placeable ──interact──> virtual call UI_OpenSurvivalGuide on the controller
      (the controller pre-creates the widget in StartupUI → property UI_SurvivalGuide → Open())
```

`build_wand_pak.py::build_codex()` clones the chain with **plain text replaces over the JSON
round-trip** — bytecode references imports by *index*, so re-pointing an import retargets every
use with zero bytecode surgery. Only two structural patches are needed in `W_TempestCodex`:

- `GenerateCategoryButtons` iterates category indexes with the enum count **baked at BP-compile
  time** as `MakeLiteralInt(9)` → patched to our 5 sections (Origins / Pentagram / Implements /
  Hydration Wand / Electrick Wand; same-width int const, offsets safe).
- the title TextBlock pulls from the `ST_ReusableTerms` string table → replaced with an inline
  Base FText ("Tempest Codex").

Rows in `DB_TempestCodex` keep the ORIGINAL `S_GameplayTip` row struct, so their category FNames
resolve against the ORIGINAL enum, whose name↔value order is permuted — see `CAT_FNAME`.
Craft/place wiring: both `DB_CraftingRecipes` rows (codex + mundane wand) are **research-gated
bench recipes** — `StartingRecipy=false`, `CraftingLocations` = `NewEnumerator1` (bench) only
(`NewEnumerator0` would be hand/quick-craft, 4 = cooking) — unlocked together by ONE
`DB_Researchables` row ("TempestCodex", RainCollector-shaped): `StartingResearch=true` = offered
from level 1 with no level gate, `UnlockingRecepieIDs` = both new `RecipyID`s, `ItemsNeeded` =
1 beeswax + 1 clay + 1 leaf. Unlike the recipe/buildable tables, `S_Researchable` is a
STANDALONE struct asset (`Code/Research/Framework/S_Researchable.uasset`) — preload that, not
the table. Placement: a `DB_Buildables` row whose `ItemsNeeded` matches the item by
**DB_Items row name**.

Gotchas discovered on this arc (all encoded in the build script):

- **UE4SS `LoadAsset` cannot load pak packages that aren't in the game's AssetRegistry.** It
  resolves through the registry and returns null *silently* — no `SkipPackage` log line (a
  soft-ref miss from the game's own loader DOES log). Our new packages ship no registry entries,
  so any package that only the Lua mod needs must be given a **hard-import edge from a package
  the game itself loads**: `BP_TempestCodex_Placeable` imports `W_TempestCodex_C`
  (`/Script/UMG` + `WidgetBlueprintGeneratedClass`), and the widget's own imports drag in
  `DB_TempestCodex`, `ETempestCodexCategory` and both `WC_*` widgets when a placed codex loads.
  retoc keeps import-map entries even when it can't see them referenced, and the zen loader
  eagerly loads every `ImportedPackages` entry — the same mechanism that already loads the icon
  and item-BP packages via the imports `add_texture_import`/`add_item_actor_import` plant in
  `DB_Items`. **But loading is not staying loaded:** nothing in the game *references* the widget
  chain after load, so the post-world-load GC unloads it again ~2s later (verified by decoding
  the container header's store entries — the edges were present — plus live residency probes).
  The DataTable-referenced packages survive because table rows hold rooted object refs; the
  widget chain is rooted Lua-side instead: `features/codex.lua` creates the widget and parks it
  in the viewport inside the pre-GC window (interact-hook arm time + every placeable
  construction). Debugging recipe: `retoc unpack-raw out.utoc dir` → `manifest.json` maps each
  chunk-id's 8-byte hex prefix (the FPackageId) to its package path; the ContainerHeader chunk =
  `IoCn` magic, version u32, container-id u64, PackageIds TArray, then a StoreEntries blob of
  16-byte entries `{ImportedPackages{count, offset-from-field}, ShaderMapHashes{count, offset}}`.
- **Never point a virtual call at a missing function.** The placeable's interact event calls
  `UI_OpenSurvivalGuide` by name (`EX_LocalVirtualFunction` → `FindFunctionChecked` → fatal
  assert if absent). The clone renames the call to the controller's no-arg
  `ForceCloseInteractableUIs` (harmless, signature-compatible); `features/codex.lua` hooks the
  clone's interact event and opens `W_TempestCodex` itself.
- **UAssetAPI writes unversioned properties from usmap schemas only.** wandsmith's preloader
  registers `StructExport`s *and* (since this arc) `EnumExport`s from preload assets — the cloned
  `ETempestCodexCategory` must be preloaded when writing any widget that types a property to it.
  Row structs that are cooked *inside* a table's own package (S_CraftingRecipy in
  DB_CraftingRecipes, S_Buildable in DB_Buildables) are handled by preloading **the source table
  itself**.
- **Offline verify needs `global.utoc/ucas` beside the mod triple** (a lone mod container has no
  ScriptObjects chunk). The round-tripped tables read back as `RawExport`s — that's expected; the
  meaningful assertion is that the **NameMap** still contains every added row key (the historical
  boundary-drop failure mode).

## Engine-version note

The game is UE 5.7.1, but UAssetAPI (v1.1.0) can only *read* these assets as `VER_UE5_6` (5_7
throws on the header). retoc packs as `UE5_7`. That split is fine **as long as the name indices
are internally consistent** — which the low-index fix guarantees. Do not "fix" the version skew
by forcing retoc to UE5_6; the 5.7 game wants a 5.7 container.
