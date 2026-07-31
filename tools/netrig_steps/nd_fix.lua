-- Point the GameNetDriver definition at plain IpNetDriver (runtime, this session only).
local IP = "/Script/OnlineSubsystemUtils.IpNetDriver"
local e = FindFirstOf("GameEngine")
if not (e and e:IsValid()) then emit("no GameEngine") return end
local arr = e.NetDriverDefinitions
local n = #arr
for i = 1, n do
  local d = arr[i]
  local ok, name = pcall(function() return d.DefName:ToString() end)
  if ok and name == "GameNetDriver" then
    local fn
    local okf, errf = pcall(function() fn = FName(IP, FNAME_Add) end)
    if not okf or not fn then pcall(function() fn = FName(IP) end) end
    if not fn then emit("could not make FName (" .. tostring(errf) .. ")") return end
    local okw, err = pcall(function()
      d.DriverClassName = fn
      d.DriverClassNameFallback = fn
    end)
    emit("write ok=" .. tostring(okw) .. " err=" .. tostring(err))
  end
end
for i = 1, n do
  pcall(function()
    local d = arr[i]
    emit(i .. ": def=" .. d.DefName:ToString() .. " cls=" .. d.DriverClassName:ToString())
  end)
end
