-- Headless unit tests for the game-independent logic. Run from the repo root:
--   lua tests/spec.lua
-- Stubs the UE4SS globals + the game-facing modules so the pure logic (json, eventbus, config,
-- mapping, gate, health/damage math) can be verified without the game.
local ROOT = "mod/SolarpunkSurvival/Scripts/"
package.path = ROOT .. "?.lua;" .. package.path

-- --- stub UE4SS globals (referenced at load/runtime) ---
_G.FindFirstOf = function() return nil end
_G.FindAllOf = function() return {} end
_G.RegisterHook = function() end
_G.NotifyOnNewObject = function() end
_G.RegisterKeyBind = function() end
_G.RegisterConsoleCommandHandler = function() end
_G.LoopAsync = function() end
_G.ExecuteWithDelay = function() end
_G.Key = setmetatable({}, { __index = function() return 0 end })

local passed, failed = 0, 0
local function ok(cond, msg)
  if cond then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. tostring(msg)) end
end
local function eq(a, b, msg)
  ok(a == b, (msg or "eq") .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end

------------------------------------------------------------------ json
local json = require("lib.json")
do
  local r = json.decode('{"a":1,"b":[true,false,null,"x"],"c":{"d":2.5}}')
  eq(r.a, 1, "json a"); eq(r.b[1], true, "json b[1]"); eq(r.b[4], "x", "json b[4]"); eq(r.c.d, 2.5, "json nested")
  local r2 = json.decode(json.encode({ x = 1, y = { 2, 3 } }))
  eq(r2.x, 1, "json roundtrip x"); eq(r2.y[2], 3, "json roundtrip y[2]")
  eq(json.decode('// comment\n{"z":9}').z, 9, "json tolerates // comment")
end

------------------------------------------------------------------ eventbus
local bus = require("core.eventbus")
do
  local got
  local fn = bus.on("t", function(p) got = p.v end)
  bus.emit("t", { v = 42 }); eq(got, 42, "bus emit")
  bus.off("t", fn); got = nil
  bus.emit("t", { v = 7 }); eq(got, nil, "bus off unsubscribes")
end

------------------------------------------------------------------ gate
local gate = require("core.gate")
do
  local map = { weather = { managerClass = "X" } }
  ok((gate.check(map, { "weather.managerClass" })), "gate: present passes")
  ok(not (gate.check(map, { "weather.currentProp" })), "gate: missing fails")
end

------------------------------------------------------------------ mapping
local mapping = require("mapping")
do
  local m, known = mapping.resolve("24038177")
  ok(known, "mapping: 24038177 is a known build")
  eq(m.pawn.worldLocationFn, "K2_GetActorLocation", "mapping: default worldLocationFn")
  eq(m.net.hasAuthorityFn, "HasAuthority", "mapping: default hasAuthorityFn")
  ok(#mapping.missing(m) > 0, "mapping: reports unmapped symbols")
  local _, known2 = mapping.resolve("does-not-exist")
  ok(not known2, "mapping: unknown build falls back")
  -- Milestone 2 sections
  eq(m.items.classFmt, "BP_%s_Item_C", "mapping: item class format")
  eq(string.format(m.items.classFmt, "Log"), "BP_Log_Item_C", "mapping: item class formats a row")
  eq(m.player.pingFn, "MULTI_Ping", "mapping: ping hook is the validated broadcast")
  eq(m.player.reduceHealthFn, "Reduce Health", "mapping: damage goes through Reduce Health")
  eq(m.ritual.wandItemRow, "Hoe_Kickstarter", "mapping: wand item is the KS-exclusive hoe (collision-proof)")
  eq(m.ritual.rodItemRow, "Weather_Station", "mapping: rod item")
  eq(m.animal.sheepClass, "BP_Animal_Sheep_C", "mapping: sheep class")
  eq(m.tree.classPrefix, "BP_Tree_", "mapping: tree prefix")
  ok(type(m.battery.chargePropCandidates) == "table" and #m.battery.chargePropCandidates > 0,
     "mapping: battery charge candidates present")
  ok(type(m.rod.stationClassCandidates) == "table", "mapping: rod station candidates present")
  eq(m.fx.clientDamageRpcFn, "CLIENT_ReduceHealth", "mapping: victim FX rides the client damage RPC")
end

------------------------------------------------------------------ config
local config = require("core.config").init("./__no_such_modroot__/")
do
  eq(config.get("player_strike_pct"), 0.70, "config: default strike pct")
  eq(config.get("lightning_rod_range"), 2500.0, "config: default rod range")
  local changedKey
  bus.on("config.changed", function(p) changedKey = p.key end)
  config.set("player_strike_pct", 0.9)
  eq(config.get("player_strike_pct"), 0.9, "config: set overrides")
  eq(changedKey, "player_strike_pct", "config: set emits config.changed")
end

------------------------------------------------------------------ health / damage math
-- stub the game-facing modules health depends on
package.loaded["core.net"] = { init = function() end, isHost = function() return true end,
                               multicast = function() end, hasCarriers = function() return false end }
package.loaded["core.identity"] = { init = function() end, idOf = function(a) return a.id end,
                                    locationOf = function() return nil end }
local health = require("core.health")
do
  -- player: 70% per strike -> survives one (at 30), dies on the second
  health.attach({ id = "p1" }, { max = 100, kind = "player" })
  local pDead = false
  bus.on("entity.destroyed", function(e) if e.id == "p1" then pDead = true end end)
  health.applyDamage("p1", 70, { source = "lightning" })
  ok(not pDead, "player: survives 1 strike")
  eq(health.get("p1").current, 30, "player: at 30 HP after 1 strike")
  health.applyDamage("p1", 70, { source = "lightning" })
  ok(pDead, "player: dies on 2nd strike (double strike lethal)")

  -- machine two-hit: 1st strike smokes (damaged), 2nd destroys
  health.attach({ id = "m1" }, { max = 200, kind = "machine", twoHit = true })
  local smoked, mDead = false, false
  bus.on("structure.damaged", function(e) if e.id == "m1" then smoked = true end end)
  bus.on("entity.destroyed", function(e) if e.id == "m1" then mDead = true end end)
  health.applyDamage("m1", 120, { source = "lightning" })
  ok(smoked, "machine: smokes on 1st strike")
  ok(not mDead, "machine: survives 1st strike")
  ok(health.get("m1").damaged, "machine: damaged flag set")
  health.applyDamage("m1", 120, { source = "lightning" })
  ok(mDead, "machine: destroyed on 2nd strike")

  -- repair clears the smoking state and restores HP
  health.attach({ id = "m2" }, { max = 200, kind = "machine", twoHit = true })
  health.applyDamage("m2", 120, { source = "lightning" })
  ok(health.repair("m2"), "repair returns true")
  ok(not health.get("m2").damaged, "repair: clears smoking")
  eq(health.get("m2").current, 200, "repair: restores full HP")
end

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
