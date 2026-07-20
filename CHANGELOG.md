# Changelog

All notable changes to this project are documented here. Versioning is [SemVer](https://semver.org/):
MAJOR = save-schema break, MINOR = new feature/phase, PATCH = re-map for a new game build / bugfix.

## [0.1.0] — Unreleased (scaffold)

### Added
- Repo scaffold and full mod project structure.
- **Core framework** (`Scripts/core/`): logging, event bus, config loader, authority/replication
  helper, actor-identity resolver, health/damage component, save/persistence hook.
- **Milestone 1 storm logic** (`Scripts/features/`): storm detection, telegraphed lightning with
  bursts, per-target strike effects, destructible structures with partial salvage, Lightning Rod
  redirect + battery charging, Storm Repair Tool, player strike/death handling.
- **Mapping-driven design**: all game-specific symbols centralized in `Scripts/mapping.lua`
  with per-build profiles; features self-disable and report missing symbols on unmapped builds.
- Runtime build detection and compatibility banner (`Scripts/buildinfo.lua`).
- Tooling: `tools/package.ps1` (release zip), `tools/dump-diff.py` (post-patch symbol diff).
- Docs: design, install, reverse-engineering checklist, compatibility, release checklist.

### Known limitations
- Game hooks in `Scripts/mapping.lua` are **not yet populated** — no gameplay changes until a
  UE4SS dump of build `24038177` is mapped. Not yet functional in-game.
- LogicMod paks (`BP_ModStateActor`, `BP_HealthState`) are specified but not yet cooked; the
  net layer runs in single-player/degraded mode until they exist.
