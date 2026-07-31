-- HOST: run the mod's own ship-chest ensure service (same path the park hook takes).
if not (ctx.services and ctx.services.shipChestEnsure) then emit("no service") return end
ctx.services.shipChestEnsure("netrig")
emit("shipChestEnsure requested")
