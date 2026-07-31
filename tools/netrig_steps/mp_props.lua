-- Ship + carried-prop state on this machine (run on host AND client, compare).
local function nameOf(a) local n; pcall(function() n = a:GetFullName() end); return n or "?" end
local function fmt(v) return v and (math.floor(v.X) .. "," .. math.floor(v.Y) .. "," .. math.floor(v.Z)) or "?" end
for _, s in ipairs(ctx.uehelp.findAll("BP_Airship_C")) do
  if ctx.uehelp.isValid(s) and not nameOf(s):find("Default__", 1, true) then
    local hull, aloc
    pcall(function() hull = ctx.uehelp.vec(s.Root:K2_GetComponentLocation()) end)
    pcall(function() aloc = ctx.uehelp.vec(s:K2_GetActorLocation()) end)
    emit("SHIP " .. nameOf(s))
    emit("  hull=" .. fmt(hull) .. " actor=" .. fmt(aloc))
  end
end
for _, cls in ipairs({ "BP_Deco_Bench_Curved_Buildable_C", "BP_Chest_Buildable_C" }) do
  for _, a in ipairs(ctx.uehelp.findAll(cls)) do
    if ctx.uehelp.isValid(a) then
      local n = nameOf(a)
      if not n:find("Default__", 1, true) then
        local rm; pcall(function() rm = a.bReplicateMovement end)
        local par
        pcall(function()
          local p = a:GetAttachParentActor()
          if p and p:IsValid() then par = p:GetFullName() end
        end)
        -- regular chests are everywhere; only show ours (attached or repMove-off)
        if cls ~= "BP_Chest_Buildable_C" or par or rm == false then
          local loc; pcall(function() loc = ctx.uehelp.vec(a:K2_GetActorLocation()) end)
          emit(cls .. " " .. n)
          emit("  repMove=" .. tostring(rm) .. " loc=" .. fmt(loc))
          emit("  parent=" .. tostring(par))
        end
      end
    end
  end
end
