-- Crouch the LOCAL player's pawn (client-side input path).
local p = ctx.uehelp.ownPawn()
if not p then emit("no own pawn") return end
local ok, err = pcall(function() p:Crouch(false) end)
emit("crouch call ok=" .. tostring(ok) .. " err=" .. tostring(err))
local c; pcall(function() c = p.bIsCrouched end)
emit("local bIsCrouched=" .. tostring(c))
