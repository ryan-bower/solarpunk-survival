# Cooked paks

Release copies of the cooked content live here (git-ignored — they contain game-derived data, so
they ship in the release zip, not in the public repo). `install.ps1` picks up a triple from this
folder first, then falls back to `tools/pakkit/out/`.

## The content pak

`Solarpunk-Windows_1_P.{utoc,ucas,pak}` — built by [`tools/pakkit`](../tools/pakkit/HOWTO.md)
(`python tools/pakkit/build_wand_pak.py`, output `out/z_SolarpunkWand_P.*`), **no Unreal Editor
involved**: it round-trips the game's own cooked assets. It adds the four wand items, the Tempest
Codex (item, placeable, and its whole cloned reader UI), the "Tempest Codex" and "The Dark Arts"
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
