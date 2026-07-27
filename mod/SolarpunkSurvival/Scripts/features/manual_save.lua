-- Save on demand: a "Save Game" button in the pause menu (2026-07-26 request).
--
-- The button runs the game's OWN periodic autosave -- BPC_SaveManager.Save, the very function the
-- autosave timer is bound to. Nothing here reimplements saving, writes a slot, or touches the
-- save file: see mapping.savemenu / mapping.save for the RE notes behind every symbol.
--
-- HOST ONLY. CachedSave (the save object the write serialises) is built inside the IsServer branch
-- of the manager's Initialize, so on a client Save() would broadcast the pre-save flush into a null
-- object and then hand AsyncSaveCompressedGameToSlot a null SaveGame under the CLIENT's own last
-- world-slot name. There is no client->host save RPC to ride (that needs the LogicMod pak the mod
-- doesn't ship yet), so a client is given no button at all rather than a lying one.
--
-- The double-save guard, which is the whole point of the safety work:
--   * `Save` itself is hooked, so the flag is raised by the GAME's autosave too -- clicking during
--     an autosave is refused, not queued behind it;
--   * the flag is also raised optimistically before our own call, so a double-click cannot slip
--     through in the window before the hook body runs;
--   * it is lowered by the "write finished" hook (OnAutoSaveCompleted's handler), and failing
--     that by a timeout -- a lost completion signal must never wedge the button shut for good;
--   * a short cooldown after a completed save keeps an impatient player from immediately asking
--     for a second full write.
--
-- Module rules inherited from the crash post-mortems (see the gotchas memory): hook bodies touch
-- no UObjects and only schedule; nothing polls a UObject on a timer; every reflected call is
-- guarded and degrades to a logged no-op.
local F = {}
local ctx

local function smap() return ctx.map.save or {} end
local function mmap() return ctx.map.savemenu or {} end

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function defer(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then onGameThread(fn) end
end

-- Schedule-ONLY defer, for hook bodies: defer()'s fallback runs fn inline, and the click hook's
-- work (widget reads, a reflected Save call) may never run on the hook thread.
local function deferOnly(ms, fn)
  if not pcall(ExecuteWithDelay, ms, fn) then
    ctx.log.debug("manual_save: no delay scheduler; dropped deferred work (hook bodies never run inline)")
  end
end

-- Resolve a UFunction's full object path off a live instance (RegisterHook rejects short
-- "Class:Fn"). Mirrors features/qol.fullFuncPath.
local function fullFuncPath(obj, fnName)
  local full
  pcall(function()
    obj:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if n == fnName then pcall(function() full = fn:GetFullName() end) end
    end)
  end)
  if full then return (full:gsub("^%S+%s+", "")) end
  return nil
end

local function fullName(obj)
  local n
  pcall(function() n = obj:GetFullName() end)
  return n
end

--------------------------------------------------------------------- save state
local inFlight     = false -- a write is running RIGHT NOW (ours or the game's autosave)
local inFlightAt   = 0
local lastDoneAt   = -1e9  -- when the last write landed (cooldown baseline)
local startedHooked = false -- is the game's Save hooked? (it carries the sidecar-state write)
local doneHooked   = false -- did any "write finished" signal arm? (else the timeout carries us)

local function cfg(key, fallback)
  local v = ctx.config.get(key)
  if v == nil then return fallback end
  return v
end

-- Is a save already running? Self-healing: an in-flight state older than the timeout is treated as
-- finished, because the alternative (a completion signal that never arrives) locks the button out
-- for the rest of the session.
local function busy()
  if not inFlight then return false end
  if os.clock() - inFlightAt > (cfg("save_button_timeout", 60.0)) then
    ctx.log.warn("manual_save: no 'save finished' signal within the timeout; clearing the in-flight flag")
    inFlight = false
    -- deliberately NOT touching lastDoneAt: the click that cleared a stale flag should be allowed
    -- through, not bounced straight back off the cooldown for a save nobody can confirm happened
    return false
  end
  return true
end

local function saveManager()
  local s = smap()
  local gs = ctx.uehelp.findFirst(s.gameStateClass)
  if gs then
    local ok, mgr = ctx.uehelp.get(gs, s.managerProp)
    if ok and ctx.uehelp.isValid(mgr) then return mgr end
  end
  -- degrade path: the component is findable on its own if the game state class ever moves
  return ctx.uehelp.findFirst(s.managerClass)
end

-- A manual save resets the autosave clock. The game's timer is LOOPING and bound straight to Save,
-- so without this it would happily write again seconds after the player just did.
-- InvalidateAndSetAutosaveInterval is the game's own clear-and-re-arm, called with the interval the
-- manager itself carries -- but a bad value here would silently kill autosaving for the whole
-- session, so anything that doesn't read back as a sane number leaves the timer alone.
local function rearmAutosave(mgr)
  local s = smap()
  if not (s.autosaveArmFn and s.intervalProp) then return end
  if not cfg("save_button_rearm_autosave", true) then return end
  local ok, iv = ctx.uehelp.get(mgr, s.intervalProp)
  if type(iv) == "userdata" then pcall(function() iv = iv:get() end) end
  if not ok or type(iv) ~= "number" or iv < 10 or iv > 3600 then
    ctx.log.debug("manual_save: autosave interval reads " .. tostring(iv) .. "; leaving the timer alone")
    return
  end
  ctx.uehelp.call(mgr, s.autosaveArmFn, iv)
end

--------------------------------------------------------------------- the button
local armClickHook          -- defined with the other hooks below; needed by ensureButton
local button       = nil    -- our W_MenuButton_V2 instance
local buttonName    = nil   -- its full object name, for the shared class-level click hook
local injectedMenu  = nil   -- full name of the menu we injected into (a new world builds a new one)
local labelRestore  = 0     -- token so only the newest "Saved" flash restores the idle label

-- The label goes through the widget's own SetText and NOWHERE else. Writing the button's `Text`
-- FText PROPERTY directly (belt-and-braces against a PreConstruct re-run) was tempting and is
-- deleted on purpose: it parks a Lua-owned FText inside a UObject and leaves the widget holding
-- it after Lua collects the temporary -- the exact null/dangling-wrapper shape behind this
-- project's uncatchable AVs. SetText's callee copies the text properly, and PreConstruct only
-- ever runs once for a runtime-created widget, so the property write bought nothing.
local function setLabel(text)
  if not (ctx.uehelp.isValid(button) and FText) then return end
  local ft
  if not pcall(function() ft = FText(tostring(text)) end) then return end
  ctx.uehelp.call(button, mmap().buttonTextFn, ft)
end

local function idleLabel() setLabel(cfg("save_button_label", "Save Game")) end

-- Feedback lives on the button itself rather than the HUD's "Saving..." indicator: the pause menu
-- is what the player is looking at, and the overlay behind it may well be hidden.
local function flashSaved()
  setLabel(cfg("save_button_done_label", "Saved"))
  labelRestore = labelRestore + 1
  local token = labelRestore
  defer(math.floor((cfg("save_button_done_seconds", 3.0)) * 1000), function()
    if token == labelRestore and not inFlight then idleLabel() end
  end)
end

--------------------------------------------------------------------- doing it
-- Returns ok, reason. Never throws; every failure is a logged no-op.
local function saveNow()
  if not ctx.net.isHost() then return false, "only the host writes the world save" end
  if busy() then return false, "a save is already running" end
  local cool = cfg("save_button_cooldown", 10.0) or 0
  local since = os.clock() - lastDoneAt
  if since < cool then return false, string.format("the last save landed %.0fs ago", since) end
  local mgr = saveManager()
  if not mgr then return false, "no save manager (not in a world yet?)" end
  local fn = smap().saveFn
  if not fn then return false, "save.saveFn is unmapped" end

  -- Shut the door BEFORE the call. The Save hook raises this too, but if that hook never armed
  -- this flag is the only thing standing between a double-click and two concurrent writes.
  inFlight, inFlightAt = true, os.clock()
  setLabel(cfg("save_button_busy_label", "Saving..."))
  local ok = ctx.uehelp.call(mgr, fn)
  if not ok then
    inFlight = false
    idleLabel()
    return false, "the game's " .. tostring(fn) .. " call failed"
  end
  rearmAutosave(mgr)
  -- Our own sidecar state rides the game's save (core/save.lua's designed contract). Emitted here
  -- only when the Save hook isn't carrying it -- when it is, it covers autosaves too.
  if not startedHooked then ctx.bus.emit("save.write") end
  ctx.log.info("manual_save: save requested from the pause menu")
  return true
end

--------------------------------------------------------------------- injection
local function makeButton(pc)
  local m = mmap()
  local cls = ctx.uehelp.classByName(m.buttonClass, m.buttonPath)
  if not cls then ctx.log.warn("manual_save: " .. tostring(m.buttonClass) .. " not resident"); return nil end
  local wbl = StaticFindObject and StaticFindObject(m.wblPath)
  if not wbl then ctx.log.warn("manual_save: no WidgetBlueprintLibrary"); return nil end
  local w
  pcall(function() w = wbl:Create(pc, cls, pc) end)
  if not ctx.uehelp.isValid(w) then ctx.log.warn("manual_save: button create failed"); return nil end
  return w
end

-- Every BTN2_ slot in BOX_MenuButtons ships Padding {Bottom = 4}; a freshly added slot gets the
-- UMG default of zero, so re-apply it or the menu's spacing collapses around the new row.
local PAD = { Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 4.0 }

local function appendToBox(box, w)
  local m = mmap()
  local ok, slot = ctx.uehelp.call(box, m.boxAddFn, w)
  if not ok then return false end
  if m.slotPadFn and ctx.uehelp.isValid(slot) then ctx.uehelp.call(slot, m.slotPadFn, PAD) end
  return true
end

-- BOX_MenuButtons is rotated 180 degrees so the menu grows upward from the bottom of the screen,
-- and every button inside carries a 180 counter-rotation so its own label reads the right way up.
-- A widget we create has no transform at all, so it inherits the box's flip and renders upside
-- down. Copy the angle off a real sibling (Resume) and fall back to the mapped constant, because a
-- future build could re-author the menu without the rotation -- in which case Resume reads 0 and we
-- correctly apply nothing.
local function matchFlip(w, sibling)
  local m = mmap()
  if not m.setAngleFn then return end
  local angle
  if m.renderTransformProp and m.angleField and ctx.uehelp.isValid(sibling) then
    pcall(function()
      local ok, xf = ctx.uehelp.get(sibling, m.renderTransformProp)
      if ok and xf then angle = tonumber(xf[m.angleField]) end
    end)
  end
  if angle == nil then angle = tonumber(m.buttonAngle) end
  if angle == nil then return end
  ctx.uehelp.call(w, m.setAngleFn, angle)
end

-- Park the new button immediately under Resume. A Blueprint/Lua caller can only APPEND to a
-- UVerticalBox (InsertChildAt and ShiftChild are C++-only), and Resume is the box's last child --
-- which, through the box's 180 rotation, is the VISUAL top -- so the order is bought by appending
-- ours and then re-appending Resume behind it. Resume is out of the box for exactly one call and
-- goes back unconditionally -- losing it would cost the player their Resume button (ESC still
-- closes the menu, but that is not a trade worth making silently), so a failed re-add is loud.
local function placeUnderResume(box, resume)
  if not ctx.uehelp.isValid(resume) then return end
  local okRemove, removed = ctx.uehelp.call(box, mmap().boxRemoveFn, resume)
  if not (okRemove and removed == true) then return end
  if not appendToBox(box, resume) then
    ctx.log.error("manual_save: could not put Resume back into the pause menu (ESC still closes it)")
  end
end

-- Is our button still sitting in THIS menu's box? A plain isValid on the stored reference is not
-- enough: a level change builds a fresh W_IngameMenu, UE recycles object names, and a stale
-- pre-GC widget can still answer IsValid -- which would fast-out the injection and leave the new
-- menu with no Save button for the rest of the session. Asking the box settles it.
local function stillInBox(box)
  if not ctx.uehelp.isValid(button) then return false end
  local fn = mmap().boxHasFn
  if not fn then return true end      -- unmapped: fall back to the isValid answer
  local ok, has = ctx.uehelp.call(box, fn, button)
  if not ok then return true end
  return has == true
end

local function ensureButton(menu)
  if not cfg("save_button", true) then return false end
  local m = mmap()
  local okBox, box = ctx.uehelp.get(menu, m.buttonsBoxProp)
  if not (okBox and ctx.uehelp.isValid(box)) then return false end
  if injectedMenu == fullName(menu) and stillInBox(box) then return true end
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
             or ctx.uehelp.playerController()
  if not pc then return false end

  local w = makeButton(pc)
  if not w then return false end
  if not appendToBox(box, w) then
    ctx.log.warn("manual_save: could not add the button to " .. tostring(m.buttonsBoxProp))
    return false
  end
  button, buttonName = w, fullName(w)
  injectedMenu = fullName(menu)
  idleLabel()

  local _, resume = ctx.uehelp.get(menu, m.resumeButtonProp)
  matchFlip(w, resume)
  placeUnderResume(box, resume)

  -- The click hook needs a live instance of the button class to resolve its UFunction path, and
  -- ours is the one instance guaranteed to be that exact class.
  armClickHook(w)
  ctx.log.info("manual_save: '" .. tostring(cfg("save_button_label", "Save Game")) ..
    "' added to the pause menu")
  return true
end

--------------------------------------------------------------------- arming
local hooked = {}       -- key -> { preId, postId, path = funcPath }
local hookWorldPc       -- local controller fullname the registrations belong to

-- World load GCs and RELOADS whole class chains (proven live 2026-07-27 on the qol chest-grid
-- hook): a registration made against the menu-time copy of a class dies silently when LoadSave
-- reloads it, and the reloaded copy keeps the same full path. So when the world changes (a new
-- local controller instance), every stored registration is dropped and the next apply() re-arms
-- against whatever is resident. Unregistering a dead copy no-ops (pcall); a surviving one loses
-- our own hook and gets it right back -- net one live hook either way.
local function clearHooks()
  for key, h in pairs(hooked) do
    if type(h) == "table" and h.path then pcall(UnregisterHook, h.path, h[1], h[2]) end
    hooked[key] = nil
  end
end

local function armHook(inst, fnName, tag, body)
  if not (inst and fnName) then return false end
  local key = tostring(ctx.uehelp.className(inst)) .. ":" .. fnName
  if hooked[key] then return true end
  local path = fullFuncPath(inst, fnName)
  if not path then return false end
  local ok, pre, post = pcall(RegisterHook, path, ctx.log.guard(tag, body))
  if not ok then return false end
  hooked[key] = { pre, post, path = path }
  ctx.log.debug("manual_save: hooked " .. path)
  return true
end

-- Hooks the button class's own click handler. UE4SS cannot bind a Blueprint multicast delegate
-- from Lua, so this fires for EVERY W_MenuButton_V2 in the game (main menu included) and filters
-- on the instance. The body touches nothing but Lua state and schedules the work.
armClickHook = function(inst)
  local ok = armHook(inst, mmap().buttonClickFn, "manual_save.click", function(Context)
    local self_
    pcall(function() self_ = Context:get() end)
    if not self_ then return end
    if fullName(self_) ~= buttonName then return end   -- some other menu button
    deferOnly(0, function()
      local done, why = saveNow()
      if not done then ctx.log.info("manual_save: not saving -- " .. tostring(why)) end
    end)
  end)
  if not ok then
    ctx.log.warn("manual_save: the button's click handler could not be hooked -- the button will " ..
      "sit there doing nothing (mapping savemenu.buttonClickFn)")
  end
  return ok
end

-- The save-manager side: who is writing, and when they finish.
local function armSaveHooks()
  local s = smap()
  local mgr = saveManager()
  if not mgr then return end

  -- Every write goes through Save, the game's autosave included, so this is what makes a click
  -- during an autosave a refusal instead of a second concurrent write.
  if armHook(mgr, s.saveFn, "manual_save.started", function()
    inFlight, inFlightAt = true, os.clock()
    deferOnly(0, function()
      setLabel(cfg("save_button_busy_label", "Saving..."))
      -- our sidecar state rides every game save, autosaves included (core/save.lua's contract)
      ctx.bus.emit("save.write")
    end)
  end) then
    startedHooked = true
  end

  for _, sig in ipairs(s.saveDoneFns or {}) do
    local owner = sig.class and (ctx.uehelp.className(mgr) == sig.class and mgr
                                 or ctx.uehelp.findFirst(sig.class))
    if armHook(owner, sig.fn, "manual_save.done", function()
      inFlight   = false
      lastDoneAt = os.clock()
      deferOnly(0, flashSaved)
    end) then
      doneHooked = true
      break     -- first signal that arms wins; a second would just double-flash the label
    end
  end
  if not doneHooked then
    ctx.log.debug("manual_save: no 'save finished' signal armed yet; the in-flight guard is on its timeout")
  end
end

-- Everything the feature needs, (re)established whenever the world might be new. Cheap and
-- idempotent: each step fast-outs the moment its work is already done.
local function apply()
  if not ctx.net.isHost() then return end
  -- new local controller instance = a world was (re)loaded: drop the last world's registrations
  local pcNow
  pcall(function()
    local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
    pcNow = pc and pc:GetFullName() or nil
  end)
  if pcNow and pcNow ~= hookWorldPc then
    hookWorldPc = pcNow
    clearHooks()
  end
  armSaveHooks()
  local menu = ctx.uehelp.findFirst(mmap().menuClass)
  if not menu then return end
  -- Re-inject on every Open too: a level change builds a fresh menu widget, and injecting into
  -- the hidden widget up front means the button is there the first time ESC is pressed.
  armHook(menu, mmap().menuOpenFn, "manual_save.menu", function()
    deferOnly(50, function()
      local m = ctx.uehelp.findFirst(mmap().menuClass)
      if m and ctx.net.isHost() then ensureButton(m) end
    end)
  end)
  ensureButton(menu)
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "manual_save",
      { "save.saveFn", "save.gameStateClass", "save.managerProp",
        "savemenu.menuClass", "savemenu.buttonsBoxProp", "savemenu.buttonClass",
        "savemenu.buttonClickFn", "savemenu.boxAddFn", "savemenu.wblPath" }) then
    return false
  end
  if not cfg("save_button", true) then
    ctx.log.info("manual_save: disabled (save_button = false)")
    return true
  end

  -- A new local pawn means world entry, a reloaded save or a respawn -- the one moment the game
  -- state, the controller and its pre-created menu are all guaranteed to exist. Multiplexed on
  -- the one Engine.Character notify channel the other features already share.
  --
  -- Animals are Characters too, so this notify fires for every Unlit a storm spawns: gate on the
  -- LOCAL pawn actually being a new instance before doing any of the reflected work, or the
  -- feature quietly re-adds the per-spawn host cost the storm perf pass went and removed.
  -- COALESCED, for the same reason qol's copy of this is: a save load fires this notify once per
  -- streamed-in animal, and forty queued 2.5s checks all answer the same question. One pending
  -- check is enough -- the body re-reads the world when it runs.
  local seenPawn = nil
  local pending = false
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    if pending then return end
    pending = true
    defer(2500, function()
      pending = false
      onGameThread(function()
        -- the PLAYER's pawn: a main-menu Character latching seenPawn would mean the button never
        -- gets injected into the world that actually has a pause menu worth saving from
        local pawn = ctx.uehelp.playerPawn(ctx.map.pawn and ctx.map.pawn.class)
        local fn; if pawn then pcall(function() fn = pawn:GetFullName() end) end
        if not fn or fn == seenPawn then return end
        seenPawn = fn
        apply()
      end)
    end)
  end)
  -- hot reload mid-session: the world may already be up
  defer(2000, function() onGameThread(apply) end)
  defer(12000, function() onGameThread(apply) end)

  ctx.log.info("manual_save: pause-menu save armed (host only; " ..
    tostring(cfg("save_button_cooldown", 10.0)) .. "s cooldown, refused while a save is running)")
  return true
end

return F
