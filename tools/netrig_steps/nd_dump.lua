-- Dump the engine's live NetDriverDefinitions array.
local e = FindFirstOf("GameEngine")
if not (e and e:IsValid()) then emit("no GameEngine") return end
local ok, arr = pcall(function() return e.NetDriverDefinitions end)
if not ok or not arr then emit("no NetDriverDefinitions prop: " .. tostring(arr)) return end
local n = 0
pcall(function() n = #arr end)
emit("count=" .. tostring(n))
for i = 1, n do
  local okd = pcall(function()
    local d = arr[i]
    emit(i .. ": def=" .. d.DefName:ToString()
      .. " cls=" .. d.DriverClassName:ToString()
      .. " fb=" .. d.DriverClassNameFallback:ToString())
  end)
  if not okd then emit(i .. ": (read failed)") end
end
