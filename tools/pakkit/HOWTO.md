# pakkit — the Solarpunk content-pak toolchain

Builds `z_SolarpunkWand_P.{utoc,ucas,pak}`: a cooked IoStore content pak that adds the
**Mundane Wand** and **Electric Wand** as real inventory items — no Unreal Editor required.

The Lua mod can't mint new item IDs (that's why the wand started life as a mod-managed rig).
This pak does it properly, by editing the game's own `DB_Items` DataTable and shipping two new
item-actor Blueprints, all offline via binary asset round-tripping.

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

## The one non-obvious gotcha (cost a full debugging arc — do not relearn it)

`retoc to-zen` rebuilds each package's local name map and can only fix up FName references it can
*see*: import-table names, export headers, preload deps. Names that live **only inside a
DataTable row's serialized bytes** (i.e. new **row-key** names) are invisible to it — it can't
parse the `S_Item` struct — so if such a name sits at a high name-map index it gets dropped on
repack and the row key ends up pointing past the end of the rebuilt map:

```
Fatal: ObjectSerializationError: ... DataTable ... DB_Items: Bad name index 1788/290
```

Fix (in `build_wand_pak.py::add_rowkey_name`): insert new **row-key** names into the *low* local
region — right before the package's own `DB_Items` name — where all the existing row keys live
and where retoc preserves them. Property names, enum values, and text keys are reused from
existing rows, so they're already down there; only the brand-new row keys need placing. Import
class names (`BP_*_Item_C`) can be appended anywhere — the import table keeps them alive.

Verify offline before booting (the readback shows the names surviving; the rows read as
`RawExport` without global context, which is expected):

```
retoc to-legacy <mod triple + game global.utoc> verify/
wandsmith tojson Solarpunk.usmap verify/.../DB_Items.uasset db.json VER_UE5_6 <S_Item.uasset>
# -> NameMap must contain MundaneWand / ElectricWand at low indices
```

## What the pak contains

- `DB_Items` (311 rows = game's 309 + MundaneWand + ElectricWand). Each new row is a Stick clone
  re-typed as a hold-tool (Repairkit's `ItemType` + `ItemInteractionType`), stack size 1,
  pointing `ItemActor` at the matching new BP below, with its own display name + description.
- `BP_MundaneWand_Item` / `BP_ElectricWand_Item` — Stick-item clones (mesh = `SM_Stick`). The
  cobalt tip is not yet on the item mesh; adding an `SM_Cobalt` SCS node to these BPs is the next
  refinement so the held item matches the mod-rig look.

## Engine-version note

The game is UE 5.7.1, but UAssetAPI (v1.1.0) can only *read* these assets as `VER_UE5_6` (5_7
throws on the header). retoc packs as `UE5_7`. That split is fine **as long as the name indices
are internally consistent** — which the low-index fix guarantees. Do not "fix" the version skew
by forcing retoc to UE5_6; the 5.7 game wants a 5.7 container.
