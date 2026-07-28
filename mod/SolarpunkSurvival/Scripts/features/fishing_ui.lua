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
  missTrack = { 0.55, 0.08, 0.08, 0.95 },
  missMark = { 1.00, 0.60, 0.60, 1.00 },
  timeoutTrack = { 0.30, 0.30, 0.32, 0.90 },
}
local MARK_W, GLOW_W = 4, 12

local VIS_SHOWN, VIS_HIDDEN = 4, 1 -- SelfHitTestInvisible / Collapsed (the qol-proven pair)

local mode = nil    -- nil = unprobed this world; "own" | "group" | "flat" | false = give up
local shell = {}    -- own: { w, cv }  group: { cv }  flat: {}
local parts = nil   -- built bar widgets, reverse-fold order; nil = no bar up
local mark = nil    -- { group } (own/group) or { glow, line, glowSlot, lineSlot } (flat)
local geom = nil    -- cached at show: { x, y, w, h }
local slotFallback = false -- SetRenderTranslation died once -> per-frame slot:SetPosition
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
  parts, mark, geom = nil, nil, nil
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
  parts, mark, geom = nil, nil, nil
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
  add(X, Y, W, H, LOOK.track, 61)
  add(X, Y, W, math.floor(H * 0.35), LOOK.sheen, 62)
  add(X + (c - zw / 2) * W - 5, Y - 2, zw * W + 10, H + 4, LOOK.zoneGlow[tone], 63)
  add(X + (c - zw / 2) * W, Y, zw * W, H, LOOK.zoneCore[tone], 64)
  add(X + (c - 0.2 * zw) * W, Y + math.floor(H * 0.22), 0.4 * zw * W, math.floor(H * 0.56), LOOK.zoneHot[tone], 65)

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
  geom = { x = X, y = Y, w = W, h = H }
  statsBuf = {}
  shellVisible(true)
  return true
end

-- PER-FRAME (animator hop). Returns false when the bar's widgets died under us.
function F.setMarker(p)
  local g, m = geom, mark
  if not (g and m) then return false end
  local tx = p * (g.w - MARK_W)
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
  if not parts then return end
  local function tint(w, c)
    if valid(w) then pcall(function() w:SetColorAndOpacity({ R = c[1], G = c[2], B = c[3], A = c[4] }) end) end
  end
  if kind == "hit" then
    tint(parts[5], LOOK.hitZone)
    tint(parts[6], LOOK.hitZone)
  elseif kind == "miss" then
    tint(parts[2], LOOK.missTrack)
    if mark then tint(mark.line, LOOK.missMark) end
  elseif kind == "timeout" then
    tint(parts[2], LOOK.timeoutTrack)
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
