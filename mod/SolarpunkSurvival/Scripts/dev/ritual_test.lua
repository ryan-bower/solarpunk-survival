-- Dev: stage the dark-arts ritual test at the user's pre-built candle pentagram.
-- Gives the mundane wand + dark-arts book, teleports the player to the circle's edge and spawns
-- the sacrificial sheep at the center. Runs via `sps_ritual_test`, or AUTOMATICALLY on the next
-- world load when dump/ritual_test_pending.txt exists (the flag is consumed on success).
local F = {}
local ctx
local ranAuto = false

-- The center the user pinged to mark their pentagram (2026-07-21).
local CENTER = { X = 6506, Y = -1165, Z = -5221 }

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

local function flagPath() return (ctx.modRoot or "") .. "dump/ritual_test_pending.txt" end
local function flagSet() local f = io.open(flagPath(), "r"); if f then f:close(); return true end return false end

function F.stage()
  local pc = ctx.uehelp.findFirst(ctx.map.player and ctx.map.player.controllerClass)
  if not pc then ctx.log.warn("ritual_test: no controller (load a world first)"); return false end
  local pawn
  pcall(function() pawn = pc:K2_GetPawn() end)
  if not ctx.uehelp.isValid(pawn) then ctx.log.warn("ritual_test: no pawn yet"); return false end

  -- 1) the book of the rite (granted ONCE per install; the wand is NOT an item -- the ritual
  --    itself forges it, features/wand.lua)
  local rit = ctx.map.ritual
  local grantFlag = (ctx.modRoot or "") .. "dump/wand_granted.txt"
  local gf = io.open(grantFlag, "r")
  if gf then
    gf:close()
    ctx.log.info("ritual_test: book already granted (delete dump/wand_granted.txt to regrant)")
  else
    if not ctx.items.give(pc, rit.bookItemRow, 1) then
      ctx.log.warn("ritual_test: item class missing for " .. tostring(rit.bookItemRow))
    end
    local wf = io.open(grantFlag, "w")
    if wf then wf:write("granted\n"); wf:close() end
  end

  -- 2) to the circle's edge (~6 m out, facing the center)
  pcall(function()
    pawn:K2_TeleportTo({ X = CENTER.X + 600, Y = CENTER.Y, Z = CENTER.Z + 150 },
                       { Pitch = 0, Yaw = 180, Roll = 0 })
  end)

  -- 3) the offering
  local sheepCls = ctx.uehelp.classByName(ctx.map.animal and ctx.map.animal.sheepClass)
  local sheep = sheepCls and ctx.uehelp.spawnActorAt(pc, sheepCls,
    { X = CENTER.X, Y = CENTER.Y, Z = CENTER.Z + 80 })
  if not sheep then ctx.log.warn("ritual_test: could not spawn the sheep (class not loaded?)") end

  ctx.log.info("*** RITUAL STAGED *** sheep at the pentagram.")
  ctx.log.info("    Press H for a storm and stay within the circle -- the rite forges the wand. (docs/DARK-ARTS.md)")
  return true
end

function F.init(c)
  ctx = c
  pcall(function()
    RegisterConsoleCommandHandler("sps_ritual_test", function()
      onGameThread(function() F.stage() end)
      return true
    end)
  end)

  -- Auto-run once per pending flag: waits for a controller (world load), then a settling delay.
  if flagSet() then
    local function tryAuto()
      if ranAuto then return end
      pcall(ExecuteWithDelay, 8000, ctx.log.guard("ritual_test.auto", function()
        onGameThread(function()
          if ranAuto or not flagSet() then return end
          if F.stage() then
            ranAuto = true
            os.remove(flagPath())
          end
        end)
      end))
    end
    ctx.uehelp.onNewInstance("/Script/Engine.PlayerController",
      ctx.map.player and ctx.map.player.controllerClass,
      ctx.log.guard("ritual_test.newpc", tryAuto))
    if ctx.uehelp.findFirst(ctx.map.player and ctx.map.player.controllerClass) then tryAuto() end
    ctx.log.info("ritual_test: pending -- will stage automatically once you're in the world")
  end
  return true
end

return F
