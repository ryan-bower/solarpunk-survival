-- The wand: a REAL standalone tool, not a redressed inventory item.
--
-- Lua cannot mint a new inventory item ID (that needs a cooked content pak -- see
-- docs/MILESTONE-2.md), so the wand lives OUTSIDE the inventory -- but it is HELD the way the
-- game holds its own tools. Real tools work like this (RE capture, BP_MainPlayerCharacter_C):
-- the selected hotbar item's mesh is placed into two right-hand slot components --
-- Mesh_Slot_1Person_Hand_R (first person) and Mesh_Slot_3rdPerson_Hand_R (third person) -- via
-- SetHandRMeshForBoth; StashHandItem / RestoreHandItem park and re-equip the held item; and
-- HotbarSlotChanged fires when the player switches tools. The drawn wand rides exactly that
-- machinery:
--
--   model    = a TINTED stick rendered by the game's OWN held-item pipeline. Every visible held
--              item in this game is a spawned BP_HandItem_* actor (bytecode RE, 2026-07-21 -- see
--              buildRig + the mapping's wand comments); our rows aren't in the baked
--              item->hand-item map, so the game shows an empty palm. buildRig makes the game's own
--              equip call (SetHandRBlueprintForBoth) with a donor hand-item class (Carrot), then
--              dresses the spawned actor's mesh as SM_Stick (force-loaded via LoadAsset if
--              needed); paintState tints it with the wand_mat_* material assets per state:
--              Mundane = log brown, Electric = cobalt blue, Charged = the stick's pickup-glow
--              shimmer. The old AddComponentByClass component rig was REMOVED (2026-07-21):
--              it native-crashed on this build -- the step log ended at "build rig (hand seat)" on
--              every equip that reached the mesh ops (12:33 + 15:54 sessions), and the earlier
--              component->component K2_AttachToComponent attach was the maiden-flight fatal too.
--              The whole custom-component-on-pawn family is unsafe here, which is why the tint is
--              a material override and the actor spawn rides the game's own equip function.
--              Risky steps append to dump/wand_steps.txt.
--   obtain   = craft the Mundane Wand at the bench; the rites imbue it in TWO rungs (the codex's
--              ladder): chicken + five clean waters -> Hydration Wand (blue, 240 water measures =
--              2x the watering can; pours into growboxes, quenches teammates, refills on drinking
--              any water or wading in pond/river); then sheep + the five offerings -> the
--              Electrick Wand (gold when spent, BRIGHT yellow when charged). `sps_wand forge`
--              grants a test Mundane; `sps_wand soak` a full Hydration.
--   carry    = press the draw key (V) or `sps_wand draw` to draw/stow. Drawing stashes the held
--              item (the game's own StashHandItem); stowing restores it; picking a hotbar tool
--              while the wand is out stows the wand -- exactly like swapping tools.
--   states   = Mundane Wand -> Lightning Wand (charged) -> Lightning Wand (uncharged).
--              charged: the powered-state glow (the wand is live) + optional crackle.
--              uncharged: beeswax yellow. hydration: cobalt blue. mundane: tree-bark dark
--              brown. All from config wand_mat_* material assets.
--   cast     = left click (PressedHandInteraction / IA_HandInteract) while drawn + charged: a
--              real bolt at the aimed point, ANY weather. The stash means the game still sees
--              EMPTY hands while the wand is drawn, so the generic left click keeps firing --
--              and no real tool's action can double-trigger under a cast.
--   recharge = stand within wand_recharge_radius (5 m) of a strike that isn't your own cast
--              while the wand is drawn.
--
-- MP: wand state lives on the host (fully functional for the host player; remote players'
-- states are tracked host-side, but their draw key/visuals run on their own machine -- a
-- client->host carrier is future work, docs/MILESTONE-2.md). The rig is cosmetic only; stash/
-- restore of the held item runs ONLY on the local player's pawn (never on a remote replica).
local F = {}
local ctx

local wands = {}    -- playerId -> "mundane" | "hydration" | "charged" | "uncharged"  (nil = none)
local drawn = {}    -- playerId -> true while the wand is out
local rigs  = {}    -- playerId -> { pawn, mode="hand"|"capsule", handle?, tips={}, slots={}, fx?, stashed? }
local heldItemKind = {}  -- playerId -> item kind while a REAL cooked wand item is in hand
local castHooked = false
local hotbarHooked = false
local rebuildHooked = false
local drinkHooked = false
local waterHooked = false
local lastCast = -1e9
local lastHandAction = -1e9  -- our own stash/restore fires HotbarSlotChanged; this window ignores it
local meshCache     -- assetName -> UStaticMesh (successes only -- misses always retry)
local donorMats = {} -- donor mesh assetName -> its slot-0 material (the wand tint source)

-- The rite ladder (host-side, survives hotbar swaps and stowing): nil -> "hydration" ->
-- "electrick". The rites promote it; the held MUNDANE item then renders/behaves at the earned
-- rung (the blank rod is what gets imbued -- the inventory item itself cannot change).
local tiers   = {}  -- playerId -> "hydration" | "electrick" (nil = the rod is still mundane)
local charges = {}  -- playerId -> water measures left in the blue rod (hydration tier only)
local zaps    = {}  -- playerId -> bolts left in the charged rod (wand_electric_charges per fill)
local barLevel = {} -- playerId -> durability notches the held HYDRATION item currently displays
local lastSoak = {} -- playerId -> os.clock() of the last wade-refill (footstep events spam)
local hydroKnown = {} -- playerId -> true once a REAL HydrationWand item was seen in their hand:
                      -- the dedicated item keeps its own nature at ANY tier, so drink/wade
                      -- refills must keep working for it even after the rite ladder reads
                      -- electrick (and even while a carafe/tool is in hand -- you drink with
                      -- the carafe up, not the rod). Cleared when the rod transmutes to charged.
local transmuteHeld -- fwd decls (defined after onHotbarChanged; earlier code calls them at runtime)
local syncHydroBar
local refreshHotbarUi

local STATE_NAMES = { mundane = "Mundane Wand", hydration = "Hydration Wand",
                      charged = "Lightning Wand (charged)",
                      uncharged = "Lightning Wand (uncharged)" }

-- The cooked wand items map to rig states + a friendly label. Mundane (brown) = the blank rod;
-- Hydration (blue) = the quenched rod; Electric (dim gold, spent) = "uncharged"; Charged
-- Electric (bright yellow) = "charged".
local KIND_STATE = { mundane = "mundane", hydration = "hydration",
                     electric = "uncharged", charged = "charged" }
local KIND_LABEL = { mundane = "Mundane", hydration = "Hydration",
                     electric = "Electrick", charged = "Charged Electrick" }

local function onGameThread(fn)
  if ExecuteInGameThread then
    if pcall(ExecuteInGameThread, fn) then return end
  end
  pcall(fn)
end

-- Crash bisection: one line per risky rig step, appended to dump/wand_steps.txt. A native crash
-- kills the process before the next line, so the file names the killer (the proven P1-P6 method).
local function mark(s)
  if not ctx.config.get("wand_step_log") then return end
  pcall(function()
    local f = io.open((ctx.modRoot or "") .. "dump/wand_steps.txt", "a")
    if f then f:write(os.date("%H:%M:%S ") .. s .. "\n"); f:close() end
  end)
end

-- Same live UObject instance? Path compare via uehelp (wrapper equality is not trustworthy
-- across two separate property reads).
local function sameObject(a, b) return ctx.uehelp.sameObject(a, b) end

-- UE4SS out-params: every call with OUT params REQUIRES a fresh Lua table in each OUT slot
-- (a scalar placeholder throws "no table was on the stack" -- live 2026-07-22); the out
-- value lands in that table keyed by param name, when a caller needs to read it back.

local function pawnController(pawn)
  local pc
  pcall(function() pc = pawn.Controller end)
  if ctx.uehelp.isValid(pc) then return pc end
  return nil
end

-- Stable per-player key. The game's own UniquePlayerID is preferred: identity.idOf falls back to
-- a location-derived key for pawns/controllers, which DRIFTS as the player walks -- and a tool
-- must keep working while its owner moves (draw, walk, cast).
local function playerIdOf(pawn)
  local prop = ctx.map.pawn.playerIdProp
  if prop then
    local candidates = {}
    local pc = pawnController(pawn)
    if pc then candidates[#candidates + 1] = pc end
    candidates[#candidates + 1] = pawn
    for _, obj in ipairs(candidates) do
      local ok, v = ctx.uehelp.get(obj, prop)
      if ok and v ~= nil then
        local s
        if type(v) == "userdata" then pcall(function() s = v:ToString() end) else s = tostring(v) end
        if s and s ~= "" then return "uid:" .. s end
      end
    end
  end
  local pc = pawnController(pawn)
  return pc and ctx.identity.idOf(pc) or ctx.identity.idOf(pawn)
end

local function localPlayerPawn()
  local pc = ctx.uehelp.findFirst(ctx.map.player.controllerClass)
  local pawn
  pcall(function() pawn = pc and pc:K2_GetPawn() end)
  if ctx.uehelp.isValid(pawn) then return pawn end
  return ctx.uehelp.findFirst(ctx.map.pawn.class)
end

local function isLocalPawn(pawn)
  local lp = localPlayerPawn()
  return lp ~= nil and playerIdOf(lp) == playerIdOf(pawn)
end

--------------------------------------------------------------------- mesh + material donors
-- Scan loaded StaticMesh assets by NAME. Names-only iteration -- never read properties off
-- CDOs/templates (fatal, proven P1), never spawn item BPs for their looks.
local function scanForMesh(assetName)
  local found
  local all = {}
  pcall(function() all = FindAllOf("StaticMesh") or {} end)
  for _, m in ipairs(all) do
    local nm; pcall(function() nm = m:GetFName():ToString() end)
    if nm == assetName then found = m; break end
  end
  return found
end

-- Resolve a mesh asset, force-loading it if needed. SM_Stick is only resident when a stick actor
-- exists in the world (the base Stick never renders in-hand), so the first wand equip of a session
-- routinely finds NOTHING in the loaded scan -- the old one-shot cache then pinned that miss
-- forever and the hand stayed empty (the palm-out-pose-with-no-item bug). Misses are never cached;
-- LoadAsset is the same proven fallback uehelp.classByName uses. Runs only off equip events.
local function meshByName(assetName)
  if not assetName then return nil end
  meshCache = meshCache or {}
  local cached = meshCache[assetName]
  if ctx.uehelp.isValid(cached) then return cached end
  meshCache[assetName] = nil
  local found = scanForMesh(assetName)
  if not found then
    local path = (ctx.map.wand.meshPaths or {})[assetName]
    if path and LoadAsset then
      mark("LoadAsset " .. assetName)
      pcall(LoadAsset, path)
      found = scanForMesh(assetName)
    end
    if not found then
      ctx.log.warn("wand: mesh asset '" .. assetName .. "' not loaded -- visual degrades")
    end
  end
  meshCache[assetName] = found
  return found
end

-- Resolve a material ASSET by name (config wand_mat_*), force-loading from the game's flat
-- materials dir if needed. Direct material assets beat mesh donors: the SM_Cobalt MESH ships with
-- WorldGridMaterial (the engine's grey-white checker -- its real M_Cobalt was simply never
-- assigned), so reading a donor mesh's slot 0 can hand back the wrong look entirely. Tries both
-- Material and MaterialInstanceConstant kinds; only successes are cached.
local matCache = {}
local function materialByName(name)
  if not name or name == "" then return nil end
  local cached = matCache[name]
  if cached and ctx.uehelp.isValid(cached) then return cached end
  matCache[name] = nil
  local function find()
    for _, kind in ipairs({ "MaterialInstanceConstant", "Material" }) do
      local ok, mt = pcall(FindObject, kind, name)
      if ok and ctx.uehelp.isValid(mt) then return mt end
    end
    return nil
  end
  local mt = find()
  if not mt and ctx.map.wand.materialDir and LoadAsset then
    mark("LoadAsset material " .. name)
    pcall(LoadAsset, ctx.map.wand.materialDir .. name .. "." .. name)
    mt = find()
  end
  if not mt then
    ctx.log.warn("wand: tint material '" .. name .. "' not found -- mesh-donor fallback")
  end
  matCache[name] = mt
  return mt
end

-- FALLBACK tint source: a donor mesh asset's slot-0 material (reading a mesh ASSET's material is
-- the proven-safe pattern; only success is cached, so a not-yet-loaded donor retries next equip).
local function donorMaterial(assetName)
  if not assetName then return nil end
  local cached = donorMats[assetName]
  if cached and ctx.uehelp.isValid(cached) then return cached end
  donorMats[assetName] = nil
  local mat
  local m = meshByName(assetName)
  if m then pcall(function() mat = m:GetMaterial(0) end) end
  donorMats[assetName] = mat
  return mat
end

--------------------------------------------------------------------- the visual rig
local function spawnElectricity(comp)
  local nfl = StaticFindObject and StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
  if not nfl then return nil end
  for _, nm in ipairs(ctx.map.wand.niagaraCandidates or {}) do
    local sys; pcall(function() sys = FindObject("NiagaraSystem", nm) end)
    if sys then
      local fx
      local zero, rot = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }
      -- reflected signature varies across engine versions; try the two common arities
      -- (a wrong arity is a SAFE Lua error -- UE4SS validates the param count)
      if not pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false) end) then
        pcall(function() fx = nfl:SpawnSystemAttached(sys, comp, "None", zero, rot, 1, false, true, 0, false) end)
      end
      if fx then return fx end
    end
  end
  return nil
end

-- opts.handsBack=false skips the stashed-item re-equip (used when the game itself just took
-- the hand back, e.g. the player picked a hotbar tool while the wand was out).
local function tearRig(id, opts)
  local r = id and rigs[id]
  if not r then return end
  local handsBack = not (opts and opts.handsBack == false)
  pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx) end end)
  for _, tip in ipairs(r.tips or {}) do
    pcall(function() tip:DestroyComponent(tip) end)
  end
  pcall(function() if r.handle then r.handle:DestroyComponent(r.handle) end end)
  -- Destroy our spawned hand-item actor ONLY if it is still the pawn's tracked hand item (V-key
  -- stow, retune, wand->wand rebuild race). On a normal hotbar switch the game has already
  -- destroyed/replaced it -- SetHandRBlueprintForBoth destroys the old actor on every call -- and
  -- firing ClearHandBlueprints then would kill the NEW item's hand actor (the hidden-berry class
  -- of bug). The tint override needs no cleanup: it lives on the spawned actor and dies with it.
  if r.handItem and ctx.uehelp.isValid(r.handItem) and ctx.map.wand.clearHandFn
      and ctx.map.wand.handItemProp and ctx.uehelp.isValid(r.pawn) then
    local cur
    pcall(function() cur = r.pawn[ctx.map.wand.handItemProp] end)
    if ctx.uehelp.isValid(cur) and sameObject(cur, r.handItem) then
      mark("clear hand item")
      ctx.uehelp.call(r.pawn, ctx.map.wand.clearHandFn)
    end
  end
  if r.stashed and handsBack and ctx.map.wand.restoreFn and ctx.uehelp.isValid(r.pawn) then
    lastHandAction = os.clock()
    mark("restore held item")
    ctx.uehelp.call(r.pawn, ctx.map.wand.restoreFn)
  end
  rigs[id] = nil
end

-- Give the wand a REAL in-hand model by riding the game's held-item pipeline. Offline bytecode RE
-- of BP_MainPlayerCharacter (2026-07-21; see the mapping's wand comments + pakkit HOWTO): every
-- VISIBLE held item is a spawned BP_HandItem_* actor. Consumables go through UpdateHandConsumable
-- = Map_Find(ClassesToActor, CurItemdataInHand.ItemActor) -> SetHandRBlueprintForBoth(found),
-- where ClassesToActor is a class->class map BAKED into the bytecode. Our wand rows (like the
-- Stick they clone) are NOT in the map, so the game passes null and the palm poses empty -- and
-- neither pawn "FoodMesh" (doesn't exist -- mis-probe) nor the SetHandRMeshForBoth slot comps
-- (never visible) can fix that. So we make the game's own equip call ourselves with a DONOR
-- consumable's hand-item class (Carrot: elongated, pure-visual actor), then dress the spawned
-- actor's mesh comp as the stick; paintState tints it. Lifecycle stays game-owned:
-- SetHandRBlueprintForBoth destroys the previous hand item on every call and the game re-runs it
-- on every hotbar switch, so our spawn is cleaned up exactly like a berry's. All ops are the
-- game's own machinery on the game thread; the custom-component/attach family stays banned
-- (native crash). Local player only. Every op step-logs into wand_steps.txt.
local function buildRig(pawn, r)
  local m = ctx.map.wand
  local u = ctx.uehelp
  if not isLocalPawn(pawn) then return end
  local mesh = meshByName(m.stickMesh)
  if not mesh then mark("no stick mesh -- rig aborted") return end

  -- re-assert (the +600ms refill): the spawned hand item is still alive -- just re-dress it
  if r.handItem and u.isValid(r.handItem) and r.food and u.isValid(r.food) then
    u.call(r.food, "SetStaticMesh", mesh)
    r.mode = "handitem"
    return
  end
  r.handItem, r.food = nil, nil

  -- wand_in_hand gates the whole HAND TAKEOVER: stash of the held tool + the spawned hand-item
  -- actor. false = legacy slot-mesh fallback only (usually invisible; casting still works).
  local inHand = ctx.config.get("wand_in_hand")

  -- V-draw over a real held tool: park it first (the game's own stash) so the generic left click
  -- can't both swing the tool and cast a bolt; tearRig/refreshRig give it back via restoreFn.
  -- Never stash when the held item IS a cooked wand (it is the thing being drawn), and only once
  -- per rig (the +600ms re-assert re-enters buildRig on the same r).
  local ownerId = playerIdOf(pawn)
  if inHand and m.stashFn and not r.stashed and not (ownerId and heldItemKind[ownerId]) then
    lastHandAction = os.clock()
    if u.call(pawn, m.stashFn) then r.stashed = true end
    mark(r.stashed and "stash held item" or "stash refused (continuing)")
  end

  -- primary: spawn the game's hand-item actor via its own equip call, then re-dress it
  if inHand and m.handBlueprintFn and m.handItemDonor then
    local cls = u.classByName(m.handItemDonor, m.handItemDonorPath)
    if not cls then
      mark("hand item donor class unavailable")
    else
      mark("spawn hand item")
      if u.call(pawn, m.handBlueprintFn, cls) then
        local actor
        pcall(function() actor = pawn[m.handItemProp] end)
        if u.isValid(actor) then
          r.handItem = actor
          -- The hand item is cosmetic, and the game's food meshes carry no collision -- but
          -- SM_Stick SHIPS collision geometry (it lies on the ground as a pickup). Attached to the
          -- palm, that collider is a separate actor the pawn's own movement sweeps hit: the
          -- can't-walk-while-drawn bug. Kill collision on the whole actor before dressing it.
          local collOff = u.call(actor, "SetActorEnableCollision", false)
          for _, compName in ipairs(m.handItemMeshProps or {}) do
            local comp
            pcall(function() comp = actor[compName] end)
            if u.isValid(comp) and u.call(comp, "SetStaticMesh", mesh) then
              r.food = comp
              break  -- ONE mesh only -- dressing MainMesh too would draw a second stick
            end
          end
          mark(r.food and "hand item dressed as stick" or "hand item mesh comp missing")
          if r.food then
            if not collOff then u.call(r.food, "SetCollisionEnabled", 0) end
            mark(collOff and "collision off (actor)" or "collision off (comp fallback)")
            r.mode = "handitem"
            -- live-tunable stick size (any wand_* change rebuilds the rig -- see init)
            local s = ctx.config.get("wand_hand_scale") or 1.0
            if s ~= 1.0 then u.call(r.food, "SetRelativeScale3D", { X = s, Y = s, Z = s }) end
          end
        else
          mark("hand item prop empty after spawn")
        end
      else
        mark("SetHandRBlueprintForBoth FAILED")
      end
    end
  end

  -- fallback (nothing visible, but the state machinery still works): the legacy tool slots
  if not r.mode and m.handMeshFn and u.call(pawn, m.handMeshFn, mesh) then r.mode = "handmesh" end
end

-- Repaint the in-hand stick (and any legacy tips) + fx for the owner's current state. The TINT is
-- a material override on the dressed hand-item mesh comp, from the config wand_mat_* material
-- assets: Mundane = tree-bark dark brown, Electric/uncharged = beeswax yellow, Hydration =
-- cobalt blue, Charged = the powered-state glow. Mundane is painted explicitly (not skipped) so
-- switching hotbar slots from an Electric wand back to a Mundane one un-blues the stick. The
-- override needs no cleanup -- it lives on the spawned hand-item actor and dies with it. Only the
-- CHARGED wand crackles (wand_fx: OFF until the Niagara call is live-proven).
local function paintState(r, state)
  local m = ctx.map.wand
  local cfgKey = (state == "charged" and "wand_mat_charged")
              or (state == "uncharged" and "wand_mat_electric")
              or (state == "hydration" and "wand_mat_hydration")
              or "wand_mat_mundane"
  local mat = materialByName(ctx.config.get(cfgKey))
  local matSrc = tostring(ctx.config.get(cfgKey))
  if not mat then
    -- last resort: a donor MESH's slot-0 material (SM_Cobalt's is WorldGrid -- wrong but visible)
    local donor = (state == "charged" and m.diamondMesh)
               or ((state == "uncharged" or state == "hydration") and m.cobaltMesh)
               or m.stickMesh
    mat = donorMaterial(donor)
    matSrc = "donor " .. tostring(donor)
  end
  if mat then
    if r.food and ctx.uehelp.isValid(r.food) then
      mark("tint " .. tostring(state) .. " (" .. matSrc .. ")")
      pcall(function() r.food:SetMaterial(0, mat) end)
    end
    for _, tip in ipairs(r.tips or {}) do pcall(function() tip:SetMaterial(0, mat) end) end
  end
  if state == "charged" then
    if not r.fx and ctx.config.get("wand_fx") and r.tips[1] then r.fx = spawnElectricity(r.tips[1]) end
  else
    pcall(function() if r.fx then r.fx:Deactivate(); r.fx:DestroyComponent(r.fx); r.fx = nil end end)
  end
end

-- Build/refresh the in-hand wand model for a pawn according to its owner's state.
local function refreshRig(pawn)
  if not ctx.config.get("wand_rig") then return end
  if not ctx.uehelp.isValid(pawn) then return end
  local id = playerIdOf(pawn)
  if not id then return end
  if not (wands[id] and drawn[id]) then tearRig(id); return end

  local r = rigs[id]
  -- self-heal: the game's own re-equip (a hotbar switch, or ANY UI close via
  -- ForceUpdateHotbarSlot -> UpdateHandMeshesAndModes -- offline RE 2026-07-22) destroys our
  -- spawned hand actor and poses an empty palm. A rig whose actor died must REBUILD on the
  -- same record -- repainting dead comps leaves the hand empty, and keeping r preserves
  -- r.stashed (never re-stash/restore mid-draw). IsValid alone CANNOT detect this death:
  -- a game-destroyed actor stays "valid" until GC actually collects it (the
  -- invisible-wand-after-inventory bug, live 2026-07-22), so also require the pawn's
  -- tracked hand-item prop to still point at OUR actor -- after the game's re-equip it is
  -- null (unmapped rows) or a new actor, which is the reliable death signal.
  if r and r.mode and r.handItem then
    local alive = ctx.uehelp.isValid(r.handItem)
    if alive and ctx.map.wand.handItemProp then
      local cur
      pcall(function() cur = pawn[ctx.map.wand.handItemProp] end)
      alive = ctx.uehelp.isValid(cur) and sameObject(cur, r.handItem)
    end
    if not alive then
      mark("hand actor gone -- rebuild")
      r.mode, r.handItem, r.food, r.refill = nil, nil, nil, nil
    end
  end
  if not (r and r.mode) then
    if not r then
      tearRig(id)
      r = { pawn = pawn, tips = {} }
    end
    buildRig(pawn, r)
    if not r.mode then
      -- total failure: give back anything the hand attempt stashed before giving up
      if r.stashed and ctx.map.wand.restoreFn then
        lastHandAction = os.clock()
        ctx.uehelp.call(pawn, ctx.map.wand.restoreFn)
      end
      ctx.log.warn("wand: no rig components -- the wand is in your hand, just unseen")
      return
    end
    rigs[id] = r
  end
  paintState(r, wands[id])
  -- The game's own consumable equip (UpdateHandConsumable) can land AFTER this build and re-clear
  -- the mesh it found empty in the row data -- one delayed re-fill wins that race. A single
  -- event-driven shot per rig, NOT a timer (polling UObjects on a timer is the proven native
  -- crash); everything it touches is re-validated at fire time.
  if not r.refill then
    r.refill = true
    pcall(ExecuteWithDelay, 600, ctx.log.guard("wand.refill", function()
      onGameThread(function()
        if rigs[id] ~= r or not drawn[id] then return end
        if not ctx.uehelp.isValid(pawn) then return end
        mark("re-assert hand mesh")
        buildRig(pawn, r)
        paintState(r, wands[id])
      end)
    end))
  end
end

--------------------------------------------------------------------- state transitions
local function setState(pawn, state, quiet)
  local id = playerIdOf(pawn)
  if not id then return end
  local isNew = wands[id] == nil
  wands[id] = state
  -- the rite ladder remembers the highest rung even when the item is stowed / swapped away
  if state == "hydration" and tiers[id] ~= "electrick" then tiers[id] = "hydration" end
  if state == "charged" or state == "uncharged" then tiers[id] = "electrick" end
  if isNew then drawn[id] = true end   -- a freshly forged wand leaps straight into the hand
  if not quiet then
    if state == "charged" then
      ctx.log.info(string.format(
        "*** LIGHTNING WAND (CHARGED) *** the rod burns yellow as noon (%d bolts). Left click to cast.",
        zaps[id] or ctx.config.get("wand_electric_charges")))
    elseif state == "uncharged" then
      ctx.log.info("Lightning Wand (uncharged) -- the rod dims to old gold."
        .. " Hold it within 5 m of a strike to recharge.")
    elseif state == "hydration" then
      ctx.log.info(string.format(
        "*** HYDRATION WAND *** the rod runs river-blue (%.0f measures). Left click to pour.",
        charges[id] or 0))
    elseif state == "mundane" then
      ctx.log.info("a Mundane Wand -- a wax-sealed stick. The rites will wake it: first water, then fire.")
    end
  end
  -- refresh the rig OUTSIDE whatever call chain set the state (the ritual sets it from inside
  -- the bolt-impact chain; never build cosmetics in there). HARD refresh -- tear + rebuild -- so
  -- the mesh AND tint are re-asserted from scratch: the click that cast may have run the game's
  -- consume handling over the same hand and cleared the mesh a repaint alone would not restore.
  pcall(ExecuteWithDelay, 150, ctx.log.guard("wand.rig", function()
    onGameThread(function()
      tearRig(id, { handsBack = false })
      refreshRig(pawn)
    end)
  end))
end

-- Sheep-rite payout (the SECOND rung): the storm only enters a rod that has first drunk the
-- deluge. Players in the circle whose rod is hydration-tier (or already electrick) -> Lightning
-- Wand (charged); a still-mundane rod is passed over (the codex warns: skip no rung); wandless
-- bystanders receive nothing.
function F.chargeWands(center, radius)
  if not ctx.net.isHost() then return 0 end
  local r2 = (radius or ctx.config.get("ritual_radius")) ^ 2
  local woken, rewoken, dry = 0, 0, 0
  for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl and ctx.uehelp.dist2(pl, center) <= r2 then
      local id = playerIdOf(pawn)
      if id then
        local st, tier = wands[id], tiers[id]
        if tier == "electrick" or st == "charged" or st == "uncharged" then
          rewoken = rewoken + 1
          charges[id] = nil            -- whatever water was left boiled away long ago
          zaps[id] = ctx.config.get("wand_electric_charges")
          setState(pawn, "charged", true)
          transmuteHeld(pawn, "charged")
        elseif tier == "hydration" or st == "hydration" then
          woken = woken + 1
          charges[id] = nil            -- the water boils away; the fire moves in
          zaps[id] = ctx.config.get("wand_electric_charges")
          setState(pawn, "charged", true)
          transmuteHeld(pawn, "charged")  -- a REAL blue rod in hand becomes the charged rod item
        elseif st == "mundane" then
          dry = dry + 1
        end
      end
    end
  end
  local total = woken + rewoken
  if total > 0 then
    ctx.log.info(string.format(
      "*** the bolt is BOUND -- %d Lightning Wand(s) (charged): %d transmuted from water, %d reawakened ***",
      total, woken, rewoken))
    ctx.log.info("    press V to draw/stow the wand; left click while it's drawn to cast")
  else
    ctx.log.info("ritual: no quenched rod stood inside the circle to receive the fire")
  end
  if dry > 0 then
    ctx.log.info(string.format(
      "    the sky passed over %d dry rod(s) -- the deluge comes before the fire (chicken + five waters)", dry))
  end
  return total
end

-- Chicken-rite payout (the FIRST rung): every mundane rod held by a player in the circle turns
-- river-blue -- a Hydration Wand, full to the brim (2x the watering can); an already-blue rod is
-- refilled; an electrick rod is beyond water and is passed over.
function F.hydrateWands(center, radius)
  if not ctx.net.isHost() then return 0 end
  local max = ctx.config.get("wand_hydration_max")
  local r2 = (radius or ctx.config.get("ritual_radius")) ^ 2
  local quenched, refilled, beyond = 0, 0, 0
  for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
    local pl = ctx.identity.locationOf(pawn)
    if pl and ctx.uehelp.dist2(pl, center) <= r2 then
      local id = playerIdOf(pawn)
      if id then
        local st, tier = wands[id], tiers[id]
        if tier == "electrick" or st == "charged" or st == "uncharged" then
          beyond = beyond + 1
        elseif st == "hydration" or tier == "hydration" then
          refilled = refilled + 1
          charges[id] = max
          if st == "hydration" then setState(pawn, "hydration", true) end
        elseif st == "mundane" then
          quenched = quenched + 1
          charges[id] = max
          setState(pawn, "hydration", true)
        end
      end
    end
  end
  local total = quenched + refilled
  if total > 0 then
    ctx.log.info(string.format(
      "*** the five waters leap into the rod -- %d Hydration Wand(s) (%.0f measures): %d newly quenched, %d refilled ***",
      total, max, quenched, refilled))
    ctx.log.info("    left click while drawn: pour on a growbox, or quench a thirsty companion")
  else
    ctx.log.info("ritual: no mundane rod stood inside the circle to be quenched (hold thy wand)")
  end
  if beyond > 0 then
    ctx.log.info(string.format("    %d electrick rod(s) are beyond water now -- the fire keeps what it takes", beyond))
  end
  return total
end

--------------------------------------------------------------------- casting
local function aimPoint(pc, pawn)
  local u = ctx.uehelp
  local cam; pcall(function() cam = pc.PlayerCameraManager end)
  if not cam then return nil end
  local cl = u.vec(cam:GetCameraLocation())
  local rot; pcall(function() rot = cam:GetCameraRotation() end)
  local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
  local fwd = (rot and kml) and u.vec(kml:GetForwardVector(rot)) or nil
  if not (cl and fwd) then return nil end
  local range = ctx.config.get("wand_cast_range")
  local endp = { X = cl.X + fwd.X * range, Y = cl.Y + fwd.Y * range, Z = cl.Z + fwd.Z * range }
  local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
  local hitLoc
  pcall(function()
    local hit = {}
    local red, green = { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }
    if ksl:LineTraceSingle(pc, cl, endp, 0, false, { pawn }, 0, hit, true, red, green, 0.0) then
      for _, f in ipairs({ "ImpactPoint", "Location" }) do
        local okf, v = pcall(function() return hit[f] end)
        if okf then
          local hv = u.vec(v)
          if hv then hitLoc = hv; return end
        end
      end
    end
  end)
  return hitLoc or endp
end

-- The watercan's own splash on a wand pour. The watered target (growbox and kin) carries a
-- BC_WateringParticleManager component whose bytecode spawns the NS_Watering_Hit Niagara itself;
-- we only make two plain BP calls on it (register the pourer, play for a beat). Cosmetic --
-- every miss is silent. NEVER spawn Niagara via reflected statics from Lua (proven native crash).
local function sprayAt(pawn, targetActor)
  local u, m = ctx.uehelp, ctx.map
  local cls = m.wand.wateringFxComponentClass
  if not (cls and u.isValid(targetActor)) then return end
  for _, comp in ipairs(u.findAll(cls)) do
    if u.isValid(comp) then
      local owner
      pcall(function() owner = comp:GetOwner() end)
      if u.isValid(owner) and u.sameObject(owner, targetActor) then
        u.call(comp, m.wand.sprayRegisterFn, pawn)
        u.call(comp, m.wand.sprayPlayFn, ctx.config.get("wand_spray_seconds") or 0.8)
        return
      end
    end
  end
end

-- The can's own pour STREAM, from the wand's tip. The watering can's tick fires the
-- controller RPC SERVER_WaterCanParticles(ParticleManager, State, TargetPlayer) (offline RE
-- 2026-07-22 of BP_HandItem_Watercan + BP_MainPlayerController); mgr is the WATERED
-- TARGET's BC_WateringParticleManager -- the pawn carries none while idle (live 19:54:
-- "pawn has no particle manager"), the can's tick fetches it off the traced hit actor.
-- Plain BP calls on live objects -- cosmetic, every miss is silent; a delayed State=false
-- shuts the stream off after the spray window.
local function pourStream(pawn, mgr)
  local u, m = ctx.uehelp, ctx.map.wand
  if not (m.waterFxRpcFn and u.isValid(mgr)) then return end
  local pc = pawnController(pawn)
  if not pc then return end
  if u.call(pc, m.waterFxRpcFn, mgr, true, pawn) then
    mark("pour stream on")
    local ms = math.floor((ctx.config.get("wand_spray_seconds") or 0.8) * 1000)
    pcall(ExecuteWithDelay, ms, ctx.log.guard("wand.pourstream", function()
      onGameThread(function()
        if u.isValid(pc) and u.isValid(mgr) and u.isValid(pawn) then
          u.call(pc, m.waterFxRpcFn, mgr, false, pawn)
          mark("pour stream off")
        end
      end)
    end))
  end
end

-- The Hydration Wand's pour. Aim-point search instead of FHitResult actor extraction (reading
-- HitObjectHandle from Lua is engine-version fragile; distance-to-impact is not): a parched
-- TEAMMATE near the aim point outranks a planter box; else the nearest BC_WaterStorage owner
-- (growbox and kin) drinks a pour. Everything host-side: AddWater replicates via its OnRep, and
-- a remote teammate is quenched through the game's own owning-client CLIENT_AddThirst RPC.
local function hydroCast(pawn, id)
  local u, m = ctx.uehelp, ctx.map
  local ch = charges[id] or 0
  if ch <= 0 then
    ctx.log.info("the blue rod is DRY -- drink (any water), wade a river, or repeat the rite")
    return
  end
  local pc = pawnController(pawn)
  if not pc then return end
  local loc = aimPoint(pc, pawn)
  if not loc then return end
  local r2 = ctx.config.get("wand_pour_radius") ^ 2

  -- a companion first
  local mate, mateD
  for _, p in ipairs(u.findAll(m.pawn.class)) do
    if u.isValid(p) and playerIdOf(p) ~= id then
      local pl = ctx.identity.locationOf(p)
      local d2 = pl and u.dist2(pl, loc)
      if d2 and d2 <= r2 and (not mateD or d2 < mateD) then mate, mateD = p, d2 end
    end
  end
  if mate then
    local tpc = pawnController(mate)
    local amt = ctx.config.get("wand_hydrate_thirst")
    local ok = false
    if tpc and m.player.addThirstFn then
      local okCall, added
      if isLocalPawn(mate) then
        okCall, added = u.call(tpc, m.player.addThirstFn, amt, true)
      elseif m.player.clientAddThirstFn then
        okCall, added = u.call(tpc, m.player.clientAddThirstFn, amt, true)
      end
      -- u.call's first return is only marshal success; honor the fn's own verdict when it gives
      -- one (false = the vessel refused -- don't spend a measure; nil = void fn, call stands)
      ok = okCall == true and added ~= false
    end
    if ok then
      charges[id] = math.max(0, ch - ctx.config.get("wand_hydrate_cost"))
      syncHydroBar(pawn, id)
      ctx.log.info(string.format(
        "*** the rod QUENCHES thy companion (+%.0f thirst) -- %.0f measures remain ***",
        amt, charges[id]))
    else
      ctx.log.warn("wand: the pour found thy companion but their vessel refused it")
    end
    return
  end

  -- else the nearest thing that holds water (growbox etc. -- its BC_WaterStorage component)
  local store, storeD, storeOwner
  if m.wand.waterStorageClass then
    for _, comp in ipairs(u.findAll(m.wand.waterStorageClass)) do
      if u.isValid(comp) then
        local owner
        pcall(function() owner = comp:GetOwner() end)
        local ol = u.isValid(owner) and ctx.identity.locationOf(owner)
        local d2 = ol and u.dist2(ol, loc)
        if d2 and d2 <= r2 and (not storeD or d2 < storeD) then
          store, storeD, storeOwner = comp, d2, owner
        end
      end
    end
  end
  if store then
    local pour = math.min(ch, ctx.config.get("wand_pour_amount"))
    if u.call(store, m.wand.storageAddWaterFn, pour) then
      charges[id] = ch - pour
      syncHydroBar(pawn, id)
      sprayAt(pawn, storeOwner)
      pourStream(pawn, store)
      ctx.log.info(string.format(
        "*** the rod POURS (%.0f water) -- %.0f measures remain ***", pour, charges[id]))
    else
      ctx.log.warn("wand: the storage refused the pour (AddWater failed)")
    end
    return
  end
  ctx.log.info("the water finds nothing that thirsts -- aim at a growbox or a companion")
end

local function tryCast(pawn)
  if os.clock() - lastCast < ctx.config.get("wand_cast_debounce") then return end
  if not ctx.uehelp.isValid(pawn) then return end
  local id = playerIdOf(pawn)
  if not (id and drawn[id]) then return end
  local st = wands[id]
  if st ~= "charged" and st ~= "hydration" then return end
  lastCast = os.clock()
  if not ctx.net.isHost() then
    ctx.log.info("wand: casting is host-only until a client->host carrier exists")
    return
  end
  if st == "hydration" then
    hydroCast(pawn, id)
    return
  end
  local pc = pawnController(pawn)
  if not pc then return end
  local loc = aimPoint(pc, pawn)
  if not loc then return end
  if ctx.services.castBolt and ctx.services.castBolt(loc, id) then
    ctx.log.info(string.format("*** the wand SPEAKS -- bolt cast at (%.0f,%.0f) ***", loc.X, loc.Y))
    -- a full rod holds wand_electric_charges bolts; only the LAST one dims it (clamped at
    -- 0 -- a stray negative count would turn every later cast into an instant transmute)
    local left = math.max((zaps[id] or ctx.config.get("wand_electric_charges")) - 1, 0)
    zaps[id] = left
    if left > 0 then
      -- the charged item's bar (DefaultAttribues DURABILITY=3) counts the bolts down with
      -- us. DecreaseCurItemDurability's OUT param (ItemDestroyed) needs a fresh Lua TABLE
      -- in its slot (UE4SS convention; anything else = pcall fail, the frozen-bar bug).
      -- The bar NEVER steps to 0 -- at 0 the game destroys the item; the last bolt swaps
      -- the slot to the spent rod in place instead (transmuteHeld overwrite).
      if heldItemKind[id] == "charged" and ctx.map.wand.durabilityFn then
        local okD = ctx.uehelp.call(pawn, ctx.map.wand.durabilityFn, 1, {})
        mark("cast durability -1 ok=" .. tostring(okD))
        refreshHotbarUi(pawn)
      end
      ctx.log.info(string.format("the rod still holds %d bolt(s)", left))
    else
      setState(pawn, "uncharged")
      transmuteHeld(pawn, "electric")
    end
  end
end

-- Hook the generic left-click on the pawn: PressedHandInteraction + every IA_HandInteract input
-- event (NOT AltHandInteract -- that is right click). These fire with empty hands, so the wand
-- needs no held tool. The debounce eats the multi-phase double-fire.
local function hookCast()
  if castHooked then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local exact, prefix = ctx.map.wand.castFnExact, ctx.map.wand.castFnPrefix
  local paths = {}
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if (exact and n == exact) or (prefix and n:sub(1, #prefix) == prefix) then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  local hooked = 0
  for _, path in ipairs(paths) do
    local ok = pcall(RegisterHook, path, ctx.log.guard("wand.cast", function(Context)
      local p; pcall(function() p = Context:get() end)
      onGameThread(function() tryCast(p) end)
    end))
    if ok then hooked = hooked + 1 end
  end
  if hooked > 0 then
    castHooked = true
    ctx.log.info("wand: cast trigger armed (" .. hooked .. " left-click hooks)")
  end
end

--------------------------------------------------------------------- hydration refills
-- Full-path resolution for named pawn-class functions (same recipe as hookCast/hookHotbar).
local function pawnFnPaths(pawn, names)
  local want = {}
  for _, n in ipairs(names or {}) do want[n] = true end
  local paths = {}
  pcall(function()
    pawn:GetClass():ForEachFunction(function(fn)
      local n = ""; pcall(function() n = fn:GetFName():ToString() end)
      if want[n] then
        local full; pcall(function() full = fn:GetFullName() end)
        if full then paths[#paths + 1] = (full:gsub("^%S+%s+", "")) end
      end
    end)
  end)
  return paths
end

-- Refill the blue rod to the brim. Applies to anyone who has EARNED the hydration rung (drawn or
-- stowed -- you drink with the carafe in hand, not the wand); an electrick rod is beyond water.
local function refillHydration(pawn, why)
  local id = playerIdOf(pawn)
  if not id then return end
  -- an electrick ROD is beyond water -- but a player who owns the REAL HydrationWand item
  -- (hydroKnown) still refills it at any tier: the dedicated item keeps its own nature, and
  -- without this an electrick-tier player's blue rod bricks dry at 0 measures forever.
  if tiers[id] == "electrick" and not hydroKnown[id] then return end
  if not (wands[id] == "hydration" or tiers[id] == "hydration" or hydroKnown[id]) then return end
  local max = ctx.config.get("wand_hydration_max")
  if (charges[id] or 0) >= max then return end
  charges[id] = max
  ctx.log.info(string.format("*** the blue rod drinks %s -- FULL (%.0f measures) ***", why, max))
  -- refill the charge BAR in place (watering-can behavior): holding the rod -> sync now;
  -- holding the carafe/anything else -> onHotbarChanged syncs when the rod is next taken up
  if heldItemKind[id] == "hydration" and ctx.uehelp.isValid(pawn) then
    syncHydroBar(pawn, id)
  end
  if wands[id] == "hydration" and drawn[id] and ctx.uehelp.isValid(pawn) then
    pcall(ExecuteWithDelay, 150, ctx.log.guard("wand.refillrig", function()
      onGameThread(function() refreshRig(pawn) end)
    end))
  end
end

-- Drinking water (pure OR foul) refills the rod: AddConsumeableEffects(ConsumeableClass) runs on
-- the pawn for every consumed item -- match the two carafe classes (mapping wand.drinkClasses).
local function hookDrink()
  if drinkHooked then return end
  local m = ctx.map.wand
  if not (m.consumeEffectsFn and m.drinkClasses) then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local isDrink = {}
  for _, cn in ipairs(m.drinkClasses) do isDrink[cn] = true end
  local hooked = 0
  for _, path in ipairs(pawnFnPaths(pawn, { m.consumeEffectsFn })) do
    local ok = pcall(RegisterHook, path, ctx.log.guard("wand.drink", function(Context, ClsParam)
      local p, cls
      pcall(function() p = Context:get() end)
      pcall(function() cls = ClsParam:get() end)
      local cn
      if cls ~= nil then pcall(function() cn = cls:GetFName():ToString() end) end
      if not (cn and isDrink[cn]) then return end
      pcall(ExecuteWithDelay, 100, ctx.log.guard("wand.drink2", function()
        onGameThread(function()
          if ctx.uehelp.isValid(p) then refillHydration(p, "with thee") end
        end)
      end))
    end))
    if ok then hooked = hooked + 1 end
  end
  if hooked > 0 then
    drinkHooked = true
    ctx.log.info("wand: drink watch armed (any water refills the blue rod)")
  end
end

-- Standing/wading in pond or river refills the rod: the pawn's own water-footstep/water-landing
-- events are the poll-free "I am in water" signal (free-running UObject timers native-crash).
local function hookWaterTouch()
  if waterHooked then return end
  local m = ctx.map.wand
  if not m.waterTouchFns then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local hooked = 0
  for _, path in ipairs(pawnFnPaths(pawn, m.waterTouchFns)) do
    local ok = pcall(RegisterHook, path, ctx.log.guard("wand.wade", function(Context)
      local p; pcall(function() p = Context:get() end)
      pcall(ExecuteWithDelay, 100, ctx.log.guard("wand.wade2", function()
        onGameThread(function()
          if not ctx.uehelp.isValid(p) then return end
          local id = playerIdOf(p)
          if not id then return end
          if os.clock() - (lastSoak[id] or -1e9) < ctx.config.get("wand_water_refill_debounce") then
            return
          end
          lastSoak[id] = os.clock()
          refillHydration(p, "of the river")
        end)
      end))
    end))
    if ok then hooked = hooked + 1 end
  end
  if hooked > 0 then
    waterHooked = true
    ctx.log.info("wand: wade watch armed (pond/river water refills the blue rod)")
  end
end

--------------------------------------------------------------------- real-item detection
-- The held item is identified off `CurItemdataInHand` (the pawn's live S_Item struct). Two live
-- findings drive this (RE probe 2026-07-21, game running):
--   * `GetCurrentHoldItem` is a Blueprint fn with out-params (CurItem, EmptyHand) -- not a clean
--     0-arg getter -- so it is NOT used here.
--   * the struct's `DisplayName` FText reads EMPTY at runtime, but its `ItemActor` member is the
--     item's UClass directly (e.g. BP_MundaneWand_Item_C) -- the robust identity. S_Item is a
--     UserDefinedStruct, so every member name carries a GUID suffix (ItemActor_16_A80D...); we
--     discover the real names once by walking the struct type's properties and cache them.
local structMembers  -- { ItemActor="ItemActor_16_...", ... } once resolved; false = gave up
local structMemberTries = 0

local function itemStructMembers(pawn)
  if structMembers ~= nil then return structMembers or nil end
  local prop = ctx.map.wand.handItemDataProp
  if not prop then return nil end
  local found
  pcall(function()
    local cls = pawn:GetClass()
    if not (cls and cls.ForEachProperty) then return end
    cls:ForEachProperty(function(pr)
      local pn; pcall(function() pn = pr:GetFName():ToString() end)
      if pn == prop then
        local st
        pcall(function() st = pr:GetStruct() end)
        if not st then pcall(function() st = pr.Struct end) end
        if st and st.ForEachProperty then
          local m = {}
          st:ForEachProperty(function(mp)
            local mn; pcall(function() mn = mp:GetFName():ToString() end)
            if mn then m[mn:match("^(.-)_%d+_") or mn] = mn end
          end)
          if next(m) then found = m end
        end
      end
    end)
  end)
  if found then
    structMembers = found
  else
    -- a transient miss (reflection not fully registered yet) must not brick item detection for
    -- the whole session: retry on later hotbar events, cache the failure only once it's chronic
    structMemberTries = structMemberTries + 1
    if structMemberTries >= 5 then structMembers = false end
  end
  return structMembers or nil
end

-- Is the item CURRENTLY in this pawn's hand one of our cooked wand items? Returns
-- "mundane" | "electric" | nil. Read-only and fully pcall-guarded -- it runs off HotbarSlotChanged
-- (never a timer), and on any doubt returns nil (draw nothing) rather than risk a bad read.
local function equippedWandKind(pawn)
  local m = ctx.map.wand
  local u = ctx.uehelp
  local rows = m.itemRows or {}
  local classFmt = ctx.map.items and ctx.map.items.classFmt
  if not (m.handItemDataProp and classFmt) then return nil end
  local ok, data = u.get(pawn, m.handItemDataProp)
  if not (ok and data ~= nil) then return nil end
  local members = itemStructMembers(pawn)
  if not (members and members.ItemActor) then return nil end
  local ia; pcall(function() ia = data[members.ItemActor] end)
  -- EMPTY-SLOT CRASH FIX: an empty/no-item hand returns ItemActor as a UE4SS userdata wrapping a
  -- NULL UObject -- which is NOT Lua nil -- so `ia == nil` lets it through and ia:GetFName() then
  -- dereferences null => native access violation (uncatchable by pcall). This is exactly why
  -- selecting an empty hotbar slot crashed while holding a wand did not. IsValid() safely reports
  -- false for that null wrapper, so it is the correct guard here.
  if not u.isValid(ia) then return nil end
  local cn; pcall(function() cn = ia:GetFName():ToString() end)
  if not cn then return nil end
  if rows.mundane and cn == string.format(classFmt, rows.mundane) then return "mundane" end
  if rows.hydration and cn == string.format(classFmt, rows.hydration) then return "hydration" end
  if rows.electric and cn == string.format(classFmt, rows.electric) then return "electric" end
  if rows.charged and cn == string.format(classFmt, rows.charged) then return "charged" end
  return nil
end

-- The rite-ladder overlay on a HELD item: the cooked item can't change when a rite imbues it, so
-- the blank (mundane) rod renders/behaves at the player's EARNED rung -- blue once quenched,
-- gold once the fire has been through it. The dedicated hydration/electric items keep their own
-- nature regardless of tier.
local function effectiveState(id, kind)
  if kind == "mundane" then
    local t = tiers[id]
    if t == "hydration" then return "hydration", "Hydration" end
    if t == "electrick" then
      local st = (wands[id] == "charged") and "charged" or "uncharged"
      return st, (st == "charged") and "Charged Electrick" or "Electrick"
    end
  end
  return KIND_STATE[kind], KIND_LABEL[kind]
end

--------------------------------------------------------------------- tool-like hand behavior
-- Fires on every hotbar switch. Two jobs:
--   * real-item path (wand_from_item): equipping the cooked MundaneWand/ElectricWand draws the
--     stick+cobalt rig in that item's look; switching away stows it. This is how the real inventory
--     item gets a proper in-hand look without the crashing hoe-type tool integration.
--   * legacy path: a forged / V-drawn wand steps aside when the player picks a hotbar tool.
local function onHotbarChanged(pawn)
  if os.clock() - lastHandAction < 1.0 then return end  -- our own stash/restore echoes here
  if not ctx.uehelp.isValid(pawn) then return end
  local id = playerIdOf(pawn)
  if not id then return end

  if ctx.config.get("wand_from_item") then
    local kind = equippedWandKind(pawn)
    if kind then
      local switched = heldItemKind[id] ~= kind
      heldItemKind[id] = kind
      if kind == "hydration" then
        -- the cooked blue rod arrives full: taking it up earns the hydration rung (never
        -- downgrades an earned electrick tier) and pours its first tankful -- without this a
        -- granted/looted item reads "0 measures" and the drink/wade refills stay tier-locked.
        hydroKnown[id] = true
        tiers[id] = tiers[id] or "hydration"
        charges[id] = charges[id] or ctx.config.get("wand_hydration_max")
        -- a refill that happened while the carafe was in hand couldn't reset the rod's bar;
        -- settle the debt now that the rod is up (in-place savedata rewrite, never a regrant)
        local per = ctx.config.get("wand_pour_amount")
        if switched and per and per > 0 and barLevel[id]
            and charges[id] >= ctx.config.get("wand_hydration_max")
            and barLevel[id] < math.ceil(charges[id] / per) then
          syncHydroBar(pawn, id)
        end
      elseif kind == "charged" then
        -- a charged rod IN HAND is never spent: a fresh one arrives full, and a spent
        -- count meeting a charged item means the next rod of a stack came up after a
        -- transmute. 0 is truthy in Lua, so the old `zaps or full` never reset a spent
        -- count -- the one-bolt-then-flicker loop (live 2026-07-22)
        tiers[id] = "electrick"
        if (zaps[id] or 0) <= 0 then zaps[id] = ctx.config.get("wand_electric_charges") end
      elseif kind == "electric" then
        tiers[id] = "electrick"
      end
      local st, label = effectiveState(id, kind)
      wands[id] = st or "mundane"
      drawn[id] = true
      -- switching straight from one wand slot to the other: rebuild fresh so the new item's hand
      -- mesh is re-cleared and the tip repaints for its state (wood / blue / gold / bright yellow).
      if switched and rigs[id] then tearRig(id, { handsBack = false }) end
      refreshRig(pawn)  -- buildRig sets the stick into the game's own hand slots (overwrites the stale mesh)
      if switched then
        local extra = (st == "hydration") and string.format(" (%.0f measures)", charges[id] or 0) or ""
        ctx.log.info("you take up the " .. (label or "Mundane") .. " Wand" .. extra)
      end
      return
    elseif heldItemKind[id] then
      heldItemKind[id] = nil
      -- fall back to the rite ladder, never to nothing: erasing wands[id] here stripped a
      -- rite-earned rod of its V-draw/recharge the moment its owner picked up any tool
      local t = tiers[id]
      wands[id] = (t == "electrick"
                    and ((wands[id] == "charged" and (zaps[id] or 0) > 0) and "charged" or "uncharged"))
               or (t == "hydration" and "hydration")
               or nil
      drawn[id] = false
      tearRig(id, { handsBack = false })  -- the game already switched to the new item; don't re-equip
      ctx.log.info("you put the wand away")
      return
    end
  end

  if not (drawn[id] and rigs[id]) then return end
  drawn[id] = false
  tearRig(id, { handsBack = false })
  ctx.log.info("you stow the wand to take up a tool")
end

-- The wand-slot savedata: byte-exact copy of what the game's own writer stores in the .sav
-- (raw dump 2026-07-22: '{' CRLF TAB '"Durability": N' CRLF '}') -- composed verbatim in case
-- the parser is a string-matcher rather than a real JSON reader.
local function durabilitySavedata(n)
  return "{\r\n\t\"Durability\": " .. math.floor(n) .. "\r\n}"
end

-- Rewrite the HELD slot in place: item class + qty 1 + savedata, via the inventory system's
-- own OverwriteAndSaveItemAtIndex (offline RE 2026-07-22). This is the watering-can behavior
-- the destroy+regrant flow could never give: the wand NEVER leaves its slot -- no freed-slot
-- races, no spawner drops, no ground pickups. ForceUpdateHotbarSlot then re-reads the active
-- slot into the hand so CurItemdataInHand matches immediately.
local function overwriteHeldSlot(pawn, cls, savedata)
  local m = ctx.map.wand
  if not (m.overwriteSlotFn and m.slotItemField and m.slotQtyField and m.slotSavedataField
          and m.holdIndexFn) then return false end
  local okIdx, idx = ctx.uehelp.call(pawn, m.holdIndexFn)
  local inv; pcall(function() inv = pawn[m.inventorySystemProp or "InventorySystem"] end)
  if not (okIdx and type(idx) == "number" and idx >= 0 and ctx.uehelp.isValid(inv)) then
    mark("overwrite: no held index (idx=" .. tostring(idx) .. ")")
    return false
  end
  lastHandAction = os.clock()   -- the rewrite echoes through the hotbar/hand hooks
  local slot = {
    [m.slotItemField]     = cls,
    [m.slotQtyField]      = 1,
    [m.slotSavedataField] = savedata or "",
  }
  local ok = ctx.uehelp.call(inv, m.overwriteSlotFn, slot, idx)
  mark("overwrite slot idx=" .. tostring(idx) .. " ok=" .. tostring(ok))
  if not ok then
    lastHandAction = -1e9
    return false
  end
  if m.forceHandRefreshFn then ctx.uehelp.call(pawn, m.forceHandRefreshFn) end
  refreshHotbarUi(pawn)
  -- the forced hand refresh destroys+respawns the hand actor while lastHandAction still
  -- suppresses the rebuild hook -- re-heal the rig ourselves once the equip settles
  pcall(ExecuteWithDelay, 600, ctx.log.guard("wand.overwrite.rig", function()
    onGameThread(function()
      if ctx.uehelp.isValid(pawn) then refreshRig(pawn) end
    end)
  end))
  return true
end

-- Swap the REAL held inventory item between the wand forms (kind = "electric" | "charged" |
-- "hydration") by REWRITING ITS SLOT IN PLACE (overwriteHeldSlot). History of why not the
-- obvious paths (all live-failed 2026-07-22): ConsumeItem is the consumable EAT path and
-- silently no-ops on the rods (duplication loop); remove+regrant frees the slot but the
-- debug spawner lands the replacement in an arbitrary slot or on the GROUND ("it just
-- deletes it"). Only fires when the matching REAL item is in hand; the mundane-overlay rod
-- has no item to swap. The delayed onHotbarChanged re-read settles mod state afterwards.
transmuteHeld = function(pawn, toKind)
  if not ctx.config.get("wand_transmute_items") then return end
  local id = playerIdOf(pawn)
  if not id then return end
  local held = heldItemKind[id]
  -- electric<->charged transmute, or the sheep rite's hydration->charged
  local legal = ((held == "electric" or held == "charged") and held ~= toKind)
             or (held == "hydration" and (toKind == "hydration" or toKind == "charged"))
  if not legal then return end
  local rows = ctx.map.wand.itemRows or {}
  if not (rows[toKind] and ctx.items) then return end
  local cls = ctx.items.classFor(rows[toKind])
  if not cls then
    ctx.log.warn("wand: no cooked item class for row " .. tostring(rows[toKind]) .. " -- rod kept as-is")
    return
  end
  -- the new form's charge bar: charged rod = full bolts; blue rod = its current measures;
  -- the spent rod carries no attribute (empty savedata = no bar)
  local savedata = ""
  if toKind == "charged" then
    savedata = durabilitySavedata(ctx.config.get("wand_electric_charges"))
  elseif toKind == "hydration" then
    local per = ctx.config.get("wand_pour_amount")
    local n = (per and per > 0) and math.max(1, math.ceil((charges[id] or 0) / per)) or 1
    savedata = durabilitySavedata(n)
  end
  if overwriteHeldSlot(pawn, cls, savedata) then
    if held == "hydration" and toKind == "charged" then hydroKnown[id] = nil end
    -- barLevel mirrors the HYDRATION item only -- an electric<->charged transmute must NOT
    -- touch it (clobbering it here broke the refill sync and got the blue rod destroyed,
    -- live 2026-07-22 19:54)
    if toKind == "hydration" then
      local per = ctx.config.get("wand_pour_amount")
      barLevel[id] = (per and per > 0) and math.max(1, math.ceil((charges[id] or 0) / per)) or nil
    elseif held == "hydration" then
      barLevel[id] = nil
    end
    heldItemKind[id] = toKind
    pcall(ExecuteWithDelay, 1200, ctx.log.guard("wand.transmute", function()
      onGameThread(function()
        lastHandAction = -1e9
        if ctx.uehelp.isValid(pawn) then onHotbarChanged(pawn) end
      end)
    end))
  else
    ctx.log.warn("wand: the rod's new form failed to arrive -- item row " .. tostring(rows[toKind])
      .. " (recover it with `sps_wand give`)")
  end
end

-- Redraw the hotbar's item bars after a durability step. The game's decrement chain writes the
-- inventory slot but never refreshes the always-visible hotbar on the HOST (no OnRep fires on
-- the authority and the chain broadcasts nothing -- offline RE 2026-07-22), so the bar only
-- moved on a slot switch. UpdateHotbar re-DisplayItems every slot from the live inventory;
-- arg-free, all iteration native-side. CallInventoryChanged also refreshes an OPEN inventory
-- grid; guarded -- a miss just no-ops.
refreshHotbarUi = function(pawn)
  local u, m = ctx.uehelp, ctx.map.wand
  local pc
  pcall(function() pc = pawn[m.localControllerProp or "LocalController"] end)
  if u.isValid(pc) then
    local hb
    pcall(function() hb = pc[m.hotbarWidgetProp or "UI_Hotbar"] end)
    if u.isValid(hb) and m.hotbarRefreshFn then u.call(hb, m.hotbarRefreshFn) end
  end
  local inv
  pcall(function() inv = pawn[m.inventorySystemProp or "InventorySystem"] end)
  if u.isValid(inv) and m.invChangedFn then u.call(inv, m.invChangedFn) end
end

-- Mirror the blue rod's measures onto the held item's DURABILITY BAR, BOTH directions --
-- the watering-can behavior (the cooked row ships DefaultAttribues DURABILITY=12 = 240
-- measures / 20 per pour; W_InventorySlot renders the bar for any attribute-bearing item).
-- ALWAYS an ABSOLUTE in-place rewrite of the slot's savedata, never a relative decrement:
-- a decrement sized off the barLevel MIRROR destroyed the rod live (2026-07-22 19:54 --
-- the electrick transmutes had nil'd the shared mirror, the refill write got skipped as
-- "already full", and the next pour stepped REAL durability 1 -> 0 = the game deletes the
-- item). An absolute write is right even when the mirror is wrong; the mirror only skips
-- redundant writes, and a FAILED write nils it so the next sync retries.
syncHydroBar = function(pawn, id)
  if heldItemKind[id] ~= "hydration" then return end
  local per = ctx.config.get("wand_pour_amount")
  if not per or per <= 0 then return end
  local target = math.max(1, math.ceil((charges[id] or 0) / per))
  if barLevel[id] == target then return end
  local cls = ctx.items and ctx.items.classFor((ctx.map.wand.itemRows or {}).hydration)
  if not cls then mark("hydro bar: no item class -- sync skipped") return end
  if overwriteHeldSlot(pawn, cls, durabilitySavedata(target)) then
    barLevel[id] = target
  else
    barLevel[id] = nil
  end
end

-- Watch the game's own tool-switch signal so the wand steps aside like any other tool would.
local function hookHotbar()
  if hotbarHooked then return end
  local fnName = ctx.map.wand.hotbarChangedFn
  if not fnName then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local path = pawnFnPaths(pawn, { fnName })[1]
  if not path then return end
  -- this can fire re-entrantly inside our OWN stash/restore calls -- the hook body touches no
  -- UObjects beyond the param read; all real work is deferred out of the call chain (gotcha)
  local ok = pcall(RegisterHook, path, ctx.log.guard("wand.hotbar", function(Context)
    local p; pcall(function() p = Context:get() end)
    pcall(ExecuteWithDelay, 120, ctx.log.guard("wand.hotbar2", function()
      onGameThread(function() onHotbarChanged(p) end)
    end))
  end))
  if ok then
    hotbarHooked = true
    ctx.log.info("wand: hotbar watch armed (picking a tool stows the wand)")
  end
end

-- The game rebuilt the held item's hand actor: EVERY UI close (Esc/Back, chest, crafting,
-- inventory...) runs controller SetInputModeGame -> pawn ForceUpdateHotbarSlot -> the same
-- equip block a hotbar switch uses -> UpdateHandMeshesAndModes -> SetHandRBlueprintForBoth,
-- which DESTROYS the previous hand actor (ours included) and poses an empty palm for our
-- unmapped rows -- the invisible-wand-after-inventory bug (offline RE 2026-07-22). One POST
-- hook on that single chokepoint heals every such rebuild. Event-driven (equip flows only,
-- never per-frame), and our own SetHandRBlueprintForBoth calls do NOT pass through it (no
-- recursion). Defers longer than the hotbar hook so real switches settle first.
local function hookHandRebuild()
  if rebuildHooked then return end
  local fnName = ctx.map.wand.handRebuildFn
  if not fnName then return end
  local pawn = ctx.uehelp.findFirst(ctx.map.pawn.class)
  if not pawn then return end
  local path = pawnFnPaths(pawn, { fnName })[1]
  if not path then return end
  local ok = pcall(RegisterHook, path, ctx.log.guard("wand.handrebuild", function(Context)
    local p; pcall(function() p = Context:get() end)
    pcall(ExecuteWithDelay, 250, ctx.log.guard("wand.handrebuild2", function()
      onGameThread(function()
        if os.clock() - lastHandAction < 1.0 then return end  -- our own swap machinery settles itself
        if not ctx.uehelp.isValid(p) then return end
        local id = playerIdOf(p)
        if not (id and drawn[id] and wands[id]) then return end
        -- an inventory shuffle can change the ACTIVE slot's item with no HotbarSlotChanged:
        -- a kind drift is a real switch (take-up/put-away), not a heal
        if ctx.config.get("wand_from_item") and heldItemKind[id]
            and equippedWandKind(p) ~= heldItemKind[id] then
          onHotbarChanged(p)
          return
        end
        refreshRig(p)  -- a dead hand actor forces a rebuild on the same rig record
      end)
    end))
  end))
  if ok then
    rebuildHooked = true
    ctx.log.info("wand: hand-rebuild watch armed (closing a menu no longer empties the palm)")
  end
end

--------------------------------------------------------------------- draw / stow
local function toggleDraw()
  local pawn = localPlayerPawn()
  if not pawn then return end
  local id = playerIdOf(pawn)
  if not id then return end
  if not wands[id] then
    ctx.log.info("you own no wand -- the dark-arts ritual forges one (docs/DARK-ARTS.md)")
    return
  end
  drawn[id] = not drawn[id]
  if drawn[id] then
    ctx.log.info("you draw the " .. STATE_NAMES[wands[id]])
  else
    ctx.log.info("you stow the wand")
  end
  refreshRig(pawn)
end

--------------------------------------------------------------------- init
function F.init(c)
  ctx = c
  -- stickMesh is the only mesh symbol the in-hand visual still needs (SetHandRMeshForBoth path);
  -- handMeshFn's absence is handled gracefully in buildRig (no visual, casting still works), so it
  -- is not a hard gate. smcPath/cobaltMesh went unused when the component rig was removed.
  if not ctx.gate.require(ctx.log, ctx.map, "wand",
      { "pawn.class", "player.controllerClass", "wand.stickMesh" }) then
    return false
  end

  ctx.services.chargeWands = function(center, radius) return F.chargeWands(center, radius) end
  ctx.services.hydrateWands = function(center, radius) return F.hydrateWands(center, radius) end

  -- Recharge: a strike within wand_recharge_radius (5 m) of a player HOLDING the spent rod
  -- refills it to wand_electric_charges bolts and the item turns back into the charged rod --
  -- except the caster's own bolt (no self-recharge loop). "Holding" is the drawn flag; remote
  -- players' flag is unknown host-side (nil), which counts as holding -- the generous reading.
  ctx.bus.on("lightning.strike", ctx.log.guard("wand.recharge", function(e)
    if not (ctx.net.isHost() and e and e.location) then return end
    local r2 = ctx.config.get("wand_recharge_radius") ^ 2
    for _, pawn in ipairs(ctx.uehelp.findAll(ctx.map.pawn.class)) do
      local id = playerIdOf(pawn)
      if id and wands[id] == "uncharged" and id ~= e.castBy and drawn[id] ~= false then
        local pl = ctx.identity.locationOf(pawn)
        if pl and ctx.uehelp.dist2(pl, e.location) <= r2 then
          zaps[id] = ctx.config.get("wand_electric_charges")
          setState(pawn, "charged")
          transmuteHeld(pawn, "charged")
          ctx.log.info(string.format(
            "*** the wand drinks the storm -- RECHARGED (%d bolts) ***", zaps[id]))
        end
      end
    end
  end))

  -- The draw key (config wand_draw_key, default V).
  local kname = ctx.config.get("wand_draw_key")
  pcall(function()
    if RegisterKeyBind and Key and kname and Key[kname] then
      RegisterKeyBind(Key[kname], ctx.log.guard("wand.key", function()
        onGameThread(toggleDraw)
      end))
    end
  end)

  -- Arm the cast + hotbar + refill hooks as soon as a pawn exists (now, on pawn spawn, and on
  -- storms as a retry); rebuild the rig after respawns (the old rig died with the old pawn).
  hookCast()
  hookHotbar()
  hookHandRebuild()
  hookDrink()
  hookWaterTouch()
  ctx.uehelp.onNewInstance("/Script/Engine.Character", ctx.map.pawn.class,
    ctx.log.guard("wand.newpawn", function(p)
      hookCast()
      hookHotbar()
      hookHandRebuild()
      hookDrink()
      hookWaterTouch()
      pcall(ExecuteWithDelay, 1500, ctx.log.guard("wand.respawnrig", function()
        onGameThread(function() refreshRig(p) end)
      end))
    end))
  ctx.bus.on("weather.changed", ctx.log.guard("wand.rearm", function()
    hookCast(); hookHotbar(); hookHandRebuild(); hookDrink(); hookWaterTouch()
  end))

  -- Live rig tuning: any wand_* config change rebuilds drawn rigs immediately (no restart).
  -- Snapshot first: tearRig/refreshRig mutate `rigs` and pairs() must not see that churn.
  ctx.bus.on("config.changed", ctx.log.guard("wand.retune", function(e)
    if not (e and type(e.key) == "string" and e.key:sub(1, 5) == "wand_") then return end
    onGameThread(function()
      local torebuild = {}
      for id, r in pairs(rigs) do torebuild[#torebuild + 1] = { id = id, pawn = r.pawn } end
      for _, t in ipairs(torebuild) do
        tearRig(t.id)
        if ctx.uehelp.isValid(t.pawn) then refreshRig(t.pawn) end
      end
    end)
  end))

  pcall(function()
    RegisterConsoleCommandHandler("sps_wand", function(_, params)
      local sub = (params and params[1]) or "state"
      onGameThread(function()
        local pawn = localPlayerPawn()
        if not pawn then return end
        local id = playerIdOf(pawn)
        if sub == "forge" then
          if wands[id] then ctx.log.info("you already own a wand")
          else setState(pawn, "mundane") end
        elseif sub == "soak" then
          -- test shortcut for the chicken rite: a full-to-the-brim Hydration Wand
          charges[id] = ctx.config.get("wand_hydration_max")
          setState(pawn, "hydration")
        elseif sub == "charge" then
          if wands[id] then setState(pawn, "charged")
          else ctx.log.info("no wand to charge (sps_wand forge first)") end
        elseif sub == "draw" then
          toggleDraw()
        elseif sub == "give" then
          -- Grant the REAL cooked item (from the content pak) into the inventory. This is the
          -- true item, not the mod-managed rig: it stacks, has an icon/name, and the game holds
          -- it through its own tool system. Needs the wand pak installed (Solarpunk-Windows_1_P);
          -- with no pak the row/class won't resolve and this no-ops with a warning.
          local which = (params and params[2]) or "mundane"
          local row = ctx.map.wand.itemRows and ctx.map.wand.itemRows[which]
          if not row then ctx.log.info("sps_wand give mundane|hydration|electric|charged"); return end
          local pc = pawnController(pawn)
          if pc and ctx.items and ctx.items.give(pc, row, 1) then
            ctx.log.info("granted the real " .. row .. " item -- check your inventory/hotbar")
          else
            ctx.log.info("could not grant " .. row ..
              " -- is the wand content pak installed? (Solarpunk-Windows_1_P.*)")
          end
        else
          local owned = wands[id] and (STATE_NAMES[wands[id]] .. (drawn[id] and ", drawn" or ", stowed"))
                        or "none owned"
          if wands[id] == "hydration" or tiers[id] == "hydration" then
            owned = owned .. string.format(" -- %.0f/%.0f measures", charges[id] or 0,
                                           ctx.config.get("wand_hydration_max"))
          end
          if tiers[id] then owned = owned .. " [rung: " .. tiers[id] .. "]" end
          ctx.log.info("wand: " .. owned .. "  (sps_wand forge|soak|charge|draw|give)")
        end
      end)
      return true
    end)
  end)

  ctx.log.info("wand: a real tool now -- drawn with [" .. tostring(kname) ..
    "] into the game's own hand slots; hotbar swaps stow it like any tool")
  return true
end

return F
