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
- **Save on demand** (`features/manual_save.lua`): a **Save Game** button in the pause menu, sitting
  directly under Resume. It runs the game's *own* periodic autosave — `BPC_SaveManager.Save`, the exact
  function the autosave timer is bound to — so the HUD's "Saving…" indicator, the pre-save flush
  every system hangs off `OnAutoSaveStarting`, and the write itself are all the stock ones; nothing
  here reimplements saving or touches a save file. The mod's own sidecar state (`save/state.json`)
  now rides along with every game save, autosaves included.
  - **Never two writes at once.** The game's `Save` is hooked, so the button is refused while an
    autosave is already running rather than queueing behind it; the in-flight flag is also raised
    before the mod's own call, so a double-click can't slip through the window before the hook body
    runs. It is lowered by the save-completed signal and, failing that, by a timeout — a lost signal
    costs a stale label, never a button that stays shut for the session. A short cooldown
    (`save_button_cooldown`, 10 s) follows a completed write.
  - Host only: `CachedSave` is built solely on the server, so on a client `Save()` would hand the
    writer a null save object under the client's own world-slot name. Clients get no button (there
    is no client→host save RPC to ride yet).
  - A manual save re-arms the autosave timer, so the game doesn't write again seconds later —
    skipped unless its own interval reads back sane, since a bad value there would kill autosaving
    for the session.
  - The button reports on itself (`Save Game` → `Saving…` → `Saved`), because the pause menu covers
    the HUD indicator. Tunable via `save_button*` config keys; `save_button = false` removes it.

### Fixed
- **Pinging crashed the game, and the material was never the reason.** Colouring a marker called
  `CreateDynamicMaterialInstance`, which killed build 24038177 twice, identically. The dump is what
  settled it: an access violation reading `0x70` with **not one game-module frame on the stack** —
  UE4SS faulted while setting the call up and the engine was never reached. So the three parent
  materials suspected in turn were all innocent; the member simply does not resolve on this build,
  and `obj.Fn ~= nil` cannot tell you that because UE4SS returns a callable wrapper around nothing.
  The presumed-safer door — `SetMaterial` + `SetVectorParameterValueOnMaterials`, the engine making
  the dynamic instance itself — then died the very same way on its first live call (byte-identical
  all-UE4SS stack; `SetMaterial` itself survived, the parameter call did not). Verdict: **the whole
  material-parameter family is off-limits on this build**, and colour can only be *chosen*, never
  *applied* — see the palette rework below. Every material name is still proved against the
  reflected function list — climbing the class chain, and distinguishing "the class does not
  declare this" from "reflection told us nothing", which are not the same answer.
  - Offline RE also killed the original plan: `SM_Ping` has **two** material slots, `BP_Ping`
    overrides neither, and neither stock material (`M_Ping1`, a gradient; `M_Ping2`, the `Icon_Ping`
    texture) declares a colour parameter — there was never anything to tint. Both slots are now
    replaced outright, so the "strange textures" go with them. `qol_ping_slots 1` keeps the icon
    glyph if the flat card reads worse.
- **Abort on loading a save.** The UE4SS "Abort signal received" crash from 2026-07-22 came back
  once, at world entry, with a byte-identical frame list: UE4SS walks its own deferred-action list
  on the game thread while the mod appends to it from the async ticker, and a save load is when the
  mod schedules hardest. Three changes shrink that window to almost nothing. The scheduler now keeps
  **at most one outstanding game-thread hop** and drains at most 24 actions per hop, so a load-time
  flood is spread across ticks instead of piled into the list; a hop the engine refuses puts its
  actions *back* on the queue instead of dropping them (and no longer latches the scheduler shut).
  And the two features that listen for a new Character — qol and the save button — **coalesce**: a
  save load streams in every animal on the map, and forty queued "did the player's pawn change?"
  checks answer the same question one does.
- **The mod was doing player surgery on main-menu characters.** `localPawn()` deliberately falls
  back to the first `Character` in the world, which in a menu level is whatever is standing in the
  backdrop. Five seconds after launch that got handed `SetInventoryUpgradeLevel`, and worse, it
  latched "world already seen" — so when the real save finished loading it looked like a repeat and
  qol's whole apply pass never ran for it. New `uehelp.playerPawn(class)` returns the local pawn
  only when it really is the mapped player class; the backpack repair, qol's world-entry check and
  the save button's all use it.
- **The bigger backpack was eating your entire player save.** Symptom: reloading remembered where
  you stood and everything in your chests, but not your inventory, health, hunger or thirst. Cause
  was this mod. `qol_backpack_level` called the pawn's `SetInventoryUpgradeLevel`, which only grows
  the *live* inventory array (tier 0/1/3/7 → 29/36/43/50 slots); the tier itself lives in the
  controller's `Playerdata` and is written by a different event, which the mod never called. So the
  save recorded a 43-slot inventory against a tier-0 record — and `BP_MainPlayerCharacter`'s
  `Apply Playerdata` restores the inventory, its save-GUID link, health, hunger, thirst and saved
  effects in **one all-or-nothing branch** gated on `len(saved inventory) == length-for-saved-tier`.
  That check failed on every load (`"<pawn> failed to load Inventory from save"` in the game log),
  so nothing in that branch ran — including the `SetInventoryID` that links the pawn's inventory to
  its saved entry. With a null GUID every subsequent save was a silent no-op, because
  `SAVE_WorldSaveV1::UpdateSavedInventory` only ever updates a GUID it can already find. Position
  and chests kept working the whole time because both are applied elsewhere, which is exactly how
  this stayed hidden. The tier is now recorded through the game's own `Playerdata_SaveBackpackTier`
  (what `BP_Backpack::OnCollect` and the game's debug helper both call), after the login apply has
  run — never before it, or the repair would fail a healthy save the same way. An already-broken
  save is re-linked to its player record on entry so the session's inventory has somewhere to go
  (`qol_backpack_relink`; off instead restores the older stored snapshot on the next load).
- **The pause menu's Save Game button rendered upside down.** `BOX_MenuButtons` is rotated 180° —
  that is how the designer made a bottom-anchored menu grow upward — and every button in it carries
  a 180° counter-rotation. A widget created from Lua has no transform at all, so it inherited the
  container's flip; it now copies the angle off `BTN2_Resume`.
- **Crouch is hold-to-crouch** (`qol_crouch_hold`, default on): release the key and you stand back
  up. UE4SS reports key-DOWN only, so the release comes from the game itself — `BP_MainPlayerCharacter`
  declares raw `LeftControl` input-key events, and a UE InputKey node compiles its Pressed and
  Released pins into two separate functions, so hooking both *is* a key-up subscription. The letter
  key has no such event and samples `IsInputKeyDown` while held instead (a poll that exists only
  while a key is down, re-fetches its objects every tick and dies on any transition); if a build
  won't report key state it says so once and that key degrades to a toggle.
- **Dying crouched no longer buries your loot chest.** Crouching drops the pawn's actor origin by
  the capsule half-height difference (~70cm — the feet stay planted, so the origin must come down),
  and the game stamps `DeathLootSpawnLocation` off that origin, then places the chest a fixed
  standing-height below it. The stamp is now corrected back to standing height (only when it isn't
  already ground-correct, which is measured rather than assumed), with a pawn-lift fallback if the
  write won't stick.
- **Crouch keys** (`features/qol.lua`): the Ctrl bind never existed — UE4SS's `Key` table has no
  Ctrl/Shift/Alt members at all (they live in `ModifierKey`, which only ever qualifies another
  key), so `Key["LEFT_CONTROL"]` was nil and the registration was silently skipped. Those keys are
  now bound by raw virtual-key code (sided *and* generic, since Windows reports Ctrl either way),
  and every bind is debounced so one press means one toggle. The crouch itself no longer hangs on
  a `bCanCrouch` write that UE4SS logs-but-does-not-throw on a half-constructed pawn, and it
  verifies a few frames later that the collision capsule really shrank (115 → 45 on this build).
  Crouch is a TAP TOGGLE, not hold-to-crouch: UE4SS delivers key-down events only.
- **Inventory at the airship wheel**: pressing the key now converges on an intent instead of
  firing one blind toggle — it stands down if the game's own inventory action already handled the
  press (two toggles inside a frame cancel out and look like a dead key), re-asserts if something
  else cancelled ours, and falls back to the game's chest-UI entry with your own inventory
  component if `ToggleInventory` no-ops while the ship is possessed.
- **Hotbar lift** while the inventory is open raised to sit under the inventory window
  (`qol_hotbar_y` −240 → −430; tune live with `sps set qol_hotbar_y <n>`), and it now **scales with
  the inventory**: a backpack upgrade adds whole rows to the grid (`W_PlayerInventory::GetRowCount`
  → 3/4/5/6 rows for tier 0/1/3/7), so the window's bottom edge drops and a fixed lift buries the
  hotbar underneath it. The lift grows a row's worth per row gained
  (`qol_hotbar_rows_base`, `qol_hotbar_row_px`).
- **Pings rebuilt**: the marker is a single plane that the game aims once, so it went edge-on and
  vanished as you moved around it. It now **turns to face the camera** — yaw only, so it stays
  standing upright — from a loop that runs only while a ping exists and re-finds its actors every
  step rather than holding one across a tick. It is also painted **one flat colour matching that
  player's map icon** — but since setting a material parameter is a proven native crash on this
  build (see above), each palette slot instead names a cooked game material whose **baked-in
  default look already is the slot's colour** (chosen by reading the compiled binaries offline:
  the blue/red build previews, the powered-device indicator's emissive green, the airship docking
  guide's yellow — all in the same translucent family as the stock ping art), applied with
  `SetMaterial`, the one material call this build has survived. That replaces both the old
  arbitrary per-player *cooked game materials* — which is why pings used to wear tomato leaves
  and wax grain — and the column of spawned point lights the mod stood at the marker, **which has
  been removed**. The marker is now a **clean ~110 m beacon**: 4× taller than before
  (`qol_ping_scale_z` 10), and SM_Ping's icon quad — which reads as a floating box once painted
  flat, and whose slot turned out to be **slot 0, not 1** (the cooked mesh says so) — is dressed
  in the engine's own draw-nothing masked material (`NaniteHiddenSectionMaterial`), leaving just
  the rod. `qol_ping_face`, `qol_ping_face_ms`, `qol_ping_face_yaw`, `qol_ping_rod_only`.

- **Storms now actually END.** The user report: daylight comes and the clouds clear, but the wind
  keeps thrashing the trees and lightning keeps falling — even for natural storms. Root cause:
  `InstantSunny` is a sky **repaint**, not a storm stop, and the mod's dawn checks called it on
  the game's OWN storms — clouds gone while the game's still-running thunderstorm kept its native
  thunder loop striking and its wind pinned at storm level. Now: ending a storm calls the weather
  manager's own **`DEBUG_StopWeather` program stop first**, then the repaint + wind restore; and
  dawn on a purely NATURAL storm only stands the mod's machinery down and lets the game blow its
  own storm out, sky, wind and thunder in agreement.
- **The hotbar now lands exactly under the open inventory at every backpack tier.** The cooked
  layout (not a guess): the inventory window's canvas slot is anchored *and* aligned at screen
  centre with auto-size, so it grows **symmetrically** — each added row (80 px slot, padding-free
  grid, no ScaleBox in the chain) moves the bottom edge down by **40 px**. The old formula moved
  the hotbar a full row *up* per row and parked it inside the window. `qol_hotbar_y` is the tuned
  lift at `qol_hotbar_rows_base` (5 rows — the tier it was dialled in at); `qol_hotbar_row_px`
  (40) is how far the window's bottom edge travels per row, in the correct direction.
- **Double chests now cover OCCUPIED chests too** — the old pass only grew empty ones (rebuilding
  an occupied array needs its old slots, and reading struct-array elements from Lua wedges the
  scheduler), which in practice meant every chest actually in use stayed at 12 slots. The
  end-run: the game itself moves slots **between** inventories by index (`MoveItemDiffInv`), so
  the mod stands a temporary chest on the same spot, moves the slots across game-side, grows the
  now-empty chest with `ForceReplace Inventory`, and moves everything back — each phase verified
  by `GetNrOfFreeSlots` counts, and on any miscount the shuffle stops *with* the items where they
  are (worst case: a second chest standing on the spot holding the goods; never a deletion).
  The mod's own buffer chests are blinded to the chest-spawn notify the moment they exist — a
  destroyed buffer lingers until GC with garbage free-slot counts, and growing *it* spawns
  another buffer (live: 1190 abort warns in 14 s until GC broke the chain). One shuffle attempt
  per sweep pass, and a chest that aborts three times is left alone. Verified live after the fix:
  every occupied chest on the test save grew (5–9 stacks riding along), zero aborts.
  `qol_chest_grow_occupied`.
- **The chest UI shows every slot now.** Its slot grid is built by
  `CreateItemSlotGrid(..., 2, 6, ...)` — dimensions are **literals in the widget's bytecode** —
  so a 24-slot chest displayed 12 widgets forever (`FillInventoryInGridPanel` only fills widgets
  that exist). A flight rewrite through a hook on the library call does NOT work: the build is an
  `EX_FinalFunction` static call, and UE4SS script hooks never see VM-internal calls (proven live
  — an armed hook fired on ProcessEvent calls but the game's own build sailed past it). Instead
  the grid is **rebuilt from outside after every open**: `UI_OpenChestInventory` *is* hookable
  (a CustomEvent stub → ProcessEvent), and 80 ms later the mod clears the panel, has the game's
  own library build ceil(len/6)×6 fresh slots, hands the new widgets back to `ChestSlots`
  (a TArray of object refs takes a Lua table — unlike struct arrays), and calls the widget's own
  `SyncAndFill_Chest` to repopulate. Verified live: grid and `ChestSlots` both read 24.
- **Hooks now survive world loads.** Loading a save GCs and **reloads whole Blueprint class
  chains**, and a hook registered against the menu-time copy of a class dies silently — the
  reloaded copy keeps the same path, so the stale registration is undetectable. All hook-owning
  features (qol, manual_save, ship_chest) now drop their stored registrations when the local
  controller instance changes (= a world was (re)loaded) and re-arm against whatever is resident;
  `UnregisterHook` first, so a surviving class never accumulates duplicates. This is what makes
  the map-name dressing, the chest-grid rebuild and the save-button hooks reliable on the second
  and later world loads of a session.

### Added (2026-07-27)
- **The airship simply HAS storage** (`features/ship_chest.lua`) — no chest upgrade needed (that
  upgrade collides with the other ship upgrades). A real `BP_Chest_Buildable` is kept at the
  inside back of the ship — the exact spot the game parks its own chest-upgrade lid — which buys
  the stock chest model, native walk-up interact, replication and save persistence for free.
  Never attached and never tick-followed (both are proven crash families): it is **re-anchored on
  events** — world entry and the airship's `ReceiveUnpossessed` (= someone stopped driving) — and
  remembered by location in the mod's sidecar save, so reloads adopt the restored chest instead
  of duplicating it. **At the wheel, the inventory key (TAB) opens the transfer view**: the ship's
  storage and your own inventory side by side (the chest UI already draws both), replacing the
  old blind-toggle dance. `[B]` prefers the stern chest too. `ship_chest`, `ship_chest_back/right/up`,
  `ship_chest_adopt_r`.

### Known limitations
- Mapped and tested against game build `24038177` only; a game update needs a re-map (and a pak
  rebuild) per `docs/RELEASE-CHECKLIST.md`.
- The wands render in-hand as a plain tinted stick — the game's tool-integration path can't be
  used by cooked items on this build (see `docs/DARK-ARTS.md`).
