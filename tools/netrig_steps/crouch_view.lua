-- Every player pawn's crouch state as THIS machine sees it.
local cls = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
local own = ctx.uehelp.ownPawn and ctx.uehelp.ownPawn() or nil
for _, p in ipairs(ctx.uehelp.findAll(cls)) do
  if ctx.uehelp.isValid(p) then
    local n = "?"; pcall(function() n = p:GetFullName() end)
    if not n:find("Default__", 1, true) then
      local crouched; pcall(function() crouched = p.bIsCrouched end)
      local can; pcall(function() can = p.CharacterMovement.NavAgentProps.bCanCrouch end)
      local tag = ctx.uehelp.sameObject(p, own) and "OWN" or "REMOTE"
      emit(tag .. " " .. n)
      emit("  bIsCrouched=" .. tostring(crouched) .. " bCanCrouch=" .. tostring(can))
    end
  end
end
