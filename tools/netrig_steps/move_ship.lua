-- HOST: teleport the ship +500 X so replication carries it (and the attached props) on the client.
local s = ctx.uehelp.findFirst("BP_Airship_C")
if not s then emit("no ship") return end
local loc = ctx.uehelp.vec(s:K2_GetActorLocation())
loc.X = loc.X + 500
local ok, err = pcall(function() s:K2_SetActorLocation(loc, false, {}, true) end)
emit("moved ok=" .. tostring(ok) .. " err=" .. tostring(err))
local now = ctx.uehelp.vec(s:K2_GetActorLocation())
emit("host ship now " .. math.floor(now.X) .. "," .. math.floor(now.Y) .. "," .. math.floor(now.Z))
