-- Storm Repair Tool: a new craftable cloned from the game's existing ship-repair item, made
-- cheaper, registered into the unlock system. Using it on a smoking structure clears the damaged
-- state (health.repair). Also the mod's first "add a new craftable" — reused later for turrets/weapons.
local F = {}
local ctx

function F.init(c)
  ctx = c
  if ctx.gate.require(ctx.log, ctx.map, "repair_tool:register",
        { "craft.repairItemId", "craft.addRecipeFn", "unlock.registerFn" }) then
    F.register()
  end
  -- Exposed for the (future) use-action hook to call once the repair item's use is mapped.
  ctx.services.repairStructure = function(actor) return F.repair(actor) end

  -- Until the repair item's use-action is hooked: `sps_repair` fixes the nearest broken
  -- (smoking) structure within 6 m of the player. Host-only, like all repairs.
  pcall(function()
    RegisterConsoleCommandHandler("sps_repair", function()
      if ExecuteInGameThread then pcall(ExecuteInGameThread, function() F.repairNearest() end)
      else F.repairNearest() end
      return true
    end)
  end)
  return true
end

function F.repairNearest()
  if not ctx.net.isHost() then ctx.log.warn("repair: host only"); return end
  local pawn = ctx.uehelp.localPawn()
  local ploc = pawn and ctx.identity.locationOf(pawn)
  if not ploc then return end
  local best, bestD = nil, 600 * 600
  for id, rec in pairs(ctx.health.byId) do
    if rec.damaged and not rec.destroyed and ctx.uehelp.isValid(rec.actor) then
      local al = ctx.identity.locationOf(rec.actor)
      if al then
        local d = ctx.uehelp.dist2(al, ploc)
        if d <= bestD then best, bestD = id, d end
      end
    end
  end
  if best and F.repair(ctx.health.byId[best].actor) then
    ctx.log.info("repaired -- the smoking stops")
  else
    ctx.log.info("nothing broken within reach")
  end
end

function F.register()
  -- TODO(RE): clone the recipe of craft.repairItemId, scale its cost down, register the new item
  -- via craft.addRecipeFn, and gate it behind unlock.registerFn.
  ctx.log.info("repair_tool: register stub (clone-cheaper-repair-item pending RE)")
end

function F.repair(actor)
  if not ctx.net.isHost() then return false end
  local id = ctx.identity.idOf(actor)
  if not id then return false end
  local ok = ctx.health.repair(id)
  if ok then ctx.net.multicast("Multicast_Repaired", { id = id }) end
  return ok
end

return F
