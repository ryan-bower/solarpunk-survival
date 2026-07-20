-- luacheck config for the UE4SS Lua mod.
std = "lua54"
max_line_length = 160
unused_args = false          -- scaffold has intentional stub args (RE stubs)
ignore = { "631" }           -- line length in comment-heavy files

-- UE4SS injects these globals into the Lua VM.
read_globals = {
  "print",
  "RegisterHook",
  "NotifyOnNewObject",
  "RegisterKeyBind",
  "RegisterConsoleCommandHandler",
  "RegisterCustomEvent",
  "LoopAsync",
  "ExecuteWithDelay",
  "ExecuteInGameThread",
  "ExecuteAsync",
  "FindFirstOf",
  "FindAllOf",
  "StaticFindObject",
  "Key",
  "ImGui",
}

include_files = { "mod/SolarpunkSurvival/Scripts/**/*.lua" }
exclude_files = { "mod/SolarpunkSurvival/Scripts/lib/json.lua" } -- vendored; long by nature
