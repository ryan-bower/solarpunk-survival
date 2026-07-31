-- What's here? Class instance counts + where the player is.
for _, cls in ipairs({ "BP_Airship_C", "BP_Deco_Bench_Curved_Buildable_C",
                       "BP_Chest_Buildable_C", "BP_SortingChest_Placeable_C",
                       "BP_MainPlayerCharacter_C" }) do
  local n = 0
  for _, a in ipairs(ctx.uehelp.findAll(cls)) do
    if ctx.uehelp.isValid(a) then
      local nm = "?"; pcall(function() nm = a:GetFullName() end)
      if not nm:find("Default__", 1, true) then n = n + 1 end
    end
  end
  emit(cls .. " count=" .. n)
end
local p = ctx.uehelp.ownPawn and ctx.uehelp.ownPawn()
if p then
  local loc; pcall(function() loc = ctx.uehelp.vec(p:K2_GetActorLocation()) end)
  if loc then emit("ownPawn at " .. math.floor(loc.X) .. "," .. math.floor(loc.Y) .. "," .. math.floor(loc.Z)) end
end
