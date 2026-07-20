# Compatibility

| Mod version | Tested game build | UE4SS | Notes |
|---|---|---|---|
| 0.1.0 (scaffold) | `24038177` | TBD | Framework + storm logic; `mapping.lua` not yet populated (no gameplay change). |

- **Engine:** Unreal Engine 5, IoStore packaging (`global.ucas`/`.utoc`, `Solarpunk-Windows_0_P.pak`).
  The shipping exe stamps `UE5-CL-0`; confirm the exact minor from a UE4SS CXX dump.
- **Symbols:** the game ships its full `.pdb`, so UE4SS can resolve names reliably — good for
  re-patching after updates.
- **Untested builds:** if the detected `buildid` isn't in `manifest.json > testedGameBuilds`, the mod
  falls back to the `default` mapping profile and shows an in-game banner warning that it's running in
  degraded / at-risk mode.

Update the table above with each release (see `RELEASE-CHECKLIST.md`).
