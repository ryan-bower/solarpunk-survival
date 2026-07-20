# Testing

Three layers, from most to least automated.

## 1. Headless unit tests (CI + local) — game-independent logic

`tests/spec.lua` stubs the UE4SS globals and game-facing modules, then asserts the pure logic:
JSON round-trip, event bus, config defaults/overrides, mapping resolve/missing, and the
health/damage math (player 70%→lethal-on-2nd, machine 2-hit smoke→destroy, repair clears smoking).

Run locally (needs a Lua 5.4 interpreter):
```
lua5.4 tests/spec.lua      # exits non-zero on any failure
```
Runs automatically on every push via the `luatest` GitHub Actions job (see `.github/workflows/lint.yml`),
alongside `luacheck` (Lua static analysis) and Python byte-compile.

## 2. In-game self-check + RE capture — needs the game running with UE4SS

Once UE4SS + the mod are installed (`tools/install-dev-env.ps1`) and you launch the game:

- **Status / self-check:** press **F7**, or open the UE4SS console and type `sps`. It prints the
  detected game build, host-authority state, and the list of still-unmapped symbols.
- **Reverse-engineering capture** (the step that unblocks real gameplay): load your save, make the
  target exist (start a storm, place a build piece, board the airship...), then in the console:
  - `sps_dump` — writes `Mods/SolarpunkSurvival/dump/re_capture.txt` (every live actor class + its
    functions/properties). Send that file back to fill in `mapping.lua`.
  - `sps_find weather` — quickly prints live class names containing "weather" (or any substring).

## 3. Multiplayer acceptance — needs two clients

Once `mapping.lua` is populated, follow the multiplayer test matrix in `RELEASE-CHECKLIST.md`
(host + one client, both modded; verify the storm tick runs only on host, strikes land at the same
world location on both, destruction replicates, saves persist, and an unmodded client doesn't crash).

## Convenience scripts

- `tools/install-dev-env.ps1` — download + install UE4SS into the game, copy this mod in, enable it,
  turn on the UE4SS console. Idempotent; re-run to update the mod.
- `tools/capture-dump.ps1` — launch the game, wait for the UE4SS log + any `re_capture.txt`, copy
  them into `dumps/` (git-ignored), then stop the game.
