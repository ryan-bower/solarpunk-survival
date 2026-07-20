# Release Checklist (run on every game update)

Solarpunk has no official mod API, so a game patch can move/rename symbols and break hooks. This
runbook makes re-patching fast. Everything fragile lives in one file: `Scripts/mapping.lua`.

1. **Detect the new build.** Check `steamapps/appmanifest_1805110.acf` → `buildid`. Note it.
2. **Update UE4SS** if the Solarpunk-patched build was updated.
3. **Re-dump** symbols into `dumps/<newbuild>/` (see `REVERSE-ENGINEERING.md`).
4. **Diff** against the last good dump:
   `python tools/dump-diff.py dumps/<oldbuild> dumps/<newbuild> --mapping mod/SolarpunkSurvival/Scripts/mapping.lua`
   This prints only the mapped symbols that were removed/renamed/changed — your punch-list.
5. **Patch `mapping.lua`.** Add a new profile keyed by the new build id (inherit `default`, override
   what moved). Leave the old profile so users on the previous build still work.
6. **Smoke test** (single player): launch, confirm no red errors, storms fire, a structure takes a
   strike, the Lightning Rod redirects.
7. **Multiplayer test** (see below).
8. **Bump versions:** `manifest.json` (`modVersion`, add build to `testedGameBuilds`), `CHANGELOG.md`.
9. **Package:** `pwsh tools/package.ps1` → `dist/SolarpunkSurvival-vX.Y.Z.zip`.
10. **Release:** tag git (`vX.Y.Z`), upload the zip to GitHub Releases, tell the group to update in
    lockstep (host + all clients on the same version).

## Multiplayer smoke test

Two instances (two PCs, or one PC + a LAN peer), host + one client, both modded:

- Storm starts → both see the same weather; damage tick runs **only on host** (client log shows none).
- Lightning → telegraph decal + bolt at the **same world location** on both; struck structure loses
  the **same HP** on both.
- Structure destroyed → gone on both within a frame or two; no ghost on the client; still gone after
  the client walks away and back.
- Host save + reload → destroyed pieces and HP persist and re-replicate to a rejoining client.
- Repeat once with the client **unmodded**: no crash; the mod warns the peer is unmodded.
