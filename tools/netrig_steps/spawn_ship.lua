-- HOST: spawn an airship near the player so the ship-prop carriage has a target.
local cls = ctx.uehelp.classByName("BP_Airship_C")
emit("cls=" .. tostring(cls))
if not cls then
  for _, path in ipairs({
    "/Game/Code/Airship/BP_Airship.BP_Airship_C",
    "/Game/Code/Airship/Framework/BP_Airship.BP_Airship_C",
    "/Game/Airship/BP_Airship.BP_Airship_C",
  }) do
    cls = ctx.uehelp.classByName("BP_Airship_C", path)
    emit("try " .. path .. " -> " .. tostring(cls))
    if cls then break end
  end
end
if not cls then emit("class unavailable") return end
local p = ctx.uehelp.ownPawn()
if not p then emit("no pawn") return end
local loc = ctx.uehelp.vec(p:K2_GetActorLocation())
loc.X = loc.X + 900
loc.Z = loc.Z + 400
local a = ctx.uehelp.spawnActorAt(p, cls, loc)
emit("spawned=" .. tostring(a))
if a then pcall(function() emit("shipFull=" .. a:GetFullName()) end) end
