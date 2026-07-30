-- The skillshot bar's renderer -- everything the player SEES; features/fishing.lua keeps the
-- rules. Split out so the game logic never touches a widget and the renderer never judges.
--
-- Surface: our OWN viewport widget, not the game's overlay. A bare /Script/UMG.UserWidget from
-- WidgetBlueprintLibrary:Create with a raw CanvasPanel as its WidgetTree.RootWidget, parked in
-- the viewport per world and shown/hidden per bar (probed live 2026-07-28: create, root assign,
-- AddToViewport, raw Images, SetRenderTranslation and a nested canvas group all work on build
-- 24038177). Falling ladder when a step dies on a future build, each rung under its own
-- log.risky poison tag: "own" -> "group" (raw CanvasPanel on the overlay root) -> "flat"
-- (images straight onto the overlay root -- the original shipped surface).
--
-- The bar is a stack of flat-tinted Images (no textures, no materials -- the material-parameter
-- family is FATAL on this build, mapping.lua). Layered rects fake the depth: frame behind track,
-- a translucent top sheen, a soft zone glow under the zone core + hot center, and the marker as
-- a bright line inside a wide translucent glow. The marker pair lives in a nested canvas group,
-- so each frame moves ONE widget via SetRenderTranslation (a render-transform: no layout pass,
-- and the proven cheap call -- qol's hotbar slide uses it).
--
-- setMarker is the per-frame hot path (core/animator hop): no allocations, no log.guard, no
-- config reads -- geometry is cached at show(). It appends one os.clock() per draw to a stats
-- buffer; fishing.lua logs UI.stats() when the bar folds (the cadence proof, debug level).
local F = {}

local ctx

-- All look-and-feel in one place (flat RGBA; tune here, geometry via fishing_bar_* config).
local LOOK = {
  frame    = { 0.02, 0.02, 0.03, 0.88 },
  track    = { 0.10, 0.13, 0.18, 0.94 },
  sheen    = { 1.00, 1.00, 1.00, 0.05 },
  zoneGlow = { gold = { 1.00, 0.78, 0.10, 0.30 }, ice = { 0.55, 0.85, 1.00, 0.30 } },
  zoneCore = { gold = { 1.00, 0.72, 0.10, 0.96 }, ice = { 0.55, 0.85, 1.00, 0.96 } },
  zoneHot  = { gold = { 1.00, 0.90, 0.45, 0.95 }, ice = { 0.85, 0.97, 1.00, 0.95 } },
  markGlow = { 1.00, 1.00, 1.00, 0.22 },
  markLine = { 1.00, 1.00, 1.00, 1.00 },
  -- resolve flashes (recolors only; the bar folds fishing_flash_secs later)
  hitZone  = { 1.00, 1.00, 0.92, 1.00 },
  hitTrack = { 0.08, 0.52, 0.16, 0.95 },
  hitMark  = { 0.72, 1.00, 0.78, 1.00 },
  missTrack = { 0.55, 0.08, 0.08, 0.95 },
  missMark = { 1.00, 0.60, 0.60, 1.00 },
  timeoutTrack = { 0.30, 0.30, 0.32, 0.90 },
  -- the spinner wheel (dial-shaped; red rim = lose, gold/ice arc = win)
  rimTick  = { 0.82, 0.16, 0.12, 0.85 },
  hub      = { 1.00, 1.00, 1.00, 0.90 },
}
local MARK_W, GLOW_W = 4, 12
local RIM_STEP, ZONE_STEP, GLOW_STEP = 15, 2, 4 -- wheel tick spacing, degrees (zone ticks
-- overlap at radius 90 -- 2deg is ~3px of arc vs a 6px tick -- so the wedge reads solid)

local VIS_SHOWN, VIS_HIDDEN = 4, 1 -- SelfHitTestInvisible / Collapsed (the qol-proven pair)

local mode = nil    -- nil = unprobed this world; "own" | "group" | "flat" | false = give up
local shell = {}    -- own: { w, cv }  group: { cv }  flat: {}
local parts = nil   -- built widgets (bar OR wheel OR vsync), reverse-fold order; nil = nothing up
local mark = nil    -- bar: marker refs; wheel: { group = needle canvas, line }; vsync: below
local refs = nil    -- named flash targets: {kind="bar",...} | {kind="wheel",...} | {kind="vsync",...}
local geom = nil    -- bar only, cached at show: { x, y, w, h }
local geomV = nil   -- vsync only, cached at showVsync: { ty, len, w, span, slideHit, slideMiss }
local slotFallback = false -- SetRenderTranslation died once -> per-frame slot:SetPosition
local wheelBroken = false  -- SetRenderTransformAngle failed on raw widgets -> bar-only session
local vsyncBroken = false  -- SetRenderScale failed on raw widgets -> no gap-sync this session
local statsBuf = {}

local function cfgn(k, d) return tonumber(ctx.config.get(k)) or d end
local function valid(o) return ctx.uehelp.isValid(o) end

local function imageClass()
  local c = StaticFindObject and StaticFindObject(ctx.map.fishing.imagePath)
  return valid(c) and c or nil
end

local function overlayCanvas()
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not valid(pc) then return nil end
  local overlay
  pcall(function() overlay = pc[(ctx.map.qol and ctx.map.qol.overlayProp) or "PlayerOverlay"] end)
  if not valid(overlay) then return nil end
  local root
  pcall(function() root = overlay.WidgetTree.RootWidget end)
  if not valid(root) then return nil end
  return root, overlay
end

-- outer = the object the Image is constructed under (its GC owner until slotted into the tree)
local function makeImage(canvas, outer, x, y, w, h, color, z)
  local imgCls = imageClass()
  if not imgCls then return nil end
  local m = ctx.map.fishing
  local img, slot
  local ok = pcall(function()
    img = StaticConstructObject(imgCls, outer)
    slot = canvas[m.canvasAddFn](canvas, img)
    slot:SetPosition({ X = x, Y = y })
    slot:SetSize({ X = w, Y = h })
    slot:SetZOrder(z or 60)
    img:SetColorAndOpacity({ R = color[1], G = color[2], B = color[3], A = color[4] })
    img:SetVisibility(VIS_SHOWN)
  end)
  if not (ok and valid(img)) then
    if img then pcall(function() img:RemoveFromParent() end) end
    return nil
  end
  return img, slot
end

--------------------------------------------------------------------- shells
local function buildShellOwn()
  local m = ctx.map.fishing
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not valid(pc) then return nil end
  local wbl = StaticFindObject and StaticFindObject(m.wblPath)
  local uwCls = StaticFindObject and StaticFindObject(m.userWidgetPath)
  local cvCls = StaticFindObject and StaticFindObject(m.canvasPanelPath)
  if not (valid(wbl) and valid(uwCls) and valid(cvCls)) then return nil end
  local w, cv
  local okC = select(1, ctx.log.risky("fishingui.create", function() w = wbl:Create(pc, uwCls, pc) end))
  if not (okC and valid(w)) then return nil end
  local okR = select(1, ctx.log.risky("fishingui.root", function()
    local wt = w.WidgetTree
    cv = StaticConstructObject(cvCls, wt)
    wt.RootWidget = cv
  end))
  if not (okR and valid(cv)) then return nil end
  -- root BEFORE the first AddToViewport: TakeWidget builds the Slate tree then
  local okV = select(1, ctx.log.risky("fishingui.viewport", function()
    w:AddToViewport(60)
    w:SetVisibility(VIS_HIDDEN)
  end))
  if not okV then
    pcall(function() w:RemoveFromParent() end)
    return nil
  end
  return { w = w, cv = cv }
end

local function buildShellGroup()
  local m = ctx.map.fishing
  local root, overlay = overlayCanvas()
  if not root then return nil end
  local cvCls = StaticFindObject and StaticFindObject(m.canvasPanelPath)
  if not valid(cvCls) then return nil end
  local cv
  local ok = select(1, ctx.log.risky("fishingui.group", function()
    cv = StaticConstructObject(cvCls, overlay)
    local slot = root[m.canvasAddFn](root, cv)
    slot:SetPosition({ X = 0, Y = 0 })
    slot:SetSize({ X = 1920, Y = 1080 })
    slot:SetZOrder(59)
    cv:SetVisibility(VIS_HIDDEN)
  end))
  if not (ok and valid(cv)) then
    if cv then pcall(function() cv:RemoveFromParent() end) end
    return nil
  end
  return { cv = cv }
end

local function probeFlat()
  local root, overlay = overlayCanvas()
  if not root then return nil end
  local img = makeImage(root, overlay, 0, 0, 2, 2, { 0, 0, 0, 0 }, 1)
  if not img then return nil end
  pcall(function() img:RemoveFromParent() end)
  return {}
end

-- Decide + build the surface for this world. Game thread. Returns true when a surface is ready,
-- false when every rung failed for good, nil for "no world yet -- ask again later".
function F.probe()
  if mode == false then return false end
  if mode and F.ensureShell() then return true end
  local pc = ctx.uehelp.localController(ctx.map.player and ctx.map.player.controllerClass)
  if not valid(pc) then return nil end -- menu / early: re-probed by the next world pass
  if ctx.config.get("fishing_ui_own_widget") then
    local s = buildShellOwn()
    if s then
      mode, shell = "own", s
      ctx.log.debug("fishing_ui: own viewport widget shell ready")
      return true
    end
  end
  local s = buildShellGroup()
  if s then
    mode, shell = "group", s
    ctx.log.info("fishing_ui: own-widget shell unavailable -- overlay group fallback")
    return true
  end
  local flat = probeFlat()
  if flat then
    mode, shell = "flat", flat
    ctx.log.info("fishing_ui: canvas construction unavailable -- flat overlay images fallback")
    return true
  end
  if overlayCanvas() == nil then return nil end -- overlay not streamed in yet: not a verdict
  mode = false
  ctx.log.warn("fishing_ui: no widget surface works on this build -- skillshot disabled")
  return false
end

-- Revalidate the parked shell (widgets die on world unload); lazily rebuild for the known mode.
function F.ensureShell()
  if mode == "own" then
    if valid(shell.w) and valid(shell.cv) then return shell.cv, shell.w end
    shell = buildShellOwn() or {}
    return shell.cv, shell.w
  elseif mode == "group" then
    if valid(shell.cv) then return shell.cv, shell.cv end
    shell = buildShellGroup() or {}
    return shell.cv, shell.cv
  elseif mode == "flat" then
    return overlayCanvas()
  end
  return nil
end

-- World changed: every widget ref is dead. The mode survives (it is a build fact, not world state).
function F.reset()
  parts, mark, geom, geomV = nil, nil, nil, nil
  shell = {}
  statsBuf = {}
end

--------------------------------------------------------------------- the bar
local function shellVisible(on)
  if mode == "own" and valid(shell.w) then
    pcall(function() shell.w:SetVisibility(on and VIS_SHOWN or VIS_HIDDEN) end)
  elseif mode == "group" and valid(shell.cv) then
    pcall(function() shell.cv:SetVisibility(on and VIS_SHOWN or VIS_HIDDEN) end)
  end
end

function F.fold()
  if parts then
    for i = #parts, 1, -1 do
      pcall(function() parts[i]:RemoveFromParent() end)
    end
  end
  parts, mark, refs, geom, geomV = nil, nil, nil, nil, nil
  shellVisible(false)
end

-- opts: { diamond = bool, center = 0..1, width = 0..1 }
function F.show(opts)
  F.fold()
  local canvas, outer = F.ensureShell()
  if not canvas then return false end
  local X, Y = cfgn("fishing_bar_x", 750), cfgn("fishing_bar_y", 700)
  local W, H = cfgn("fishing_bar_w", 420), cfgn("fishing_bar_h", 26)
  local c, zw = opts.center or 0.5, opts.width or 0.18
  local tone = opts.diamond and "ice" or "gold"
  local built, ok = {}, true
  local function add(x, y, w, h, color, z)
    local img = makeImage(canvas, outer, x, y, w, h, color, z)
    if img then built[#built + 1] = img else ok = false end
    return img
  end
  add(X - 3, Y - 3, W + 6, H + 6, LOOK.frame, 60)
  local track = add(X, Y, W, H, LOOK.track, 61)
  add(X, Y, W, math.floor(H * 0.35), LOOK.sheen, 62)
  -- glow bleeds only VERTICALLY: sideways feathering read as "in the zone" but judged out
  add(X + (c - zw / 2) * W, Y - 2, zw * W, H + 4, LOOK.zoneGlow[tone], 63)
  local zoneCore = add(X + (c - zw / 2) * W, Y, zw * W, H, LOOK.zoneCore[tone], 64)
  local zoneHot = add(X + (c - 0.2 * zw) * W, Y + math.floor(H * 0.22), 0.4 * zw * W, math.floor(H * 0.56), LOOK.zoneHot[tone], 65)

  -- the marker: one nested canvas group when the surface can nest, two loose images when not
  mark = nil
  if ok and mode ~= "flat" then
    local m = ctx.map.fishing
    local cvCls = StaticFindObject and StaticFindObject(m.canvasPanelPath)
    if valid(cvCls) then
      local g, gslot
      local okG = pcall(function()
        g = StaticConstructObject(cvCls, outer)
        gslot = canvas[m.canvasAddFn](canvas, g)
        gslot:SetPosition({ X = X - 4, Y = Y - 5 })
        gslot:SetSize({ X = GLOW_W, Y = H + 10 })
        gslot:SetZOrder(66)
        g:SetVisibility(VIS_SHOWN)
      end)
      if okG and valid(g) then
        built[#built + 1] = g
        local glow = makeImage(g, outer, 0, 1, GLOW_W, H + 8, LOOK.markGlow, 1)
        local line = makeImage(g, outer, 4, 0, MARK_W, H + 10, LOOK.markLine, 2)
        if glow and line then
          built[#built + 1] = glow
          built[#built + 1] = line
          mark = { group = g, groupSlot = gslot, line = line }
        else ok = false end
      else ok = false end
    else ok = false end
  elseif ok then
    local glow, glowSlot = makeImage(canvas, outer, X - 4, Y - 4, GLOW_W, H + 8, LOOK.markGlow, 66)
    local line, lineSlot = makeImage(canvas, outer, X, Y - 5, MARK_W, H + 10, LOOK.markLine, 67)
    if glow and line then
      built[#built + 1] = glow
      built[#built + 1] = line
      mark = { glow = glow, line = line, glowSlot = glowSlot, lineSlot = lineSlot }
    else ok = false end
  end

  parts = built
  if not (ok and mark) then
    F.fold()
    return false
  end
  refs = { kind = "bar", track = track, zoneCore = zoneCore, zoneHot = zoneHot, line = mark.line }
  geom = { x = X, y = Y, w = W, h = H }
  statsBuf = {}
  shellVisible(true)
  return true
end

--------------------------------------------------------------------- the wheel
-- The spinner: a dial of radial tick rects (statics, each rotated once at build) with the zone
-- as a denser arc of gold/ice ticks, and the needle = line+glow inside a nested canvas group
-- rotated about its own center per frame (RenderTransformPivot defaults to 0.5,0.5). Rotation
-- rides UWidget:SetRenderTransformAngle -- proven on game widgets (savemenu matchFlip); its
-- first-ever call on OUR raw widgets sits under a poison latch, and a failure latches
-- wheelBroken so the session falls back to bar-only skillshots.
-- opts: { diamond = bool, centerDeg = 0..360, widthDeg = degrees }
function F.showWheel(opts)
  F.fold()
  if wheelBroken then return false end
  local canvas, outer = F.ensureShell()
  if not canvas then return false end
  if mode == "flat" then return false end -- no nested groups on the flat surface: bar-only
  local CX, CY = cfgn("fishing_wheel_x", 960), cfgn("fishing_wheel_y", 540)
  local R = cfgn("fishing_wheel_r", 90)
  local zc, zw = opts.centerDeg or 0, opts.widthDeg or 40
  local tone = opts.diamond and "ice" or "gold"
  local m = ctx.map.fishing
  local built, ok = {}, true
  local function add(x, y, w, h, color, z)
    local img = makeImage(canvas, outer, x, y, w, h, color, z)
    if img then built[#built + 1] = img else ok = false end
    return img
  end
  -- a tick whose CENTER sits at `rad` from the wheel center, rotated to lie radially
  local function tick(deg, rad, w, h, color, z)
    local rd = math.rad(deg)
    local img = add(CX + rad * math.sin(rd) - w / 2, CY - rad * math.cos(rd) - h / 2, w, h, color, z)
    if img and not pcall(function() img:SetRenderTransformAngle(deg) end) then
      ok = false
    end
    return img
  end
  local function inArc(deg, center, width)
    local d = ((deg - center + 540) % 360) - 180
    return math.abs(d) <= width / 2
  end

  -- the hub carries the FIRST rotation call, latched: if this build can't rotate raw widgets,
  -- one wheel dies cleanly and every later skillshot rolls the bar instead
  local hub
  local okHub = select(1, ctx.log.risky("fishingui.angle", function()
    hub = makeImage(canvas, outer, CX - 6, CY - 6, 12, 12, LOOK.hub, 68)
    if not hub then error("hub image failed") end
    hub:SetRenderTransformAngle(45.0)
  end))
  if not (okHub and hub) then
    if hub then pcall(function() hub:RemoveFromParent() end) end
    wheelBroken = true
    ctx.log.warn("fishing_ui: widget rotation unavailable -- wheel skillshot disabled (bar-only)")
    return false
  end
  built[#built + 1] = hub

  local rim = {}
  for deg = 0, 359, RIM_STEP do
    if not inArc(deg, zc, zw + 6) then -- the zone arc replaces the rim underneath it
      rim[#rim + 1] = tick(deg, R, 4, 14, LOOK.rimTick, 63)
    end
  end
  -- tick centers inset by half a step so the tick BODIES tile the wedge edge-to-edge --
  -- the drawn arc must match the judged arc (what looks in, IS in)
  local zone = {}
  local half = zw / 2
  for off = -half + GLOW_STEP / 2, half - GLOW_STEP / 2 + 0.001, GLOW_STEP do
    tick((zc + off) % 360, R, 10, 22, LOOK.zoneGlow[tone], 64)
  end
  for off = -half + ZONE_STEP / 2, half - ZONE_STEP / 2 + 0.001, ZONE_STEP do
    zone[#zone + 1] = tick((zc + off) % 360, R, 6, 18, LOOK.zoneCore[tone], 65)
  end
  if #zone == 0 then -- a config-narrowed arc below one tick step still needs to be visible
    zone[1] = tick(zc % 360, R, 6, 18, LOOK.zoneCore[tone], 65)
  end

  -- the needle: a 2R square group centered on the hub; line+glow point up from the center,
  -- one SetRenderTransformAngle on the group per frame sweeps them like a clock hand
  mark = nil
  local cvCls = StaticFindObject and StaticFindObject(m.canvasPanelPath)
  if ok and valid(cvCls) then
    local g
    local okG = pcall(function()
      g = StaticConstructObject(cvCls, outer)
      local gs = canvas[m.canvasAddFn](canvas, g)
      gs:SetPosition({ X = CX - R, Y = CY - R })
      gs:SetSize({ X = 2 * R, Y = 2 * R })
      gs:SetZOrder(66)
      g:SetVisibility(VIS_SHOWN)
    end)
    if okG and valid(g) then
      built[#built + 1] = g
      local glow = makeImage(g, outer, R - 5, R * 0.10, 10, R * 0.92, LOOK.markGlow, 1)
      local line = makeImage(g, outer, R - 2, R * 0.14, 4, R * 0.88, LOOK.markLine, 2)
      if glow and line then
        built[#built + 1] = glow
        built[#built + 1] = line
        mark = { group = g, line = line }
      else ok = false end
    else ok = false end
  else ok = false end

  parts = built
  if not (ok and mark) then
    F.fold()
    return false
  end
  refs = { kind = "wheel", rim = rim, zone = zone, line = mark.line, hub = hub }
  statsBuf = {}
  shellVisible(true)
  return true
end

-- PER-FRAME (animator hop): rotate the needle group to `deg`. False when the wheel died.
function F.setNeedle(deg)
  local mk = mark
  if not (mk and mk.group) then return false end
  if not valid(mk.group) then return false end
  local okR = pcall(function() mk.group:SetRenderTransformAngle(deg) end)
  if okR then statsBuf[#statsBuf + 1] = os.clock() end
  return okR
end

function F.wheelOK() return not wheelBroken end

--------------------------------------------------------------------- the gap-sync (vsync)
-- Two vertical lanes, each as long as the sliding bar. LEFT lane: invisible (user spec) -- only
-- a thin bright line rides it, GROWING while the player dithers. RIGHT lane: a visible track
-- carrying a rect-gap-rect trio. Each moving side is one nested canvas group (one render
-- transform per frame); the line's growth is the group's Y render SCALE, so drawn height =
-- lineH * scale exactly -- the very number the judge uses (the screenshot rule, geometrically).
-- SetRenderScale's first-ever call on our raw widgets sits under a poison latch like the
-- wheel's rotation: a failure folds this one game and latches vsyncBroken (bar clothes after).
-- opts: { diamond, lineH, rectH, gapH, len }
function F.showVsync(opts)
  F.fold()
  if vsyncBroken then return false end
  local canvas, outer = F.ensureShell()
  if not canvas then return false end
  if mode == "flat" then return false end -- needs nested groups: bar-only on the flat surface
  local m = ctx.map.fishing
  local W = cfgn("fishing_bar_h", 26)          -- lane width = the sliding bar's thickness
  local LEN = opts.len or cfgn("fishing_bar_w", 420)
  local LX = cfgn("fishing_vsync_x", 840)      -- left lane's left edge
  local RX = LX + cfgn("fishing_vsync_dx", 70)
  local TY = cfgn("fishing_vsync_y", 300)
  local lineH = opts.lineH or 3.6
  local rectH = opts.rectH or lineH * 10
  local gapH = opts.gapH or rectH
  local span = rectH * 2 + gapH
  local tone = opts.diamond and "ice" or "gold"
  local built, ok = {}, true
  local function add(x, y, w, h, color, z)
    local img = makeImage(canvas, outer, x, y, w, h, color, z)
    if img then built[#built + 1] = img else ok = false end
    return img
  end

  -- right lane: framed visible track (the left lane is deliberately naked)
  add(RX - 3, TY - 3, W + 6, LEN + 6, LOOK.frame, 60)
  local track = add(RX, TY, W, LEN, LOOK.track, 61)

  -- NOTE: no early `F.fold() return` past this point -- makeImage parents each image to the
  -- shell the moment it is built, but fold() only knows about `parts`, which is not published
  -- until the bottom. An early return therefore left the frame + track stranded on the HUD,
  -- one stray pair per failed roll. Everything below flows to `ok = false` and the one exit.
  local cvCls = StaticFindObject and StaticFindObject(m.canvasPanelPath)
  if not valid(cvCls) then ok = false end

  -- the right trio group: rect / glowing gap / rect, one translation per frame
  local rgroup, rect1, rect2, gapGlow
  local okR = ok and pcall(function()
    rgroup = StaticConstructObject(cvCls, outer)
    local gs = canvas[m.canvasAddFn](canvas, rgroup)
    gs:SetPosition({ X = RX, Y = TY })
    gs:SetSize({ X = W, Y = span })
    gs:SetZOrder(64)
    rgroup:SetVisibility(VIS_SHOWN)
  end)
  if okR and valid(rgroup) then
    built[#built + 1] = rgroup
    rect1 = makeImage(rgroup, outer, 0, 0, W, rectH, LOOK.zoneCore[tone], 1)
    gapGlow = makeImage(rgroup, outer, 0, rectH, W, gapH, LOOK.zoneGlow[tone], 1)
    rect2 = makeImage(rgroup, outer, 0, rectH + gapH, W, rectH, LOOK.zoneCore[tone], 1)
    if rect1 and gapGlow and rect2 then
      built[#built + 1] = rect1
      built[#built + 1] = gapGlow
      built[#built + 1] = rect2
    else ok = false end
  else ok = false end

  -- the left line group: glow + line; the group's Y scale IS the growth
  local vgroup, vline
  if ok then
    local okL = pcall(function()
      vgroup = StaticConstructObject(cvCls, outer)
      local gs = canvas[m.canvasAddFn](canvas, vgroup)
      gs:SetPosition({ X = LX - 4, Y = TY - lineH / 2 })
      gs:SetSize({ X = W + 8, Y = lineH })
      gs:SetZOrder(66)
      vgroup:SetVisibility(VIS_SHOWN)
    end)
    if okL and valid(vgroup) then
      built[#built + 1] = vgroup
      local glow = makeImage(vgroup, outer, 0, -2, W + 8, lineH + 4, LOOK.markGlow, 1)
      vline = makeImage(vgroup, outer, 4, 0, W, lineH, LOOK.markLine, 2)
      if glow and vline then
        built[#built + 1] = glow
        built[#built + 1] = vline
      else ok = false end
    else ok = false end
  end

  -- the poison-latched first scale call: a build that can't render-scale raw widgets loses
  -- this game cleanly and never rolls it again
  if ok then
    local okS = select(1, ctx.log.risky("fishingui.scale", function()
      vgroup:SetRenderScale({ X = 1.0, Y = 1.0 })
    end))
    if not okS then
      vsyncBroken = true
      ctx.log.warn("fishing_ui: widget scaling unavailable -- gap-sync skillshot disabled")
      ok = false
    end
  end

  parts = built
  if not ok then
    F.fold()
    return false
  end
  mark = { vgroup = vgroup, vline = vline, rgroup = rgroup, lastLY = 0 }
  refs = { kind = "vsync", track = track, rects = { rect1, rect2 }, gap = gapGlow, line = vline }
  geomV = { ty = TY, len = LEN, w = W, span = span,
            slideHit = RX - LX, slideMiss = RX - LX - W }
  statsBuf = {}
  shellVisible(true)
  return true
end

function F.vsyncOK() return not vsyncBroken end

-- PER-FRAME (animator hop): both lane translations + the line's growth scale. False on death.
function F.setVsync(pL, pR, scale)
  local g, mk = geomV, mark
  if not (g and mk and mk.vgroup) then return false end
  if not (valid(mk.vgroup) and valid(mk.rgroup)) then return false end
  local ly = pL * g.len
  local okD = pcall(function()
    mk.vgroup:SetRenderTranslation({ X = 0, Y = ly })
    mk.vgroup:SetRenderScale({ X = 1.0, Y = scale })
    mk.rgroup:SetRenderTranslation({ X = 0, Y = pR * (g.len - g.span) })
  end)
  if okD then
    mk.lastLY = ly
    statsBuf[#statsBuf + 1] = os.clock()
  end
  return okD
end

-- PER-FRAME during the reveal: slide the frozen line rightward. A hit runs the full distance
-- (flush into the gap); a miss stops with the line's nose against the trio's left face.
function F.vsyncSlide(frac, hit)
  local g, mk = geomV, mark
  if not (g and mk and mk.vgroup) then return false end
  if not valid(mk.vgroup) then return false end
  local fx = (frac or 0) * (hit and g.slideHit or g.slideMiss)
  local okD = pcall(function()
    mk.vgroup:SetRenderTranslation({ X = fx, Y = mk.lastLY })
  end)
  if okD then statsBuf[#statsBuf + 1] = os.clock() end
  return okD
end

-- PER-FRAME (animator hop). Returns false when the bar's widgets died under us.
function F.setMarker(p)
  local g, m = geom, mark
  if not (g and m) then return false end
  -- the line's CENTER sits at the judged pixel p*W (it straddles the track ends at 0 and 1)
  local tx = p * g.w - MARK_W / 2
  if m.group then
    if not valid(m.group) then return false end
    if not slotFallback then
      if pcall(function() m.group:SetRenderTranslation({ X = tx, Y = 0 }) end) then
        statsBuf[#statsBuf + 1] = os.clock()
        return true
      end
      slotFallback = true
    end
    local okS = pcall(function()
      m.groupSlot:SetPosition({ X = g.x - 4 + tx, Y = g.y - 5 })
    end)
    if okS then statsBuf[#statsBuf + 1] = os.clock() end
    return okS
  end
  if not (valid(m.glow) and valid(m.line)) then return false end
  local okF = pcall(function()
    m.glow:SetRenderTranslation({ X = tx, Y = 0 })
    m.line:SetRenderTranslation({ X = tx, Y = 0 })
  end)
  if okF then statsBuf[#statsBuf + 1] = os.clock() end
  return okF
end

-- kind: "hit" | "miss" | "timeout" -- recolors only; fishing.lua folds after fishing_flash_secs
function F.flash(kind)
  local r = refs
  if not r then return end
  local function tint(w, c)
    if valid(w) then pcall(function() w:SetColorAndOpacity({ R = c[1], G = c[2], B = c[3], A = c[4] }) end) end
  end
  local function tintAll(list, c)
    for _, w in ipairs(list or {}) do tint(w, c) end
  end
  if r.kind == "bar" then
    if kind == "hit" then -- green sweep, mirroring the red miss
      tint(r.track, LOOK.hitTrack)
      tint(r.zoneCore, LOOK.hitZone)
      tint(r.zoneHot, LOOK.hitZone)
      tint(r.line, LOOK.hitMark)
    elseif kind == "miss" then
      tint(r.track, LOOK.missTrack)
      tint(r.line, LOOK.missMark)
    elseif kind == "timeout" then
      tint(r.track, LOOK.timeoutTrack)
    end
  elseif r.kind == "vsync" then
    -- the RIGHT bar carries the verdict (user spec: it flashes green on a slot-in, red on a slam)
    if kind == "hit" then
      tint(r.track, LOOK.hitTrack)
      tintAll(r.rects, LOOK.hitZone)
      tint(r.gap, LOOK.hitZone)
      tint(r.line, LOOK.hitMark)
    elseif kind == "miss" then
      tint(r.track, LOOK.missTrack)
      tintAll(r.rects, LOOK.missTrack)
      tint(r.line, LOOK.missMark)
    elseif kind == "timeout" then
      tint(r.track, LOOK.timeoutTrack)
      tintAll(r.rects, LOOK.timeoutTrack)
    end
  else -- wheel
    if kind == "hit" then
      tintAll(r.rim, LOOK.hitTrack)
      tintAll(r.zone, LOOK.hitZone)
      tint(r.hub, LOOK.hitZone)
      tint(r.line, LOOK.hitMark)
    elseif kind == "miss" then
      tintAll(r.rim, LOOK.missTrack)
      tintAll(r.zone, LOOK.missTrack)
      tint(r.line, LOOK.missMark)
    elseif kind == "timeout" then
      tintAll(r.rim, LOOK.timeoutTrack)
      tintAll(r.zone, LOOK.timeoutTrack)
    end
  end
end

-- Frame-delta stats since show(), then clears. The smoothness proof without per-frame file I/O.
function F.stats()
  local n = #statsBuf
  if n < 2 then statsBuf = {}; return { n = n } end
  local ds = {}
  for i = 2, n do ds[#ds + 1] = (statsBuf[i] - statsBuf[i - 1]) * 1000 end
  table.sort(ds)
  local sum = 0
  for _, d in ipairs(ds) do sum = sum + d end
  local s = {
    n = n,
    min = ds[1],
    avg = sum / #ds,
    p95 = ds[math.max(1, math.floor(#ds * 0.95))],
    max = ds[#ds],
  }
  statsBuf = {}
  return s
end

function F.mode() return mode end

function F.init(c)
  ctx = c
  return true
end

return F
