-- Client travel to the host (instance 2 only).
local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
if not gs then emit("no GameplayStatics") return end
local pc = ctx.uehelp.playerController()
if not pc then emit("no player controller for world ctx") return end
local ok, err = pcall(function() gs:OpenLevel(pc, FName("127.0.0.1:7777"), true, "") end)
emit("openlevel ok=" .. tostring(ok) .. " err=" .. tostring(err))
