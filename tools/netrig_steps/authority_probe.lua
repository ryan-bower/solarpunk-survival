-- Ground truth: what does HasAuthority say right now, cache aside?
local pc = ctx.uehelp.playerController()
if not pc then emit("no pc") return end
emit("pcName=" .. tostring(pc:GetFullName()))
local ok, res = ctx.uehelp.call(pc, "HasAuthority")
emit("pc HasAuthority ok=" .. tostring(ok) .. " res=" .. tostring(res))
local cls = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
local p = ctx.uehelp.findFirst(cls)
if p then
  local ok2, r2 = ctx.uehelp.call(p, "HasAuthority")
  emit("pawn HasAuthority ok=" .. tostring(ok2) .. " res=" .. tostring(r2))
  local ok3, role = ctx.uehelp.get(p, "Role")
  emit("pawn Role=" .. tostring(role))
end
emit("cached isHost=" .. tostring(ctx.net.isHost()))
ctx.net.invalidate()
emit("fresh isHost=" .. tostring(ctx.net.isHost()))
