-- List the ingame (ESC) menu's bound-event trampolines + host/invite-ish functions.
local w = FindFirstOf("W_IngameMenu_C")
if not (w and w:IsValid()) then emit("no W_IngameMenu_C") return end
emit("widget=" .. w:GetFullName())
local cls = w:GetClass()
cls:ForEachFunction(function(fn)
  local ok, n = pcall(function() return fn:GetFName():ToString() end)
  if ok and n then
    local l = n:lower()
    if l:find("bndevt", 1, true) or l:find("host", 1, true) or l:find("invite", 1, true)
       or l:find("session", 1, true) or l:find("friend", 1, true) then
      emit(n)
    end
  end
end)
