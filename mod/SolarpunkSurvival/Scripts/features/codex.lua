-- The Tempest Codex: a REAL in-game book of the dark arts (content pak, tools/pakkit).
--
-- The pak clones the survival guide's whole data-driven chain: W_TempestCodex (the reader UI)
-- pulls its four sections (Origins / Pentagram / Implements / Electrick Wand) from the cooked
-- DB_TempestCodex table, and BP_TempestCodex_Placeable is the placed, interactable book (unlock
-- "The Dark Arts" research, craft the codex at the bench, then place it anywhere, like the
-- survival guide). The cooked placeable's native "open survival guide" virtual call was retargeted to the
-- controller's no-op ForceCloseInteractableUIs, so OPENING the codex UI is this feature's job:
-- hook the clone's interact event, create W_TempestCodex once (the game's own controller does the
-- same for the survival guide in StartupUI: Create -> AddToViewport, then Open per read), and
-- Open it on each interact.
--
-- MP: the interact event runs where the interaction is processed; the UI must only open for the
-- LOCAL player, so the hook compares the interacting controller against ours. Everything is
-- pcall-guarded and hook-driven -- no UObject is ever polled on a timer.
local F = {}
local ctx

local widget          -- the created W_TempestCodex instance (one per local player, reused)
local hooked = false
local warned = false  -- "pak missing" is logged once, not per interact attempt

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function codexMap() return ctx.map.codex or {} end

-- Why the last ensureWidget attempt failed (surfaced in the interact-time warn -- the boot-window
-- pin race taught us that silent returns cost a whole live session to diagnose).
local whyNot = "not attempted"

-- Find the widget class -- FIND-ONLY, never a native load. Two dead ends, both proven live
-- 2026-07-21, are documented here so nobody retries them:
--   * UE4SS LoadAsset cannot load our pak's packages (no AssetRegistry entry; classByName's
--     LoadAsset fallback silently no-ops -- harmless, just useless here).
--   * KismetSystemLibrary.LoadClassAsset_Blocking exists on this build, but UE4SS CANNOT marshal
--     its TSoftClassPtr param: the call goes native with a garbage soft path and FATALS the game
--     (the 23:45 menu-idle launch crash; pcall cannot catch a native fault). NEVER call the
--     *_Blocking soft-path loaders from Lua.
-- So the chain must be ROOTED, not re-loaded. The keeper recipe row alone proved NOT to hold it
-- (live 2026-07-22: "widget class not resident" one minute into a session), so the pak now also
-- plants a script OBJECT REFERENCE to W_TempestCodex_C in BP_TempestCodex_Placeable's interact
-- event bytecode (see build_wand_pak.py): while any codex stands placed, its class roots the
-- widget chain. This feature still parks its widget in the viewport as belt-and-braces.
local function loadWidgetClass(m)
  local cls = ctx.uehelp.classByName(m.widgetClass, m.widgetPath)
  if not cls then whyNot = "widget class not resident (UI chain GC'd; is the pak current?)" end
  return cls
end

-- Create the widget once and PARK IT IN THE VIEWPORT (hidden by design, exactly like the
-- controller pre-creates W_SurvivalGuide in StartupUI): a created, viewport-held widget is a
-- rooted reference that keeps the class chain alive for the rest of the session. The pin CANNOT
-- rely on the load window alone (proven live 2026-07-21): the chain loads at BOOT (DB_Buildables
-- roots the placeable class, whose import edge drags the UI in ~2s after process start), when no
-- PlayerController exists to own a widget, and the post-load GC evicts it seconds later --
-- loadWidgetClass's on-demand re-load is what makes ensureWidget work at interact time.
local function ensureWidget()
  local u, m = ctx.uehelp, codexMap()
  if u.isValid(widget) then return true end
  local pc = u.playerController()
  if not pc then whyNot = "no player controller (boot/menu)"; return false end
  local cls = loadWidgetClass(m)
  if not cls then return false end
  local wbl = StaticFindObject and StaticFindObject(m.wblPath)
  if not wbl then whyNot = "no WidgetBlueprintLibrary"; return false end
  local w
  pcall(function() w = wbl:Create(pc, cls, pc) end)
  if not u.isValid(w) then
    whyNot = "widget create failed"
    ctx.log.warn("codex: widget create failed")
    return false
  end
  pcall(function() w:AddToViewport(50) end)
  widget = w
  warned = false
  ctx.log.info("codex: the book is bound (widget pinned in viewport)")
  return true
end

-- Race the post-load GC: try soon, retry a few times (the player controller can lag the class
-- load by a beat during world load). Delay chain, never a poll.
local function pinSoon(tries)
  tries = tries or 4
  local function attempt(n)
    onGameThread(function()
      if ensureWidget() then return end
      if n <= 1 then
        -- surface the loss (a silent pin failure cost a whole live session to diagnose); the
        -- placeable's cooked script-ref root makes this rare -- see build_wand_pak.py
        ctx.log.info("codex: widget pin not settled yet -- " .. tostring(whyNot) ..
          " (interact re-tries)")
        return
      end
      if not pcall(ExecuteWithDelay, 700, function() attempt(n - 1) end) then attempt(n - 1) end
    end)
  end
  if not pcall(ExecuteWithDelay, 250, function() attempt(tries) end) then attempt(tries) end
end

-- Input focus. The widget never touches input mode itself (offline RE: for the survival guide
-- the CONTROLLER's ubergraph pairs the widget's Open with SetInputModeUI and the close path with
-- SetInputModeGame; the widget just shows/hides). The controller doesn't know our widget, so we
-- make its exact calls ourselves -- the guide's own call site reads
-- SetInputModeUI(UI_SurvivalGuide, DontQuitBuildingMode=false, LockMovement=IsGamepad,
-- ShowCursorOnGamepad=false, DisableTabNavigation=true), and every UI closes through
-- SetInputModeGame(false, false, false).
local uiFocused = false
local closeHooked = false

local function setUiFocus(on)
  local u, m = ctx.uehelp, codexMap()
  local pc = u.playerController()
  if not pc then return end
  if on then
    local ok = u.call(pc, m.inputUiFn or "SetInputModeUI", widget, false, false, false, true)
    if ok then uiFocused = true
    else ctx.log.info("codex: input-mode call failed -- the book opens without focus") end
  elseif uiFocused then
    uiFocused = false
    u.call(pc, m.inputGameFn or "SetInputModeGame", false, false, false)
  end
end

-- The widget's own X button runs its Close/Hide BP events: hook them to hand game input back.
-- (Real work deferred out of the BP call chain, as everywhere.)
local function armCloseHooks()
  if closeHooked then return end
  local m = codexMap()
  for _, fn in ipairs(m.closeFns or { "Close", "Hide" }) do
    local ok = pcall(RegisterHook, (m.widgetPath or "") .. ":" .. fn,
      ctx.log.guard("codex.close", function()
        onGameThread(function() setUiFocus(false) end)
      end))
    closeHooked = closeHooked or ok
  end
  if closeHooked then ctx.log.info("codex: close hooks armed (input restores on shut cover)") end
end

-- Create (once) + Open the codex widget for the local player, taking UI input focus.
local function openCodex()
  local u, m = ctx.uehelp, codexMap()
  if not ensureWidget() then
    if not warned then
      warned = true
      ctx.log.warn("codex: cannot open the book -- " .. whyNot)
    end
    return
  end
  armCloseHooks()
  u.call(widget, m.openFn or "Open")
  setUiFocus(true)
end

-- "The Dark Arts" research card, old-save migration. The card is tier-2 gated data-side
-- (StartingResearch=False; LvL_2's UnlockingResearchIDs reveals it), but a save that researched
-- LvL_2 BEFORE this pak existed never re-fires that unlock list, so the card would stay
-- invisible forever. Availability is just membership in the player's saved Researches array
-- (S_SavedResearch {id, Researched=false} -- RE'd from HasPlayerResearch?/UnlockResearch), and
-- the controller's own Playerdata_SaveResearchForSelf plants exactly one entry; UE4SS marshals
-- the struct param from a Lua table keyed by the BP-struct's suffixed field names (proven live
-- 2026-07-22 on the user's world: can=false -> can=true). Local player only; each machine runs
-- its own migration, and the save flow is the game's own host-authoritative path.
local migrated = false

local function migrateResearch()
  if migrated then return true end
  local u, m = ctx.uehelp, codexMap()
  if not (m.researchId and m.researchTierId and m.researchHasFn and m.researchSaveFn
      and m.researchFieldId and m.researchFieldDone) then return true end
  local pc = u.playerController()
  if not pc then return false end
  -- only touch the save when our pak is demonstrably active (a planted id with no table row
  -- would hand the research UI a rowless card)
  if not u.classByName(m.placeableClass, m.placeablePath) then return false end
  local function has(id)
    local t = {}
    if not pcall(function() pc[m.researchHasFn](pc, id, t, t) end) then return nil end
    return t.CanResearch == true, t.IsResearched == true
  end
  local _, tierDone = has(m.researchTierId)
  if tierDone == nil then return false end          -- playerdata not loaded yet; retry
  local cardCan, cardDone = has(m.researchId)
  if cardCan == nil then return false end
  -- the card is settled if it is already OFFERED (can) or already COMPLETED (done): re-planting
  -- a completed card as {Researched=false} would resurrect it in the station every session
  if not tierDone or cardCan or cardDone then migrated = true; return true end
  local ok = pcall(function()
    pc[m.researchSaveFn](pc, {
      [m.researchFieldId]   = m.researchId,
      [m.researchFieldDone] = false,
    })
  end)
  if ok then
    migrated = true
    ctx.log.info("codex: The Dark Arts surfaces in this elder world (research card migrated)")
  end
  return ok
end

-- Playerdata lags world entry (it loads during the join flow), so try on a spaced delay chain --
-- never a poll -- and stop as soon as one attempt settles the question.
local function migrateSoon()
  if migrated then return end
  local delays = { 4000, 12000, 30000 }
  local function attempt(n)
    onGameThread(function()
      if migrateResearch() then return end
      local nxt = delays[n + 1]
      if nxt and pcall(ExecuteWithDelay, nxt, function() attempt(n + 1) end) then return end
    end)
  end
  if not pcall(ExecuteWithDelay, delays[1], function() attempt(1) end) then attempt(1) end
end

-- Arm the interact hook on the cooked placeable's bound event. The class is loaded on demand
-- (LoadAsset via classByName), so this works before any codex has ever been placed.
local function hookInteract()
  if hooked then return end
  local u, m = ctx.uehelp, codexMap()
  local cls = u.classByName(m.placeableClass, m.placeablePath)
  if not cls then return end
  local paths = {}
  pcall(function()
    cls:ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n:find(m.interactFnHint or "OnInteractedWith", 1, true) then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  for _, path in ipairs(paths) do
    local ok = pcall(RegisterHook, path, ctx.log.guard("codex.interact", function(Context, comp, hit, controller, tool)
      local pc; pcall(function() pc = controller:get() end)
      -- real work OUT of the hook call chain (never mutate from inside the BP call)
      onGameThread(function()
        local localPc = ctx.uehelp.playerController()
        -- open only on the machine whose local player did the interacting (on the host the event
        -- also fires for remote players' controllers -- their UI is not ours to open). isValid,
        -- never `== nil`: a null-UObject wrapper is not Lua nil, and touching one native-crashes
        if not ctx.uehelp.isValid(pc) or ctx.uehelp.sameObject(pc, localPc) then openCodex() end
      end)
    end))
    if ok then hooked = true end
  end
  if hooked then
    ctx.log.info("codex: the placed book listens (" .. #paths .. " interact hook)")
    -- arm time == the placeable class just loaded == the widget chain is briefly resident: pin it
    pinSoon()
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "codex",
      { "codex.widgetClass", "codex.widgetPath", "codex.placeableClass", "codex.placeablePath" }) then
    return false
  end
  onGameThread(function() hookInteract() end)
  if not hooked then
    ctx.log.info("codex: placeable class not loadable yet (pak missing or not mounted) -- " ..
      "sps_codex retries and opens the book directly")
  end
  -- World entry re-arms the interact hook, re-pins the widget chain, and triggers the old-save
  -- card migration -- all off ONE trigger: a pawn constructing, the same rare, proven-safe
  -- notify the wand rides. NEVER a bare-Actor or controller construction notify: a 2026-07-22
  -- world-entry fatal (60s game-thread hang) bisected to exactly such notifies firing in the
  -- world-load actor storm. Mid-session placements need no notify of their own -- hookInteract
  -- armed at init covers the class, and openCodex re-resolves the widget chain per interact.
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    -- construction callback: defer everything out of the spawn stack (pinSoon already delays)
    if not pcall(ExecuteWithDelay, 200, function() onGameThread(hookInteract) end) then
      onGameThread(function() hookInteract() end)
    end
    pinSoon()
    migrateSoon()
  end)
  migrateSoon()  -- already in-world (hot reload / late init)
  pcall(function()
    RegisterConsoleCommandHandler("sps_codex", function()
      onGameThread(function()
        hookInteract()   -- retry arming in case the pak mounted after init
        openCodex()
      end)
      return true
    end)
  end)
  return true
end

return F
