# Changelog

All notable changes to this project are documented here. Versioning is [SemVer](https://semver.org/):
MAJOR = save-schema break, MINOR = new feature/phase, PATCH = re-map for a new game build / bugfix.

## [0.1.0] — Unreleased

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
- **Milestone 2**: storm interactions (player stun/T-pose/whiteout, machine + tree effects),
  the dark-arts rites, the wand ladder (Mundane → Hydration / Electrick), the Tempest Codex.
- **Content pak toolchain** (`tools/pakkit`): cooks real items, DataTable edits and cloned UI
  offline — no Unreal Editor. Ships the wands, the codex and its research cards.
- Tooling, all pure Python (no PowerShell anywhere): `install.py` (one-command, cross-platform
  install of every runtime dependency — VC++ runtime, UE4SS, the Lua mod, the content pak — with
  `--uninstall`; player installs ship no dev tools), `tools/run.py` (dev deploy + launch + log
  tail, sharing `install.py`'s logic), `tools/package.py` (drop-in release zip),
  `tools/pakkit/setup.py` (build-toolchain bootstrap), `tools/capture_dump.py` (RE capture),
  `tools/dump-diff.py` (symbol diff).
- **Bundled UE4SS runtime** (`vendor/UE4SS-Solarpunk-runtime.zip`, built by
  `tools/make_ue4ss_runtime.py`): a trimmed, runtime-only build of the Solarpunk-patched UE4SS —
  no debug symbols, debugger DLLs or dumper configs — so nothing has to be downloaded from
  Nexus or anywhere else.
- Docs: design, install, reverse-engineering checklist, compatibility, release checklist.

### Known limitations
- Mapped and tested against game build `24038177` only; a game update needs a re-map (and a pak
  rebuild) per `docs/RELEASE-CHECKLIST.md`.
- The wands render in-hand as a plain tinted stick — the game's tool-integration path can't be
  used by cooked items on this build (see `docs/DARK-ARTS.md`).
