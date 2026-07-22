-- Foundations snap free of the earth: when a foundation preview is SNAPPED to an existing
-- buildable, the game's own "all four corners must touch the ground" rule no longer vetoes the
-- placement. Free placement (not snapped) keeps the vanilla rule.
--
-- How (offline RE, 2026-07-22): BC_BuildSystem:ComplyFunctionalBuildRules? asks the current
-- preview's TestAdvancedBuildingRule(out CanBuild); each foundation preview's override
-- line-traces its four GroundCheck corner components down to the ground and fails on any miss.
-- BC_BuildSystem.IsSnapping is true exactly while the preview rides another buildable's snap
-- point (SnapTrace sets it from the hit component's snap tags). So: post-hook every foundation
-- override and, when the driving build system says IsSnapping, write CanBuild back to true.
--
-- Arming is two-stage, and deliberately avoids construction notifies on busy channels (a
-- 2026-07-22 world-entry fatal -- 60s game-thread hang -- bisected to bare-Actor notifies
-- added that day):
--   1. world entry (the proven Character notify the wand rides) hooks the build system's own
--      ComplyFunctionalBuildRules? -- BC_BuildSystem is a pawn component, so its class is
--      resident the moment a pawn exists;
--   2. that pre-hook arms the four preview-override hooks -- it only ever runs in build mode,
--      which is exactly when the preview classes are resident, and it degrades to four table
--      lookups once they all stuck.
-- MP: previews and their build systems are per-player local machinery; each machine bypasses
-- only its own snapped preview. Everything is pcall-guarded; nothing polls on a timer.
local F = {}
local ctx

local armedPaths = {}   -- preview path -> true once its RegisterHook stuck
local armedCount = 0
local gateHooked = false

local function fmap() return ctx.map.foundation or {} end

-- The build system driving this preview: normally the local player's only BC_BuildSystem, but
-- match on its BuildingPreview ref so a listen-server never reads another player's snap state.
local function buildSystemFor(preview)
  local m = fmap()
  local all = FindAllOf(m.buildSystemClass or "BC_BuildSystem_C") or {}
  local fallback
  for _, bs in ipairs(all) do
    local valid = false
    pcall(function() valid = bs:IsValid() end)
    if valid then
      fallback = fallback or bs
      local match = false
      pcall(function()
        match = ctx.uehelp.sameObject(bs[m.previewProp or "BuildingPreview"], preview)
      end)
      if match then return bs end
    end
  end
  return fallback
end

local function onRuleChecked(Context, canBuild)
  if not ctx.config.get("foundation_snap_ignore_ground") then return end
  local preview
  pcall(function() preview = Context:get() end)
  if not preview then return end
  local bs = buildSystemFor(preview)
  if not bs then return end
  local snapping = false
  pcall(function() snapping = bs[fmap().snapProp or "IsSnapping"] == true end)
  if snapping then pcall(function() canBuild:set(true) end) end
end

local function armHooks()
  local m = fmap()
  local paths = m.previewPaths or {}
  if armedCount >= #paths then return end
  local fn = m.ruleFn or "TestAdvancedBuildingRule"
  local newly = 0
  for _, path in ipairs(paths) do
    if not armedPaths[path] then
      local ok = pcall(RegisterHook, path .. ":" .. fn,
        function() end,  -- pre: nothing to do; the override must run and do its traces
        ctx.log.guard("foundation.rule", onRuleChecked))
      if ok then
        armedPaths[path] = true
        armedCount = armedCount + 1
        newly = newly + 1
      end
    end
  end
  if newly > 0 then
    ctx.log.info("foundation: snapped foundations ignore the ground rule (" ..
      newly .. " preview hook(s) armed)")
  end
end

-- Stage 1: hook the build-mode gate. Runs only while placing, i.e. exactly when preview
-- classes are resident; real arming work is deferred out of the BP call chain.
local function armGate()
  if gateHooked then return end
  local m = fmap()
  local path = (m.buildSystemPath or "") .. ":" .. (m.gateFn or "ComplyFunctionalBuildRules?")
  gateHooked = pcall(RegisterHook, path, ctx.log.guard("foundation.gate", function()
    if armedCount >= #(fmap().previewPaths or {}) then return end
    if not pcall(ExecuteWithDelay, 50, armHooks) then armHooks() end
  end))
  if gateHooked then
    ctx.log.info("foundation: build-mode gate armed (preview hooks follow on first placement)")
  end
end

function F.init(c)
  ctx = c
  if not ctx.gate.require(ctx.log, ctx.map, "foundation",
      { "foundation.previewPaths", "foundation.buildSystemPath" }) then
    return false
  end
  armGate()   -- classes may already be resident (hot reload mid-session)
  armHooks()
  -- world entry: the pawn (and so its BC_BuildSystem component class) now exists
  ctx.uehelp.onNewInstance("/Script/Engine.Character", nil, function()
    if not pcall(ExecuteWithDelay, 1500, armGate) then armGate() end
  end)
  return true
end

return F
