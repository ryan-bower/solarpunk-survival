-- Player + airship strike effects. Players have no vanilla health, so the framework owns it.
-- Player strike = 70% max HP (two hits lethal); death -> respawn at base + drop carried items.
-- Airship strike (flying) = -1/3 HP; crashes at 0 (occupants take fall damage).
local F = {}
local ctx

function F.init(c)
  ctx = c
  ctx.bus.on("strike.player",  function(e) F.onStrikePlayer(e) end)
  ctx.bus.on("strike.airship", function(e) F.onStrikeAirship(e) end)

  if ctx.map.pawn and ctx.map.pawn.class then
    pcall(NotifyOnNewObject, ctx.map.pawn.class, ctx.log.guard("pawn.new", function(o) F.onNewPawn(o) end))
    for _, p in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do F.onNewPawn(p) end
  else
    ctx.gate.require(ctx.log, ctx.map, "player_effects", { "pawn.class" })
  end

  if ctx.map.airship and ctx.map.airship.class then
    pcall(NotifyOnNewObject, ctx.map.airship.class, ctx.log.guard("airship.new", function(o)
      ctx.health.attach(o, { max = ctx.config.get("airship_max_hp"), kind = "airship" })
    end))
    for _, a in ipairs(ctx.uehelp.findAll(ctx.map.airship.class)) do
      ctx.health.attach(a, { max = ctx.config.get("airship_max_hp"), kind = "airship" })
    end
  end
  return true
end

function F.onNewPawn(pawn)
  if not ctx.net.isHost() then return end
  ctx.health.attach(pawn, { max = ctx.config.get("player_max_hp"), kind = "player" })
end

function F.onStrikePlayer(e)
  if not ctx.net.isHost() or not e.id then return end
  local dmg = ctx.config.get("player_max_hp") * ctx.config.get("player_strike_pct")
  local rec = ctx.health.applyDamage(e.id, dmg, { source = "lightning" })
  ctx.net.multicast("Multicast_PlayerHit", { id = e.id })
  if rec and rec.destroyed then F.onPlayerDeath(e.actor, e.id) end
end

function F.onPlayerDeath(actor, id)
  ctx.bus.emit("player.died", { actor = actor, id = id })
  local p, u = ctx.map.pawn, ctx.uehelp
  if p and p.dropInventoryFn then u.call(actor, p.dropInventoryFn) end  -- drop carried items
  if p and p.respawnFn then u.call(actor, p.respawnFn) end              -- respawn at base
  local rec = ctx.health.get(id)                                        -- reset for the respawned pawn
  if rec then rec.destroyed = false; rec.current = rec.max end
  ctx.log.info("player killed by lightning -> items dropped, respawn at base")
end

function F.onStrikeAirship(e)
  if not ctx.net.isHost() or not e.id then return end
  local rec = ctx.health.get(e.id)
  local max = (rec and rec.max) or ctx.config.get("airship_max_hp")
  local dmg = max * ctx.config.get("airship_strike_frac")   -- ~1/3 per strike -> 3 hits
  local rec2 = ctx.health.applyDamage(e.id, dmg, { source = "lightning" })
  if rec2 and rec2.destroyed then F.crashAirship(e.actor, e.id) end
end

function F.crashAirship(actor, id)
  local a, u = ctx.map.airship, ctx.uehelp
  if a and a.crashFn then u.call(actor, a.crashFn) end       -- forced descent
  ctx.net.multicast("Multicast_AirshipCrash", { id = id })
  -- TODO(RE): enumerate occupants and apply config.airship_fall_damage to each.
  ctx.log.info("airship crashed at 0 HP mid-flight")
end

return F
