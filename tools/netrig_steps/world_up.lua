-- Is the world loaded? Prints AActor: 0x... when the player pawn exists.
local cls = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
local p = ctx.uehelp.findFirst(cls)
emit("pawn=" .. tostring(p))
local pc = ctx.uehelp.playerController()
emit("pc=" .. tostring(pc))
emit("isHost=" .. tostring(ctx.net and ctx.net.isHost and ctx.net.isHost()))
