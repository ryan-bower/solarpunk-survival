-- Press the ESC menu's Host button (opens the co-op session / listen server).
local w = FindFirstOf("W_IngameMenu_C")
if not (w and w:IsValid()) then emit("no W_IngameMenu_C") return end
local fn = "BndEvt__W_IngameMenu_BTN2_Host_K2Node_ComponentBoundEvent_10_OnClicked__DelegateSignature"
local ok, err = pcall(function() w[fn](w) end)
emit("host clicked ok=" .. tostring(ok) .. " err=" .. tostring(err))
