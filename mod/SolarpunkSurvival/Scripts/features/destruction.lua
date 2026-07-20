-- Structure destruction + per-target strike effects for world objects:
-- build pieces (HP -> destroyed + partial salvage), machines (2-hit smoking -> destroyed),
-- crops (kill, no seed), batteries (full charge). Smoking reuses the game's ship-damage VFX.
local F = {}
local ctx

function F.init(c)
  ctx = c
  local map = ctx.map

  -- Attach health to build pieces (and machines with the 2-hit flag) as they appear.
  if map.build and map.build.pieceClass then
    pcall(NotifyOnNewObject, map.build.pieceClass, ctx.log.guard("build.new", function(o) F.onNewPiece(o, false) end))
    for _, a in ipairs(ctx.uehelp.findAll(map.build.pieceClass)) do F.onNewPiece(a, false) end
  else
    ctx.gate.require(ctx.log, ctx.map, "destruction", { "build.pieceClass" })
  end
  if map.machine and map.machine.classes then
    for _, cls in ipairs(map.machine.classes) do
      pcall(NotifyOnNewObject, cls, ctx.log.guard("machine.new", function(o) F.onNewPiece(o, true) end))
      for _, a in ipairs(ctx.uehelp.findAll(cls)) do F.onNewPiece(a, true) end
    end
  end

  -- Strike effects.
  ctx.bus.on("strike.structure", function(e) F.onStrikeStructure(e) end)
  ctx.bus.on("strike.machine",   function(e) F.onStrikeStructure(e) end)
  ctx.bus.on("strike.crop",      function(e) F.onStrikeCrop(e) end)
  ctx.bus.on("strike.battery",   function(e) F.onStrikeBattery(e) end)

  -- Reactions to health-state changes.
  ctx.bus.on("structure.damaged", function(e) F.showSmoke(e.rec) end)
  ctx.bus.on("entity.destroyed",  function(e) F.destroyStructure(e) end)
  return true
end

function F.onNewPiece(actor, isMachine)
  if not ctx.net.isHost() then return end
  local cfg = ctx.config
  ctx.health.attach(actor, {
    max    = cfg.get("structure_hp_base"),
    kind   = isMachine and "machine" or "structure",
    twoHit = isMachine and cfg.get("machine_two_hit") or false,
  })
end

function F.onStrikeStructure(e)
  if not e or not e.id then return end
  ctx.health.applyDamage(e.id, ctx.config.get("strike_structure_dmg"), { source = "lightning" })
end

function F.onStrikeCrop(e)
  if not ctx.net.isHost() or not ctx.uehelp.isValid(e.actor) then return end
  local map, u = ctx.map, ctx.uehelp
  if map.crop and map.crop.killNoSeedFn then
    u.call(e.actor, map.crop.killNoSeedFn)             -- kill without dropping a seed
  elseif map.build and map.build.demolishFn then
    u.call(e.actor, map.build.demolishFn)             -- fallback: plain removal
  else
    u.call(e.actor, "K2_DestroyActor")
  end
  ctx.net.multicast("Multicast_CropKilled", { id = e.id })
  ctx.log.debug("crop killed by lightning (no seed)")
end

function F.onStrikeBattery(e)
  if not ctx.net.isHost() or not ctx.uehelp.isValid(e.actor) then return end
  local map, u = ctx.map, ctx.uehelp
  if map.battery and map.battery.chargeProp then
    local maxc = 100
    if map.battery.maxChargeProp then
      local ok, v = u.get(e.actor, map.battery.maxChargeProp)
      if ok and type(v) == "number" then maxc = v end
    end
    u.set(e.actor, map.battery.chargeProp, maxc)       -- fully charge
    ctx.log.debug("battery fully charged by lightning")
  end
end

function F.showSmoke(rec)
  if not rec then return end
  local map, u = ctx.map, ctx.uehelp
  if map.smoke and map.smoke.shipDamageVfxFn and u.isValid(rec.actor) then
    u.call(rec.actor, map.smoke.shipDamageVfxFn)       -- reuse existing ship smoke VFX
  end
  ctx.net.multicast("Multicast_Smoke", { id = rec.id })
end

function F.destroyStructure(e)
  if not ctx.net.isHost() then return end
  local rec = e.rec
  if not rec or not ctx.uehelp.isValid(rec.actor) then return end
  local map, u = ctx.map, ctx.uehelp

  -- Prefer the vanilla demolish path (replicates cleanly; may refund materials = salvage).
  local demolished = false
  if map.build and map.build.demolishFn then
    demolished = select(1, u.call(rec.actor, map.build.demolishFn)) == true
  end
  if not demolished then
    u.call(rec.actor, "K2_DestroyActor")
    ctx.net.multicast("Multicast_Destroy", { id = rec.id })
  end
  -- Partial salvage: if the demolish path did NOT refund, spawn salvage_frac of the build cost.
  -- TODO(RE): needs build cost + item-spawn (craft tables) — see docs/REVERSE-ENGINEERING.md.
  ctx.health.forget(rec.id)
  ctx.log.debug(string.format("structure destroyed (salvage_frac=%.2f)", ctx.config.get("salvage_frac")))
end

return F
