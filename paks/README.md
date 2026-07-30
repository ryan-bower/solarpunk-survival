# Cooked paks

Release copies of the cooked content live here (git-ignored — they contain game-derived data, so
they ship in the release zip, not in the public repo). **This folder is the only place
`install.py` and `tools/package.py` look**, under exactly the name `Solarpunk-Windows_1_P.*`.

It used to fall back to `tools/pakkit/out/`, which meant a working install quietly depended on the
2 GB pak-build toolchain sitting on the same machine — and on any machine without it the installer
merely *warned* and produced a mod with no wands, no Tempest Codex, no Diamond Fishing Rod and no
Sorting Chest. A missing pak is now a hard error; `--skip-pak` is the deliberate opt-out. After
building, copy the triple here yourself:

```
cp tools/pakkit/out/z_SolarpunkWand_P.{utoc,ucas,pak} paks/   # renaming to Solarpunk-Windows_1_P.*
```

## The content pak

`Solarpunk-Windows_1_P.{utoc,ucas,pak}` — built by [`tools/pakkit`](../tools/pakkit/HOWTO.md)
(`python tools/pakkit/build_wand_pak.py`, output `out/z_SolarpunkWand_P.*`), **no Unreal Editor
involved**: it round-trips the game's own cooked assets. It adds the four wand items, the Tempest
Codex and the Tempest Handbook (each an item, a placeable and its own whole cloned reader UI),
the "Tempest Codex" and "The Dark Arts"
research cards, and the recipes that unlock them — as edits to the game's own `DB_Items` /
`DB_CraftingRecipes` / `DB_Researchables` / `DB_Buildables`.

Install to `<game>\Content\Paks\` under exactly that name: the base container
`Solarpunk-Windows_0_P` mounts at order 104, `_1_P` at 204 (so its DataTable edits win), and
`~mods\` at 103 — below the base, where the same edits are silently shadowed.

## LogicMods (Blueprint-only replication carriers) — not built, not required

The original design called for `BP_ModStateActor` / `BP_HealthState` paks to carry custom
replicated state. They turned out to be unnecessary: the mod replicates through the game's own
RPCs and native replication instead, so `core/net.lua` runs without them. If a future feature
needs custom replicated state, those would go in `<game>\Content\Paks\LogicMods\`.
