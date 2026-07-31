-- What qol.applyHold does on a key press: ensure own pawn can crouch, then Crouch.
local p = ctx.uehelp.ownPawn()
if not p then emit("no own pawn") return end
local mv; pcall(function() mv = p.CharacterMovement end)
if mv then pcall(function() mv.NavAgentProps.bCanCrouch = true end) end
local can; pcall(function() can = mv.NavAgentProps.bCanCrouch end)
emit("own bCanCrouch now=" .. tostring(can))
local ok, err = pcall(function() p:Crouch(false) end)
emit("crouch call ok=" .. tostring(ok) .. " err=" .. tostring(err))
