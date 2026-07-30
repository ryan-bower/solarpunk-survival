# Changelog

All notable changes to this project are documented here. Versioning is [SemVer](https://semver.org/):
MAJOR = save-schema break, MINOR = new feature/phase, PATCH = re-map for a new game build / bugfix.

## [0.1.0] — Unreleased

### Install / tooling cleanup
- **The installer makes no network requests.** The Visual C++ 2015-2022 x64 runtime UE4SS links
  against now ships inside `vendor/UE4SS-Solarpunk-runtime.zip` and is placed *app-local* next to
  the game exe (which is the first directory Windows searches for a non-KnownDLL), so there is no
  machine-wide install and no UAC prompt. The `aka.ms` download survives only as a fallback for a
  payload built with `tools/make_ue4ss_runtime.py --no-vcruntime`.
- **`paks/` is the single source for the content pak.** `install.py` no longer falls back to
  `tools/pakkit/out/` — that made a working install depend on a 2 GB developer tree being on the
  same machine, and on any machine without it the installer only *warned* while producing a mod
  with no wands, no Tempest Codex, no Diamond Fishing Rod and no Sorting Chest. Missing is now a
  hard error naming `--skip-pak` as the opt-out.
- **`tools/run.py` deploys the player install by default.** `Scripts/dev` (RE dumper, the
  `dump/cmd.txt` exec channel, ritual kit, test kit) needs the new `--dev`, and a deploy without
  it prunes them back out — so every plain `/run` is a real rehearsal of what a player gets.
  `run.py` also runs the same runtime check `install.py` does.
- `install.py --status` reports what is installed (UE4SS, mod, dev tools present, pak, last loaded
  version) and changes nothing. `install.py --purge` removes everything the installer ever wrote —
  mod, pak, `dwmapi.dll`, the `ue4ss/` tree, the app-local runtime DLLs, a stray mod tree left by
  a bad `--game-dir`, and the `tools/.gamedir` cache — from a strict allow-list, so the game's own
  files are never touched.
- `install.bat`: a double-click launcher that finds a Python ≥ 3.8 and, when there isn't one, says
  where to get it instead of failing with a syntax error. It holds no install logic.
- **`sps_testkit`** (dev only, `Scripts/dev/test_kit.lua`): fast-forwards a fresh save to
  "everything testable" — every research card and recipe id unlocked (which is also how the
  crafting-table and research-station *tiers* work: they are `DB_Researchables` rows flagged
  `IsLevel`, not actor properties), backpack to tier 7, the pak items, a power rig, the ship
  repair kit, both rites' offerings and bulk materials, plus battery charging / forced device
  power. Symbols live in the new `mapping.progress` section. Host only.

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
- **Trash-can slot** (`features/trash_slot.lua`): one extra red-marked slot to the right of the
  bag's bottom-right cell. Drop an item in to queue it for deletion; drop another on top and the
  previous one is destroyed while the new one takes its place; the last item in stays retrievable
  until it is replaced or the session ends. The slot is a *real* `W_InventorySlot` (native carry,
  stacking, half-splits, tooltips) backed by a detached inventory system the save file cannot see —
  "logout forgets the trash" is structural, not a cleanup pass. Local to each machine, works for
  host and clients alike. `trash_slot = false` removes it; `sps_trash` reports, `sps_trash_clear`
  empties it.

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
  `qol_backpack_level` now also goes **down** — it ships at `0`, the stock 29-slot pack — but a
  shrink is not the mirror of a grow: growing only ever adds empty slots, while shrinking takes
  slots away that may have things in them. So a downgrade is skipped, with a log line naming the
  count, while more is carried than the smaller pack holds, and the new tier is not recorded until
  the live array is read back at the length the game's own `GetInvLengthForBackpackUpgradeTier`
  says that tier has — a record that disagrees with the array is the very thing that broke saves
  above. (Counts are all that can be checked: reading a struct-array *element* from Lua wedges the
  scheduler on this build.)
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
- **Inventory at the airship wheel**: the key now *toggles* the transfer view (ship storage +
  your own inventory) — press to open, press again (or ESC) to close. Two wrong referees died
  getting here, both convicted by the step log. First, the handler stood down whenever the
  game's own inventory action had just fired, assuming that press had opened the inventory —
  but at the wheel `ToggleInventory` runs and shows *nothing* (six presses, six game toggles,
  zero UIs), so the stand-down ate every press and TAB read as a dead key. Second, with the
  view up the mod tried to close it itself, gated on the widget's `IsOpen?` — but with any UI
  up the game is in UI input mode, its input *actions* are off entirely, and the focused
  widget's own key handling **already closes on the key** (`SetInputModeGame` fires with no
  toggle in sight); `IsOpen?` reads false during that hide animation, so "closing" looked like
  "closed" and the handler re-opened every close. Final shape: the game owns the close half
  natively, the mod owns only the open, and it stands down while the widget still *draws*
  (plain `IsVisible`, which stays true through the hide animation) — correct in both
  orderings of widget-vs-handler on one press. The old converge-on-intent toggle dance survives
  only as the open fallback for a ship whose chest is missing.
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
- **The hotbar comes back while the wheel's transfer view is open.** A chest UI never draws
  your first 8 slots itself — its player grid deliberately skips them, because the
  bottom-of-screen hotbar *is* their display (the game even makes its items moveable during
  chest use). But driving the airship swaps that hotbar out for the airship control icons
  (`SetShowHotbar(false)` / `SetShowAirshipControls(true)` — the leave-airship path flips the
  same pair back), so at the wheel the transfer view had no hotbar anywhere on screen. While
  the view is up the mod now borrows the on-foot arrangement — hotbar shown, control icons
  away — and puts it back when the UI closes if you're still at the wheel; stepping off the
  wheel restores it natively and the mod stands down for that case.
- **The chest UI shows your whole pack now, too.** Its player side is a 3×7 main grid plus a
  *separate* backpack grid hidden behind a switch button (`UpdateBackpackDisplayIfRequired`
  sizes the second grid from the `Playerdata` tier record) — so with an upgraded pack the
  transfer view reads as "only the first 3 rows of my inventory". The same post-open rebuild
  that fixes the chest side now rebuilds the player side as **one grid carrying every bag row**,
  sized from the inventory array itself (a wrong tier record can't shrink it), with the backpack
  grid emptied and the switch collapsed. The game's fill loop skips the array's 8 leading
  hotbar entries, so bag slots are always whole 7-wide rows; odd lengths are left alone.
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
  old blind-toggle dance. `[B]` prefers the stern chest too. The chest sits a quarter-turn across
  the ship rather than lengthwise (`ship_chest_yaw`, 90; set 270 if the lid should open the other
  way). `ship_chest`, `ship_chest_back/right/up`, `ship_chest_adopt_r`.

### Added (2026-07-29)
- **Airship boost** (`features/boost.lua`): SPACE at the wheel pushes the throttle to max and
  boosts to **3× top speed**, with the ship camera's FOV raised by 20° and the game's own
  airship wind loop (`S_Wind_AirshipSpeed`) plus speed VFX. Unlimited duration; SPACE again or
  holding the slow-down control glides back to normal max over 3 s, then the ship decelerates
  normally. Rides the ship's own `BoostAddition` velocity channel (bytecode RE: velocity =
  `(CurrentSpeed + BoostAddition) × 50`, and only the dock-autopilot timeline ever writes it) —
  the motor pitch reacts natively. On-foot SPACE is untouched (the bind gates on
  `IsControllingAirship?`); the ship gently lifts while SPACE is held (the game's own lift bind)
  — accepted side effect.
- **Hydration wand drinks** (`features/wand.lua`): HOLD right-click with the blue rod to drink
  from it — thirst refills at 25 %/s while the rod's water drains at the matching pro-rata cost,
  so a full 0→100 % drink spends exactly the whole wand. Rate is percent-of-max (live saves
  carry `MaxPlayerThirst = 1000`). `wand_drink_mode = toggle` if a build fires the alt event
  once per press.
- **Player names on the co-op map** (`features/qol.lua`): always-visible name labels floated
  above each player's position, placed via the map's own `WorldToMapCoordinates` from live pawn
  locations every 150 ms while the map is open — sidestepping the game's flaky `FriendsMarkers`
  reconciliation (the "sometimes missing players" bug) entirely. Capability-latched: a build
  that refuses TextBlock construction logs one warning and drops only this feature.
- **The blue Sorting Chest** (content pak + `features/sort_chest.lua` + `features/chest_index.lua`):
  a craftable, powered, cobalt-blue chest (bench recipe: 4 logs, 4 iron, 2 cobalt) that files
  its contents into other chests within 50 m. Every pass it Quick Stacks into the next chest on
  the rotation — the game's own `Quick Stack` pulls exactly the item classes that chest already
  holds, which is the sorting rule; items no neighbor wants simply stay put. Draws **500 power
  while loaded, 100 idle** (cable hookup like any powered machine) and pauses without power.
  Cooked as a de-furnaced `BP_EnergyFurnace_Placeable` clone: crate mesh in the cobalt ore's
  blue, every smelt/fuel/timer function stubbed to bytecode no-ops, interact stub hooked from
  Lua to open the plain chest UI.
- **Crafting auto-pull** (`features/craft_pull.lua`): while a crafting bench, energy bench or
  kitchen is open, any recipe on screen fetches its missing materials from chests within 50 m
  straight into your inventory (chest `Remove Item Amt` → player grant, nearest chest first,
  capacity pre-flight) — so the "1/5" you'd go ferrying for becomes a real, craftable 5/5.
  Shortfall counts are re-scanned every 300 ms via the recipe widgets' own `NeedAmt`/`HaveAmt`.
  Both chest features share `features/chest_index.lua`, a demand-driven memoized stock ledger
  (per-chest per-item counts with TTL, patched immediately by the mod's own moves; zero timers).
- **A third fishing minigame — gap-sync** (`features/fishing.lua` + `fishing_ui.lua`): two
  vertical lanes; an invisible left lane carries a thin line that oscillates at 1–2× the
  sliding bar's top speed and **grows** at 2× its base height per second (cap 9×); the right
  lane's rect-gap-rect trio oscillates at its own speed. Click freezes both and slides the line
  right: fits the gap → flush slot-in, green flash, the normal loot roll; miss → it stops
  against the lane's face, red flash, nothing. Wheel / gap-sync / sliding bar now roll ~evenly
  (0.34/0.33/0.33); rain/storm skillshot-chance boosts unchanged.
- **Airship recall at 20×** (`qol_recall_mult = 20`): a deliberate TEST value for the existing
  dock-recall speed-up so the effect is unmissable in play — dial to taste afterwards.

### Added (2026-07-30)
- **Sit on benches** (`features/bench.lua`): right-click a bench with **empty hands** to sit in
  an open seat (three side by side; chairs, stools and couches seat too — the per-class seat
  table covers them at zero cost), right-click again to get up. Sitting never teleports and
  never changes movement mode — it **pins**: crouched pose (through qol, so the death-loot fix
  keeps working and the crouch keys can't stand a sitter up), speed capped via
  `MaxWalkSpeedCrouched` (the one knob the game never writes — sprint can't break the pin),
  movement input ignored at the controller (jump is blocked by the crouch for free), sitter
  faced outward. Occupancy is derived from replicated pawn positions — every machine agrees
  about who sits where with zero custom replication. Auto-releases on death, respawn, bench
  destroyed, or drifting off the seat; `sps_bench unstick` is the unconditional escape.
- **The airship passenger bench** (`features/bench.lua`): every ship grows a real bench at the
  stern (just forward of the storage chest, on the deck; adopt-by-proximity across reloads,
  never duplicated, Pawn collision knocked off so it can never punt or obstruct). **Up to
  three other players sit there and ride while the owner flies** — the seats are computed
  from the ship transform, so they work even on a machine that can't see the prop, and a
  seated pawn rides the ship through the engine's own based movement (the only network-legal
  carry for a client). While someone is at the wheel (`ship.PlayerState` — replicated to
  everyone) sitters are **locked in until the owner parks**; every game eject path and the
  qol recall assist release the seats first (`bench_lock_mode`: 0 off / 1 piloted / 2 moving /
  3 either).
- **Non-owner boarding opened** (`features/bench.lua`): the airship's `NonOwnerBlocker` — a
  Pawn-only collision capsule enclosing the interior — gets Pawn→Ignore on every machine, and
  the unblock is **re-asserted** (door-trigger hook + the ship watch, read-before-write) since
  the game's own controller timer re-arms the wall. Note: an unmodded client on a modded host
  still can't board — the host's simulation blocks their pawn; both machines need the mod.
  `bench_open_ship = false` restores the wall.
- **Ship props are real ship geometry** (`features/bench.lua`, `features/ship_chest.lua`): the
  stern bench and storage chest are attached to the ship with their pose written in **ship-local
  space** after the glue — a KeepWorld attach used to freeze whatever world pose existed at that
  instant, so attaching while the ship lay tilted (login mid-flip) baked the tilt in and the
  righted ship wore crooked props. They now bank, pitch and right with the hull. And they block
  **nothing**: the chest's mesh answers every collision channel with **Overlap** (never a
  blocking hit, so neither the hull sweep nor a pawn is obstructed — it had kept full collision
  and ground against the hull, shoving the flying ship around) except two trace channels that
  stay Block: Visibility (pack-up/hand traces) and the game's custom **Interactable** channel —
  `TraceForInteractable` line-traces TraceTypeQuery3 for the walk-up open, and a single trace is
  blind to Overlap (all-Ignore killed open while destroy kept working, found live). The
  Interactable ECC slot is config-assigned, so it's resolved at runtime from the engine's
  CollisionProfile CDO (fallback GameTraceChannel1). Blocking trace channels can never obstruct
  movement — sweeps test object channels. Applied on every machine since responses don't replicate;
  the bench was already collision-free. Players clip through by design — per spec, the props
  must never obstruct the player or the ship.
- **Crafting-table crash fixed** (`features/craft_pull.lua`): opening a crafting station could
  kill the game with a native access violation (two crash dumps, both dying in UE4SS's UObject
  member glue reading address `0x20` ≈ null + offset, ~150 ms after the open — symbolized with
  the UE4SS pdb via dbghelp). Root cause: UE4SS returns a **truthy wrapper around a NULL object
  pointer** (the qol `tintIcon` lesson), and any member call on it is an AV that `pcall` cannot
  catch. craft_pull's scan hit that two ways: a recipe row with an unset `ItemActor` field
  passed the `~= nil` gate and `GetFullName` AV'd; and a stale row from a *previously closed*
  station walked its outer chain past the dead owner to the package top, where `GetOuter`
  returns the null wrapper and the next `GetFullName` AV'd. Both sites now gate through
  `safeForCalls` — `IsValid()` (which null-checks before dereferencing) when the wrapper has
  it, while still letting the DB_Items soft-class wrappers through (their method failures are
  ordinary, catchable Lua errors).
  the mapping *profile* but missing from the *schema*, and `mapping.resolve` strictly filters
  by schema — the dock-map name-label fix read nil for all of them at runtime. Schema now
  carries them (regression-tested).
- **The Tempest Handbook** — a second real, readable, placeable book that summarises every
  finished feature of the mod in eight sections (Storms · Dark Arts · The Unlit · Fishing ·
  Airship · Homestead · Pack & Person · New Things), 24 pages, written as one settler's notes to
  another. It is a **starting recipe in the quick-craft (F) menu for 1 log + 2 leaves** — the
  same cost as the vanilla survival guide and no research card — so a brand-new player can craft
  the thing that explains the mod in their first minute. The Dark Arts section stays deliberately
  high level and points the reader at the Tempest Codex for the rites.
  Under it, `tools/pakkit/build_wand_pak.py`'s codex chain became a **book-spec factory**
  (`BOOKS` + `_names`): enum, tips table, both widget components, the reader widget, the item BP
  and the placeable are all generated per slug, so a third book costs one spec. The codex's own
  cooked assets are byte-identical across the refactor (bar `base_text`'s per-build random
  localisation keys). Supporting work: `CAT_FNAME` extended to all nine vanilla
  `EGameplayTipCategory` byte↔FName pairs (decoded from the legacy `.uexp`; **nine sections is
  the hard ceiling for any book**), `ICON_DIR_OVERRIDES` filled in for every `/Game/UI/ItemIcons`
  texture including the ones this build stages, a build-time page-icon existence check, and
  `_check_replaces` — an assert on `clone_asset`'s two ordering invariants (no source a substring
  of another source; no target containing a later source), because the replace lists are now
  *generated* from a slug rather than hand-reviewed.
  The hidden `TempestCodexKeeper` recipe row now carries **one part slot per book**, each holding
  a reader-widget class ref: a row struct's slot array is walked element-wise by
  `AddReferencedObjects`, so one row roots every chain and costs no extra recipe id.
  `features/codex.lua` became a two-book feature: widget, hooks and diagnostics are per book,
  while input focus and the `UI_SurvivalGuide` repoint stay shared and **arbitrated**, because
  they are properties of the controller. The arbiter refuses to adopt one of our own widgets as
  "the real guide" and self-heals from the stashed original — without it, a leaked repoint from
  book A would be captured by book B and written back on close, orphaning the vanilla survival
  guide for the rest of the session. New console command `sps_handbook`. New recipe id **10010**,
  appended last so every existing `Playerdata.UnlockedRecipys` entry keeps its meaning, with an
  `EXPECTED_IDS` assert in the build to keep it that way; `verify_pak` now also checks the
  quick-craft contract, the keeper's slot count and each placeable's widget-class import edge.
- **The P and F7 development binds are gone.** Both were testing controls — P forced a
  thunderstorm so the strike systems could be exercised on demand, F7 dumped mod status — and
  both are retired now that that testing is done. Storms arrive with the game's own weather
  (`storms.lua` already detects them as `naturalStorm` and everything downstream keys off
  `stormy()`), and `sps` prints the same status F7 did. The `storm_key` and `imgui_key` config
  keys are removed with them, since a live key name is what registers the bind. Every console
  command is unchanged, `sps_storm` included. Play binds (V, C / Left Ctrl, B, TAB, SPACE) are
  untouched.
- **The vanilla fishing rod is replaced by a modded clone** (`ModFishingRod`, pak + `fishing.lua`).
  The vanilla rod's class sits inside `UpdateHandMeshesAndModes`' hardcoded tool ladder, so
  closing any UI destroyed its hand actor and uncast a thrown line (the recast shim was its
  ceiling), and its VM-internal `Catch()` forced the leaf-swap hack on every skillshot reveal.
  The clone is the diamond rod's proven row shape at **exactly vanilla stats** (same icon, same
  "Fishing Rod" name, durability 200, 5% skillshot, no luck bonus): its cast now **survives
  closing the inventory**, and its minigames run clean — no leaf drop, mod-driven reel, the
  wheel can hold the line through its slow-down. Replacement is total: the game's own
  `FishingRod` **recipe end product is repointed** at the clone (same persisted RecipyID — every
  save keeps its unlock, benches just craft the modded rod now), the **loot tables** drop the
  clone, and a one-time host sweep at world entry **reforges rods already in any inventory**
  in place (quantity + durability preserved; hard-gated on the pak class resolving, so a
  pak-degraded session leaves vanilla rods untouched). The vanilla `DB_Items` row stays so
  legacy rods keep resolving, and every old vanilla-rod shim survives as the fallback path.
  The **rod ledger now tracks both pak rods** (the clone inherits the diamond rod's vanish
  risk; per-kind sidecar flags, `mod_rod_ledger`) and `sps_fish_rescue` reels in both kinds.
  New config `fishing_rod_replace`, new console command `sps_fish_migrate`.
- **Diamond rod durability 2000 → 999** (user spec). The pak row, `mapping.fishing
  .diamondDurability` and the build verify all agree; the migration sweep also clamps over-max
  diamond rods found in older saves so their bars read sane.

### Known limitations
- Mapped and tested against game build `24038177` only; a game update needs a re-map (and a pak
  rebuild) per `docs/RELEASE-CHECKLIST.md`.
- The wands render in-hand as a plain tinted stick — the game's tool-integration path can't be
  used by cooked items on this build (see `docs/DARK-ARTS.md`).
