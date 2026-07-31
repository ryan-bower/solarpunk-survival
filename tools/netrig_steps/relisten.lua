-- Re-travel with ?listen (same URL the Host flow used) so the NEW driver def takes.
local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
if not ksl then emit("no KSL") return end
local cls = (ctx.map.pawn and ctx.map.pawn.class) or "BP_MainPlayerCharacter_C"
local anchor = ctx.uehelp.findFirst(cls) or ctx.uehelp.playerController()
if not anchor then emit("no world anchor") return end
local ok, err = pcall(function()
  ksl:ExecuteConsoleCommand(anchor, "open /Game/Maps/MainLevel?Name=Player?listen", nil)
end)
emit("open?listen ok=" .. tostring(ok) .. " err=" .. tostring(err))
