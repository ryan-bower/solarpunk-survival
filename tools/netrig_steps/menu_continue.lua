-- Click the main menu's "keep playing" button (loads the most recent save).
-- Trampoline name proven live 2026-07-28 (solarpunk-live-hotload memory).
local w = FindFirstOf("W_MainMenu_C")
if not (w and w:IsValid()) then emit("no W_MainMenu_C") return end
local fn = "BndEvt__W_MainMenu_BTN_Playing_1_K2Node_ComponentBoundEvent_12_OnButtonClickedEvent__DelegateSignature"
local ok, err = pcall(function() w[fn](w) end)
emit("continue clicked ok=" .. tostring(ok) .. " err=" .. tostring(err))
